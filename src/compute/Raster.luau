--!native
--!optimize 2
-- universe-at-home :: compute/Raster
--
-- Scene rasterizer for hundreds of anti-aliased 2D shapes (circles, rounded boxes,
-- capsules, rings, polygons, cut discs: half-discs and pie slices) composited
-- bottom to top with straight-alpha source-over. Three renderers share one
-- per-pixel shading routine:
--
--   renderBrute    every shape at every pixel (the reference)
--   renderPainter  every shape over its own bounding box, 8-bit read-modify-write
--                  (what an engine DrawCircle loop does; not bit-identical)
--   render         shape bins per 64 x 64 tile, then a Lipschitz quadtree per tile:
--                  shapes that cannot touch a node are dropped, the topmost opaque
--                  shape that covers a node entirely becomes its base and hides
--                  everything below, nodes whose remaining shapes all cover them
--                  entirely are filled with buffer.copy, and only leaves that an
--                  edge crosses are shaded per pixel.
--
-- render is pixel-identical to renderBrute by construction (docs/COMPUTE.md, C2):
-- a dropped shape has coverage exactly 0 at every pixel of the node, a base shape
-- has coverage exactly 1 and alpha 255, and the per-pixel arithmetic is the same
-- function with the same operand order (including the exact-visibility path below,
-- whose inputs are the same per-pixel stack in both renderers).
--
-- Coverage modes (docs/COMPUTE.md 3.3 and "Flawless pipeline"):
--   MODE_EXACT   (the DEFAULT) flawless. F1: every coverage is the exact area of
--                the pixel inside the shape: disc areas by quadrant integration
--                (circles, ring edges, rounded-box corners), products of 1D
--                overlaps (boxes), the exact capsule decomposition (body = pixel
--                clipped by the end lines and the strip sides; caps = disc and
--                pixel clipped by the end line), disc and clipped pixel (cut discs),
--                per-edge Green integrals (polygons, any number of edges per pixel).
--                F2: where two or more shapes' edges enter a pixel ("conflict
--                pixels") the composite is computed with exact visibility
--                (compute/Visibility.luau) instead of chaining coverage as alpha,
--                so abutting shapes leave no seam (C11). Elsewhere coverage as alpha
--                is exact. Culling reach is sqrt(2)/2 AA widths (C4).
--   MODE_LAYERED exact coverage (F1) composited as alpha everywhere: shows the
--                conflation seam at shared edges (kept for comparison and cost).
--   MODE_LINEAR  clamp(0.5 - d / aa, 0, 1), MyMath.coverage: the PREVIEW ramp.
--                Exact only on axis-aligned edges: up to 10.94/255 on a 45 degree
--                edge (C3), 38/255 at sharp box corners, 26 to 83/255 at star tips.
--
-- Deterministic ops only: + - * / sqrt abs floor, comparisons and the
-- deterministic arcsine Coverage.dasin (RUNTIME_AUDIT 6.5).

local Pixels = require("../Pixels")
local MyMath = require("../MyMath")
local Coverage = require("./Coverage")
local Visibility = require("./Visibility")

local Raster = {}

local CIRCLE, BOX, SEGMENT, RING, POLYGON, CUTDISC = 1, 2, 3, 4, 5, 6
Raster.CIRCLE, Raster.BOX, Raster.SEGMENT, Raster.RING, Raster.POLYGON = CIRCLE, BOX, SEGMENT, RING, POLYGON
Raster.CUTDISC = CUTDISC
local MODE_LINEAR, MODE_EXACT, MODE_LAYERED = 0, 1, 2
Raster.MODE_LINEAR, Raster.MODE_EXACT, Raster.MODE_LAYERED = MODE_LINEAR, MODE_EXACT, MODE_LAYERED

export type Scene = {
	n: number,
	kind: { number },
	p1: { number },
	p2: { number },
	p3: { number },
	p4: { number },
	p5: { number },
	p6: { number },
	cr: { number },
	cg: { number },
	cb: { number },
	ca: { number },
	bx0: { number },
	by0: { number },
	bx1: { number },
	by1: { number },
	verts: { number }, -- polygon vertices; cut-disc half-planes (n1x, n1y, o1, n2x, n2y, o2)
	aa: number, -- anti-aliasing (box filter) width in pixels
	mode: number, -- MODE_EXACT (default), MODE_LAYERED or MODE_LINEAR
	bgR: number,
	bgG: number,
	bgB: number,
	bgA: number, -- 0..1
}

export type Bins = {
	tile: number,
	tilesX: number,
	tilesY: number,
	lists: { { number } },
}

export type Stats = { nodes: number, uniform: number, leaves: number, shaded: number, evals: number, conflicts: number }

local stats: Stats = { nodes = 0, uniform = 0, leaves = 0, shaded = 0, evals = 0, conflicts = 0 }
Raster.stats = stats

function Raster.resetStats()
	stats.nodes, stats.uniform, stats.leaves, stats.shaded, stats.evals, stats.conflicts = 0, 0, 0, 0, 0, 0
end

----------------------------------------------------------------------------------
-- Scene construction
----------------------------------------------------------------------------------

function Raster.newScene(background: number, aa: number?, mode: number?): Scene
	local r, g, b, a = MyMath.unpack(background)
	return {
		n = 0,
		kind = {},
		p1 = {},
		p2 = {},
		p3 = {},
		p4 = {},
		p5 = {},
		p6 = {},
		cr = {},
		cg = {},
		cb = {},
		ca = {},
		bx0 = {},
		by0 = {},
		bx1 = {},
		by1 = {},
		verts = {},
		aa = aa or 1,
		mode = mode or MODE_EXACT,
		bgR = r,
		bgG = g,
		bgB = b,
		bgA = a / 255,
	}
end

local function push(sc: Scene, kind: number, color: number, a: number, b: number, c: number, d: number, e: number, f: number): number
	local n = sc.n + 1
	sc.n = n
	sc.kind[n] = kind
	sc.p1[n], sc.p2[n], sc.p3[n], sc.p4[n], sc.p5[n], sc.p6[n] = a, b, c, d, e, f
	local r, g, bl, al = MyMath.unpack(color)
	sc.cr[n], sc.cg[n], sc.cb[n], sc.ca[n] = r, g, bl, al
	return n
end

-- Recomputes the conservative pixel bounding box of shape s (pixels whose centre
-- can have nonzero coverage).
local function updateBounds(sc: Scene, s: number)
	local k = sc.kind[s]
	-- coverage can be nonzero up to half an AA width (linear) or sqrt(2)/2 (exact)
	local h = sc.aa * (if sc.mode ~= MODE_LINEAR then 0.70710678118654757 else 0.5)
	local x0, y0, x1, y1 = 0, 0, 0, 0
	if k == CIRCLE or k == CUTDISC then
		local r = sc.p3[s] + h
		x0, y0, x1, y1 = sc.p1[s] - r, sc.p2[s] - r, sc.p1[s] + r, sc.p2[s] + r
	elseif k == BOX then
		x0, y0 = sc.p1[s] - sc.p3[s] - h, sc.p2[s] - sc.p4[s] - h
		x1, y1 = sc.p1[s] + sc.p3[s] + h, sc.p2[s] + sc.p4[s] + h
	elseif k == SEGMENT then
		local r = sc.p5[s] + h
		local ax, ay = sc.p1[s], sc.p2[s]
		local bx, by = ax + sc.p3[s], ay + sc.p4[s]
		x0, x1 = math.min(ax, bx) - r, math.max(ax, bx) + r
		y0, y1 = math.min(ay, by) - r, math.max(ay, by) + r
	elseif k == RING then
		local r = sc.p3[s] + sc.p4[s] + h
		x0, y0, x1, y1 = sc.p1[s] - r, sc.p2[s] - r, sc.p1[s] + r, sc.p2[s] + r
	else
		local v = sc.verts
		local first, count = sc.p1[s], sc.p2[s]
		x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		for i = first, first + 2 * count - 2, 2 do
			local vx: number, vy: number = v[i], v[i + 1]
			if vx < x0 then
				x0 = vx
			end
			if vx > x1 then
				x1 = vx
			end
			if vy < y0 then
				y0 = vy
			end
			if vy > y1 then
				y1 = vy
			end
		end
		x0, y0, x1, y1 = x0 - h, y0 - h, x1 + h, y1 + h
	end
	-- pixel x has centre x + 0.5; keep every pixel whose centre lies in [x0, x1]
	sc.bx0[s] = math.floor(x0 - 0.5)
	sc.by0[s] = math.floor(y0 - 0.5)
	sc.bx1[s] = math.ceil(x1 - 0.5)
	sc.by1[s] = math.ceil(y1 - 0.5)
end
Raster.updateBounds = updateBounds

function Raster.circle(sc: Scene, color: number, cx: number, cy: number, r: number): number
	local s = push(sc, CIRCLE, color, cx, cy, r, 0, 0, 0)
	updateBounds(sc, s)
	return s
end

-- Axis-aligned box centred at (cx, cy), half extents (hx, hy), corner radius rad
-- (clamped to [0, min(hx, hy)], where the rounded-box SDF is exact).
function Raster.box(sc: Scene, color: number, cx: number, cy: number, hx: number, hy: number, rad: number): number
	local m = if hx < hy then hx else hy
	if rad > m then
		rad = m
	elseif rad < 0 then
		rad = 0
	end
	local s = push(sc, BOX, color, cx, cy, hx, hy, rad, 0)
	updateBounds(sc, s)
	return s
end

-- Capsule from (ax, ay) to (bx, by) with radius r.
function Raster.segment(sc: Scene, color: number, ax: number, ay: number, bx: number, by: number, r: number): number
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local s = push(sc, SEGMENT, color, ax, ay, dx, dy, r, if len2 > 0 then 1 / len2 else 0)
	updateBounds(sc, s)
	return s
end

-- Annulus: |distance to centre - r| <= t.
function Raster.ring(sc: Scene, color: number, cx: number, cy: number, r: number, t: number): number
	local s = push(sc, RING, color, cx, cy, r, t, 0, 0)
	updateBounds(sc, s)
	return s
end

-- Polygon from flat {x1, y1, x2, y2, ...}; exact distance with the even-odd sign.
-- p3 holds the orientation (sign of the shoelace area). Exact coverage (F1, F2)
-- assumes a simple (non-self-intersecting) polygon.
function Raster.polygon(sc: Scene, color: number, pts: { number }): number
	local v = sc.verts
	local first = #v + 1
	for i = 1, #pts do
		v[first + i - 1] = pts[i]
	end
	local area = 0
	local n = #pts // 2
	local jx, jy = pts[2 * n - 1], pts[2 * n]
	for i = 1, n do
		local ix, iy = pts[2 * i - 1], pts[2 * i]
		area += jx * iy - ix * jy
		jx, jy = ix, iy
	end
	local s = push(sc, POLYGON, color, first, n, if area >= 0 then 1 else -1, 0, 0, 0)
	updateBounds(sc, s)
	return s
end

-- Cut disc: the disc (cx, cy, r) intersected with up to two half-planes
-- {q : n . (q - c) <= o}, normals (n1x, n1y) and (n2x, n2y) of unit length. With
-- one half-plane it is a circular segment (o = 0: a half-disc); with two through
-- the centre it is a pie slice. A convex primitive whose pieces abut exactly when
-- neighbours pass bit-identical normals with opposite signs (negation is exact).
function Raster.cutDisc(
	sc: Scene,
	color: number,
	cx: number,
	cy: number,
	r: number,
	n1x: number,
	n1y: number,
	o1: number,
	n2x: number?,
	n2y: number?,
	o2: number?
): number
	local v = sc.verts
	local first = #v + 1
	v[first], v[first + 1], v[first + 2] = n1x, n1y, o1
	if n2x and n2y then
		v[first + 3], v[first + 4], v[first + 5] = n2x, n2y, o2 or 0
	else
		-- no second half-plane: zero normal, always satisfied (its distance is -1e300)
		v[first + 3], v[first + 4], v[first + 5] = 0, 0, 1e300
	end
	local s = push(sc, CUTDISC, color, cx, cy, r, first, if n2x and n2y then 2 else 1, 0)
	updateBounds(sc, s)
	return s
end

-- Half-disc: the half of the disc on the side opposite to the unit vector (nx, ny),
-- {q : n . (q - c) <= 0}. Its partner is halfDisc with (-nx, -ny).
function Raster.halfDisc(sc: Scene, color: number, cx: number, cy: number, r: number, nx: number, ny: number): number
	return Raster.cutDisc(sc, color, cx, cy, r, nx, ny, 0)
end

-- Pie slice from the unit direction (ax, ay) to the unit direction (bx, by), turning
-- the way that takes x towards y (counter-clockwise in a y-up frame), at most half
-- a turn: {cross(a, q - c) >= 0} and {cross(q - c, b) >= 0}. Slices that share a
-- boundary direction (the same numbers) abut exactly.
function Raster.pie(sc: Scene, color: number, cx: number, cy: number, r: number, ax: number, ay: number, bx: number, by: number): number
	return Raster.cutDisc(sc, color, cx, cy, r, ay, -ax, 0, -by, bx, 0)
end

-- Moves shape s by (dx, dy) pixels.
function Raster.move(sc: Scene, s: number, dx: number, dy: number)
	local k = sc.kind[s]
	if k == POLYGON then
		local v = sc.verts
		for i = sc.p1[s], sc.p1[s] + 2 * sc.p2[s] - 2, 2 do
			v[i] += dx
			v[i + 1] += dy
		end
	else
		sc.p1[s] += dx
		sc.p2[s] += dy
	end
	updateBounds(sc, s)
end

-- A copy of the scene with every length multiplied by f, for rendering a level of
-- detail directly at its own resolution: the AA width stays one output pixel, so
-- every level is the exact box filter of the vector source at that level (F1/F2
-- hold per level; docs/COMPUTE.md "Flawless pipeline", LOD).
function Raster.scaled(sc: Scene, f: number): Scene
	local out = Raster.newScene(0, sc.aa, sc.mode)
	out.bgR, out.bgG, out.bgB, out.bgA = sc.bgR, sc.bgG, sc.bgB, sc.bgA
	for i = 1, #sc.verts do
		out.verts[i] = sc.verts[i]
	end
	for s = 1, sc.n do
		local k = sc.kind[s]
		out.n = s
		out.kind[s] = k
		out.cr[s], out.cg[s], out.cb[s], out.ca[s] = sc.cr[s], sc.cg[s], sc.cb[s], sc.ca[s]
		if k == POLYGON then
			out.p1[s], out.p2[s], out.p3[s], out.p4[s], out.p5[s], out.p6[s] = sc.p1[s], sc.p2[s], sc.p3[s], 0, 0, 0
			local first = sc.p1[s]
			for i = first, first + 2 * sc.p2[s] - 1 do
				out.verts[i] = sc.verts[i] * f
			end
		elseif k == CUTDISC then
			out.p1[s], out.p2[s], out.p3[s], out.p4[s], out.p5[s], out.p6[s] = sc.p1[s] * f, sc.p2[s] * f, sc.p3[s] * f, sc.p4[s], sc.p5[s], 0
			local i = sc.p4[s]
			-- normals stay, offsets scale (the always-true second plane stays 1)
			out.verts[i + 2] = sc.verts[i + 2] * f
			if sc.p5[s] == 2 then
				out.verts[i + 5] = sc.verts[i + 5] * f
			end
		elseif k == SEGMENT then
			out.p1[s], out.p2[s], out.p3[s], out.p4[s], out.p5[s] = sc.p1[s] * f, sc.p2[s] * f, sc.p3[s] * f, sc.p4[s] * f, sc.p5[s] * f
			local len2 = out.p3[s] * out.p3[s] + out.p4[s] * out.p4[s]
			out.p6[s] = if len2 > 0 then 1 / len2 else 0
		else
			out.p1[s], out.p2[s], out.p3[s], out.p4[s], out.p5[s], out.p6[s] =
				sc.p1[s] * f, sc.p2[s] * f, sc.p3[s] * f, sc.p4[s] * f, sc.p5[s] * f, 0
		end
		updateBounds(out, s)
	end
	return out
end

-- Deterministic demo scene: n shapes on a size x size canvas. Mixes every kind,
-- radii from 2 to 60 px at 1024 (scaled with size), one in four translucent.
function Raster.demoScene(n: number, size: number, seed: number, background: number?, mode: number?): Scene
	local sc = Raster.newScene(background or 0xFF201810, 1, mode)
	local f = size / 1024
	local hash = MyMath.hash32
	local h = hash(seed)
	local function rnd(): number
		h = hash((h + 0x9E3779B9) % 4294967296)
		return h / 4294967296
	end
	for i = 1, n do
		local kind = 1 + (rnd() * 5) // 1
		-- quantise positions to 1/16 px so a scaled scene stays exact at power-of-two sizes
		local cx = ((rnd() * 1024 * 16) // 1) / 16 * f
		local cy = ((rnd() * 1024 * 16) // 1) / 16 * f
		local big = if i <= n // 16 then 4 else 1 -- a few large shapes give occlusion
		local r = (2 + rnd() * 58) * big * f
		local alpha = if rnd() < 0.25 then 96 + (rnd() * 150) // 1 else 255
		local color = ((rnd() * 0xFFFFFF) // 1) + alpha * 16777216
		if kind == CIRCLE then
			Raster.circle(sc, color, cx, cy, r)
		elseif kind == BOX then
			Raster.box(sc, color, cx, cy, r, r * (0.3 + rnd()), r * 0.25)
		elseif kind == SEGMENT then
			local ang = rnd()
			local len = r * 2
			Raster.segment(sc, color, cx, cy, cx + MyMath.dcosTurns(ang) * len, cy + MyMath.dsinTurns(ang) * len, 1 + r * 0.15)
		elseif kind == RING then
			Raster.ring(sc, color, cx, cy, r, 1 + r * 0.1)
		else
			-- five-point star
			local pts = table.create(20, 0)
			local rot = rnd()
			for k = 0, 9 do
				local rr = if k % 2 == 0 then r else r * 0.45
				local t = rot + k / 10
				pts[2 * k + 1] = cx + MyMath.dcosTurns(t) * rr
				pts[2 * k + 2] = cy + MyMath.dsinTurns(t) * rr
			end
			Raster.polygon(sc, color, pts)
		end
	end
	return sc
end

----------------------------------------------------------------------------------
-- Signed distance of shape s at (px, py); used for node classification.
-- The per-pixel paths in shadeRect and shadeExact inline the same formulas.
-- Every distance here is exact or a 1-Lipschitz bound that is exact inside (the
-- cut disc uses the max of its constraints), which classification relies on.
----------------------------------------------------------------------------------

local sqrt = math.sqrt
local abs = math.abs

local function sdf(sc: Scene, s: number, px: number, py: number): number
	local k = sc.kind[s]
	if k == CIRCLE then
		local dx, dy = px - sc.p1[s], py - sc.p2[s]
		return sqrt(dx * dx + dy * dy) - sc.p3[s]
	elseif k == BOX then
		local rad = sc.p5[s]
		local qx = abs(px - sc.p1[s]) - sc.p3[s] + rad
		local qy = abs(py - sc.p2[s]) - sc.p4[s] + rad
		local ox = if qx > 0 then qx else 0
		local oy = if qy > 0 then qy else 0
		local inside = if qx > qy then qx else qy
		if inside > 0 then
			inside = 0
		end
		return sqrt(ox * ox + oy * oy) + inside - rad
	elseif k == SEGMENT then
		local pax, pay = px - sc.p1[s], py - sc.p2[s]
		local bax, bay = sc.p3[s], sc.p4[s]
		local hh = (pax * bax + pay * bay) * sc.p6[s]
		hh = if hh < 0 then 0 elseif hh > 1 then 1 else hh
		local dx, dy = pax - bax * hh, pay - bay * hh
		return sqrt(dx * dx + dy * dy) - sc.p5[s]
	elseif k == RING then
		local dx, dy = px - sc.p1[s], py - sc.p2[s]
		return abs(sqrt(dx * dx + dy * dy) - sc.p3[s]) - sc.p4[s]
	elseif k == CUTDISC then
		local v = sc.verts
		local i = sc.p4[s]
		local dx, dy = px - sc.p1[s], py - sc.p2[s]
		local d = sqrt(dx * dx + dy * dy) - sc.p3[s]
		local h1 = v[i] * dx + v[i + 1] * dy - v[i + 2]
		local h2 = v[i + 3] * dx + v[i + 4] * dy - v[i + 5]
		if h1 > d then
			d = h1
		end
		if h2 > d then
			d = h2
		end
		return d
	else
		local v = sc.verts
		local first, count = sc.p1[s], sc.p2[s]
		local last = first + 2 * count - 2
		local dmin = math.huge
		local sign = 1
		local jx, jy = v[last], v[last + 1]
		for i = first, last, 2 do
			local vx, vy = v[i], v[i + 1]
			local ex, ey = jx - vx, jy - vy
			local wx, wy = px - vx, py - vy
			local ee = ex * ex + ey * ey
			local t = if ee > 0 then (wx * ex + wy * ey) / ee else 0
			t = if t < 0 then 0 elseif t > 1 then 1 else t
			local bx, by = wx - ex * t, wy - ey * t
			local dd = bx * bx + by * by
			if dd < dmin then
				dmin = dd
			end
			local c1 = py >= vy
			local c2 = py < jy
			local c3 = ex * wy > ey * wx
			if (c1 and c2 and c3) or (not c1 and not c2 and not c3) then
				sign = -sign
			end
			jx, jy = vx, vy
		end
		return sign * sqrt(dmin)
	end
end
Raster.sdf = sdf

----------------------------------------------------------------------------------
-- The shared per-pixel shading routine (MODE_LINEAR).
-- Shades pixels [x0, x1] x [y0, y1] with shapes list[lo..hi] (bottom to top),
-- starting from shape `base` (fully covering and opaque) or the background.
----------------------------------------------------------------------------------

local function shadeRect(
	sc: Scene,
	out: buffer,
	width: number,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	base: number,
	list: { number },
	lo: number,
	hi: number
)
	local K, P1, P2, P3, P4, P5, P6 = sc.kind, sc.p1, sc.p2, sc.p3, sc.p4, sc.p5, sc.p6
	local CR, CG, CB, CA = sc.cr, sc.cg, sc.cb, sc.ca
	local V = sc.verts
	local w = sc.aa
	local r0, g0, b0, a0
	if base > 0 then
		r0, g0, b0, a0 = CR[base], CG[base], CB[base], 1
	else
		r0, g0, b0, a0 = sc.bgR, sc.bgG, sc.bgB, sc.bgA
	end
	for y = y0, y1 do
		local py = y + 0.5
		local o = (y * width + x0) * 4
		for x = x0, x1 do
			local px = x + 0.5
			local ar, ag, ab, aa = r0, g0, b0, a0
			for j = lo, hi do
				local s = list[j]
				local k = K[s]
				local d
				if k == CIRCLE then
					local dx, dy = px - P1[s], py - P2[s]
					d = sqrt(dx * dx + dy * dy) - P3[s]
				elseif k == BOX then
					local rad = P5[s]
					local qx = abs(px - P1[s]) - P3[s] + rad
					local qy = abs(py - P2[s]) - P4[s] + rad
					local ox = if qx > 0 then qx else 0
					local oy = if qy > 0 then qy else 0
					local inside = if qx > qy then qx else qy
					if inside > 0 then
						inside = 0
					end
					d = sqrt(ox * ox + oy * oy) + inside - rad
				elseif k == SEGMENT then
					local pax, pay = px - P1[s], py - P2[s]
					local bax, bay = P3[s], P4[s]
					local hh = (pax * bax + pay * bay) * P6[s]
					hh = if hh < 0 then 0 elseif hh > 1 then 1 else hh
					local dx, dy = pax - bax * hh, pay - bay * hh
					d = sqrt(dx * dx + dy * dy) - P5[s]
				elseif k == RING then
					local dx, dy = px - P1[s], py - P2[s]
					d = abs(sqrt(dx * dx + dy * dy) - P3[s]) - P4[s]
				elseif k == CUTDISC then
					local i = P4[s]
					local dx, dy = px - P1[s], py - P2[s]
					d = sqrt(dx * dx + dy * dy) - P3[s]
					local h1 = V[i] * dx + V[i + 1] * dy - V[i + 2]
					local h2 = V[i + 3] * dx + V[i + 4] * dy - V[i + 5]
					if h1 > d then
						d = h1
					end
					if h2 > d then
						d = h2
					end
				else
					local first = P1[s]
					local last = first + 2 * P2[s] - 2
					local dmin = math.huge
					local sign = 1
					local jx, jy = V[last], V[last + 1]
					for i = first, last, 2 do
						local vx, vy = V[i], V[i + 1]
						local ex, ey = jx - vx, jy - vy
						local wx, wy = px - vx, py - vy
						local ee = ex * ex + ey * ey
						local t = if ee > 0 then (wx * ex + wy * ey) / ee else 0
						t = if t < 0 then 0 elseif t > 1 then 1 else t
						local bx, by = wx - ex * t, wy - ey * t
						local dd = bx * bx + by * by
						if dd < dmin then
							dmin = dd
						end
						local c1 = py >= vy
						local c2 = py < jy
						local c3 = ex * wy > ey * wx
						if (c1 and c2 and c3) or (not c1 and not c2 and not c3) then
							sign = -sign
						end
						jx, jy = vx, vy
					end
					d = sign * sqrt(dmin)
				end
				local cov = 0.5 - d / w
				if cov > 0 then
					local sa = (if cov < 1 then cov else 1) * CA[s] / 255
					if sa >= 1 then
						ar, ag, ab, aa = CR[s], CG[s], CB[s], 1
					else
						local da = aa * (1 - sa)
						local oa = sa + da
						ar = (CR[s] * sa + ar * da) / oa
						ag = (CG[s] * sa + ag * da) / oa
						ab = (CB[s] * sa + ab * da) / oa
						aa = oa
					end
				end
			end
			buffer.writeu32(
				out,
				o,
				(ar + 0.5) // 1 + ((ag + 0.5) // 1) * 256 + ((ab + 0.5) // 1) * 65536 + ((aa * 255 + 0.5) // 1) * 16777216
			)
			o += 4
		end
	end
end

----------------------------------------------------------------------------------
-- Exact-area coverage (MODE_EXACT, MODE_LAYERED): F1 for every primitive.
-- Coverage is exactly 0 for d >= REACH and exactly 1 for d <= -REACH (REACH =
-- sqrt(2) / 2 AA widths), which classify uses; in between it is the exact area of
-- the w x w pixel inside the shape, divided by w^2.
----------------------------------------------------------------------------------

local REACH = MyMath.COVERAGE_REACH

-- The curvature-corrected estimator (C5) is MyMath's axiom; kept as Raster.covCurved
-- for compute/Rows.luau. MODE_EXACT does not use it (its residual is O(1/R)).
local covCurved = MyMath.coverageCurved
Raster.covCurved = covCurved

local halfPlane = MyMath.coverageHalfPlane
local discBoxArea = Coverage.discBoxArea
local discPolyArea = Coverage.discPolyArea
local polyArea = Coverage.polyArea
local clipInto = Coverage.clipInto
local polygonBoxCoverage = Coverage.polygonBoxCoverage

-- scratch polygons (pixel-local coordinates, pixel = [-1/2, 1/2]^2)
local QX: { number } = table.create(64, 0)
local QY: { number } = table.create(64, 0)
local RX: { number } = table.create(64, 0)
local RY: { number } = table.create(64, 0)

local function squareQ()
	QX[1], QY[1] = -0.5, -0.5
	QX[2], QY[2] = 0.5, -0.5
	QX[3], QY[3] = 0.5, 0.5
	QX[4], QY[4] = -0.5, 0.5
end

-- Length of [a0, a1] intersected with [b0, b1].
local function overlap(a0: number, a1: number, b0: number, b1: number): number
	local lo = if a0 > b0 then a0 else b0
	local hi = if a1 < b1 then a1 else b1
	return if hi > lo then hi - lo else 0
end

-- Exact area of the pixel box [X0, X1] x [Y0, Y1] (relative to the box centre)
-- inside the rounded box with half extents (hx, hy) and corner radius rad. The
-- rounded box is the disjoint union of the vertical band |x| <= hx - rad, the two
-- side rectangles hx - rad <= |x| <= hx, |y| <= hy - rad, and four corner pieces
-- (corner disc and corner quadrant), each measured exactly.
local function boxArea(X0: number, X1: number, Y0: number, Y1: number, hx: number, hy: number, rad: number): number
	if rad <= 0 then
		return overlap(X0, X1, -hx, hx) * overlap(Y0, Y1, -hy, hy)
	end
	local ix, iy = hx - rad, hy - rad
	if Y0 >= -iy and Y1 <= iy then
		return overlap(X0, X1, -hx, hx) * (Y1 - Y0)
	end
	if X0 >= -ix and X1 <= ix then
		return (X1 - X0) * overlap(Y0, Y1, -hy, hy)
	end
	local area = overlap(X0, X1, -ix, ix) * overlap(Y0, Y1, -hy, hy)
		+ (overlap(X0, X1, ix, hx) + overlap(X0, X1, -hx, -ix)) * overlap(Y0, Y1, -iy, iy)
	local xr0 = if X0 > ix then X0 else ix
	local xr1 = if X1 < hx then X1 else hx
	local xl0 = if X0 > -hx then X0 else -hx
	local xl1 = if X1 < -ix then X1 else -ix
	local yp0 = if Y0 > iy then Y0 else iy
	local yp1 = if Y1 < hy then Y1 else hy
	local yn0 = if Y0 > -hy then Y0 else -hy
	local yn1 = if Y1 < -iy then Y1 else -iy
	if xr1 > xr0 then
		if yp1 > yp0 then
			area += discBoxArea(ix, iy, rad, xr0, yp0, xr1, yp1)
		end
		if yn1 > yn0 then
			area += discBoxArea(ix, -iy, rad, xr0, yn0, xr1, yn1)
		end
	end
	if xl1 > xl0 then
		if yp1 > yp0 then
			area += discBoxArea(-ix, iy, rad, xl0, yp0, xl1, yp1)
		end
		if yn1 > yn0 then
			area += discBoxArea(-ix, -iy, rad, xl0, yn0, xl1, yn1)
		end
	end
	return area
end

-- Exact coverage of the w x w pixel centred at (px, py) by the capsule from A to
-- A + D with radius r. The capsule is the disjoint union of the body (points whose
-- projection on the axis lies in [0, L], within r of the axis) and the two caps
-- (points beyond an end line, within r of that end point), so its area in the
-- pixel is |pixel ^ body| + |pixel ^ {h <= 0} ^ disc(A)| + |pixel ^ {h >= L} ^
-- disc(B)|: a clipped square, and two discs with a clipped square. A pixel whose
-- projection lies inside [0, L] sees only the two straight sides (C4, exact).
local function capsuleCoverage(px: number, py: number, w: number, ax: number, ay: number, ddx: number, ddy: number, r: number): number
	local iw = 1 / w
	local Ax, Ay = (ax - px) * iw, (ay - py) * iw
	local rw = r * iw
	local L2 = ddx * ddx + ddy * ddy
	if L2 == 0 then
		return discBoxArea(Ax, Ay, rw, -0.5, -0.5, 0.5, 0.5)
	end
	local L = sqrt(L2)
	local ex, ey = ddx / L, ddy / L
	local nx, ny = -ey, ex
	local Lw = L * iw
	local eA = Ax * ex + Ay * ey
	local nA = Ax * nx + Ay * ny
	local h = -eA -- pixel centre along the axis, from A
	local sN = -nA -- pixel centre across the axis
	local hr = 0.5 * (abs(ex) + abs(ey)) -- half extent of the pixel along the axis
	if h - hr >= 0 and h + hr <= Lw then
		local c = halfPlane(sN - rw, nx, ny) + halfPlane(-sN - rw, nx, ny) - 1
		return if c < 0 then 0 else c
	end
	local area = 0
	if h + hr > 0 and h - hr < Lw then
		squareQ()
		local m = clipInto(QX, QY, 4, RX, RY, -ex, -ey, -eA)
		m = clipInto(RX, RY, m, QX, QY, ex, ey, eA + Lw)
		m = clipInto(QX, QY, m, RX, RY, nx, ny, nA + rw)
		m = clipInto(RX, RY, m, QX, QY, -nx, -ny, rw - nA)
		area += polyArea(QX, QY, m)
	end
	if h - hr < 0 then
		if h + hr <= 0 then
			area += discBoxArea(Ax, Ay, rw, -0.5, -0.5, 0.5, 0.5)
		else
			squareQ()
			local m = clipInto(QX, QY, 4, RX, RY, ex, ey, eA)
			area += discPolyArea(RX, RY, m, Ax, Ay, rw)
		end
	end
	if h + hr > Lw then
		local Bx, By = Ax + ddx * iw, Ay + ddy * iw
		if h - hr >= Lw then
			area += discBoxArea(Bx, By, rw, -0.5, -0.5, 0.5, 0.5)
		else
			squareQ()
			local m = clipInto(QX, QY, 4, RX, RY, -ex, -ey, -(eA + Lw))
			area += discPolyArea(RX, RY, m, Bx, By, rw)
		end
	end
	return if area < 0 then 0 elseif area > 1 then 1 else area
end

-- Exact coverage of the pixel by a cut disc: the square clipped by the half-planes
-- that cross it, intersected with the disc (or the plain clipped square / the plain
-- disc where the other part covers the pixel). d1, d2, dd are the pixel centre's
-- signed distances (AA widths) to the two lines and the circle.
local function cutDiscCoverage(
	px: number,
	py: number,
	w: number,
	cx: number,
	cy: number,
	r: number,
	n1x: number,
	n1y: number,
	o1: number,
	n2x: number,
	n2y: number,
	o2: number,
	d1: number,
	d2: number,
	dd: number
): number
	local iw = 1 / w
	local Cx, Cy, rw = (cx - px) * iw, (cy - py) * iw, r * iw
	local need1 = d1 > -REACH
	local need2 = d2 > -REACH and (n2x ~= 0 or n2y ~= 0)
	local c
	if not need1 and not need2 then
		c = discBoxArea(Cx, Cy, rw, -0.5, -0.5, 0.5, 0.5)
	else
		squareQ()
		local X, Y, m = QX, QY, 4
		if need1 then
			m = clipInto(X, Y, m, RX, RY, n1x, n1y, o1 * iw + n1x * Cx + n1y * Cy)
			X, Y = RX, RY
		end
		if need2 then
			if X == QX then
				m = clipInto(QX, QY, m, RX, RY, n2x, n2y, o2 * iw + n2x * Cx + n2y * Cy)
				X, Y = RX, RY
			else
				m = clipInto(RX, RY, m, QX, QY, n2x, n2y, o2 * iw + n2x * Cx + n2y * Cy)
				X, Y = QX, QY
			end
		end
		if dd <= -REACH then
			c = polyArea(X, Y, m)
		else
			c = discPolyArea(X, Y, m, Cx, Cy, rw)
		end
	end
	return if c < 0 then 0 elseif c > 1 then 1 else c
end

----------------------------------------------------------------------------------
-- Pieces for exact visibility (F2): each shape's indicator inside the pixel as a
-- signed sum of convex pieces (pixel-local coordinates, pixel = [-1/2, 1/2]^2).
----------------------------------------------------------------------------------

local GX: { number } = table.create(64, 0)
local GY: { number } = table.create(64, 0)

local function addPieces(sc: Scene, s: number, px: number, py: number, w: number)
	local k = sc.kind[s]
	local iw = 1 / w
	local P1, P2, P3, P4, P5 = sc.p1, sc.p2, sc.p3, sc.p4, sc.p5
	if k == CIRCLE then
		Visibility.square(1)
		Visibility.disc((P1[s] - px) * iw, (P2[s] - py) * iw, P3[s] * iw)
		Visibility.piece()
	elseif k == RING then
		local Cx, Cy = (P1[s] - px) * iw, (P2[s] - py) * iw
		local r, t = P3[s], P4[s]
		Visibility.square(1)
		Visibility.disc(Cx, Cy, (r + t) * iw)
		Visibility.piece()
		if r - t > 0 then
			Visibility.square(-1)
			Visibility.disc(Cx, Cy, (r - t) * iw)
			Visibility.piece()
		end
	elseif k == BOX then
		local bx, by = (P1[s] - px) * iw, (P2[s] - py) * iw
		local hx, hy, rad = P3[s] * iw, P4[s] * iw, P5[s] * iw
		if rad <= 0 then
			Visibility.rect(1, bx - hx, by - hy, bx + hx, by + hy)
			Visibility.piece()
		else
			local ix, iy = hx - rad, hy - rad
			if ix > 0 then
				Visibility.rect(1, bx - ix, by - hy, bx + ix, by + hy)
				Visibility.piece()
			end
			if iy > 0 then
				Visibility.rect(1, bx - hx, by - iy, bx - ix, by + iy)
				Visibility.piece()
				Visibility.rect(1, bx + ix, by - iy, bx + hx, by + iy)
				Visibility.piece()
			end
			Visibility.rect(1, bx + ix, by + iy, bx + hx, by + hy)
			Visibility.disc(bx + ix, by + iy, rad)
			Visibility.piece()
			Visibility.rect(1, bx - hx, by + iy, bx - ix, by + hy)
			Visibility.disc(bx - ix, by + iy, rad)
			Visibility.piece()
			Visibility.rect(1, bx + ix, by - hy, bx + hx, by - iy)
			Visibility.disc(bx + ix, by - iy, rad)
			Visibility.piece()
			Visibility.rect(1, bx - hx, by - hy, bx - ix, by - iy)
			Visibility.disc(bx - ix, by - iy, rad)
			Visibility.piece()
		end
	elseif k == SEGMENT then
		local Ax, Ay = (P1[s] - px) * iw, (P2[s] - py) * iw
		local ddx, ddy, rw = P3[s] * iw, P4[s] * iw, P5[s] * iw
		local L2 = ddx * ddx + ddy * ddy
		if L2 == 0 then
			Visibility.square(1)
			Visibility.disc(Ax, Ay, rw)
			Visibility.piece()
		else
			local L = sqrt(L2)
			local ex, ey = ddx / L, ddy / L
			local nx, ny = -ey, ex
			local eA = Ax * ex + Ay * ey
			local nA = Ax * nx + Ay * ny
			Visibility.square(1)
			Visibility.clip(-ex, -ey, -eA)
			Visibility.clip(ex, ey, eA + L)
			Visibility.clip(nx, ny, nA + rw)
			Visibility.clip(-nx, -ny, rw - nA)
			Visibility.piece()
			Visibility.square(1)
			Visibility.clip(ex, ey, eA)
			Visibility.disc(Ax, Ay, rw)
			Visibility.piece()
			Visibility.square(1)
			Visibility.clip(-ex, -ey, -(eA + L))
			Visibility.disc(Ax + ddx, Ay + ddy, rw)
			Visibility.piece()
		end
	elseif k == CUTDISC then
		local V = sc.verts
		local i = P4[s]
		local Cx, Cy = (P1[s] - px) * iw, (P2[s] - py) * iw
		Visibility.square(1)
		Visibility.clip(V[i], V[i + 1], V[i + 2] * iw + V[i] * Cx + V[i + 1] * Cy)
		if P5[s] == 2 then
			Visibility.clip(V[i + 3], V[i + 4], V[i + 5] * iw + V[i + 3] * Cx + V[i + 4] * Cy)
		end
		Visibility.disc(Cx, Cy, P3[s] * iw)
		Visibility.piece()
	else
		-- polygon: clipped to the pixel by Visibility.polygon (one convex piece or a
		-- signed fan); p3 is the orientation, so the interior counts +1
		local V = sc.verts
		local first, count = P1[s], P2[s]
		for i = 1, count do
			GX[i] = (V[first + 2 * i - 2] - px) * iw
			GY[i] = (V[first + 2 * i - 1] - py) * iw
		end
		Visibility.polygon(GX, GY, count, P3[s])
	end
end
Raster.addPieces = addPieces

-- Per-pixel coverage of list[lo..hi], kept for the exact-visibility path.
local COV: { number } = table.create(512, 0)

-- Exact composite of the pixel (F2): shapes list[from..hi] above the base colour
-- (straight r, g, b, alpha a), with coverages COV[j - lo + 1]. Top-down.
local function resolve(
	sc: Scene,
	list: { number },
	lo: number,
	from: number,
	hi: number,
	px: number,
	py: number,
	w: number,
	br: number,
	bg: number,
	bb: number,
	ba: number
): (number, number, number, number)
	Visibility.reset()
	local CR, CG, CB, CA = sc.cr, sc.cg, sc.cb, sc.ca
	for j = hi, from, -1 do
		local cov = COV[j - lo + 1]
		if cov > 0 then
			local s = list[j]
			local a = CA[s] / 255
			if cov >= 1 then
				Visibility.full(CR[s], CG[s], CB[s], a)
			else
				Visibility.begin(CR[s], CG[s], CB[s], a)
				addPieces(sc, s, px, py, w)
				Visibility.commit()
			end
		end
	end
	return Visibility.finish(br, bg, bb, ba)
end

local function shadeExact(
	sc: Scene,
	out: buffer,
	width: number,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	base: number,
	list: { number },
	lo: number,
	hi: number
)
	local K, P1, P2, P3, P4, P5, P6 = sc.kind, sc.p1, sc.p2, sc.p3, sc.p4, sc.p5, sc.p6
	local CR, CG, CB, CA = sc.cr, sc.cg, sc.cb, sc.ca
	local V = sc.verts
	local w = sc.aa
	local iw = 1 / w
	local iw2 = iw * iw
	local hw = w * 0.5
	local exactComposite = sc.mode == MODE_EXACT
	local r0, g0, b0, a0
	if base > 0 then
		r0, g0, b0, a0 = CR[base], CG[base], CB[base], 1
	else
		r0, g0, b0, a0 = sc.bgR, sc.bgG, sc.bgB, sc.bgA
	end
	for y = y0, y1 do
		local py = y + 0.5
		local o = (y * width + x0) * 4
		for x = x0, x1 do
			local px = x + 0.5
			local ar, ag, ab, aa = r0, g0, b0, a0
			local nf = 0 -- shapes with fractional coverage above the last opaque full one
			local reset = lo - 1 -- list index of the last opaque full shape (lo - 1: the base)
			for j = lo, hi do
				local s = list[j]
				local k = K[s]
				local cov
				if k == CIRCLE then
					local cx, cy = P1[s], P2[s]
					local dx, dy = px - cx, py - cy
					local r = P3[s]
					local d = (sqrt(dx * dx + dy * dy) - r) * iw
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						cov = discBoxArea(cx, cy, r, px - hw, py - hw, px + hw, py + hw) * iw2
						cov = if cov > 1 then 1 else cov
					end
				elseif k == BOX then
					local rad = P5[s]
					local cx, cy, hx, hy = P1[s], P2[s], P3[s], P4[s]
					local qx = abs(px - cx) - hx + rad
					local qy = abs(py - cy) - hy + rad
					local ox = if qx > 0 then qx else 0
					local oy = if qy > 0 then qy else 0
					local inside = if qx > qy then qx else qy
					if inside > 0 then
						inside = 0
					end
					local d = (sqrt(ox * ox + oy * oy) + inside - rad) * iw
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						local X0, X1, Y0, Y1 = px - hw - cx, px + hw - cx, py - hw - cy, py + hw - cy
						if Y0 >= rad - hy and Y1 <= hy - rad then
							-- inside the horizontal band: the box is locally the slab |x| <= hx
							local lo = if X0 > -hx then X0 else -hx
							local hi = if X1 < hx then X1 else hx
							cov = if hi > lo then (hi - lo) * iw else 0
						elseif X0 >= rad - hx and X1 <= hx - rad then
							local lo = if Y0 > -hy then Y0 else -hy
							local hi = if Y1 < hy then Y1 else hy
							cov = if hi > lo then (hi - lo) * iw else 0
						else
							cov = boxArea(X0, X1, Y0, Y1, hx, hy, rad) * iw2
						end
						cov = if cov > 1 then 1 else cov
					end
				elseif k == SEGMENT then
					local ax, ay = P1[s], P2[s]
					local pax, pay = px - ax, py - ay
					local bax, bay = P3[s], P4[s]
					local i2 = P6[s]
					local h0 = (pax * bax + pay * bay) * i2
					local hh = if h0 < 0 then 0 elseif h0 > 1 then 1 else h0
					local dx, dy = pax - bax * hh, pay - bay * hh
					local len = sqrt(dx * dx + dy * dy)
					local r = P5[s]
					local d = (len - r) * iw
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						-- half extent of the pixel along the axis, in units of the segment
						local hr = hw * (abs(bax) + abs(bay)) * i2
						if i2 > 0 and h0 - hr >= 0 and h0 + hr <= 1 and len > 0 and r * iw >= REACH then
							-- the pixel sees one straight side only (C4, exact)
							cov = halfPlane(d, dx / len, dy / len)
						else
							cov = capsuleCoverage(px, py, w, ax, ay, bax, bay, r)
						end
					end
				elseif k == RING then
					local cx, cy = P1[s], P2[s]
					local dx, dy = px - cx, py - cy
					local len = sqrt(dx * dx + dy * dy)
					local r, t = P3[s], P4[s]
					local d = (abs(len - r) - t) * iw
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						-- annulus = outer disc minus inner disc, each exact
						local ro = r + t
						local dOut = (len - ro) * iw
						local cOut
						if dOut >= REACH then
							cOut = 0
						elseif dOut <= -REACH then
							cOut = 1
						else
							cOut = discBoxArea(cx, cy, ro, px - hw, py - hw, px + hw, py + hw) * iw2
						end
						local ri = r - t
						local cIn = 0
						if ri > 0 then
							local dIn = (len - ri) * iw
							if dIn >= REACH then
								cIn = 0
							elseif dIn <= -REACH then
								cIn = 1
							else
								cIn = discBoxArea(cx, cy, ri, px - hw, py - hw, px + hw, py + hw) * iw2
							end
						end
						cov = cOut - cIn
						cov = if cov < 0 then 0 elseif cov > 1 then 1 else cov
					end
				elseif k == CUTDISC then
					local i = P4[s]
					local cx, cy, r = P1[s], P2[s], P3[s]
					local dx, dy = px - cx, py - cy
					local dd = (sqrt(dx * dx + dy * dy) - r) * iw
					local n1x, n1y, o1 = V[i], V[i + 1], V[i + 2]
					local n2x, n2y, o2 = V[i + 3], V[i + 4], V[i + 5]
					local d1 = (n1x * dx + n1y * dy - o1) * iw
					local d2 = (n2x * dx + n2y * dy - o2) * iw
					local d = dd
					if d1 > d then
						d = d1
					end
					if d2 > d then
						d = d2
					end
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						cov = cutDiscCoverage(px, py, w, cx, cy, r, n1x, n1y, o1, n2x, n2y, o2, d1, d2, dd)
					end
				else
					local first = P1[s]
					local count = P2[s]
					local last = first + 2 * count - 2
					local dmin = math.huge
					local sign = 1
					local jx, jy = V[last], V[last + 1]
					for i = first, last, 2 do
						local vx, vy = V[i], V[i + 1]
						local ex, ey = jx - vx, jy - vy
						local wx, wy = px - vx, py - vy
						local ee = ex * ex + ey * ey
						local t = if ee > 0 then (wx * ex + wy * ey) / ee else 0
						t = if t < 0 then 0 elseif t > 1 then 1 else t
						local bx, by = wx - ex * t, wy - ey * t
						local dd = bx * bx + by * by
						if dd < dmin then
							dmin = dd
						end
						local c1 = py >= vy
						local c2 = py < jy
						local c3 = ex * wy > ey * wx
						if (c1 and c2 and c3) or (not c1 and not c2 and not c3) then
							sign = -sign
						end
						jx, jy = vx, vy
					end
					local d = sign * sqrt(dmin) * iw
					if d >= REACH then
						cov = 0
					elseif d <= -REACH then
						cov = 1
					else
						-- exact area by per-edge Green integrals (any number of edges)
						cov = -P3[s] * polygonBoxCoverage(V, first, count, px - hw, py - hw, w)
						cov = if cov < 0 then 0 elseif cov > 1 then 1 else cov
					end
				end
				COV[j - lo + 1] = cov
				if cov > 0 then
					local sa = cov * CA[s] / 255
					if sa >= 1 then
						ar, ag, ab, aa = CR[s], CG[s], CB[s], 1
						nf = 0
						reset = j
					else
						local da = aa * (1 - sa)
						local oa = sa + da
						ar = (CR[s] * sa + ar * da) / oa
						ag = (CG[s] * sa + ag * da) / oa
						ab = (CB[s] * sa + ab * da) / oa
						aa = oa
						if cov < 1 then
							nf += 1
						end
					end
				end
			end
			if nf >= 2 and exactComposite then
				-- two or more edges in this pixel: exact visibility (F2)
				stats.conflicts += 1
				local br, bgc, bb, ba
				if reset >= lo then
					local s = list[reset]
					br, bgc, bb, ba = CR[s], CG[s], CB[s], 1
				else
					br, bgc, bb, ba = r0, g0, b0, a0
				end
				ar, ag, ab, aa = resolve(sc, list, lo, reset + 1, hi, px, py, w, br, bgc, bb, ba)
			end
			buffer.writeu32(
				out,
				o,
				(ar + 0.5) // 1 + ((ag + 0.5) // 1) * 256 + ((ab + 0.5) // 1) * 65536 + ((aa * 255 + 0.5) // 1) * 16777216
			)
			o += 4
		end
	end
end

local function shade(
	sc: Scene,
	out: buffer,
	width: number,
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	base: number,
	list: { number },
	lo: number,
	hi: number
)
	if sc.mode == MODE_LINEAR then
		shadeRect(sc, out, width, x0, y0, x1, y1, base, list, lo, hi)
	else
		shadeExact(sc, out, width, x0, y0, x1, y1, base, list, lo, hi)
	end
end

----------------------------------------------------------------------------------
-- Reference renderers
----------------------------------------------------------------------------------

-- Every shape at every pixel. rows: optional list of row indices to render (the
-- benchmark samples rows because the full frame takes seconds in the interpreter).
function Raster.renderBrute(sc: Scene, out: buffer, width: number, height: number, rows: { number }?)
	local list = table.create(sc.n, 0)
	for s = 1, sc.n do
		list[s] = s
	end
	if rows then
		for _, y in rows do
			shade(sc, out, width, 0, y, width - 1, y, 0, list, 1, sc.n)
		end
	else
		shade(sc, out, width, 0, 0, width - 1, height - 1, 0, list, 1, sc.n)
	end
end

-- Painter's algorithm over each shape's bounding box with an 8-bit framebuffer
-- (read, unpack, blend, pack, write per covered pixel). Fast to write, but it
-- rounds to 8 bits after every shape, so it is not identical to renderBrute.
-- Linear coverage only (it is the baseline an engine DrawCircle loop gives).
function Raster.renderPainter(sc: Scene, out: buffer, width: number, height: number)
	local bg = (sc.bgR // 1) + (sc.bgG // 1) * 256 + (sc.bgB // 1) * 65536 + ((sc.bgA * 255 + 0.5) // 1) * 16777216
	Pixels.fill(out, bg)
	for s = 1, sc.n do
		local x0, y0 = math.max(0, sc.bx0[s]), math.max(0, sc.by0[s])
		local x1, y1 = math.min(width - 1, sc.bx1[s]), math.min(height - 1, sc.by1[s])
		local cr, cg, cb, ca = sc.cr[s], sc.cg[s], sc.cb[s], sc.ca[s]
		local w = sc.aa
		for y = y0, y1 do
			local py = y + 0.5
			local o = (y * width + x0) * 4
			for x = x0, x1 do
				local d = sdf(sc, s, x + 0.5, py)
				local cov = 0.5 - d / w
				if cov > 0 then
					local sa = (if cov < 1 then cov else 1) * ca / 255
					local p = buffer.readu32(out, o)
					local ia = 1 - sa
					local r = cr * sa + (p % 256) * ia
					local g = cg * sa + ((p // 256) % 256) * ia
					local b = cb * sa + ((p // 65536) % 256) * ia
					local a = sa * 255 + (p // 16777216) * ia
					buffer.writeu32(out, o, (r + 0.5) // 1 + ((g + 0.5) // 1) * 256 + ((b + 0.5) // 1) * 65536 + ((a + 0.5) // 1) * 16777216)
				end
				o += 4
			end
		end
	end
end

----------------------------------------------------------------------------------
-- Shape binning
----------------------------------------------------------------------------------

function Raster.bin(sc: Scene, width: number, height: number, tile: number?): Bins
	local t = tile or 64
	local tilesX, tilesY = (width + t - 1) // t, (height + t - 1) // t
	local lists: { { number } } = {}
	for i = 1, tilesX * tilesY do
		lists[i] = {}
	end
	for s = 1, sc.n do
		local tx0 = math.max(0, sc.bx0[s] // t)
		local ty0 = math.max(0, sc.by0[s] // t)
		local tx1 = math.min(tilesX - 1, sc.bx1[s] // t)
		local ty1 = math.min(tilesY - 1, sc.by1[s] // t)
		for ty = ty0, ty1 do
			for tx = tx0, tx1 do
				table.insert(lists[ty * tilesX + tx + 1], s)
			end
		end
	end
	return { tile = t, tilesX = tilesX, tilesY = tilesY, lists = lists }
end

----------------------------------------------------------------------------------
-- Lipschitz quadtree over one tile
----------------------------------------------------------------------------------

local SQRT_HALF = 0.70710678118654757
local EPS = 1e-7 -- covers rounding in sdf evaluation (|error| < 1e-12 at 1024 px)

local stack: { number } = table.create(4096, 0)

-- Classifies list stack[lo..hi] against the node [x, x+size) x [y, y+size).
-- Pushes the surviving shapes above the topmost covering opaque shape onto the
-- stack and returns (newLo, newHi, base, uniform).
local function classify(sc: Scene, x: number, y: number, size: number, lo: number, hi: number, base: number): (number, number, number, boolean)
	local cx, cy = x + size * 0.5, y + size * 0.5
	local reach = (size - 1) * SQRT_HALF * (1 + 1e-12) -- half-diagonal to the farthest pixel centre
	-- coverage is exactly 0 / 1 beyond half an AA width (linear) or sqrt(2)/2 (exact)
	local half = sc.aa * (if sc.mode ~= MODE_LINEAR then SQRT_HALF else 0.5)
	local CA = sc.ca
	local top = hi
	local allFull = true
	local nb = base
	local n = 0
	for j = hi, lo, -1 do
		local s = stack[j]
		local d = sdf(sc, s, cx, cy)
		stats.evals += 1
		if d - reach > half + EPS then
			continue -- coverage exactly 0 at every pixel centre of the node
		end
		local full = d + reach < -half - EPS -- coverage exactly 1 at every pixel centre
		if full and CA[s] == 255 then
			nb = s -- hides every shape below it
			break
		end
		if not full then
			allFull = false
		end
		n += 1
		stack[top + n] = s
	end
	-- surviving shapes were pushed top-down; reverse into bottom-up order
	local newLo, newHi = top + 1, top + n
	local i, k = newLo, newHi
	while i < k do
		stack[i], stack[k] = stack[k], stack[i]
		i += 1
		k -= 1
	end
	return newLo, newHi, nb, allFull
end

local function fillNode(sc: Scene, out: buffer, width: number, x: number, y: number, w: number, h: number, base: number, lo: number, hi: number)
	-- every remaining shape covers the node fully: shade one pixel, copy it everywhere
	local c
	if lo > hi then
		-- nothing above the base: the colour is known without shading (the same value
		-- shadeRect produces, since channels are integers and alpha is exactly 1 or bgA)
		if base > 0 then
			c = sc.cr[base] + sc.cg[base] * 256 + sc.cb[base] * 65536 + 0xFF000000
		else
			c = (sc.bgR + 0.5) // 1 + ((sc.bgG + 0.5) // 1) * 256 + ((sc.bgB + 0.5) // 1) * 65536 + ((sc.bgA * 255 + 0.5) // 1) * 16777216
		end
	else
		shade(sc, out, width, x, y, x, y, base, stack, lo, hi)
		c = buffer.readu32(out, (y * width + x) * 4)
	end
	Pixels.fillRect(out, width, x, y, w, h, c)
end

local function node(
	sc: Scene,
	out: buffer,
	width: number,
	height: number,
	x: number,
	y: number,
	size: number,
	lo: number,
	hi: number,
	base: number,
	leaf: number
)
	stats.nodes += 1
	local nlo, nhi, nb, uniform = classify(sc, x, y, size, lo, hi, base)
	local w = math.min(size, width - x)
	local h = math.min(size, height - y)
	if uniform then
		stats.uniform += 1
		fillNode(sc, out, width, x, y, w, h, nb, nlo, nhi)
	elseif size <= leaf then
		stats.leaves += 1
		stats.shaded += w * h
		shade(sc, out, width, x, y, x + w - 1, y + h - 1, nb, stack, nlo, nhi)
	else
		local half = size // 2
		node(sc, out, width, height, x, y, half, nlo, nhi, nb, leaf)
		if x + half < width then
			node(sc, out, width, height, x + half, y, half, nlo, nhi, nb, leaf)
		end
		if y + half < height then
			node(sc, out, width, height, x, y + half, half, nlo, nhi, nb, leaf)
			if x + half < width then
				node(sc, out, width, height, x + half, y + half, half, nlo, nhi, nb, leaf)
			end
		end
	end
end

-- Renders tiles [tx0, tx1] x [ty0, ty1] of the bins (all tiles by default).
-- leaf: smallest node edge that is shaded per pixel (default 8; power of two).
function Raster.render(
	sc: Scene,
	bins: Bins,
	out: buffer,
	width: number,
	height: number,
	leaf: number?,
	tx0: number?,
	ty0: number?,
	tx1: number?,
	ty1: number?
)
	local lf = leaf or 8
	local t = bins.tile
	for ty = ty0 or 0, ty1 or bins.tilesY - 1 do
		for tx = tx0 or 0, tx1 or bins.tilesX - 1 do
			local list = bins.lists[ty * bins.tilesX + tx + 1]
			local n = #list
			for i = 1, n do
				stack[i] = list[i]
			end
			node(sc, out, width, height, tx * t, ty * t, t, 1, n, 0, lf)
		end
	end
end

-- Re-renders after shapes changed: every tile touched by any of the pixel
-- rectangles {x0, y0, x1, y1} (old and new bounds of moved shapes). Returns the
-- number of tiles rendered.
function Raster.renderDirty(sc: Scene, bins: Bins, out: buffer, width: number, height: number, rects: { { number } }, leaf: number?): number
	local t = bins.tile
	local seen: { [number]: boolean } = {}
	local count = 0
	for _, r in rects do
		local tx0 = math.max(0, r[1] // t)
		local ty0 = math.max(0, r[2] // t)
		local tx1 = math.min(bins.tilesX - 1, r[3] // t)
		local ty1 = math.min(bins.tilesY - 1, r[4] // t)
		for ty = ty0, ty1 do
			for tx = tx0, tx1 do
				local key = ty * bins.tilesX + tx
				if not seen[key] then
					seen[key] = true
					count += 1
					Raster.render(sc, bins, out, width, height, leaf, tx, ty, tx, ty)
				end
			end
		end
	end
	return count
end

-- Time-sliced rendering: renders tiles in the given order until os.clock() passes
-- the deadline. Returns the index of the next tile to render (order length + 1
-- when finished). order holds 0-based tile indices (ty * tilesX + tx).
function Raster.renderUntil(sc: Scene, bins: Bins, out: buffer, width: number, height: number, order: { number }, from: number, deadline: number, leaf: number?): number
	local i = from
	local clock = os.clock
	while i <= #order do
		local k = order[i]
		local tx, ty = k % bins.tilesX, k // bins.tilesX
		Raster.render(sc, bins, out, width, height, leaf, tx, ty, tx, ty)
		i += 1
		if clock() >= deadline then
			break
		end
	end
	return i
end

return Raster
