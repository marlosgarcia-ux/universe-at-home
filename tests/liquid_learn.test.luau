--!strict
-- ALLAN learning tests (src/LiquidLearn.luau; docs/LIQUID_TRAINING.md).
-- Every check compares against constants computed by tools/liquid_train.py, so a
-- pass in both runtimes (tests/run.sh runs the interpreter and --codegen) proves the
-- Luau-trained model is bit-identical across interpreter and native code and equal
-- to the Python exact path.

local LL = require("../src/LiquidLearn")
local MyMath = require("../src/MyMath")
local G = require("../assets/liquid/golden")

local function hexToBuffer(s: string): buffer
	local n = #s // 2
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, tonumber(string.sub(s, 2 * i + 1, 2 * i + 2), 16) :: number)
	end
	return b
end

local function same(a: buffer, b: buffer): boolean
	return buffer.len(a) == buffer.len(b) and buffer.tostring(a) == buffer.tostring(b)
end

local function statsMatch(st: LL.Stats, hi: { number }, lo: { number }): boolean
	local c = LL.copyStats(st)
	LL.normalise(c)
	if c.E ~= #hi then
		return false
	end
	for e = 1, c.E do
		if c.hi[e] ~= hi[e] or c.lo[e] ~= lo[e] then
			return false
		end
	end
	return true
end

-- tiny deterministic permutation generator (MyMath.hash32 based)
local function shuffle<T>(t: { T }, seed: number): { T }
	local out = table.clone(t)
	for i = #out, 2, -1 do
		local j = MyMath.hash32((seed * 7919 + i) % 4294967296) % i + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

----------------------------------------------------------------------------------
-- minimal independent loader and reference renderer (format v1, exact order)
----------------------------------------------------------------------------------

local function minimalRender(model: buffer, r: number): buffer
	assert(buffer.readu8(model, 0) == 0x41 and buffer.readu8(model, 1) == 0x4C and buffer.readu8(model, 2) == 0x4E)
	assert(buffer.readu8(model, 3) == 1)
	local N, I, M, K = buffer.readu8(model, 4), buffer.readu8(model, 5), buffer.readu8(model, 6), buffer.readu8(model, 7)
	local o = 8
	local function f64s(n: number): { number }
		local t = {}
		for i = 1, n do
			t[i] = buffer.readf64(model, o)
			o += 8
		end
		return t
	end
	local beta, B, kBase = f64s(N), f64s(N * I), f64s(N)
	local Cf, Cb, d = f64s(M * N), f64s(M * N), f64s(M)
	local W, H, maxDepth = buffer.readu16(model, o), buffer.readu16(model, o + 2), buffer.readu8(model, o + 4)
	o += 5
	local S, rl = 1, 0
	while S < math.max(W, H) do
		S *= 2
		rl += 1
	end
	local bitPos = 0
	local leaves: { { number } } = {}
	local function walk(x: number, y: number, l: number, depth: number)
		local split = false
		if depth < maxDepth then
			split = bit32.extract(buffer.readu8(model, o + bitPos // 8), bitPos % 8, 1) == 1
			bitPos += 1
		end
		if split then
			local h = 2 ^ (l - 1) // 1
			walk(x, y, l - 1, depth + 1)
			walk(x + h, y, l - 1, depth + 1)
			walk(x, y + h, l - 1, depth + 1)
			walk(x + h, y + h, l - 1, depth + 1)
		else
			table.insert(leaves, { x, y, l })
		end
	end
	walk(0, 0, rl, 0)
	local lb = o + (bitPos + 7) // 8
	local g = { 1 }
	for k = 2, K do
		g[k] = g[k - 1] * 0.5
	end
	local Wr = W * 2 ^ r // 1
	local rep = 2 ^ r // 1
	local out = buffer.create(Wr * H * rep * M)
	for y = 0, H - 1 do
		-- segments crossing row y, sorted by x
		local segs: { { number } } = {}
		for li, lf in leaves do
			local side = 2 ^ lf[3] // 1
			if lf[2] <= y and y < lf[2] + side and lf[1] < W then
				table.insert(segs, { lf[1], math.min(lf[1] + side, W), lf[3], li - 1 })
			end
		end
		table.sort(segs, function(a: { number }, b: { number }): boolean
			return a[1] < b[1]
		end)
		local bs: { { number } }, gs: { { number } } = {}, {}
		for s, seg in segs do
			bs[s], gs[s] = {}, {}
			for i = 1, N do
				local b = beta[i]
				for t = 1, I do
					b = b + B[(i - 1) * I + t] * (buffer.readu8(model, lb + seg[4] * I + t - 1) / 255)
				end
				bs[s][i] = b
				local k = math.clamp(kBase[i] + seg[3] + r, 0, K - 1)
				gs[s][i] = g[k + 1]
			end
		end
		local hf: { { number } }, hb: { { number } } = {}, {}
		local h = table.clone(bs[1])
		for s, seg in segs do
			for x = seg[1] * rep, seg[2] * rep - 1 do
				for i = 1, N do
					h[i] = h[i] + (bs[s][i] - h[i]) * gs[s][i]
				end
				hf[x + 1] = table.clone(h)
			end
		end
		h = table.clone(bs[#segs])
		for s = #segs, 1, -1 do
			local seg = segs[s]
			for x = seg[2] * rep - 1, seg[1] * rep, -1 do
				for i = 1, N do
					h[i] = h[i] + (bs[s][i] - h[i]) * gs[s][i]
				end
				hb[x + 1] = table.clone(h)
			end
		end
		for k = 0, rep - 1 do
			local yr = y * rep + k
			for x = 0, Wr - 1 do
				for m = 1, M do
					local z = d[m]
					for i = 1, N do
						z = z + Cf[(m - 1) * N + i] * hf[x + 1][i]
					end
					for i = 1, N do
						z = z + Cb[(m - 1) * N + i] * hb[x + 1][i]
					end
					buffer.writeu8(out, (yr * Wr + x) * M + m - 1, math.clamp(math.floor(z + 0.5), 0, 255))
				end
			end
		end
	end
	return out
end

----------------------------------------------------------------------------------
-- per-case checks: tree, statistics, readout bytes, numpy tolerance, golden pixels
----------------------------------------------------------------------------------

local NUMPY_TOLERANCE = 0.1 -- stated tolerance on z (byte units) between Luau and numpy readouts

local okLiquid, Liquid = pcall(require, "../src/Liquid")
local checkedThroughLiquid = 0

for _, c in G do
	local size, r, M, N = c.size, c.r, c.M, c.N
	local srcSize = size // (2 ^ r // 1)
	local source = hexToBuffer(c.source)
	local target = hexToBuffer(c.target)

	-- 1. quadtree bytes equal the Python builder's
	local tree = LL.buildTree(source, srcSize, srcSize, M, M, c.theta)
	assert(tree.leafCount == c.leaves, c.name .. ": leaf count")
	assert(same(LL.encodeTree(tree), hexToBuffer(c.tree)), c.name .. ": tree bytes differ from Python")

	-- 2. reservoir and fingerprint
	local res = LL.walshReservoir(N, M, c.K, nil, c.scales)
	assert(LL.fingerprint(res, M) == c.fingerprint, c.name .. ": fingerprint")

	-- 3. exact statistics: plain stride 1, event mode, sliced trainer, stride 4
	local D = 2 * N + 1
	local st1 = LL.newStats(D, M)
	LL.accumulate(st1, LL.newRows(res, tree, r), target, {})
	assert(statsMatch(st1, c.stats1Hi, c.stats1Lo), c.name .. ": stride-1 statistics differ from Python")
	local stE = LL.newStats(D, M)
	LL.accumulate(stE, LL.newRows(res, tree, r), target, { event = true })
	assert(LL.statsEqual(st1, stE), c.name .. ": event mode differs from plain mode")
	local ticks = 0
	local fakeClock = function(): number
		ticks += 1
		return ticks * 0.001 -- every clock read advances 1 ms: one unit per slice
	end
	for _, mode in { false, true } do
		local trn = LL.newTrainer(res, tree, target, M, { event = mode }, r, fakeClock)
		trn.kChunk = 7
		trn.rowChunk = 3
		local guard = 0
		while not LL.step(trn, 0.0005) do
			guard += 1
			assert(guard < 1000000, "trainer does not finish")
		end
		assert(trn.slices > 10, "trainer should have been sliced")
		assert(LL.statsEqual(trn.stats, st1), c.name .. ": sliced trainer differs")
	end
	local st4 = LL.newStats(D, M)
	LL.accumulate(st4, LL.newRows(res, tree, r), target, { stride = 4 })
	assert(statsMatch(st4, c.stats4Hi, c.stats4Lo), c.name .. ": stride-4 statistics differ from Python")

	-- 4. readout bytes: bit-identical to tools/liquid_train.py cholesky_solve_exact
	local ro = LL.solve(st1, N, c.lambda)
	assert(same(LL.encodeReadout(ro), hexToBuffer(c.readoutExact)), c.name .. ": readout bytes differ from Python")
	local ro4 = LL.solve(st4, N, c.lambda)
	assert(same(LL.encodeReadout(ro4), hexToBuffer(c.readoutExact4)), c.name .. ": stride-4 readout bytes differ")
	-- event-aware ridge (larger ridge on slow neurons): bit-identical to Python, and it
	-- shrinks the slow neurons' weights
	local roSlow = LL.solve(st1, N, c.lambda, LL.slowRidge(res, 1e4))
	assert(same(LL.encodeReadout(roSlow), hexToBuffer(c.readoutSlow)), c.name .. ": event-aware readout bytes differ")
	local function slowWeight(r: LL.Readout): number
		local sum = 0
		for m = 1, M do
			for i = 1, N do
				if res.kBase[i] > -res.K then
					sum += math.abs(r.Cf[(m - 1) * N + i]) + math.abs(r.Cb[(m - 1) * N + i])
				end
			end
		end
		return sum
	end
	assert(slowWeight(roSlow) < slowWeight(ro), c.name .. ": the event-aware ridge must shrink slow weights")

	-- 5. numpy float readout: predictions within the stated tolerance
	local npb = hexToBuffer(c.readoutNumpy)
	local npro: LL.Readout = { M = M, N = N, Cf = {}, Cb = {}, d = {} }
	for i = 1, M * N do
		npro.Cf[i] = buffer.readf64(npb, (i - 1) * 8)
		npro.Cb[i] = buffer.readf64(npb, (M * N + i - 1) * 8)
	end
	for m = 1, M do
		npro.d[m] = buffer.readf64(npb, (2 * M * N + m - 1) * 8)
	end
	local rows = LL.newRows(res, tree, r)
	local W = rows.W
	local hf, hb = table.create(W * N, 0), table.create(W * N, 0)
	local maxDz = 0
	for y = 0, tree.height - 1 do
		LL.rowSegments(rows, y)
		LL.simulate(rows, hf, hb)
		for x = 0, W - 1 do
			for m = 1, M do
				local za, zb = ro.d[m], npro.d[m]
				for i = 1, N do
					za = za + ro.Cf[(m - 1) * N + i] * hf[x * N + i]
					zb = zb + npro.Cf[(m - 1) * N + i] * hf[x * N + i]
				end
				for i = 1, N do
					za = za + ro.Cb[(m - 1) * N + i] * hb[x * N + i]
					zb = zb + npro.Cb[(m - 1) * N + i] * hb[x * N + i]
				end
				maxDz = math.max(maxDz, math.abs(za - zb))
			end
		end
	end
	assert(maxDz <= NUMPY_TOLERANCE, c.name .. ": Luau vs numpy readout beyond tolerance: " .. maxDz)
	assert(maxDz == c.numpyMaxDz, c.name .. ": max |dz| should equal Python's bit for bit")

	-- 6. golden pixels of the exported model
	local model = hexToBuffer(c.model)
	local pixels = hexToBuffer(c.pixels)
	assert(same(LL.encode(res, ro, tree), model), c.name .. ": Luau-built model bytes differ from Python export")
	local dres, dro, dtree = LL.decode(model)
	assert(same(LL.renderExact(dres, dro, dtree, r), pixels), c.name .. ": LiquidLearn.renderExact differs from golden")
	assert(same(minimalRender(model, r), pixels), c.name .. ": minimal loader differs from golden")
	-- through the renderer, src/Liquid.luau (RGBA8 output; channels >= M are 0, alpha 255)
	local Lq: any = if okLiquid then Liquid else nil
	local hasRenderer = type(Lq) == "table" and type(Lq.decode) == "function" and type(Lq.prepare) == "function" and type(Lq.reference) == "function"
	local hasEventRenderer = hasRenderer and type(Lq.render) == "function"
	if hasRenderer then
		local lm, lt = Lq.decode(model)
		local plan = Lq.prepare(lm, lt, r)
		local Wr = size
		local function channelDiff(rgba: buffer): number
			local worst = 0
			for p = 0, Wr * Wr - 1 do
				for m = 0, 3 do
					local want = if m < M then buffer.readu8(pixels, p * M + m) elseif m == 3 then 255 else 0
					worst = math.max(worst, math.abs(buffer.readu8(rgba, p * 4 + m) - want))
				end
			end
			return worst
		end
		local ref = buffer.create(Wr * Wr * 4)
		Lq.reference(plan, lt, ref, Wr)
		assert(channelDiff(ref) == 0, c.name .. ": src/Liquid.luau reference differs from the golden pixels")
		checkedThroughLiquid += 1
		if hasEventRenderer then
			for _, eps in { 0, 0.5 } do
				local ev = buffer.create(Wr * Wr * 4)
				local ok = pcall(Lq.render, plan, lt, ev, Wr, { epsilon = eps })
				if ok then
					-- T2: every byte within eps + 0.5 of the exact value, so within
					-- floor(eps + 1) of the golden byte (reported, owned by tests/liquid.test.luau)
					print(string.format("%s: Liquid.render eps %.2f max |byte - golden| = %d (bound %d)", c.name, eps, channelDiff(ev), math.floor(eps + 1)))
				end
			end
		end
	end

	-- 7. validation from statistics equals the rendered training error (before rounding)
	local mse = LL.mseOf(st1, ro)
	assert(mse >= 0 and mse < 65025, c.name .. ": mseOf out of range")
end

----------------------------------------------------------------------------------
-- S4: federated merge, every order gives the same readout bytes
----------------------------------------------------------------------------------

do
	local c = G[1]
	local M, N, size = c.M, c.N, c.size
	local target = hexToBuffer(c.target)
	local tree = LL.buildTree(target, size, size, M, M, c.theta)
	local res = LL.walshReservoir(N, M, c.K, nil, c.scales)
	local D = 2 * N + 1
	local fp = LL.fingerprint(res, M)
	-- five servers each own a horizontal band of rows (their textures / player edits)
	local servers = 5
	local per: { LL.Stats } = {}
	for sidx = 1, servers do
		per[sidx] = LL.newStats(D, M)
	end
	local rows = LL.newRows(res, tree, 0)
	for y = 0, tree.height - 1 do
		LL.rowSegments(rows, y)
		LL.simulateQ(rows)
		local sidx = (y * servers) // tree.height + 1
		LL.accumulateRange(per[sidx], rows, target, y, y + 1, 0, rows.W, {})
	end
	local whole = LL.newStats(D, M)
	LL.accumulate(whole, LL.newRows(res, tree, 0), target, {})
	local wantBytes = buffer.tostring(LL.encodeReadout(LL.solve(whole, N, c.lambda)))
	assert(wantBytes == buffer.tostring(hexToBuffer(c.readoutExact)))

	-- messages: every server publishes its cumulative stats as sequence 1, and an
	-- older partial snapshot as sequence 0 (stale, must be ignored)
	local allMsgs: { string } = {}
	for sidx = 1, servers do
		local stale = LL.copyStats(per[sidx])
		LL.halveStats(stale)
		for _, m in LL.packMessages(stale, fp, 1000 + sidx, 0) do
			table.insert(allMsgs, m)
		end
		local msgs = LL.packMessages(per[sidx], fp, 1000 + sidx, 1)
		for _, m in msgs do
			assert(#m <= LL.MAX_MESSAGE_CHARS, "message over 1000 characters")
			table.insert(allMsgs, m)
			table.insert(allMsgs, m) -- duplicate delivery
		end
	end
	-- a message from another reservoir must be rejected
	local other = LL.walshReservoir(N, M, c.K, nil, { -64, 1 })
	for _, m in LL.packMessages(per[1], LL.fingerprint(other, M), 99, 5) do
		table.insert(allMsgs, m)
	end
	for trial = 1, 24 do
		local led = LL.newLedger(fp, D, M)
		for _, m in shuffle(allMsgs, trial) do
			LL.receive(led, m)
		end
		local got = buffer.tostring(LL.encodeReadout(LL.solve(LL.total(led), N, c.lambda)))
		assert(got == wantBytes, "merge order " .. trial .. " changed the readout bytes")
		assert(led.slots[99] == nil, "foreign fingerprint merged")
	end
	-- tree-shaped merges with addStats in different groupings
	for trial = 1, 12 do
		local order = shuffle({ 1, 2, 3, 4, 5 }, 100 + trial)
		local a = LL.copyStats(per[order[1]])
		local b = LL.copyStats(per[order[2]])
		LL.addStats(b, per[order[3]])
		local cst = LL.copyStats(per[order[4]])
		LL.addStats(cst, per[order[5]])
		LL.addStats(a, cst)
		LL.addStats(b, a)
		assert(LL.statsEqual(b, whole), "grouping changed the integer sums")
	end
	-- ledger-to-ledger state merge (CRDT): union of two partial ledgers
	local l1, l2 = LL.newLedger(fp, D, M), LL.newLedger(fp, D, M)
	for sidx = 1, servers do
		LL.observe(if sidx % 2 == 0 then l1 else l2, 1000 + sidx, 1, per[sidx])
	end
	LL.observe(l1, 1003, 0, per[1]) -- stale entry for a sender l2 knows newer
	for sender, slot in l2.slots do
		LL.observe(l1, sender, slot.sequence, slot.stats)
	end
	assert(buffer.tostring(LL.encodeReadout(LL.solve(LL.total(l1), N, c.lambda))) == wantBytes)
	-- folding a finished sender keeps the total
	LL.fold(l1, 1002)
	assert(LL.statsEqual(LL.total(l1), whole), "fold changed the total")
	assert(not LL.observe(l1, 1002, 7, per[2]), "folded sender must be ignored")
	-- DataStore round trip
	local ser = LL.serializeStats(whole, fp)
	local back, fp2 = LL.deserializeStats(ser, D, M)
	assert(fp2 == fp and LL.statsEqual(back, whole), "serialize round trip")

	------------------------------------------------------------------------------
	-- S6: exact online updates
	------------------------------------------------------------------------------
	local twice = LL.copyStats(whole)
	LL.addStats(twice, whole)
	LL.halveStats(twice)
	assert(LL.statsEqual(twice, whole), "halving 2S must give S exactly")
	local win = LL.copyStats(whole)
	LL.subStats(win, per[1])
	local rest = LL.newStats(D, M)
	for sidx = 2, servers do
		LL.addStats(rest, per[sidx])
	end
	assert(LL.statsEqual(win, rest), "sliding-window subtraction must be exact")

	------------------------------------------------------------------------------
	-- S5: gain search on sub-Grams is exact
	------------------------------------------------------------------------------
	local gs = LL.gainSearch(res, tree, target, M, { candidates = { -64, -2, 0, 2 }, sweeps = 2, lambda = c.lambda })
	assert(gs.validationMSE <= gs.startValidationMSE, "gain search must not worsen validation error")
	assert(gs.trials > 1)
	local tuned = LL.walshReservoir(N, M, c.K, gs.kBase, nil)
	local trT = LL.accumulateSplit(tuned, tree, target, M, 4, {})
	local direct = LL.solve(trT, N, c.lambda)
	assert(math.abs(LL.mseOf(trT, direct) - gs.trainMSE) <= 1e-9 * (1 + gs.trainMSE), "sub-Gram solve must equal a direct solve")
	-- byte level: statistics extracted from a superset equal a direct accumulation of
	-- the configuration, integer for integer, and give the same readout bytes
	local sp, sk = {}, {}
	for p = 0, M - 1 do
		for _, k in { -64, -2, 0, 2 } do
			table.insert(sp, p)
			table.insert(sk, k)
		end
	end
	local S = #sp
	local sup = LL.walshReservoir(S, M, c.K, sk, nil, sp)
	local stSup = LL.newStats(2 * S + 1, M)
	LL.accumulate(stSup, LL.newRows(sup, tree, 0), target, {})
	local pick = { 1, 5, 9, 3, 6, 12, 2 } -- any neurons of the superset, in any order
	local cp, ck = {}, {}
	for i, si in pick do
		cp[i], ck[i] = sp[si], sk[si]
	end
	local cfg = LL.walshReservoir(#pick, M, c.K, ck, nil, cp)
	local stCfg = LL.newStats(2 * #pick + 1, M)
	LL.accumulate(stCfg, LL.newRows(cfg, tree, 0), target, {})
	local ext = LL.extractStats(stSup, LL.superMap(pick, S))
	assert(LL.statsEqual(ext, stCfg), "extracted sub-statistics must equal a direct accumulation")
	assert(
		buffer.tostring(LL.encodeReadout(LL.solve(ext, #pick, c.lambda))) == buffer.tostring(LL.encodeReadout(LL.solve(stCfg, #pick, c.lambda))),
		"sub-Gram readout bytes must equal the direct readout bytes"
	)
end

-- S3 invariant under splitting: a lowered per-pass weight limit forces every band to
-- be cut into sub-bands (batch path and trainer); the integers must not change
do
	local c = G[2]
	local M, N, size = c.M, c.N, c.size
	local target = hexToBuffer(c.target)
	local tree = LL.buildTree(target, size, size, M, M, c.theta)
	local res = LL.walshReservoir(N, M, c.K, nil, c.scales)
	local ticks = 0
	local clock = function(): number
		ticks += 1
		return ticks * 0.001
	end
	local saved = LL.pendingLimit
	local modes: { LL.AccumOptions } = { {}, { event = true }, { stride = 4 } }
	for _, o in modes do
		LL.pendingLimit = saved
		local want = LL.newStats(2 * N + 1, M)
		LL.accumulate(want, LL.newRows(res, tree, 0), target, o)
		LL.pendingLimit = 3 * size -- three render rows per pass
		local st = LL.newStats(2 * N + 1, M)
		LL.accumulate(st, LL.newRows(res, tree, 0), target, o)
		assert(LL.statsEqual(st, want), "split batch accumulation changed the integers")
		local trn = LL.newTrainer(res, tree, target, M, o, 0, clock)
		while not LL.step(trn, 0.0005) do
		end
		assert(LL.statsEqual(trn.stats, want), "split trainer changed the integers")
	end
	LL.pendingLimit = saved
end

-- 7. S3 second limb: 2^24 samples of the largest feature (q = 32767) give
-- G[1][1] = 2^24 * q^2 > 2^53, so the sums are exact only through the second limb.
do
	local res = LL.walshReservoir(1, 1, 16, { -64 }, nil) -- one instant neuron: q = 32767
	local img = buffer.create(1024 * 64)
	buffer.fill(img, 0, 255)
	local tree = LL.buildTree(img, 1024, 64, 1, 1, 0)
	local rows = LL.newRows(res, tree, 0)
	local st = LL.newStats(3, 1)
	for _ = 1, 256 do
		LL.accumulate(st, rows, img, { event = true }) -- 65536 samples per call
	end
	local c = LL.copyStats(st)
	LL.normalise(c)
	-- exact value v = q^2 * 2^24 = (q^2 // 256) * 2^32 + (q^2 % 256) * 2^24
	local q2 = 32767 * 32767
	assert(q2 * 16777216 > 9007199254740992, "the test must exceed 2^53")
	for e = 1, 6 do -- all six G entries equal q^2 * 2^24
		assert(c.hi[e] == q2 // 256 and c.lo[e] == (q2 % 256) * 16777216, "G limbs")
	end
	local T = 6 + 3
	assert(c.hi[T + 1] == 65025 // 256 and c.lo[T + 1] == (65025 % 256) * 16777216, "YY limbs")
	assert(c.hi[c.E] == 0 and c.lo[c.E] == 16777216, "count limbs")
end

print(string.format("liquid_learn ok (%d golden cases, %d through src/Liquid.luau)", #G, checkedThroughLiquid))
