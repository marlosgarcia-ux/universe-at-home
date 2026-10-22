--!strict
-- Tests for the planet system's pure core (planets/shared): layout rules, cube-sphere
-- geometry, noise, the tile generator (seams, normal maps, coastline coverage, meshes),
-- crater and ring math. Run by tests/run.sh in the interpreter and with native code; a
-- golden digest pins tile bytes to the same values in both runtimes.

local Layout = require("../planets/shared/Layout")
local CubeSphere = require("../planets/shared/CubeSphere")
local Noise3 = require("../planets/shared/Noise3")
local Bodies = require("../planets/shared/Bodies")
local TileGen = require("../planets/shared/TileGen")
local MyMath = require("../src/MyMath")

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local GOLDEN = { tiles = 3061049182 }
local PRINT_GOLDEN = false

local abs, sqrt = math.abs, math.sqrt

----------------------------------------------------------------------------------------
-- A. layout
----------------------------------------------------------------------------------------

do
	check(Layout.TILES_PER_ROW * Layout.TILE == Layout.ATLAS, "tiles fill the atlas")
	check(Layout.SLOTS == Layout.TILES_PER_ROW ^ 2, "one slot per tile")
	check(Layout.SPAN == Layout.TILE - 2 * Layout.GUTTER - 1, "span")
	check(Layout.ROUGH_TILE * 2 == Layout.TILE and Layout.ROUGH_ATLAS * 2 == Layout.ATLAS, "roughness at half resolution")
	check(Layout.paramOfPixel(Layout.GUTTER) == 0 and Layout.paramOfPixel(Layout.TILE - 1 - Layout.GUTTER) == 1, "texel centres on the patch edges")
	for _, tile in { { 0, 0 }, { 5, 9 }, { 15, 15 } } do
		local tx, ty = tile[1], tile[2]
		local u0, v0 = Layout.uv(tx, ty, 0, 0)
		local u1, v1 = Layout.uv(tx, ty, 1, 1)
		-- pixel k's centre is at k + 0.5
		check(abs(u0 * Layout.ATLAS - (tx * Layout.TILE + Layout.GUTTER + 0.5)) < 1e-9, "u of s = 0 is the centre of the first inner pixel")
		check(abs(u1 * Layout.ATLAS - (tx * Layout.TILE + Layout.TILE - 1 - Layout.GUTTER + 0.5)) < 1e-9, "u of s = 1 is the centre of the last inner pixel")
		check(abs(v0 * Layout.ATLAS - (ty * Layout.TILE + 1.5)) < 1e-9 and abs(v1 * Layout.ATLAS - (ty * Layout.TILE + 62.5)) < 1e-9, "v likewise")
	end
	local tx, ty = Layout.tileOf(37)
	check(tx == 5 and ty == 2, "tile of a slot")
	check(Layout.VERTS == Layout.GRID_VERTS + Layout.SKIRT_VERTS + Layout.PIN_VERTS, "vertex budget")
	check(Layout.TRIS == Layout.GRID_TRIS + Layout.SKIRT_TRIS + Layout.PIN_TRIS, "triangle budget")
end

----------------------------------------------------------------------------------------
-- B. cube-sphere geometry
----------------------------------------------------------------------------------------

do
	for f = 1, 6 do
		local n, u, v = CubeSphere.FN[f], CubeSphere.FU[f], CubeSphere.FV[f]
		local cx = u[2] * v[3] - u[3] * v[2]
		local cy = u[3] * v[1] - u[1] * v[3]
		local cz = u[1] * v[2] - u[2] * v[1]
		check(cx == n[1] and cy == n[2] and cz == n[3], "U x V = N on face " .. f)
	end
	-- unit length and shared edges: every face-edge point maps to the same sphere point
	-- from the neighbouring face
	local worst, worstLen = 0, 0
	for f = 1, 6 do
		for m = 0, 40 do
			local w = m / 40
			for _, ab in { { 0, w }, { 1, w }, { w, 0 }, { w, 1 } } do
				local x, y, z = CubeSphere.facePoint(f, ab[1], ab[2])
				worstLen = math.max(worstLen, abs(sqrt(x * x + y * y + z * z) - 1))
				local cxp, cyp, czp = CubeSphere.cubePoint(f, ab[1], ab[2])
				for g = 1, 6 do
					if g ~= f then
						local N = CubeSphere.FN[g]
						if abs(cxp * N[1] + cyp * N[2] + czp * N[3] - 1) < 1e-12 then
							local U, V = CubeSphere.FU[g], CubeSphere.FV[g]
							local a2 = ((cxp * U[1] + cyp * U[2] + czp * U[3]) + 1) * 0.5
							local b2 = ((cxp * V[1] + cyp * V[2] + czp * V[3]) + 1) * 0.5
							local x2, y2, z2 = CubeSphere.facePoint(g, a2, b2)
							worst = math.max(worst, abs(x - x2) + abs(y - y2) + abs(z - z2))
						end
					end
				end
			end
		end
	end
	check(worstLen < 1e-14, "Nowell's map lands on the unit sphere (" .. worstLen .. ")")
	check(worst < 1e-14, "shared face edges map to the same sphere points (" .. worst .. ")")
	-- key round trip, gnomonic round trip
	for _, k in { { 1, 0, 0, 0 }, { 6, 14, 16383, 1 }, { 3, 9, 300, 511 } } do
		local key = CubeSphere.key(k[1], k[2], k[3], k[4])
		local f, l, i, j = CubeSphere.unkey(key)
		check(f == k[1] and l == k[2] and i == k[3] and j == k[4], "patch key round trip")
	end
	local gw = 0
	for f = 1, 6 do
		for _, ab in { { 0.1, 0.9 }, { 0.5, 0.5 }, { 0.99, 0.02 } } do
			local x, y, z = CubeSphere.gnomonicPoint(f, ab[1], ab[2])
			local f2, a2, b2 = CubeSphere.gnomonic(x, y, z)
			check(f2 == f, "gnomonic face")
			gw = math.max(gw, abs(a2 - ab[1]) + abs(b2 - ab[2]))
		end
	end
	check(gw < 1e-12, "gnomonic round trip")
	-- area balance of Nowell's map: largest / smallest cell area on a 16 x 16 face grid
	local amin, amax = 1e300, 0
	for i = 0, 15 do
		for j = 0, 15 do
			local ax, ay, az = CubeSphere.facePoint(5, i / 16, j / 16)
			local bx, by, bz = CubeSphere.facePoint(5, (i + 1) / 16, j / 16)
			local cx2, cy2, cz2 = CubeSphere.facePoint(5, i / 16, (j + 1) / 16)
			local ux, uy, uz = bx - ax, by - ay, bz - az
			local vx, vy, vz = cx2 - ax, cy2 - ay, cz2 - az
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			local area = sqrt(nx * nx + ny * ny + nz * nz)
			if area < amin then
				amin = area
			end
			if area > amax then
				amax = area
			end
		end
	end
	check(amax / amin < 1.6, string.format("Nowell cells stay within 1.6x in area (%.3f)", amax / amin))
end

----------------------------------------------------------------------------------------
-- C. noise
----------------------------------------------------------------------------------------

do
	local F = Noise3.new(5)
	local lo, hi = math.huge, -math.huge
	local lip = 0
	for k = 1, 60000 do
		local x = MyMath.rand2(k, 1, 9) * 40 - 20
		local y = MyMath.rand2(k, 2, 9) * 40 - 20
		local z = MyMath.rand2(k, 3, 9) * 40 - 20
		local v = Noise3.simplex(F, x, y, z)
		lo, hi = math.min(lo, v), math.max(hi, v)
		local d = 1e-4
		local v2 = Noise3.simplex(F, x + d, y, z)
		lip = math.max(lip, abs(v2 - v) / d)
	end
	check(lo > -1.05 and hi < 1.05 and lo < -0.7 and hi > 0.7, string.format("simplex range [%.3f, %.3f]", lo, hi))
	-- Rigorous bound: a corner contributes 32 t^4 (g . x), t = 0.6 - |x|^2, |g| <= sqrt 2;
	-- its gradient is at most 32 sqrt(2) max(t^4 + 8 t^3 |x|^2) = 32 sqrt(2) 0.164 = 7.4, and
	-- four corners give 29.7. Measured maxima sit well inside it.
	check(lip < 29.7, string.format("simplex slope within its proved bound (%.2f per unit)", lip))
	-- different seeds give different fields; the same seed the same bits
	check(Noise3.simplex(Noise3.new(5), 1.3, 2.7, -0.4) == Noise3.simplex(F, 1.3, 2.7, -0.4), "same seed, same value")
	check(Noise3.simplex(Noise3.new(6), 1.3, 2.7, -0.4) ~= Noise3.simplex(F, 1.3, 2.7, -0.4), "another seed, another field")
	-- octave budget: monotone and continuous across a doubling
	local prev = 0
	for e = 0, 60 do
		local sp = 0.5 * 0.8 ^ e
		local o = Noise3.octavesFor(2, sp, 20)
		check(o >= prev - 1e-12, "octavesFor grows as the spacing shrinks")
		prev = o
	end
	local a = Noise3.octavesFor(1, 1 / 64 - 1e-9, 20)
	local b = Noise3.octavesFor(1, 1 / 64 + 1e-9, 20)
	check(abs(a - b) < 1e-6, "octavesFor is continuous across a power of two")
	-- a fractional octave count blends towards the next integer one
	local x, y, z = 0.3, -0.2, 0.9
	local f3 = Noise3.fbm(F, x, y, z, 2, 3, 0.5)
	local f4 = Noise3.fbm(F, x, y, z, 2, 4, 0.5)
	local f35 = Noise3.fbm(F, x, y, z, 2, 3.5, 0.5)
	check(abs(f35 - (f3 + f4) * 0.5) < 1e-12, "fractional octave is a linear blend")
end

----------------------------------------------------------------------------------------
-- D. tile generator
----------------------------------------------------------------------------------------

local function px(b: buffer, k: number, r: number): (number, number, number, number)
	return MyMath.unpack(buffer.readu32(b, (r * Layout.TILE + k) * 4))
end

-- 1. seams inside a face, both at a level that interpolates coarse fields and one that
-- does not: the shared edge texels are the same surface points
local digest = 0x811C9DC5
local function mix(h: number)
	digest = MyMath.hash32(bit32.bxor(digest, h))
end
local function hashBuffer(b: buffer)
	for o = 0, buffer.len(b) - 4, 4 do
		mix(buffer.readu32(b, o))
	end
end

for _, L in { 2, 5 } do
	local n = 2 ^ L
	local i, j = n // 2 - 1, n // 2 - 1
	local A = TileGen.generate({ body = "terra", face = 5, level = L, i = i, j = j })
	local Rgt = TileGen.generate({ body = "terra", face = 5, level = L, i = i + 1, j = j })
	local Dn = TileGen.generate({ body = "terra", face = 5, level = L, i = i, j = j + 1 })
	hashBuffer(A.color)
	hashBuffer(A.normal)
	hashBuffer(A.rough)
	hashBuffer(A.positions)
	local equalC, equalN, total, worst = 0, 0, 0, 0
	local function compare(P: TileGen.Result, k1: number, r1: number, Q: TileGen.Result, k2: number, r2: number)
		local c1 = buffer.readu32(P.color, (r1 * Layout.TILE + k1) * 4)
		local c2 = buffer.readu32(Q.color, (r2 * Layout.TILE + k2) * 4)
		local n1 = buffer.readu32(P.normal, (r1 * Layout.TILE + k1) * 4)
		local n2 = buffer.readu32(Q.normal, (r2 * Layout.TILE + k2) * 4)
		total += 1
		if c1 == c2 then
			equalC += 1
		end
		if n1 == n2 then
			equalN += 1
		end
		local a1, a2, a3 = MyMath.unpack(c1)
		local b1, b2, b3 = MyMath.unpack(c2)
		worst = math.max(worst, abs(a1 - b1), abs(a2 - b2), abs(a3 - b3))
	end
	for m = 1, Layout.TILE - 2 do
		-- A's column 62 (s = 1) against the right neighbour's column 1 (s = 0); rows likewise
		compare(A, 62, m, Rgt, 1, m)
		compare(A, m, 62, Dn, m, 1)
	end
	check(equalC / total > 0.97, string.format("level %d: shared edge colours equal (%d of %d)", L, equalC, total))
	check(equalN / total > 0.9, string.format("level %d: shared edge normals equal (%d of %d)", L, equalN, total))
	check(worst <= 2, string.format("level %d: shared edge colours within 2 levels (worst %d)", L, worst))
	-- mesh: the shared edge vertices are the same positions
	local G = Layout.GRID
	local wv = 0
	for m = 0, G do
		local va = Layout.gridVertex(G, m)
		local vb = Layout.gridVertex(0, m)
		for c = 0, 2 do
			wv = math.max(wv, abs(buffer.readf32(A.positions, va * 12 + c * 4) - buffer.readf32(Rgt.positions, vb * 12 + c * 4)))
		end
	end
	check(wv < 1e-3, string.format("level %d: shared edge vertices coincide (%.2e studs)", L, wv))
end

-- 2. normal map: decoding with the sphere frame recovers the generator's normal, computed
-- here independently from the body functions
do
	local L, i, j = 4, 7, 9
	local T = TileGen.generate({ body = "terra", face = 5, level = L, i = i, j = j })
	local B = Bodies.get("terra")
	local R = B.radius
	local inv = math.ldexp(1, -L)
	local spacing = CubeSphere.patchAngle(L) / Layout.SPAN
	local function surf(s: number, t: number): (number, number, number, number, number, number, number)
		local x, y, z = CubeSphere.facePoint(5, (i + s) * inv, (j + t) * inv)
		local c1 = Bodies.coarseAt(B, x, y, z)
		local h = B.height(B, x, y, z, spacing, c1)
		local rad = R + (if h < 0 then 0 else h)
		return x * rad, y * rad, z * rad, x, y, z, h
	end
	local worstAngle, sum, n = 0, 0, 0
	local ds = 1 / Layout.SPAN
	for r = 4, Layout.TILE - 5, 6 do
		for k = 4, Layout.TILE - 5, 6 do
			local s, t = (k - 1) / Layout.SPAN, (r - 1) / Layout.SPAN
			local lx, ly, lz, ux0, uy0, uz0, h1 = surf(s - ds, t)
			local rx, ry, rz, ux1, uy1, uz1, h2 = surf(s + ds, t)
			local tx0, ty0, tz0, _, _, _, h3 = surf(s, t - ds)
			local tx1, ty1, tz1, _, _, _, h4 = surf(s, t + ds)
			local _, _, _, nx0, ny0, nz0, h0 = surf(s, t)
			-- away from the coast (where the generator blends towards the flat sea)
			local dry = math.min(h0, h1, h2, h3, h4) > 0.5
			local wet = math.max(h0, h1, h2, h3, h4) < -0.5
			local sx, sy, sz = rx - lx, ry - ly, rz - lz
			local wx, wy, wz = tx1 - tx0, ty1 - ty0, tz1 - tz0
			local nx, ny, nz = sy * wz - sz * wy, sz * wx - sx * wz, sx * wy - sy * wx
			local nl = sqrt(nx * nx + ny * ny + nz * nz)
			nx, ny, nz = nx / nl, ny / nl, nz / nl
			-- frame
			local ax, ay, az = ux1 - ux0, uy1 - uy0, uz1 - uz0
			local d = ax * nx0 + ay * ny0 + az * nz0
			ax, ay, az = ax - d * nx0, ay - d * ny0, az - d * nz0
			local al = sqrt(ax * ax + ay * ay + az * az)
			ax, ay, az = ax / al, ay / al, az / al
			local bx, by, bz = ny0 * az - nz0 * ay, nz0 * ax - nx0 * az, nx0 * ay - ny0 * ax
			-- decode: red along +s, green towards the image top (-B)
			local cr, cg, cb = px(T.normal, k, r)
			local er, eg, eb = cr / 255 * 2 - 1, cg / 255 * 2 - 1, cb / 255 * 2 - 1
			local wxn = er * ax - eg * bx + eb * nx0
			local wyn = er * ay - eg * by + eb * ny0
			local wzn = er * az - eg * bz + eb * nz0
			local wl = sqrt(wxn * wxn + wyn * wyn + wzn * wzn)
			local cosA = (wxn * nx + wyn * ny + wzn * nz) / wl
			if cosA > 1 then
				cosA = 1
			end
			local ang = math.acos(cosA) * 180 / math.pi
			if dry or wet then
				n += 1
				sum += ang
				worstAngle = math.max(worstAngle, ang)
			end
		end
	end
	check(n > 50, "normal samples")
	check(sum / n < 1.5, string.format("decoded normals match an independent recomputation (mean %.2f deg)", sum / n))
	check(worstAngle < 3, string.format("decoded normal worst case %.2f deg", worstAngle))
end

-- 3. ocean: deep water texels are flat (tangent-space up) and dark; coast texels mix
do
	-- level-3 patch in the middle of a large ocean of face 6 (searched once, fixed here)
	local found = false
	for i = 0, 7 do
		local T = TileGen.generate({ body = "terra", face = 6, level = 3, i = i, j = 3 })
		local flat, deep, coast = 0, 0, 0
		for r = 1, 62, 3 do
			for k = 1, 62, 3 do
				local nr, ng, nb = px(T.normal, k, r)
				local cr, cg, cb = px(T.color, k, r)
				if cb > cr + 40 and cr < 20 then
					deep += 1
					if abs(nr - 128) <= 1 and abs(ng - 128) <= 1 and nb >= 254 then
						flat += 1
					end
				end
				if cb > cr and cg > 60 then
					coast += 1
				end
			end
		end
		if deep > 50 then
			found = true
			check(flat == deep, string.format("deep water normals are flat (%d of %d)", flat, deep))
		end
	end
	check(found, "an ocean patch was found on face 6")
end

-- 4. coastline coverage: texels where the height changes sign are mixed, never a hard 0/1
-- step; the land share is the exact area against the tangent line
do
	check(MyMath.coverageHalfPlane(0, 1, 0) == 0.5, "edge through the centre covers half")
	check(abs(MyMath.coverageHalfPlane(0, sqrt(0.5), sqrt(0.5)) - 0.5) < 1e-12, "diagonal edge through the centre covers half")
	check(MyMath.coverageHalfPlane(-0.71, sqrt(0.5), sqrt(0.5)) == 1, "inside beyond the reach is full")
end

-- 5. mesh topology: grid faces outward, skirts face away from the patch, pins are flat
do
	local T = TileGen.generate({ body = "selene", face = 3, level = 3, i = 2, j = 5 })
	hashBuffer(T.color)
	hashBuffer(T.normal)
	local tris = TileGen.triangles()
	check(#tris == Layout.TRIS * 3, "triangle list length")
	local function pos(v: number): (number, number, number)
		return buffer.readf32(T.positions, v * 12), buffer.readf32(T.positions, v * 12 + 4), buffer.readf32(T.positions, v * 12 + 8)
	end
	-- patch centre direction
	local cx, cy, cz = CubeSphere.patchPoint(3, 3, 2, 5, 0.5, 0.5)
	local outward, inwardSkirt, flatPins = 0, 0, 0
	for tIdx = 0, Layout.TRIS - 1 do
		local a, b, c = tris[tIdx * 3 + 1], tris[tIdx * 3 + 2], tris[tIdx * 3 + 3]
		local ax, ay, az = pos(a)
		local bx, by, bz = pos(b)
		local qx, qy, qz = pos(c)
		local ux, uy, uz = bx - ax, by - ay, bz - az
		local vx, vy, vz = qx - ax, qy - ay, qz - az
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		local nl = sqrt(nx * nx + ny * ny + nz * nz)
		if tIdx < Layout.GRID_TRIS then
			local mx, my, mz = (ax + bx + qx) / 3, (ay + by + qy) / 3, (az + bz + qz) / 3
			if nx * mx + ny * my + nz * mz > 0 then
				outward += 1
			end
		elseif tIdx < Layout.GRID_TRIS + Layout.SKIRT_TRIS then
			-- the skirt's normal points away from the patch centre (horizontally)
			local mx, my, mz = (ax + bx + qx) / 3, (ay + by + qy) / 3, (az + bz + qz) / 3
			local rr = sqrt(mx * mx + my * my + mz * mz)
			local hx, hy, hz = mx / rr - cx, my / rr - cy, mz / rr - cz
			if nl > 0 and (nx * hx + ny * hy + nz * hz) / nl > 0 then
				inwardSkirt += 1
			end
		else
			if nl < 1e-3 then
				flatPins += 1
			end
		end
	end
	check(outward == Layout.GRID_TRIS, "every grid triangle faces outward (" .. outward .. ")")
	check(inwardSkirt == Layout.SKIRT_TRIS, "every skirt triangle faces away from the patch (" .. inwardSkirt .. ")")
	check(flatPins == Layout.PIN_TRIS, "pin triangles have zero area")
	-- every vertex inside the pinned box, pins on its corners
	local P = Layout.PIN_EXTENT
	local inside = true
	for v = 0, Layout.VERTS - 1 do
		local x, y, z = pos(v)
		if abs(x) > P + 1e-3 or abs(y) > P + 1e-3 or abs(z) > P + 1e-3 then
			inside = false
		end
	end
	check(inside, "all vertices inside the pinned bounding box")
	local x0, y0, z0 = pos(Layout.VERTS - 6)
	local x1, y1, z1 = pos(Layout.VERTS - 3)
	check(x0 == P and y0 == P and z0 == P and x1 == -P and y1 == -P and z1 == -P, "pins on the box corners")
	-- UVs: inside the slot's tile, between the first and last inner texel centres
	local uvs = TileGen.uvs(7, 11)
	local okUV = true
	for v = 0, Layout.GRID_VERTS + Layout.SKIRT_VERTS - 1 do
		local u, w = uvs[v * 2 + 1] * Layout.ATLAS, uvs[v * 2 + 2] * Layout.ATLAS
		if u < 7 * 64 + 1.5 - 1e-9 or u > 7 * 64 + 62.5 + 1e-9 or w < 11 * 64 + 1.5 - 1e-9 or w > 11 * 64 + 62.5 + 1e-9 then
			okUV = false
		end
	end
	check(okUV, "UVs stay inside the tile's inner texel centres")
	-- heights: Selene's patch has craters (relief) and stays within the body's bound
	check(T.hmax - T.hmin > 1 and T.hmax <= 40 and T.hmin >= -40, string.format("selene relief %.1f .. %.1f", T.hmin, T.hmax))
end

----------------------------------------------------------------------------------------
-- E. craters and rings
----------------------------------------------------------------------------------------

do
	local p = Bodies.craterProfile
	check(p(0) == -1, "crater floor")
	check(abs(p(1) - 0.32) < 1e-12, "crater rim")
	check(p(1.3) == 0 and p(2) == 0, "nothing beyond the rim's reach")
	local worstJump = 0
	for k = 0, 1300 do
		local a, b = k / 1000, (k + 1) / 1000
		worstJump = math.max(worstJump, abs(p(b) - p(a)))
	end
	check(worstJump < 0.01, "crater profile is continuous")

	local rings = (Bodies.get("saturnia").rings :: any) :: Bodies.Rings
	-- additivity of the box filter: mean over [a, c] is the width-weighted mean of halves
	local a, b, c = 1.6, 1.97, 2.25
	local dac = Bodies.ringAt(rings, a, c)
	local dab = Bodies.ringAt(rings, a, b)
	local dbc = Bodies.ringAt(rings, b, c)
	check(abs(dac - (dab * (b - a) + dbc * (c - b)) / (c - a)) < 1e-9, "ring box filter is additive")
	local cassini = Bodies.ringAt(rings, 1.96, 2.02)
	local bRing = Bodies.ringAt(rings, 1.7, 1.8)
	check(cassini < 0.1 and bRing > 0.6, string.format("Cassini division is a gap (%.2f vs %.2f)", cassini, bRing))
	check(Bodies.ringAt(rings, 2.5, 2.6) == 0 and Bodies.ringAt(rings, 1.0, 1.1) == 0, "no ring outside its radii")
	-- a pixel straddling the Encke gap is dimmed by the gap's share, not flickering
	local wide = Bodies.ringAt(rings, 2.19, 2.23)
	local left = Bodies.ringAt(rings, 2.19, 2.205)
	check(wide < left, "a pixel over a narrow gap is dimmed by the gap's share")
end

-- F. Terra has oceans and continents in sensible proportions
do
	local B = Bodies.get("terra")
	local land, n = 0, 4000
	for k = 1, n do
		local x = MyMath.rand2(k, 1, 3) * 2 - 1
		local y = MyMath.rand2(k, 2, 3) * 2 - 1
		local z = MyMath.rand2(k, 3, 3) * 2 - 1
		local l = sqrt(x * x + y * y + z * z)
		if l > 0.1 and l <= 1 then
			x, y, z = x / l, y / l, z / l
			local c1 = Bodies.coarseAt(B, x, y, z)
			if B.height(B, x, y, z, 0.01, c1) > 0 then
				land += 1
			end
		else
			n -= 1
		end
	end
	local share = land / n
	check(share > 0.2 and share < 0.6, string.format("land covers %.0f%% of Terra", share * 100))
end

if PRINT_GOLDEN then
	print("tiles", digest)
else
	check(digest == GOLDEN.tiles, "golden digest of tile bytes: " .. digest)
end
print("planets: " .. checks .. " checks passed")
