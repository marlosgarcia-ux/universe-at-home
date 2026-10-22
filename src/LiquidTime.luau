--!native
--!optimize 2
-- universe-at-home :: LiquidTime (ALLAN X1: extrapolation in time, texture dead reckoning)
--
-- Animated textures (water, fire, caustics) as per-leaf liquid cells that evolve the leaves'
-- feature bytes in time. A cell's state has a closed form at any future tick, so a client
-- renders ahead and keeps the texture moving between server updates (dead reckoning). The
-- server sends inputs and time stamps, never pixels; a late input is applied by rolling the
-- affected leaves back to a checkpoint and replaying, after which client and server hold the
-- same bits. docs/LIQUID.md "Applications results" holds the proofs and measurements.
--
-- THE MODEL (deterministic ops only: + - * / comparisons, floor, integer % and //, hashes).
--
-- Ticks are integers t >= 0. Leaf l (0-based) has C channels; per (l, c): base, amp, and a
-- persistent offset off (0 at t = 0). Gains: g1 = 2^-k_l, g2 = 2^-(k_l + 1), a = 1 - g.
-- Target during tick t (epoch E = t // P):
--   b = base + off + amp * drive(l, c, E)
--   drive "hash": hash2(l * C + c, E, seed) / 2^32 * 2 - 1
--   drive "flow": valueNoise2(cx / scale + E vx, cy / scale + E vy, seed + 101 c) * 2 - 1
-- One tick from t to t + 1, after applying the events stamped t (in (tick, seq, sub) order):
--   x2 = x2 + (x1 - x2) g2;  x1 = x1 + (b - x1) g1          (order 2; order 1 keeps x1 only)
-- Output feature: x2 (order 2) or x1 (order 1); byte = clamp(floor(v + 0.5), 0, 255).
-- Initial state: x1 = x2 = b at t = 0 (rest). Events have tick >= 1.
-- Events: kick (x1 = x1 + v; x2 follows smoothly), offset (off = v from that tick on),
-- splash (x, y, r, v): a kick of v (1 - d^2 / r^2) into every leaf whose centre lies at
-- distance d < r, expanded in leaf order (sub = leaf + 1).
--
-- CANONICAL EVALUATION (what makes every device agree bit for bit). A leaf's commit points
-- are the epoch boundaries and its event ticks. Its state is only ever stored at commit
-- points, after that tick's events, and moves between consecutive ones in closed form:
--   A1 = POW(a1, n), A2 = POW(a2, n), e1 = x1 - b, e2 = x2 - b
--   x1' = b + e1 A1;   x2' = b + e2 A2 - e1 (A1 - A2)          (exact for g1 = 2 g2)
-- POW(a, n) multiplies a^(2^j) (j = 0, 1, ...; by repeated squaring) over the set bits of
-- n in increasing j, and flushes any factor or product below 2^-200 to 0 (no subnormals).
-- A query at tick t jumps from the last commit point <= t without storing anything, so the
-- answer depends only on the events and t, never on when or how often a device asked.
--
-- MESSAGES (little-endian; values are fixed point, value = i32 / 256):
--   kick / offset:  u8 kind (1 / 2), u32 tick, u32 seq, u32 leaf, u8 channel, i32 value
--   splash:         u8 3, u32 tick, u32 seq, u16 x, u16 y, u16 r, u8 channel, i32 value
--   horizon:        u8 4, u32 tick   (no later message carries a tick below it)

local MyMath = require("./MyMath")

local LiquidTime = {}

local hash2 = MyMath.hash2
local valueNoise2 = MyMath.valueNoise2
local floor = math.floor
local TINY = 2 ^ -200
local JMAX = 32 -- ticks below 2^32

export type Event = {
	tick: number,
	seq: number,
	sub: number,
	kind: number, -- 1 kick, 2 offset
	leaf: number,
	ch: number,
	value: number,
}

export type Message = {
	kind: number, -- 1 kick, 2 offset, 3 splash, 4 horizon
	tick: number,
	seq: number,
	leaf: number,
	ch: number,
	value: number,
	x: number,
	y: number,
	r: number,
}

export type Spec = {
	leaves: number,
	channels: number,
	epoch: number, -- ticks per drive epoch (P)
	seed: number,
	order: number?, -- 1 or 2 (default 2)
	height: number, -- texture rows (for the rows to re-render)
	k: { number }, -- per leaf: first-neuron gain exponent, 0..30
	y0: { number }, -- per leaf: first row of its footprint
	rows: { number }, -- per leaf: footprint height in rows
	cx: { number }, -- per leaf: centre x (texture pixels)
	cy: { number }, -- per leaf: centre y
	base: { number }, -- per (leaf, channel): l * C + c + 1
	amp: { number },
	drive: string?, -- "hash" (default) or "flow"
	flowScale: number?,
	flowVx: number?,
	flowVy: number?,
}

export type World = {
	L: number,
	C: number,
	P: number,
	seed: number,
	order: number,
	H: number,
	k: { number },
	y0: { number },
	rows: { number },
	cx: { number },
	cy: { number },
	base: { number },
	amp: { number },
	flow: boolean,
	scale: number,
	vx: number,
	vy: number,
	-- canonical cursor per leaf (state after the events of tick tc)
	tc: { number },
	x1: { number },
	x2: { number },
	off: { number },
	evNext: { number },
	ev: { { Event } },
	-- rollback checkpoint per leaf (a commit point below the horizon)
	ckT: { number },
	ckX1: { number },
	ckX2: { number },
	ckOff: { number },
	ckEv: { number },
	horizon: number,
	-- dirty tracking (calendar)
	snap: { number },
	wakeAt: { number },
	heap: { number },
	heapN: number,
	lastDirty: number,
	-- statistics
	rollbacks: number,
	replays: number,
	jumps: number,
	evaluations: number,
}

-- POW tables: pw[k + 1] = { a^(2^j) for j = 0..JMAX - 1 } with a = 1 - 2^-k, flushed below TINY.
local PW: { { number } } = {}
for k = 0, 31 do
	local a = 1
	local g = 1
	for _ = 1, k do
		g *= 0.5
	end
	a = 1 - g
	local t = table.create(JMAX, 0)
	local v = a
	for j = 1, JMAX do
		if v < TINY then
			v = 0
		end
		t[j] = v
		v = v * v
	end
	PW[k + 1] = t
end

local function pow(k: number, n: number): number
	local t = PW[k + 1]
	local r = 1
	local j = 1
	while n > 0 do
		if n % 2 == 1 then
			r *= t[j]
			if r < TINY then
				return 0
			end
		end
		n = n // 2
		j += 1
	end
	return r
end
LiquidTime.pow = pow

local function gain(k: number): number
	local g = 1
	for _ = 1, k do
		g *= 0.5
	end
	return g
end

function LiquidTime.new(spec: Spec): World
	local L, C = spec.leaves, spec.channels
	assert(L >= 1 and C >= 1 and spec.epoch >= 1, "need leaves, channels and an epoch")
	local order = spec.order or 2
	assert(order == 1 or order == 2, "order is 1 or 2")
	local W: World = {
		L = L,
		C = C,
		P = spec.epoch,
		seed = spec.seed,
		order = order,
		H = spec.height,
		k = spec.k,
		y0 = spec.y0,
		rows = spec.rows,
		cx = spec.cx,
		cy = spec.cy,
		base = spec.base,
		amp = spec.amp,
		flow = spec.drive == "flow",
		scale = spec.flowScale or 64,
		vx = spec.flowVx or 0.37,
		vy = spec.flowVy or 0.11,
		tc = table.create(L, 0),
		x1 = table.create(L * C, 0),
		x2 = table.create(L * C, 0),
		off = table.create(L * C, 0),
		evNext = table.create(L, 1),
		ev = {} :: { { Event } },
		ckT = table.create(L, 0),
		ckX1 = table.create(L * C, 0),
		ckX2 = table.create(L * C, 0),
		ckOff = table.create(L * C, 0),
		ckEv = table.create(L, 1),
		horizon = 1,
		snap = table.create(L * C, 0),
		wakeAt = table.create(L, -1),
		heap = {},
		heapN = 0,
		lastDirty = -1,
		rollbacks = 0,
		replays = 0,
		jumps = 0,
		evaluations = 0,
	}
	for l = 0, L - 1 do
		W.ev[l + 1] = {}
		assert(W.k[l + 1] >= 0 and W.k[l + 1] <= 30, "gain exponent in 0..30")
	end
	LiquidTime.reset(W)
	return W
end

local function drive(W: World, l: number, c: number, E: number): number
	if W.flow then
		return valueNoise2(W.cx[l + 1] / W.scale + E * W.vx, W.cy[l + 1] / W.scale + E * W.vy, W.seed + 101 * c) * 2 - 1
	end
	return hash2(l * W.C + c, E, W.seed) / 4294967296 * 2 - 1
end

-- Target of (l, c) during epoch E with the offset currently at the cursor.
local function target(W: World, l: number, c: number, E: number): number
	local i = l * W.C + c + 1
	return W.base[i] + W.off[i] + W.amp[i] * drive(W, l, c, E)
end
LiquidTime.target = target

-- Puts every leaf at rest at t = 0 (keeps the received events, forgets the cursors).
function LiquidTime.reset(W: World)
	local C = W.C
	for l = 0, W.L - 1 do
		W.tc[l + 1] = 0
		W.evNext[l + 1] = 1
		W.ckT[l + 1] = 0
		W.ckEv[l + 1] = 1
		for c = 0, C - 1 do
			local i = l * C + c + 1
			W.off[i] = 0
			local b = target(W, l, c, 0)
			W.x1[i], W.x2[i] = b, b
			W.ckX1[i], W.ckX2[i], W.ckOff[i] = b, b, 0
		end
	end
end

local function applyEvent(W: World, e: Event)
	local i = e.leaf * W.C + e.ch + 1
	if e.kind == 1 then
		W.x1[i] += e.value
		if W.order == 1 then
			W.x2[i] = W.x1[i]
		end
	else
		W.off[i] = e.value
	end
end

-- Moves leaf l's cursor through every commit point <= T (canonical).
local function advance(W: World, l: number, T: number)
	local C, P = W.C, W.P
	local k = W.k[l + 1]
	local evs = W.ev[l + 1]
	local nev = #evs
	local tc = W.tc[l + 1]
	local en = W.evNext[l + 1]
	local x1, x2 = W.x1, W.x2
	while true do
		local E = tc // P
		local nt = (E + 1) * P
		if en <= nev and evs[en].tick < nt then
			nt = evs[en].tick
		end
		if nt > T then
			break
		end
		local n = nt - tc
		local A1 = pow(k, n)
		local A2 = pow(k + 1, n)
		for c = 0, C - 1 do
			local i = l * C + c + 1
			local b = target(W, l, c, E)
			local e1 = x1[i] - b
			x1[i] = b + e1 * A1
			if W.order == 2 then
				local e2 = x2[i] - b
				x2[i] = b + e2 * A2 - e1 * (A1 - A2)
			else
				x2[i] = x1[i]
			end
		end
		W.jumps += 1
		tc = nt
		while en <= nev and evs[en].tick == nt do
			applyEvent(W, evs[en])
			en += 1
		end
		if nt < W.horizon then
			W.ckT[l + 1] = nt
			W.ckEv[l + 1] = en
			for c = 0, C - 1 do
				local i = l * C + c + 1
				W.ckX1[i], W.ckX2[i], W.ckOff[i] = x1[i], x2[i], W.off[i]
			end
		end
	end
	W.tc[l + 1] = tc
	W.evNext[l + 1] = en
end
LiquidTime.advance = advance

-- Canonical values of leaf l at tick T (advances the cursor; the result does not depend on
-- earlier queries). Writes the output feature of each channel to out[c + 1] and returns out.
-- With `states`, also writes x1 and x2 (out[C + c + 1], out[2C + c + 1]).
function LiquidTime.valuesAt(W: World, l: number, T: number, out: { number }, states: boolean?): { number }
	advance(W, l, T)
	W.evaluations += 1
	local C = W.C
	local tc = W.tc[l + 1]
	local n = T - tc
	local k = W.k[l + 1]
	local A1 = pow(k, n)
	local A2 = pow(k + 1, n)
	local E = tc // W.P
	for c = 0, C - 1 do
		local i = l * C + c + 1
		local b = target(W, l, c, E)
		local e1 = W.x1[i] - b
		local v1 = b + e1 * A1
		local v2 = v1
		if W.order == 2 then
			v2 = b + (W.x2[i] - b) * A2 - e1 * (A1 - A2)
		end
		out[c + 1] = v2
		if states then
			out[C + c + 1] = v1
			out[2 * C + c + 1] = v2
		end
	end
	return out
end

function LiquidTime.byte(v: number): number
	local q = floor(v + 0.5)
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

----------------------------------------------------------------------------------------
-- inputs, rollback, horizon
----------------------------------------------------------------------------------------

local function eventBefore(a: Event, b: Event): boolean
	if a.tick ~= b.tick then
		return a.tick < b.tick
	end
	if a.seq ~= b.seq then
		return a.seq < b.seq
	end
	return a.sub < b.sub
end

-- Rolls leaf l back so that an event stamped `tick` will be replayed: to its checkpoint when
-- that lies before the tick, else to t = 0 (a protocol violation: an event below the horizon).
local function rollback(W: World, l: number, tick: number)
	W.rollbacks += 1
	local C = W.C
	if W.ckT[l + 1] < tick then
		W.tc[l + 1] = W.ckT[l + 1]
		W.evNext[l + 1] = W.ckEv[l + 1]
		for c = 0, C - 1 do
			local i = l * C + c + 1
			W.x1[i], W.x2[i], W.off[i] = W.ckX1[i], W.ckX2[i], W.ckOff[i]
		end
	else
		W.replays += 1
		W.tc[l + 1] = 0
		W.evNext[l + 1] = 1
		W.ckT[l + 1] = 0
		W.ckEv[l + 1] = 1
		for c = 0, C - 1 do
			local i = l * C + c + 1
			W.off[i] = 0
			local b = target(W, l, c, 0)
			W.x1[i], W.x2[i] = b, b
			W.ckX1[i], W.ckX2[i], W.ckOff[i] = b, b, 0
		end
	end
end

local heapPush: (W: World, key: number) -> ()

-- Adds one event (idempotent: an event already held is ignored). Late events roll the leaf
-- back; the calendar re-checks the leaf at the next dirty() call.
function LiquidTime.receive(W: World, e: Event)
	assert(e.tick >= 1, "events start at tick 1")
	local l = e.leaf
	local evs = W.ev[l + 1]
	local n = #evs
	local p = n + 1
	while p > 1 and eventBefore(e, evs[p - 1]) do
		p -= 1
	end
	if p > 1 then
		local q = evs[p - 1]
		if q.tick == e.tick and q.seq == e.seq and q.sub == e.sub then
			return -- duplicate
		end
	end
	table.insert(evs, p, e)
	if W.tc[l + 1] >= e.tick then
		rollback(W, l, e.tick)
	elseif p < W.evNext[l + 1] then
		W.evNext[l + 1] += 1 -- cannot happen for tick > tc; kept for safety
	end
	if W.lastDirty >= 0 then
		local wake = if e.tick > W.lastDirty + 1 then e.tick else W.lastDirty + 1
		if W.wakeAt[l + 1] < 0 or wake < W.wakeAt[l + 1] then
			W.wakeAt[l + 1] = wake
			heapPush(W, wake * 1048576 + l)
		end
	end
end

-- Expands a splash into kicks, in leaf order.
function LiquidTime.splash(W: World, tick: number, seq: number, x: number, y: number, r: number, ch: number, v: number): number
	local n = 0
	local r2 = r * r
	for l = 0, W.L - 1 do
		local dx, dy = W.cx[l + 1] - x, W.cy[l + 1] - y
		local d2 = dx * dx + dy * dy
		if d2 < r2 then
			n += 1
			LiquidTime.receive(W, { tick = tick, seq = seq, sub = l + 1, kind = 1, leaf = l, ch = ch, value = v * (1 - d2 / r2) })
		end
	end
	return n
end

function LiquidTime.setHorizon(W: World, H: number)
	if H > W.horizon then
		W.horizon = H
	end
end

----------------------------------------------------------------------------------------
-- messages (inputs and time stamps; never pixels)
----------------------------------------------------------------------------------------

function LiquidTime.encode(m: Message): buffer
	if m.kind == 4 then
		local b = buffer.create(5)
		buffer.writeu8(b, 0, 4)
		buffer.writeu32(b, 1, m.tick)
		return b
	end
	local q = floor(m.value * 256 + 0.5)
	assert(q >= -2147483648 and q <= 2147483647, "value out of range")
	if m.kind == 3 then
		local b = buffer.create(20)
		buffer.writeu8(b, 0, 3)
		buffer.writeu32(b, 1, m.tick)
		buffer.writeu32(b, 5, m.seq)
		buffer.writeu16(b, 9, m.x)
		buffer.writeu16(b, 11, m.y)
		buffer.writeu16(b, 13, m.r)
		buffer.writeu8(b, 15, m.ch)
		buffer.writei32(b, 16, q)
		return b
	end
	local b = buffer.create(18)
	buffer.writeu8(b, 0, m.kind)
	buffer.writeu32(b, 1, m.tick)
	buffer.writeu32(b, 5, m.seq)
	buffer.writeu32(b, 9, m.leaf)
	buffer.writeu8(b, 13, m.ch)
	buffer.writei32(b, 14, q)
	return b
end

function LiquidTime.decode(b: buffer): Message
	local kind = buffer.readu8(b, 0)
	local m: Message = { kind = kind, tick = buffer.readu32(b, 1), seq = 0, leaf = 0, ch = 0, value = 0, x = 0, y = 0, r = 0 }
	if kind == 3 then
		m.seq = buffer.readu32(b, 5)
		m.x = buffer.readu16(b, 9)
		m.y = buffer.readu16(b, 11)
		m.r = buffer.readu16(b, 13)
		m.ch = buffer.readu8(b, 15)
		m.value = buffer.readi32(b, 16) / 256
	elseif kind == 1 or kind == 2 then
		m.seq = buffer.readu32(b, 5)
		m.leaf = buffer.readu32(b, 9)
		m.ch = buffer.readu8(b, 13)
		m.value = buffer.readi32(b, 14) / 256
	end
	return m
end

-- Applies one decoded message to a world (server and clients run the same code).
function LiquidTime.handle(W: World, m: Message)
	if m.kind == 4 then
		LiquidTime.setHorizon(W, m.tick)
	elseif m.kind == 3 then
		LiquidTime.splash(W, m.tick, m.seq, m.x, m.y, m.r, m.ch, m.value)
	else
		LiquidTime.receive(W, { tick = m.tick, seq = m.seq, sub = 0, kind = m.kind, leaf = m.leaf, ch = m.ch, value = m.value })
	end
end

----------------------------------------------------------------------------------------
-- reference: tick-by-tick evolution of every cell (the dynamics written literally)
----------------------------------------------------------------------------------------

-- Returns per (l, c) the output feature at tick T, stepping every tick from 0 with the
-- events of W (which this does not modify).
function LiquidTime.stepReference(W: World, T: number): { number }
	local L, C, P = W.L, W.C, W.P
	local x1 = table.create(L * C, 0)
	local x2 = table.create(L * C, 0)
	local off = table.create(L * C, 0)
	local idx = table.create(L, 1)
	for l = 0, L - 1 do
		for c = 0, C - 1 do
			local i = l * C + c + 1
			local b = W.base[i] + W.amp[i] * drive(W, l, c, 0)
			x1[i], x2[i] = b, b
		end
	end
	for t = 0, T - 1 do
		local E = t // P
		for l = 0, L - 1 do
			local evs = W.ev[l + 1]
			local j = idx[l + 1]
			while j <= #evs and evs[j].tick == t do
				local e = evs[j]
				local i = l * C + e.ch + 1
				if e.kind == 1 then
					x1[i] += e.value
				else
					off[i] = e.value
				end
				j += 1
			end
			idx[l + 1] = j
			local g1, g2 = gain(W.k[l + 1]), gain(W.k[l + 1] + 1)
			for c = 0, C - 1 do
				local i = l * C + c + 1
				local b = W.base[i] + off[i] + W.amp[i] * drive(W, l, c, E)
				if W.order == 2 then
					x2[i] = x2[i] + (x1[i] - x2[i]) * g2
				end
				x1[i] = x1[i] + (b - x1[i]) * g1
			end
		end
	end
	-- events stamped T itself
	for l = 0, L - 1 do
		local evs = W.ev[l + 1]
		local j = idx[l + 1]
		while j <= #evs and evs[j].tick == T do
			local e = evs[j]
			local i = l * C + e.ch + 1
			if e.kind == 1 then
				x1[i] += e.value
			else
				off[i] = e.value
			end
			j += 1
		end
	end
	local out = table.create(L * C, 0)
	for i = 1, L * C do
		out[i] = if W.order == 2 then x2[i] else x1[i]
	end
	return out
end

----------------------------------------------------------------------------------------
-- dirty leaves and rows: a wake-up calendar against brute force
----------------------------------------------------------------------------------------

-- min-heap of keys tick * 2^20 + leaf (exact integers below 2^52)
heapPush = function(W: World, key: number)
	local h = W.heap
	local n = W.heapN + 1
	W.heapN = n
	h[n] = key
	while n > 1 do
		local p = n // 2
		if h[p] <= key then
			break
		end
		h[n] = h[p]
		n = p
	end
	h[n] = key
end

local function heapPop(W: World): number
	local h = W.heap
	local top = h[1]
	local n = W.heapN
	local last = h[n]
	h[n] = nil
	n -= 1
	W.heapN = n
	if n > 0 then
		local i = 1
		while true do
			local c = i * 2
			if c > n then
				break
			end
			if c < n and h[c + 1] < h[c] then
				c += 1
			end
			if h[c] >= last then
				break
			end
			h[i] = h[c]
			i = c
		end
		h[i] = last
	end
	return top
end

local SAFE = 1 - 2 ^ -30 -- shrinks the tolerance used for wake times (rounding slack)

-- Next tick at which leaf l must be looked at again, given its values `v` at tick t (the
-- cursor is at the last commit point <= t). Uses two proved bounds per channel (docs):
--   settled: |x2(t + n) - x2(t)| <= |e1| + |e2| for all n until the next commit point;
--   speed:   |x2(t + n) - x2(t)| <= n g2 (2 |e1| + |e2|)   (order 1: n g1 |e1|).
local function nextWake(W: World, l: number, t: number, eps: number, v: { number }): number
	local C, P = W.C, W.P
	local tc = W.tc[l + 1]
	local E = tc // P
	local nc = (E + 1) * P
	local evs = W.ev[l + 1]
	local en = W.evNext[l + 1]
	if en <= #evs and evs[en].tick < nc then
		nc = evs[en].tick
	end
	local k = W.k[l + 1]
	local n = t - tc
	local A1 = pow(k, n)
	local A2 = pow(k + 1, n)
	local g = if W.order == 2 then gain(k + 1) else gain(k)
	local wake = nc
	local tol = eps * SAFE
	for c = 0, C - 1 do
		local i = l * C + c + 1
		local b = target(W, l, c, E)
		local e1 = (W.x1[i] - b) * A1
		local e2 = if W.order == 2 then (W.x2[i] - b) * A2 - (W.x1[i] - b) * (A1 - A2) else e1
		local a1, a2 = math.abs(e1), math.abs(e2)
		local d0 = math.abs(v[c + 1] - W.snap[i])
		local reach = if W.order == 2 then a1 + a2 else a1
		if d0 + reach * (1 + 2 ^ -30) > tol then
			local speed = (if W.order == 2 then 2 * a1 + a2 else a1) * g * (1 + 2 ^ -30)
			local m = if speed > 0 then floor((tol - d0) / speed) + 1 else nc - t
			if m < 1 then
				m = 1
			end
			if t + m < wake then
				wake = t + m
			end
		end
	end
	if wake <= t then
		wake = t + 1
	end
	return wake
end

-- Starts dirty tracking at tick t: every leaf's snapshot is its value at t.
function LiquidTime.track(W: World, t: number, eps: number)
	W.heap = {}
	W.heapN = 0
	local v = table.create(W.C, 0)
	for l = 0, W.L - 1 do
		LiquidTime.valuesAt(W, l, t, v)
		for c = 0, W.C - 1 do
			W.snap[l * W.C + c + 1] = v[c + 1]
		end
		local wake = nextWake(W, l, t, eps, v)
		W.wakeAt[l + 1] = wake
		heapPush(W, wake * 1048576 + l)
	end
	W.lastDirty = t
end

local function addRows(marks: buffer, H: number, y0: number, rows: number)
	local a = if y0 < 0 then 0 else y0
	local b = y0 + rows - 1
	if b > H - 1 then
		b = H - 1
	end
	if b >= a then
		buffer.fill(marks, a, 1, b - a + 1)
	end
end

local function rowRanges(marks: buffer, H: number): { number }
	local out = {}
	local y = 0
	while y < H do
		if buffer.readu8(marks, y) == 1 then
			local a = y
			while y < H and buffer.readu8(marks, y) == 1 do
				y += 1
			end
			table.insert(out, a)
			table.insert(out, y - 1)
		else
			y += 1
		end
	end
	return out
end

-- Leaves whose output moved more than eps (any channel) since they were last reported, at
-- tick t >= the previous call, and the merged row ranges {a1, b1, a2, b2, ...} to re-render.
-- Reported leaves take their value at t as the new snapshot. Cost follows the wake-ups.
function LiquidTime.dirty(W: World, t: number, eps: number): ({ number }, { number })
	local leaves = {}
	local marks = buffer.create(W.H)
	local v = table.create(W.C, 0)
	local C = W.C
	local limit = (t + 1) * 1048576
	while W.heapN > 0 and W.heap[1] < limit do
		local key = heapPop(W)
		local l = key % 1048576
		local tw = (key - l) / 1048576
		if W.wakeAt[l + 1] ~= tw then
			continue -- stale entry
		end
		LiquidTime.valuesAt(W, l, t, v)
		local moved = false
		for c = 0, C - 1 do
			if math.abs(v[c + 1] - W.snap[l * C + c + 1]) > eps then
				moved = true
			end
		end
		if moved then
			for c = 0, C - 1 do
				W.snap[l * C + c + 1] = v[c + 1]
			end
			table.insert(leaves, l)
			addRows(marks, W.H, W.y0[l + 1], W.rows[l + 1])
		end
		local wake = nextWake(W, l, t, eps, v)
		W.wakeAt[l + 1] = wake
		heapPush(W, wake * 1048576 + l)
	end
	W.lastDirty = t
	table.sort(leaves)
	return leaves, rowRanges(marks, W.H)
end

-- The same answer by checking every leaf (snapshots kept in `snap`, owned by the caller).
function LiquidTime.dirtyBrute(W: World, t: number, eps: number, snap: { number }): ({ number }, { number })
	local leaves = {}
	local marks = buffer.create(W.H)
	local v = table.create(W.C, 0)
	local C = W.C
	for l = 0, W.L - 1 do
		LiquidTime.valuesAt(W, l, t, v)
		local moved = false
		for c = 0, C - 1 do
			if math.abs(v[c + 1] - snap[l * C + c + 1]) > eps then
				moved = true
			end
		end
		if moved then
			for c = 0, C - 1 do
				snap[l * C + c + 1] = v[c + 1]
			end
			table.insert(leaves, l)
			addRows(marks, W.H, W.y0[l + 1], W.rows[l + 1])
		end
	end
	return leaves, rowRanges(marks, W.H)
end

----------------------------------------------------------------------------------------
-- bounds and checksums
----------------------------------------------------------------------------------------

-- Largest change a single late input can make to the output of an order-2 cell, `lat` ticks
-- after its time stamp (docs: the response of the cell to the input alone, by linearity):
--   kick v:   |v| (a2^lat - a1^lat)          offset change d: |d| (1 + a1^lat - 2 a2^lat)
-- (order 1: kick |v| a1^lat, offset |d| (1 - a1^lat)). Real arithmetic; add rounding slack.
function LiquidTime.driftBound(kind: number, v: number, k: number, lat: number, order: number?): number
	local A1, A2 = pow(k, lat), pow(k + 1, lat)
	local m = math.abs(v)
	if (order or 2) == 1 then
		return if kind == 1 then m * A1 else m * (1 - A1)
	end
	if kind == 1 then
		return m * (A2 - A1)
	end
	return m * (1 + A1 - 2 * A2)
end

-- Checksum of every leaf's state at tick T (f64 bits of x1 and x2): equal checksums mean
-- equal bits.
function LiquidTime.hashState(W: World, T: number): number
	local h = 0x811C9DC5
	local C = W.C
	local v = table.create(3 * C, 0)
	local b = buffer.create(8)
	for l = 0, W.L - 1 do
		LiquidTime.valuesAt(W, l, T, v, true)
		for j = C + 1, 3 * C do
			buffer.writef64(b, 0, v[j])
			h = MyMath.hash32(bit32.bxor(h, buffer.readu32(b, 0)))
			h = MyMath.hash32(bit32.bxor(h, buffer.readu32(b, 4)))
		end
	end
	return h
end

return LiquidTime
