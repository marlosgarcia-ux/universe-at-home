--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Quadtree
--
-- Level-of-detail for a cube-sphere body, as pure logic (the client applies it to meshes
-- and atlases; the tests drive it through whole flights).
--
-- SELECT: the target cut. Starting from the six faces, the patch whose texels look largest
-- on screen is split first (a max-heap on that metric), until no patch's texel exceeds
-- `splitPx` pixels, the deepest level is reached, or the cut would exceed `capacity`
-- patches (the atlas has a fixed number of tiles). Splitting by the largest texel first
-- means a capacity limit always lands on the least visible detail. Patches entirely
-- behind the horizon are never split; patches outside the view frustum split far less.
-- Hysteresis: a patch split in the previous cut keeps its children until its metric falls
-- below splitPx / hysteresis, so a camera hovering at a threshold does not make detail
-- flicker.
--
-- PLAN: how to move the displayed cut towards the target without ever opening a hole.
-- Displayed patches always partition the sphere. A displayed patch whose region the target
-- wants finer is replaced by its four children, and only once all four are generated (one
-- level per step; deeper targets follow in later steps). Displayed patches whose region
-- the target wants coarser are replaced by that coarser patch once it is generated. Until
-- a replacement is ready the old patches stay. The client turns each swap into a two-phase
-- fade (new patches fade in over the old ones, then the old ones go).

local CubeSphere = require("./CubeSphere")
local Layout = require("./Layout")

local Quadtree = {}

export type View = {
	x: number, -- camera position, body-local studs
	y: number,
	z: number,
	dx: number, -- view direction (unit)
	dy: number,
	dz: number,
	tanHalfFov: number, -- tan of half the vertical field of view
	aspect: number, -- viewport width / height
	viewportH: number, -- pixels
}

export type Params = {
	radius: number,
	maxHeight: number, -- largest |height| anywhere (horizon reach, unknown patches)
	-- Height range (studs) of patches already generated; a patch without an entry uses its
	-- nearest generated ancestor's range (a superset), else +-maxHeight.
	heightLo: { [number]: number }?,
	heightHi: { [number]: number }?,
	capacity: number, -- most leaves in the cut
	splitPx: number, -- split while a texel would cover more pixels than this
	hysteresis: number, -- > 1
	maxLevel: number,
}

export type Selection = {
	leaves: { number }, -- patch keys, sorted
	split: { [number]: boolean }, -- interior nodes of the cut (hysteresis input next time)
	metric: { [number]: number }, -- leaf -> projected texel size in pixels
	deepest: number,
	hidden: number, -- leaves entirely behind the horizon
	limited: boolean, -- refinement stopped by capacity
}

export type Swap = { show: { number }, hide: { number } }
export type Plan = {
	generate: { number }, -- patches to generate, in the order to generate them
	merges: { [number]: boolean }, -- those that coarsen (each frees three or more tiles)
	-- every patch a pending step needs, generated or not: a child that is ready while its
	-- siblings are still generating must not be evicted (it would be regenerated forever)
	needed: { [number]: boolean },
	swaps: { Swap },
}

local sqrt, acos, atan, asin = math.sqrt, math.acos, math.atan, math.asin
local key, unkey = CubeSphere.key, CubeSphere.unkey

-- Angular radius (radians) that bounds a patch around its centre direction. Nowell's map
-- keeps patch edges within about 1.2x of the face-centre value; half the diagonal of that.
local function angularRadius(level: number): number
	return CubeSphere.patchAngle(level) * 0.9
end
Quadtree.angularRadius = angularRadius

-- Height range of a patch: its own if generated, else its nearest generated ancestor's.
local function heightRange(P: Params, f: number, L: number, i: number, j: number): (number, number)
	local lo, hi = P.heightLo, P.heightHi
	if lo and hi then
		local level, ii, jj = L, i, j
		while level >= 0 do
			local k = key(f, level, ii, jj)
			local a = lo[k]
			if a then
				return a, hi[k] or P.maxHeight
			end
			level -= 1
			ii //= 2
			jj //= 2
		end
	end
	return -P.maxHeight, P.maxHeight
end
Quadtree.heightRange = heightRange

-- Projected texel size (pixels) of a patch, and whether it is behind the horizon.
local function measure(f: number, L: number, i: number, j: number, v: View, P: Params, focal: number): (number, boolean)
	local R = P.radius
	local ux, uy, uz = CubeSphere.patchPoint(f, L, i, j, 0.5, 0.5)
	local rho = angularRadius(L)
	local lo, hi = heightRange(P, f, L, i, j)
	local mid = (lo + hi) * 0.5
	local br = (R + hi) * rho + (hi - lo) * 0.5 + 0.5 -- bounding sphere radius (studs)
	local px, py, pz = ux * (R + mid) - v.x, uy * (R + mid) - v.y, uz * (R + mid) - v.z
	local dist = sqrt(px * px + py * py + pz * pz)
	-- horizon: visible directions satisfy angle(u, cam) <= acos(R / D) plus the extra reach
	-- of the tallest relief, plus the patch's own angular radius
	local D = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if D > R then
		local c = (ux * v.x + uy * v.y + uz * v.z) / D
		if c > 1 then
			c = 1
		elseif c < -1 then
			c = -1
		end
		local horizon = acos(R / D) + acos(R / (R + P.maxHeight)) + rho
		if acos(c) > horizon then
			return 0, true
		end
	end
	local d = dist - br
	if d < 0.25 then
		d = 0.25
	end
	local texel = CubeSphere.patchAngle(L) * R / Layout.SPAN * 1.2
	local metric = texel / d * focal
	-- frustum: patches whose bounding sphere lies outside the view cone stay coarse
	if dist > br then
		local cosA = (px * v.dx + py * v.dy + pz * v.dz) / dist
		if cosA > 1 then
			cosA = 1
		elseif cosA < -1 then
			cosA = -1
		end
		local half = atan(v.tanHalfFov * sqrt(1 + v.aspect * v.aspect))
		local spread = asin(br / dist)
		if acos(cosA) > half + spread then
			metric *= 0.15
		end
	end
	return metric, false
end
Quadtree.measure = measure

function Quadtree.select(v: View, P: Params, wasSplit: { [number]: boolean }?): Selection
	local focal = v.viewportH / (2 * v.tanHalfFov)
	local prev = wasSplit or {}
	-- max-heap of (effective metric, key)
	local hk: { number } = {}
	local hp: { number } = {}
	local hn = 0
	local function push(k: number, p: number)
		hn += 1
		local n = hn
		while n > 1 do
			local parent = n // 2
			if hp[parent] >= p then
				break
			end
			hk[n], hp[n] = hk[parent], hp[parent]
			n = parent
		end
		hk[n], hp[n] = k, p
	end
	local function pop(): (number, number)
		local topK, topP = hk[1], hp[1]
		local lastK, lastP = hk[hn], hp[hn]
		hk[hn], hp[hn] = nil :: any, nil :: any
		hn -= 1
		if hn > 0 then
			local n = 1
			while true do
				local c = n * 2
				if c > hn then
					break
				end
				if c < hn and hp[c + 1] > hp[c] then
					c += 1
				end
				if hp[c] <= lastP then
					break
				end
				hk[n], hp[n] = hk[c], hp[c]
				n = c
			end
			hk[n], hp[n] = lastK, lastP
		end
		return topK, topP
	end

	local leaves: { [number]: boolean } = {}
	local metric: { [number]: number } = {}
	local split: { [number]: boolean } = {}
	local hidden: { [number]: boolean } = {}
	local count = 0
	local function add(f: number, L: number, i: number, j: number)
		local k = key(f, L, i, j)
		local m, h = measure(f, L, i, j, v, P, focal)
		leaves[k] = true
		metric[k] = m
		hidden[k] = h
		count += 1
		if not h and L < P.maxLevel then
			push(k, if prev[k] then m * P.hysteresis else m)
		end
	end
	for f = 1, 6 do
		add(f, 0, 0, 0)
	end
	local limited = false
	while hn > 0 do
		local k, p = pop()
		if p < P.splitPx then
			break
		end
		if count + 3 > P.capacity then
			limited = true
			break
		end
		local f, L, i, j = unkey(k)
		leaves[k] = nil
		metric[k] = nil
		hidden[k] = nil
		count -= 1
		split[k] = true
		for c = 0, 3 do
			add(f, L + 1, 2 * i + c % 2, 2 * j + c // 2)
		end
	end
	local list: { number } = {}
	local deepest, nHidden = 0, 0
	for k in leaves do
		table.insert(list, k)
		local _, L = unkey(k)
		if L > deepest then
			deepest = L
		end
		if hidden[k] then
			nHidden += 1
		end
	end
	table.sort(list)
	return { leaves = list, split = split, metric = metric, deepest = deepest, hidden = nHidden, limited = limited }
end

function Quadtree.parent(k: number): number?
	local f, L, i, j = unkey(k)
	if L == 0 then
		return nil
	end
	return key(f, L - 1, i // 2, j // 2)
end

function Quadtree.children(k: number): { number }
	local f, L, i, j = unkey(k)
	return {
		key(f, L + 1, 2 * i, 2 * j),
		key(f, L + 1, 2 * i + 1, 2 * j),
		key(f, L + 1, 2 * i, 2 * j + 1),
		key(f, L + 1, 2 * i + 1, 2 * j + 1),
	}
end

-- True when `a` is a strict ancestor of `b`.
function Quadtree.isAncestor(a: number, b: number): boolean
	local fa, La, ia, ja = unkey(a)
	local fb, Lb, ib, jb = unkey(b)
	if fa ~= fb or La >= Lb then
		return false
	end
	local shift = Lb - La
	local s = math.ldexp(1, -shift)
	return (ib * s) // 1 == ia and (jb * s) // 1 == ja
end

-- Area of a patch in face units (a whole face is 1): the partition invariant sums these.
function Quadtree.area(k: number): number
	local _, L = unkey(k)
	return math.ldexp(1, -2 * L)
end

-- Next steps from `displayed` (a partition of the sphere) towards `target` (another one).
-- `ready` holds generated patches. `priority` orders the generation list (higher first).
-- With `pressure` (few free atlas tiles) every coarsening comes before any refinement:
-- a coarsening costs one tile and frees at least four, while refinements near the camera
-- would otherwise always outrank the distant coarsenings and starve them.
function Quadtree.plan(displayed: { [number]: boolean }, ready: { [number]: boolean }, target: { number }, priority: { [number]: number }?, pressure: boolean?): Plan
	local generate: { number } = {}
	local wanted: { [number]: number } = {}
	local merges: { [number]: boolean } = {}
	local needed: { [number]: boolean } = {}
	local swaps: { Swap } = {}
	local splitDone: { [number]: boolean } = {}
	local mergeDone: { [number]: boolean } = {}
	local function want(k: number, p: number)
		local old = wanted[k]
		if old == nil then
			wanted[k] = p
			table.insert(generate, k)
		elseif p > old then
			wanted[k] = p
		end
	end
	-- displayed descendants per ancestor (for merges), built lazily
	local below: { [number]: { number } }? = nil
	local function descendantsOf(t: number): { number }
		if not below then
			local map: { [number]: { number } } = {}
			for d in displayed do
				local a = Quadtree.parent(d)
				while a do
					local list = map[a]
					if not list then
						list = {}
						map[a] = list
					end
					table.insert(list, d)
					a = Quadtree.parent(a)
				end
			end
			below = map
		end
		return (below :: { [number]: { number } })[t] or {}
	end
	for _, t in target do
		if not displayed[t] then
			local p = if priority then priority[t] or 0 else 0
			-- a displayed ancestor: refine it by one level
			local a = Quadtree.parent(t)
			while a and not displayed[a] do
				a = Quadtree.parent(a)
			end
			if a then
				if not splitDone[a] then
					local kids = Quadtree.children(a)
					local all = true
					for _, c in kids do
						needed[c] = true
						if not ready[c] then
							all = false
							want(c, p)
						end
					end
					if all then
						splitDone[a] = true
						table.insert(swaps, { show = kids, hide = { a } })
					end
				else
					-- already swapping this ancestor
				end
			else
				-- displayed descendants: coarsen to t
				if not mergeDone[t] then
					needed[t] = true
					if ready[t] then
						mergeDone[t] = true
						table.insert(swaps, { show = { t }, hide = descendantsOf(t) })
					else
						want(t, p)
						merges[t] = true
					end
				end
			end
		end
	end
	-- higher priority first (coarsenings first under pressure); ties by key
	table.sort(generate, function(x: number, y: number): boolean
		if pressure then
			local mx, my = merges[x] == true, merges[y] == true
			if mx ~= my then
				return mx
			end
		end
		local px, py = wanted[x], wanted[y]
		if px ~= py then
			return px > py
		end
		return x < y
	end)
	return { generate = generate, merges = merges, needed = needed, swaps = swaps }
end

-- Applies a swap to a displayed set (helper for the client and the tests).
function Quadtree.apply(displayed: { [number]: boolean }, swap: Swap)
	for _, k in swap.hide do
		displayed[k] = nil
	end
	for _, k in swap.show do
		displayed[k] = true
	end
end

return Quadtree
