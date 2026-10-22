--!strict
-- Tests for planets/shared/Quadtree: the target cut and the hole-free plan, driven through
-- whole flights. Run by tests/run.sh in the interpreter and with native code.

local Quadtree = require("../planets/shared/Quadtree")
local CubeSphere = require("../planets/shared/CubeSphere")
local Layout = require("../planets/shared/Layout")

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local R = 1600
local PARAMS: Quadtree.Params = {
	radius = R,
	maxHeight = 90,
	capacity = 200,
	splitPx = 1.6,
	hysteresis = 1.35,
	maxLevel = 11,
}

local function view(x: number, y: number, z: number, tx: number, ty: number, tz: number): Quadtree.View
	local dx, dy, dz = tx - x, ty - y, tz - z
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	return {
		x = x,
		y = y,
		z = z,
		dx = dx / l,
		dy = dy / l,
		dz = dz / l,
		tanHalfFov = math.tan(math.rad(35)),
		aspect = 16 / 9,
		viewportH = 1080,
	}
end

-- A set of patches partitions the sphere: areas sum to six faces exactly (dyadic sums are
-- exact in doubles) and no patch contains another.
local function partition(set: { [number]: boolean }): (boolean, string)
	local area = 0
	local n = 0
	for k in set do
		area += Quadtree.area(k)
		n += 1
		local a = Quadtree.parent(k)
		while a do
			if set[a] then
				return false, "patch and its ancestor both present"
			end
			a = Quadtree.parent(a)
		end
	end
	if area ~= 6 then
		return false, "area " .. area .. " over " .. n .. " patches"
	end
	return true, "ok"
end

local function asSet(list: { number }): { [number]: boolean }
	local s = {}
	for _, k in list do
		s[k] = true
	end
	return s
end

-- 1. orbit: the whole planet in view, moderate levels, far side hidden
do
	local sel = Quadtree.select(view(0, 0, 6 * R, 0, 0, 0), PARAMS)
	local ok, msg = partition(asSet(sel.leaves))
	check(ok, "orbit cut partitions the sphere: " .. msg)
	check(#sel.leaves <= PARAMS.capacity, "orbit cut within capacity")
	check(sel.deepest >= 2 and sel.deepest <= 6, "orbit detail is moderate (deepest " .. sel.deepest .. ")")
	check(sel.hidden > 0, "the far side is behind the horizon")
end

-- Height ranges as the client knows them once patches exist: here a flat plain at 0..2
-- studs around the camera's face (+Z), recorded on the six roots (their descendants
-- inherit it).
local flatLo: { [number]: number } = {}
local flatHi: { [number]: number } = {}
for f = 1, 6 do
	flatLo[CubeSphere.key(f, 0, 0, 0)] = if f == 5 then 0 else -90
	flatHi[CubeSphere.key(f, 0, 0, 0)] = if f == 5 then 2 else 90
end
local KNOWN: Quadtree.Params = table.clone(PARAMS)
KNOWN.heightLo = flatLo
KNOWN.heightHi = flatHi

-- 2. ten studs above the ground, looking along the surface: full depth near the camera
local lowSel: Quadtree.Selection
do
	local h = R + 10
	local sel = Quadtree.select(view(0, 0, h, 400, 0, h - 30), KNOWN)
	lowSel = sel
	local ok, msg = partition(asSet(sel.leaves))
	check(ok, "low cut partitions the sphere: " .. msg)
	check(#sel.leaves <= PARAMS.capacity, "low cut within capacity (" .. #sel.leaves .. ")")
	check(sel.deepest >= 9, "full detail near the camera (deepest " .. sel.deepest .. ")")
	-- the patch under the camera is among the deepest
	local below = 0
	for _, k in sel.leaves do
		local f, L, i, j = CubeSphere.unkey(k)
		local _, _, z = CubeSphere.patchPoint(f, L, i, j, 0.5, 0.5)
		if z > 0.999 and L >= sel.deepest - 1 then
			below += 1
		end
	end
	check(below > 0, "deep patches sit under the camera")
end

-- 3. capacity bounds the cut and is reported
do
	local P2 = table.clone(KNOWN)
	P2.capacity = 40
	local sel = Quadtree.select(view(0, 0, R + 10, 400, 0, R - 20), P2)
	check(#sel.leaves <= 40 and sel.limited, "a small atlas limits the cut (" .. #sel.leaves .. ")")
	local ok = partition(asSet(sel.leaves))
	check(ok, "limited cut still partitions the sphere")
end

-- 4. hysteresis: hovering at a threshold does not flicker
do
	local base = R + 300
	local split: { [number]: boolean }? = nil
	local seen: { [string]: boolean } = {}
	local distinct = 0
	for step = 1, 40 do
		local z = base + (if step % 2 == 0 then 0.6 else -0.6)
		local sel = Quadtree.select(view(0, 0, z, 0, 0, 0), PARAMS, split)
		split = sel.split
		local sig = table.concat(sel.leaves, ",")
		if not seen[sig] then
			seen[sig] = true
			distinct += 1
		end
	end
	check(distinct <= 2, "a hovering camera settles on one cut (" .. distinct .. " distinct)")
end

-- 5. the plan converges to the target without ever opening a hole
do
	local displayed: { [number]: boolean } = {}
	for f = 1, 6 do
		displayed[CubeSphere.key(f, 0, 0, 0)] = true
	end
	local ready: { [number]: boolean } = {}
	for k in displayed do
		ready[k] = true
	end
	local target = lowSel.leaves
	local rounds = 0
	local converged = false
	for round = 1, 400 do
		rounds = round
		local plan = Quadtree.plan(displayed, ready, target, lowSel.metric)
		-- generate up to 8 tiles per round, highest priority first
		for g = 1, math.min(8, #plan.generate) do
			ready[plan.generate[g]] = true
		end
		for _, swap in plan.swaps do
			Quadtree.apply(displayed, swap)
			local ok, msg = partition(displayed)
			if not ok then
				check(false, "a swap opened a hole or an overlap: " .. msg)
			end
		end
		local same = true
		for _, k in target do
			if not displayed[k] then
				same = false
				break
			end
		end
		if same then
			converged = true
			break
		end
	end
	check(converged, "the displayed cut reaches the target (" .. rounds .. " rounds)")
	local n = 0
	for _ in displayed do
		n += 1
	end
	check(n == #target, "displayed equals the target")
end

-- 6. a whole flight: orbit to ten studs and back, generation throughput of 6 tiles per
-- frame, unused tiles evicted. The displayed cut is a partition every frame and the tiles
-- in use (displayed or generated and still wanted) never exceed the atlas.
do
	local displayed: { [number]: boolean } = {}
	for f = 1, 6 do
		displayed[CubeSphere.key(f, 0, 0, 0)] = true
	end
	local ready: { [number]: boolean } = table.clone(displayed)
	local split: { [number]: boolean }? = nil
	local peak = 0
	local frames = 240
	local swapsDone = 0
	for frame = 0, frames do
		-- distance from the centre: 8R down to R + 10 and back up (log scale)
		local u = frame / frames
		local w = if u < 0.5 then u * 2 else (1 - u) * 2
		local alt = 7 * R * (10 / (7 * R)) ^ w
		local ang = u * 0.6
		local cx, cz = math.sin(ang) * (R + alt), math.cos(ang) * (R + alt)
		local v = view(cx, 0, cz, 0, 0, 0)
		if alt < 200 then
			-- near the ground, look ahead along the surface
			v = view(cx, 0, cz, cx + math.cos(ang) * 300, 20, cz - math.sin(ang) * 300)
		end
		local sel = Quadtree.select(v, PARAMS, split)
		split = sel.split
		-- tiles in use: generated ones plus displayed ones (always generated)
		local function inUseNow(): number
			local n = 0
			for _ in ready do
				n += 1
			end
			return n
		end
		local free = Layout.SLOTS - inUseNow()
		local plan = Quadtree.plan(displayed, ready, sel.leaves, sel.metric, free < 32)
		local made = 0
		for g = 1, #plan.generate do
			if made >= 6 or Layout.SLOTS - inUseNow() <= 0 then
				break
			end
			if not ready[plan.generate[g]] then
				ready[plan.generate[g]] = true
				made += 1
			end
		end
		-- swaps found this frame (re-plan so the tiles just generated count)
		plan = Quadtree.plan(displayed, ready, sel.leaves, sel.metric, Layout.SLOTS - inUseNow() < 32)
		for _, swap in plan.swaps do
			Quadtree.apply(displayed, swap)
			swapsDone += 1
		end
		local ok, msg = partition(displayed)
		if not ok then
			check(false, "frame " .. frame .. ": " .. msg)
		end
		-- evict generated tiles that are neither displayed nor needed by a pending step
		local wanted = plan.needed
		for k in ready do
			if not displayed[k] and not wanted[k] then
				ready[k] = nil
			end
		end
		local inUse = 0
		for _ in ready do
			inUse += 1
		end
		for k in displayed do
			if not ready[k] then
				inUse += 1
			end
		end
		if inUse > peak then
			peak = inUse
		end
	end
	check(swapsDone > 50, "the flight refines and coarsens (" .. swapsDone .. " swaps)")
	check(peak <= Layout.SLOTS, "tiles in use never exceed the atlas (peak " .. peak .. " of " .. Layout.SLOTS .. ")")
	print(string.format("flight: %d swaps, peak %d tiles in use of %d", swapsDone, peak, Layout.SLOTS))
end

-- 7. ancestry helpers
do
	local a = CubeSphere.key(3, 2, 1, 2)
	local b = CubeSphere.key(3, 5, 8 + 3, 16 + 5)
	check(Quadtree.isAncestor(a, b), "ancestor found")
	check(not Quadtree.isAncestor(b, a), "a descendant is not an ancestor")
	check(not Quadtree.isAncestor(a, CubeSphere.key(4, 5, 11, 21)), "other faces are unrelated")
	local kids = Quadtree.children(a)
	for _, k in kids do
		check(Quadtree.parent(k) == a, "children's parent")
	end
end

print("planets_lod: " .. checks .. " checks passed")
