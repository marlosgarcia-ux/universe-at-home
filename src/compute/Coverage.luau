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
--                           i.e. 30/R in 1/255 units (C5). = MyMath.coverageHalfPlane
--   halfPlaneCurved(...)    half-plane minus the first-order curvature term over
--                           the chord. The residual is O(1/R) where the chord
--                           leaves the pixel at a shallow angle (measured 0.36/255
--                           at R = 8, 0.036 at R = 48, 0.002 at R = 300): an
--                           estimator, not flawless. = MyMath.coverageCurved
--   corner, edgePair        exact areas where two edges enter the pixel (C6).
--   discRectArea, roundCorner, dasin   exact disc pieces with a deterministic
--                           arcsine: usable for texture content.
--   supersample(...)        n x n point samples (NOT a reference: 1/(2n) error).
--
-- Exact areas used by the flawless pipeline (F1, F2; deterministic, allocation-free):
--   datan2(s, c)            deterministic atan2 from dasin (arguments <= sqrt(2)/2)
--   discBoxArea(...)        disc and axis-aligned rectangle, by quadrant integration
--   discPolyArea(...)       disc and convex polygon, by signed disc-triangle areas
--   polygonBoxCoverage(...) simple polygon and pixel box, by per-edge integrals
--   clipInto, polyArea      Sutherland-Hodgman half-plane clip and shoelace on
--                           caller-owned scratch arrays
--
-- References for tests and benchmarks:
--   circleArea(...)         exact area of circle and pixel (closed form; uses
--                           math.asin, so REFERENCE ONLY, never texture content)
--   polygonArea(...)        exact area of polygon and pixel (clip + shoelace)

local MyMath = require("../MyMath")

local Coverage = {}

local abs = math.abs
local sqrt = math.sqrt

function Coverage.linear(d: number, w: number): number
	local a = 0.5 - d / w
	return if a < 0 then 0 elseif a > 1 then 1 else a
end

-- Exact area of {q in pixel : d + n . (q - centre) <= 0} for |n| = 1 (C4).
-- The projection of the unit square on n has a trapezoid density: ramps of width
-- b = min(|nx|, |ny|) and a plateau of width a - b, a = max(|nx|, |ny|).
-- The axiom lives in MyMath; this is the same function (bit-identical).
local halfPlane = MyMath.coverageHalfPlane
Coverage.halfPlane = halfPlane

-- The largest |d| at which halfPlane can be strictly between 0 and 1: (a + b) / 2
-- <= sqrt(2) / 2. Tile culling for exact coverage uses this instead of w / 2.
Coverage.HALF_PLANE_REACH = MyMath.COVERAGE_REACH

-- Curvature-corrected coverage (docs/COMPUTE.md C5): half-plane area minus the
-- first-order term k (t1^3 - t0^3) / 6 over the chord the tangent line cuts from
-- the pixel. The axiom lives in MyMath; this is the same function (bit-identical).
local halfPlaneCurved = MyMath.coverageCurved
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

-- Sutherland-Hodgman: clips polygon (ax, ay)[1..n] to {q : nx qx + ny qy <= c},
-- writing the result into (bx, by) and returning its vertex count. For a convex
-- input the output is the convex intersection; for any input its signed area is
-- the area of the clipped region (bridges along the clip line cancel).
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
Coverage.clipInto = clipInto

-- Signed shoelace area of (x, y)[1..n] (positive for counter-clockwise order in a
-- right-handed frame, i.e. when every edge has the interior on its left).
local function polyArea(x: { number }, y: { number }, n: number): number
	if n < 3 then
		return 0
	end
	local s = 0
	local px, py = x[n], y[n]
	for i = 1, n do
		local qx, qy = x[i], y[i]
		s += px * qy - qx * py
		px, py = qx, qy
	end
	return s * 0.5
end
Coverage.polyArea = polyArea

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

-- Deterministic arcsine: Taylor series on |x| <= 1/2 (28 terms: the first omitted
-- term is below 2e-20 at |x| = 1/2, so the result is within a few double rounding
-- units), and asin(x) = pi/2 - 2 asin(sqrt((1 - x) / 2)) above. Only + - * / sqrt,
-- so it is bit-identical on every platform, unlike math.asin. (An 18-term version
-- truncated at 7e-14, which became visible in sector areas of discs with radii
-- in the thousands; docs/COMPUTE.md "Flawless pipeline".)
local ASIN_TERMS = 28
local ASIN_C: { number } = {}
do
	-- c_n = (2n)! / (4^n (n!)^2 (2n + 1))
	local c = 1
	for n = 0, ASIN_TERMS - 1 do
		ASIN_C[n + 1] = c / (2 * n + 1)
		c = c * (2 * n + 1) / (2 * n + 2)
	end
end
local HALF_PI = 1.5707963267948966

local A1, A2, A3, A4, A5, A6, A7, A8 = ASIN_C[2], ASIN_C[3], ASIN_C[4], ASIN_C[5], ASIN_C[6], ASIN_C[7], ASIN_C[8], ASIN_C[9]

local function asinSmall(x: number): number
	local x2 = x * x
	if x2 <= 0.015625 then
		-- |x| <= 1/8 (arcs a pixel subtends): nine terms, the first omitted one is
		-- below 1e-19 relative; unrolled with the same coefficients
		return x * (1 + x2 * (A1 + x2 * (A2 + x2 * (A3 + x2 * (A4 + x2 * (A5 + x2 * (A6 + x2 * (A7 + x2 * A8))))))))
	end
	local s = ASIN_C[ASIN_TERMS]
	for i = ASIN_TERMS - 1, 1, -1 do
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

-- Integral of sqrt(r^2 - t^2) from 0 to t (|t| <= r), deterministic. Written to
-- stay well conditioned as |t| -> r (a vertical tangent of the circle): r^2 - t^2
-- as (r - t)(r + t) (r - t is exact there), and asin(t / r) as pi/2 - 2 asin(sqrt((r
-- - t) / 2r)) above r/2, so the two sqrt(r - t) terms cancel analytically instead
-- of losing sqrt(epsilon) r^2 (about 1e-8 r^2) to rounding.
local QUARTER_PI = 0.78539816339744831
local function chordIntegralDet(t: number, r: number): number
	if t >= r then
		return QUARTER_PI * r * r
	elseif t <= -r then
		return -QUARTER_PI * r * r
	end
	local a
	if t > 0.5 * r then
		a = HALF_PI - 2 * dasin(sqrt((r - t) / (2 * r)))
	elseif t < -0.5 * r then
		a = 2 * dasin(sqrt((r + t) / (2 * r))) - HALF_PI
	else
		a = dasin(t / r)
	end
	return 0.5 * (t * sqrt((r - t) * (r + t)) + r * r * a)
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

----------------------------------------------------------------------------------
-- Exact areas for the flawless pipeline (docs/COMPUTE.md "Flawless pipeline")
----------------------------------------------------------------------------------

local PI = 3.141592653589793

-- Deterministic atan2: the angle of the vector (c, s) in (-pi, pi]. Each branch
-- calls dasin with an argument of magnitude at most sqrt(2)/2, where the arcsine
-- is well conditioned (derivative <= sqrt(2)), so the absolute error stays near
-- the double rounding unit for every angle, including angles near 0 and pi.
local function datan2(s: number, c: number): number
	local m = sqrt(s * s + c * c)
	if m == 0 then
		return 0
	end
	local as = abs(s) / m
	local ac = c / m
	local t
	if ac >= as then
		t = dasin(as) -- |angle| <= 45 degrees
	elseif ac >= -as then
		t = HALF_PI - dasin(ac) -- 45 to 135 degrees
	else
		t = PI - dasin(as) -- 135 to 180 degrees
	end
	return if s < 0 then -t else t
end
Coverage.datan2 = datan2

-- Area of disc(0, r) inside [a, b] x [c, d] with 0 <= a < b and 0 <= c < d (the
-- first quadrant, where the upper circle y = sqrt(r^2 - x^2) decreases). For x <=
-- xd the circle is at height >= d (full column), for x >= xc it is below c (empty
-- column), in between the column height is sqrt(r^2 - x^2) - c, integrated in
-- closed form with one arcsine: asin(q/r) - asin(p/r) = asin((q sp - p sq) / r^2)
-- for 0 <= p <= q <= r, where sp, sq are the circle heights at p and q. The caller
-- orients the piece so the integration runs along the axis on which the circle is
-- flatter (heights stay large, no cancellation in r^2 - x^2).
local function quadrantArea(a: number, b: number, c: number, d: number, r: number, r2: number): number
	if a * a + c * c >= r2 then
		return 0
	end
	if b * b + d * d <= r2 then
		return (b - a) * (d - c)
	end
	-- (single assignments: a call in the last position of a multiple assignment
	-- types as optional in strict mode)
	local p, sp = 0, r
	if d < r then
		p = sqrt(r2 - d * d)
		sp = d
	end
	if p < a then
		p = a
		sp = sqrt(r2 - a * a)
	elseif p > b then
		p = b
		sp = sqrt(r2 - b * b)
	end
	local q = sqrt(r2 - c * c)
	local sq = c
	if q > b then
		q = b
		sq = sqrt(r2 - b * b)
	elseif q < a then
		q = a
		sq = sqrt(r2 - a * a)
	end
	local area = (d - c) * (p - a)
	if q > p then
		area += 0.5 * (q * sq - p * sp) + 0.5 * r2 * dasin((q * sp - p * sq) / r2) - c * (q - p)
	end
	return area
end

-- One quadrant piece [a, b] x [c, d] (already reflected into the first quadrant),
-- integrated along the axis where the piece lies closer to the circle's centre line.
local function quadrantPiece(a: number, b: number, c: number, d: number, r: number, r2: number): number
	if b <= a or d <= c then
		return 0
	end
	if a + b > c + d then
		return quadrantArea(c, d, a, b, r, r2)
	end
	return quadrantArea(a, b, c, d, r, r2)
end

-- Exact area of the disc (cx, cy, r) inside the rectangle [x0, x1] x [y0, y1].
-- The rectangle is split by the disc's centre lines into at most four pieces, each
-- reflected into the first quadrant and integrated in closed form (quadrantArea).
-- No topology (no walking of intersection points), so tangencies and corners on
-- the circle cannot flip a branch: the result is continuous in every input.
-- Deterministic (+ - * / sqrt and dasin), allocation-free.
local function discBoxArea(cx: number, cy: number, r: number, x0: number, y0: number, x1: number, y1: number): number
	if r <= 0 or x1 <= x0 or y1 <= y0 then
		return 0
	end
	local X0, X1, Y0, Y1 = x0 - cx, x1 - cx, y0 - cy, y1 - cy
	if X0 >= r or X1 <= -r or Y0 >= r or Y1 <= -r then
		return 0
	end
	local r2 = r * r
	if (X0 >= 0 or X1 <= 0) and (Y0 >= 0 or Y1 <= 0) then
		-- the rectangle lies in one quadrant (every edge pixel of a disc larger than
		-- the pixel, away from its centre lines): one piece
		local a, b, c, d = X0, X1, Y0, Y1
		if X1 <= 0 then
			a, b = -X1, -X0
		end
		if Y1 <= 0 then
			c, d = -Y1, -Y0
		end
		if a + b > c + d then
			return quadrantArea(c, d, a, b, r, r2)
		end
		return quadrantArea(a, b, c, d, r, r2)
	end
	-- x pieces: right [ra, rb] (x >= 0) and left mirrored [la, lb] (x <= 0)
	local ra = if X0 > 0 then X0 else 0
	local rb = X1
	local la = if X1 < 0 then -X1 else 0
	local lb = -X0
	local ta = if Y0 > 0 then Y0 else 0
	local tb = Y1
	local ba = if Y1 < 0 then -Y1 else 0
	local bb = -Y0
	local area = 0
	if rb > ra then
		area += quadrantPiece(ra, rb, ta, tb, r, r2) + quadrantPiece(ra, rb, ba, bb, r, r2)
	end
	if lb > la then
		area += quadrantPiece(la, lb, ta, tb, r, r2) + quadrantPiece(la, lb, ba, bb, r, r2)
	end
	return area
end
Coverage.discBoxArea = discBoxArea

-- Signed area of disc(0, r) intersected with the triangle (0, A, B): the part of
-- the segment A-B inside the circle contributes its triangle with the centre, the
-- parts outside contribute circular sectors r^2/2 * angle. Each edge's term is
-- computed independently (no pairing of intersection points), so the sum over a
-- polygon's edges is robust to tangencies and vertices on the circle.
local function triDisc(ax: number, ay: number, bx: number, by: number, r2: number): number
	local aa = ax * ax + ay * ay
	local bb = bx * bx + by * by
	if aa <= r2 and bb <= r2 then
		return 0.5 * (ax * by - ay * bx)
	end
	local half = 0.5 * r2
	local dx, dy = bx - ax, by - ay
	local A = dx * dx + dy * dy
	if A == 0 then
		return 0
	end
	local B = ax * dx + ay * dy
	local C = aa - r2
	local disc = B * B - A * C
	if disc <= 0 then
		return half * datan2(ax * by - ay * bx, ax * bx + ay * by)
	end
	local sd = sqrt(disc)
	-- roots of A t^2 + 2 B t + C = 0, the stable way (no cancellation)
	local t1, t2
	if B >= 0 then
		local q = -(B + sd)
		t1, t2 = q / A, C / q
	else
		local q = sd - B
		t1, t2 = C / q, q / A
	end
	local u1 = if t1 > 0 then t1 else 0
	local u2 = if t2 < 1 then t2 else 1
	if u1 >= u2 then
		return half * datan2(ax * by - ay * bx, ax * bx + ay * by)
	end
	local p1x, p1y = ax + u1 * dx, ay + u1 * dy
	local p2x, p2y = ax + u2 * dx, ay + u2 * dy
	local area = 0.5 * (p1x * p2y - p1y * p2x)
	if u1 > 0 then
		area += half * datan2(ax * p1y - ay * p1x, ax * p1x + ay * p1y)
	end
	if u2 < 1 then
		area += half * datan2(p2x * by - p2y * bx, p2x * bx + p2y * by)
	end
	return area
end

-- Exact signed area of the disc (cx, cy, r) intersected with the polygon
-- (px, py)[1..n] (positive for counter-clockwise polygons). Exact for any simple
-- polygon (the disc-triangle terms add up by Green's theorem); the flawless
-- pipeline calls it with small convex polygons in pixel-local coordinates.
local function discPolyArea(px: { number }, py: { number }, n: number, cx: number, cy: number, r: number): number
	if n < 3 or r <= 0 then
		return 0
	end
	local r2 = r * r
	local s = 0
	local ax, ay = px[n] - cx, py[n] - cy
	for i = 1, n do
		local bx, by = px[i] - cx, py[i] - cy
		s += triDisc(ax, ay, bx, by, r2)
		ax, ay = bx, by
	end
	return s
end
Coverage.discPolyArea = discPolyArea

-- Mean of clamp(t, 0, 1) for t running linearly from a to b.
local function avgClamp01(a: number, b: number): number
	if a > b then
		a, b = b, a
	end
	if b <= 0 then
		return 0
	end
	if a >= 1 then
		return 1
	end
	if a >= 0 and b <= 1 then
		return (a + b) * 0.5
	end
	-- G(t) = integral of clamp(s, 0, 1) ds from 0 to t
	local ga = if a <= 0 then 0 else a * a * 0.5
	local gb = if b >= 1 then b - 0.5 else b * b * 0.5
	return (gb - ga) / (b - a)
end

-- Signed coverage of the w x w box with lower corner (x0, y0) by the polygon
-- v[first], v[first + 1], ... (count vertices, flat x, y pairs), in units of the
-- box area. By Green's theorem the area of polygon and box is the sum over edges
-- of dir * integral over the edge's y-span inside the box of (x1 - clamp(x, x0,
-- x1)) dy: the part of the box row to the right of the edge, signed by the edge's
-- vertical direction. Each edge is a linear x(y), so the clamped integral has a
-- closed form (avgClamp01). Exact for simple polygons of either orientation (the
-- sign of the result is the orientation); edges whose y-span misses the box cost
-- two comparisons. Deterministic, allocation-free.
local function polygonBoxCoverage(v: { number }, first: number, count: number, x0: number, y0: number, w: number): number
	local iw = 1 / w
	local y1 = y0 + w
	local s = 0
	local last = first + 2 * count - 2
	local ax, ay = v[last], v[last + 1]
	for i = first, last, 2 do
		local bx, by = v[i], v[i + 1]
		if ay ~= by then
			local lx, ly, hx, hy, dir = ax, ay, bx, by, 1
			if ay > by then
				lx, ly, hx, hy, dir = bx, by, ax, ay, -1
			end
			if hy > y0 and ly < y1 then
				local lo = if ly > y0 then ly else y0
				local hi = if hy < y1 then hy else y1
				local slope = (hx - lx) / (hy - ly)
				local ul = (lx + (lo - ly) * slope - x0) * iw
				local uh = (lx + (hi - ly) * slope - x0) * iw
				s += dir * (hi - lo) * iw * (1 - avgClamp01(ul, uh))
			end
		end
		ax, ay = bx, by
	end
	return s
end
Coverage.polygonBoxCoverage = polygonBoxCoverage

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
-- Well conditioned at |t| -> r like chordIntegralDet (the plain form loses about
-- 1e-8 r^2 there: 6.5e-7 measured for r = 30.6 at a vertical tangent).
local function chordIntegral(t: number, r: number): number
	if t >= r then
		return math.pi * r * r * 0.25
	elseif t <= -r then
		return -math.pi * r * r * 0.25
	end
	local a
	if t > 0.5 * r then
		a = math.pi * 0.5 - 2 * math.asin(sqrt((r - t) / (2 * r)))
	elseif t < -0.5 * r then
		a = 2 * math.asin(sqrt((r + t) / (2 * r))) - math.pi * 0.5
	else
		a = math.asin(t / r)
	end
	return 0.5 * (t * sqrt((r - t) * (r + t)) + r * r * a)
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
