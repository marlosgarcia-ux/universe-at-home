--!strict
-- Universe at Home: Meadow :: Rings
--
-- Ring transitions for the grass (docs/DEMO.md section 3) on top of src/Saturn.luau:
-- LOD selection with hysteresis (Saturn.selector / Saturn.select) and the two-phase
-- crossfade (Saturn.fadeOpacities, Saturn.lod / Saturn.lodStep). Saturn is still being
-- written by another agent, so this adapter checks its API at load and falls back to
-- local implementations of the same rules (identical formulas, documented in
-- src/Saturn.luau: S1 and S2 for the selector, X1 to X3 and Z for the fade).
-- Rings.source tells the HUD which one is active.

local MyMath = require("../Universe/MyMath")

local Rings = {}

local okSaturn, SaturnOrError = pcall(function(): any
	return require("../Universe/Saturn")
end)
local Saturn: any = if okSaturn then SaturnOrError else nil
local usable = Saturn ~= nil
	and type(Saturn) == "table"
	and type(Saturn.selector) == "function"
	and type(Saturn.select) == "function"
	and type(Saturn.fadeOpacities) == "function"
	and type(Saturn.lod) == "function"
	and type(Saturn.lodStep) == "function"
Rings.source = if usable then "Saturn" else "demo/shared/Rings (Saturn unavailable)"
Rings.saturnError = if okSaturn then nil else tostring(SaturnOrError)

----------------------------------------------------------------------------------
-- Local implementations (used only without Saturn)
----------------------------------------------------------------------------------

export type Selector = { thresholds: { number }, up: { number }, maxLevel: number, level: number }
export type Lod = {
	sel: Selector,
	duration: number,
	slotLevel: { number },
	top: number,
	t0: number,
	fades: number,
}

local function selectorLocal(thresholds: { number }, eta: number, level: number?): Selector
	local up = table.create(#thresholds, 0)
	for k = 1, #thresholds do
		up[k] = thresholds[k] * eta
	end
	return { thresholds = table.clone(thresholds), up = up, maxLevel = #thresholds, level = level or 0 }
end

local function selectLocal(sel: Selector, x: number): number
	local L = sel.level
	while L < sel.maxLevel and x >= sel.up[L + 1] do
		L += 1
	end
	while L > 0 and x < sel.thresholds[L] do
		L -= 1
	end
	sel.level = L
	return L
end

local function fadeLocal(u: number): (number, number)
	if u <= 0 then
		return 1, 0
	elseif u >= 1 then
		return 0, 1
	elseif u <= 0.5 then
		return 1, MyMath.smoothstep(0, 1, 2 * u)
	end
	return 1 - MyMath.smoothstep(0, 1, 2 * u - 1), 1
end

local function lodLocal(thresholds: { number }, eta: number, duration: number, x0: number): Lod
	local sel = selectorLocal(thresholds, eta, 0)
	local level = selectLocal(sel, x0)
	return { sel = sel, duration = duration, slotLevel = { level, -1 }, top = 2, t0 = -1, fades = 0 }
end

local function lodStepLocal(lod: Lod, x: number, now: number, ready: ((number) -> boolean)?): (number, number, number, number, number)
	local want = selectLocal(lod.sel, x)
	if lod.t0 >= 0 then
		local u = (now - lod.t0) / lod.duration
		if u < 1 then
			local lo, ln = fadeLocal(u)
			local bottom = 3 - lod.top
			local tOld, tNew = 1 - lo, 1 - ln
			return lod.slotLevel[1], if bottom == 1 then tOld else tNew, lod.slotLevel[2], if bottom == 2 then tOld else tNew, lod.top
		end
		lod.slotLevel[3 - lod.top] = -1
		lod.t0 = -1
	end
	local shownSlot = if lod.slotLevel[lod.top] >= 0 then lod.top else 3 - lod.top
	if want ~= lod.slotLevel[shownSlot] and (ready == nil or (ready :: (number) -> boolean)(want)) then
		local incoming = 3 - shownSlot
		lod.slotLevel[incoming] = want
		lod.top = incoming
		lod.t0 = now
		lod.fades += 1
		return lod.slotLevel[1], if incoming == 1 then 1 else 0, lod.slotLevel[2], if incoming == 2 then 1 else 0, lod.top
	end
	return lod.slotLevel[1], if shownSlot == 1 then 0 else 1, lod.slotLevel[2], if shownSlot == 2 then 0 else 1, lod.top
end

----------------------------------------------------------------------------------
-- Public API (Saturn when usable)
----------------------------------------------------------------------------------

function Rings.selector(thresholds: { number }, eta: number, level: number?): Selector
	if usable then
		return Saturn.selector(thresholds, eta, level)
	end
	return selectorLocal(thresholds, eta, level)
end

function Rings.select(sel: Selector, x: number): number
	if usable then
		return Saturn.select(sel, x)
	end
	return selectLocal(sel, x)
end

-- (opacity of the old layer, opacity of the new layer) at normalised time u.
function Rings.fadeOpacities(u: number): (number, number)
	if usable then
		return Saturn.fadeOpacities(u)
	end
	return fadeLocal(u)
end

function Rings.lod(thresholds: { number }, eta: number, duration: number, x0: number): Lod
	if usable then
		return Saturn.lod(thresholds, eta, duration, x0)
	end
	return lodLocal(thresholds, eta, duration, x0)
end

-- Returns (level of slot 1, transparency of slot 1, level of slot 2, transparency of
-- slot 2, top slot). Level -1 means the slot shows nothing.
function Rings.lodStep(lod: Lod, x: number, now: number, ready: ((number) -> boolean)?): (number, number, number, number, number)
	if usable then
		return Saturn.lodStep(lod, x, now, ready)
	end
	return lodStepLocal(lod, x, now, ready)
end

-- Spatial version of the two-phase crossfade across a ring boundary at radius r with
-- a band of `width` studs inside it: u = 0 at r - width, 1 at r. Returns (opacity of
-- the inner ring's representation, opacity of the outer ring's representation): the
-- outer one is fully in before the inner one starts to leave (no gap, X2), so at no
-- distance does the grass thin out.
function Rings.boundary(d: number, r: number, width: number): (number, number)
	local u = (d - (r - width)) / width
	return Rings.fadeOpacities(u)
end

return Rings
