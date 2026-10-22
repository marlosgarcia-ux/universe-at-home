--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: TileGen
--
-- Generates one patch of a rocky body: its colour, tangent-space normal and roughness
-- tiles for the atlases, and its mesh (grid, skirts, bounding-box pins). Pure Luau on
-- buffers and numbers, so it runs in a desynchronized Actor, in the serial fallback, and
-- in the CLI tests alike. Layout.luau defines every size and the texel-centre rule.
--
-- PER TEXEL
--   position   unit point p of the texel centre (Layout: texel centres on patch edges)
--   height     h = body.height(p, texel pitch): octaves finer than the texel are left out
--   normal     central differences of the surface P = p (R + h) over neighbouring texels
--              (the generator samples one ring beyond the tile for this), sea clamped
--              flat; encoded in the tangent frame T = dp/ds, B = N x T, N = p (the mesh's
--              vertex normals are the sphere normal p, so the map carries all relief)
--   coastline  the height field near h = 0 is a signed distance after division by its
--              gradient: d = -h / |grad h| in texels, and the land share of the texel is
--              the exact area MyMath.coverageHalfPlane(d, n). Coasts stay crisp and
--              anti-aliased at every level of detail instead of blurring or stair-stepping.
--   colour     land and water albedo mixed by that share; roughness likewise
--
-- NORMAL MAP CONVENTION. Red follows +s (image right). Green follows the image's up
-- direction (decreasing t) by default, the OpenGL convention Roblox documents for normal
-- maps, read with Roblox's top-left UV origin. `greenUp = false` flips it; the client
-- exposes that as a key so a wrong guess can be corrected live.

local Layout = require("./Layout")
local CubeSphere = require("./CubeSphere")
local Bodies = require("./Bodies")
local MyMath = require("../Universe/MyMath")

local TileGen = {}

export type Spec = {
	body: string,
	face: number,
	level: number,
	i: number,
	j: number,
	greenUp: boolean?,
	tint: boolean?, -- debug: tint the colour by quadtree level
}

export type Result = {
	key: number,
	color: buffer,
	normal: buffer,
	rough: buffer,
	positions: buffer, -- Layout.VERTS x 3 f32, body-local studs
	normals: buffer, -- Layout.VERTS x 3 f32
	hmin: number,
	hmax: number,
	ms: number,
}

local sqrt = math.sqrt
local cubePoint, toSphere = CubeSphere.cubePoint, CubeSphere.toSphere
local coverageHalfPlane = MyMath.coverageHalfPlane

local function byte(v: number): number
	local q = (v * 255 + 0.5) // 1
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

local TINTS = {
	{ 1.0, 0.55, 0.55 },
	{ 1.0, 0.8, 0.5 },
	{ 1.0, 1.0, 0.5 },
	{ 0.6, 1.0, 0.5 },
	{ 0.5, 1.0, 0.9 },
	{ 0.5, 0.75, 1.0 },
	{ 0.75, 0.55, 1.0 },
	{ 1.0, 0.55, 0.9 },
}

-- Skirt depth (studs) for a level: deeper than any crack two neighbouring levels can open.
function TileGen.skirtDepth(radius: number, level: number): number
	return CubeSphere.patchAngle(level) * radius / Layout.GRID * 1.5 + 0.3
end

function TileGen.generate(spec: Spec): Result
	local t0 = os.clock()
	local B = Bodies.get(spec.body)
	local R = B.radius
	local sea = B.sea
	local f, L, pi, pj = spec.face, spec.level, spec.i, spec.j
	local greenUp = spec.greenUp ~= false
	local inv = math.ldexp(1, -L)
	local NS = Layout.SAMPLES
	local SPAN = Layout.SPAN
	local TILE = Layout.TILE
	local spacing = CubeSphere.patchAngle(L) / SPAN
	local heightFn, landFn, waterFn = B.height, B.land, B.water

	-- 1a. unit points on the (TILE + 2)^2 sample grid
	local count = NS * NS
	local X = table.create(count, 0)
	local Y = table.create(count, 0)
	local Z = table.create(count, 0)
	local idx = 1
	for q2 = 0, NS - 1 do
		local b = (pj + (q2 - 2) / SPAN) * inv
		for q1 = 0, NS - 1 do
			local a = (pi + (q1 - 2) / SPAN) * inv
			X[idx], Y[idx], Z[idx] = toSphere(cubePoint(f, a, b))
			idx += 1
		end
	end

	-- 1b. low-frequency fields from the body's coarse lattice (Bodies.coarseAt), with a
	-- node cache shared by every sample and vertex of this tile
	local cache: { [number]: number } = {}
	local coarseAt = Bodies.coarseAt
	local C1 = table.create(count, 0)
	local C2 = table.create(count, 0)
	for k = 1, count do
		C1[k], C2[k] = coarseAt(B, X[k], Y[k], Z[k], cache)
	end

	-- 1c. heights and surface radii
	local H = table.create(count, 0)
	local RR = table.create(count, 0)
	for k = 1, count do
		local h = heightFn(B, X[k], Y[k], Z[k], spacing, C1[k])
		H[k] = h
		RR[k] = R + (if sea and h < 0 then 0 else h)
	end

	-- 2. texels
	local color = buffer.create(TILE * TILE * 4)
	local normal = buffer.create(TILE * TILE * 4)
	local roughFull = table.create(TILE * TILE, 0)
	local tint = if spec.tint then TINTS[(L % #TINTS) + 1] else nil
	for r = 0, TILE - 1 do
		for k = 0, TILE - 1 do
			local i0 = (r + 1) * NS + (k + 1) + 1
			local iL, iR, iU, iD = i0 - 1, i0 + 1, i0 - NS, i0 + NS
			local nx0, ny0, nz0 = X[i0], Y[i0], Z[i0]
			-- surface tangents by central differences (scale irrelevant to the normal)
			local rL, rR, rU, rD = RR[iL], RR[iR], RR[iU], RR[iD]
			local sx = X[iR] * rR - X[iL] * rL
			local sy = Y[iR] * rR - Y[iL] * rL
			local sz = Z[iR] * rR - Z[iL] * rL
			local tx = X[iD] * rD - X[iU] * rU
			local ty = Y[iD] * rD - Y[iU] * rU
			local tz = Z[iD] * rD - Z[iU] * rU
			-- n = ds x dt (outward: U x V = N on every face)
			local nx = sy * tz - sz * ty
			local ny = sz * tx - sx * tz
			local nz = sx * ty - sy * tx
			local nl = sqrt(nx * nx + ny * ny + nz * nz)
			nx, ny, nz = nx / nl, ny / nl, nz / nl
			-- sphere tangent frame
			local ux = X[iR] - X[iL]
			local uy = Y[iR] - Y[iL]
			local uz = Z[iR] - Z[iL]
			local d = ux * nx0 + uy * ny0 + uz * nz0
			ux, uy, uz = ux - d * nx0, uy - d * ny0, uz - d * nz0
			local ul = sqrt(ux * ux + uy * uy + uz * uz)
			ux, uy, uz = ux / ul, uy / ul, uz / ul
			-- B = N x T points along +t (down the image)
			local bx = ny0 * uz - nz0 * uy
			local by = nz0 * ux - nx0 * uz
			local bz = nx0 * uy - ny0 * ux

			local h = H[i0]
			-- land share of the texel (exact area against the coast's tangent line)
			local cov = 1
			if sea then
				local gx = (H[iR] - H[iL]) * 0.5
				local gy = (H[iD] - H[iU]) * 0.5
				local g = sqrt(gx * gx + gy * gy)
				if g > 1e-12 then
					cov = coverageHalfPlane(-h / g, gx / g, gy / g)
				else
					cov = if h > 0 then 1 elseif h < 0 then 0 else 0.5
				end
			end
			local slopeCos = nx * nx0 + ny * ny0 + nz * nz0
			local cr, cg, cb, rough = 0, 0, 0, 0
			if cov > 0 then
				local lr, lg, lb, lrough = landFn(B, nx0, ny0, nz0, if h > 0 then h else 0, slopeCos, spacing, C2[i0])
				cr, cg, cb, rough = lr * cov, lg * cov, lb * cov, lrough * cov
			end
			if cov < 1 then
				local wr, wg, wb, wrough = waterFn(B, if h < 0 then -h else 0)
				local w = 1 - cov
				cr += wr * w
				cg += wg * w
				cb += wb * w
				rough += wrough * w
			end
			-- water is flat: its share pulls the normal back towards the sphere normal
			if cov < 1 then
				local w = 1 - cov
				nx, ny, nz = nx * cov + nx0 * w, ny * cov + ny0 * w, nz * cov + nz0 * w
				local l2 = sqrt(nx * nx + ny * ny + nz * nz)
				nx, ny, nz = nx / l2, ny / l2, nz / l2
			end
			if tint then
				cr, cg, cb = cr * tint[1], cg * tint[2], cb * tint[3]
			end
			local o = (r * TILE + k) * 4
			buffer.writeu32(color, o, byte(cr) + byte(cg) * 256 + byte(cb) * 65536 + 4278190080)
			local tn = nx * ux + ny * uy + nz * uz
			local bn = nx * bx + ny * by + nz * bz
			local nn = nx * nx0 + ny * ny0 + nz * nz0
			if greenUp then
				bn = -bn
			end
			buffer.writeu32(normal, o, byte(tn * 0.5 + 0.5) + byte(bn * 0.5 + 0.5) * 256 + byte(nn * 0.5 + 0.5) * 65536 + 4278190080)
			roughFull[r * TILE + k + 1] = rough
		end
	end

	-- 3. roughness at half resolution: the 2 x 2 box mean (same UVs, see Layout)
	local RT = Layout.ROUGH_TILE
	local rough = buffer.create(RT * RT * 4)
	for r = 0, RT - 1 do
		for k = 0, RT - 1 do
			local a = (2 * r) * TILE + 2 * k + 1
			local v = (roughFull[a] + roughFull[a + 1] + roughFull[a + TILE] + roughFull[a + TILE + 1]) * 0.25
			local g = byte(v)
			buffer.writeu32(rough, (r * RT + k) * 4, g + g * 256 + g * 65536 + 4278190080)
		end
	end

	-- 4. mesh: grid at the vertex pitch, skirts, pins
	local G = Layout.GRID
	local vSpacing = CubeSphere.patchAngle(L) / G
	local positions = buffer.create(Layout.VERTS * 12)
	local normals = buffer.create(Layout.VERTS * 12)
	local skirt = TileGen.skirtDepth(R, L)
	local hmin, hmax = math.huge, -math.huge
	local GX = table.create(Layout.GRID_VERTS, 0)
	local GY = table.create(Layout.GRID_VERTS, 0)
	local GZ = table.create(Layout.GRID_VERTS, 0)
	local GR = table.create(Layout.GRID_VERTS, 0)
	local v = 0
	for vj = 0, G do
		local b = (pj + vj / G) * inv
		for vi = 0, G do
			local a = (pi + vi / G) * inv
			local x, y, z = toSphere(cubePoint(f, a, b))
			local c1 = coarseAt(B, x, y, z, cache)
			local h = heightFn(B, x, y, z, vSpacing, c1)
			if sea and h < 0 then
				h = 0
			end
			if h < hmin then
				hmin = h
			end
			if h > hmax then
				hmax = h
			end
			local rad = R + h
			GX[v + 1], GY[v + 1], GZ[v + 1], GR[v + 1] = x, y, z, rad
			buffer.writef32(positions, v * 12, x * rad)
			buffer.writef32(positions, v * 12 + 4, y * rad)
			buffer.writef32(positions, v * 12 + 8, z * rad)
			buffer.writef32(normals, v * 12, x)
			buffer.writef32(normals, v * 12 + 4, y)
			buffer.writef32(normals, v * 12 + 8, z)
			v += 1
		end
	end
	-- skirts: bottom (t = 0), right (s = 1), top (t = 1), left (s = 0); each runs along
	-- increasing s or t, the order MeshPool's skirt triangles expect
	local function skirtVertex(gv: number)
		local x, y, z, rad = GX[gv + 1], GY[gv + 1], GZ[gv + 1], GR[gv + 1] - skirt
		buffer.writef32(positions, v * 12, x * rad)
		buffer.writef32(positions, v * 12 + 4, y * rad)
		buffer.writef32(positions, v * 12 + 8, z * rad)
		buffer.writef32(normals, v * 12, x)
		buffer.writef32(normals, v * 12 + 4, y)
		buffer.writef32(normals, v * 12 + 8, z)
		v += 1
	end
	for vi = 0, G do
		skirtVertex(Layout.gridVertex(vi, 0))
	end
	for vj = 0, G do
		skirtVertex(Layout.gridVertex(G, vj))
	end
	for vi = 0, G do
		skirtVertex(Layout.gridVertex(vi, G))
	end
	for vj = 0, G do
		skirtVertex(Layout.gridVertex(0, vj))
	end
	-- pins: two tiny triangles (0.01 studs, far below a pixel at 1900 studs) at opposite
	-- corners of the shared bounding box. Not zero-area, in case the engine drops
	-- degenerate faces from the bounds.
	local P = Layout.PIN_EXTENT
	local pins = { P, P, P, P - 0.01, P, P, P, P - 0.01, P, -P, -P, -P, -P + 0.01, -P, -P, -P, -P + 0.01, -P }
	for p = 0, 5 do
		buffer.writef32(positions, v * 12, pins[p * 3 + 1])
		buffer.writef32(positions, v * 12 + 4, pins[p * 3 + 2])
		buffer.writef32(positions, v * 12 + 8, pins[p * 3 + 3])
		buffer.writef32(normals, v * 12, 0)
		buffer.writef32(normals, v * 12 + 4, 1)
		buffer.writef32(normals, v * 12 + 8, 0)
		v += 1
	end
	assert(v == Layout.VERTS, "vertex count")

	return {
		key = CubeSphere.key(f, L, pi, pj),
		color = color,
		normal = normal,
		rough = rough,
		positions = positions,
		normals = normals,
		hmin = hmin,
		hmax = hmax,
		ms = (os.clock() - t0) * 1000,
	}
end

-- Triangles of the patch mesh as 0-based vertex index triples, counter-clockwise seen from
-- outside (front faces): grid quads, then skirts (facing away from the patch), then pins.
-- The same for every patch, so a mesh slot builds it once.
function TileGen.triangles(): { number }
	local G = Layout.GRID
	local tris = table.create(Layout.TRIS * 3, 0)
	local n = 0
	local function tri(a: number, b: number, c: number)
		tris[n + 1], tris[n + 2], tris[n + 3] = a, b, c
		n += 3
	end
	for vj = 0, G - 1 do
		for vi = 0, G - 1 do
			local a = Layout.gridVertex(vi, vj)
			local b = Layout.gridVertex(vi + 1, vj)
			local c = Layout.gridVertex(vi + 1, vj + 1)
			local d = Layout.gridVertex(vi, vj + 1)
			tri(a, b, c)
			tri(a, c, d)
		end
	end
	local base = Layout.GRID_VERTS
	local edgeLen = G + 1
	-- edge e: grid vertices E(m) and skirt vertices S(m), m = 0..G along increasing s or t
	local function edgeVertex(e: number, m: number): number
		if e == 0 then
			return Layout.gridVertex(m, 0)
		elseif e == 1 then
			return Layout.gridVertex(G, m)
		elseif e == 2 then
			return Layout.gridVertex(m, G)
		end
		return Layout.gridVertex(0, m)
	end
	for e = 0, 3 do
		local sk = base + e * edgeLen
		for m = 0, G - 1 do
			local E0, E1 = edgeVertex(e, m), edgeVertex(e, m + 1)
			local S0, S1 = sk + m, sk + m + 1
			if e == 0 or e == 1 then
				-- bottom faces -t, right faces +s
				tri(E0, S0, S1)
				tri(E0, S1, E1)
			else
				-- top faces +t, left faces -s
				tri(E0, S1, S0)
				tri(E0, E1, S1)
			end
		end
	end
	local pin = base + 4 * edgeLen
	tri(pin, pin + 1, pin + 2)
	tri(pin + 3, pin + 4, pin + 5)
	assert(n == Layout.TRIS * 3, "triangle count")
	return tris
end

-- UV of every vertex (0-based index -> u, v) for a slot whose tile is (tx, ty).
function TileGen.uvs(tx: number, ty: number): { number }
	local G = Layout.GRID
	local out = table.create(Layout.VERTS * 2, 0)
	local n = 0
	local function put(s: number, t: number)
		local u, v = Layout.uv(tx, ty, s, t)
		out[n + 1], out[n + 2] = u, v
		n += 2
	end
	for vj = 0, G do
		for vi = 0, G do
			put(vi / G, vj / G)
		end
	end
	for vi = 0, G do
		put(vi / G, 0)
	end
	for vj = 0, G do
		put(1, vj / G)
	end
	for vi = 0, G do
		put(vi / G, 1)
	end
	for vj = 0, G do
		put(0, vj / G)
	end
	for _ = 1, Layout.PIN_VERTS do
		put(0.5, 0.5)
	end
	return out
end

return TileGen
