--!strict
--!native
--!optimize 2
-- Universe at Home: Meadow :: RockGen
--
-- Noise-displaced icospheres for the boulders scattered on the slopes. Pure and
-- deterministic (MyMath value noise, sqrt, no libm), so a server Actor builds the
-- arrays in parallel and the serial phase turns them into an EditableMesh.
--
-- build(seed, radius, subdivisions, roughness) returns
--   positions  flat {x1, y1, z1, x2, ...} in studs, centred on the origin, flattened
--              underneath so the rock sits on the ground
--   triangles  flat {a1, b1, c1, ...}, 1-based vertex indices, counter-clockwise seen
--              from outside (the front face, EditableMesh winding rule)
--   colors     flat {r1, g1, b1, ...} in 0..1 per vertex (lichen and moss on top)

local MyMath = require("../Universe/MyMath")

local RockGen = {}

export type Rock = {
	positions: { number },
	triangles: { number },
	colors: { number },
	vertexCount: number,
	triangleCount: number,
}

local sqrt = math.sqrt
local valueNoise2 = MyMath.valueNoise2

-- Pseudo-3D value noise: the mean of three axis-aligned 2D slices.
local function noise3(x: number, y: number, z: number, seed: number): number
	return (valueNoise2(x, y, seed) + valueNoise2(y + 17.5, z, seed + 1) + valueNoise2(z, x + 31.25, seed + 2)) / 3
end
RockGen.noise3 = noise3

local function icosahedron(): ({ number }, { number })
	local t = (1 + sqrt(5)) / 2
	local p = {
		-1, t, 0,
		1, t, 0,
		-1, -t, 0,
		1, -t, 0,
		0, -1, t,
		0, 1, t,
		0, -1, -t,
		0, 1, -t,
		t, 0, -1,
		t, 0, 1,
		-t, 0, -1,
		-t, 0, 1,
	}
	local f = {
		1, 12, 6,
		1, 6, 2,
		1, 2, 8,
		1, 8, 11,
		1, 11, 12,
		2, 6, 10,
		6, 12, 5,
		12, 11, 3,
		11, 8, 7,
		8, 2, 9,
		4, 10, 5,
		4, 5, 3,
		4, 3, 7,
		4, 7, 9,
		4, 9, 10,
		5, 10, 6,
		3, 5, 12,
		7, 3, 11,
		9, 7, 8,
		10, 9, 2,
	}
	-- normalise to the unit sphere
	for i = 1, #p, 3 do
		local x, y, z = p[i], p[i + 1], p[i + 2]
		local l = sqrt(x * x + y * y + z * z)
		p[i], p[i + 1], p[i + 2] = x / l, y / l, z / l
	end
	return p, f
end

local function subdivide(p: { number }, f: { number }): ({ number }, { number })
	local cache: { [number]: number } = {}
	local function midpoint(a: number, b: number): number
		local lo, hi = if a < b then a else b, if a < b then b else a
		local key = lo * 65536 + hi
		local m = cache[key]
		if m then
			return m
		end
		local ax, ay, az = p[3 * a - 2], p[3 * a - 1], p[3 * a]
		local bx, by, bz = p[3 * b - 2], p[3 * b - 1], p[3 * b]
		local x, y, z = (ax + bx) * 0.5, (ay + by) * 0.5, (az + bz) * 0.5
		local l = sqrt(x * x + y * y + z * z)
		table.insert(p, x / l)
		table.insert(p, y / l)
		table.insert(p, z / l)
		local idx = #p // 3
		cache[key] = idx
		return idx
	end
	local out: { number } = {}
	for i = 1, #f, 3 do
		local a, b, c = f[i], f[i + 1], f[i + 2]
		local ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
		for _, v in { a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca } do
			table.insert(out, v)
		end
	end
	return p, out
end

function RockGen.build(seed: number, radius: number, subdivisions: number, roughness: number): Rock
	local p, f = icosahedron()
	for _ = 1, subdivisions do
		p, f = subdivide(p, f)
	end
	-- anisotropic stretch so rocks are not spheres
	local h = MyMath.hash32(seed % 4294967296)
	local sx = 0.85 + (h % 1000) / 1000 * 0.5
	local sy = 0.45 + ((h // 1000) % 1000) / 1000 * 0.35
	local sz = 0.85 + ((h // 1000000) % 1000) / 1000 * 0.5
	local colors = table.create(#p, 0)
	local base = 0.36 + ((h // 7) % 100) / 100 * 0.12
	for i = 1, #p, 3 do
		local x, y, z = p[i], p[i + 1], p[i + 2]
		local n = noise3(x * 1.7 + 3, y * 1.7 + 5, z * 1.7 + 7, seed)
		local d = noise3(x * 4.3 + 11, y * 4.3 + 13, z * 4.3 + 17, seed + 9)
		local r = radius * (1 + roughness * (n - 0.5) * 1.6 + roughness * 0.35 * (d - 0.5))
		local px, py, pz = x * r * sx, y * r * sy, z * r * sz
		if py < -radius * sy * 0.35 then
			py = -radius * sy * 0.35 -- flat underside, sits on the ground
		end
		p[i], p[i + 1], p[i + 2] = px, py, pz
		-- colour: grey stone, darker crevices, moss where the surface faces up
		local g = base + (d - 0.5) * 0.12
		local moss = MyMath.smoothstep(0.35, 0.8, y) * MyMath.smoothstep(0.35, 0.65, n)
		colors[i] = g * (1 - moss) + 0.27 * moss
		colors[i + 1] = g * (1 - moss) + 0.36 * moss
		colors[i + 2] = g * 0.96 * (1 - moss) + 0.16 * moss
	end
	return {
		positions = p,
		triangles = f,
		colors = colors,
		vertexCount = #p // 3,
		triangleCount = #f // 3,
	}
end

return RockGen
