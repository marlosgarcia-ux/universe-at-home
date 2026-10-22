--!strict
-- Tests for the planet renderers (planets/shared): the impostor raytracer's exact limb and
-- billboard bounds, the sphere cache, the cloud field's smoothness and the sky generator.
-- Run by tests/run.sh in the interpreter and with native code.

local Impostor = require("../planets/shared/Impostor")
local SphereCache = require("../planets/shared/SphereCache")
local Bodies = require("../planets/shared/Bodies")
local Clouds = require("../planets/shared/Clouds")
local SkyGen = require("../planets/shared/SkyGen")
local CubeSphere = require("../planets/shared/CubeSphere")
local MyMath = require("../src/MyMath")

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local sqrt, abs = math.sqrt, math.abs

local function normalize(x: number, y: number, z: number): (number, number, number)
	local l = sqrt(x * x + y * y + z * z)
	return x / l, y / l, z / l
end

-- A camera at body-local (cx, cy, cz) looking at the centre; billboard axes from it.
local function params(id: string, cx: number, cy: number, cz: number, n: number, extra: number): Impostor.Params
	local B = Bodies.get(id)
	local fx, fy, fz = normalize(-cx, -cy, -cz)
	local rx, ry, rz = normalize(-fz, 0, fx) -- forward x up(0, 1, 0)
	local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
	local D = sqrt(cx * cx + cy * cy + cz * cz)
	return {
		body = id,
		n = n,
		cx = cx,
		cy = cy,
		cz = cz,
		rx = rx,
		ry = ry,
		rz = rz,
		ux = ux,
		uy = uy,
		uz = uz,
		half = Impostor.halfSize(B.radius, extra, D, n),
		sx = 0.6,
		sy = 0.48,
		sz = 0.64,
		cloudAngle = 0,
	}
end

-- 1. the limb: alpha equals the exact share of each pixel inside the sphere's silhouette,
-- measured here by 16 x 16 supersampling of the same rays
do
	local B = Bodies.get("selene") -- no atmosphere, no rings: alpha is the disc alone
	local p = params("selene", 300, 400, 1100, 96, 1.02)
	local out = buffer.create(96 * 96 * 4)
	Impostor.render(out, p, nil, 0, 96)
	local R = B.radius
	local function inside(px: number, py: number): boolean
		local qx = (px / 96 * 2 - 1) * p.half
		local qy = (1 - py / 96 * 2) * p.half
		local dx = qx * p.rx + qy * p.ux - p.cx
		local dy = qx * p.ry + qy * p.uy - p.cy
		local dz = qx * p.rz + qy * p.uz - p.cz
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		dx, dy, dz = dx / l, dy / l, dz / l
		local b = p.cx * dx + p.cy * dy + p.cz * dz
		local c = p.cx * p.cx + p.cy * p.cy + p.cz * p.cz - R * R
		return b < 0 and b * b - c >= 0
	end
	local edge, sumErr, worst = 0, 0, 0
	for y = 0, 95 do
		for x = 0, 95 do
			local a = buffer.readu32(out, (y * 96 + x) * 4) // 16777216 / 255
			if a > 0 and a < 1 then
				local hits = 0
				for sy = 0, 15 do
					for sx = 0, 15 do
						if inside(x + (sx + 0.5) / 16, y + (sy + 0.5) / 16) then
							hits += 1
						end
					end
				end
				local ref = hits / 256
				local e = abs(a - ref)
				edge += 1
				sumErr += e
				if e > worst then
					worst = e
				end
			end
		end
	end
	check(edge > 100, "the limb has partially covered pixels (" .. edge .. ")")
	check(sumErr / edge < 0.012, string.format("limb alpha matches the exact pixel area (mean error %.4f)", sumErr / edge))
	check(worst < 0.06, string.format("limb alpha worst error %.3f", worst))
end

-- 2. the billboard contains the whole body (with its atmosphere) from any view: the image
-- border is transparent
do
	for _, v in { { "terra", 0, 0, 4000 }, { "terra", 2500, -900, 1900 }, { "selene", -600, 200, 500 }, { "terra", 30000, 0, 100 } } do
		local id = v[1] :: string
		local B = Bodies.get(id)
		local extra = 1 + (if B.atmosphere then (B.atmosphere :: Bodies.Atmosphere).thickness else 0) * 1.5
		local p = params(id, v[2] :: number, v[3] :: number, v[4] :: number, 64, extra)
		local out = buffer.create(64 * 64 * 4)
		Impostor.render(out, p, nil, 0, 64)
		local border = 0
		for k = 0, 63 do
			for _, o in { (0 * 64 + k), (63 * 64 + k), (k * 64 + 0), (k * 64 + 63) } do
				border = math.max(border, buffer.readu32(out, o * 4) // 16777216)
			end
		end
		check(border <= 2, string.format("%s: billboard border transparent from (%d, %d, %d) (alpha %d)", id, v[2] :: number, v[3] :: number, v[4] :: number, border))
	end
end

-- 3. sphere cache: texel centres return the stored bytes; neighbouring faces agree at
-- edges to within the reconstruction error (each face has its own texel grid, so the two
-- bilinear reconstructions meeting at a cube edge differ by less than one texel's change;
-- at 32 texels per face that was 8.7 % of full scale on Selene's craters, at the 128 the
-- client uses it is about a quarter of that)
do
	local C = SphereCache.build("selene", 128)
	local n = C.n
	local worstEdge = 0
	for f = 1, 6 do
		for k = 1, n, 29 do
			-- texel k's centre on this face
			local a, b = (k - 0.5) / n, (k - 0.5) / n
			local x, y, z = CubeSphere.gnomonicPoint(f, a, b)
			local r = select(1, SphereCache.sample(C, x, y, z))
			local stored = buffer.readu8(C.faces[f], ((k) * (n + 2) + k) * 8) / 255
			check(abs(r - stored) < 1e-9, "a texel centre returns its stored value")
		end
		-- just inside and just outside an edge of this face: the lookups agree
		for m = 1, 9 do
			local t = m / 10
			local x1, y1, z1 = CubeSphere.gnomonicPoint(f, 0.9995, t)
			local x2, y2, z2 = CubeSphere.gnomonicPoint(f, 1.0005, t)
			local r1 = select(1, SphereCache.sample(C, x1, y1, z1))
			local r2 = select(1, SphereCache.sample(C, x2, y2, z2))
			worstEdge = math.max(worstEdge, abs(r1 - r2))
		end
	end
	check(worstEdge < 0.04, string.format("cache steps across cube edges stay below 4%% (worst %.3f)", worstEdge))
end

-- 4. the cloud cache reconstructs the cloud field: no aliasing. With the original strong
-- domain warp the mean error at 64 texels per face was 0.131 (blocky banks); with the
-- bounded warp it measures 0.046 (median 0), and 0.022 at the client's 128.
do
	local C = SphereCache.build("terra", 64)
	local errs = {}
	for k = 1, 1500 do
		local x, y, z = normalize(MyMath.rand2(k, 1, 7) * 2 - 1, MyMath.rand2(k, 2, 7) * 2 - 1, MyMath.rand2(k, 3, 7) * 2 - 1)
		table.insert(errs, abs(SphereCache.cloud(C, x, y, z) - Clouds.density(x, y, z)))
	end
	table.sort(errs)
	local sum = 0
	for _, e in errs do
		sum += e
	end
	local mean, p99 = sum / #errs, errs[math.floor(#errs * 0.99)]
	check(mean < 0.07, string.format("cloud cache mean error %.3f", mean))
	check(p99 < 0.55, string.format("cloud cache 99th percentile error %.3f", p99))
	local cover = 0
	for k = 1, 2000 do
		local x, y, z = normalize(MyMath.rand2(k, 4, 4) * 2 - 1, MyMath.rand2(k, 5, 4) * 2 - 1, MyMath.rand2(k, 6, 4) * 2 - 1)
		cover += Clouds.density(x, y, z)
	end
	cover /= 2000
	check(cover > 0.15 and cover < 0.6, string.format("cloud cover %.0f%%", cover * 100))
end

-- 5. sky: deterministic, dark background, some bright stars, no hard edges at face borders
do
	local a = SkyGen.face(2, 128, 5)
	local b = SkyGen.face(2, 128, 5)
	check(buffer.tostring(a) == buffer.tostring(b), "skybox faces are deterministic")
	local dark, bright = 0, 0
	for i = 0, 128 * 128 - 1 do
		local c = buffer.readu32(a, i * 4)
		local lum = c % 256 + (c // 256) % 256 + (c // 65536) % 256
		if lum < 30 then
			dark += 1
		elseif lum > 400 then
			bright += 1
		end
	end
	check(dark > 128 * 128 * 0.85, "mostly dark sky")
	check(bright > 3, "some bright stars (" .. bright .. ")")
	local sun = SkyGen.sun(64, 0.22)
	local centre = buffer.readu32(sun, (32 * 64 + 32) * 4)
	local corner = buffer.readu32(sun, 0)
	check(centre // 16777216 == 255 and corner // 16777216 == 0, "sun sprite: opaque core, transparent corners")
end

print("planets_render: " .. checks .. " checks passed")
