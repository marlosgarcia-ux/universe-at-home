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
--      radius 2, kMax 2, clip 3, headroom m = 64 (alpha units).
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
--      then if |v_x - h_x| < 1/64: h_x = v_x                            (snap)
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

local SNAP = 1 / 64
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
	distinct: number, -- pixels whose colour differed from the previous pixel (Dq computed)
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

-- Dq of a packed colour against a key (integers in, integer out).
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
	local kMax = o.kMax or 2
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
	local kr, kg, kb, wy = key.r, key.g, key.b, key.wy
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
		local prev = -1
		local d = 0
		local rowPx = y * w * 4
		local rowDq = y * w * 2
		local x = 0
		while x < w do
			local p = readu32(img, rowPx + x * 4)
			if p ~= prev then
				prev = p
				distinct += 1
				if p < 4278190080 then
					opaque = false
				end
				local dr = p % 256 - kr
				local dg = (p // 256) % 256 - kg
				local db = (p // 65536) % 256 - kb
				local dy = 77 * dr + 150 * dg + 29 * db
				local dcb = 128 * db - 43 * dr - 85 * dg
				local dcr = 128 * dr - 107 * dg - 21 * db
				d = floor(sqrt(4 * (dcb * dcb + dcr * dcr) + wy * dy * dy) * 0.015625)
			end
			-- the run of pixels equal to p
			local x2 = x + 1
			while x2 < w and readu32(img, rowPx + x2 * 4) == p do
				x2 += 1
			end
			local len = x2 - x
			if len == 1 then
				writeu16(dq, rowDq + x * 2, d)
			else
				fillSpan(dq, rowDq + x * 2, len // 2, d * 65537)
				if len % 2 == 1 then
					writeu16(dq, rowDq + (x2 - 1) * 2, d)
				end
			end
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
			x = x2
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

-- Extended value of one edge-band pixel (header rule 4).
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
		local gStart = 0
		for k = k0, k1 + 1 do
			local gEnd = if k <= k1 then runA[k] - 1 else w - 1
			if gStart <= gEnd then
				local n = 0
				local lo, hi = gStart - r, gEnd + r
				for yy = ya, yb do
					local a1 = rowRun[yy + 2] - 1
					local L, H = rowRun[yy + 1], a1
					while L <= H do
						local mid = (L + H) // 2
						if runB[mid] < lo then
							L = mid + 1
						else
							H = mid - 1
						end
					end
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
						nL += 1
						La[nL] = merged[j * 2 - 1]
						Lb[nL] = merged[j * 2]
						for x = merged[j * 2 - 1], merged[j * 2] do
							band += 1
							local v = ratioValue(dq, w, h, x, y, r, t0, t1, delta, fgS)
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

-- The definition, one pixel at a time with no skipping (the tests' reference). e is the
-- extended matte (u16), the result the alpha bytes.
function LiquidMatte.refineReference(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number): buffer
	local GT = LiquidMatte.gainTable(tau, kMax)
	local function step(hs: number, v: number, s: number): number
		if s >= tau then
			return v
		end
		hs = hs + (v - hs) * GT[s + 1]
		local d = v - hs
		if d < SNAP and d > -SNAP then
			hs = v
		end
		return hs
	end
	local n = w * h
	local Hb = buffer.create(n * 2)
	local hl = table.create(w, 0)
	for y = 0, h - 1 do
		local base = y * w
		local hs = buffer.readu16(e, base * 2)
		hl[1] = hs
		for x = 1, w - 1 do
			local s = math.abs(buffer.readu16(dq, (base + x) * 2) - buffer.readu16(dq, (base + x - 1) * 2))
			hs = step(hs, buffer.readu16(e, (base + x) * 2), s)
			hl[x + 1] = hs
		end
		hs = buffer.readu16(e, (base + w - 1) * 2)
		buffer.writeu16(Hb, (base + w - 1) * 2, floor((hl[w] + hs) * 0.5 + 0.5))
		for x = w - 2, 0, -1 do
			local s = math.abs(buffer.readu16(dq, (base + x) * 2) - buffer.readu16(dq, (base + x + 1) * 2))
			hs = step(hs, buffer.readu16(e, (base + x) * 2), s)
			buffer.writeu16(Hb, (base + x) * 2, floor((hl[x + 1] + hs) * 0.5 + 0.5))
		end
	end
	local A = buffer.create(n)
	local hu = table.create(h, 0)
	for x = 0, w - 1 do
		local hs = buffer.readu16(Hb, x * 2)
		hu[1] = hs
		for y = 1, h - 1 do
			local i = y * w + x
			local s = math.abs(buffer.readu16(dq, i * 2) - buffer.readu16(dq, (i - w) * 2))
			hs = step(hs, buffer.readu16(Hb, i * 2), s)
			hu[y + 1] = hs
		end
		hs = buffer.readu16(Hb, ((h - 1) * w + x) * 2)
		buffer.writeu8(A, (h - 1) * w + x, toByte(floor((hu[h] + hs) * 0.5 + 0.5), clip))
		for y = h - 2, 0, -1 do
			local i = y * w + x
			local s = math.abs(buffer.readu16(dq, i * 2) - buffer.readu16(dq, (i + w) * 2))
			hs = step(hs, buffer.readu16(Hb, i * 2), s)
			buffer.writeu8(A, i, toByte(floor((hu[y + 1] + hs) * 0.5 + 0.5), clip))
		end
	end
	return A
end

local STRIP = 64

-- Event-driven refinement: the same bits as refineReference. Returns the alpha bytes and
-- the number of transient steps (states left off their input after a step).
function LiquidMatte.refine(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number, out: buffer?): (buffer, number)
	local GT = LiquidMatte.gainTable(tau, kMax)
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
					if d < SNAP and d > -SNAP then
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
						if d < SNAP and d > -SNAP then
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
							if d < SNAP and d > -SNAP then
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
							if d < SNAP and d > -SNAP then
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

-- Event-driven refinement on the row structure of e: `lit` lists, per row, intervals outside
-- which the row is constant between consecutive intervals (rawMatte returns them). The same
-- bits as refineReference; the work follows segments, changes between rows and transients,
-- not pixels. Returns the alpha bytes and the number of transient steps.
function LiquidMatte.refineRuns(e: buffer, dq: buffer, w: number, h: number, tau: number, kMax: number, clip: number, lit: Intervals, out: buffer?): (buffer, number)
	local GT = LiquidMatte.gainTable(tau, kMax)
	local readu16 = buffer.readu16
	local writeu16 = buffer.writeu16
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
	local gr: { number } = {} -- per gap: number of right-pass transient pixels at its end

	local function stepH(hs: number, v: number, i: number, j: number): number
		local s = readu16(dq, i * 2) - readu16(dq, j * 2)
		if s < 0 then
			s = -s
		end
		if s >= tau then
			return v
		end
		hs = hs + (v - hs) * GT[s + 1]
		local d = v - hs
		if d < SNAP and d > -SNAP then
			hs = v
		end
		return hs
	end

	for y = 0, h - 1 do
		local base = y * w
		local i0, i1 = Lfirst[y + 1], Lfirst[y + 2] - 1
		local stamp = y + 1
		-- left to right
		local hs = readu16(e, base * 2)
		local x = 1
		local k = i0
		local g = 0 -- gap index: gap g lies left of literal i0 + g
		while x < w do
			if k <= i1 and x >= La[k] then
				for xx = x, Lb[k] do
					local v = readu16(e, (base + xx) * 2)
					if hs ~= v then
						hs = stepH(hs, v, base + xx, base + xx - 1)
						if hs ~= v then
							rowL[xx + 1] = hs
							buffer.writeu32(stampL, xx * 4, stamp)
							transients += 1
						end
					end
				end
				x = Lb[k] + 1
				k += 1
				g += 1
			else
				local gb = if k <= i1 then La[k] - 1 else w - 1
				local v = readu16(e, (base + x) * 2)
				local xs = x
				while x <= gb and hs ~= v do
					hs = stepH(hs, v, base + x, base + x - 1)
					if hs ~= v then
						rowL[x + 1] = hs
						buffer.writeu32(stampL, x * 4, stamp)
						transients += 1
					end
					x += 1
				end
				-- the transient pixels are the first ones of the gap, up to the one at rest
				gl[g + 1] = if hs == v then x - xs - 1 else x - xs
				if gl[g + 1] < 0 then
					gl[g + 1] = 0
				end
				gr[g + 1] = 0
				x = gb + 1
				if k > i1 then
					break
				end
			end
		end
		-- right to left, combined with the left pass
		hs = readu16(e, (base + w - 1) * 2)
		x = w - 1
		k = i1
		g = i1 - i0 + 1 -- the last gap (right of the last literal)
		while x >= 0 do
			if k >= i0 and x <= Lb[k] then
				for xx = x, La[k], -1 do
					local v = readu16(e, (base + xx) * 2)
					if hs ~= v then
						hs = stepH(hs, v, base + xx, base + xx + 1)
						if hs ~= v then
							transients += 1
						end
					end
					local hl = if buffer.readu32(stampL, xx * 4) == stamp then rowL[xx + 1] else v
					if hl ~= v or hs ~= v then
						writeu16(Hb, (base + xx) * 2, floor((hl + hs) * 0.5 + 0.5))
					end
				end
				x = La[k] - 1
				k -= 1
				g -= 1
			else
				local ga = if k >= i0 then Lb[k] + 1 else 0
				local v = readu16(e, (base + x) * 2)
				local xs = x
				while x >= ga and hs ~= v do
					hs = stepH(hs, v, base + x, base + x + 1)
					if hs ~= v then
						transients += 1
					end
					local hl = if buffer.readu32(stampL, x * 4) == stamp then rowL[x + 1] else v
					writeu16(Hb, (base + x) * 2, floor((hl + hs) * 0.5 + 0.5))
					x -= 1
				end
				gr[g + 1] = if hs == v then xs - x - 1 else xs - x
				if gr[g + 1] < 0 then
					gr[g + 1] = 0
				end
				-- the rest of the gap has hR = v; combine the left stretch inside it
				local lend = ga + (gl[g + 1] or 0) - 1
				if lend > x then
					lend = x
				end
				for xx = ga, lend do
					local hl = rowL[xx + 1]
					if hl ~= v then
						writeu16(Hb, (base + xx) * 2, floor((hl + v) * 0.5 + 0.5))
					end
				end
				x = ga - 1
				g -= 1
			end
		end
		-- H literal intervals of the row, in order: gap stretches and literals
		Hfirst[y + 1] = nH + 1
		local rf = nH + 1
		local ga = 0
		for kk = i0, i1 + 1 do
			local gg = kk - i0 -- gap index left of literal kk
			local gb = if kk <= i1 then La[kk] - 1 else w - 1
			if ga <= gb then
				local nl, nr = gl[gg + 1] or 0, gr[gg + 1] or 0
				if nl > 0 then
					nH = pushInterval(HA, HB, nH, rf, ga, ga + nl - 1)
				end
				if nr > 0 then
					nH = pushInterval(HA, HB, nH, rf, gb - nr + 1, gb)
				end
			end
			if kk <= i1 then
				nH = pushInterval(HA, HB, nH, rf, La[kk], Lb[kk])
				ga = Lb[kk] + 1
			end
			gl[gg + 1] = 0
			gr[gg + 1] = 0
		end
	end
	Hfirst[h + 1] = nH + 1

	-- A starts as the clamp of H: constant gaps are filled, literals done per pixel
	local A = out or buffer.create(n)
	for y = 0, h - 1 do
		local base = y * w
		local x = 0
		for kk = Hfirst[y + 1], Hfirst[y + 2] do
			local a = if kk < Hfirst[y + 2] then HA[kk] else w
			if a > x then
				buffer.fill(A, base + x, toByte(readu16(Hb, (base + x) * 2), clip), a - x)
			end
			if kk < Hfirst[y + 2] then
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

	-- top to bottom: column states, active columns, transients recorded per row
	local hU = table.create(w, 0)
	for x = 0, w - 1 do
		hU[x + 1] = readu16(Hb, x * 2)
	end
	local stampU = buffer.create(w * 4)
	local act: { number } = {}
	local nAct = 0
	local nxt: { number } = {}
	local UX: { number } = {}
	local UV: { number } = {}
	local Ufirst: { number } = table.create(h + 1, 0)
	local nU = 0
	Ufirst[1] = 1
	for y = 1, h - 1 do
		Ufirst[y + 1] = nU + 1
		local rb = y * w
		local stamp = y + 1
		local nNxt = 0
		local function processU(x: number)
			buffer.writeu32(stampU, x * 4, stamp)
			local v = readu16(Hb, (rb + x) * 2)
			local hs = hU[x + 1]
			if hs ~= v then
				hs = stepH(hs, v, rb + x, rb + x - w)
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
		for kk = Cfirst[y + 1], Cfirst[y + 2] - 1 do
			for x = CA[kk], CB[kk] do
				processU(x)
			end
		end
		for j = 1, nAct do
			local x = act[j]
			if buffer.readu32(stampU, x * 4) ~= stamp then
				processU(x)
			end
		end
		act, nxt = nxt, act
		nAct = nNxt
	end
	Ufirst[h + 1] = nU + 1

	-- bottom to top, combined with the downward pass
	local hD = table.create(w, 0)
	local rbLast = (h - 1) * w
	for x = 0, w - 1 do
		hD[x + 1] = readu16(Hb, (rbLast + x) * 2)
	end
	local stampD = buffer.create(w * 4)
	local stampT = buffer.create(w * 4) -- columns with a downward transient at this row
	local tv = table.create(w, 0)
	local cl, ch = clip + OFF, 255 - clip + OFF
	nAct = 0
	for y = h - 1, 0, -1 do
		local rb = y * w
		local stamp = y + 1
		local nNxt = 0
		for j = Ufirst[y + 1], Ufirst[y + 2] - 1 do
			buffer.writeu32(stampT, UX[j] * 4, stamp)
			tv[UX[j] + 1] = UV[j]
		end
		local function processD(x: number)
			buffer.writeu32(stampD, x * 4, stamp)
			local v = readu16(Hb, (rb + x) * 2)
			local hs = hD[x + 1]
			if hs ~= v then
				hs = stepH(hs, v, rb + x, rb + x + w)
				hD[x + 1] = hs
				if hs ~= v then
					transients += 1
					nNxt += 1
					nxt[nNxt] = x
				end
			end
			local hu = if buffer.readu32(stampT, x * 4) == stamp then tv[x + 1] else v
			if hu ~= v or hs ~= v then
				local o = floor((hu + hs) * 0.5 + 0.5)
				buffer.writeu8(A, rb + x, if o <= cl then 0 elseif o >= ch then 255 else o - OFF)
			end
		end
		if y < h - 1 then
			for kk = Cfirst[y + 2], Cfirst[y + 3] - 1 do -- changes between rows y and y + 1
				for x = CA[kk], CB[kk] do
					processD(x)
				end
			end
		end
		for j = 1, nAct do
			local x = act[j]
			if buffer.readu32(stampD, x * 4) ~= stamp then
				processD(x)
			end
		end
		for j = Ufirst[y + 1], Ufirst[y + 2] - 1 do
			local x = UX[j]
			if buffer.readu32(stampD, x * 4) ~= stamp then
				processD(x)
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
		A, transients = LiquidMatte.refineRuns(e, field.dq, w, h, P.tau, P.kMax, P.clip, lit)
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
	local kr, kg, kb, wy = key.r, key.g, key.b, key.wy
	local readu32, writeu32 = buffer.readu32, buffer.writeu32
	local scale = 255 / (t1 - t0)
	for i = 0, w * h - 1 do
		local p = readu32(img, i * 4)
		local dr = p % 256 - kr
		local dg = (p // 256) % 256 - kg
		local db = (p // 65536) % 256 - kb
		local dy = 77 * dr + 150 * dg + 29 * db
		local dcb = 128 * db - 43 * dr - 85 * dg
		local dcr = 128 * dr - 107 * dg - 21 * db
		local d = floor(sqrt(4 * (dcb * dcb + dcr * dcr) + wy * dy * dy) * 0.015625)
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
