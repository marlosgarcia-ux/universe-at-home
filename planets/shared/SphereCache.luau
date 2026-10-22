--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: SphereCache
--
-- A low-resolution cube map of a body's surface for the impostor renderer: albedo,
-- roughness, world-space normal and (for Terra) cloud coverage, per gnomonic texel. A
-- far body's raytraced billboard looks up this cache instead of evaluating dozens of
-- noise octaves per pixel (about 15 times cheaper).
--
-- Layout: per face (n + 2)^2 texels, 8 bytes each:
--   bytes 0..3  albedo r, g, b, roughness
--   bytes 4..7  normal x, y, z (byte = (v + 1) / 2 * 255), cloud coverage
-- Texel k (0..n+1) has its centre at gnomonic parameter (k - 0.5) / n; texels 0 and n+1
-- are a gutter beyond the face edge, so bilinear lookups never clamp at cube edges.
-- Faces are built independently (one job each) and joined with SphereCache.assemble.

local CubeSphere = require("./CubeSphere")
local Bodies = require("./Bodies")
local Clouds = require("./Clouds")
local MyMath = require("../Universe/MyMath")

local SphereCache = {}

SphereCache.N = 128

export type Cache = {
	body: string,
	n: number,
	faces: { buffer },
}

local sqrt = math.sqrt
local coverageHalfPlane = MyMath.coverageHalfPlane

local function byte(v: number): number
	local q = (v * 255 + 0.5) // 1
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

-- Builds face f (1..6) of body `id` at n texels per edge. Returns its buffer.
function SphereCache.buildFace(id: string, f: number, n: number): buffer
	local B = Bodies.get(id)
	local R = B.radius
	local W = n + 2 -- texels per row including the gutter
	local S = n + 4 -- height samples per row: one more ring for central differences
	local out = buffer.create(W * W * 8)
	local spacing = (math.pi / 2) / n
	local X = table.create(S * S, 0)
	local Y = table.create(S * S, 0)
	local Z = table.create(S * S, 0)
	local H = table.create(S * S, 0)
	local cache: { [number]: number } = {}
	local gas = B.kind == "gas"
	local idx = 1
	for q2 = 0, S - 1 do
		local b = (q2 - 1.5) / n
		for q1 = 0, S - 1 do
			local a = (q1 - 1.5) / n
			local x, y, z = CubeSphere.gnomonicPoint(f, a, b)
			X[idx], Y[idx], Z[idx] = x, y, z
			if not gas then
				local c1 = Bodies.coarseAt(B, x, y, z, cache)
				H[idx] = B.height(B, x, y, z, spacing, c1)
			end
			idx += 1
		end
	end
	local albedo = B.albedo
	local terra = id == "terra"
	local RR = table.create(S * S, R)
	if not gas then
		for i = 1, S * S do
			local h = H[i]
			RR[i] = R + (if B.sea and h < 0 then 0 else h)
		end
	end
	for r = 0, W - 1 do
		for k = 0, W - 1 do
			local i0 = (r + 1) * S + (k + 1) + 1
			local x, y, z = X[i0], Y[i0], Z[i0]
			local cr, cg, cb, rough = 0, 0, 0, 0.9
			local nx, ny, nz = x, y, z
			if gas and albedo then
				cr, cg, cb = albedo(B, x, y, z)
			else
				local iL, iR, iU, iD = i0 - 1, i0 + 1, i0 - S, i0 + S
				local rL, rR, rU, rD = RR[iL], RR[iR], RR[iU], RR[iD]
				local sx, sy, sz = X[iR] * rR - X[iL] * rL, Y[iR] * rR - Y[iL] * rL, Z[iR] * rR - Z[iL] * rL
				local tx, ty, tz = X[iD] * rD - X[iU] * rU, Y[iD] * rD - Y[iU] * rU, Z[iD] * rD - Z[iU] * rU
				-- gnomonic U x V = N as for the patches: s x t points outward
				nx, ny, nz = sy * tz - sz * ty, sz * tx - sx * tz, sx * ty - sy * tx
				local nl = sqrt(nx * nx + ny * ny + nz * nz)
				nx, ny, nz = nx / nl, ny / nl, nz / nl
				local h = H[i0]
				local cov = 1
				if B.sea then
					local gx = (H[iR] - H[iL]) * 0.5
					local gy = (H[iD] - H[iU]) * 0.5
					local g = sqrt(gx * gx + gy * gy)
					cov = if g > 1e-12 then coverageHalfPlane(-h / g, gx / g, gy / g) elseif h > 0 then 1 else 0
				end
				local slopeCos = nx * x + ny * y + nz * z
				local _, c2 = Bodies.coarseAt(B, x, y, z, cache)
				if cov > 0 then
					local lr, lg, lb, lrough = B.land(B, x, y, z, if h > 0 then h else 0, slopeCos, spacing, c2)
					cr, cg, cb, rough = lr * cov, lg * cov, lb * cov, lrough * cov
				else
					rough = 0
				end
				if cov < 1 then
					local wr, wg, wb, wrough = B.water(B, if h < 0 then -h else 0)
					local w = 1 - cov
					cr += wr * w
					cg += wg * w
					cb += wb * w
					rough += wrough * w
					nx, ny, nz = nx * cov + x * w, ny * cov + y * w, nz * cov + z * w
					local l2 = sqrt(nx * nx + ny * ny + nz * nz)
					nx, ny, nz = nx / l2, ny / l2, nz / l2
				end
			end
			local cloud = if terra then Clouds.density(x, y, z, spacing) else 0
			local o = (r * W + k) * 8
			buffer.writeu32(out, o, byte(cr) + byte(cg) * 256 + byte(cb) * 65536 + byte(rough) * 16777216)
			buffer.writeu32(out, o + 4, byte(nx * 0.5 + 0.5) + byte(ny * 0.5 + 0.5) * 256 + byte(nz * 0.5 + 0.5) * 65536 + byte(cloud) * 16777216)
		end
	end
	return out
end

function SphereCache.assemble(id: string, n: number, faces: { buffer }): Cache
	assert(#faces == 6, "six faces")
	return { body = id, n = n, faces = faces }
end

-- Builds all six faces inline (tests, previews, serial fallback).
function SphereCache.build(id: string, n: number?): Cache
	local size = n or SphereCache.N
	local faces = {}
	for f = 1, 6 do
		faces[f] = SphereCache.buildFace(id, f, size)
	end
	return SphereCache.assemble(id, size, faces)
end

-- Bilinear lookup at a unit direction: albedo r, g, b, roughness (0..1), normal x, y, z,
-- cloud coverage. The cloud channel can be sampled at another direction (rotating layer)
-- with SphereCache.cloud.
function SphereCache.sample(C: Cache, x: number, y: number, z: number): (number, number, number, number, number, number, number, number)
	local f, a, b = CubeSphere.gnomonic(x, y, z)
	local n = C.n
	local W = n + 2
	local u = a * n + 0.5
	local v = b * n + 0.5
	local k = u // 1
	local r = v // 1
	if k < 0 then
		k = 0
	elseif k > n then
		k = n
	end
	if r < 0 then
		r = 0
	elseif r > n then
		r = n
	end
	local fx, fy = u - k, v - r
	local buf = C.faces[f]
	local o00 = (r * W + k) * 8
	local o10 = o00 + 8
	local o01 = o00 + W * 8
	local o11 = o01 + 8
	local w00 = (1 - fx) * (1 - fy)
	local w10 = fx * (1 - fy)
	local w01 = (1 - fx) * fy
	local w11 = fx * fy
	-- channels by bytes, weighted (inlined: this runs per impostor pixel)
	local cr = (buffer.readu8(buf, o00) * w00 + buffer.readu8(buf, o10) * w10 + buffer.readu8(buf, o01) * w01 + buffer.readu8(buf, o11) * w11) / 255
	local cg = (buffer.readu8(buf, o00 + 1) * w00 + buffer.readu8(buf, o10 + 1) * w10 + buffer.readu8(buf, o01 + 1) * w01 + buffer.readu8(buf, o11 + 1) * w11) / 255
	local cb = (buffer.readu8(buf, o00 + 2) * w00 + buffer.readu8(buf, o10 + 2) * w10 + buffer.readu8(buf, o01 + 2) * w01 + buffer.readu8(buf, o11 + 2) * w11) / 255
	local rough = (buffer.readu8(buf, o00 + 3) * w00 + buffer.readu8(buf, o10 + 3) * w10 + buffer.readu8(buf, o01 + 3) * w01 + buffer.readu8(buf, o11 + 3) * w11) / 255
	local nx = (buffer.readu8(buf, o00 + 4) * w00 + buffer.readu8(buf, o10 + 4) * w10 + buffer.readu8(buf, o01 + 4) * w01 + buffer.readu8(buf, o11 + 4) * w11) / 255 * 2 - 1
	local ny = (buffer.readu8(buf, o00 + 5) * w00 + buffer.readu8(buf, o10 + 5) * w10 + buffer.readu8(buf, o01 + 5) * w01 + buffer.readu8(buf, o11 + 5) * w11) / 255 * 2 - 1
	local nz = (buffer.readu8(buf, o00 + 6) * w00 + buffer.readu8(buf, o10 + 6) * w10 + buffer.readu8(buf, o01 + 6) * w01 + buffer.readu8(buf, o11 + 6) * w11) / 255 * 2 - 1
	local cloud = (buffer.readu8(buf, o00 + 7) * w00 + buffer.readu8(buf, o10 + 7) * w10 + buffer.readu8(buf, o01 + 7) * w01 + buffer.readu8(buf, o11 + 7) * w11) / 255
	local l = sqrt(nx * nx + ny * ny + nz * nz)
	if l > 0 then
		nx, ny, nz = nx / l, ny / l, nz / l
	end
	return cr, cg, cb, rough, nx, ny, nz, cloud
end

-- Cloud coverage only (bilinear), for a layer rotated against the surface.
function SphereCache.cloud(C: Cache, x: number, y: number, z: number): number
	local f, a, b = CubeSphere.gnomonic(x, y, z)
	local n = C.n
	local W = n + 2
	local u = a * n + 0.5
	local v = b * n + 0.5
	local k = u // 1
	local r = v // 1
	if k < 0 then
		k = 0
	elseif k > n then
		k = n
	end
	if r < 0 then
		r = 0
	elseif r > n then
		r = n
	end
	local fx, fy = u - k, v - r
	local buf = C.faces[f]
	local o00 = (r * W + k) * 8 + 7
	local c00 = buffer.readu8(buf, o00)
	local c10 = buffer.readu8(buf, o00 + 8)
	local c01 = buffer.readu8(buf, o00 + W * 8)
	local c11 = buffer.readu8(buf, o00 + W * 8 + 8)
	local t0 = c00 + (c10 - c00) * fx
	local t1 = c01 + (c11 - c01) * fx
	return (t0 + (t1 - t0) * fy) / 255
end

return SphereCache
