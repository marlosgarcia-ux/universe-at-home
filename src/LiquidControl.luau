--!native
--!optimize 2
-- universe-at-home :: LiquidControl (ALLAN X5: extrapolation in budget)
--
-- A six-neuron dyadic liquid controller that predicts the next frame's render load and memory
-- and sets the renderer's knobs (epsilon, level, active neurons: one "rung" of a quality
-- ladder; and residency) one frame ahead, before a stutter happens rather than after it.
-- docs/LIQUID.md "Applications results" holds the proofs (no oscillation under constant load,
-- bounded reversals under a wrong cost model, bounded settling after a step) and measurements.
--
-- THE ARITHMETIC (deterministic ops only: + - * / comparisons; gains are powers of two).
--
-- Tracker (one per signal: render load and exogenous memory). Neurons f (gain 2^-k), s (gain
-- 2^-(k+1)) and j (gain 2^-kj). With x_t the sample and P_t the prediction made for it:
--   first sample:  f = s = x, j = 0                           (at rest)
--   error e = x - P_t; surprise when |e| > max(kappa j, delta |P_t|, floor):
--     the previous frame was a surprise of the same sign (a ramp), with D = x - x_{t-1}:
--        f = x - D (2^k - 1),  s = x - D (2^(k+1) - 1)        (exact ramp steady state)
--     otherwise (a step):  f = s = x                          (instant re-anchoring)
--     j is left unchanged (a regime change is not jitter)
--   no surprise:  f = f + (x - f) 2^-k;  s = s + (x - s) 2^-(k+1);  j = j + (|e| - j) 2^-kj
--   prediction for the next frame:  P = max(0, 2 f - s)
-- For a linear ramp x_t = a + b t the steady state is f = x - b (2^k - 1), s = x - b (2^(k+1) - 1),
-- so 2 f - s = x + b: the extrapolation is exact, which is why the exponents are adjacent.
--
-- Signals. Render load L = ms / cost(rung) (time per unit of the ladder's nominal cost);
-- exogenous memory E = mb - resident * unitMb. The controller's own knobs are divided out, so
-- under a constant external load the tracked signals stay constant whatever it decides.
--
-- Decisions for the next frame, with Ps = P + margin * j (safe prediction):
--   rung q: if Ps cost(q) > hi budget: drop at once to the highest rung r < q with
--     Ps cost(r) <= hi budget (or 0), and set ban[q] = min(Ps, backoff * ban[q]).
--   else if dwell >= dwellFrames, q < top, Ps cost(q + 1) <= lo budget and
--     Ps <= backoff * ban[q + 1]: raise one rung.
--   residency R likewise with Ps + R unitMb against hiMem / loMem of memCapMb, one unit up
--   at a time, as many down as needed, with its own bans.
-- ban[] starts at +infinity; lo < hi makes the hysteresis; backoff < 1 makes a rung that
-- failed again at no lower load harder to re-enter each time.

local LiquidControl = {}

export type Rung = { epsilon: number, level: number, neurons: number, cost: number }

export type Config = {
	ladder: { Rung }?, -- cheapest first, cost strictly increasing
	start: number?, -- starting rung, 0-based (default: the top)
	budgetMs: number?, -- render budget per frame (default 4)
	memCapMb: number?, -- memory cap for the resident set (default 64)
	unitMb: number?, -- memory of one resident unit (default 4, a 1024 x 1024 RGBA8 image)
	minResident: number?, -- default 1
	maxResident: number?, -- default 8
	startResident: number?, -- default minResident
	hi: number?, -- drop above hi * budget (default 0.9)
	lo: number?, -- raise below lo * budget (default 0.6)
	hiMem: number?, -- default 0.9
	loMem: number?, -- default 0.7
	dwell: number?, -- frames between raises (default 8)
	k: number?, -- fast neuron exponent; the slow one is k + 1 (default 1)
	kJitter: number?, -- jitter neuron exponent (default 3)
	kappa: number?, -- surprise threshold in jitter units (default 4)
	delta: number?, -- surprise threshold relative to the prediction (default 1/8)
	floor: number?, -- absolute surprise floor (default 1e-6)
	margin: number?, -- jitter units added to predictions (default 2)
	backoff: number?, -- ban backoff factor rho in (0, 1) (default 0.75)
	predictive: boolean?, -- false gives the reactive baseline (P = the last sample)
}

export type Tracker = {
	f: number,
	s: number,
	j: number,
	last: number,
	pred: number,
	sign: number,
	n: number,
	surprises: number,
}

export type Knobs = {
	rung: number, -- 0-based rung index
	epsilon: number,
	level: number,
	neurons: number,
	resident: number,
	predictedMs: number, -- predicted render time of the next frame at the chosen rung
	predictedMb: number, -- predicted memory of the next frame at the chosen residency
	changed: boolean, -- rung or residency differs from the previous frame
}

export type Controller = {
	ladder: { Rung },
	budget: number,
	cap: number,
	unit: number,
	minR: number,
	maxR: number,
	hi: number,
	lo: number,
	hiM: number,
	loM: number,
	dwellFrames: number,
	k: number,
	g1: number,
	g2: number,
	gj: number,
	r1: number, -- 2^k - 1
	r2: number, -- 2^(k + 1) - 1
	kappa: number,
	delta: number,
	floor: number,
	margin: number,
	backoff: number,
	predictive: boolean,
	rung: number,
	resident: number,
	dwell: number,
	dwellMem: number,
	ban: { number },
	banMem: { number },
	load: Tracker,
	mem: Tracker,
	frames: number,
	changes: number,
	reversals: number,
	lastDir: number, -- +1 raised, -1 dropped, 0 none yet (rung)
}

-- Default ladder for the ALLAN renderer, cheapest first. Costs follow the cost model T6
-- (docs/LIQUID.md): per frame work ~ rows x events per row x neurons, with level l rendering
-- (1024 >> l) rows of (1024 >> l) pixels and a looser epsilon removing events. They are
-- nominal; pass a measured ladder to replace them.
LiquidControl.DEFAULT_LADDER = {
	{ epsilon = 4, level = 2, neurons = 4, cost = 1 / 32 },
	{ epsilon = 2, level = 2, neurons = 8, cost = 1 / 12 },
	{ epsilon = 4, level = 1, neurons = 4, cost = 1 / 8 },
	{ epsilon = 2, level = 1, neurons = 8, cost = 1 / 3 },
	{ epsilon = 1, level = 1, neurons = 8, cost = 0.4 },
	{ epsilon = 2, level = 0, neurons = 8, cost = 1 },
	{ epsilon = 1, level = 0, neurons = 8, cost = 1.25 },
	{ epsilon = 0.5, level = 0, neurons = 16, cost = 3 },
} :: { Rung }

local function pow2neg(k: number): number
	local g = 1
	for _ = 1, k do
		g *= 0.5
	end
	return g
end

local function newTracker(): Tracker
	return { f = 0, s = 0, j = 0, last = 0, pred = 0, sign = 0, n = 0, surprises = 0 }
end

function LiquidControl.new(config: Config?): Controller
	local c: Config = config or {}
	local ladder = c.ladder or LiquidControl.DEFAULT_LADDER
	assert(#ladder >= 1, "ladder needs at least one rung")
	for i = 2, #ladder do
		assert(ladder[i].cost > ladder[i - 1].cost, "ladder costs must increase")
	end
	local k = c.k or 1
	local hi, lo = c.hi or 0.9, c.lo or 0.6
	local hiM, loM = c.hiMem or 0.9, c.loMem or 0.7
	assert(lo < hi and loM < hiM, "hysteresis needs lo < hi")
	local backoff = c.backoff or 0.75
	assert(backoff > 0 and backoff < 1, "backoff in (0, 1)")
	local minR = c.minResident or 1
	local maxR = c.maxResident or 8
	local ban = table.create(#ladder, math.huge)
	local banMem = table.create(maxR + 1, math.huge)
	local p2k = 1
	for _ = 1, k do
		p2k *= 2
	end
	return {
		ladder = ladder,
		budget = c.budgetMs or 4,
		cap = c.memCapMb or 64,
		unit = c.unitMb or 4,
		minR = minR,
		maxR = maxR,
		hi = hi,
		lo = lo,
		hiM = hiM,
		loM = loM,
		dwellFrames = c.dwell or 8,
		k = k,
		g1 = pow2neg(k),
		g2 = pow2neg(k + 1),
		gj = pow2neg(c.kJitter or 3),
		r1 = p2k - 1,
		r2 = 2 * p2k - 1,
		kappa = c.kappa or 4,
		delta = c.delta or 0.125,
		floor = c.floor or 1e-6,
		margin = c.margin or 2,
		backoff = backoff,
		predictive = c.predictive ~= false,
		rung = c.start or (#ladder - 1),
		resident = c.startResident or minR,
		dwell = 0,
		dwellMem = 0,
		ban = ban,
		banMem = banMem,
		load = newTracker(),
		mem = newTracker(),
		frames = 0,
		changes = 0,
		reversals = 0,
		lastDir = 0,
	}
end

-- Feeds one sample into a tracker (header rule "Tracker") and returns the prediction for the
-- next frame. The reactive baseline predicts the last sample and keeps j as the mean
-- absolute frame-to-frame change.
local function observe(c: Controller, T: Tracker, x: number): number
	if T.n == 0 then
		T.f, T.s, T.j, T.last, T.sign = x, x, 0, x, 0
	elseif not c.predictive then
		local e = x - T.pred
		T.j = T.j + ((if e < 0 then -e else e) - T.j) * c.gj
		T.f, T.s = x, x
	else
		local e = x - T.pred
		local ae = if e < 0 then -e else e
		local thr = c.kappa * T.j
		local rel = c.delta * (if T.pred < 0 then -T.pred else T.pred)
		if rel > thr then
			thr = rel
		end
		if c.floor > thr then
			thr = c.floor
		end
		if ae > thr then
			local sgn = if e > 0 then 1 else -1
			if T.sign == sgn then
				local D = x - T.last
				T.f = x - D * c.r1
				T.s = x - D * c.r2
			else
				T.f = x
				T.s = x
			end
			T.sign = sgn
			T.surprises += 1
		else
			T.f = T.f + (x - T.f) * c.g1
			T.s = T.s + (x - T.s) * c.g2
			T.j = T.j + (ae - T.j) * c.gj
			T.sign = 0
		end
	end
	T.last = x
	T.n += 1
	local P = if c.predictive then 2 * T.f - T.s else x
	if P < 0 then
		P = 0
	end
	T.pred = P
	return P
end
LiquidControl.observe = observe

-- One frame: ms = render time of the frame just finished (at the rung in force), mb = memory
-- in use (including the resident set). Returns the knobs for the next frame.
function LiquidControl.step(c: Controller, ms: number, mb: number?): Knobs
	local ladder = c.ladder
	local q = c.rung
	local P = observe(c, c.load, ms / ladder[q + 1].cost)
	local Ps = P + c.margin * c.load.j
	c.frames += 1
	c.dwell += 1
	c.dwellMem += 1
	local B = c.budget
	local changed = false
	if Ps * ladder[q + 1].cost > c.hi * B then
		local r = q
		while r > 0 and Ps * ladder[r + 1].cost > c.hi * B do
			r -= 1
		end
		local b = c.backoff * c.ban[q + 1]
		c.ban[q + 1] = if Ps < b then Ps else b
		if r ~= q then
			if c.lastDir == 1 then
				c.reversals += 1
			end
			c.lastDir = -1
			c.rung = r
			c.dwell = 0
			changed = true
		end
	elseif
		q < #ladder - 1
		and c.dwell >= c.dwellFrames
		and Ps * ladder[q + 2].cost <= c.lo * B
		and Ps <= c.backoff * c.ban[q + 2]
	then
		if c.lastDir == -1 then
			c.reversals += 1
		end
		c.lastDir = 1
		c.rung = q + 1
		c.dwell = 0
		changed = true
	end
	-- residency
	local R = c.resident
	local PE = 0
	if mb then
		PE = observe(c, c.mem, mb - R * c.unit)
		local PEs = PE + c.margin * c.mem.j
		local u = c.unit
		if PEs + R * u > c.hiM * c.cap and R > c.minR then
			local R2 = math.floor((c.hiM * c.cap - PEs) / u)
			if R2 < c.minR then
				R2 = c.minR
			end
			if R2 < R then
				local b = c.backoff * c.banMem[R + 1]
				c.banMem[R + 1] = if PEs < b then PEs else b
				c.resident = R2
				c.dwellMem = 0
				changed = true
			end
		elseif
			R < c.maxR
			and c.dwellMem >= c.dwellFrames
			and PEs + (R + 1) * u <= c.loM * c.cap
			and PEs <= c.backoff * c.banMem[R + 2]
		then
			c.resident = R + 1
			c.dwellMem = 0
			changed = true
		end
	end
	if changed then
		c.changes += 1
	end
	local rung = ladder[c.rung + 1]
	return {
		rung = c.rung,
		epsilon = rung.epsilon,
		level = rung.level,
		neurons = rung.neurons,
		resident = c.resident,
		predictedMs = P * rung.cost,
		predictedMb = PE + c.resident * c.unit,
		changed = changed,
	}
end

-- Settling bound of the docs (theorem C3) for a load step that the tracker does not treat
-- as a surprise: frames until |P - L1| <= tol * L1 given |L1 - L0|, from |P_n - L1| <= 3 |L1 - L0| a^n
-- with a = 1 - 2^-(k+1) (each neuron's error shrinks by at least that factor per frame).
function LiquidControl.convergenceFrames(c: Controller, L0: number, L1: number, tol: number): number
	local a = 1 - c.g2
	local err = 3 * math.abs(L1 - L0)
	local n = 0
	while err > tol * L1 and n < 100000 do
		err *= a
		n += 1
	end
	return n
end

return LiquidControl
