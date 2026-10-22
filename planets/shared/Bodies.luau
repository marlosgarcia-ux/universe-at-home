--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Bodies
--
-- The solar system of the demo: what each body is, where it is, and its surface as pure
-- functions of a unit direction (x, y, z) from the body's centre. Every resolution, patch,
-- impostor and test samples these same functions, so a body is one consistent object from
-- orbit to the ground.
--
--   height(B, x, y, z, spacing)            studs above the reference sphere (sea level)
--   land(B, x, y, z, h, slopeCos, spacing) albedo r, g, b (0..1) and roughness of dry land
--   water(B, depth)                         albedo and roughness of sea water
--
-- `spacing` is the sampling interval on the unit sphere (texel or vertex pitch / radius):
-- octaves finer than it would alias, so the functions leave them out (Noise3.octavesFor).
--
-- Bodies (radius, world position in studs):
--   Terra     1600  (0, 0, 0)            oceans, continents, ridged ranges, biomes, ice caps
--   Selene     430  (-5200, 1400, 7400)  grey moon; craters are signed-distance profiles
--   Saturnia  2400  (21000, -2500, -30000) banded gas giant with a storm and rings
--   Sol             direction from Lighting:GetSunDirection() (the engine's sun)

local Noise3 = require("./Noise3")
local CubeSphere = require("./CubeSphere")
local MyMath = require("../Universe/MyMath")

local Bodies = {}

local abs, sqrt = math.abs, math.sqrt
local smoothstep = MyMath.smoothstep
local fbm, ridged, octavesFor = Noise3.fbm, Noise3.ridged, Noise3.octavesFor

export type Atmosphere = { r: number, g: number, b: number, thickness: number, strength: number }

export type Rings = {
	inner: number, -- radii in body radii
	outer: number,
	-- normal of the ring plane (unit, body-local)
	nx: number,
	ny: number,
	nz: number,
	samples: number, -- profile resolution
	density: { number }, -- opacity 0..1 per sample (piecewise linear)
	cr: { number }, -- colour per sample
	cg: { number },
	cb: { number },
	prefix: { number }, -- integral of density (box filtering, see ringAt)
	prefixR: { number }, -- integral of density * colour
	prefixG: { number },
	prefixB: { number },
}

export type Body = {
	id: string,
	name: string,
	kind: string, -- "rocky" | "gas"
	radius: number,
	px: number,
	py: number,
	pz: number,
	seed: number,
	maxHeight: number, -- largest |height| in studs (bounds, skirts)
	sea: boolean,
	fields: { Noise3.Field },
	atmosphere: Atmosphere?,
	rings: Rings?,
	-- Raw low-frequency fields (c1, c2) at a point. Callers never use them directly: the
	-- fields are defined through Bodies.coarseAt (a fixed lattice, see there).
	coarse: (Body, number, number, number) -> (number, number),
	height: (Body, number, number, number, number, number) -> number, -- (..., spacing, c1)
	land: (Body, number, number, number, number, number, number, number) -> (number, number, number, number), -- (..., h, slopeCos, spacing, c2)
	water: (Body, number) -> (number, number, number, number),
	-- albedo without lighting for impostor caches of bodies with no height (gas giants)
	albedo: ((Body, number, number, number) -> (number, number, number))?,
}

----------------------------------------------------------------------------------------
-- Terra
----------------------------------------------------------------------------------------

-- Low-frequency fields of Terra: continental elevation (its zero set is the coast, before
-- fine detail) and the moisture/temperature noise. Lattice spacing above 40 studs.
local function terraCoarse(B: Body, x: number, y: number, z: number): (number, number)
	local F = B.fields
	-- a gentle warp breaks the noise's isotropy into continent-like shapes
	local wx = fbm(F[5], x, y, z, 0.9, 3, 0.5)
	local c = fbm(F[1], x + 0.35 * wx, y - 0.25 * wx, z + 0.3 * wx, 1.15, 6, 0.5)
	local q = fbm(F[6], x, y, z, 2.1, 4, 0.55)
	return c * 0.78 + 0.07, q
end

-- Elevation about [-1, 1] including the fine coast detail, whose octaves fade in with
-- resolution.
local function terraElevation(B: Body, x: number, y: number, z: number, spacing: number, c1: number): number
	local fine = fbm(B.fields[3], x, y, z, 40, octavesFor(40, spacing, 7), 0.5)
	return c1 + 0.045 * fine
end

local function terraHeight(B: Body, x: number, y: number, z: number, spacing: number, c1: number): number
	local e = terraElevation(B, x, y, z, spacing, c1)
	if e <= 0 then
		return 30 * e -- sea floor, down to about -30 studs
	end
	local land = smoothstep(0, 0.32, e)
	local m = ridged(B.fields[2], x, y, z, 3.4, octavesFor(3.4, spacing, 12), 0.5)
	local hills = fbm(B.fields[4], x, y, z, 26, octavesFor(26, spacing, 8), 0.5)
	return 30 * e + land * (46 * m * m + 3.5 * hills * (0.5 + m))
end

local function mix3(r1: number, g1: number, b1: number, r2: number, g2: number, b2: number, t: number): (number, number, number)
	return r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t
end

local function terraLand(B: Body, x: number, y: number, z: number, h: number, slopeCos: number, spacing: number, q: number): (number, number, number, number)
	local lat = abs(y)
	local moist = 0.52 + 0.75 * q - 0.18 * smoothstep(0.15, 0.45, lat) * (1 - lat)
	local temp = 1.08 - 1.3 * lat * lat * (1.25 - 0.25 * lat) - (if h > 0 then h else 0) / 52 + 0.12 * q
	-- lowland palette by moisture: desert, savanna, grass, forest
	local r, g, b
	if moist < 0.3 then
		r, g, b = mix3(0.80, 0.66, 0.43, 0.62, 0.55, 0.30, smoothstep(0.18, 0.3, moist))
	elseif moist < 0.55 then
		r, g, b = mix3(0.62, 0.55, 0.30, 0.31, 0.45, 0.17, smoothstep(0.3, 0.55, moist))
	else
		r, g, b = mix3(0.31, 0.45, 0.17, 0.11, 0.27, 0.10, smoothstep(0.55, 0.85, moist))
	end
	local rough = 0.86
	-- cold: tundra then snow
	local tundra = smoothstep(0.42, 0.28, temp)
	r, g, b = mix3(r, g, b, 0.46, 0.45, 0.37, tundra)
	-- rock on steep ground and high ranges
	local rock = math.max(smoothstep(0.93, 0.80, slopeCos), smoothstep(26, 40, h))
	r, g, b = mix3(r, g, b, 0.40, 0.36, 0.33, rock)
	rough = rough + (0.74 - rough) * rock
	local snow = smoothstep(0.26, 0.14, temp + 0.08 * (1 - slopeCos))
	r, g, b = mix3(r, g, b, 0.93, 0.94, 0.97, snow)
	rough = rough + (0.52 - rough) * snow
	-- beaches where land meets warm sea
	local beach = smoothstep(0.9, 0.25, h) * smoothstep(0.3, 0.5, temp) * smoothstep(0.86, 0.95, slopeCos)
	r, g, b = mix3(r, g, b, 0.79, 0.72, 0.53, beach)
	rough = rough + (0.92 - rough) * beach
	return r, g, b, rough
end

local function terraWater(B: Body, depth: number): (number, number, number, number)
	local t = depth / 24
	if t > 1 then
		t = 1
	end
	t = sqrt(t)
	local r, g, b = mix3(0.11, 0.38, 0.44, 0.012, 0.055, 0.15, t)
	return r, g, b, 0.09
end

----------------------------------------------------------------------------------------
-- Selene: craters as signed-distance profiles
----------------------------------------------------------------------------------------

-- Crater levels: n x n gnomonic cells per cube face. A crater sits strictly inside its cell
-- (centre and reach chosen so the profile never leaves the cell), so a point only ever
-- looks at its own cell per level: one hash per level, no seams at cell or face edges.
local CRATER_LEVELS = { 3, 6, 12, 24, 48, 96, 192, 384 }

local function craterProfile(rho: number): number
	-- rho = distance / radius. Bowl (parabolic, depth 1 at the centre), raised rim around
	-- rho = 1, nothing beyond 1.3. A function of the distance alone: the crater is the
	-- distance field of its centre pushed through this profile.
	if rho >= 1.3 then
		return 0
	end
	local hgt = 0
	if rho < 1 then
		hgt = -(1 - rho * rho)
	end
	local u = (rho - 1) / 0.3
	if u > -1 and u < 1 then
		local w = 1 - u * u
		hgt += 0.32 * w * w
	end
	return hgt
end
Bodies.craterProfile = craterProfile

local function seleneCraters(B: Body, x: number, y: number, z: number, spacing: number): number
	local f, a, b = CubeSphere.gnomonic(x, y, z)
	local total = 0
	for li, n in CRATER_LEVELS do
		local cellAngle = (math.pi / 2) / n
		-- a crater narrower than about 3 samples cannot be drawn: stop there
		if cellAngle * 0.3 < 3 * spacing then
			break
		end
		local ci = (a * n) // 1
		local cj = (b * n) // 1
		if ci >= n then
			ci = n - 1
		end
		if cj >= n then
			cj = n - 1
		end
		local h = MyMath.hash32(MyMath.u32(((f * 16 + li) * 4096 + ci) * 4096 + cj + B.seed * 7919))
		if h % 100 < 58 then
			-- radius 0.10 .. 0.26 of the cell, centre kept 1.5 radii from the cell's edges
			local rr = 0.10 + 0.16 * ((h // 128) % 1024) / 1023
			local margin = rr * 1.5
			local ja = margin + (1 - 2 * margin) * ((h // 131072) % 256) / 255
			local jb = margin + (1 - 2 * margin) * ((h // 33554432) % 128) / 127
			local ga, gb = (ci + ja) / n, (cj + jb) / n
			local cx, cy, cz = CubeSphere.gnomonicPoint(f, ga, gb)
			local dx, dy, dz = x - cx, y - cy, z - cz
			local d = sqrt(dx * dx + dy * dy + dz * dz)
			-- A cell is 2 / n cube units wide; on the sphere that shrinks by the gnomonic
			-- factor 1 / (1 + u^2 + v^2) towards face edges and corners. Scaling the radius
			-- by it keeps every crater inside its own cell everywhere on the face.
			local u, v = 2 * ga - 1, 2 * gb - 1
			local radius = rr * (2 / n) / (1 + u * u + v * v)
			local depth = radius * B.radius * 0.18
			total += depth * craterProfile(d / radius)
		end
	end
	return total
end

local function seleneCoarse(B: Body, x: number, y: number, z: number): (number, number)
	return 0, fbm(B.fields[2], x, y, z, 1.25, 4, 0.5)
end

local function seleneHeight(B: Body, x: number, y: number, z: number, spacing: number, c1: number): number
	local base = fbm(B.fields[1], x, y, z, 1.7, octavesFor(1.7, spacing, 12), 0.52) * 7
	return base + seleneCraters(B, x, y, z, spacing)
end

local function seleneLand(B: Body, x: number, y: number, z: number, h: number, slopeCos: number, spacing: number, c2: number): (number, number, number, number)
	local mare = smoothstep(0.05, 0.3, c2)
	local grain = fbm(B.fields[3], x, y, z, 30, octavesFor(30, spacing, 6), 0.5)
	local v = 0.56 - 0.27 * mare + 0.05 * grain + 0.04 * (1 - slopeCos)
	return v, v * 0.98, v * 0.95, 0.92
end

local function noWater(B: Body, depth: number): (number, number, number, number)
	return 0, 0, 0, 1
end

----------------------------------------------------------------------------------------
-- Saturnia: bands, a storm and rings
----------------------------------------------------------------------------------------

local function saturniaAlbedo(B: Body, x: number, y: number, z: number): (number, number, number)
	local F = B.fields
	-- stretched noise: turbulence that runs along the bands
	local w = fbm(F[1], x * 1.3, y * 7.5, z * 1.3, 1, 5, 0.55)
	local lat = y + 0.045 * w
	local s1 = MyMath.dsinTurns(lat * 3.1 + 0.08)
	local s2 = MyMath.dsinTurns(lat * 7.3 + 0.31)
	local s3 = MyMath.dsinTurns(lat * 15.7 + 0.6)
	local v = 0.5 + 0.28 * s1 + 0.14 * s2 + 0.08 * s3
	local r, g, b = mix3(0.55, 0.40, 0.27, 0.93, 0.86, 0.70, MyMath.clamp01(v))
	-- pale polar hoods
	local pole = smoothstep(0.72, 0.95, abs(y))
	r, g, b = mix3(r, g, b, 0.62, 0.66, 0.70, pole)
	-- the storm: an ellipse in (longitude, latitude), signed distance through a smooth edge
	local sx, sz = 0.80, 0.54 -- storm direction in the xz plane (unit)
	local along = x * sz - z * sx -- longitude-like offset
	local lat0 = y + 0.21
	local facing = x * sx + z * sz
	if facing > 0.3 then
		local ea, eb = along / 0.16, lat0 / 0.075
		local e = sqrt(ea * ea + eb * eb)
		local storm = smoothstep(1.05, 0.75, e + 0.12 * w)
		local core = smoothstep(0.6, 0.15, e)
		r, g, b = mix3(r, g, b, 0.76, 0.38, 0.22, storm)
		r, g, b = mix3(r, g, b, 0.86, 0.55, 0.36, core * 0.6)
	end
	return r, g, b
end

local function gasCoarse(B: Body, x: number, y: number, z: number): (number, number)
	return 0, 0
end

local function gasHeight(B: Body, x: number, y: number, z: number, spacing: number, c1: number): number
	return 0
end

local function gasLand(B: Body, x: number, y: number, z: number, h: number, slopeCos: number, spacing: number, c2: number): (number, number, number, number)
	local r, g, b = saturniaAlbedo(B, x, y, z)
	return r, g, b, 0.95
end

-- Ring profile: bands with sharp gaps. Built once; ringAt box-filters it exactly over any
-- radial interval through prefix integrals, so gaps stay crisp and never alias.
local function buildRings(seed: number): Rings
	local inner, outer = 1.24, 2.32
	local N = 1024
	local density = table.create(N + 1, 0)
	local cr = table.create(N + 1, 0)
	local cg = table.create(N + 1, 0)
	local cb = table.create(N + 1, 0)
	for k = 0, N do
		local r = inner + (outer - inner) * k / N
		local d
		-- C ring (faint), B ring (dense), Cassini division, A ring, Encke gap, F edge
		if r < 1.52 then
			d = 0.16 + 0.10 * smoothstep(1.24, 1.52, r)
		elseif r < 1.95 then
			d = 0.78 + 0.18 * smoothstep(1.52, 1.62, r) - 0.10 * smoothstep(1.85, 1.95, r)
		elseif r < 2.03 then
			d = 0.05 -- Cassini division
		elseif r < 2.27 then
			d = 0.55 + 0.1 * smoothstep(2.03, 2.1, r)
			if r > 2.205 and r < 2.215 then
				d = 0.0 -- Encke gap
			end
		else
			d = 0.25 * smoothstep(2.32, 2.27, r)
		end
		-- ringlets: hashed fine structure
		local hv = MyMath.hash32(MyMath.u32(k * 2654435761 + seed)) / 4294967296
		d = d * (0.82 + 0.36 * hv)
		density[k + 1] = MyMath.clamp01(d)
		local tint = 0.5 + 0.5 * MyMath.dsinTurns(r * 2.7)
		cr[k + 1] = 0.80 + 0.12 * tint
		cg[k + 1] = 0.72 + 0.10 * tint
		cb[k + 1] = 0.58 + 0.06 * tint
	end
	-- prefix integrals by the trapezoid rule (exact for the piecewise-linear profile)
	local prefix = table.create(N + 1, 0)
	local pr = table.create(N + 1, 0)
	local pg = table.create(N + 1, 0)
	local pb = table.create(N + 1, 0)
	for k = 1, N do
		local d0, d1 = density[k], density[k + 1]
		prefix[k + 1] = prefix[k] + (d0 + d1) * 0.5
		pr[k + 1] = pr[k] + (d0 * cr[k] + d1 * cr[k + 1]) * 0.5
		pg[k + 1] = pg[k] + (d0 * cg[k] + d1 * cg[k + 1]) * 0.5
		pb[k + 1] = pb[k] + (d0 * cb[k] + d1 * cb[k + 1]) * 0.5
	end
	-- plane tilted 22 degrees about the x axis
	local tilt = 22 / 360
	return {
		inner = inner,
		outer = outer,
		nx = 0,
		ny = MyMath.dcosTurns(tilt),
		nz = MyMath.dsinTurns(tilt),
		samples = N,
		density = density,
		cr = cr,
		cg = cg,
		cb = cb,
		prefix = prefix,
		prefixR = pr,
		prefixG = pg,
		prefixB = pb,
	}
end

-- Integral of a prefix array at fractional sample position u in [0, N] (linear in u between
-- samples; the error against the exact quadratic is below 1/8 of a sample's mass).
local function prefixAt(p: { number }, N: number, u: number): number
	if u <= 0 then
		return 0
	end
	if u >= N then
		return p[N + 1]
	end
	local k = u // 1
	local fr = u - k
	return p[k + 1] + (p[k + 2] - p[k + 1]) * fr
end

-- Mean ring opacity and colour over radii [r0, r1] (in body radii). A box filter of any
-- width, exact up to the profile's sampling: gaps narrower than a pixel dim the pixel by
-- exactly their share instead of flickering.
function Bodies.ringAt(rings: Rings, r0: number, r1: number): (number, number, number, number)
	if r1 < r0 then
		r0, r1 = r1, r0
	end
	local N = rings.samples
	local span = rings.outer - rings.inner
	local u0 = (r0 - rings.inner) / span * N
	local u1 = (r1 - rings.inner) / span * N
	local width = u1 - u0
	if width < 1e-6 then
		-- point sample with linear interpolation
		local u = (u0 + u1) * 0.5
		if u <= 0 or u >= N then
			return 0, 0, 0, 0
		end
		local k = u // 1
		local fr = u - k
		local d = rings.density[k + 1] + (rings.density[k + 2] - rings.density[k + 1]) * fr
		local r = rings.cr[k + 1] + (rings.cr[k + 2] - rings.cr[k + 1]) * fr
		local g = rings.cg[k + 1] + (rings.cg[k + 2] - rings.cg[k + 1]) * fr
		local b = rings.cb[k + 1] + (rings.cb[k + 2] - rings.cb[k + 1]) * fr
		return d, r, g, b
	end
	local mass = prefixAt(rings.prefix, N, u1) - prefixAt(rings.prefix, N, u0)
	local d = mass / width
	if mass <= 1e-12 then
		return 0, 0, 0, 0
	end
	local r = (prefixAt(rings.prefixR, N, u1) - prefixAt(rings.prefixR, N, u0)) / mass
	local g = (prefixAt(rings.prefixG, N, u1) - prefixAt(rings.prefixG, N, u0)) / mass
	local b = (prefixAt(rings.prefixB, N, u1) - prefixAt(rings.prefixB, N, u0)) / mass
	return d, r, g, b
end

----------------------------------------------------------------------------------------
-- the coarse lattice
----------------------------------------------------------------------------------------

-- The low-frequency fields of a body are DEFINED as the bilinear interpolation of
-- B.coarse over a fixed lattice: on each cube face, nodes at gnomonic parameters
-- (m / K, n / K), m, n = 0..K. A point uses the cell of its own canonical face
-- (CubeSphere.gnomonic), so the field is one function on the whole sphere: every patch of
-- every level, every face, the impostor caches and the tests sample exactly the same
-- values. Two faces meet along nodes they share, where bilinear interpolation reduces to
-- linear interpolation between the same two nodes, so the field is continuous across
-- cube edges too. Per-patch interpolation grids cannot give this: neighbours and levels
-- would each interpolate their own way and the mountains, which amplify the elevation,
-- would show seams of up to 100 colour levels (measured, tools/planets_seamdiag.luau).
--
-- Cost: a deep patch spans a few lattice cells, so a tile evaluates tens of nodes instead
-- of 4356 samples x 13 octaves.
Bodies.COARSE_K = 128

local COARSE_K = 128
local NODES = COARSE_K + 1

-- (c1, c2) at unit point (x, y, z). `cache` (optional) holds node values already computed:
-- key 2 * node and 2 * node + 1.
function Bodies.coarseAt(B: Body, x: number, y: number, z: number, cache: { [number]: number }?): (number, number)
	local f, a, b = CubeSphere.gnomonic(x, y, z)
	local u, v = a * COARSE_K, b * COARSE_K
	local m = u // 1
	local n = v // 1
	if m > COARSE_K - 1 then
		m = COARSE_K - 1
	elseif m < 0 then
		m = 0
	end
	if n > COARSE_K - 1 then
		n = COARSE_K - 1
	elseif n < 0 then
		n = 0
	end
	local fx, fy = u - m, v - n
	local base = ((f - 1) * NODES + n) * NODES + m
	local coarseFn = B.coarse
	local a00, b00, a10, b10, a01, b01, a11, b11
	local function node(id: number, mm: number, nn: number): (number, number)
		if cache then
			local c1 = cache[id * 2]
			if c1 then
				return c1, cache[id * 2 + 1]
			end
		end
		local nx, ny, nz = CubeSphere.gnomonicPoint(f, mm / COARSE_K, nn / COARSE_K)
		local c1, c2 = coarseFn(B, nx, ny, nz)
		if cache then
			cache[id * 2] = c1
			cache[id * 2 + 1] = c2
		end
		return c1, c2
	end
	a00, b00 = node(base, m, n)
	a10, b10 = node(base + 1, m + 1, n)
	a01, b01 = node(base + NODES, m, n + 1)
	a11, b11 = node(base + NODES + 1, m + 1, n + 1)
	local p0 = a00 + (a10 - a00) * fx
	local p1 = a01 + (a11 - a01) * fx
	local q0 = b00 + (b10 - b00) * fx
	local q1 = b01 + (b11 - b01) * fx
	return p0 + (p1 - p0) * fy, q0 + (q1 - q0) * fy
end

----------------------------------------------------------------------------------------
-- registry
----------------------------------------------------------------------------------------

local function fields(seed: number, n: number): { Noise3.Field }
	local out = {}
	for k = 1, n do
		out[k] = Noise3.new(seed * 97 + k * 7919)
	end
	return out
end

local terra: Body = {
	id = "terra",
	name = "Terra",
	kind = "rocky",
	radius = 1600,
	px = 0,
	py = 0,
	pz = 0,
	seed = 11,
	maxHeight = 90,
	sea = true,
	fields = fields(11, 6),
	atmosphere = { r = 0.36, g = 0.62, b = 1.0, thickness = 0.065, strength = 1.0 },
	rings = nil,
	coarse = terraCoarse,
	height = terraHeight,
	land = terraLand,
	water = terraWater,
	albedo = nil,
}

local selene: Body = {
	id = "selene",
	name = "Selene",
	kind = "rocky",
	radius = 430,
	px = -5200,
	py = 1400,
	pz = 7400,
	seed = 23,
	maxHeight = 40,
	sea = false,
	fields = fields(23, 3),
	atmosphere = nil,
	rings = nil,
	coarse = seleneCoarse,
	height = seleneHeight,
	land = seleneLand,
	water = noWater,
	albedo = nil,
}

local saturnia: Body = {
	id = "saturnia",
	name = "Saturnia",
	kind = "gas",
	radius = 2400,
	px = 21000,
	py = -2500,
	pz = -30000,
	seed = 37,
	maxHeight = 0,
	sea = false,
	fields = fields(37, 1),
	atmosphere = { r = 0.95, g = 0.85, b = 0.65, thickness = 0.025, strength = 0.6 },
	rings = buildRings(37),
	coarse = gasCoarse,
	height = gasHeight,
	land = gasLand,
	water = noWater,
	albedo = saturniaAlbedo,
}

Bodies.list = { terra, selene, saturnia }
Bodies.byId = { terra = terra, selene = selene, saturnia = saturnia } :: { [string]: Body }

function Bodies.get(id: string): Body
	local b = Bodies.byId[id]
	assert(b, "unknown body " .. tostring(id))
	return b
end

Bodies.terraElevation = terraElevation
Bodies.terraCoarse = terraCoarse

return Bodies
