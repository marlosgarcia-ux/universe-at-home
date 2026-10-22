--!strict
-- Flawless 2D pipeline (docs/COMPUTE.md "Flawless pipeline"). Every check is an
-- assertion; tests/run.sh runs this file in the interpreter and with --codegen.
--
--   1. MyMath coverage axioms: bit equality with the original implementations,
--      C3 closed form, C4 exactness and reach.
--   2. Exact primitives (disc and box, disc and polygon, polygon and box, datan2).
--   3. F1 per primitive: circles (r 0.3 to 300), sharp and rounded boxes, capsules
--      (r 0.5 to 50), rings, stars, random polygons, cut discs, at random
--      rotations and sub-pixel offsets: |byte - 255 A| <= 0.51.
--   4. F2 scenes: abutting half-discs, a checkerboard, a polygon split into
--      triangles, a pie chart, overlapping translucent shapes; Raster and
--      Scanline.renderScene against an independent exact scene reference; no
--      seams (while coverage-as-alpha, MODE_LAYERED, shows them); render ==
--      renderBrute.
--   5. LOD: every level rendered directly is exact at its level; levels agree with
--      the exact box filter (Filter.areaResample of level 0 within 1 LSB);
--      Filter.areaResampleAlpha is the exact box filter of straight-alpha content.
--   6. Saturn: selector (S1, S2), crossfade (X1, X2, X3), slot bookkeeping (Z),
--      checked by dense sampling.
--   7. F3: output hashes are constants both runtimes must reproduce.
--
-- The exact scene reference (refPixel) is independent of the code under test: a
-- vertical decomposition of the pixel by every boundary curve (segments and whole
-- circles), with breakpoints at curve ends and pairwise crossings, closed-form
-- integrals per trapezoid (math.asin: reference only), and the source-over
-- composite of the shapes covering each trapezoid's midpoint (exact inside tests).
-- Between breakpoints no boundary crosses another, so each trapezoid has a single
-- cover set: the reference is exact up to floating rounding (its accuracy is
-- checked against 50-digit values and against Coverage.circleArea / polygonArea).

local MyMath = require("../src/MyMath")
local Pixels = require("../src/Pixels")
local Coverage = require("../src/compute/Coverage")
local Raster = require("../src/compute/Raster")
local Scanline = require("../src/compute/Scanline")
local Filter = require("../src/compute/Filter")
local Visibility = require("../src/compute/Visibility")
local Saturn = require("../src/Saturn")

local PRINT = false -- set true to print measured maxima and regenerate the hash constants
local F1 = 0.51 -- correctly rounded exact area: 0.5 + epsilon 0.01 (COMPUTE.md F1)

local function report(name: string, value: number)
	if PRINT then
		print(string.format("%-60s %.4f", name, value))
	end
end

-- deterministic generator (identical in both runtimes)
local seed = 20261022
local function rnd(): number
	seed = MyMath.hash32((seed + 0x9E3779B9) % 4294967296)
	return seed / 4294967296
end

local function hashWords(b: buffer, count: number): number
	local h = 0
	for i = 0, count - 1 do
		h = (h * 31 + buffer.readu32(b, i * 4)) % 4294967291
	end
	return h
end

local hashes: { [string]: number } = {}
local function checkHash(name: string, got: number, want: number)
	hashes[name] = got
	if not PRINT then
		assert(got == want, string.format("%s: hash %d, expected %d (runtimes or platforms differ)", name, got, want))
	end
end

----------------------------------------------------------------------------------
-- Exact scene reference
----------------------------------------------------------------------------------

type RShape = {
	inside: (number, number) -> boolean,
	segs: { number }, -- x0, y0, x1, y1 per boundary segment
	circs: { number }, -- cx, cy, r per boundary circle (whole circles: a superset is fine)
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	r: number,
	g: number,
	b: number,
	a: number,
}
type RScene = { shapes: { RShape }, bgR: number, bgG: number, bgB: number, bgA: number }

local function newRef(background: number): RScene
	return {
		shapes = {},
		bgR = background % 256,
		bgG = (background // 256) % 256,
		bgB = (background // 65536) % 256,
		bgA = (background // 16777216) / 255,
	}
end

local function addRef(rs: RScene, color: number, inside: (number, number) -> boolean, segs: { number }, circs: { number })
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for k = 1, #segs, 2 do
		x0 = math.min(x0, segs[k])
		x1 = math.max(x1, segs[k])
		y0 = math.min(y0, segs[k + 1])
		y1 = math.max(y1, segs[k + 1])
	end
	for k = 1, #circs, 3 do
		local cx, cy, r = circs[k], circs[k + 1], circs[k + 2]
		x0 = math.min(x0, cx - r)
		x1 = math.max(x1, cx + r)
		y0 = math.min(y0, cy - r)
		y1 = math.max(y1, cy + r)
	end
	table.insert(rs.shapes, {
		inside = inside,
		segs = segs,
		circs = circs,
		x0 = x0,
		y0 = y0,
		x1 = x1,
		y1 = y1,
		r = color % 256,
		g = (color // 256) % 256,
		b = (color // 65536) % 256,
		a = (color // 16777216) / 255,
	})
end

-- Shapes added to a Raster scene and to its reference at once (same parameters).
local function circle(sc: Raster.Scene, rs: RScene, color: number, cx: number, cy: number, r: number)
	Raster.circle(sc, color, cx, cy, r)
	addRef(rs, color, function(x, y)
		return (x - cx) ^ 2 + (y - cy) ^ 2 < r * r
	end, {}, { cx, cy, r })
end

local function ring(sc: Raster.Scene, rs: RScene, color: number, cx: number, cy: number, r: number, t: number)
	Raster.ring(sc, color, cx, cy, r, t)
	local circs = { cx, cy, r + t }
	if r - t > 0 then
		table.insert(circs, cx)
		table.insert(circs, cy)
		table.insert(circs, r - t)
	end
	addRef(rs, color, function(x, y)
		return math.abs(math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2) - r) < t
	end, {}, circs)
end

local function box(sc: Raster.Scene, rs: RScene, color: number, cx: number, cy: number, hx: number, hy: number, rad: number)
	Raster.box(sc, color, cx, cy, hx, hy, rad)
	local ix, iy = hx - rad, hy - rad
	local segs = {
		cx - ix, cy - hy, cx + ix, cy - hy,
		cx - ix, cy + hy, cx + ix, cy + hy,
		cx - hx, cy - iy, cx - hx, cy + iy,
		cx + hx, cy - iy, cx + hx, cy + iy,
	}
	local circs = {}
	if rad > 0 then
		circs = { cx - ix, cy - iy, rad, cx + ix, cy - iy, rad, cx - ix, cy + iy, rad, cx + ix, cy + iy, rad }
	end
	addRef(rs, color, function(x, y)
		local qx, qy = math.abs(x - cx), math.abs(y - cy)
		if qx > hx or qy > hy then
			return false
		end
		if qx > ix and qy > iy then
			return (qx - ix) ^ 2 + (qy - iy) ^ 2 < rad * rad
		end
		return true
	end, segs, circs)
end

local function capsule(sc: Raster.Scene, rs: RScene, color: number, ax: number, ay: number, bx: number, by: number, r: number)
	Raster.segment(sc, color, ax, ay, bx, by, r)
	local dx, dy = bx - ax, by - ay
	local L = math.sqrt(dx * dx + dy * dy)
	local segs = {}
	if L > 0 then
		local nx, ny = -dy / L * r, dx / L * r
		segs = { ax + nx, ay + ny, bx + nx, by + ny, ax - nx, ay - ny, bx - nx, by - ny }
	end
	addRef(rs, color, function(x, y)
		local t = if L > 0 then ((x - ax) * dx + (y - ay) * dy) / (L * L) else 0
		t = math.clamp(t, 0, 1)
		return (x - ax - dx * t) ^ 2 + (y - ay - dy * t) ^ 2 < r * r
	end, segs, { ax, ay, r, bx, by, r })
end

local function polygon(sc: Raster.Scene, rs: RScene, color: number, pts: { number })
	Raster.polygon(sc, color, pts)
	local segs = {}
	local n = #pts // 2
	for i = 1, n do
		local j = i % n + 1
		table.insert(segs, pts[2 * i - 1])
		table.insert(segs, pts[2 * i])
		table.insert(segs, pts[2 * j - 1])
		table.insert(segs, pts[2 * j])
	end
	addRef(rs, color, function(x, y)
		local inside = false
		local jx, jy = pts[2 * n - 1], pts[2 * n]
		for i = 1, n do
			local ix, iy = pts[2 * i - 1], pts[2 * i]
			if (iy > y) ~= (jy > y) and x < (jx - ix) * (y - iy) / (jy - iy) + ix then
				inside = not inside
			end
			jx, jy = ix, iy
		end
		return inside
	end, segs, {})
end

-- disc and up to two half-planes n . (q - c) <= o (unit normals); the boundary
-- segments are the chords' lines across the disc's bounding box
local function cutDisc(sc: Raster.Scene, rs: RScene, color: number, cx: number, cy: number, r: number, n1x: number, n1y: number, o1: number, n2x: number?, n2y: number?, o2: number?)
	Raster.cutDisc(sc, color, cx, cy, r, n1x, n1y, o1, n2x, n2y, o2)
	local planes = { n1x, n1y, o1 }
	if n2x and n2y then
		table.insert(planes, n2x)
		table.insert(planes, n2y)
		table.insert(planes, o2 or 0)
	end
	local segs = {}
	for k = 1, #planes, 3 do
		local nx, ny, o = planes[k], planes[k + 1], planes[k + 2]
		-- the line through c + o n, direction (-ny, nx), long enough to span the disc
		local px, py = cx + o * nx, cy + o * ny
		local L = 2 * r + 2
		table.insert(segs, px - ny * L)
		table.insert(segs, py + nx * L)
		table.insert(segs, px + ny * L)
		table.insert(segs, py - nx * L)
	end
	addRef(rs, color, function(x, y)
		if (x - cx) ^ 2 + (y - cy) ^ 2 >= r * r then
			return false
		end
		for k = 1, #planes, 3 do
			if planes[k] * (x - cx) + planes[k + 1] * (y - cy) > planes[k + 2] then
				return false
			end
		end
		return true
	end, segs, { cx, cy, r })
end

local PI = math.pi
-- integral of sqrt(r^2 - s^2) from 0 to t, well conditioned as |t| -> r
local function chordInt(t: number, r: number): number
	if t >= r then
		return PI * r * r * 0.25
	elseif t <= -r then
		return -PI * r * r * 0.25
	end
	local a
	if t > 0.5 * r then
		a = PI * 0.5 - 2 * math.asin(math.sqrt((r - t) / (2 * r)))
	elseif t < -0.5 * r then
		a = 2 * math.asin(math.sqrt((r + t) / (2 * r))) - PI * 0.5
	else
		a = math.asin(t / r)
	end
	return 0.5 * (t * math.sqrt((r - t) * (r + t)) + r * r * a)
end

-- Exact box filter of the reference scene over the pixel [X0, X0 + 1] x [Y0, Y0 + 1]:
-- premultiplied r, g, b (0..255 * alpha) and alpha. Also returns the total area of
-- the trapezoids (1 up to rounding: a self-check).
local function refPixel(rs: RScene, X0: number, Y0: number): (number, number, number, number, number)
	local X1, Y1 = X0 + 1, Y0 + 1
	local rel: { RShape } = {}
	for _, s in rs.shapes do
		if s.x1 > X0 and s.x0 < X1 and s.y1 > Y0 and s.y0 < Y1 then
			table.insert(rel, s)
		end
	end
	-- curves near the pixel
	local segs: { number } = {}
	local circs: { number } = {}
	for _, s in rel do
		local S = s.segs
		for k = 1, #S, 4 do
			local ax, ay, bx, by = S[k], S[k + 1], S[k + 2], S[k + 3]
			if math.max(ax, bx) >= X0 and math.min(ax, bx) <= X1 and math.max(ay, by) >= Y0 and math.min(ay, by) <= Y1 then
				if ax > bx then
					ax, ay, bx, by = bx, by, ax, ay
				end
				table.insert(segs, ax)
				table.insert(segs, ay)
				table.insert(segs, bx)
				table.insert(segs, by)
			end
		end
		local C = s.circs
		for k = 1, #C, 3 do
			local cx, cy, r = C[k], C[k + 1], C[k + 2]
			local nx = math.clamp(cx, X0, X1) - cx
			local ny = math.clamp(cy, Y0, Y1) - cy
			local fx = math.max(math.abs(X0 - cx), math.abs(X1 - cx))
			local fy = math.max(math.abs(Y0 - cy), math.abs(Y1 - cy))
			if nx * nx + ny * ny <= r * r and fx * fx + fy * fy >= r * r then
				table.insert(circs, cx)
				table.insert(circs, cy)
				table.insert(circs, r)
			end
		end
	end
	local bps: { number } = { X0, X1 }
	local function bp(x: number)
		if x > X0 and x < X1 then
			table.insert(bps, x)
		end
	end
	local ns, nc = #segs // 4, #circs // 3
	for i = 0, ns - 1 do
		local ax, ay, bx, by = segs[4 * i + 1], segs[4 * i + 2], segs[4 * i + 3], segs[4 * i + 4]
		bp(ax)
		bp(bx)
		for _, Y in { Y0, Y1 } do
			if (ay - Y) * (by - Y) < 0 then
				bp(ax + (Y - ay) / (by - ay) * (bx - ax))
			end
		end
		for j = i + 1, ns - 1 do
			local cx0, cy0, dx1, dy1 = segs[4 * j + 1], segs[4 * j + 2], segs[4 * j + 3], segs[4 * j + 4]
			local ex, ey = bx - ax, by - ay
			local fx, fy = dx1 - cx0, dy1 - cy0
			local den = ex * fy - ey * fx
			if den ~= 0 then
				local t = ((cx0 - ax) * fy - (cy0 - ay) * fx) / den
				local u = ((cx0 - ax) * ey - (cy0 - ay) * ex) / den
				if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
					bp(ax + t * ex)
				end
			end
		end
		for j = 0, nc - 1 do
			local cx, cy, r = circs[3 * j + 1], circs[3 * j + 2], circs[3 * j + 3]
			local ex, ey = bx - ax, by - ay
			local fx, fy = ax - cx, ay - cy
			local A = ex * ex + ey * ey
			local B = 2 * (fx * ex + fy * ey)
			local Cc = fx * fx + fy * fy - r * r
			local disc = B * B - 4 * A * Cc
			if A > 0 and disc > 0 then
				local sd = math.sqrt(disc)
				for _, t in { (-B - sd) / (2 * A), (-B + sd) / (2 * A) } do
					if t >= 0 and t <= 1 then
						bp(ax + t * ex)
					end
				end
			end
		end
	end
	for i = 0, nc - 1 do
		local cx, cy, r = circs[3 * i + 1], circs[3 * i + 2], circs[3 * i + 3]
		bp(cx - r)
		bp(cx + r)
		for _, Y in { Y0, Y1 } do
			local dy = Y - cy
			if math.abs(dy) < r then
				local h = math.sqrt(r * r - dy * dy)
				bp(cx - h)
				bp(cx + h)
			end
		end
		for j = i + 1, nc - 1 do
			local cx2, cy2, r2 = circs[3 * j + 1], circs[3 * j + 2], circs[3 * j + 3]
			local dx, dy = cx2 - cx, cy2 - cy
			local d = math.sqrt(dx * dx + dy * dy)
			if d > 0 and d < r + r2 and d > math.abs(r - r2) then
				local a = (r * r - r2 * r2 + d * d) / (2 * d)
				local h = math.sqrt(math.max(0, r * r - a * a))
				local mx = cx + a * dx / d
				bp(mx - h * dy / d)
				bp(mx + h * dy / d)
			end
		end
	end
	table.sort(bps)
	local R, G, B, A, total = 0, 0, 0, 0, 0
	for k = 1, #bps - 1 do
		local u, v = bps[k], bps[k + 1]
		if v - u <= 1e-13 then
			continue
		end
		local xm = (u + v) * 0.5
		local w = v - u
		-- curve values at xm inside the pixel's y-range, with their integrals over [u, v]
		local ys: { number } = { Y0, Y1 }
		local ints: { number } = { Y0 * w, Y1 * w }
		for i = 0, ns - 1 do
			local ax, ay, bx, by = segs[4 * i + 1], segs[4 * i + 2], segs[4 * i + 3], segs[4 * i + 4]
			if ax <= u and bx >= v and bx > ax then
				local y = ay + (xm - ax) * (by - ay) / (bx - ax)
				if y > Y0 and y < Y1 then
					table.insert(ys, y)
					table.insert(ints, y * w)
				end
			end
		end
		for i = 0, nc - 1 do
			local cx, cy, r = circs[3 * i + 1], circs[3 * i + 2], circs[3 * i + 3]
			if cx - r <= u and cx + r >= v then
				local h = math.sqrt(math.max(0, r * r - (xm - cx) ^ 2))
				local I = chordInt(v - cx, r) - chordInt(u - cx, r)
				if cy + h > Y0 and cy + h < Y1 then
					table.insert(ys, cy + h)
					table.insert(ints, cy * w + I)
				end
				if cy - h > Y0 and cy - h < Y1 then
					table.insert(ys, cy - h)
					table.insert(ints, cy * w - I)
				end
			end
		end
		-- sort by y (insertion sort, carrying the integrals)
		for i = 2, #ys do
			local y, I = ys[i], ints[i]
			local j = i - 1
			while j >= 1 and ys[j] > y do
				ys[j + 1], ints[j + 1] = ys[j], ints[j]
				j -= 1
			end
			ys[j + 1], ints[j + 1] = y, I
		end
		for i = 1, #ys - 1 do
			if ys[i + 1] - ys[i] > 1e-13 then
				local area = ints[i + 1] - ints[i]
				local ym = (ys[i] + ys[i + 1]) * 0.5
				local r, g, b, a = rs.bgR * rs.bgA, rs.bgG * rs.bgA, rs.bgB * rs.bgA, rs.bgA
				for _, s in rel do
					if s.inside(xm, ym) then
						local f = 1 - s.a
						r, g, b, a = s.r * s.a + r * f, s.g * s.a + g * f, s.b * s.a + b * f, s.a + a * f
					end
				end
				R += r * area
				G += g * area
				B += b * area
				A += a * area
				total += area
			end
		end
	end
	return R, G, B, A, total
end

-- Max errors of an RGBA8 render against the reference over [x0, x1] x [y0, y1]:
-- alpha (in 1/255) and straight colour (in 1/255, where the exact alpha > 1e-6).
local function compareRef(img: buffer, W: number, rs: RScene, x0: number, y0: number, x1: number, y1: number): (number, number)
	local ma, mc = 0, 0
	for y = math.max(0, y0), math.min(W - 1, y1) do
		for x = math.max(0, x0), math.min(W - 1, x1) do
			local R, G, B, A, total = refPixel(rs, x, y)
			assert(math.abs(total - 1) < 1e-9, "reference does not tile the pixel")
			local o = (y * W + x) * 4
			ma = math.max(ma, math.abs(buffer.readu8(img, o + 3) - 255 * A))
			if A > 1e-6 then
				mc = math.max(mc, math.abs(buffer.readu8(img, o) - R / A), math.abs(buffer.readu8(img, o + 1) - G / A), math.abs(buffer.readu8(img, o + 2) - B / A))
			end
		end
	end
	return ma, mc
end

----------------------------------------------------------------------------------
-- 1. MyMath coverage axioms
----------------------------------------------------------------------------------

do
	-- verbatim copies of the implementations as they were in compute/Coverage.luau
	-- before the move (frozen here to prove the move kept every bit)
	local function halfPlaneOrig(d: number, nx: number, ny: number): number
		local a, b = math.abs(nx), math.abs(ny)
		if a < b then
			a, b = b, a
		end
		local u = (a + b) * 0.5 - d
		if u <= 0 then
			return 0
		end
		if u >= a + b then
			return 1
		end
		if u < b then
			return u * u / (2 * a * b)
		end
		if u <= a then
			return (2 * u - b) / (2 * a)
		end
		local v = a + b - u
		return 1 - v * v / (2 * a * b)
	end
	local function halfPlaneCurvedOrig(d: number, nx: number, ny: number, k: number): number
		local base = halfPlaneOrig(d, nx, ny)
		if k == 0 then
			return base
		end
		local t0, t1 = -1e300, 1e300
		local tx, ty = -ny, nx
		local ox, oy = -d * nx, -d * ny
		if tx ~= 0 then
			local a0 = (-0.5 - ox) / tx
			local a1 = (0.5 - ox) / tx
			if a0 > a1 then
				a0, a1 = a1, a0
			end
			if a0 > t0 then
				t0 = a0
			end
			if a1 < t1 then
				t1 = a1
			end
		elseif ox < -0.5 or ox > 0.5 then
			t1 = t0
		end
		if ty ~= 0 then
			local a0 = (-0.5 - oy) / ty
			local a1 = (0.5 - oy) / ty
			if a0 > a1 then
				a0, a1 = a1, a0
			end
			if a0 > t0 then
				t0 = a0
			end
			if a1 < t1 then
				t1 = a1
			end
		elseif oy < -0.5 or oy > 0.5 then
			t1 = t0
		end
		local c = base
		if t1 > t0 then
			c = base - k * (t1 * t1 * t1 - t0 * t0 * t0) / 6
		end
		return if c < 0 then 0 elseif c > 1 then 1 else c
	end
	assert(Coverage.halfPlane == MyMath.coverageHalfPlane, "Coverage.halfPlane is the MyMath axiom")
	assert(Coverage.halfPlaneCurved == MyMath.coverageCurved, "Coverage.halfPlaneCurved is the MyMath axiom")
	assert(Raster.covCurved == MyMath.coverageCurved, "Raster.covCurved is the MyMath axiom")
	assert(MyMath.COVERAGE_REACH == math.sqrt(2) / 2 and Coverage.HALF_PLANE_REACH == MyMath.COVERAGE_REACH, "reach")
	for i = 1, 200000 do
		local ang = rnd()
		local nx, ny = MyMath.dcosTurns(ang), MyMath.dsinTurns(ang)
		if i % 17 == 0 then
			nx, ny = 1, 0
		elseif i % 19 == 0 then
			nx, ny = 0, -1
		end
		local d = (rnd() - 0.5) * 2.2
		local k = if i % 5 == 0 then 0 else (rnd() - 0.3) * (if i % 3 == 0 then 3 else 0.2)
		assert(MyMath.coverageHalfPlane(d, nx, ny) == halfPlaneOrig(d, nx, ny), "coverageHalfPlane bits")
		assert(MyMath.coverageCurved(d, nx, ny, k) == halfPlaneCurvedOrig(d, nx, ny, k), "coverageCurved bits")
		assert(MyMath.coverageHalfPlane(d, nx, ny, 1) == halfPlaneOrig(d, nx, ny), "w = 1 is the identity")
		-- w scales the box filter: d / w and k * w
		local w = 0.25 + rnd() * 4
		assert(MyMath.coverageHalfPlane(d * w, nx, ny, w) == halfPlaneOrig((d * w) / w, nx, ny), "w scaling (half-plane)")
		assert(MyMath.coverageCurved(d * w, nx, ny, k / w, w) == halfPlaneCurvedOrig((d * w) / w, nx, ny, (k / w) * w), "w scaling (curved)")
		-- C4 reach: exactly 0 / 1 beyond sqrt(2)/2 for every normal
		if math.abs(d) >= MyMath.COVERAGE_REACH then
			assert(MyMath.coverageHalfPlane(d, nx, ny) == (if d > 0 then 0 else 1), "C4 reach")
		end
	end
	-- C3: the ramp's worst error on a 45 degree edge, (sqrt(2)/2 - 1/2)^2 = 10.94/255
	local s = math.sqrt(2) / 2
	local worst = 0
	for i = 0, 20000 do
		local d = -1 + i / 10000
		worst = math.max(worst, math.abs(MyMath.coverage(d, 1) - MyMath.coverageHalfPlane(d, s, s)))
	end
	assert(math.abs(worst - (s - 0.5) ^ 2) < 1e-7 and math.abs(worst * 255 - 10.94) < 0.01, "C3 closed form")
	-- C4: half-plane coverage is the exact area of the pixel and a straight edge
	local hp = 0
	for _ = 1, 3000 do
		local ang = rnd()
		local nx, ny = MyMath.dcosTurns(ang), MyMath.dsinTurns(ang)
		local d = (rnd() - 0.5) * 1.6
		local px, py = 0.5 - d * nx, 0.5 - d * ny
		local L = 50
		local poly = { px - ny * L, py + nx * L, px + ny * L, py - nx * L, px + ny * L - nx * L, py - nx * L - ny * L, px - ny * L - nx * L, py + nx * L - ny * L }
		hp = math.max(hp, math.abs(MyMath.coverageHalfPlane(d, nx, ny) - Coverage.polygonArea(poly, 0, 0)))
	end
	assert(hp < 1e-9, "C4 exactness " .. hp)
	-- C5: the curvature estimator is NOT flawless below R of a few hundred (O(1/R) residual)
	local worstC = 0
	for k = 1, 40 do
		local R = 8
		local cx, cy = 50 + rnd(), 50 + rnd()
		for y = 40, 60 do
			for x = 40, 60 do
				local dx, dy = x + 0.5 - cx, y + 0.5 - cy
				local len = math.sqrt(dx * dx + dy * dy)
				if math.abs(len - R) < 0.71 then
					worstC = math.max(worstC, 255 * math.abs(MyMath.coverageCurved(len - R, dx / len, dy / len, 1 / R) - Coverage.circleArea(cx, cy, R, x, y)))
				end
			end
		end
		local _ = k
	end
	report("C5 curvature estimator worst error at R = 8 (1/255)", worstC)
	assert(worstC > 0.05, "C5 residual should be visible at R = 8")
end

----------------------------------------------------------------------------------
-- 2. Exact primitives
----------------------------------------------------------------------------------

do
	-- Ground truth: areas of disc (cx, cy, r) and pixel [x0, x0 + 1] x [y0, y0 + 1]
	-- computed with 50-digit decimal arithmetic (Python decimal, closed form), for
	-- radii 0.05 to 5000 and pixels at vertical and horizontal tangents, where
	-- plain x-integration loses about 1e-8 r^2 (the original circleArea did:
	-- 6.5e-7 at r = 30.6, 1.4e-6 at r = 4439). Columns: cx, cy, r, x0, y0, area.
	local cases = {
		{ 1.3304862007498741, 1.9807719059754163, 4439.1749620987594, 4440, 0, 0.50519194344476288962860308 },
		{ 2.8382096055429429, 2.2924320255406201, 30.568328245890587, 33, 2, 0.40446990380783530550428018 },
		{ 2.7903428881407555, 1.0833192561501321, 0.2296583975627937, 3, 1, 0.0024992600434305427743399 },
		{ 2.1607865987247643, 2.5750360195120896, 100.6597912847737, 8, 102, 1.0000000000000000000000000 },
		{ 2.516228617455269, 1.1255533915429154, 223.93004046929866, 161, 159, 0.0531512841448493345260044 },
		{ 0.17610649362743935, 2.559762028862127, 9.422846340855907, 4, 12, 0.0000000000000000000000000 },
		{ 2.0679175439708395, 1.4095423774047617, 73.42313460403912, 1, 74, 0.8299130259446170010605623 },
		{ 0.25248736919421655, 0.2959130532185025, 51.9943760834282, 34, -40, 0.0388406683324685607740124 },
		{ 0.6140982456998522, 0.3435958270729079, 2365.004245543208, -4, -2365, 0.6570537076026846033837670 },
		{ 2.3674026005144873, 1.9855250411091805, 37.55088209726646, -16, 33, 1.0000000000000000000000000 },
		{ 0.4380600639076153, 2.9148125741852207, 0.365511092115542, 0, 3, 0.1481503712233460130027819 },
		{ 1.7841195424041063, 1.4723852737284202, 0.15162720079186315, 1, -1, 0.0000000000000000000000000 },
		{ 0.8576920553105568, 0.6215270110565962, 9.636178427288485, 10, 0, 0.4887773666903404777213993 },
		{ 0.814833200611362, 0.818923160312339, 0.0548192656285202, 0, -1, 0.0000000000000000000000000 },
		{ 2.8633109031765556, 1.927586534125945, 131.64101780106574, 3, 134, 0.0000000000000000000000000 },
		{ 1.177799150841218, 1.1301545604979708, 223.0739983965364, -215, 58, 0.3926542034490220796161281 },
		{ 0.6760274874267226, 0.2825960659889819, 0.0820297315143495, -1, -1, 0.0000000000000000000000000 },
		{ 2.372253756454973, 1.7478058828808103, 0.39829366956691725, 2, 1, 0.4307548364668006258653318 },
		{ 1.6721172171917187, 0.31846285417105313, 105.13648090302809, 106, -1, 0.8050159535983754590384922 },
		{ 1.9410282915610675, 2.5844543271735723, 0.07447628403113521, 1, 3, 0.0000000000000000000000000 },
		{ 1.88619792915152, 1.3435205961110392, 0.7174031567955261, 2, -1, 0.0000000000000000000000000 },
		{ 0.9709657693416778, 0.9415905278995296, 0.9569800774087931, -1, 1, 0.0000000000000000000000000 },
		{ 2.1024757087351373, 0.25978251848410383, 1.3080062376773214, 1, 0, 0.9995677884980603044823312 },
		{ 0.47735659764630367, 0.009094009650470247, 0.5672936462595175, 1, -1, 0.0062143326264565009784710 },
		{ 0.030894528881144634, 1.4981063904331102, 6.948317257618922, -1, 9, 0.0000000000000000000000000 },
		{ 2.76508365111287, 0.4689950289760858, 21.41478150355469, -8, 17, 1.0000000000000000000000000 },
		{ 2.8776527742643543, 2.2253248313978835, 2678.4763707982147, 2681, 1, 0.3539098082752205890734802 },
		{ 1.2598772249548653, 2.0994979794895547, 40.985882773401194, -39, -8, 0.5848721625977123379802625 },
		{ 0.7806509876850054, 0.5630240160920913, 2.670087723082545, 1, -3, 0.0308190257579625624207583 },
		{ 0.7066946567751169, 1.7006578286923157, 0.1749685773700509, 0, 2, 0.0000000000000000000000000 },
		{ 2.8260757560851477, 0.3617340541631192, 0.07706450299139286, 2, 0, 0.0186577228012367911952518 },
		{ 0.7974469009184121, 0.8101102313734448, 15.593503710945908, -11, 11, 0.5482882319436382425016725 },
		{ 1.9711313478905437, 1.8094795233955512, 5.740637899434372, 7, 5, 0.0000000000000000000000000 },
		{ 1.5913483054258255, 0.31455608925464384, 3.0315384619633265, 1, -4, 0.0000000000000000000000000 },
		{ 1.0432207908656435, 0.3830294849445214, 2.622818144077784, 3, 0, 0.6474065374077649964481284 },
		{ 0.013324798293945839, 2.0795673234373684, 32.195417093803606, -33, 6, 0.0000000000000000000000000 },
		{ 0.8775337391765505, 0.760520705440442, 0.21475182935454146, 0, 0, 0.1220328972872272794435265 },
		{ 1.1342618230085362, 2.8281889648696166, 373.32871226858634, 195, -316, 0.8743223893248712454922503 },
		{ 1.8262845244791595, 2.0359887661388973, 60.7111034671654, 2, 62, 0.7426675394406031713474984 },
		{ 2.9036942927246567, 2.707710628854695, 1081.3043902976463, 1084, 7, 0.1974264046686062002961592 },
		{ 1.9941335616373075, 1.6427566744857138, 7.340146472231407, 1, 10, 0.0000000000000000000000000 },
		{ 2.447686676558579, 0.5873791622868699, 1.4233809939731141, 3, 2, 0.0000000000000000000000000 },
	}
	local wt = 0
	for _, c in cases do
		local tol = 1e-12 * math.max(1, c[3] * c[3]) -- double rounding of terms of size r^2
		local got = Coverage.discBoxArea(c[1], c[2], c[3], c[4], c[5], c[4] + 1, c[5] + 1)
		assert(math.abs(got - c[6]) < tol, "discBoxArea vs 50-digit reference " .. got)
		local px = { c[4], c[4] + 1, c[4] + 1, c[4] }
		local py = { c[5], c[5], c[5] + 1, c[5] + 1 }
		assert(math.abs(Coverage.discPolyArea(px, py, 4, c[1], c[2], c[3]) - c[6]) < tol, "discPolyArea vs 50-digit reference")
		assert(math.abs(Coverage.circleArea(c[1], c[2], c[3], c[4], c[5]) - c[6]) < tol, "circleArea (reference) vs 50-digit reference")
		wt = math.max(wt, math.abs(got - c[6]))
	end
	report("discBoxArea worst error vs 50-digit cases (r up to 5000)", wt)
	-- datan2 against libm (reference only)
	local wa = 0
	for i = 1, 20000 do
		local s, c = (rnd() - 0.5) * 10 ^ (rnd() * 4 - 2), (rnd() - 0.5) * 10 ^ (rnd() * 4 - 2)
		if i % 7 == 0 then
			s = 0
		end
		wa = math.max(wa, math.abs(Coverage.datan2(s, c) - math.atan2(s, c)))
	end
	assert(wa < 1e-15, "datan2 accuracy " .. wa)
	-- disc and box: two independent exact methods agree (radius 0.05 to 5000), and
	-- both agree with the closed-form reference where it is well conditioned (r <= 300)
	local SX, SY = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
	local wb, wr = 0, 0
	for i = 1, 20000 do
		local r = 0.05 * 100000 ^ rnd()
		local cx, cy = rnd() * 3, rnd() * 3
		local ang = rnd() * 2 * PI
		local x0 = math.floor(cx + math.cos(ang) * r + (rnd() - 0.5) * 3)
		local y0 = math.floor(cy + math.sin(ang) * r + (rnd() - 0.5) * 3)
		if i % 4 == 0 then
			x0 = math.floor(cx + (rnd() - 0.5) * 4)
			y0 = math.floor(cy + (rnd() - 0.5) * 4)
		end
		SX[1], SY[1], SX[2], SY[2], SX[3], SY[3], SX[4], SY[4] = x0, y0, x0 + 1, y0, x0 + 1, y0 + 1, x0, y0 + 1
		local a = Coverage.discBoxArea(cx, cy, r, x0, y0, x0 + 1, y0 + 1)
		local b = Coverage.discPolyArea(SX, SY, 4, cx, cy, r)
		wb = math.max(wb, math.abs(a - b))
		if r <= 300 then
			wr = math.max(wr, math.abs(a - Coverage.circleArea(cx, cy, r, x0, y0)))
		end
	end
	assert(wb < 1e-8 and wr < 1e-9, string.format("disc areas disagree: %g %g", wb, wr))
	-- polygon and box: per-edge integrals == clip + shoelace
	local wp = 0
	for _ = 1, 300 do
		local n = 3 + (rnd() * 12) // 1
		local pts = {}
		local cx, cy, rr = 5 + rnd() * 3, 5 + rnd() * 3, 0.3 + rnd() * 6
		for k = 0, n - 1 do
			local t = (k + rnd() * 0.9) / n * 2 * PI
			local rk = rr * (0.2 + 0.8 * rnd())
			table.insert(pts, cx + rk * math.cos(t))
			table.insert(pts, cy + rk * math.sin(t))
		end
		for y = 0, 14 do
			for x = 0, 14 do
				wp = math.max(wp, math.abs(Coverage.polygonArea(pts, x, y) - math.abs(Coverage.polygonBoxCoverage(pts, 1, n, x, y, 1))))
			end
		end
	end
	assert(wp < 1e-12, "polygonBoxCoverage " .. wp)
	-- the reference itself: single circles and polygons against the closed forms
	local rs = newRef(0)
	local sc0 = Raster.newScene(0)
	circle(sc0, rs, 0xFFFFFFFF, 10.37, 9.81, 6.3)
	local wref = 0
	for y = 2, 17 do
		for x = 2, 17 do
			local _, _, _, A = refPixel(rs, x, y)
			wref = math.max(wref, math.abs(A - Coverage.circleArea(10.37, 9.81, 6.3, x, y)))
		end
	end
	local pts = { 3.3, 4.1, 17.9, 6.2, 12.4, 18.8, 8.8, 9.9 }
	rs = newRef(0)
	polygon(sc0, rs, 0xFFFFFFFF, pts)
	for y = 2, 19 do
		for x = 2, 18 do
			local _, _, _, A = refPixel(rs, x, y)
			wref = math.max(wref, math.abs(A - Coverage.polygonArea(pts, x, y)))
		end
	end
	assert(wref < 1e-10, "scene reference vs closed forms " .. wref)
end

----------------------------------------------------------------------------------
-- 3. F1 per primitive (Raster's default mode is the flawless one)
----------------------------------------------------------------------------------

do
	assert(Raster.newScene(0).mode == Raster.MODE_EXACT, "MODE_EXACT is the default")
	local W = 160
	local img = buffer.create(W * W * 4)
	local maxima: { [string]: number } = {}
	-- renders one white shape on transparent black and compares its alpha with the
	-- reference over the shape's box (pixels far from the edge must be exactly 0/255)
	local function check(name: string, size: number, build: (Raster.Scene, RScene) -> ())
		local sc = Raster.newScene(0x00000000)
		local rs = newRef(0x00000000)
		build(sc, rs)
		local out = if size == W then img else buffer.create(size * size * 4)
		buffer.fill(out, 0, 0)
		Raster.render(sc, Raster.bin(sc, size, size), out, size, size, 8)
		local s = rs.shapes[1]
		local worst = 0
		for y = math.max(0, math.floor(s.y0) - 2), math.min(size - 1, math.ceil(s.y1) + 1) do
			for x = math.max(0, math.floor(s.x0) - 2), math.min(size - 1, math.ceil(s.x1) + 1) do
				local d = Raster.sdf(sc, 1, x + 0.5, y + 0.5)
				local A
				if d > 0.75 then
					A = 0
				elseif d < -0.75 then
					A = 1
				else
					local _, _, _, a = refPixel(rs, x, y)
					A = a
				end
				worst = math.max(worst, math.abs(buffer.readu8(out, (y * size + x) * 4 + 3) - 255 * A))
			end
		end
		maxima[name] = math.max(maxima[name] or 0, worst)
		assert(worst <= F1, string.format("F1 %s: error %.4f/255", name, worst))
	end
	-- circles, radius 0.3 to 300
	for i = 1, 24 do
		local r = 0.3 * 1000 ^ ((i - 1) / 23)
		local size = if r > 70 then 2 * math.ceil(r) + 8 else W
		local c = size / 2 + rnd() - 0.5
		check("circle r 0.3..300", size, function(sc, rs)
			circle(sc, rs, 0xFFFFFFFF, c, c + rnd() - 0.5, r)
		end)
	end
	-- sharp and rounded boxes, including boxes thinner than a pixel
	for i = 1, 30 do
		local hx, hy = 0.15 + rnd() * 40, 0.15 + rnd() * 40
		if i % 5 == 0 then
			hy = 0.1 + rnd() * 0.6
		end
		local rad = if i % 3 == 0 then 0 else rnd() * math.min(hx, hy)
		check(if rad == 0 then "box sharp" else "box rounded", W, function(sc, rs)
			box(sc, rs, 0xFFFFFFFF, 80 + rnd() - 0.5, 80 + rnd() - 0.5, hx, hy, rad)
		end)
	end
	-- capsules, radius 0.5 to 50, random orientation and offset
	for i = 1, 30 do
		local r = 0.5 * 100 ^ ((i - 1) / 29)
		local len = rnd() * (60 - r)
		local ang = rnd() * 2 * PI
		local ax, ay = 80 - math.cos(ang) * len / 2 + rnd() - 0.5, 80 - math.sin(ang) * len / 2 + rnd() - 0.5
		check("capsule r 0.5..50", W, function(sc, rs)
			capsule(sc, rs, 0xFFFFFFFF, ax, ay, ax + math.cos(ang) * len, ay + math.sin(ang) * len, r)
		end)
	end
	-- rings (thin rings put both edges in one pixel)
	for i = 1, 16 do
		local r = 1 + rnd() * 60
		local t = if i % 4 == 0 then 0.05 + rnd() * 0.4 else 0.3 + rnd() * 8
		check("ring", W, function(sc, rs)
			ring(sc, rs, 0xFFFFFFFF, 80 + rnd() - 0.5, 80 + rnd() - 0.5, r, t)
		end)
	end
	-- stars at random rotations, and random simple (star-shaped) polygons
	for i = 1, 12 do
		local rr = 2 + rnd() * 60
		local rot = rnd()
		local cx, cy = 80 + rnd() - 0.5, 80 + rnd() - 0.5
		local pts = {}
		for k = 0, 9 do
			local q = if k % 2 == 0 then rr else rr * (0.3 + 0.3 * rnd())
			table.insert(pts, cx + math.cos(2 * PI * (rot + k / 10)) * q)
			table.insert(pts, cy + math.sin(2 * PI * (rot + k / 10)) * q)
		end
		check("star", W, function(sc, rs)
			polygon(sc, rs, 0xFFFFFFFF, pts)
		end)
		local n = 3 + (rnd() * 14) // 1
		local poly = {}
		for k = 0, n - 1 do
			local t = (k + rnd() * 0.9) / n * 2 * PI
			local q = (1 + rnd() * 50) * (0.15 + 0.85 * rnd())
			table.insert(poly, cx + math.cos(t) * q)
			table.insert(poly, cy + math.sin(t) * q)
		end
		check("random polygon", W, function(sc, rs)
			polygon(sc, rs, 0xFFFFFFFF, poly)
		end)
		local _ = i
	end
	-- cut discs: circular segments, half-discs and pie slices
	for i = 1, 12 do
		local r = 0.5 + rnd() * 50
		local a1 = rnd()
		local n1x, n1y = MyMath.dcosTurns(a1), MyMath.dsinTurns(a1)
		check("cut disc", W, function(sc, rs)
			if i % 2 == 0 then
				local a2 = a1 + 0.1 + rnd() * 0.35
				cutDisc(sc, rs, 0xFFFFFFFF, 80 + rnd() - 0.5, 80 + rnd() - 0.5, r, n1x, n1y, 0, -MyMath.dcosTurns(a2), -MyMath.dsinTurns(a2), 0)
			else
				cutDisc(sc, rs, 0xFFFFFFFF, 80 + rnd() - 0.5, 80 + rnd() - 0.5, r, n1x, n1y, (rnd() - 0.5) * r)
			end
		end)
	end
	for name, v in maxima do
		report("F1 max error, " .. name .. " (1/255)", v)
	end
end

----------------------------------------------------------------------------------
-- 4. F2 scenes
----------------------------------------------------------------------------------

local f2Hash = 0
do
	local W = 72
	type Scene = { name: string, sc: Raster.Scene, rs: RScene, seam: boolean, paths: { Scanline.Path }? }
	local scenes: { Scene } = {}
	local function newScene(name: string, bg: number, seam: boolean): Scene
		local s: Scene = { name = name, sc = Raster.newScene(bg), rs = newRef(bg), seam = seam, paths = nil }
		table.insert(scenes, s)
		return s
	end
	-- (a) two half-discs sharing a diameter at an arbitrary angle: different colours,
	-- and the same colour (their union is the disc: no seam may remain)
	do
		local a = rnd()
		local nx, ny = MyMath.dcosTurns(a), MyMath.dsinTurns(a)
		local s = newScene("half-discs, two colours", 0xFF102030, true)
		cutDisc(s.sc, s.rs, 0xFF2080F0, 36.3, 35.8, 27.4, nx, ny, 0)
		cutDisc(s.sc, s.rs, 0xFFF0A020, 36.3, 35.8, 27.4, -nx, -ny, 0)
		local t = newScene("half-discs, one colour", 0x00000000, true)
		cutDisc(t.sc, t.rs, 0xFFFFFFFF, 36.3, 35.8, 27.4, nx, ny, 0)
		cutDisc(t.sc, t.rs, 0xFFFFFFFF, 36.3, 35.8, 27.4, -nx, -ny, 0)
	end
	-- (b) a checkerboard of 7 x 7 squares at sub-pixel offsets (dyadic coordinates,
	-- so neighbours share their edges exactly)
	do
		local s = newScene("checkerboard", 0xFF000000, true)
		local side, ox, oy = 8.625, 5.3125, 4.6875
		local paths: { Scanline.Path } = {}
		for j = 0, 6 do
			for i = 0, 6 do
				local col = if (i + j) % 2 == 0 then 0xFFF0F0F0 else 0xFF3060C0
				local x0, y0 = ox + i * side, oy + j * side
				box(s.sc, s.rs, col, x0 + side / 2, y0 + side / 2, side / 2, side / 2, 0)
				table.insert(paths, { contours = { { x0, y0, x0 + side, y0, x0 + side, y0 + side, x0, y0 + side } }, color = col })
			end
		end
		s.paths = paths
	end
	-- (c) a polygon split into triangles (a fan from an interior point), each its own colour
	do
		local s = newScene("polygon split into triangles", 0xFF202020, true)
		local t = newScene("polygon split, one colour", 0x00000000, true)
		local cx, cy = 35.7, 36.2
		local n = 9
		local outer = {}
		for k = 0, n - 1 do
			local ang = 2 * PI * (k + 0.37 * rnd()) / n
			local q = 18 + rnd() * 14
			table.insert(outer, cx + math.cos(ang) * q)
			table.insert(outer, cy + math.sin(ang) * q)
		end
		local pa: { Scanline.Path } = {}
		local pb: { Scanline.Path } = {}
		for k = 0, n - 1 do
			local j = (k + 1) % n
			local tri = { cx, cy, outer[2 * k + 1], outer[2 * k + 2], outer[2 * j + 1], outer[2 * j + 2] }
			local col = 0xFF000000 + ((rnd() * 0xFFFFFF) // 1)
			polygon(s.sc, s.rs, col, tri)
			polygon(t.sc, t.rs, 0xFFFFFFFF, tri)
			table.insert(pa, { contours = { tri }, color = col })
			table.insert(pb, { contours = { tri }, color = 0xFFFFFFFF })
		end
		s.paths = pa
		t.paths = pb
	end
	-- (d) a pie chart: seven slices that share every boundary ray
	do
		local s = newScene("pie chart", 0xFF181818, true)
		local dirs: { [number]: { number } } = {}
		for k = 0, 6 do
			local tt = k / 7 + 0.05
			dirs[k] = { MyMath.dcosTurns(tt), MyMath.dsinTurns(tt) }
		end
		dirs[7] = dirs[0]
		for k = 0, 6 do
			local col = 0xFF000000 + ((rnd() * 0xFFFFFF) // 1)
			Raster.pie(s.sc, col, 36.4, 35.9, 29.3, dirs[k][1], dirs[k][2], dirs[k + 1][1], dirs[k + 1][2])
			-- reference: disc and the two half-planes of Raster.pie
			local ax, ay, bx, by = dirs[k][1], dirs[k][2], dirs[k + 1][1], dirs[k + 1][2]
			local planes = { ay, -ax, 0, -by, bx, 0 }
			local segs = {}
			for p = 1, 6, 3 do
				local nx, ny = planes[p], planes[p + 1]
				table.insert(segs, 36.4 - ny * 40)
				table.insert(segs, 35.9 + nx * 40)
				table.insert(segs, 36.4 + ny * 40)
				table.insert(segs, 35.9 - nx * 40)
			end
			addRef(s.rs, col, function(x, y)
				local dx, dy = x - 36.4, y - 35.9
				return dx * dx + dy * dy < 29.3 * 29.3 and planes[1] * dx + planes[2] * dy <= 0 and planes[4] * dx + planes[5] * dy <= 0
			end, segs, { 36.4, 35.9, 29.3 })
		end
	end
	-- (e) overlapping shapes of different colours, some translucent, over a translucent background
	do
		local s = newScene("overlapping translucent shapes", 0x80403020, false)
		for k = 1, 22 do
			local col = (((rnd() * 0xFFFFFF) // 1) + (if rnd() < 0.5 then 255 else 80 + (rnd() * 150) // 1) * 16777216)
			local cx, cy, r = 6 + rnd() * 60, 6 + rnd() * 60, 2 + rnd() * 16
			local kind = k % 6
			if kind == 0 then
				circle(s.sc, s.rs, col, cx, cy, r)
			elseif kind == 1 then
				ring(s.sc, s.rs, col, cx, cy, r, 0.4 + rnd() * 3)
			elseif kind == 2 then
				local ang = rnd() * 2 * PI
				capsule(s.sc, s.rs, col, cx, cy, cx + math.cos(ang) * r * 1.5, cy + math.sin(ang) * r * 1.5, 0.6 + rnd() * 4)
			elseif kind == 3 then
				box(s.sc, s.rs, col, cx, cy, r, r * (0.3 + rnd()), rnd() * r * 0.3)
			elseif kind == 4 then
				local pts = {}
				local rot = rnd()
				for q = 0, 9 do
					local rr = if q % 2 == 0 then r else r * 0.45
					table.insert(pts, cx + math.cos(2 * PI * (rot + q / 10)) * rr)
					table.insert(pts, cy + math.sin(2 * PI * (rot + q / 10)) * rr)
				end
				polygon(s.sc, s.rs, col, pts)
			else
				local a = rnd()
				cutDisc(s.sc, s.rs, col, cx, cy, r, MyMath.dcosTurns(a), MyMath.dsinTurns(a), (rnd() - 0.5) * r)
			end
		end
	end
	local a = buffer.create(W * W * 4)
	local b = buffer.create(W * W * 4)
	for _, s in scenes do
		-- exact compositing: no seam, every channel correctly rounded
		Raster.resetStats()
		Raster.render(s.sc, Raster.bin(s.sc, W, W), a, W, W, 8)
		local conflicts = Raster.stats.conflicts
		Raster.renderBrute(s.sc, b, W, W)
		assert(Pixels.diff(a, b, W * W) == 0, "render != renderBrute (" .. s.name .. ")")
		local ma, mc = compareRef(a, W, s.rs, 0, 0, W - 1, W - 1)
		report("F2 " .. s.name .. ": alpha / colour max error (1/255)", math.max(ma, mc))
		assert(ma <= F1 and mc <= F1, string.format("F2 %s: alpha %.3f colour %.3f", s.name, ma, mc))
		assert(conflicts > 0, "scene has no conflict pixels: " .. s.name)
		f2Hash = (f2Hash * 31 + hashWords(a, W * W)) % 4294967291
		-- coverage as alpha (MODE_LAYERED) leaves the conflation seam the exact path removes
		if s.seam then
			local layered = Raster.newScene(0)
			for k, v in s.sc :: any do
				(layered :: any)[k] = v
			end
			layered.mode = Raster.MODE_LAYERED
			Raster.renderBrute(layered, b, W, W)
			local la, lc = compareRef(b, W, s.rs, 0, 0, W - 1, W - 1)
			report("    same scene composited as alpha (seam, 1/255)", math.max(la, lc))
			assert(math.max(la, lc) > 10, "expected a conflation seam with coverage as alpha: " .. s.name)
		end
		-- the scanline scene renderer, where the scene is polygons
		local paths = s.paths
		if paths then
			local bg = s.rs.bgR + s.rs.bgG * 256 + s.rs.bgB * 65536 + ((s.rs.bgA * 255 + 0.5) // 1) * 16777216
			local st = Scanline.renderScene(a, W, W, paths, bg)
			local sa, sc2 = compareRef(a, W, s.rs, 0, 0, W - 1, W - 1)
			report("F2 " .. s.name .. ", Scanline.renderScene (1/255)", math.max(sa, sc2))
			assert(sa <= F1 and sc2 <= F1 and st.conflicts > 0, "Scanline.renderScene F2: " .. s.name)
			f2Hash = (f2Hash * 31 + hashWords(a, W * W)) % 4294967291
		end
	end
	-- a multi-path scene painted path by path with Scanline.composite conflates (C11)
	local s = scenes[5] -- polygon split, one colour
	local acc = Scanline.new(W, W)
	buffer.fill(a, 0, 0)
	for _, p in s.paths :: { Scanline.Path } do
		Scanline.addPolygon(acc, p.contours[1])
		Scanline.composite(acc, a, p.color)
	end
	local seam = compareRef(a, W, s.rs, 0, 0, W - 1, W - 1)
	assert(seam > 10, "sequential Scanline.composite should conflate")
	assert(Visibility.stats.capped == 0, "visibility term cap reached")
end

----------------------------------------------------------------------------------
-- 5. LOD: levels rendered directly are exact; levels agree with the box filter
----------------------------------------------------------------------------------

local lodHash = 0
do
	local S0 = 96
	-- an opaque scene built at scale f (both the Raster scene and its reference)
	local function build(f: number): (Raster.Scene, RScene)
		local sc = Raster.newScene(0xFF282018)
		local rs = newRef(0xFF282018)
		local g = 4242
		local function r2(): number
			g = MyMath.hash32((g + 0x9E3779B9) % 4294967296)
			return g / 4294967296
		end
		for k = 1, 18 do
			local col = (((r2() * 0xFFFFFF) // 1) + (if k % 4 == 0 then 140 else 255) * 16777216)
			local cx, cy, r = (8 + r2() * 80) * f, (8 + r2() * 80) * f, (3 + r2() * 20) * f
			if k % 3 == 0 then
				circle(sc, rs, col, cx, cy, r)
			elseif k % 3 == 1 then
				local ang = r2() * 2 * PI
				capsule(sc, rs, col, cx, cy, cx + math.cos(ang) * r, cy + math.sin(ang) * r, (1 + r2() * 4) * f)
			else
				box(sc, rs, col, cx, cy, r, r * 0.6, r * 0.2)
			end
		end
		return sc, rs
	end
	local sc0, _ = build(1)
	local img0 = buffer.create(S0 * S0 * 4)
	Raster.render(sc0, Raster.bin(sc0, S0, S0), img0, S0, S0, 8)
	for _, lvl in { 1, 2 } do
		local f = 1 / 2 ^ lvl
		local S = S0 // 2 ^ lvl
		-- Raster.scaled renders the level directly: exact at its own resolution
		local scl = Raster.scaled(sc0, f)
		local img = buffer.create(S * S * 4)
		Raster.render(scl, Raster.bin(scl, S, S), img, S, S, 8)
		local _, rsl = build(f)
		local ma, mc = compareRef(img, S, rsl, 0, 0, S - 1, S - 1)
		report(string.format("LOD level %d rendered directly, max error (1/255)", lvl), math.max(ma, mc))
		assert(ma <= F1 and mc <= F1, "LOD level not exact")
		lodHash = (lodHash * 31 + hashWords(img, S * S)) % 4294967291
		-- the exact box filter of level 0 (opaque: Filter.areaResample) agrees within 1 LSB
		local down = Filter.areaResample(img0, S0, S0, S, S)
		local worst = 0
		for i = 0, S * S * 4 - 1 do
			worst = math.max(worst, math.abs(buffer.readu8(down, i) - buffer.readu8(img, i)))
		end
		assert(worst <= 1, "levels disagree with the box filter of level 0 by " .. worst)
		assert(Pixels.diff(Filter.areaResampleAlpha(img0, S0, S0, S, S), down, S * S) == 0, "alpha resample == plain on opaque content")
	end
	-- straight-alpha raster content: areaResampleAlpha is the exact (alpha-weighted) box filter
	local w, h = 23, 17
	local src = buffer.create(w * h * 4)
	for i = 0, w * h - 1 do
		local v = MyMath.hash32(i * 13 + 5)
		if i % 4 == 0 then
			v %= 16777216 -- alpha 0 with a colour that must not bleed
		end
		buffer.writeu32(src, i * 4, v)
	end
	for _, d in { { 9, 7 }, { 23, 17 }, { 4, 3 }, { 11, 8 } } do
		local dw, dh = d[1], d[2]
		local out = Filter.areaResampleAlpha(src, w, h, dw, dh)
		for j = 0, dh - 1 do
			for i = 0, dw - 1 do
				local SA, S0c, S1c, S2c = 0, 0, 0, 0
				for yy = 0, h - 1 do
					local oy = math.min((j + 1) * h, (yy + 1) * dh) - math.max(j * h, yy * dh)
					if oy > 0 then
						for xx = 0, w - 1 do
							local ox = math.min((i + 1) * w, (xx + 1) * dw) - math.max(i * w, xx * dw)
							if ox > 0 then
								local o = (yy * w + xx) * 4
								local aw = ox * oy * buffer.readu8(src, o + 3)
								SA += aw
								S0c += aw * buffer.readu8(src, o)
								S1c += aw * buffer.readu8(src, o + 1)
								S2c += aw * buffer.readu8(src, o + 2)
							end
						end
					end
				end
				local T = w * h
				local o = (j * dw + i) * 4
				assert(buffer.readu8(out, o + 3) == (2 * SA + T) // (2 * T), "areaResampleAlpha alpha")
				if SA > 0 then
					assert(buffer.readu8(out, o) == (2 * S0c + SA) // (2 * SA), "areaResampleAlpha colour")
					assert(buffer.readu8(out, o + 1) == (2 * S1c + SA) // (2 * SA), "areaResampleAlpha colour")
					assert(buffer.readu8(out, o + 2) == (2 * S2c + SA) // (2 * SA), "areaResampleAlpha colour")
				end
			end
		end
		lodHash = (lodHash * 31 + hashWords(out, dw * dh)) % 4294967291
	end
end

----------------------------------------------------------------------------------
-- 6. Saturn
----------------------------------------------------------------------------------

do
	local th = Saturn.halvingThresholds(6) -- levels 0..5, boundaries at 2, 4, 8, 16, 32
	local eta = 1.25
	-- S1: after every update t_(L-1) <= x < t_L * eta (never undersampled)
	local sel = Saturn.selector(th, eta)
	for _ = 1, 200000 do
		local x = 0.5 * 2 ^ (rnd() * 7)
		local L = Saturn.select(sel, x)
		assert(L == 0 or x >= th[L], "S1: level insufficient")
		assert(L == #th or x < th[L + 1] * eta, "S1: level too fine")
		-- at most one level finer than the coarsest sufficient one (eta <= 2)
		local ideal = 0
		while ideal < #th and x >= th[ideal + 1] do
			ideal += 1
		end
		assert(L == ideal or L == ideal - 1, "S1: more than one level off")
	end
	-- S2: sequences confined to one band [t_k, t_k * eta) change the level at most
	-- once; sequences in an interval that straddles no band never reverse
	for trial = 1, 3000 do
		local k = 1 + (rnd() * #th) // 1
		local s2 = Saturn.selector(th, eta, (rnd() * (#th + 1)) // 1)
		local changes = 0
		local prev = -1
		for step = 1, 200 do
			local x = th[k] * (1 + (eta - 1) * rnd() * 0.999999)
			local L = Saturn.select(s2, x)
			if prev >= 0 and L ~= prev then
				changes += 1
			end
			prev = L
			local _ = step
		end
		assert(changes == 0, "S2: level changed inside a band after the first update")
		-- any interval of multiplicative width below eta straddles no band
		local lo = 0.6 * 2 ^ (rnd() * 6.5)
		local hi = lo * (1 + (eta - 1) * rnd())
		local s3 = Saturn.selector(th, eta, (rnd() * (#th + 1)) // 1)
		local dir = 0
		prev = Saturn.select(s3, lo + (hi - lo) * rnd())
		for _ = 1, 200 do
			local L = Saturn.select(s3, lo + (hi - lo) * rnd())
			if L ~= prev then
				local d = if L > prev then 1 else -1
				assert(dir == 0 or dir == d, "S2: level sequence reversed")
				dir = d
			end
			prev = L
		end
		local _ = trial
	end
	-- X1: C1 continuity of the opacities (dense sampling); one moves at a time
	local N = 20000
	local po, pn = Saturn.fadeOpacities(0)
	assert(po == 1 and pn == 0, "fade starts at the old level")
	local maxSlope = 0
	for i = 1, N do
		local u = i / N
		local lo, ln = Saturn.fadeOpacities(u)
		maxSlope = math.max(maxSlope, math.abs(lo - po) * N, math.abs(ln - pn) * N)
		assert(lo == 1 or ln == 1, "one layer is always opaque")
		po, pn = lo, ln
	end
	assert(po == 0 and pn == 1, "fade ends at the new level")
	assert(maxSlope <= 3 + 1e-6, "X1: |d lambda / du| <= 3, got " .. maxSlope)
	for _, u0 in { 0, 0.5, 1 } do
		-- one-sided difference quotients vanish at the phase joints (C1)
		local h = 1e-6
		local a0, b0 = Saturn.fadeOpacities(u0)
		local a1, b1 = Saturn.fadeOpacities(u0 + h)
		local a2, b2 = Saturn.fadeOpacities(u0 - h)
		assert(math.abs(a1 - a0) / h < 1e-4 and math.abs(b1 - b0) / h < 1e-4, "X1 right derivative")
		assert(math.abs(a2 - a0) / h < 1e-4 and math.abs(b2 - b0) / h < 1e-4, "X1 left derivative")
	end
	-- X2 / X3 over random pixel pairs and times
	for _ = 1, 100000 do
		local u = rnd()
		local lo, ln = Saturn.fadeOpacities(u)
		local cA, cB, X, aX = rnd(), rnd(), rnd(), rnd()
		-- opaque pair: alpha stays 1, colour is the exact blend
		local P, A = Saturn.composite(cA, 1, cB, 1, lo, ln, X, aX)
		local w = if u <= 0.5 then ln else 1
		assert(math.abs(A - 1) < 1e-15, "X2: alpha dips")
		assert(math.abs(P - ((1 - w) * cA + w * cB)) < 1e-15, "X2: not the exact blend")
		-- semi-transparent pair: deviation from the ideal blend of the two composites
		local aA, aB = rnd(), rnd()
		local Pt, At = Saturn.composite(cA, aA, cB, aB, lo, ln, X, aX)
		local PA, AA = Saturn.composite(cA, aA, cB, aB, 1, 0, X, aX)
		local PB, AB = Saturn.composite(cA, aA, cB, aB, 0, 1, X, aX)
		local theta = if u <= 0.5 then ln else lo
		local dev = Pt - ((1 - w) * PA + w * PB)
		assert(math.abs(dev - theta * (1 - aB) * aA * (cA - X * aX)) < 1e-12, "X3: deviation formula")
		assert(math.abs(dev) <= (1 - aB) * aA + 1e-12, "X3: deviation bound")
		assert(At >= (1 - w) * AA + w * AB - 1e-12, "X3: more transparent than the ideal blend")
	end
	-- Z: the controller only moves a slot on top while it is fully transparent, each
	-- frame's composite lies on the continuous path, and at rest one slot shows
	local lod = Saturn.lod(th, eta, 0.5, 3)
	local now = 0
	local prevTop = -1
	local prevVis = -1
	local x = 3
	for frame = 1, 20000 do
		now += 1 / 60
		if frame % 97 == 0 then
			x = 0.6 * 2 ^ (rnd() * 6.5)
		end
		local l1, t1, l2, t2, top = Saturn.lodStep(lod, x * (1 + 0.1 * (rnd() - 0.5)), now)
		assert(t1 >= 0 and t1 <= 1 and t2 >= 0 and t2 <= 1, "transparency range")
		if prevTop >= 0 and top ~= prevTop then
			assert((if top == 1 then t1 else t2) == 1, "Z: slot moved on top while visible")
		end
		-- opaque test images whose colour is the level: the visible colour moves
		-- continuously (at most 3 / (60 * 0.5) of a level step per frame) and the
		-- composite is always fully opaque
		local bottom = 3 - top
		local lb = if bottom == 1 then l1 else l2
		local lt = if top == 1 then l1 else l2
		local ob = if bottom == 1 then 1 - t1 else 1 - t2
		local ot = if top == 1 then 1 - t1 else 1 - t2
		local P, A = Saturn.composite(math.max(lb, 0), if lb >= 0 then 1 else 0, math.max(lt, 0), if lt >= 0 then 1 else 0, ob, ot, 0, 0)
		assert(math.abs(A - 1) < 1e-12, "Z: composite not opaque")
		if prevVis >= 0 then
			assert(math.abs(P - prevVis) <= 5 * (3 / (60 * 0.5)) + 1e-9, "Z: visible jump between frames")
		end
		prevVis = P
		prevTop = top
	end
	assert(lod.fades > 10, "the controller should have faded")
	report("Saturn fades in 20000 frames", lod.fades)
end

----------------------------------------------------------------------------------
-- 7. F3: identical bytes in every runtime (constants both runtimes must reproduce)
----------------------------------------------------------------------------------

do
	local S = 256
	local sc = Raster.demoScene(96, S, 11)
	local img = buffer.create(S * S * 4)
	Raster.resetStats()
	Raster.render(sc, Raster.bin(sc, S, S), img, S, S, 8)
	report("demo scene 96 shapes 256^2: conflict pixels", Raster.stats.conflicts)
	checkHash("raster flawless demo", hashWords(img, S * S), 1754726396)
	checkHash("F2 scenes", f2Hash, 2478953521)
	checkHash("LOD levels", lodHash, 3236752937)
end

if PRINT then
	for k, v in hashes do
		print("hash", k, v)
	end
end
print("flawless tests ok")
