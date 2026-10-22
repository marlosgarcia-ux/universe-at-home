--!optimize 2
-- ALLAN learning benchmark (docs/LIQUID_TRAINING.md, "Server training cost").
-- usage: luau [--codegen] bench/liquid_learn.luau [-a quick]
-- Prints "key<TAB>value<TAB>unit" lines. The machine is shared: run each runtime at
-- least three times and keep the per-key minimum of the timings.

local LL = require("../src/LiquidLearn")
local MyMath = require("../src/MyMath")

local args = { ... }
local quick = args[1] == "quick"
local SIZE = if quick then 256 else 1024

local function emit(key: string, value: number, unit: string)
	print(string.format("%s\t%.6g\t%s", key, value, unit))
end

----------------------------------------------------------------------------------
-- targets (3 bytes per pixel), generated with MyMath's deterministic ops
----------------------------------------------------------------------------------

-- Flat UI-like art: panels, bars, circles, text-like glyph cells on a flat background.
local function flatTarget(W: number, H: number): buffer
	local img = buffer.create(W * H * 3)
	local function put(x: number, y: number, r: number, g: number, b: number)
		local o = (y * W + x) * 3
		buffer.writeu8(img, o, r)
		buffer.writeu8(img, o + 1, g)
		buffer.writeu8(img, o + 2, b)
	end
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local u, v = (x + 0.5) / W, (y + 0.5) / H
			local r, g, b = 30, 34, 48
			if u > 0.07 and u < 0.93 and v > 0.1 and v < 0.95 then
				r, g, b = 43, 50, 69
				if v < 0.17 then
					r, g, b = 58, 134, 255
				end
			end
			-- text lines: glyph cells from a hash
			if u > 0.1 and u < 0.85 and v > 0.22 and v < 0.6 then
				local line = (v - 0.22) // 0.05
				local inLine = (v - 0.22) - line * 0.05
				if inLine < 0.025 then
					local cx = u // 0.006
					local cy = inLine // 0.005
					if MyMath.hash2(cx // 1, (line * 8 + cy) // 1, 7) % 3 == 0 then
						r, g, b = 230, 233, 240
					end
				end
			end
			local dx, dy = u - 0.3, v - 0.78
			if dx * dx + dy * dy < 0.004 then
				r, g, b = 254, 188, 46
			end
			if v > 0.68 and v < 0.72 and u > 0.45 and u < 0.85 then
				r, g, b = if u < 0.65 then 58 else 30, if u < 0.65 then 134 else 34, if u < 0.65 then 255 else 48
			end
			put(x, y, r, g, b)
		end
	end
	return img
end

-- Noise-like marble: every pixel differs.
local function marbleTarget(W: number, H: number): buffer
	local img = buffer.create(W * H * 3)
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local u, v = (x + 0.5) / W, (y + 0.5) / H
			local n = MyMath.fbm2(u * 4, v * 4, 1, 5)
			local s = 0.5 + 0.5 * MyMath.dsinTurns(u * 2 + v + 2.2 * n)
			s = s * s
			s = s * s
			local t = 1 - s
			local o = (y * W + x) * 3
			buffer.writeu8(img, o, math.floor((0.28 + (0.93 - 0.28) * t) * 255 + 0.5))
			buffer.writeu8(img, o + 1, math.floor((0.33 + (0.92 - 0.33) * t) * 255 + 0.5))
			buffer.writeu8(img, o + 2, math.floor((0.31 + (0.89 - 0.31) * t) * 255 + 0.5))
		end
	end
	return img
end

----------------------------------------------------------------------------------

local function timeit(f: () -> ()): number
	local t0 = os.clock()
	f()
	return os.clock() - t0
end

local N = 8
local M = 3
local theta = 8
local res = LL.walshReservoir(N, M)
local D = 2 * N + 1

for _, spec in { { "flat", flatTarget }, { "marble", marbleTarget } } do
	local name = spec[1] :: string
	local gen = spec[2] :: (number, number) -> buffer
	local img = gen(SIZE, SIZE)
	local tb0 = os.clock()
	local tr = LL.buildTree(img, SIZE, SIZE, M, M, theta)
	local tBuild = os.clock() - tb0
	emit(name .. ".leaves", tr.leafCount, "count")
	emit(name .. ".tree_build_ms", tBuild * 1000, "ms")
	local segTotal, bands = 0, 0
	do
		local rows = LL.newRows(res, tr, 0)
		local y = 0
		while y < tr.height do
			segTotal += LL.rowSegments(rows, y) * (rows.groupEnd - y)
			bands += 1
			y = rows.groupEnd
		end
	end
	emit(name .. ".segments_per_row", segTotal / tr.height, "count")
	emit(name .. ".bands", bands, "count")
	-- states only (the floor under every accumulation mode)
	local tStates = timeit(function()
		local rows = LL.newRows(res, tr, 0)
		for y = 0, tr.height - 1 do
			LL.rowSegments(rows, y)
			LL.simulateQ(rows)
		end
	end)
	emit(name .. ".states_all_rows_ms", tStates * 1000, "ms")
	-- the S2 cost model of docs/LIQUID.md: one outer product per sampled pixel
	local stNaive = LL.newStats(D, M)
	local tNaive = timeit(function()
		LL.accumulate(stNaive, LL.newRows(res, tr, 0), img, { naive = true })
	end)
	emit(name .. ".S2_naive_stride1_ms", tNaive * 1000, "ms")
	emit(name .. ".S2_naive_stride1_ns_per_sample", tNaive * 1e9 / (SIZE * SIZE), "ns")
	local stNaive4 = LL.newStats(D, M)
	local tNaive4 = timeit(function()
		LL.accumulate(stNaive4, LL.newRows(res, tr, 0), img, { naive = true, stride = 4 })
	end)
	emit(name .. ".S2_naive_stride4_ms", tNaive4 * 1000, "ms")
	local stPlain = LL.newStats(D, M)
	local tPlain = timeit(function()
		LL.accumulate(stPlain, LL.newRows(res, tr, 0), img, {})
	end)
	assert(LL.statsEqual(stPlain, stNaive), "band path must equal the naive path")
	emit(name .. ".S2_plain_stride1_ms", tPlain * 1000, "ms")
	emit(name .. ".S2_plain_stride1_ns_per_sample", tPlain * 1e9 / (SIZE * SIZE), "ns")
	local st4 = LL.newStats(D, M)
	local t4 = timeit(function()
		LL.accumulate(st4, LL.newRows(res, tr, 0), img, { stride = 4 })
	end)
	emit(name .. ".S2_plain_stride4_ms", t4 * 1000, "ms")
	assert(LL.statsEqual(st4, stNaive4), "band path must equal the naive path (stride 4)")
	local stE = LL.newStats(D, M)
	local tE = timeit(function()
		LL.accumulate(stE, LL.newRows(res, tr, 0), img, { event = true })
	end)
	assert(LL.statsEqual(stE, stPlain), "event mode must equal plain mode")
	emit(name .. ".S2_event_ms", tE * 1000, "ms")
	local reps = 200
	local ro = LL.solve(stPlain, N)
	local tSolve = timeit(function()
		for _ = 1, reps do
			LL.solve(stPlain, N)
		end
	end)
	emit(name .. ".solve_D17_us", tSolve * 1e6 / reps, "us")
	local blob = LL.encode(res, ro, tr)
	emit(name .. ".model_bytes", buffer.len(blob), "bytes")
	local tRender = timeit(function()
		LL.renderExact(res, ro, tr, 0)
	end)
	emit(name .. ".render_exact_ms", tRender * 1000, "ms")
	local msgs = LL.packMessages(stPlain, LL.fingerprint(res, M), 1, 1)
	local maxLen = 0
	for _, m in msgs do
		maxLen = math.max(maxLen, #m)
	end
	emit(name .. ".messages", #msgs, "count")
	emit(name .. ".message_max_chars", maxLen, "chars")
	-- time slicing with the real clock: 1.5 ms budget per Heartbeat-sized slice
	for _, mode in { "plain", "plain4", "event" } do
		local opts: LL.AccumOptions = if mode == "event" then { event = true } elseif mode == "plain4" then { stride = 4 } else {}
		local trn = LL.newTrainer(res, tr, img, M, opts, 0)
		local times: { number } = {}
		local total = 0
		while true do
			local t0 = os.clock()
			local done = LL.step(trn, 0.0015)
			local dt = os.clock() - t0
			table.insert(times, dt)
			total += dt
			if done then
				break
			end
		end
		assert(LL.statsEqual(trn.stats, if mode == "plain4" then st4 else stPlain), "sliced statistics differ")
		table.sort(times)
		local over2 = 0
		for _, t in times do
			if t > 0.002 then
				over2 += 1
			end
		end
		emit(name .. ".slice_" .. mode .. "_max_ms", times[#times] * 1000, "ms")
		emit(name .. ".slice_" .. mode .. "_p99_ms", times[math.max(1, math.ceil(#times * 0.99))] * 1000, "ms")
		emit(name .. ".slice_" .. mode .. "_count", #times, "count")
		emit(name .. ".slice_" .. mode .. "_over_2ms", over2, "count")
		emit(name .. ".slice_" .. mode .. "_total_ms", total * 1000, "ms")
		emit(name .. ".slice_" .. mode .. "_units", trn.units, "count")
	end
end

-- S5 gain search on a 256 x 256 target (superset of 3 projections x 10 candidates)
do
	local S5 = 256
	local img = marbleTarget(S5, S5)
	local tree = LL.buildTree(img, S5, S5, M, M, theta)
	-- what one trial costs without the superset: re-simulate, accumulate, solve
	local tTrial = timeit(function()
		local tr, va = LL.accumulateSplit(res, tree, img, M, 4, { event = true })
		LL.solve(tr, N)
		LL.mseOf(va, LL.solve(tr, N))
	end)
	emit("gain256.naive_trial_ms", tTrial * 1000, "ms")
	local r = LL.gainSearch(res, tree, img, M, {})
	emit("gain256.superD", r.superD, "count")
	emit("gain256.trials", r.trials, "count")
	emit("gain256.accumulate_ms", r.accumulateSeconds * 1000, "ms")
	emit("gain256.search_ms", r.searchSeconds * 1000, "ms")
	emit("gain256.val_mse_start", r.startValidationMSE, "mse")
	emit("gain256.val_mse_end", r.validationMSE, "mse")
end

-- environment jitter floor: the same 20-microsecond workload repeated; on a shared
-- machine its maximum shows how much a slice can be delayed by preemption alone
do
	local times: { number } = {}
	local acc = 0
	for _ = 1, 20000 do
		local t0 = os.clock()
		while os.clock() - t0 < 0.00002 do
			acc += 1
		end
		table.insert(times, os.clock() - t0)
	end
	table.sort(times)
	emit("jitter.work_20us_max_ms", times[#times] * 1000, "ms")
	emit("jitter.work_20us_p999_ms", times[math.ceil(#times * 0.999)] * 1000, "ms")
	local over = 0
	for _, t in times do
		if t > 0.0005 then
			over += 1
		end
	end
	emit("jitter.work_20us_over_0.5ms", over, "count")
end
