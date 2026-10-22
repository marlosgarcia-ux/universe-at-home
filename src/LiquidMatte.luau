--!native
--!optimize 2
-- universe-at-home :: LiquidMatte (ALLAN application: liquid background removal)
--
-- docs/LIQUID.md section 8 ("Liquid matte") and "Applications results" hold the proofs and
-- measurements. This header is the single source of truth for the arithmetic: the
-- event-driven path and LiquidMatte.refineReference (the per-pixel definition) produce the
-- same bits, and so must any port.
--
-- IMAGES are row-major straight-alpha RGBA8 (the EditableImage layout): a pixel read with
-- readu32 is r + g*256 + b*65536 + a*16777216.
--
-- 1. COLOUR METRIC (integers, exact). For a pixel minus the key, dr, dg, db in [-255, 255]:
--      dy  =  77 dr + 150 dg +  29 db           luma x 256       (77 + 150 + 29 = 256)
--      dcb = -43 dr -  85 dg + 128 db           chroma x 256     (row sums 0: greys have no
--      dcr = 128 dr - 107 dg -  21 db           chroma x 256      chroma)
--      d2  = 4 (dcb^2 + dcr^2) + wy dy^2        integer below 2^39 (wy in 0..64, default 1)
--      Dq  = floor(sqrt(d2) / 64)               u16, 8 units per byte of chroma distance
--    wy = 1 weighs luma half as much as chroma (in distance), so shading of the screen moves
--    Dq less than a change of hue; white, grey and black keys still work through luma.
--    sqrt is IEEE correctly rounded and /64 is exact, so Dq is the same on every device.
--
-- 2. KEY (detectKey). The border is walked as a closed loop (top row left to right, right
--    column down, bottom row right to left, left column up). Its colours go into a 4096-bin
--    histogram (4 bits per channel); the mode bin (lowest index on ties) seeds a mean shift:
--    key = round(mean of loop pixels within Dq <= 192 of the key), four times. Loop pixels
--    within Dq <= 384 are background samples; noiseD and noiseStep are the 99.9 % quantiles
--    of their Dq and of |Dq step| between consecutive samples.
--
-- 3. PARAMETERS (params, all in Dq units, each overridable):
--      t0  = max(16, floor(3 noiseD / 4) + 8)   background ceiling (refinement removes the
--                                               outliers this lets through)
--      tau = max(24, noiseStep + 8, t0)         edge step: a neighbour step >= tau is hard
--      t1  = max(4 t0, t0 + 64)                 ratio floor (mode "ratio"), ramp top ("ramp")
--      radius 2, kMax 1, snap 1/2, clip 3, headroom m = 64 (alpha units), speck 64.
--
-- 4. EXTENDED MATTE e, stored as e + 256 in a u16 (stored values 0..2047). It is not
--    clamped to 0..255: smoothing happens before the one final clamp, so noise averages out
--    instead of being biased by the clamp, and confident plateaus sit beyond the visible
--    range by a headroom m (default 64) so smoothing tails are absorbed by that clamp.
--    Mode "ratio" (default), with W(p) the (2 radius + 1)^2 window clipped to the image:
--      Dq(p) <= t0                          -> -m               (background plateau)
--      no q in W(p) with Dq(q) <= t0        -> 255 + m          (interior plateau)
--      otherwise (edge band), with t = (Dq / F) min(1, (Dq - t0) / t0):
--                                              255 + m if t >= 1, else floor(255 t + 0.5)
--         M = max of Dq over W(p); F = max(t1, mean of the Dq(q), q in W(p), Dq(q) >= M - noiseD)
--    For an anti-aliased pixel C = c Fg + (1 - c) K the metric is a norm, so Dq(C) = c Dq(Fg)
--    up to rounding, and the ratio recovers the coverage c whatever the foreground colour
--    (local unmixing). On clean images noiseD = 0 and F = M exactly; under noise F is the
--    mean of the window's samples within one noise radius of M, so noisy foreground pixels
--    average 255 instead of sitting below it (the maximum of noisy samples is biased high).
--    Speck rule: an edge-band pixel with e <= speck (default 64) whose four neighbours all
--    have Dq <= t0 (or lie outside the image) is set to -m: a lone pixel barely above the
--    background ceiling is noise, and dropping it before smoothing saves its transients.
--    Mode "ramp": e = -m if Dq <= t0, 255 + m if Dq >= t1, else floor(255 (Dq - t0) / (t1 - t0) + 0.5).
--
-- 5. FLOOD (optional). Passable pixels have e < 255. Passable pixels not 4-connected to the
--    border through passable pixels are protected: e := 255 + m, and despill skips them.
--
-- 6. LIQUID REFINEMENT (refine). Gain of a neighbour pair with step s = |Dq(p) - Dq(q)|:
--      g(s) = 1 if s >= tau, else 2^-k, k = ceil(kMax (tau - s) / tau)   (exact powers of 2)
--    One pass over a line with inputs v_x and pair steps s_x between x and the pixel before
--    it in the pass direction:
--      h_0 = v_0;   h_x = v_x if s_x >= tau, else h_{x-1} + (v_x - h_{x-1}) * g(s_x),
--      then if |v_x - h_x| < snap: h_x = v_x               (snap, default 1/2)
--    Horizontal stage: passes left to right (hL) and right to left (hR) on e,
--      H = floor((hL + hR) * 0.5 + 0.5)                     (on stored values, unclamped)
--    Vertical stage: passes top to bottom (hU) and bottom to top (hD) on H,
--      z = floor((hU + hD) * 0.5 + 0.5) - 256,  A = 0 if z <= clip, 255 if z >= 255 - clip,
--      else z. (The step is translation-equivariant, so the offset only fixes the storage.)
--    The event-driven path skips pixels whose state already equals their input (the step is
--    then the identity), several pixels per compare, so its cost follows the transients.
--    Without refinement A is the same clamp applied to e.
--
-- 7. COMPOSE. a = A (times the source alpha, rounded, if the source is not opaque).
--      a = 255: the source pixel; a = 0: transparent, colour from step 8;
--      0 < a < 255: unmixed colour F = clamp(round((255 C - (255 - a) K) / a)), the exact
--      inverse of C = (a F + (255 - a) K) / 255 (despill), or C itself with despill off.
--    Optional spill limiter of strength s in [0, 1] on unprotected visible pixels: with
--    p = (cb kcb + cr kcr) / (kcb^2 + kcr^2) the key-ward share of the pixel's chroma,
--    C' = C - s max(p, 0) (K - Y_K), which keeps luma and removes s of the key hue.
-- 8. BLEED. Every transparent pixel takes the RGB of the nearest visible pixel in its row
--    (ties to the left), alpha 0; rows without a visible pixel copy the nearest such row
--    (ties upward). Bilinear filtering and mips then never pull in the key colour.
--
-- Deterministic ops only (docs/RUNTIME_AUDIT.md 6.5): + - * / sqrt, math.floor on
-- fractions, integer // and %, comparisons, integer buffer ops and f64 buffer storage.

local MyMath = require("./MyMath")
local Pixels = require("./Pixels")

local LiquidMatte = {}

local floor = math.floor
local sqrt = math.sqrt
local fillSpan = Pixels.fillSpan
local hash32 = MyMath.hash32

local SNAP = 0.5 -- default snap tolerance (header rule 6)
local WORD1 = 0x01010101

export type Key = {
	color: number, -- packed RGB with alpha 255
	r: number,
	g: number,
	b: number,
	wy: number,
	noiseD: number, -- Dq units
	noiseStep: number, -- Dq units
	samples: number, -- background samples on the border loop
	share: number, -- samples / loop length
}

export type Options = {
	key: number?, -- packed colour; default: detected from the border
	wy: number?, -- luma weight 0..64 (default 1)
	t0: number?,
	t1: number?,
	tau: number?,
	kMax: number?,
	radius: number?,
	clip: number?,
	headroom: number?, -- plateau headroom m in alpha units (default 64)
	speck: number?, -- isolated band pixels with e <= speck join the background (default 64, -1 off)
	snap: number?, -- snap tolerance of the liquid passes (default 1/2)
	mode: string?, -- "ratio" (default) or "ramp"
	flood: boolean?, -- protect key-coloured regions not connected to the border
	refine: boolean?, -- liquid refinement (default true)
	despill: boolean?, -- unmix partial pixels (default true)
	spill: number?, -- spill limiter strength 0..1 (default 0)
	bleed: boolean?, -- alpha bleeding (default true)
}

export type Params = {
	key: Key,
	t0: number,
	t1: number,
	tau: number,
	kMax: number,
	radius: number,
	clip: number,
	headroom: number,
	speck: number,
	snap: number,
	mode: string,
	flood: boolean,
	refine: boolean,
	despill: boolean,
	spill: number,
	bleed: boolean,
}

export type Field = {
	dq: buffer, -- u16 per pixel
	runA: { number }, -- background runs (Dq <= t0), flat, row by row
	runB: { number },
	rowRun: { number }, -- [y + 1] = first run index of row y; [h + 1] = runs + 1
	opaque: boolean, -- every source alpha is 255
	distinct: number, -- runs of equal pixels in rows (one Dq computed per run)
}

-- Per-row sorted, disjoint closed intervals [a, b] (flat, row by row). For an extended matte
-- they are its literal pixels: the row is constant on each gap between them.
export type Intervals = {
	a: { number },
	b: { number },
	first: { number }, -- [y + 1] = index of row y's first interval; [h + 1] = count + 1
}

export type Info = {
	key: Key,
	params: Params,
	edgeBand: number, -- pixels evaluated by the ratio rule
	protected: number, -- pixels protected by the flood
	transients: number, -- refinement steps that left the state off its input
	partial: number, -- output pixels with 0 < alpha < 255
	distinct: number,
}

----------------------------------------------------------------------------------------
-- 1. metric
----------------------------------------------------------------------------------------

-- d2 of header rule 1 expanded into a quadratic form in (dr, dg, db) with integer
-- coefficients: the same integers in 14 operations instead of 22 (every product is exact,
-- below 2^39). Returns A, B, C, D, E, F with
--   d2 = dr (A dr + D dg + E db) + dg (B dg + F db) + C db^2.
local function quadForm(wy: number): (number, number, number, number, number, number)
	return 72932 + 5929 * wy, 74696 + 22500 * wy, 67300 + 841 * wy, -80328 + 23100 * wy, -65536 + 4466 * wy, -69064 + 8700 * wy
end
LiquidMatte.quadForm = quadForm

-- Dq of a packed colour against a key (integers in, integer out), written exactly as rule 1.
local function dqOf(p: number, kr: number, kg: number, kb: number, wy: number): number
	local dr = p % 256 - kr
	local dg = (p // 256) % 256 - kg
	local db = (p // 65536) % 256 - kb
	local dy = 77 * dr + 150 * dg + 29 * db
	local dcb = 128 * db - 43 * dr - 85 * dg
	local dcr = 128 * dr - 107 * dg - 21 * db
	return floor(sqrt(4 * (dcb * dcb + dcr * dcr) + wy * dy * dy) * 0.015625)
end
LiquidMatte.dqOf = dqOf

----------------------------------------------------------------------------------------
-- 2. key detection
----------------------------------------------------------------------------------------

local function quantile(list: { number }, num: number, den: number): number
	local n = #list
	if n == 0 then
		return 0
	end
	table.sort(list)
	local i = (n * num) // den + 1
	if i > n then
		i = n
	end
	return list[i]
end

local function borderLoop(img: buffer, w: number, h: number): { number }
	local loop = {}
	local function push(x: number, y: number)
		table.insert(loop, buffer.readu32(img, (y * w + x) * 4))
	end
	if h == 1 then
		for x = 0, w - 1 do
			push(x, 0)
		end
		return loop
	end
	if w == 1 then
		for y = 0, h - 1 do
			push(0, y)
		end
		return loop
	end
	for x = 0, w - 1 do
		push(x, 0)
	end
	for y = 1, h - 2 do
		push(w - 1, y)
	end
	for x = w - 1, 0, -1 do
		push(x, h - 1)
	end
	for y = h - 2, 1, -1 do
		push(0, y)
	end
	return loop
end

function LiquidMatte.detectKey(img: buffer, w: number, h: number, wy: number?, given: number?): Key
	local wyv = wy or 1
	assert(wyv >= 0 and wyv <= 64 and wyv == floor(wyv), "wy must be an integer in 0..64")
	local loop = borderLoop(img, w, h)
	local n = #loop
	local kr, kg, kb
	if given then
		kr, kg, kb = given % 256, (given // 256) % 256, (given // 65536) % 256
	else
		local hist = buffer.create(4096 * 4)
		for i = 1, n do
			local p = loop[i]
			local bin = ((p % 256) // 16) * 256 + (((p // 256) % 256) // 16) * 16 + ((p // 65536) % 256) // 16
			buffer.writeu32(hist, bin * 4, buffer.readu32(hist, bin * 4) + 1)
		end
		local best, bestCount = 0, -1
		for bin = 0, 4095 do
			local c = buffer.readu32(hist, bin * 4)
			if c > bestCount then
				best, bestCount = bin, c
			end
		end
		local sr, sg, sb = 0, 0, 0
		for i = 1, n do
			local p = loop[i]
			local bin = ((p % 256) // 16) * 256 + (((p // 256) % 256) // 16) * 16 + ((p // 65536) % 256) // 16
			if bin == best then
				sr += p % 256
				sg += (p // 256) % 256
				sb += (p // 65536) % 256
			end
		end
		kr = floor(sr / bestCount + 0.5)
		kg = floor(sg / bestCount + 0.5)
		kb = floor(sb / bestCount + 0.5)
		for _ = 1, 4 do
			local cr, cg, cb, c = 0, 0, 0, 0
			for i = 1, n do
				local p = loop[i]
				if dqOf(p, kr, kg, kb, wyv) <= 192 then
					cr += p % 256
					cg += (p // 256) % 256
					cb += (p // 65536) % 256
					c += 1
				end
			end
			if c == 0 then
				break
			end
			local nr, ng, nb = floor(cr / c + 0.5), floor(cg / c + 0.5), floor(cb / c + 0.5)
			if nr == kr and ng == kg and nb == kb then
				break
			end
			kr, kg, kb = nr, ng, nb
		end
	end
	local ds: { number } = {}
	local steps: { number } = {}
	local samples = 0
	local prevD = -1
	local firstD = -1
	for i = 1, n do
		local d = dqOf(loop[i], kr, kg, kb, wyv)
		if d <= 384 then
			samples += 1
			table.insert(ds, d)
			if prevD >= 0 then
				table.insert(steps, math.abs(d - prevD))
			end
			if i == 1 then
				firstD = d
			end
			prevD = d
		else
			prevD = -1
		end
	end
	if prevD >= 0 and firstD >= 0 and n > 2 then
		table.insert(steps, math.abs(firstD - prevD)) -- the loop closes
	end
	return {
		color = kr + kg * 256 + kb * 65536 + 255 * 16777216,
		r = kr,
		g = kg,
		b = kb,
		wy = wyv,
		noiseD = quantile(ds, 999, 1000),
		noiseStep = quantile(steps, 999, 1000),
		samples = samples,
		share = if n > 0 then samples / n else 0,
	}
end

----------------------------------------------------------------------------------------
-- 3. parameters
----------------------------------------------------------------------------------------

function LiquidMatte.params(key: Key, opts: Options?): Params
	local o: Options = opts or {}
	local t0 = o.t0 or math.max(16, (3 * key.noiseD) // 4 + 8)
	local tau = o.tau or math.max(24, key.noiseStep + 8, t0)
	local t1 = o.t1 or math.max(4 * t0, t0 + 64)
	local mode = o.mode or "ratio"
	assert(mode == "ratio" or mode == "ramp", "mode must be ratio or ramp")
	assert(t1 > t0 and tau >= 1, "need t1 > t0 and tau >= 1")
	local kMax = o.kMax or 1
	assert(kMax >= 0 and kMax <= 30, "kMax in 0..30")
	return {
		key = key,
		t0 = t0,
		t1 = t1,
		tau = tau,
		kMax = kMax,
		radius = o.radius or 2,
		clip = o.clip or 3,
		headroom = o.headroom or 64,
		speck = o.speck or 64,
		snap = o.snap or SNAP,
		mode = mode,
		flood = o.flood == true,
		refine = o.refine ~= false,
		despill = o.despill ~= false,
		spill = o.spill or 0,
		bleed = o.bleed ~= false,
	}
end

----------------------------------------------------------------------------------------
-- 4. distance field (fused with the background runs)
----------------------------------------------------------------------------------------

function LiquidMatte.distanceField(img: buffer, w: number, h: number, key: Key, t0: number, dqBuf: buffer?): Field
	local dq = dqBuf or buffer.create(w * h * 2)
	local kr, kg, kb = key.r, key.g, key.b
	local QA, QB, QC, QD, QE, QF = quadForm(key.wy)
	local readu32 = buffer.readu32
	local writeu16 = buffer.writeu16
	local runA: { number } = {}
	local runB: { number } = {}
	local rowRun: { number } = table.create(h + 1, 0)
	local nRuns = 0
	local opaque = true
	local distinct = 0
	for y = 0, h - 1 do
		rowRun[y + 1] = nRuns + 1
		local inRun = false
		local rowPx = y * w * 4
		local rowDq = y * w * 2
		local x = 0
		local p = readu32(img, rowPx)
		while true do
			-- p starts a new run (runs are maximal, so its colour differs from the last)
			distinct += 1
			if p < 4278190080 then
				opaque = false
			end
			local dr = p % 256 - kr
			local dg = (p // 256) % 256 - kg
			local db = (p // 65536) % 256 - kb
			local d = floor(sqrt(dr * (QA * dr + QD * dg + QE * db) + dg * (QB * dg + QF * db) + QC * db * db) * 0.015625)
			writeu16(dq, rowDq + x * 2, d)
			if d <= t0 then
				if not inRun then
					nRuns += 1
					runA[nRuns] = x
					inRun = true
				end
			elseif inRun then
				runB[nRuns] = x - 1
				inRun = false
			end
			x += 1
			if x >= w then
				break
			end
			local q = readu32(img, rowPx + x * 4)
			if q == p then
				-- a run of equal pixels: find its end and fill the distances in one go
				local x2 = x + 1
				while x2 < w do
					q = readu32(img, rowPx + x2 * 4)
					if q ~= p then
						break
					end
					x2 += 1
				end
				local len = x2 - x
				if len >= 2 then
					fillSpan(dq, rowDq + x * 2, len // 2, d * 65537)
				end
				if len % 2 == 1 then
					writeu16(dq, rowDq + (x2 - 1) * 2, d)
				end
				x = x2
				if x >= w then
					break
				end
			end
			p = q
		end
		if inRun then
			runB[nRuns] = w - 1
		end
	end
	rowRun[h + 1] = nRuns + 1
	return { dq = dq, runA = runA, runB = runB, rowRun = rowRun, opaque = opaque, distinct = distinct }
end

----------------------------------------------------------------------------------------
-- 5. raw (extended) matte
----------------------------------------------------------------------------------------

local OFF = 256 -- stored = e + OFF
LiquidMatte.OFFSET = OFF

-- Final alpha byte of a stored extended value (header rule 6, last line).
local function toByte(s: number, clip: number): number
	local z = s - OFF
	if z <= clip then
		return 0
	elseif z >= 255 - clip then
		return 255
	end
	return z
end
LiquidMatte.toByte = toByte

-- Stored extended value of one edge-band pixel by the literal definition (header rule 4),
-- before the speck rule. rawMatte computes the same bits with a sliding window.
local function ratioValue(dq: buffer, w: number, h: number, x: number, y: number, radius: number, t0: number, t1: number, delta: number, plateau: number): number
	local d = buffer.readu16(dq, (y * w + x) * 2)
	local x0, x1 = math.max(0, x - radius), math.min(w - 1, x + radius)
	local y0, y1 = math.max(0, y - radius), math.min(h - 1, y + radius)
	local mx = 0
	for yy = y0, y1 do
		local base = yy * w
		for xx = x0, x1 do
			local q = buffer.readu16(dq, (base + xx) * 2)
			if q > mx then
				mx = q
			end
		end
	end
	local sum, cnt = 0, 0
	local cut = mx - delta
	for yy = y0, y1 do
		local base = yy * w
		for xx = x0, x1 do
			local q = buffer.readu16(dq, (base + xx) * 2)
			if q >= cut then
				sum += q
				cnt += 1
			end
		end
	end
	local F = sum / cnt
	if F < t1 then
		F = t1
	end
	local ramp = (d - t0) / t0
	if ramp > 1 then
		ramp = 1
	end
	local t = (d / F) * ramp
	if t >= 1 then
		return plateau -- fully covered: joins the interior plateau
	end
	return floor(255 * t + 0.5) + OFF
end

-- Merges closed intervals (flat pairs, any order, may overlap) into sorted disjoint ones.
LiquidMatte.ratioValue = ratioValue

local function mergeIntervals(src: { number }, n: number, out: { number }): number
	for i = 3, n * 2 - 1, 2 do -- insertion sort by start: a few runs per row
		local a, b = src[i], src[i + 1]
		local j = i - 2
		while j >= 1 and src[j] > a do
			src[j + 2], src[j + 3] = src[j], src[j + 1]
			j -= 2
		end
		src[j + 2], src[j + 3] = a, b
	end
	local m = 0
	for i = 1, n * 2 - 1, 2 do
		local a, b = src[i], src[i + 1]
		if m > 0 and a <= out[m * 2] + 1 then
			if b > out[m * 2] then
				out[m * 2] = b
			end
		else
			m += 1
			out[m * 2 - 1] = a
			out[m * 2] = b
		end
	end
	return m
end

-- Extended matte e (u16 per pixel, header rule 4) from the distance field. Returns e, the
-- number of edge-band pixels (the only ones that read a window) and the literal intervals:
-- every value change of a row lies inside or next to one of them.
function LiquidMatte.rawMatte(field: Field, w: number, h: number, P: Params, eBuf: buffer?): (buffer, number, Intervals)
	local e = eBuf or buffer.create(w * h * 2 + 8)
	local dq = field.dq
	local t0, t1 = P.t0, P.t1
	local bgS, fgS = OFF - P.headroom, OFF + 255 + P.headroom
	local band = 0
	local La: { number } = {}
	local Lb: { number } = {}
	local Lfirst: { number } = table.create(h + 1, 0)
	local nL = 0
	if P.mode == "ramp" then
		local span = t1 - t0
		for y = 0, h - 1 do
			Lfirst[y + 1] = nL + 1
			local prevLit = false
			for x = 0, w - 1 do
				local i = y * w + x
				local d = buffer.readu16(dq, i * 2)
				local v = bgS
				local lit = false
				if d >= t1 then
					v = fgS
				elseif d > t0 then
					v = floor(255 * (d - t0) / span + 0.5) + OFF
					lit = true
				end
				-- a plateau change between neighbours is marked literal too
				if not lit and x > 0 and buffer.readu16(e, (i - 1) * 2) ~= v then
					lit = true
				end
				if lit then
					if prevLit then
						Lb[nL] = x
					else
						nL += 1
						La[nL] = x
						Lb[nL] = x
					end
				end
				prevLit = lit
				buffer.writeu16(e, i * 2, v)
			end
		end
		Lfirst[h + 1] = nL + 1
		return e, 0, { a = La, b = Lb, first = Lfirst }
	end
	local r = P.radius
	local delta = P.key.noiseD
	local speck = P.speck + OFF
	local runA, runB, rowRun = field.runA, field.runB, field.rowRun
	local readu16 = buffer.readu16
	local sub: { number } = {}
	local merged: { number } = {}
	local colMax = table.create(w, 0)
	local cur = table.create(2 * r + 1, 0)
	local colVal = table.create(w * (2 * P.radius + 1), 0)
	local fgWord, bgWord = fgS * 65537, bgS * 65537
	for y = 0, h - 1 do
		local base = y * w
		Lfirst[y + 1] = nL + 1
		-- interior plateau everywhere, then background runs, then the edge band
		fillSpan(e, base * 2, w // 2, fgWord)
		if w % 2 == 1 then
			buffer.writeu16(e, (base + w - 1) * 2, fgS)
		end
		local k0, k1 = rowRun[y + 1], rowRun[y + 2] - 1
		for k = k0, k1 do
			local a, len = runA[k], runB[k] - runA[k] + 1
			if len >= 2 then
				fillSpan(e, (base + a) * 2, len // 2, bgWord)
			end
			if len % 2 == 1 then
				buffer.writeu16(e, (base + runB[k]) * 2, bgS)
			end
		end
		-- every gap between background runs is non-background; its band part lies within
		-- r of a background run of rows y - r .. y + r (binary search per row)
		local ya, yb = math.max(0, y - r), math.min(h - 1, y + r)
		for yy = ya, yb do -- one forward cursor per nearby row (gaps move left to right)
			cur[yy - ya + 1] = rowRun[yy + 1]
		end
		local gStart = 0
		for k = k0, k1 + 1 do
			local gEnd = if k <= k1 then runA[k] - 1 else w - 1
			if gStart == gEnd then
				-- a one-pixel gap: if its vertical neighbours are background too and even the
				-- largest value the ratio rule could give (F >= t1) is a speck, it is one
				local x = gStart
				local i = base + x
				if (y == 0 or readu16(dq, (i - w) * 2) <= t0) and (y == h - 1 or readu16(dq, (i + w) * 2) <= t0) then
					local d = readu16(dq, i * 2)
					local ramp = (d - t0) / t0
					if ramp > 1 then
						ramp = 1
					end
					if floor(255 * (d / t1) * ramp + 0.5) <= P.speck and d < t1 then
						band += 1
						buffer.writeu16(e, i * 2, bgS)
						if k <= k1 then
							gStart = runB[k] + 1
						end
						continue
					end
				end
			end
			if gStart <= gEnd then
				local n = 0
				local lo, hi = gStart - r, gEnd + r
				for yy = ya, yb do
					local a1 = rowRun[yy + 2] - 1
					local L = cur[yy - ya + 1]
					while L <= a1 and runB[L] < lo do
						L += 1
					end
					cur[yy - ya + 1] = L
					while L <= a1 and runA[L] <= hi do
						n += 1
						local s0 = runA[L] - r
						local s1 = runB[L] + r
						sub[n * 2 - 1] = if s0 < gStart then gStart else s0
						sub[n * 2] = if s1 > gEnd then gEnd else s1
						L += 1
					end
				end
				if n > 0 then
					local m = mergeIntervals(sub, n, merged)
					for j = 1, m do
						local m0, m1 = merged[j * 2 - 1], merged[j * 2]
						-- column maxima over rows ya..yb, then a sliding window maximum
						local c0 = if m0 - r < 0 then 0 else m0 - r
						local c1 = if m1 + r > w - 1 then w - 1 else m1 + r
						local R = yb - ya + 1
						for c = c0, c1 do
							local mx = 0
							local at = (c - c0) * R
							for yy = ya, yb do
								local q = readu16(dq, (yy * w + c) * 2)
								at += 1
								colVal[at] = q
								if q > mx then
									mx = q
								end
							end
							colMax[c + 1] = mx
						end
						for x = m0, m1 do
							band += 1
							local xa = if x - r < 0 then 0 else x - r
							local xb = if x + r > w - 1 then w - 1 else x + r
							local M = 0
							for c = xa, xb do
								local q = colMax[c + 1]
								if q > M then
									M = q
								end
							end
							local F = M -- the mean of the members equals M when delta = 0
							if delta > 0 then
								local sum, cnt = 0, 0
								local cut = M - delta
								for at = (xa - c0) * R + 1, (xb - c0 + 1) * R do
									local q = colVal[at]
									if q >= cut then
										sum += q
										cnt += 1
									end
								end
								F = sum / cnt
							end
							if F < t1 then
								F = t1
							end
							local d = readu16(dq, (base + x) * 2)
							local ramp = (d - t0) / t0
							if ramp > 1 then
								ramp = 1
							end
							local t = (d / F) * ramp
							local v = if t >= 1 then fgS else floor(255 * t + 0.5) + OFF
							if
								v <= speck
								and (x == 0 or readu16(dq, (base + x - 1) * 2) <= t0)
								and (x == w - 1 or readu16(dq, (base + x + 1) * 2) <= t0)
								and (y == 0 or readu16(dq, (base + x - w) * 2) <= t0)
								and (y == h - 1 or readu16(dq, (base + x + w) * 2) <= t0)
							then
								v = bgS -- an isolated weak pixel is a speck of noise
							end
							buffer.writeu16(e, (base + x) * 2, v)
						end
						-- literal interval: drop leading / trailing pixels equal to the plateau
						-- next to them (they join that gap); keep one separating pixel when
						-- the plateaus on the two sides differ
						local tl, th = m0, m1
						local lv = if m0 > 0 then readu16(e, (base + m0 - 1) * 2) else -1
						local rv = if m1 < w - 1 then readu16(e, (base + m1 + 1) * 2) else -1
						if rv >= 0 then
							while th >= tl and readu16(e, (base + th) * 2) == rv do
								th -= 1
							end
						end
						if lv >= 0 then
							while tl <= th and readu16(e, (base + tl) * 2) == lv do
								tl += 1
							end
						end
						if tl > th and lv >= 0 and rv >= 0 and lv ~= rv then
							-- [m0, th] equals lv and (th, m1] equals rv: the change is at th + 1
							tl = if th + 1 <= m1 then th + 1 else m1
							th = tl
						end
						if tl <= th then
							nL += 1
							La[nL] = tl
							Lb[nL] = th
						end
					end
				end
			end
			if k <= k1 then
				gStart = runB[k] + 1
			end
		end
	end
	Lfirst[h + 1] = nL + 1
	return e, band, { a = La, b = Lb, first = Lfirst }
end

-- Alpha bytes from an extended plane (header rule 6, last line), runs of 0 and 255 four at
-- a time.
function LiquidMatte.toAlpha(e: buffer, n: number, clip: number, out: buffer?): buffer
	local A = out or buffer.create(n)
	local readu32, readu16 = buffer.readu32, buffer.readu16
	local i = 0
	while i < n do
		if i + 3 < n then
			local w1 = readu32(e, i * 2)
			if w1 == readu32(e, i * 2 + 4) and w1 % 65537 == 0 then -- four equal values
				local j = i + 4
				while j + 1 < n and readu32(e, j * 2) == w1 do
					j += 2
				end
				buffer.fill(A, i, toByte(w1 // 65537, clip), j - i)
				i = j
				continue
			end
		end
		buffer.writeu8(A, i, toByte(readu16(e, i * 2), clip))
		i += 1
	end
	return A
end

----------------------------------------------------------------------------------------
-- 6. flood from the border (4-connected, run based)
----------------------------------------------------------------------------------------

-- Sets e := 255 + m on passable pixels (e < 255) that the border cannot reach through
-- passable pixels, and marks them in the returned mask (1 = protected). Cost follows the
-- number of passable runs, not pixels.
function LiquidMatte.floodProtect(e: buffer, w: number, h: number, headroom: number): (buffer, number)
	local T = OFF + 255 -- stored values >= T are opaque
	local fgS = T + headroom
	local readu16 = buffer.readu16
	local readu32 = buffer.readu32
	local RA: { number } = {}
	local RB: { number } = {}
	local rowStart: { number } = table.create(h + 1, 0)
	local n = 0
	for y = 0, h - 1 do
		rowStart[y + 1] = n + 1
		local base = y * w
		local x = 0
		while x < w do
			while x + 1 < w do -- opaque pairs of equal values
				local wv = readu32(e, (base + x) * 2)
				if wv % 65537 == 0 and wv // 65537 >= T then
					x += 2
				else
					break
				end
			end
			while x < w and readu16(e, (base + x) * 2) >= T do
				x += 1
			end
			if x >= w then
				break
			end
			local a = x
			while true do
				while x + 1 < w do -- passable pairs of equal values
					local wv = readu32(e, (base + x) * 2)
					if wv % 65537 == 0 and wv // 65537 < T then
						x += 2
					else
						break
					end
				end
				if x < w and readu16(e, (base + x) * 2) < T then
					x += 1
				else
					break
				end
			end
			n += 1
			RA[n] = a
			RB[n] = x - 1
		end
	end
	rowStart[h + 1] = n + 1
	local seen = buffer.create(n + 1)
	local rowOf = table.create(n, 0)
	for y = 0, h - 1 do
		for k = rowStart[y + 1], rowStart[y + 2] - 1 do
			rowOf[k] = y
		end
	end
	local stack: { number } = {}
	local top = 0
	for y = 0, h - 1 do
		for k = rowStart[y + 1], rowStart[y + 2] - 1 do
			if y == 0 or y == h - 1 or RA[k] == 0 or RB[k] == w - 1 then
				buffer.writeu8(seen, k, 1)
				top += 1
				stack[top] = k
			end
		end
	end
	while top > 0 do
		local k = stack[top]
		top -= 1
		local y = rowOf[k]
		local a, b = RA[k], RB[k]
		for dy = -1, 1, 2 do
			local yy = y + dy
			if yy >= 0 and yy < h then
				local lo, hi = rowStart[yy + 1], rowStart[yy + 2] - 1
				local last = hi
				while lo <= hi do -- first run of row yy ending at or after a
					local mid = (lo + hi) // 2
					if RB[mid] < a then
						lo = mid + 1
					else
						hi = mid - 1
					end
				end
				local j = lo
				while j <= last and RA[j] <= b do
					if buffer.readu8(seen, j) == 0 then
						buffer.writeu8(seen, j, 1)
						top += 1
						stack[top] = j
					end
					j += 1
				end
			end
		end
	end
	local mask = buffer.create(w * h)
	local count = 0
	for y = 0, h - 1 do
		for k = rowStart[y + 1], rowStart[y + 2] - 1 do
			if buffer.readu8(seen, k) == 0 then
				local len = RB[k] - RA[k] + 1
				local at = y * w + RA[k]
				for x = 0, len - 1 do
					buffer.writeu16(e, (at + x) * 2, fgS)
				end
				buffer.fill(mask, at, 1, len)
				count += len
			end
		end
	end
	return mask, count
end

----------------------------------------------------------------------------------------
-- 7. liquid refinement
----------------------------------------------------------------------------------------

-- GT[s + 1] = g(s) for s = 0 .. tau - 1 (header rule 6).
function LiquidMatte.gainTable(tau: number, kMax: number): { number }
	local GT = table.create(tau, 0)
	for s = 0, tau - 1 do
		local k = (kMax * (tau - s) + tau - 1) // tau
		local g = 1
		for _ = 1, k do
			g *= 0.5
		end
		GT[s + 1] = g
	end
	return GT
end

-- One liquid pass over a line (header rule 6), the definition every refinement reproduces:
-- v = inputs, d = guide values (Dq) of the same pixels, both 1-based arrays of equal length.
-- Forward: h[1] = v[1], then h[i] from h[i - 1] with the step s = |d[i] - d[i - 1]|.
-- Backward: h[n] = v[n], then h[i] from h[i + 1] with s = |d[i] - d[i + 1]|.
function LiquidMatte.linePass(v: { number }, d: { number }, tau: number, kMax: number, snap: number?, backward: boolean?, GT: { number }?): { number }
	local G = GT or LiquidMatte.gainTable(tau, kMax)
	local SN = snap or SNAP
	local n = #v
	local out = table.create(n, 0)
	local first, last, dir = 1, n, 1
	if backward then
		first, last, dir = n, 1, -1
	end
	local hs = v[first]
	out[first] = hs
	for i = first + dir, last, dir do
		local x = v[i]
		local s = d[i] - d[i - dir]
		if s < 0 then
			s = -s
		end
		if s >= tau then
			hs = x
		else
			hs = hs + (x - hs) * G[s + 1]
			local r = x - hs
			if r < SN and r > -SN then
				hs = x
			end
		end
		out[i] = hs
	end
	return out
end

-- The definition, line by line with no skipping (the tests' reference): rule 6 written with
-- linePass. e is the extended matte (stored u16), the result the alpha bytes.
function LiquidMatte.refineReference(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number, snap: number?): buffer
	local GT = LiquidMatte.gainTable(tau, kMax)
	local n = w * h
	local Hb = buffer.create(n * 2)
	local v = table.create(w, 0)
	local d = table.create(w, 0)
	for y = 0, h - 1 do
		local base = y * w
		for x = 0, w - 1 do
			v[x + 1] = buffer.readu16(e, (base + x) * 2)
			d[x + 1] = buffer.readu16(dq, (base + x) * 2)
		end
		local hl = LiquidMatte.linePass(v, d, tau, kMax, snap, false, GT)
		local hr = LiquidMatte.linePass(v, d, tau, kMax, snap, true, GT)
		for x = 0, w - 1 do
			buffer.writeu16(Hb, (base + x) * 2, floor((hl[x + 1] + hr[x + 1]) * 0.5 + 0.5))
		end
	end
	local A = buffer.create(n)
	local cv = table.create(h, 0)
	local cd = table.create(h, 0)
	for x = 0, w - 1 do
		for y = 0, h - 1 do
			cv[y + 1] = buffer.readu16(Hb, (y * w + x) * 2)
			cd[y + 1] = buffer.readu16(dq, (y * w + x) * 2)
		end
		local hu = LiquidMatte.linePass(cv, cd, tau, kMax, snap, false, GT)
		local hd = LiquidMatte.linePass(cv, cd, tau, kMax, snap, true, GT)
		for y = 0, h - 1 do
			buffer.writeu8(A, y * w + x, toByte(floor((hu[y + 1] + hd[y + 1]) * 0.5 + 0.5), clip))
		end
	end
	return A
end

local STRIP = 64

-- Event-driven refinement: the same bits as refineReference. Returns the alpha bytes and
-- the number of transient steps (states left off their input after a step).
function LiquidMatte.refine(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number, snap: number?, out: buffer?): (buffer, number)
	local GT = LiquidMatte.gainTable(tau, kMax)
	local SN = snap or SNAP
	local readu8, readu16, readu32 = buffer.readu8, buffer.readu16, buffer.readu32
	local writeu8, writeu16 = buffer.writeu8, buffer.writeu16
	local n = w * h
	local transients = 0
	local cl, ch = clip + OFF, 255 - clip + OFF -- thresholds on stored values
	-- horizontal stage: Hb = round((hL + hR) / 2), extended values
	local Hb = buffer.create(n * 2 + 8)
	buffer.copy(Hb, 0, e, 0, n * 2)
	local rowL = table.create(w, 0)
	local markL = buffer.create(w + 8)
	for y = 0, h - 1 do
		local base = y * w
		local touched = false
		local hs = readu16(e, base * 2)
		local x = 1
		while x < w do
			local v = readu16(e, (base + x) * 2)
			if hs == v then
				x += 1
				local word = v * 65537
				while x + 1 < w and readu32(e, (base + x) * 2) == word do
					x += 2
				end
			else
				local s = readu16(dq, (base + x) * 2) - readu16(dq, (base + x - 1) * 2)
				if s < 0 then
					s = -s
				end
				if s >= tau then
					hs = v
				else
					hs = hs + (v - hs) * GT[s + 1]
					local d = v - hs
					if d < SN and d > -SN then
						hs = v
					end
				end
				if hs ~= v then
					if not touched then
						buffer.fill(markL, 0, 0, w + 8)
						touched = true
					end
					rowL[x + 1] = hs
					writeu8(markL, x, 1)
					transients += 1
				end
				x += 1
			end
		end
		hs = readu16(e, (base + w - 1) * 2)
		x = w - 1
		while x >= 0 do
			local v = readu16(e, (base + x) * 2)
			local ml = if touched then readu8(markL, x) else 0
			if hs == v and ml == 0 then
				x -= 1
				local word = v * 65537
				if touched then
					while x >= 1 and readu32(e, (base + x - 1) * 2) == word and readu16(markL, x - 1) == 0 do
						x -= 2
					end
				else
					while x >= 1 and readu32(e, (base + x - 1) * 2) == word do
						x -= 2
					end
				end
			else
				if hs ~= v then
					local s = readu16(dq, (base + x) * 2) - readu16(dq, (base + x + 1) * 2)
					if s < 0 then
						s = -s
					end
					if s >= tau then
						hs = v
					else
						hs = hs + (v - hs) * GT[s + 1]
						local d = v - hs
						if d < SN and d > -SN then
							hs = v
						end
					end
					if hs ~= v then
						transients += 1
					end
				end
				local hlv = if ml == 1 then rowL[x + 1] else v
				if hlv ~= v or hs ~= v then
					writeu16(Hb, (base + x) * 2, floor((hlv + hs) * 0.5 + 0.5))
				end
				x -= 1
			end
		end
	end
	-- vertical stage in strips of STRIP columns; A starts as the alpha of Hb
	local A = LiquidMatte.toAlpha(Hb, n, clip, out)
	local store = buffer.create(STRIP * h * 8)
	local markU = buffer.create(STRIP * h + 8)
	local hU = table.create(STRIP, 0)
	local conv = buffer.create(STRIP + 8)
	for x0 = 0, w - 1, STRIP do
		local x1 = math.min(x0 + STRIP, w)
		buffer.fill(markU, 0, 0)
		for x = x0, x1 - 1 do
			hU[x - x0 + 1] = readu16(Hb, x * 2)
			writeu8(conv, x - x0, 1)
		end
		for y = 1, h - 1 do -- top to bottom
			local rb = y * w
			local rp = rb - w
			local mrow = y * STRIP
			local x = x0
			while x < x1 do
				local j = x - x0
				if
					x + 3 < x1
					and readu32(conv, j) == WORD1
					and readu32(Hb, (rb + x) * 2) == readu32(Hb, (rp + x) * 2)
					and readu32(Hb, (rb + x) * 2 + 4) == readu32(Hb, (rp + x) * 2 + 4)
				then
					x += 4
				else
					local v = readu16(Hb, (rb + x) * 2)
					local hs = hU[j + 1]
					if hs ~= v then
						local s = readu16(dq, (rb + x) * 2) - readu16(dq, (rp + x) * 2)
						if s < 0 then
							s = -s
						end
						if s >= tau then
							hs = v
						else
							hs = hs + (v - hs) * GT[s + 1]
							local d = v - hs
							if d < SN and d > -SN then
								hs = v
							end
						end
						hU[j + 1] = hs
					end
					if hs == v then
						writeu8(conv, j, 1)
					else
						writeu8(conv, j, 0)
						buffer.writef64(store, (mrow + j) * 8, hs)
						writeu8(markU, mrow + j, 1)
						transients += 1
					end
					x += 1
				end
			end
		end
		do -- bottom row: the upward pass starts at rest
			local rb = (h - 1) * w
			local mrow = (h - 1) * STRIP
			for x = x0, x1 - 1 do
				local j = x - x0
				local v = readu16(Hb, (rb + x) * 2)
				hU[j + 1] = v
				writeu8(conv, j, 1)
				if readu8(markU, mrow + j) == 1 then
					local o = floor((buffer.readf64(store, (mrow + j) * 8) + v) * 0.5 + 0.5)
					writeu8(A, rb + x, if o <= cl then 0 elseif o >= ch then 255 else o - OFF)
				end
			end
		end
		for y = h - 2, 0, -1 do -- bottom to top, combined with the downward pass
			local rb = y * w
			local rn = rb + w
			local mrow = y * STRIP
			local x = x0
			while x < x1 do
				local j = x - x0
				if
					x + 3 < x1
					and readu32(conv, j) == WORD1
					and readu32(markU, mrow + j) == 0
					and readu32(Hb, (rb + x) * 2) == readu32(Hb, (rn + x) * 2)
					and readu32(Hb, (rb + x) * 2 + 4) == readu32(Hb, (rn + x) * 2 + 4)
				then
					x += 4
				else
					local v = readu16(Hb, (rb + x) * 2)
					local hs = hU[j + 1]
					if hs ~= v then
						local s = readu16(dq, (rb + x) * 2) - readu16(dq, (rn + x) * 2)
						if s < 0 then
							s = -s
						end
						if s >= tau then
							hs = v
						else
							hs = hs + (v - hs) * GT[s + 1]
							local d = v - hs
							if d < SN and d > -SN then
								hs = v
							end
						end
						hU[j + 1] = hs
						if hs ~= v then
							transients += 1
						end
					end
					writeu8(conv, j, if hs == v then 1 else 0)
					local mu = readu8(markU, mrow + j)
					if mu == 1 or hs ~= v then
						local hu = if mu == 1 then buffer.readf64(store, (mrow + j) * 8) else v
						local o = floor((hu + hs) * 0.5 + 0.5)
						writeu8(A, rb + x, if o <= cl then 0 elseif o >= ch then 255 else o - OFF)
					end
					x += 1
				end
			end
		end
	end
	return A, transients
end

-- Appends [a, b] to a row-ordered interval list, merging with the previous interval when
-- they touch. Returns the new count.
local function pushInterval(A: { number }, B: { number }, n: number, rowFirst: number, a: number, b: number): number
	if n >= rowFirst and a <= B[n] + 1 then
		if b > B[n] then
			B[n] = b
		end
		return n
	end
	n += 1
	A[n] = a
	B[n] = b
	return n
end

-- Literal intervals of any extended plane: pixels whose value differs from their left
-- neighbour (so each gap is constant). O(pixels); rawMatte builds them for free.
function LiquidMatte.literalsOf(e: buffer, w: number, h: number): Intervals
	local A: { number } = {}
	local B: { number } = {}
	local first: { number } = table.create(h + 1, 0)
	local n = 0
	for y = 0, h - 1 do
		first[y + 1] = n + 1
		local base = y * w
		local prev = buffer.readu16(e, base * 2)
		for x = 1, w - 1 do
			local v = buffer.readu16(e, (base + x) * 2)
			if v ~= prev then
				n = pushInterval(A, B, n, first[y + 1], x, x)
				prev = v
			end
		end
	end
	first[h + 1] = n + 1
	return { a = A, b = B, first = first }
end

-- Event-driven refinement on the row structure of e: `lit` lists, per row, intervals outside
-- which the row is constant between consecutive intervals (rawMatte returns them). The same
-- bits as refineReference; the work follows segments, changes between rows and transients,
-- not pixels. Returns the alpha bytes and the number of transient steps.
function LiquidMatte.refineRuns(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number, lit: Intervals, snap: number?, out: buffer?): (buffer, number)
	local GT = LiquidMatte.gainTable(tau, kMax)
	local SN = snap or SNAP
	local readu16, readu32 = buffer.readu16, buffer.readu32
	local writeu16, writeu32 = buffer.writeu16, buffer.writeu32
	local La, Lb, Lfirst = lit.a, lit.b, lit.first
	local n = w * h
	local transients = 0
	local Hb = buffer.create(n * 2 + 8)
	buffer.copy(Hb, 0, e, 0, n * 2)
	-- H literal intervals: the e literals plus the transient stretches of each gap
	local HA: { number } = {}
	local HB: { number } = {}
	local Hfirst: { number } = table.create(h + 1, 0)
	local nH = 0
	local rowL = table.create(w, 0)
	local stampL = buffer.create(w * 4) -- u32 per column: y + 1 where rowL holds this row's hL
	local gl: { number } = {} -- per gap: number of left-pass transient pixels at its start
	local gs: { number } = {} -- per gap: first pixel the left pass stepped in it
	local gr: { number } = {} -- per gap: number of right-pass transient pixels at its end

	for y = 0, h - 1 do
		local base = y * w
		local i0, i1 = Lfirst[y + 1], Lfirst[y + 2] - 1
		local stamp = y + 1
		-- left to right
		local hs = readu16(e, base * 2)
		local x = 1
		local k = i0 -- gap k - i0 lies left of literal k
		while x < w do
			local lit0 = k <= i1 and x >= La[k]
			local xe = if lit0 then Lb[k] elseif k <= i1 then La[k] - 1 else w - 1
			local v = readu16(e, (base + x) * 2)
			local xs = x
			while x <= xe do
				if lit0 then
					v = readu16(e, (base + x) * 2)
				elseif hs == v then
					break -- at rest on a constant gap: skip the rest of it
				end
				if hs ~= v then
					local s = readu16(dq, (base + x) * 2) - readu16(dq, (base + x - 1) * 2)
					if s < 0 then
						s = -s
					end
					if s >= tau then
						hs = v
					else
						hs = hs + (v - hs) * GT[s + 1]
						local d = v - hs
						if d < SN and d > -SN then
							hs = v
						end
					end
					if hs ~= v then
						rowL[x + 1] = hs
						writeu32(stampL, x * 4, stamp)
						transients += 1
					end
				end
				x += 1
			end
			if lit0 then
				k += 1
			else
				local g = k - i0 + 1
				local nl = x - xs - (if hs == v and x > xs then 1 else 0)
				gl[g] = if nl > 0 then nl else 0
				gs[g] = xs
				gr[g] = 0
			end
			x = xe + 1
		end
		-- right to left, combined with the left pass
		hs = readu16(e, (base + w - 1) * 2)
		x = w - 1
		k = i1 -- gap k - i0 + 1 lies right of literal k
		while x >= 0 do
			local lit0 = k >= i0 and x <= Lb[k]
			local xe = if lit0 then La[k] elseif k >= i0 then Lb[k] + 1 else 0
			local v = readu16(e, (base + x) * 2)
			local xs = x
			while x >= xe do
				if lit0 then
					v = readu16(e, (base + x) * 2)
				elseif hs == v then
					break
				end
				if hs ~= v then
					local s = readu16(dq, (base + x) * 2) - readu16(dq, (base + x + 1) * 2)
					if s < 0 then
						s = -s
					end
					if s >= tau then
						hs = v
					else
						hs = hs + (v - hs) * GT[s + 1]
						local d = v - hs
						if d < SN and d > -SN then
							hs = v
						end
					end
					if hs ~= v then
						transients += 1
					end
				end
				local hl = if readu32(stampL, x * 4) == stamp then rowL[x + 1] else v
				if hl ~= v or hs ~= v then
					writeu16(Hb, (base + x) * 2, floor((hl + hs) * 0.5 + 0.5))
				end
				x -= 1
			end
			if lit0 then
				k -= 1
			else
				local g = k - i0 + 2
				local nr = xs - x - (if hs == v and x < xs then 1 else 0)
				gr[g] = if nr > 0 then nr else 0
				-- the rest of the gap has hR = v: combine the left stretch inside it
				local nl = gl[g] or 0
				if nl > 0 then
					local lsta = gs[g]
					local lend = lsta + nl - 1
					if lend > x then
						lend = x
					end
					for xx = lsta, lend do
						writeu16(Hb, (base + xx) * 2, floor((rowL[xx + 1] + v) * 0.5 + 0.5))
					end
				end
			end
			x = xe - 1
		end
		-- H literal intervals of the row, in order: gap stretches and literals
		Hfirst[y + 1] = nH + 1
		local rf = nH + 1
		local ga = 0
		for kk = i0, i1 + 1 do
			local g = kk - i0 + 1
			local gb = if kk <= i1 then La[kk] - 1 else w - 1
			if ga <= gb then
				local nl, nr = gl[g] or 0, gr[g] or 0
				if nl > 0 then
					nH = pushInterval(HA, HB, nH, rf, gs[g], gs[g] + nl - 1)
				end
				if nr > 0 then
					nH = pushInterval(HA, HB, nH, rf, gb - nr + 1, gb)
				end
			end
			if kk <= i1 then
				nH = pushInterval(HA, HB, nH, rf, La[kk], Lb[kk])
				ga = Lb[kk] + 1
			end
			gl[g] = 0
			gr[g] = 0
		end
	end
	Hfirst[h + 1] = nH + 1

	-- A starts as the clamp of H: constant gaps are filled, literals done per pixel
	local A = out or buffer.create(n)
	for y = 0, h - 1 do
		local base = y * w
		local x = 0
		local kEnd = Hfirst[y + 2]
		for kk = Hfirst[y + 1], kEnd do
			local a = if kk < kEnd then HA[kk] else w
			if a > x then
				buffer.fill(A, base + x, toByte(readu16(Hb, (base + x) * 2), clip), a - x)
			end
			if kk < kEnd then
				for xx = a, HB[kk] do
					buffer.writeu8(A, base + xx, toByte(readu16(Hb, (base + xx) * 2), clip))
				end
				x = HB[kk] + 1
			end
		end
	end

	-- change sets C_y (y >= 1): columns where H(y) may differ from H(y - 1)
	local CA: { number } = {}
	local CB: { number } = {}
	local Cfirst: { number } = table.create(h + 1, 0)
	local nC = 0
	Cfirst[1] = 1
	for y = 1, h - 1 do
		Cfirst[y + 1] = nC + 1
		local rf = nC + 1
		local p = 0
		local k1, e1 = Hfirst[y], Hfirst[y + 1] - 1 -- row y - 1
		local k2, e2 = Hfirst[y + 1], Hfirst[y + 2] - 1 -- row y
		local bPrev, bCur = (y - 1) * w, y * w
		while p < w do
			local lit1 = k1 <= e1 and p >= HA[k1]
			local end1 = if lit1 then HB[k1] elseif k1 <= e1 then HA[k1] - 1 else w - 1
			local lit2 = k2 <= e2 and p >= HA[k2]
			local end2 = if lit2 then HB[k2] elseif k2 <= e2 then HA[k2] - 1 else w - 1
			local q = if end1 < end2 then end1 else end2
			if lit1 or lit2 or readu16(Hb, (bPrev + p) * 2) ~= readu16(Hb, (bCur + p) * 2) then
				nC = pushInterval(CA, CB, nC, rf, p, q)
			end
			p = q + 1
			if lit1 and p > HB[k1] then
				k1 += 1
			end
			if lit2 and p > HB[k2] then
				k2 += 1
			end
		end
	end
	Cfirst[h + 1] = nC + 1

	-- vertical passes: per row the columns to visit are the change set, the columns still in
	-- a transient, and (upward) the columns with a downward transient on this row
	local cols = table.create(w, 0)
	local stampV = buffer.create(w * 4)
	local act: { number } = {}
	local nAct = 0
	local nxt: { number } = {}

	-- top to bottom
	local hU = table.create(w, 0)
	for x = 0, w - 1 do
		hU[x + 1] = readu16(Hb, x * 2)
	end
	local UX: { number } = {}
	local UV: { number } = {}
	local Ufirst: { number } = table.create(h + 1, 0)
	local nU = 0
	Ufirst[1] = 1
	for y = 1, h - 1 do
		Ufirst[y + 1] = nU + 1
		local rb = y * w
		local stamp = y + 1
		local nc = 0
		for kk = Cfirst[y + 1], Cfirst[y + 2] - 1 do
			for x = CA[kk], CB[kk] do
				nc += 1
				cols[nc] = x
				writeu32(stampV, x * 4, stamp)
			end
		end
		for j = 1, nAct do
			local x = act[j]
			if readu32(stampV, x * 4) ~= stamp then
				nc += 1
				cols[nc] = x
				writeu32(stampV, x * 4, stamp)
			end
		end
		local nNxt = 0
		for j = 1, nc do
			local x = cols[j]
			local v = readu16(Hb, (rb + x) * 2)
			local hs = hU[x + 1]
			if hs ~= v then
				local s = readu16(dq, (rb + x) * 2) - readu16(dq, (rb + x - w) * 2)
				if s < 0 then
					s = -s
				end
				if s >= tau then
					hs = v
				else
					hs = hs + (v - hs) * GT[s + 1]
					local d = v - hs
					if d < SN and d > -SN then
						hs = v
					end
				end
				hU[x + 1] = hs
				if hs ~= v then
					transients += 1
					nU += 1
					UX[nU] = x
					UV[nU] = hs
					nNxt += 1
					nxt[nNxt] = x
				end
			end
		end
		act, nxt = nxt, act
		nAct = nNxt
	end
	Ufirst[h + 1] = nU + 1

	-- bottom to top, combined with the downward pass
	local hD = hU
	local rbLast = (h - 1) * w
	for x = 0, w - 1 do
		hD[x + 1] = readu16(Hb, (rbLast + x) * 2)
	end
	local stampT = buffer.create(w * 4) -- columns with a downward transient on this row
	local tv = table.create(w, 0)
	local cl, ch = clip + OFF, 255 - clip + OFF
	nAct = 0
	for y = h - 1, 0, -1 do
		local rb = y * w
		local stamp = h + 1 + y -- distinct from the downward stamps
		local nc = 0
		if y < h - 1 then
			for kk = Cfirst[y + 2], Cfirst[y + 3] - 1 do -- changes between rows y and y + 1
				for x = CA[kk], CB[kk] do
					nc += 1
					cols[nc] = x
					writeu32(stampV, x * 4, stamp)
				end
			end
		end
		for j = 1, nAct do
			local x = act[j]
			if readu32(stampV, x * 4) ~= stamp then
				nc += 1
				cols[nc] = x
				writeu32(stampV, x * 4, stamp)
			end
		end
		for j = Ufirst[y + 1], Ufirst[y + 2] - 1 do
			local x = UX[j]
			writeu32(stampT, x * 4, stamp)
			tv[x + 1] = UV[j]
			if readu32(stampV, x * 4) ~= stamp then
				nc += 1
				cols[nc] = x
				writeu32(stampV, x * 4, stamp)
			end
		end
		local nNxt = 0
		for j = 1, nc do
			local x = cols[j]
			local v = readu16(Hb, (rb + x) * 2)
			local hs = hD[x + 1]
			if hs ~= v then
				local s = readu16(dq, (rb + x) * 2) - readu16(dq, (rb + x + w) * 2)
				if s < 0 then
					s = -s
				end
				if s >= tau then
					hs = v
				else
					hs = hs + (v - hs) * GT[s + 1]
					local d = v - hs
					if d < SN and d > -SN then
						hs = v
					end
				end
				hD[x + 1] = hs
				if hs ~= v then
					transients += 1
					nNxt += 1
					nxt[nNxt] = x
				end
			end
			local hu = if readu32(stampT, x * 4) == stamp then tv[x + 1] else v
			if hu ~= v or hs ~= v then
				local o = floor((hu + hs) * 0.5 + 0.5)
				buffer.writeu8(A, rb + x, if o <= cl then 0 elseif o >= ch then 255 else o - OFF)
			end
		end
		act, nxt = nxt, act
		nAct = nNxt
	end
	return A, transients
end

----------------------------------------------------------------------------------------
-- 8. compose (despill) and bleed
----------------------------------------------------------------------------------------

-- Key chroma and the luma-free direction K - Y_K used by the spill limiter.
local function spillBasis(key: Key): (number, number, number, number, number, number)
	local kr, kg, kb = key.r, key.g, key.b
	local kcb = 128 * kb - 43 * kr - 85 * kg
	local kcr = 128 * kr - 107 * kg - 21 * kb
	local yk = (77 * kr + 150 * kg + 29 * kb) / 256
	return kcb, kcr, kcb * kcb + kcr * kcr, kr - yk, kg - yk, kb - yk
end

-- Key-ward share of a colour's chroma: p = (cb kcb + cr kcr) / |kc|^2 (0 for grey keys).
function LiquidMatte.keyShare(c: number, key: Key): number
	local kcb, kcr, kk = spillBasis(key)
	if kk == 0 then
		return 0
	end
	local r, g, b = c % 256, (c // 256) % 256, (c // 65536) % 256
	local cb = 128 * b - 43 * r - 85 * g
	local cr = 128 * r - 107 * g - 21 * b
	return (cb * kcb + cr * kcr) / kk
end

local function round255(v: number): number
	local q = floor(v + 0.5)
	if q < 0 then
		return 0
	elseif q > 255 then
		return 255
	end
	return q
end

-- Writes the output image from the source, the final alpha plane A and the key.
-- Returns the number of partial pixels.
function LiquidMatte.compose(img: buffer, w: number, h: number, A: buffer, P: Params, opaque: boolean, protect: buffer?, out: buffer?): (buffer, number)
	local dst = out or buffer.create(w * h * 4)
	local readu8, readu32 = buffer.readu8, buffer.readu32
	local writeu32 = buffer.writeu32
	local key = P.key
	local kr, kg, kb = key.r, key.g, key.b
	local despill = P.despill
	local s = P.spill
	local kcb, kcr, kk, vr, vg, vb = spillBasis(key)
	local limiter = s > 0 and kk > 0
	local partial = 0
	for y = 0, h - 1 do
		local base = y * w
		local x = 0
		while x < w do
			local i = base + x
			local a = readu8(A, i)
			if a == 0 and x + 3 < w and readu32(A, i) == 0 then
				-- transparent words: zero now, bled later
				local x2 = x + 4
				while x2 + 3 < w and readu32(A, base + x2) == 0 do
					x2 += 4
				end
				buffer.fill(dst, i * 4, 0, (x2 - x) * 4)
				x = x2
				continue
			end
			if a == 255 and opaque and not limiter and x + 3 < w and readu32(A, i) == 0xFFFFFFFF then
				local x2 = x + 4
				while x2 + 3 < w and readu32(A, base + x2) == 0xFFFFFFFF do
					x2 += 4
				end
				buffer.copy(dst, i * 4, img, i * 4, (x2 - x) * 4)
				x = x2
				continue
			end
			local p = readu32(img, i * 4)
			local sa = p // 16777216
			local r, g, b = p % 256, (p // 256) % 256, (p // 65536) % 256
			local prot = protect ~= nil and readu8(protect, i) == 1
			if a > 0 and a < 255 then
				partial += 1
				if despill and not prot then
					local inv = 255 - a
					r = round255((255 * r - inv * kr) / a)
					g = round255((255 * g - inv * kg) / a)
					b = round255((255 * b - inv * kb) / a)
				end
			end
			if limiter and a > 0 and not prot then
				local cb = 128 * b - 43 * r - 85 * g
				local cr = 128 * r - 107 * g - 21 * b
				local pk = (cb * kcb + cr * kcr) / kk
				if pk > 0 then
					local t = s * pk
					r = round255(r - t * vr)
					g = round255(g - t * vg)
					b = round255(b - t * vb)
				end
			end
			local oa = a
			if sa < 255 then
				oa = MyMath.div255(sa * a)
			end
			if oa == 0 then
				writeu32(dst, i * 4, 0)
			else
				writeu32(dst, i * 4, r + g * 256 + b * 65536 + oa * 16777216)
			end
			x += 1
		end
	end
	return dst, partial
end

-- Alpha bleeding (header rule 8), in place on an RGBA8 image whose alpha plane is A
-- (A is read; transparency is A == 0). Span fills only: cost follows runs.
function LiquidMatte.bleed(img: buffer, A: buffer, w: number, h: number)
	local readu8, readu32 = buffer.readu8, buffer.readu32
	local empty = buffer.create(h)
	local any = false
	for y = 0, h - 1 do
		local base = y * w
		local x = 0
		local visible = false
		while x < w do
			-- skip visible pixels (opaque words four at a time)
			while x < w do
				if x + 3 < w and readu32(A, base + x) == 0xFFFFFFFF then
					x += 4
				elseif readu8(A, base + x) ~= 0 then
					x += 1
				else
					break
				end
				visible = true
			end
			if x >= w then
				break
			end
			local a = x
			while x + 3 < w and readu32(A, base + x) == 0 do
				x += 4
			end
			while x < w and readu8(A, base + x) == 0 do
				x += 1
			end
			local b = x - 1
			local hasL = a > 0
			local hasR = x < w
			if hasL or hasR then
				local cl = if hasL then readu32(img, (base + a - 1) * 4) % 16777216 else 0
				local cr = if hasR then readu32(img, (base + x) * 4) % 16777216 else 0
				if hasL and hasR then
					local mid = (a + b) // 2
					fillSpan(img, (base + a) * 4, mid - a + 1, cl)
					fillSpan(img, (base + mid + 1) * 4, b - mid, cr)
				elseif hasL then
					fillSpan(img, (base + a) * 4, b - a + 1, cl)
				else
					fillSpan(img, (base + a) * 4, b - a + 1, cr)
				end
			end
		end
		if visible then
			any = true
		else
			buffer.writeu8(empty, y, 1)
		end
	end
	if not any then
		return
	end
	local rowBytes = w * 4
	local row = buffer.create(rowBytes)
	local function zeroAlphaCopy(src: number)
		buffer.copy(row, 0, img, src * rowBytes, rowBytes)
		for x = 0, w - 1 do
			buffer.writeu8(row, x * 4 + 3, 0)
		end
	end
	local y = 0
	while y < h do
		if buffer.readu8(empty, y) == 0 then
			y += 1
			continue
		end
		local ya = y
		while y < h and buffer.readu8(empty, y) == 1 do
			y += 1
		end
		local yb = y - 1
		local up = if ya > 0 then ya - 1 else -1
		local down = if yb < h - 1 then yb + 1 else -1
		local split = if up >= 0 and down >= 0 then (up + down) // 2 else (if up >= 0 then yb else ya - 1)
		if up >= 0 then
			zeroAlphaCopy(up)
			for yy = ya, math.min(split, yb) do
				buffer.copy(img, yy * rowBytes, row, 0, rowBytes)
			end
		end
		if down >= 0 then
			zeroAlphaCopy(down)
			for yy = math.max(split + 1, ya), yb do
				buffer.copy(img, yy * rowBytes, row, 0, rowBytes)
			end
		end
	end
end

----------------------------------------------------------------------------------------
-- 9. the pipeline and the baseline
----------------------------------------------------------------------------------------

-- Full liquid matte. Returns the RGBA8 output, the final alpha plane (before the source
-- alpha is applied) and statistics.
function LiquidMatte.matte(img: buffer, w: number, h: number, opts: Options?, out: buffer?): (buffer, buffer, Info)
	local o: Options = opts or {}
	local key = LiquidMatte.detectKey(img, w, h, o.wy, o.key)
	local P = LiquidMatte.params(key, o)
	local field = LiquidMatte.distanceField(img, w, h, key, P.t0)
	local e, band, lit = LiquidMatte.rawMatte(field, w, h, P)
	local protect: buffer? = nil
	local protectedCount = 0
	if P.flood then
		protect, protectedCount = LiquidMatte.floodProtect(e, w, h, P.headroom)
	end
	local A: buffer
	local transients = 0
	if P.refine then
		A, transients = LiquidMatte.refineRuns(e, field.dq, w, h, P.tau, P.kMax, P.clip, lit, P.snap)
	else
		A = LiquidMatte.toAlpha(e, w * h, P.clip)
	end
	local dst, partial = LiquidMatte.compose(img, w, h, A, P, field.opaque, protect, out)
	if P.bleed then
		LiquidMatte.bleed(dst, A, w, h)
	end
	return dst,
		A,
		{
			key = key,
			params = P,
			edgeBand = band,
			protected = protectedCount,
			transients = transients,
			partial = partial,
			distinct = field.distinct,
		}
end

-- Baseline: a plain per-pixel chroma key with the same metric and a linear ramp from t0 to
-- t1 (Dq units). No refinement, no despill, no bleed.
function LiquidMatte.plainKey(img: buffer, w: number, h: number, key: Key, t0: number, t1: number, out: buffer?): buffer
	local dst = out or buffer.create(w * h * 4)
	local kr, kg, kb = key.r, key.g, key.b
	local QA, QB, QC, QD, QE, QF = quadForm(key.wy)
	local readu32, writeu32 = buffer.readu32, buffer.writeu32
	local scale = 255 / (t1 - t0)
	for i = 0, w * h - 1 do
		local p = readu32(img, i * 4)
		local dr = p % 256 - kr
		local dg = (p // 256) % 256 - kg
		local db = (p // 65536) % 256 - kb
		local d = floor(sqrt(dr * (QA * dr + QD * dg + QE * db) + dg * (QB * dg + QF * db) + QC * db * db) * 0.015625)
		local a
		if d <= t0 then
			a = 0
		elseif d >= t1 then
			a = 255
		else
			a = floor((d - t0) * scale + 0.5)
		end
		writeu32(dst, i * 4, p % 16777216 + a * 16777216)
	end
	return dst
end

-- Lockstep checksum (as Liquid.hashBuffer): hash32 folded over the u32 words.
function LiquidMatte.hash(b: buffer): number
	local h = 0x811C9DC5
	local n = buffer.len(b) // 4
	for i = 0, n - 1 do
		h = hash32(bit32.bxor(h, buffer.readu32(b, i * 4)))
	end
	for i = n * 4, buffer.len(b) - 1 do
		h = hash32(bit32.bxor(h, buffer.readu8(b, i)))
	end
	return h
end

return LiquidMatte
