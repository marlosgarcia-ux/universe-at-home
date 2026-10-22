--!native
--!optimize 2
-- universe-at-home :: compute/Trace
--
-- Sphere tracing a 3D signed distance field into 2D maps (docs/COMPUTE.md 3.10):
-- an orthographic view down -z gives, per pixel, the first hit, its normal (from
-- a 4-tap tetrahedral gradient) and its height. Outputs a tangent-space normal
-- map (RGB = 127.5 + 127.5 n, alpha 255 on hit, 0 on miss) and a u8 height map.
-- Impostors, bevels, embossed UI and procedural relief come from this; the
-- height map also feeds Filter.normalMap.
--
-- Determinism: + - * / sqrt abs only, a fixed step limit and epsilon, so every
-- client reproduces the same bytes. Cost: steps x SDF cost per pixel, so pixels
-- whose ray misses the object's bounding sphere are skipped in screen space
-- (one span fill per row), and the step loop stops at the bound's far side.

local Pixels = require("../Pixels")

local Trace = {}

export type Scene = {
	sdf: (number, number, number) -> number, -- Lipschitz <= 1
	cx: number, -- bounding sphere (pixels)
	cy: number,
	cz: number,
	br: number,
}

local sqrt, abs = math.sqrt, math.abs

local function smin(a: number, b: number, k: number): number
	local h = 0.5 + 0.5 * (b - a) / k
	h = if h < 0 then 0 elseif h > 1 then 1 else h
	return b + (a - b) * h - k * h * (1 - h)
end

-- Demo scene scaled to a size x size image: a sphere smoothly merged with a torus
-- lying in the image plane and a rounded slab. Units are pixels.
function Trace.demo(size: number): Scene
	local s = size / 256
	local cx, cy = size * 0.5, size * 0.5
	local R, tr, tt = 70 * s, 85 * s, 14 * s
	local function sdf(x: number, y: number, z: number): number
		local dx, dy, dz = x - cx, y - cy, z
		local sphere = sqrt(dx * dx + dy * dy + dz * dz) - R
		local q = sqrt(dx * dx + dy * dy) - tr
		local torus = sqrt(q * q + dz * dz) - tt
		-- rounded slab |x|, |y| <= 110 s, |z| <= 6 s, edge radius 4 s
		local bx = abs(dx) - 106 * s
		local by = abs(dy) - 106 * s
		local bz = abs(dz) - 2 * s
		local ox = if bx > 0 then bx else 0
		local oy = if by > 0 then by else 0
		local oz = if bz > 0 then bz else 0
		local m = if bx > by then bx else by
		if bz > m then
			m = bz
		end
		if m > 0 then
			m = 0
		end
		local slab = sqrt(ox * ox + oy * oy + oz * oz) + m - 4 * s
		return smin(smin(sphere, torus, 12 * s), slab, 8 * s)
	end
	return { sdf = sdf, cx = cx, cy = cy, cz = 0, br = 152 * s }
end

export type TraceStats = { rays: number, steps: number, hits: number }

-- Traces every pixel; writes the normal map into `normals` (RGBA8) and heights
-- (z of the hit, 0 at the bound's far side .. 255 at its near side) into `heights`
-- (u8). maxSteps bounds the work per ray; eps is the hit threshold in pixels.
function Trace.render(sc: Scene, size: number, normals: buffer, heights: buffer, maxSteps: number, eps: number): TraceStats
	local st: TraceStats = { rays = 0, steps = 0, hits = 0 }
	local f = sc.sdf
	local cx, cy, cz, br = sc.cx, sc.cy, sc.cz, sc.br
	local zBot = cz - br
	local hScale = 255 / (2 * br)
	local e = 0.5 -- gradient tap distance
	for y = 0, size - 1 do
		local py = y + 0.5
		local row = y * size
		local dy = py - cy
		local hw2 = br * br - dy * dy
		if hw2 <= 0 then
			Pixels.fillSpan(normals, row * 4, size, 0x00FF8080)
			buffer.fill(heights, row, 0, size)
			continue
		end
		local hw = sqrt(hw2)
		local xa = math.max(0, math.floor(cx - hw - 0.5))
		local xb = math.min(size - 1, math.ceil(cx + hw - 0.5))
		Pixels.fillSpan(normals, row * 4, xa, 0x00FF8080)
		Pixels.fillSpan(normals, (row + xb + 1) * 4, size - 1 - xb, 0x00FF8080)
		buffer.fill(heights, row, 0, size)
		for x = xa, xb do
			local px = x + 0.5
			st.rays += 1
			-- enter the bounding sphere at its near surface
			local dx = px - cx
			local inside = br * br - dx * dx - dy * dy
			local o = (row + x) * 4
			if inside <= 0 then
				buffer.writeu32(normals, o, 0x00FF8080)
				continue
			end
			local z = cz + sqrt(inside)
			local zEnd = cz - sqrt(inside)
			local hit = false
			for _ = 1, maxSteps do
				local d = f(px, py, z)
				st.steps += 1
				if d < eps then
					hit = true
					break
				end
				z -= d
				if z < zEnd then
					break
				end
			end
			if not hit then
				buffer.writeu32(normals, o, 0x00FF8080)
				continue
			end
			st.hits += 1
			-- tetrahedral gradient: k1 = (1,-1,-1), k2 = (-1,-1,1), k3 = (-1,1,-1), k4 = (1,1,1)
			local f1 = f(px + e, py - e, z - e)
			local f2 = f(px - e, py - e, z + e)
			local f3 = f(px - e, py + e, z - e)
			local f4 = f(px + e, py + e, z + e)
			local gx = f1 - f2 - f3 + f4
			local gy = -f1 - f2 + f3 + f4
			local gz = -f1 + f2 - f3 + f4
			local inv = 1 / sqrt(gx * gx + gy * gy + gz * gz)
			local nx, ny, nz = gx * inv, gy * inv, gz * inv
			buffer.writeu32(
				normals,
				o,
				((nx + 1) * 127.5 + 0.5) // 1 + (((ny + 1) * 127.5 + 0.5) // 1) * 256 + (((nz + 1) * 127.5 + 0.5) // 1) * 65536 + 0xFF000000
			)
			local hv = (z - zBot) * hScale
			hv = if hv < 0 then 0 elseif hv > 255 then 255 else hv
			buffer.writeu8(heights, row + x, (hv + 0.5) // 1)
		end
	end
	return st
end

-- Simple Lambert shading of a normal map (light direction l normalised by the
-- caller), for previews: rgb = albedo * max(0, n . l), alpha kept.
function Trace.shade(normals: buffer, count: number, lx: number, ly: number, lz: number, albedo: number, out: buffer)
	local ar, ag, ab = albedo % 256, (albedo // 256) % 256, (albedo // 65536) % 256
	for i = 0, count - 1 do
		local p = buffer.readu32(normals, i * 4)
		local a = p // 16777216
		if a == 0 then
			buffer.writeu32(out, i * 4, 0)
			continue
		end
		local nx = (p % 256) / 127.5 - 1
		local ny = ((p // 256) % 256) / 127.5 - 1
		local nz = ((p // 65536) % 256) / 127.5 - 1
		local l = nx * lx + ny * ly + nz * lz
		if l < 0 then
			l = 0
		end
		buffer.writeu32(out, i * 4, ((ar * l + 0.5) // 1) + ((ag * l + 0.5) // 1) * 256 + ((ab * l + 0.5) // 1) * 65536 + a * 16777216)
	end
end

return Trace
