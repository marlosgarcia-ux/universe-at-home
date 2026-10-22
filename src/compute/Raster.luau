--!native
--!optimize 2
-- universe-at-home :: compute/Raster
--
-- Scene rasterizer for hundreds of anti-aliased 2D shapes (circles, rounded boxes,
-- capsules, rings, polygons) composited bottom to top with straight-alpha
-- source-over. Three renderers share one per-pixel shading routine:
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
-- function with the same operand order.
--
-- Deterministic ops only: + - * / sqrt abs floor, comparisons (RUNTIME_AUDIT 6.5).

local Pixels = require("../Pixels")
local MyMath = require("../MyMath")

local Raster = {}

local CIRCLE, BOX, SEGMENT, RING, POLYGON = 1, 2, 3, 4, 5
Raster.CIRCLE, Raster.BOX, Raster.SEGMENT, Raster.RING, Raster.POLYGON = CIRCLE, BOX, SEGMENT, RING, POLYGON

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
	verts: { number },
	aa: number, -- anti-aliasing width in pixels (coverage = clamp(0.5 - d / aa, 0, 1))
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

export type Stats = { nodes: number, uniform: number, leaves: number, shaded: number, evals: number }

local stats: Stats = { nodes = 0, uniform = 0, leaves = 0, shaded = 0, evals = 0 }
Raster.stats = stats

function Raster.resetStats()
	stats.nodes, stats.uniform, stats.leaves, stats.shaded, stats.evals = 0, 0, 0, 0, 0
end

----------------------------------------------------------------------------------
-- Scene construction
----------------------------------------------------------------------------------

function Raster.newScene(background: number, aa: number?): Scene
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
	local h = sc.aa * 0.5
	local x0, y0, x1, y1
	if k == CIRCLE then
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
			x0, x1 = math.min(x0, v[i]), math.max(x1, v[i])
			y0, y1 = math.min(y0, v[i + 1]), math.max(y1, v[i + 1])
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

-- Box centred at (cx, cy), half extents (hx, hy), corner radius rad.
function Raster.box(sc: Scene, color: number, cx: number, cy: number, hx: number, hy: number, rad: number): number
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

-- Polygon from flat {x1, y1, x2, y2, ...}; even-odd fill, exact distance.
function Raster.polygon(sc: Scene, color: number, pts: { number }): number
	local v = sc.verts
	local first = #v + 1
	for i = 1, #pts do
		v[first + i - 1] = pts[i]
	end
	local s = push(sc, POLYGON, color, first, #pts // 2, 0, 0, 0, 0)
	updateBounds(sc, s)
	return s
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

-- A copy of the scene with every length multiplied by f (for rendering a mip
-- level directly at its own resolution; the AA width stays one output pixel).
function Raster.scaled(sc: Scene, f: number): Scene
	local out = Raster.newScene(0, sc.aa)
	out.bgR, out.bgG, out.bgB, out.bgA = sc.bgR, sc.bgG, sc.bgB, sc.bgA
	for i = 1, #sc.verts do
		out.verts[i] = sc.verts[i] * f
	end
	for s = 1, sc.n do
		local k = sc.kind[s]
		out.n = s
		out.kind[s] = k
		out.cr[s], out.cg[s], out.cb[s], out.ca[s] = sc.cr[s], sc.cg[s], sc.cb[s], sc.ca[s]
		if k == POLYGON then
			out.p1[s], out.p2[s], out.p3[s], out.p4[s], out.p5[s], out.p6[s] = sc.p1[s], sc.p2[s], 0, 0, 0, 0
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
function Raster.demoScene(n: number, size: number, seed: number, background: number?): Scene
	local sc = Raster.newScene(background or 0xFF201810)
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
-- The per-pixel path in shadeRect inlines the same formulas.
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
-- The shared per-pixel shading routine.
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
			shadeRect(sc, out, width, 0, y, width - 1, y, 0, list, 1, sc.n)
		end
	else
		shadeRect(sc, out, width, 0, 0, width - 1, height - 1, 0, list, 1, sc.n)
	end
end

-- Painter's algorithm over each shape's bounding box with an 8-bit framebuffer
-- (read, unpack, blend, pack, write per covered pixel). Fast to write, but it
-- rounds to 8 bits after every shape, so it is not identical to renderBrute.
function Raster.renderPainter(sc: Scene, out: buffer, width: number, height: number)
	local bg = (sc.bgR // 1) + (sc.bgG // 1) * 256 + (sc.bgB // 1) * 65536 + ((sc.bgA * 255 + 0.5) // 1) * 16777216
	Pixels.fill(out, bg)
	local one = { 0 }
	for s = 1, sc.n do
		one[1] = s
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
	local lists = table.create(tilesX * tilesY)
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
	local half = sc.aa * 0.5
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
		shadeRect(sc, out, width, x, y, x, y, base, stack, lo, hi)
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
		shadeRect(sc, out, width, x, y, x + w - 1, y + h - 1, nb, stack, nlo, nhi)
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
