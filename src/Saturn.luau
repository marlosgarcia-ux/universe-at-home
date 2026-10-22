--!native
--!optimize 2
-- universe-at-home :: Saturn
--
-- Level of detail without visible transitions: which level to show (LodSelector,
-- with hysteresis) and how to switch (Crossfade, two-phase and stacked). Pure
-- logic: no engine objects. Every frame it returns one transparency per layer;
-- engine code applies them to ImageLabel.ImageTransparency or Decal.Transparency
-- (the GPU blends for free; a CPU crossfade costs 120 ms per 1024^2 frame,
-- RUNTIME_AUDIT 6.7.7). Proofs: docs/COMPUTE.md "Flawless pipeline", LOD; checked
-- by dense sampling in tests/flawless.test.luau.
--
-- Levels. Level 0 is the finest; level k has 1/2^k of the base resolution and is
-- rendered directly at its own size (Raster.scaled), so every level is the exact
-- box filter of the vector source at that level (F1/F2 per level), or the exact
-- area resample of raster content (Filter.areaResample, C9). Levels therefore
-- agree with each other in the box-filter sense, and the only artifact left is the
-- switch itself, which this module makes continuous.
--
-- LodSelector. Input x is any quantity that grows with the coarseness the display
-- can afford, typically the texel footprint r = (base texels across) / (screen
-- pixels across). thresholds[k] = t_k is the value of x from which level k + 1 is
-- sufficient (t_k = 2^(k+1) for halving levels and r as input). With eta > 1:
--     move to a coarser level across boundary k only when x >= t_k * eta,
--     move to a finer level across boundary k as soon as x < t_k.
--   S1 (never undersampled) After every update t_(L-1) <= x < t_L * eta, so the
--      shown level L is always sufficient (L = 0 or x >= t_(L-1)) and, when
--      eta <= t_(k+1) / t_k, at most one level finer than the coarsest sufficient.
--   S2 (no oscillation) Crossing boundary k upward needs some input >= t_k * eta,
--      downward some input < t_k. An input sequence confined to an interval J
--      that does not contain points on both sides of any band [t_k, t_k * eta)
--      therefore crosses every boundary in at most one direction: the level
--      sequence is monotone, so it changes at most (levels - 1) times and never
--      reverses. If J lies inside one band [t_k, t_k * eta), the level changes at
--      most once, on the first update, and then stays fixed for any sequence.
--      In particular jitter of multiplicative size below eta can never flicker.
--
-- Crossfade. Two layers: OLD (the level shown) at the bottom and NEW (the level
-- coming in) stacked on top, composited by the GPU with straight-alpha
-- source-over. Opacities lambda = 1 - transparency, with u = elapsed / duration
-- and s(v) = v^2 (3 - 2 v) (smoothstep):
--     phase 1, u in [0, 1/2]:  lambda_new = s(2u),      lambda_old = 1
--     phase 2, u in [1/2, 1]:  lambda_new = 1,          lambda_old = 1 - s(2u - 1)
--   X1 (C1 continuity) Both opacities are continuous with continuous first
--      derivatives on [0, 1], equal to the static states outside it, with zero
--      derivative at u = 0, 1/2, 1 (s'(0) = s'(1) = 0). The composite of any
--      straight-alpha pixel pair is a polynomial in the two opacities, so colour
--      and alpha are C1 in time; only one opacity moves at a time and |d lambda /
--      du| <= 3, so every channel moves by at most 3 * |du| of full scale.
--   X2 (opaque pixels exact) If both levels are opaque at a pixel, alpha stays
--      exactly 1 throughout (no dip to the background, unlike the symmetric fade
--      lambda_old = 1 - t, lambda_new = t, whose alpha is 1 - t + t^2 >= 3/4) and
--      the colour is the exact blend (1 - w) c_old + w c_new, w = lambda_new in
--      phase 1 and 1 in phase 2.
--   X3 (semi-transparent pixels) Against the ideal blend of the two composites,
--      P* = (1 - w) P_old + w P_new, the stack deviates by exactly
--      theta (1 - a_new) a_old (c_old - background), theta = lambda_new in phase 1
--      and lambda_old in phase 2, theta in [0, 1]: at most (1 - a_new) a_old of
--      full scale (at most a (1 - a) <= 1/4 when both levels have alpha a), zero
--      at both ends, and alpha is never below the ideal (never more transparent).
--      No pair of per-layer scalar opacities can be exact for every
--      semi-transparent pixel unless one layer is off (a hard switch).
--   Z  (order swaps are invisible) The new layer must be on top. When a fade
--      ends the old layer is fully transparent, and when the next fade starts the
--      incoming layer is fully transparent, so the slot that receives the next
--      level is moved on top exactly when it is invisible: the composite does not
--      change. Lod does this bookkeeping with two slots.

local MyMath = require("./MyMath")

local Saturn = {}

----------------------------------------------------------------------------------
-- LodSelector
----------------------------------------------------------------------------------

export type Selector = {
	thresholds: { number }, -- t_k, increasing; #thresholds + 1 levels
	up: { number }, -- t_k * eta
	maxLevel: number,
	level: number,
}

-- thresholds: increasing t_0 < t_1 < ...; eta > 1: hysteresis factor; level:
-- initial level (default: the selector starts at 0 and the first update moves it).
function Saturn.selector(thresholds: { number }, eta: number, level: number?): Selector
	assert(eta >= 1, "hysteresis factor must be >= 1")
	local up = table.create(#thresholds, 0)
	for k = 1, #thresholds do
		if k > 1 then
			assert(thresholds[k] > thresholds[k - 1], "thresholds must increase")
		end
		up[k] = thresholds[k] * eta
	end
	return { thresholds = table.clone(thresholds), up = up, maxLevel = #thresholds, level = level or 0 }
end

-- Thresholds for levels that halve the resolution each step, with the texel
-- footprint r = base texels / screen pixels as input: level k + 1 is sufficient
-- from r = 2^(k+1).
function Saturn.halvingThresholds(levels: number): { number }
	local t = table.create(levels - 1, 0)
	local v = 1
	for k = 1, levels - 1 do
		v *= 2
		t[k] = v
	end
	return t
end

-- Updates the level for input x and returns it. (thresholds[k] is t_(k-1): Luau
-- arrays start at 1, so boundary k between levels k - 1 and k is index k.)
function Saturn.select(sel: Selector, x: number): number
	local L = sel.level
	local up, t = sel.up, sel.thresholds
	while L < sel.maxLevel and x >= up[L + 1] do
		L += 1
	end
	while L > 0 and x < t[L] do
		L -= 1
	end
	sel.level = L
	return L
end

----------------------------------------------------------------------------------
-- Crossfade
----------------------------------------------------------------------------------

local function smooth(v: number): number
	return MyMath.smoothstep(0, 1, v)
end

-- Opacities (lambda_old, lambda_new) at normalised time u (clamped to [0, 1]).
function Saturn.fadeOpacities(u: number): (number, number)
	if u <= 0 then
		return 1, 0
	elseif u >= 1 then
		return 0, 1
	elseif u <= 0.5 then
		return 1, smooth(2 * u)
	end
	return 1 - smooth(2 * u - 1), 1
end

-- Transparencies (old layer, new layer) at normalised time u: what engine code
-- writes to ImageTransparency / Decal.Transparency (1 - opacity).
function Saturn.fadeTransparencies(u: number): (number, number)
	local lo, ln = Saturn.fadeOpacities(u)
	return 1 - lo, 1 - ln
end

-- The composite of the stack at one pixel, for proofs and tests: straight-alpha
-- old (cA, aA) and new (cB, aB) layers with opacities lo, ln over a background
-- colour X with alpha aX (all 0..1). Returns premultiplied colour and alpha.
function Saturn.composite(cA: number, aA: number, cB: number, aB: number, lo: number, ln: number, X: number, aX: number): (number, number)
	local eA, eB = lo * aA, ln * aB
	local below = eA * cA + (1 - eA) * X * aX
	local belowA = eA + (1 - eA) * aX
	return eB * cB + (1 - eB) * below, eB + (1 - eB) * belowA
end

----------------------------------------------------------------------------------
-- Lod: selector + crossfade + two layer slots
----------------------------------------------------------------------------------

export type Lod = {
	sel: Selector,
	duration: number,
	slotLevel: { number }, -- level shown by slot 1 and slot 2 (-1: none)
	top: number, -- slot drawn on top (1 or 2)
	t0: number, -- start time of the running fade (-1: idle)
	fades: number, -- transitions started so far
}

-- A level-of-detail controller for one surface. thresholds and eta as for
-- Saturn.selector; duration: seconds per transition; x0: the first input (the
-- initial level is selected from it and shown at once, without a fade).
function Saturn.lod(thresholds: { number }, eta: number, duration: number, x0: number): Lod
	local sel = Saturn.selector(thresholds, eta, 0)
	local level = Saturn.select(sel, x0)
	return { sel = sel, duration = duration, slotLevel = { level, -1 }, top = 2, t0 = -1, fades = 0 }
end

-- Advances to time `now` with input x. ready(level) (optional) tells whether the
-- image of a level exists yet; a fade starts only when its level is ready.
-- Returns, for slot 1 and slot 2: level (-1: none), transparency; then the slot
-- that must be drawn on top. Engine code sets each slot's image to its level, its
-- ImageTransparency (or Decal.Transparency) and gives the top slot the higher
-- ZIndex; the top slot only changes while it is fully transparent (Z). A level
-- requested during a fade waits for the fade to finish (the selector keeps the
-- latest wish), so every frame lies on a continuous path (X1).
function Saturn.lodStep(lod: Lod, x: number, now: number, ready: ((number) -> boolean)?): (number, number, number, number, number)
	local want = Saturn.select(lod.sel, x)
	if lod.t0 >= 0 then
		local u = (now - lod.t0) / lod.duration
		if u < 1 then
			-- fading from the bottom slot (old) to the top slot (new)
			local tOld, tNew = Saturn.fadeTransparencies(u)
			local bottom = 3 - lod.top
			return lod.slotLevel[1], if bottom == 1 then tOld else tNew, lod.slotLevel[2], if bottom == 2 then tOld else tNew, lod.top
		end
		-- done: the top slot is opaque and the bottom one fully transparent
		lod.slotLevel[3 - lod.top] = -1
		lod.t0 = -1
	end
	-- idle: exactly one slot holds the shown level, at opacity 1
	local shownSlot = if lod.slotLevel[lod.top] >= 0 then lod.top else 3 - lod.top
	if want ~= lod.slotLevel[shownSlot] and (ready == nil or (ready :: (number) -> boolean)(want)) then
		-- start a fade: the empty (invisible) slot takes the new level and goes on top
		local incoming = 3 - shownSlot
		lod.slotLevel[incoming] = want
		lod.top = incoming
		lod.t0 = now
		lod.fades += 1
		return lod.slotLevel[1], if incoming == 1 then 1 else 0, lod.slotLevel[2], if incoming == 2 then 1 else 0, lod.top
	end
	return lod.slotLevel[1], if shownSlot == 1 then 0 else 1, lod.slotLevel[2], if shownSlot == 2 then 0 else 1, lod.top
end

return Saturn
