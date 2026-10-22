--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: CubeSphere
--
-- A sphere as six cube faces, each a quadtree of patches. Face f has an outward normal N
-- and tangent axes U, V with U x V = N (right-handed on every face), so the triangle
-- (s0,t0) (s1,t0) (s1,t1) is counter-clockwise seen from outside on all six faces, and a
-- normal map's tangent frame has the same handedness everywhere.
--
-- Face parameter (a, b) in [0, 1]^2 -> cube point C = N + (2a - 1) U + (2b - 1) V ->
-- sphere point by Nowell's mapping
--     x' = x sqrt(1 - y^2/2 - z^2/2 + y^2 z^2 / 3)   (and cyclic)
-- which is exactly unit length on the cube surface and spreads area much more evenly
-- than normalising (cell areas vary by about 1.4x instead of 5.2x). Only + - * and
-- sqrt (correctly rounded in IEEE 754), so every device computes the same points.
--
-- Patch (face, level, i, j) covers a in [i, i+1] / 2^level, b in [j, j+1] / 2^level;
-- patch-local parameters s, t in [0, 1] (s along U, t along V).

local CubeSphere = {}

-- N, U, V per face (1-based): +X, -X, +Y, -Y, +Z, -Z
local FN = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}
local FU = {
	{ 0, 0, -1 },
	{ 0, 0, 1 },
	{ 1, 0, 0 },
	{ 1, 0, 0 },
	{ 1, 0, 0 },
	{ -1, 0, 0 },
}
local FV = {
	{ 0, 1, 0 },
	{ 0, 1, 0 },
	{ 0, 0, -1 },
	{ 0, 0, 1 },
	{ 0, 1, 0 },
	{ 0, 1, 0 },
}
CubeSphere.FN = FN
CubeSphere.FU = FU
CubeSphere.FV = FV

local sqrt = math.sqrt

-- Cube point of face parameter (a, b) on face f (1-based). a, b may leave [0, 1] slightly
-- (gutter samples): the face plane simply extends.
local function cubePoint(f: number, a: number, b: number): (number, number, number)
	local n, u, v = FN[f], FU[f], FV[f]
	local sa, sb = 2 * a - 1, 2 * b - 1
	return n[1] + sa * u[1] + sb * v[1], n[2] + sa * u[2] + sb * v[2], n[3] + sa * u[3] + sb * v[3]
end
CubeSphere.cubePoint = cubePoint

-- Nowell's cube-to-sphere map, renormalised (a no-op on the cube surface up to rounding,
-- and the right projection for gutter points just beyond an edge).
local function toSphere(x: number, y: number, z: number): (number, number, number)
	local x2, y2, z2 = x * x, y * y, z * z
	local sx = x * sqrt(math.max(0, 1 - y2 * 0.5 - z2 * 0.5 + y2 * z2 / 3))
	local sy = y * sqrt(math.max(0, 1 - z2 * 0.5 - x2 * 0.5 + z2 * x2 / 3))
	local sz = z * sqrt(math.max(0, 1 - x2 * 0.5 - y2 * 0.5 + x2 * y2 / 3))
	local l = sqrt(sx * sx + sy * sy + sz * sz)
	return sx / l, sy / l, sz / l
end
CubeSphere.toSphere = toSphere

-- Unit sphere point of face parameter (a, b).
function CubeSphere.facePoint(f: number, a: number, b: number): (number, number, number)
	return toSphere(cubePoint(f, a, b))
end

-- Unit sphere point of patch-local (s, t) in patch (f, level, i, j).
function CubeSphere.patchPoint(f: number, level: number, i: number, j: number, s: number, t: number): (number, number, number)
	local inv = math.ldexp(1, -level) -- exact power of two (unlike ^, which calls pow)
	return toSphere(cubePoint(f, (i + s) * inv, (j + t) * inv))
end

-- Edge length (radians, along U) of a patch at `level`, at the face centre where it is
-- largest; used for LOD metrics and octave budgets. A face edge spans 90 degrees.
function CubeSphere.patchAngle(level: number): number
	return (math.pi / 2) * math.ldexp(1, -level)
end

-- Face (1-based) and face parameters (a, b) of a unit direction, for the gnomonic
-- (central projection) parameterisation used by the low-resolution sphere caches. This
-- is NOT the inverse of Nowell's map; it is its own simple, invertible cube map.
function CubeSphere.gnomonic(x: number, y: number, z: number): (number, number, number)
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	local f, m
	if ax >= ay and ax >= az then
		f = if x > 0 then 1 else 2
		m = ax
	elseif ay >= az then
		f = if y > 0 then 3 else 4
		m = ay
	else
		f = if z > 0 then 5 else 6
		m = az
	end
	local cx, cy, cz = x / m, y / m, z / m
	local u, v = FU[f], FV[f]
	local a = ((cx * u[1] + cy * u[2] + cz * u[3]) + 1) * 0.5
	local b = ((cx * v[1] + cy * v[2] + cz * v[3]) + 1) * 0.5
	return f, a, b
end

-- Inverse of `gnomonic`: unit direction of face parameter (a, b).
function CubeSphere.gnomonicPoint(f: number, a: number, b: number): (number, number, number)
	local x, y, z = cubePoint(f, a, b)
	local l = sqrt(x * x + y * y + z * z)
	return x / l, y / l, z / l
end

-- Numeric key of a patch: exact integer below 2^53 for level <= 14.
function CubeSphere.key(f: number, level: number, i: number, j: number): number
	return ((f * 32 + level) * 16384 + i) * 16384 + j
end

function CubeSphere.unkey(key: number): (number, number, number, number)
	local j = key % 16384
	local r = (key - j) / 16384
	local i = r % 16384
	r = (r - i) / 16384
	local level = r % 32
	local f = (r - level) / 32
	return f, level, i, j
end

return CubeSphere
