--!native
--!optimize 2
-- universe-at-home :: compute/Coverage
--
-- Pixel coverage: the fraction of a unit pixel square inside a shape (a box
-- filter, which is what "anti-aliased" means here). Three estimators and two
-- exact references:
--
--   linear(d, w)            clamp(0.5 - d / w, 0, 1): the distance ramp used by
--                           MyMath.coverage. Exact only for axis-aligned edges.
--   halfPlane(d, nx, ny)    exact area of the pixel inside the tangent half-plane
--                           (SDF value d at the centre, unit gradient (nx, ny)).
--                           Exact for straight edges; curvature error about
--                           L^3 / (12 R) for a circle of radius R (docs/COMPUTE.md C5).
--   supersample(...)        n x n point samples (the classic reference).
--
--   circleArea(...)         exact area of circle and pixel (closed form; uses
--                           math.asin, so REFERENCE ONLY, never texture content)
--   polygonArea(...)        exact area of polygon and pixel (clip + shoelace)
--
-- halfPlane uses only + - * / abs and comparisons, so it is deterministic.

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
