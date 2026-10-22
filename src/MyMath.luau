--!native
--!optimize 2
-- universe-at-home :: MyMath
--
-- The project's numeric axioms, written as code. Every function here uses only
-- operations that round identically on every platform and in both Luau runtimes
-- (interpreter and native): + - * / and sqrt (IEEE 754 correctly rounded), floor,
-- abs, min, max, // and % on integers, and bit32. No libm transcendental functions,
-- no math.lerp (native code fuses it into an FMA), no math.noise or math.random.
-- See docs/RUNTIME_AUDIT.md section 6.5 and docs/DESIGN.md axioms M1 to M9.
--
-- Pixel axioms (docs/COMPUTE.md sections 1, 3.3 and "Flawless pipeline"):
--
--   F1  A pixel is a box filter. The coverage of a shape at a pixel is the EXACT
--       area of the pixel square inside the shape; a byte is flawless when
--       |byte - 255 A| <= 0.5 + 0.01 (the correctly rounded exact area). Exact
--       area, never supersampling, is the reference (n x n point samples err by up
--       to about 1/(2n) per edge crossing).
--   F2  A scene is a box filter of its source-over composite: each pixel is the sum
--       over visible regions of colour times area. Coverage used as alpha is exact
--       only where at most one shape's edge enters the pixel; elsewhere visibility
--       must be computed exactly (compute/Visibility.luau).
--   F3  Content bytes depend only on the deterministic ops listed above (plus the
--       deterministic arcsine Coverage.dasin); interpreter and native code agree.
--
--   C3  Linear ramp error. coverage(d, w) = clamp(1/2 - d/w) is exact only for
--       axis-aligned edges. On a straight 45 degree edge its worst error is
--       (sqrt(2)/2 - 1/2)^2 = 0.04289, i.e. 10.94/255 (closed form). Measured on
--       shapes: 11/255 on circles of any radius, 38/255 at sharp box corners, 26 to
--       57/255 at polygon corners. It is the PREVIEW ramp (Raster MODE_LINEAR).
--   C4  Half-plane exactness. For a straight edge with unit normal (nx, ny) and
--       signed distance d from the pixel centre, coverageHalfPlane is the exact
--       area: the pixel's projection on n has a trapezoid density with ramps of
--       width b = min(|nx|, |ny|) and a plateau of width a - b, a = max(|nx|, |ny|).
--       It is exactly 0 for d >= (a + b)/2 and exactly 1 for d <= -(a + b)/2.
--   C5  Curvature. A boundary of curvature k tangent to the half-plane line lies
--       k t^2 / 2 inside it at tangential offset t, so the half-plane overestimates
--       by at most k (sqrt(2)/2)^3 / 3 = 0.1179 k (30/R in 1/255 units).
--       coverageCurved subtracts the exact first-order term k (t1^3 - t0^3) / 6
--       over the chord [t0, t1] the tangent line cuts from the pixel. Where the
--       line leaves the pixel at a shallow angle, the pixel side cuts the sliver
--       between line and curve obliquely, so the residual is O(k), not O(k^2):
--       measured worst 0.36/255 at R = 8, 0.09 at R = 16, 0.036 at R = 48, 0.004
--       at R = 128, 0.002 at R = 300 (1/255 units, random placements). That is
--       far better than the ramp but NOT flawless (F1 needs < 0.01) below about
--       R = 300, so flawless rendering uses exact disc areas instead
--       (Coverage.discBoxArea, Coverage.discPolyArea).
--   Reach. The reach R_cov of a coverage function is the largest |d| at which it
--       can be strictly between 0 and 1: w/2 for the ramp, COVERAGE_REACH * w =
--       w sqrt(2)/2 for any exact area coverage (every point of a w x w pixel lies
--       within w sqrt(2)/2 of its centre). Culling must drop a shape only when
--       d - L rho >= R_cov (L the Lipschitz constant, rho the node radius) and
--       bounding boxes must grow by R_cov; culling at w/2 silently cuts real
--       coverage on diagonal edges.

local MyMath = {}

local TWO16 = 65536
local TWO32 = 4294967296

MyMath.TWO32 = TWO32

----------------------------------------------------------------------------------
-- M1. Exact 32-bit integer arithmetic inside doubles
----------------------------------------------------------------------------------

-- Low 32 bits of a * b for integers a, b in [0, 2^32).
-- Splitting b into 16-bit halves keeps every partial product below 2^48, so all
-- intermediate values are exact doubles and the result is bit-identical everywhere.
local function mul32(a: number, b: number): number
	local bl = b % TWO16
	local bh = (b - bl) / TWO16
	return (a * bl + (a * bh) % TWO16 * TWO16) % TWO32
end
MyMath.mul32 = mul32

-- Folds any integer-valued number (negative too) into [0, 2^32).
function MyMath.u32(x: number): number
	return (x // 1) % TWO32
end

----------------------------------------------------------------------------------
-- M2. Deterministic hashing and noise
----------------------------------------------------------------------------------

-- lowbias32 (Chris Wellons, public domain): a full-avalanche 32-bit integer hash.
local function hash32(x: number): number
	x = bit32.bxor(x, bit32.rshift(x, 16))
	x = mul32(x, 0x7FEB352D)
	x = bit32.bxor(x, bit32.rshift(x, 15))
	x = mul32(x, 0x846CA68B)
	return bit32.bxor(x, bit32.rshift(x, 16))
end
MyMath.hash32 = hash32

-- Hash of an integer lattice point and a seed. Inputs may be negative.
local function hash2(ix: number, iy: number, seed: number): number
	local h = hash32(bit32.bxor(seed % TWO32, mul32(ix % TWO32, 0x9E3779B1)))
	return hash32(bit32.bxor(h, mul32(iy % TWO32, 0x85EBCA77)))
end
MyMath.hash2 = hash2

-- Uniform number in [0, 1) from a lattice point.
function MyMath.rand2(ix: number, iy: number, seed: number): number
	return hash2(ix, iy, seed) / TWO32
end

-- Quintic fade 6t^5 - 15t^4 + 10t^3. Its derivative peaks at 1.875 (t = 0.5).
local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end
MyMath.fade = fade

-- Value noise in [0, 1). Lipschitz constant <= 1.875 * sqrt(2) per unit of input.
MyMath.VALUE_NOISE_LIPSCHITZ = 2.6517

function MyMath.valueNoise2(x: number, y: number, seed: number): number
	local ix = x // 1
	local iy = y // 1
	local ux = fade(x - ix)
	local uy = fade(y - iy)
	local a = hash2(ix, iy, seed) / TWO32
	local b = hash2(ix + 1, iy, seed) / TWO32
	local c = hash2(ix, iy + 1, seed) / TWO32
	local d = hash2(ix + 1, iy + 1, seed) / TWO32
	local ab = a + (b - a) * ux
	local cd = c + (d - c) * ux
	return ab + (cd - ab) * uy
end

-- Fractal sum of value noise. Returns value in [0, 1) and its Lipschitz bound.
function MyMath.fbm2(x: number, y: number, seed: number, octaves: number): (number, number)
	local sum, amp, freq, norm, lip = 0, 1, 1, 0, 0
	for o = 1, octaves do
		sum += amp * MyMath.valueNoise2(x * freq, y * freq, seed + o * 1013)
		norm += amp
		lip += amp * freq * 2.6517
		amp *= 0.5
		freq *= 2
	end
	return sum / norm, lip / norm
end

----------------------------------------------------------------------------------
-- M3. Deterministic trigonometry (angles in turns: 1 turn = 360 degrees)
----------------------------------------------------------------------------------

local TAU = 6.283185307179586

-- sin(2 pi t) from an odd Taylor polynomial up to x^15 on [-pi/2, pi/2].
-- Truncation error is below 1e-10; only + and * are used, so it is bit-identical
-- on every platform (unlike math.sin).
local function dsinTurns(t: number): number
	t = t - t // 1 -- [0, 1)
	local s
	if t < 0.25 then
		s = t
	elseif t < 0.75 then
		s = 0.5 - t
	else
		s = t - 1
	end
	local x = s * TAU
	local x2 = x * x
	return x
		* (1 + x2 * (-1 / 6 + x2 * (1 / 120 + x2 * (-1 / 5040 + x2 * (1 / 362880 + x2 * (-1 / 39916800 + x2 * (1 / 6227020800 + x2 * (-1 / 1307674368000))))))))
end
MyMath.dsinTurns = dsinTurns

function MyMath.dcosTurns(t: number): number
	return dsinTurns(t + 0.25)
end

----------------------------------------------------------------------------------
-- M4. Shaping functions
----------------------------------------------------------------------------------

function MyMath.clamp01(x: number): number
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

function MyMath.smoothstep(e0: number, e1: number, x: number): number
	local t = (x - e0) / (e1 - e0)
	t = if t < 0 then 0 elseif t > 1 then 1 else t
	return t * t * (3 - 2 * t)
end

-- Linear interpolation written out so native code never fuses it into an FMA.
function MyMath.mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

----------------------------------------------------------------------------------
-- M5. Signed distance primitives (negative inside). All are exact or bounded
-- distances with Lipschitz constant 1, which the rasterizer relies on.
----------------------------------------------------------------------------------

function MyMath.sdCircle(px: number, py: number, cx: number, cy: number, r: number): number
	local dx, dy = px - cx, py - cy
	return math.sqrt(dx * dx + dy * dy) - r
end

-- Box centred at (cx, cy) with half extents (hx, hy) and corner radius rad.
function MyMath.sdRoundBox(px: number, py: number, cx: number, cy: number, hx: number, hy: number, rad: number): number
	local qx = math.abs(px - cx) - hx + rad
	local qy = math.abs(py - cy) - hy + rad
	local ox = if qx > 0 then qx else 0
	local oy = if qy > 0 then qy else 0
	local inside = if qx > qy then qx else qy
	if inside > 0 then
		inside = 0
	end
	return math.sqrt(ox * ox + oy * oy) + inside - rad
end

-- Capsule: segment a-b thickened by radius r.
function MyMath.sdSegment(px: number, py: number, ax: number, ay: number, bx: number, by: number, r: number): number
	local pax, pay = px - ax, py - ay
	local bax, bay = bx - ax, by - ay
	local len2 = bax * bax + bay * bay
	local h = if len2 > 0 then (pax * bax + pay * bay) / len2 else 0
	h = if h < 0 then 0 elseif h > 1 then 1 else h
	local dx, dy = pax - bax * h, pay - bay * h
	return math.sqrt(dx * dx + dy * dy) - r
end

-- Polygon given as flat {x1, y1, x2, y2, ...}; exact signed distance with the
-- even-odd winding sign (Inigo Quilez's sdPolygon).
function MyMath.sdPolygon(px: number, py: number, pts: { number }): number
	local n = #pts // 2
	local d = math.huge
	local s = 1
	local jx, jy = pts[2 * n - 1], pts[2 * n]
	for i = 1, n do
		local vx, vy = pts[2 * i - 1], pts[2 * i]
		local ex, ey = jx - vx, jy - vy
		local wx, wy = px - vx, py - vy
		local ee = ex * ex + ey * ey
		local h = if ee > 0 then (wx * ex + wy * ey) / ee else 0
		h = if h < 0 then 0 elseif h > 1 then 1 else h
		local bx, by = wx - ex * h, wy - ey * h
		local dd = bx * bx + by * by
		if dd < d then
			d = dd
		end
		local c1 = py >= vy
		local c2 = py < jy
		local c3 = ex * wy > ey * wx
		if (c1 and c2 and c3) or (not c1 and not c2 and not c3) then
			s = -s
		end
		jx, jy = vx, vy
	end
	return s * math.sqrt(d)
end

-- Polynomial smooth minimum. Its partial derivatives are h and 1 - h, so it keeps
-- the Lipschitz bound of its inputs (proof in docs/DESIGN.md).
function MyMath.smin(a: number, b: number, k: number): number
	if k <= 0 then
		return if a < b then a else b
	end
	local h = 0.5 + 0.5 * (b - a) / k
	h = if h < 0 then 0 elseif h > 1 then 1 else h
	return b + (a - b) * h - k * h * (1 - h)
end

-- The LINEAR PREVIEW RAMP: clamp(0.5 - d / w, 0, 1) from the signed distance d in
-- pixels and an anti-aliasing width w (1 = one pixel). Exactly 0 when d >= w/2 and
-- exactly 1 when d <= -w/2 (its reach is w/2), which ramp-based culling relies on.
-- As an estimate of pixel area it is exact only for axis-aligned edges: up to
-- 10.94/255 on a straight 45 degree edge (C3, closed form), 11/255 on circles of
-- any radius, 38/255 at sharp box corners and 26 to 57/255 at polygon corners
-- (measured, docs/COMPUTE.md 3.3). Use it for previews (Raster MODE_LINEAR); use
-- coverageHalfPlane, coverageCurved or exact areas for content (F1).
function MyMath.coverage(d: number, w: number): number
	local a = 0.5 - d / w
	return if a < 0 then 0 elseif a > 1 then 1 else a
end

----------------------------------------------------------------------------------
-- M8. Exact-area coverage axioms (C4, C5; header). Moved verbatim from
-- compute/Coverage.luau (halfPlane, halfPlaneCurved), so results are bit-identical;
-- the optional w scales the box filter (a w x w pixel, default 1): d is divided by
-- w and the curvature k multiplied by w, which is exact when w is 1 or omitted.
----------------------------------------------------------------------------------

local abs = math.abs

-- sqrt(2)/2: the reach of every exact-area coverage function in pixel widths.
MyMath.COVERAGE_REACH = 0.70710678118654757

-- C4. Exact area of {q in pixel : d + n . (q - centre) <= 0} for |n| = 1, i.e. the
-- part of the pixel on the inner side of a straight edge at signed distance d
-- (negative inside) with unit normal (nx, ny). Only |nx| and |ny| matter.
local function coverageHalfPlane(d: number, nx: number, ny: number, w: number?): number
	if w then
		d = d / w
	end
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
MyMath.coverageHalfPlane = coverageHalfPlane

-- C5. Half-plane area minus the first-order curvature term k (t1^3 - t0^3) / 6
-- over the chord the tangent line cuts from the pixel. k > 0 where the shape is
-- convex (1 / R for a disc of radius R), k < 0 where it is concave. Error O(k) at
-- shallow chord exits (header), so it is an estimator, not an exact area.
local function coverageCurved(d: number, nx: number, ny: number, k: number, w: number?): number
	if w then
		d = d / w
		k = k * w
	end
	local base = coverageHalfPlane(d, nx, ny)
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
MyMath.coverageCurved = coverageCurved

----------------------------------------------------------------------------------
-- M6. Exact 8-bit colour arithmetic
----------------------------------------------------------------------------------

-- round(t / 255) for integer t in [0, 65025], with no division. Verified for every
-- input by brute force. Each 16-bit lane of a SWAR word stays below 2^16.
function MyMath.div255(t: number): number
	local x = t + 128
	return (x + x // 256) // 256
end

function MyMath.pack(r: number, g: number, b: number, a: number): number
	return r + g * 256 + b * 65536 + a * 16777216
end

function MyMath.unpack(c: number): (number, number, number, number)
	return c % 256, (c // 256) % 256, (c // 65536) % 256, c // 16777216
end

-- Parses "#RRGGBB" or "#RRGGBBAA" into a packed straight-alpha RGBA8 value.
function MyMath.hex(s: string): number
	local h = string.gsub(s, "^#", "")
	local r = tonumber(string.sub(h, 1, 2), 16) or 0
	local g = tonumber(string.sub(h, 3, 4), 16) or 0
	local b = tonumber(string.sub(h, 5, 6), 16) or 0
	local a = if #h >= 8 then tonumber(string.sub(h, 7, 8), 16) or 255 else 255
	return r + g * 256 + b * 65536 + a * 16777216
end

-- sRGB to linear light in 16-bit fixed point, generated offline (tools/gen_vectors.py)
-- so every client uses the same integers. Strictly increasing.
local SRGB_TO_LINEAR16 = {
	0, 20, 40, 60, 80, 99, 119, 139, 159, 179, 199, 219, 241, 264, 288, 313,
	340, 367, 396, 427, 458, 491, 526, 562, 599, 637, 677, 718, 761, 805, 851, 898,
	947, 997, 1048, 1101, 1156, 1212, 1270, 1330, 1391, 1453, 1517, 1583, 1651, 1720, 1790, 1863,
	1937, 2013, 2090, 2170, 2250, 2333, 2418, 2504, 2592, 2681, 2773, 2866, 2961, 3058, 3157, 3258,
	3360, 3464, 3570, 3678, 3788, 3900, 4014, 4129, 4247, 4366, 4488, 4611, 4736, 4864, 4993, 5124,
	5257, 5392, 5530, 5669, 5810, 5953, 6099, 6246, 6395, 6547, 6700, 6856, 7014, 7174, 7335, 7500,
	7666, 7834, 8004, 8177, 8352, 8528, 8708, 8889, 9072, 9258, 9445, 9635, 9828, 10022, 10219, 10417,
	10619, 10822, 11028, 11235, 11446, 11658, 11873, 12090, 12309, 12530, 12754, 12980, 13209, 13440, 13673, 13909,
	14146, 14387, 14629, 14874, 15122, 15371, 15623, 15878, 16135, 16394, 16656, 16920, 17187, 17456, 17727, 18001,
	18277, 18556, 18837, 19121, 19407, 19696, 19987, 20281, 20577, 20876, 21177, 21481, 21787, 22096, 22407, 22721,
	23038, 23357, 23678, 24002, 24329, 24658, 24990, 25325, 25662, 26001, 26344, 26688, 27036, 27386, 27739, 28094,
	28452, 28813, 29176, 29542, 29911, 30282, 30656, 31033, 31412, 31794, 32179, 32567, 32957, 33350, 33745, 34143,
	34544, 34948, 35355, 35764, 36176, 36591, 37008, 37429, 37852, 38278, 38706, 39138, 39572, 40009, 40449, 40891,
	41337, 41785, 42236, 42690, 43147, 43606, 44069, 44534, 45002, 45473, 45947, 46423, 46903, 47385, 47871, 48359,
	48850, 49344, 49841, 50341, 50844, 51349, 51858, 52369, 52884, 53401, 53921, 54445, 54971, 55500, 56032, 56567,
	57105, 57646, 58190, 58737, 59287, 59840, 60396, 60955, 61517, 62082, 62650, 63221, 63795, 64372, 64952, 65535,
}
MyMath.SRGB_TO_LINEAR16 = SRGB_TO_LINEAR16

function MyMath.srgbToLinear16(c8: number): number
	return SRGB_TO_LINEAR16[c8 + 1]
end

-- Inverse by binary search: the sRGB byte whose linear value is nearest to v.
function MyMath.linear16ToSrgb(v: number): number
	local lo, hi = 0, 255
	while lo < hi do
		local mid = (lo + hi) // 2
		if SRGB_TO_LINEAR16[mid + 1] < v then
			lo = mid + 1
		else
			hi = mid
		end
	end
	if lo > 0 and v - SRGB_TO_LINEAR16[lo] <= SRGB_TO_LINEAR16[lo + 1] - v then
		return lo - 1
	end
	return lo
end

----------------------------------------------------------------------------------
-- M7. Resolution allocation under a pixel-area budget ("water filling")
----------------------------------------------------------------------------------

-- Chooses a square texture size for each surface so the total pixel area fits the
-- budget. A surface gains detail only up to the pixels it covers on screen, so the
-- benefit of each size step is min(area, demand) * weight and has diminishing
-- returns. Greedy by benefit per added pixel is optimal for the continuous
-- relaxation and within one size step of optimal here.
--
-- demands[i]: on-screen pixel area of surface i (its useful texel count)
-- weights[i]: importance multiplier, default 1
-- budget:     total texel area allowed
-- sizes:      ascending allowed edge lengths, e.g. {64, 128, 256, 512, 1024}
-- returns { edge length or 0 } per surface (0 = no editable image)
function MyMath.allocate(demands: { number }, weights: { number }?, budget: number, sizes: { number }): { number }
	local n = #demands
	local level = table.create(n, 0) -- index into sizes; 0 = none
	local result = table.create(n, 0)
	local remaining = budget
	local function area(l: number): number
		if l == 0 then
			return 0
		end
		local s = sizes[l]
		return s * s
	end
	while true do
		local best, bestRatio = 0, 0
		for i = 1, n do
			local l = level[i]
			if l < #sizes then
				local cur, nxt = area(l), area(l + 1)
				local cost = nxt - cur
				if cost <= remaining then
					local d = demands[i]
					local w = if weights then weights[i] or 1 else 1
					local gain = ((if nxt < d then nxt else d) - (if cur < d then cur else d)) * w
					local ratio = gain / cost
					if ratio > bestRatio then
						best, bestRatio = i, ratio
					end
				end
			end
		end
		if best == 0 then
			break
		end
		remaining -= area(level[best] + 1) - area(level[best])
		level[best] += 1
	end
	for i = 1, n do
		result[i] = if level[i] == 0 then 0 else sizes[level[i]]
	end
	return result
end

return MyMath
