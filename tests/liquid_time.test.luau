--!strict
-- Tests for LiquidTime (ALLAN X1: extrapolation in time, texture dead reckoning). Run by
-- tests/run.sh in the interpreter and with native code generation; every check asserts.
--
-- What is proved here, each against an independent computation:
--   A  the closed-form jump equals the dynamics stepped tick by tick (stepReference)
--   B  the answer depends only on the set of events, not on delivery order, duplicates, late
--      arrival (rollback and replay) or the horizon (checkpoints): bits are identical
--   C  the answer does not depend on how often or when a device asked
--   D  messages round-trip through their binary form and give the same world
--   E  the wake-up calendar (dirty) reports exactly what checking every leaf reports (dirtyBrute)
--   F  the response of one late input equals driftBound (docs: a late input is bounded)
--   G  reset forgets cursors but keeps events
-- A golden digest pins the result to the same constant in both runtimes.
--
-- Contract noted while writing the test: per leaf, queries must come in non-decreasing tick
-- order (the cursor only moves forward, apart from rollbacks caused by late events).

local LiquidTime = require("../src/LiquidTime")
local MyMath = require("../src/MyMath")

type Msg = LiquidTime.Message
type World = LiquidTime.World

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local GOLDEN = { state = 4111357201 }
local PRINT_GOLDEN = false

local function rng(seed: number): () -> number
	local n = 0
	return function(): number
		n += 1
		return MyMath.rand2(n, 77, seed)
	end
end

type Cfg = { L: number, C: number, P: number, seed: number, order: number, drive: string, kmax: number }

local function makeSpec(cfg: Cfg): LiquidTime.Spec
	local rand = rng(cfg.seed * 31 + 5)
	local L, C = cfg.L, cfg.C
	local k: { number } = {}
	local y0: { number } = {}
	local rows: { number } = {}
	local cx: { number } = {}
	local cy: { number } = {}
	local base: { number } = {}
	local amp: { number } = {}
	local side = math.ceil(math.sqrt(L))
	for l = 0, L - 1 do
		k[l + 1] = math.floor(rand() * (cfg.kmax + 1))
		local gx, gy = l % side, l // side
		cx[l + 1] = gx * 16 + 8
		cy[l + 1] = gy * 16 + 8
		y0[l + 1] = gy * 16
		rows[l + 1] = 16
		for c = 0, C - 1 do
			local i = l * C + c + 1
			base[i] = 60 + math.floor(rand() * 120)
			amp[i] = math.floor(rand() * 40)
		end
	end
	return {
		leaves = L,
		channels = C,
		epoch = cfg.P,
		seed = cfg.seed,
		order = cfg.order,
		height = side * 16,
		k = k,
		y0 = y0,
		rows = rows,
		cx = cx,
		cy = cy,
		base = base,
		amp = amp,
		drive = cfg.drive,
		flowScale = 48,
		flowVx = 0.37,
		flowVy = 0.11,
	}
end

-- Messages whose values are multiples of 1/256, so that they survive the binary form exactly.
local function randomMessages(cfg: Cfg, count: number, tMax: number, seed: number): { Msg }
	local rand = rng(seed * 101 + 9)
	local out: { Msg } = {}
	local side = math.ceil(math.sqrt(cfg.L))
	for n = 1, count do
		local pick = rand()
		local m: Msg = {
			kind = 1,
			tick = 1 + math.floor(rand() * tMax),
			seq = n,
			leaf = math.floor(rand() * cfg.L),
			ch = math.floor(rand() * cfg.C),
			value = 0,
			x = 0,
			y = 0,
			r = 0,
		}
		if pick < 0.6 then
			m.kind = 1
			m.value = math.floor((rand() * 120 - 60) * 256) / 256
		elseif pick < 0.8 then
			m.kind = 2
			m.value = math.floor((rand() * 80 - 40) * 256) / 256
		else
			m.kind = 3
			m.value = math.floor((rand() * 160 - 80) * 256) / 256
			m.x = math.floor(rand() * side * 16)
			m.y = math.floor(rand() * side * 16)
			m.r = 8 + math.floor(rand() * 32)
		end
		out[#out + 1] = m
	end
	return out
end

local function shuffled(msgs: { Msg }, seed: number): { Msg }
	local rand = rng(seed)
	local a = table.clone(msgs)
	for i = #a, 2, -1 do
		local j = 1 + math.floor(rand() * i)
		a[i], a[j] = a[j], a[i]
	end
	return a
end

local function build(cfg: Cfg, msgs: { Msg }): World
	local W = LiquidTime.new(makeSpec(cfg))
	for _, m in msgs do
		LiquidTime.handle(W, m)
	end
	return W
end

local function sameList(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

----------------------------------------------------------------------------------------
-- A. closed form against the dynamics written literally
----------------------------------------------------------------------------------------

local CONFIGS: { Cfg } = {
	{ L = 12, C = 2, P = 1, seed = 1, order = 2, drive = "hash", kmax = 6 },
	{ L = 12, C = 2, P = 7, seed = 2, order = 2, drive = "hash", kmax = 8 },
	{ L = 12, C = 3, P = 16, seed = 3, order = 1, drive = "hash", kmax = 8 },
	{ L = 16, C = 2, P = 37, seed = 4, order = 2, drive = "flow", kmax = 10 },
	{ L = 9, C = 4, P = 5, seed = 5, order = 1, drive = "flow", kmax = 30 },
	{ L = 12, C = 2, P = 64, seed = 6, order = 2, drive = "hash", kmax = 30 },
}
local T_FINAL = 260

do
	local worst = 0
	for _, cfg in CONFIGS do
		local msgs = randomMessages(cfg, 60, 200, cfg.seed)
		local W = build(cfg, msgs)
		local queries = { 0, 1, 2, cfg.P - 1, cfg.P, cfg.P + 1, 50, 51, 99, 120, 199, 200, 201, T_FINAL }
		table.sort(queries)
		local out: { number } = table.create(cfg.C, 0)
		local last = -1
		for _, T in queries do
			if T ~= last and T >= 0 then
				last = T
				local ref = LiquidTime.stepReference(W, T)
				for l = 0, cfg.L - 1 do
					LiquidTime.valuesAt(W, l, T, out)
					for c = 0, cfg.C - 1 do
						local want = ref[l * cfg.C + c + 1]
						local err = math.abs(out[c + 1] - want) / (1 + math.abs(want))
						worst = math.max(worst, err)
						check(err < 1e-7, string.format("closed form vs steps: cfg seed %d leaf %d ch %d T %d got %.9g want %.9g", cfg.seed, l, c, T, out[c + 1], want))
					end
				end
			end
		end
	end
	check(worst < 1e-9, "closed form is as exact as the stepped dynamics (worst relative gap " .. worst .. ")")
end

----------------------------------------------------------------------------------------
-- B. order, duplicates, late arrival and the horizon do not change the bits
----------------------------------------------------------------------------------------

local goldenParts: { number } = {}

do
	for ci, cfg in CONFIGS do
		local msgs = randomMessages(cfg, 70, 200, cfg.seed + 40)
		local W1 = build(cfg, msgs)
		local h1 = LiquidTime.hashState(W1, T_FINAL)
		table.insert(goldenParts, h1)

		-- shuffled order
		local W2 = build(cfg, shuffled(msgs, 7 + ci))
		check(LiquidTime.hashState(W2, T_FINAL) == h1, "shuffled delivery order, cfg " .. ci)

		-- every message twice
		local W3 = LiquidTime.new(makeSpec(cfg))
		for _, m in msgs do
			LiquidTime.handle(W3, m)
		end
		for _, m in shuffled(msgs, 99 + ci) do
			LiquidTime.handle(W3, m)
		end
		check(LiquidTime.hashState(W3, T_FINAL) == h1, "duplicates are ignored, cfg " .. ci)

		-- late arrival: the far future first, a query in the middle, then the rest
		for _, horizon in { 0, 90 } do
			local W4 = LiquidTime.new(makeSpec(cfg))
			if horizon > 0 then
				LiquidTime.setHorizon(W4, horizon)
			end
			local early: { Msg } = {}
			local late: { Msg } = {}
			for _, m in msgs do
				table.insert(if m.tick > 120 then early else late, m)
			end
			for _, m in early do
				LiquidTime.handle(W4, m)
			end
			LiquidTime.hashState(W4, 100)
			for _, m in shuffled(late, 5 + ci) do
				LiquidTime.handle(W4, m)
			end
			check(LiquidTime.hashState(W4, T_FINAL) == h1, string.format("late events (horizon %d), cfg %d", horizon, ci))
			check(W4.rollbacks > 0, string.format("late events were exercised (horizon %d), cfg %d", horizon, ci))
		end
	end
end

-- The horizon only makes rollbacks cheap: late events at or above it never replay from zero.
do
	local cfg = CONFIGS[2]
	local msgs = randomMessages(cfg, 80, 200, 61)
	local W1 = build(cfg, msgs)
	local h1 = LiquidTime.hashState(W1, T_FINAL)
	local W = LiquidTime.new(makeSpec(cfg))
	local known: { Msg } = {}
	local ahead: { Msg } = {}
	local late: { Msg } = {}
	for _, m in msgs do
		table.insert(if m.tick < 100 then known elseif m.tick >= 150 then ahead else late, m)
	end
	for _, m in known do
		LiquidTime.handle(W, m)
	end
	LiquidTime.setHorizon(W, 100)
	for _, m in ahead do
		LiquidTime.handle(W, m)
	end
	LiquidTime.hashState(W, 170)
	for _, m in late do
		LiquidTime.handle(W, m)
	end
	check(#late > 0 and W.rollbacks > 0, "events at or above the horizon arrived late")
	check(W.replays == 0, "events at or above the horizon roll back to a checkpoint, never to zero (replays " .. W.replays .. ")")
	check(LiquidTime.hashState(W, T_FINAL) == h1, "horizon run gives the bits of the all-at-once world")
end

-- A splash is exactly a kick of v (1 - d^2 / r^2) into every leaf centre closer than r.
do
	local cfg: Cfg = { L = 25, C = 2, P = 6, seed = 17, order = 2, drive = "hash", kmax = 6 }
	local spec = makeSpec(cfg)
	local x, y, r, v = 37, 29, 30, 48.5
	local Wa = LiquidTime.new(spec)
	local n = LiquidTime.splash(Wa, 10, 3, x, y, r, 1, v)
	local Wb = LiquidTime.new(spec)
	local expected = 0
	for l = 0, cfg.L - 1 do
		local dx, dy = spec.cx[l + 1] - x, spec.cy[l + 1] - y
		local d2 = dx * dx + dy * dy
		if d2 < r * r then
			expected += 1
			LiquidTime.receive(Wb, { tick = 10, seq = 3, sub = l + 1, kind = 1, leaf = l, ch = 1, value = v * (1 - d2 / (r * r)) })
		end
	end
	check(expected > 3 and expected < cfg.L, "the splash test touches some leaves and not all (" .. expected .. ")")
	check(n == expected, "splash reports the number of leaves it kicked")
	check(LiquidTime.hashState(Wa, 40) == LiquidTime.hashState(Wb, 40), "splash equals the kicks it is defined as")
	-- a leaf exactly at the radius is outside (leaf 0 has its centre at 8, 8)
	local Wd = LiquidTime.new(spec)
	local nEdge = LiquidTime.splash(Wd, 10, 4, 8 + r, 8, r, 0, v)
	local expectedEdge = 0
	for l = 0, cfg.L - 1 do
		local dx, dy = spec.cx[l + 1] - (8 + r), spec.cy[l + 1] - 8
		if dx * dx + dy * dy < r * r then
			expectedEdge += 1
		end
	end
	check(nEdge == expectedEdge and spec.cx[1] == 8 and spec.cy[1] == 8, "a leaf centre exactly r away is not kicked")
	-- a leaf outside the radius is untouched by it
	local Wc = LiquidTime.new(spec)
	local oa: { number } = table.create(cfg.C, 0)
	local oc: { number } = table.create(cfg.C, 0)
	for l = 0, cfg.L - 1 do
		local dx, dy = spec.cx[l + 1] - x, spec.cy[l + 1] - y
		if dx * dx + dy * dy >= r * r then
			LiquidTime.valuesAt(Wa, l, 40, oa)
			LiquidTime.valuesAt(Wc, l, 40, oc)
			check(oa[1] == oc[1] and oa[2] == oc[2], "a leaf outside the splash radius is untouched")
		end
	end
end

----------------------------------------------------------------------------------------
-- C. how often a device asks does not change the answer
----------------------------------------------------------------------------------------

do
	local cfg = CONFIGS[4]
	local msgs = randomMessages(cfg, 80, 200, 123)
	local W1 = build(cfg, msgs)
	local h1 = LiquidTime.hashState(W1, T_FINAL)

	local W2 = build(cfg, msgs)
	local out: { number } = table.create(cfg.C, 0)
	for T = 0, T_FINAL - 1 do
		for l = 0, cfg.L - 1 do
			LiquidTime.valuesAt(W2, l, T, out)
		end
	end
	check(LiquidTime.hashState(W2, T_FINAL) == h1, "asking at every tick gives the same bits as asking once")

	local W3 = build(cfg, msgs)
	local rand = rng(4242)
	local T = 0
	while T < T_FINAL - 1 do
		T = math.min(T_FINAL - 1, T + 1 + math.floor(rand() * 40))
		for l = 0, cfg.L - 1 do
			if rand() < 0.5 then
				LiquidTime.valuesAt(W3, l, T, out)
			end
		end
	end
	check(LiquidTime.hashState(W3, T_FINAL) == h1, "asking at random times and leaves gives the same bits")
end

----------------------------------------------------------------------------------------
-- D. binary messages
----------------------------------------------------------------------------------------

do
	local cfg = CONFIGS[2]
	local msgs = randomMessages(cfg, 120, 200, 77)
	local sizes = { [1] = 18, [2] = 18, [3] = 20, [4] = 5 }
	for _, m in msgs do
		local b = LiquidTime.encode(m)
		check(buffer.len(b) == sizes[m.kind], "message size for kind " .. m.kind)
		local d = LiquidTime.decode(b)
		check(d.kind == m.kind and d.tick == m.tick and d.seq == m.seq, "kind, tick and seq survive")
		check(d.value == m.value, "a value that is a multiple of 1/256 survives exactly")
		if m.kind == 3 then
			check(d.x == m.x and d.y == m.y and d.r == m.r and d.ch == m.ch, "splash fields survive")
		else
			check(d.leaf == m.leaf and d.ch == m.ch, "leaf and channel survive")
		end
	end
	local hz = LiquidTime.decode(LiquidTime.encode({ kind = 4, tick = 1234, seq = 0, leaf = 0, ch = 0, value = 0, x = 0, y = 0, r = 0 }))
	check(hz.kind == 4 and hz.tick == 1234, "horizon message survives")
	local rounded = LiquidTime.decode(LiquidTime.encode({ kind = 1, tick = 5, seq = 1, leaf = 2, ch = 1, value = 1.2345, x = 0, y = 0, r = 0 }))
	check(rounded.value == math.floor(1.2345 * 256 + 0.5) / 256, "other values round to the nearest 1/256")

	-- a world fed through the wire equals one fed directly
	local W1 = build(cfg, msgs)
	local W2 = LiquidTime.new(makeSpec(cfg))
	for _, m in msgs do
		LiquidTime.handle(W2, LiquidTime.decode(LiquidTime.encode(m)))
	end
	check(LiquidTime.hashState(W2, T_FINAL) == LiquidTime.hashState(W1, T_FINAL), "world fed through the wire equals the direct world")
end

----------------------------------------------------------------------------------------
-- E. the wake-up calendar against checking every leaf
----------------------------------------------------------------------------------------

do
	local cfg: Cfg = { L = 36, C = 2, P = 9, seed = 11, order = 2, drive = "hash", kmax = 7 }
	for _, eps in { 0.5, 2.0 } do
		for _, order in { 2, 1 } do
			local c2: Cfg = { L = cfg.L, C = cfg.C, P = cfg.P, seed = cfg.seed, order = order, drive = cfg.drive, kmax = cfg.kmax }
			local W = LiquidTime.new(makeSpec(c2))
			local msgs = randomMessages(c2, 90, 250, 31)
			local t0 = 40
			-- events due before the start are known; the others arrive 12 ticks ahead of their
			-- effect, and every seventh arrives 5 ticks after it (late)
			local pending: { { arrive: number, m: Msg } } = {}
			for n, m in msgs do
				if m.tick <= t0 then
					LiquidTime.handle(W, m)
				else
					table.insert(pending, { arrive = if n % 7 == 0 then m.tick + 5 else m.tick - 12, m = m })
				end
			end
			LiquidTime.track(W, t0, eps)
			local bsnap = table.clone(W.snap)
			local rand = rng(900 + order)
			local t = t0
			local reported = 0
			local lateSeen = 0
			for _ = 1, 70 do
				t += 1 + math.floor(rand() * 5)
				local keep: { { arrive: number, m: Msg } } = {}
				for _, p in pending do
					if p.arrive <= t then
						if p.m.tick <= W.lastDirty then
							lateSeen += 1
						end
						LiquidTime.handle(W, p.m)
					else
						table.insert(keep, p)
					end
				end
				pending = keep
				local la, ra = LiquidTime.dirty(W, t, eps)
				local lb, rb = LiquidTime.dirtyBrute(W, t, eps, bsnap)
				check(sameList(la, lb), string.format("dirty leaves equal brute force (eps %.1f order %d t %d)", eps, order, t))
				check(sameList(ra, rb), string.format("dirty row ranges equal brute force (eps %.1f order %d t %d)", eps, order, t))
				reported += #la
			end
			check(reported > 0, "the calendar run reported some leaves")
			check(lateSeen > 0, "the calendar run met late events")
		end
	end
end

----------------------------------------------------------------------------------------
-- F. one late input moves a cell by driftBound
----------------------------------------------------------------------------------------

do
	local rand = rng(55)
	for _, order in { 1, 2 } do
		for trial = 1, 24 do
			local cfg: Cfg = { L = 4, C = 1, P = 11 + trial, seed = 60 + trial, order = order, drive = "hash", kmax = 12 }
			local spec = makeSpec(cfg)
			local k = spec.k[1]
			local tick = 3 + math.floor(rand() * 30)
			local lat = math.floor(rand() * 60)
			local v = math.floor((rand() * 100 - 50) * 256) / 256
			for _, kind in { 1, 2 } do
				local X = LiquidTime.new(spec)
				local Y = LiquidTime.new(spec)
				LiquidTime.receive(Y, { tick = tick, seq = 1, sub = 0, kind = kind, leaf = 0, ch = 0, value = v })
				local ox: { number } = { 0 }
				local oy: { number } = { 0 }
				LiquidTime.valuesAt(X, 0, tick + lat, ox)
				LiquidTime.valuesAt(Y, 0, tick + lat, oy)
				local moved = math.abs(oy[1] - ox[1])
				local bound = LiquidTime.driftBound(kind, v, k, lat, order)
				check(math.abs(moved - bound) <= 1e-9 * (1 + math.abs(v)), string.format("driftBound order %d kind %d k %d lat %d: moved %.12g bound %.12g", order, kind, k, lat, moved, bound))
			end
		end
	end
end

----------------------------------------------------------------------------------------
-- G. the state checksum sees the second state, reset, byte
----------------------------------------------------------------------------------------

-- With k = 0 the first state forgets a kick one tick later (a1 = 0) while the second keeps it
-- (a2 = 1/2): two worlds that differ only in x2 must still have different checksums.
do
	local cfg: Cfg = { L = 4, C = 1, P = 50, seed = 3, order = 2, drive = "hash", kmax = 0 }
	local Wn = LiquidTime.new(makeSpec(cfg))
	local Wk = LiquidTime.new(makeSpec(cfg))
	LiquidTime.receive(Wk, { tick = 10, seq = 1, sub = 0, kind = 1, leaf = 0, ch = 0, value = 8 })
	local a: { number } = table.create(3, 0)
	local b: { number } = table.create(3, 0)
	LiquidTime.valuesAt(Wn, 0, 20, a, true)
	LiquidTime.valuesAt(Wk, 0, 20, b, true)
	check(a[2] == b[2], "after a kick, the first state of a k = 0 cell is back on its target")
	check(a[3] ~= b[3], "the second state still remembers the kick")
	check(LiquidTime.hashState(Wn, 20) ~= LiquidTime.hashState(Wk, 20), "the checksum covers the second state")
end

do
	local cfg = CONFIGS[2]
	local W = build(cfg, randomMessages(cfg, 50, 200, 8))
	local h = LiquidTime.hashState(W, T_FINAL)
	LiquidTime.reset(W)
	check(LiquidTime.hashState(W, T_FINAL) == h, "reset forgets cursors and keeps events")
	check(LiquidTime.byte(-5) == 0 and LiquidTime.byte(0.49) == 0 and LiquidTime.byte(0.5) == 1 and LiquidTime.byte(254.5) == 255 and LiquidTime.byte(1e9) == 255, "byte rounds and clamps")
end

----------------------------------------------------------------------------------------
-- golden digest
----------------------------------------------------------------------------------------

local digest = 0x811C9DC5
for _, h in goldenParts do
	digest = MyMath.hash32(bit32.bxor(digest, h))
end
if PRINT_GOLDEN then
	print("timeState", digest)
end
check(digest == GOLDEN.state, "golden digest of the states: " .. digest)

print("liquid_time: " .. checks .. " checks passed")
