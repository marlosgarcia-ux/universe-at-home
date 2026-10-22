--!native
--!optimize 2
-- universe-at-home :: compute/Coverage
--
-- Pixel coverage: the fraction of a unit pixel square inside a shape (a box
-- filter, which is what "anti-aliased" means here). docs/COMPUTE.md 3.3.
--
-- Estimators (deterministic: + - * / sqrt abs and comparisons only):
--   linear(d, w)            clamp(0.5 - d / w, 0, 1): the distance ramp used by
--                           MyMath.coverage. Exact only for axis-aligned edges;
--                           up to 10.94/255 on a 45 degree edge (C3).
--   halfPlane(d, nx, ny)    exact area of the pixel inside the tangent half-plane
--                           (SDF value d at the centre, unit gradient (nx, ny)).
--                           Exact for straight edges (C4); on a curve of radius R
--                           it overestimates by at most (sqrt(2)/2)^3 / (3 R),
--                           i.e. 30/R in 1/255 units (C5).
--   halfPlaneCurved(...)    half-plane minus the first-order curvature term over
--                           the chord: O(1/R^2), flawless for R >= 8 px (C5).
--   corner, edgePair        exact areas where two edges enter the pixel (C6).
--   discRectArea, roundCorner, dasin   exact disc pieces with a deterministic
--                           arcsine: usable for texture content.
--   supersample(...)        n x n point samples (NOT a reference: 1/(2n) error).
--
-- References for tests and benchmarks:
--   circleArea(...)         exact area of circle and pixel (closed form; uses
--                           math.asin, so REFERENCE ONLY, never texture content)
--   polygonArea(...)        exact area of polygon and pixel (clip + shoelace)

local Coverage = {}

local abs = math.abs
local sqrt = math.sqrt

function Coverage.linear(d: number, w: number): number
	local a = 0.5 - d / w
	return if a < 0 then 0 elseif a > 1 then 1 else a
end

-- Exact area of {q in pixel : d + n . (q - centre) <= 0} for |n| = 1.
-- The projection of the unit square on n has a trapezoid density: ramps of width
-- b = min(|nx|, |ny|) and a plateau of width a - b, a = max(|nx|, |ny|).
local function halfPlane(d: number, nx: number, ny: number): number
	local a, b = abs(nx), abs(ny)
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
Coverage.halfPlane = halfPlane

-- The largest |d| at which halfPlane can be strictly between 0 and 1: (a + b) / 2
-- <= sqrt(2) / 2. Tile culling for exact coverage uses this instead of w / 2.
Coverage.HALF_PLANE_REACH = 0.70710678118654757

-- Curvature-corrected coverage (docs/COMPUTE.md C5). The boundary near the pixel is
-- a curve of signed curvature k (k > 0: the shape is convex there, e.g. 1 / R for a
-- disc) tangent to the half-plane line. Along the line, at tangential offset t from
-- the foot point, the curve lies k t^2 / 2 inside the line, so to first order in k
-- the pixel loses the area integral of k t^2 / 2 over the chord the line cuts from
-- the pixel: k (t1^3 - t0^3) / 6. With the chord from the clipped line, the
-- remaining error is O(k^2). Deterministic: + - * / abs and comparisons only.
local function halfPlaneCurved(d: number, nx: number, ny: number, k: number): number
	local base = halfPlane(d, nx, ny)
	if k == 0 then
		return base
	end
	-- the line is {q : n . (q - c) = -d}; parametrise q = c - d n + t (-ny, nx)
	-- and clip t to the unit square |qx - cx| <= 1/2, |qy - cy| <= 1/2
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
Coverage.halfPlaneCurved = halfPlaneCurved

-- Exact area of the unit pixel square centred at the origin intersected with up to
-- two half-planes {q : n1 . q <= c1} and {q : n2 . q <= c2} (normals need not be
-- unit length). Sutherland-Hodgman with preallocated scratch arrays, then the
-- shoelace formula: no allocation, deterministic ops only. Used for polygon
-- vertices, where the boundary is a wedge (two edges) and no single half-plane
-- describes it. Pass n2x = n2y = 0, c2 = 1 for one half-plane.
local SX: { number } = table.create(16, 0)
local SY: { number } = table.create(16, 0)
local TX: { number } = table.create(16, 0)
local TY: { number } = table.create(16, 0)

local function clipInto(ax: { number }, ay: { number }, n: number, bx: { number }, by: { number }, nx: number, ny: number, c: number): number
	local m = 0
	if n == 0 then
		return 0
	end
	local px, py = ax[n], ay[n]
	local pv = nx * px + ny * py - c
	for i = 1, n do
		local qx, qy = ax[i], ay[i]
		local qv = nx * qx + ny * qy - c
		if qv <= 0 then
			if pv > 0 then
				local t = pv / (pv - qv)
				m += 1
				bx[m] = px + (qx - px) * t
				by[m] = py + (qy - py) * t
			end
			m += 1
			bx[m] = qx
			by[m] = qy
		elseif pv <= 0 then
			local t = pv / (pv - qv)
			m += 1
			bx[m] = px + (qx - px) * t
			by[m] = py + (qy - py) * t
		end
		px, py, pv = qx, qy, qv
	end
	return m
end

local function squareClip2(n1x: number, n1y: number, c1: number, n2x: number, n2y: number, c2: number): number
	SX[1], SY[1] = -0.5, -0.5
	SX[2], SY[2] = 0.5, -0.5
	SX[3], SY[3] = 0.5, 0.5
	SX[4], SY[4] = -0.5, 0.5
	local m = clipInto(SX, SY, 4, TX, TY, n1x, n1y, c1)
	m = clipInto(TX, TY, m, SX, SY, n2x, n2y, c2)
	if m < 3 then
		return 0
	end
	local s = 0
	local px, py = SX[m], SY[m]
	for i = 1, m do
		local qx, qy = SX[i], SY[i]
		s += px * qy - qx * py
		px, py = qx, qy
	end
	s = abs(s) * 0.5
	return if s > 1 then 1 else s
end
Coverage.squareClip2 = squareClip2

-- Exact coverage of the pixel centred at (px, py) by the polygon corner at vertex
-- v = (vx, vy) between the incoming edge (from u) and the outgoing edge (to w),
-- for a polygon of orientation sigma (+1 or -1, the sign of its shoelace area).
-- Exact whenever no other edge of the polygon enters the pixel.
function Coverage.corner(px: number, py: number, ux: number, uy: number, vx: number, vy: number, wx: number, wy: number, sigma: number): number
	-- inner side of edge a->b: sigma * cross(b - a, q - a) >= 0, i.e. n . q <= c
	-- with n = sigma * (by - ay, -(bx - ax)); shift q to pixel-local coordinates
	local e1x, e1y = vx - ux, vy - uy
	local e2x, e2y = wx - vx, wy - vy
	local n1x, n1y = sigma * e1y, -sigma * e1x
	local n2x, n2y = sigma * e2y, -sigma * e2x
	local c1 = n1x * (vx - px) + n1y * (vy - py)
	local c2 = n2x * (vx - px) + n2y * (vy - py)
	local convex = sigma * (e1x * e2y - e1y * e2x) >= 0
	if convex then
		return squareClip2(n1x, n1y, c1, n2x, n2y, c2)
	end
	-- reflex: the polygon is locally the union of the two half-planes
	local a1 = squareClip2(n1x, n1y, c1, 0, 0, 1)
	local a2 = squareClip2(n2x, n2y, c2, 0, 0, 1)
	local a12 = squareClip2(n1x, n1y, c1, n2x, n2y, c2)
	local a = a1 + a2 - a12
	return if a < 0 then 0 elseif a > 1 then 1 else a
end

-- Deterministic arcsine: Taylor series on |x| <= 1/2 (18 terms, truncation below
-- 1e-13), and asin(x) = pi/2 - 2 asin(sqrt((1 - x) / 2)) above. Only + - * / sqrt,
-- so it is bit-identical on every platform, unlike math.asin.
local ASIN_C: { number } = {}
do
	-- c_n = (2n)! / (4^n (n!)^2 (2n + 1))
	local c = 1
	for n = 0, 17 do
		ASIN_C[n + 1] = c / (2 * n + 1)
		c = c * (2 * n + 1) / (2 * n + 2)
	end
end
local HALF_PI = 1.5707963267948966

local function asinSmall(x: number): number
	local x2 = x * x
	local s = ASIN_C[18]
	for i = 17, 1, -1 do
		s = s * x2 + ASIN_C[i]
	end
	return x * s
end

local function dasin(x: number): number
	local ax = abs(x)
	local r
	if ax <= 0.5 then
		return asinSmall(x)
	elseif ax >= 1 then
		r = HALF_PI
	else
		r = HALF_PI - 2 * asinSmall(sqrt((1 - ax) * 0.5))
	end
	return if x < 0 then -r else r
end
Coverage.dasin = dasin

-- Integral of sqrt(r^2 - t^2) from 0 to t (|t| <= r), deterministic.
local QUARTER_PI = 0.78539816339744831
local function chordIntegralDet(t: number, r: number): number
	if t >= r then
		return QUARTER_PI * r * r
	elseif t <= -r then
		return -QUARTER_PI * r * r
	end
	return 0.5 * (t * sqrt(r * r - t * t) + r * r * dasin(t / r))
end

-- Exact area of the disc (cx, cy, r) inside the rectangle [x0, x1] x [y0, y1],
-- deterministic and allocation-free (cuts kept in a fixed scratch array and
-- insertion-sorted). Same method as circleArea: split x where min/max switch.
local CUT: { number } = table.create(8, 0)

-- Inserts x into CUT[1..n] (sorted) when x0 < x < x1; returns the new count.
local function insertCut(n: number, x: number, x0: number, x1: number): number
	if x > x0 and x < x1 then
		n += 1
		local i = n
		while i > 1 and CUT[i - 1] > x do
			CUT[i] = CUT[i - 1]
			i -= 1
		end
		CUT[i] = x
	end
	return n
end

local function discRectArea(cx: number, cy: number, r: number, x0: number, y0: number, x1: number, y1: number): number
	if x1 <= x0 or y1 <= y0 or r <= 0 then
		return 0
	end
	local n = insertCut(0, cx - r, x0, x1)
	n = insertCut(n, cx + r, x0, x1)
	local dy0 = y0 - cy
	if abs(dy0) < r then
		local hw = sqrt(r * r - dy0 * dy0)
		n = insertCut(n, cx - hw, x0, x1)
		n = insertCut(n, cx + hw, x0, x1)
	end
	local dy1 = y1 - cy
	if abs(dy1) < r then
		local hw = sqrt(r * r - dy1 * dy1)
		n = insertCut(n, cx - hw, x0, x1)
		n = insertCut(n, cx + hw, x0, x1)
	end
	local area = 0
	local a = x0
	for i = 1, n + 1 do
		local b = if i <= n then CUT[i] else x1
		if b > a then
			local m = (a + b) * 0.5 - cx
			if abs(m) < r then
				local hm = sqrt(r * r - m * m)
				local upperIsCircle = cy + hm < y1
				local lowerIsCircle = cy - hm > y0
				local top = if upperIsCircle then cy + hm else y1
				local bot = if lowerIsCircle then cy - hm else y0
				if top > bot then
					local len = b - a
					local hInt = if upperIsCircle or lowerIsCircle then chordIntegralDet(b - cx, r) - chordIntegralDet(a - cx, r) else 0
					local upper = if upperIsCircle then cy * len + hInt else y1 * len
					local lower = if lowerIsCircle then cy * len - hInt else y0 * len
					area += upper - lower
				end
			end
		end
		a = b
	end
	return area
end
Coverage.discRectArea = discRectArea

-- Nearest point of the segment a + t e (0 <= t <= 1) to (px, py), relative to (px, py).
local function nearestLocal(px: number, py: number, ax: number, ay: number, ex: number, ey: number): (number, number)
	local ee = ex * ex + ey * ey
	local t = if ee > 0 then ((px - ax) * ex + (py - ay) * ey) / ee else 0
	t = if t < 0 then 0 elseif t > 1 then 1 else t
	return ax + ex * t - px, ay + ey * t - py
end

-- Exact coverage of the pixel centred at (px, py) by a polygon locally bounded by
-- two non-adjacent edges a1->b1 and a2->b2 (polygon order, orientation sigma).
-- The edges cut the pixel into an outer part, a between part and another outer
-- part, and inside/outside alternates across each edge. If the inner sides face
-- each other the polygon is locally H1 and H2 (a sliver); if they face away it is
-- H1 or H2 (a gap). Otherwise (a third edge must be involved) it falls back to the
-- nearer edge alone. Exact whenever only these two edges enter the pixel.
function Coverage.edgePair(
	px: number,
	py: number,
	a1x: number,
	a1y: number,
	b1x: number,
	b1y: number,
	a2x: number,
	a2y: number,
	b2x: number,
	b2y: number,
	sigma: number
): number
	local e1x, e1y = b1x - a1x, b1y - a1y
	local e2x, e2y = b2x - a2x, b2y - a2y
	local n1x, n1y = sigma * e1y, -sigma * e1x
	local n2x, n2y = sigma * e2y, -sigma * e2x
	local c1 = n1x * (a1x - px) + n1y * (a1y - py)
	local c2 = n2x * (a2x - px) + n2y * (a2y - py)
	local q1x, q1y = nearestLocal(px, py, a1x, a1y, e1x, e1y)
	local q2x, q2y = nearestLocal(px, py, a2x, a2y, e2x, e2y)
	local twoInOne = n1x * q2x + n1y * q2y <= c1
	local oneInTwo = n2x * q1x + n2y * q1y <= c2
	if twoInOne and oneInTwo then
		return squareClip2(n1x, n1y, c1, n2x, n2y, c2)
	elseif not twoInOne and not oneInTwo then
		local a = squareClip2(n1x, n1y, c1, 0, 0, 1) + squareClip2(n2x, n2y, c2, 0, 0, 1) - squareClip2(n1x, n1y, c1, n2x, n2y, c2)
		return if a < 0 then 0 elseif a > 1 then 1 else a
	end
	if q1x * q1x + q1y * q1y <= q2x * q2x + q2y * q2y then
		return squareClip2(n1x, n1y, c1, 0, 0, 1)
	end
	return squareClip2(n2x, n2y, c2, 0, 0, 1)
end

-- Exact coverage of a w x w pixel box centred at (X, Y) by a rounded-box corner in
-- corner-local coordinates (arc centre at the origin, the box extends towards
-- negative X and Y): {X <= 0, Y <= rad} or {Y <= 0, X <= rad} or the disc of
-- radius rad. Split into two rectangles and a disc-rectangle piece. Returns area
-- divided by w^2.
function Coverage.roundCorner(X: number, Y: number, rad: number, w: number): number
	local h = w * 0.5
	local a0, a1, b0, b1 = X - h, X + h, Y - h, Y + h
	local area = 0
	-- part 1: X' <= 0 and Y' <= rad
	local ux = (if a1 < 0 then a1 else 0) - a0
	local uy = (if b1 < rad then b1 else rad) - b0
	if ux > 0 and uy > 0 then
		area += ux * uy
	end
	-- part 2: 0 < X' <= rad and Y' <= 0
	local vx = (if a1 < rad then a1 else rad) - (if a0 > 0 then a0 else 0)
	local vy = (if b1 < 0 then b1 else 0) - b0
	if vx > 0 and vy > 0 then
		area += vx * vy
	end
	-- part 3: X' > 0, Y' > 0 inside the disc
	if a1 > 0 and b1 > 0 then
		area += discRectArea(0, 0, rad, if a0 > 0 then a0 else 0, if b0 > 0 then b0 else 0, a1, b1)
	end
	local c = area / (w * w)
	return if c > 1 then 1 else c
end

-- Curvature-corrected circle coverage (k = 1 / r).
function Coverage.circleCurved(px: number, py: number, cx: number, cy: number, r: number): number
	local dx, dy = px - cx, py - cy
	local len = sqrt(dx * dx + dy * dy)
	if len == 0 then
		return if r > 0.70710678118654757 then 1 else halfPlane(-r, 1, 0)
	end
	return halfPlaneCurved(len - r, dx / len, dy / len, 1 / r)
end

-- Exact coverage estimate for a circle from its SDF (centre distance minus r).
function Coverage.circleHalfPlane(px: number, py: number, cx: number, cy: number, r: number): number
	local dx, dy = px - cx, py - cy
	local len = sqrt(dx * dx + dy * dy)
	if len == 0 then
		return if r > 0.70710678118654757 then 1 else halfPlane(-r, 1, 0)
	end
	return halfPlane(len - r, dx / len, dy / len)
end

----------------------------------------------------------------------------------
-- Exact references
----------------------------------------------------------------------------------

-- Integral of sqrt(r^2 - t^2) dt from 0 to t, |t| <= r. Reference only (asin).
local function chordIntegral(t: number, r: number): number
	if t >= r then
		return math.pi * r * r * 0.25
	elseif t <= -r then
		return -math.pi * r * r * 0.25
	end
	return 0.5 * (t * sqrt(r * r - t * t) + r * r * math.asin(t / r))
end

-- Exact area of the disc (cx, cy, r) inside the square [x0, x0 + 1] x [y0, y0 + 1].
-- Integrates max(0, min(y1, cy + h) - max(y0, cy - h)) over x, splitting at every
-- x where one of the min/max switches, so each piece is a constant or +-h + const.
function Coverage.circleArea(cx: number, cy: number, r: number, x0: number, y0: number): number
	local x1, y1 = x0 + 1, y0 + 1
	local cuts = { x0, x1 }
	local function cut(x: number)
		if x > x0 and x < x1 then
			table.insert(cuts, x)
		end
	end
	cut(cx - r)
	cut(cx + r)
	for _, yb in { y0, y1 } do
		local dy = yb - cy
		if abs(dy) < r then
			local hw = sqrt(r * r - dy * dy)
			cut(cx - hw)
			cut(cx + hw)
		end
	end
	table.sort(cuts)
	local area = 0
	for i = 1, #cuts - 1 do
		local a, b = cuts[i], cuts[i + 1]
		if b - a <= 0 then
			continue
		end
		local m = (a + b) * 0.5 - cx
		if abs(m) >= r then
			continue
		end
		local hm = sqrt(r * r - m * m)
		local upperIsCircle = cy + hm < y1
		local lowerIsCircle = cy - hm > y0
		local top = if upperIsCircle then cy + hm else y1
		local bot = if lowerIsCircle then cy - hm else y0
		if top <= bot then
			continue
		end
		local len = b - a
		local hInt = chordIntegral(b - cx, r) - chordIntegral(a - cx, r)
		local upper = if upperIsCircle then cy * len + hInt else y1 * len
		local lower = if lowerIsCircle then cy * len - hInt else y0 * len
		area += upper - lower
	end
	return area
end

-- Sutherland-Hodgman clip of a polygon (flat list) against x >= k (sx = 1),
-- x <= k (sx = -1), y >= k (sy = 1) or y <= k (sy = -1).
local function clipAxis(pts: { number }, axis: number, k: number, sgn: number): { number }
	local out = {}
	local n = #pts // 2
	if n == 0 then
		return out
	end
	local px, py = pts[2 * n - 1], pts[2 * n]
	local pv = (if axis == 0 then px else py) * sgn - k * sgn
	for i = 1, n do
		local qx, qy = pts[2 * i - 1], pts[2 * i]
		local qv = (if axis == 0 then qx else qy) * sgn - k * sgn
		if qv >= 0 then
			if pv < 0 then
				local t = pv / (pv - qv)
				table.insert(out, px + (qx - px) * t)
				table.insert(out, py + (qy - py) * t)
			end
			table.insert(out, qx)
			table.insert(out, qy)
		elseif pv >= 0 then
			local t = pv / (pv - qv)
			table.insert(out, px + (qx - px) * t)
			table.insert(out, py + (qy - py) * t)
		end
		px, py, pv = qx, qy, qv
	end
	return out
end

local function shoelace(pts: { number }): number
	local n = #pts // 2
	local s = 0
	for i = 1, n do
		local j = if i == n then 1 else i + 1
		s += pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
	end
	return s * 0.5
end
Coverage.shoelace = shoelace

-- Exact area of a simple polygon inside the square [x0, x0 + 1] x [y0, y0 + 1].
function Coverage.polygonArea(pts: { number }, x0: number, y0: number): number
	local p = clipAxis(pts, 0, x0, 1)
	p = clipAxis(p, 0, x0 + 1, -1)
	p = clipAxis(p, 1, y0, 1)
	p = clipAxis(p, 1, y0 + 1, -1)
	return abs(shoelace(p))
end

-- Fraction of n x n sample points (cell centres) for which inside(x, y) is true.
function Coverage.supersample(inside: (number, number) -> boolean, x0: number, y0: number, n: number): number
	local hits = 0
	local step = 1 / n
	for j = 0, n - 1 do
		local y = y0 + (j + 0.5) * step
		for i = 0, n - 1 do
			if inside(x0 + (i + 0.5) * step, y) then
				hits += 1
			end
		end
	end
	return hits / (n * n)
end

----------------------------------------------------------------------------------
-- Error study helpers (used by tests and bench; report in 1/255 units)
----------------------------------------------------------------------------------

export type ErrorStats = { max: number, mean: number, count: number, over1: number }

-- Compares estimator(px, py) with reference(px, py) over the pixels of a box,
-- counting only pixels where either value is strictly between 0 and 1 or they differ.
function Coverage.compare(
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	estimator: (number, number) -> number,
	reference: (number, number) -> number
): ErrorStats
	local maxE, sum, count, over = 0, 0, 0, 0
	for y = y0, y1 do
		for x = x0, x1 do
			local r = reference(x, y)
			local e = estimator(x, y)
			if (r > 0 and r < 1) or (e > 0 and e < 1) or r ~= e then
				local err = abs(e - r) * 255
				if err > maxE then
					maxE = err
				end
				if err > 1 then
					over += 1
				end
				sum += err
				count += 1
			end
		end
	end
	return { max = maxE, mean = if count > 0 then sum / count else 0, count = count, over1 = over }
end

return Coverage
