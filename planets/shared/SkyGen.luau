--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: SkyGen
--
-- The space backdrop: six skybox faces of stars, and the sun's glow sprite.
--
-- Stars are hashed per cell (a jittered grid, so density is even and nothing clumps),
-- with a power-law brightness and a colour temperature. Each star is a small disc whose
-- pixel coverage is the exact area under a circle of radius r centred off-grid: the
-- discs are drawn with MyMath.coverageCurved on the distance to their centre, so faint
-- stars are smooth sub-pixel dots instead of single hard pixels that crawl as the camera
-- turns. A faint dust glow comes from low-frequency noise per face. The faces carry no
-- feature that must line up across an edge (no galactic band), so the result does not
-- depend on how the engine orients each skybox image.

local MyMath = require("../Universe/MyMath")
local Noise3 = require("./Noise3")

local SkyGen = {}

local sqrt = math.sqrt

local function byte(v: number): number
	local q = (v * 255 + 0.5) // 1
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

-- Star colour from a temperature-like parameter t in [0, 1] (red dwarfs to blue giants).
local function starColor(t: number): (number, number, number)
	if t < 0.5 then
		local u = t * 2
		return 1, 0.62 + 0.33 * u, 0.42 + 0.48 * u
	end
	local u = (t - 0.5) * 2
	return 1 - 0.22 * u, 0.95 - 0.07 * u, 0.9 + 0.1 * u
end

-- Skybox face `face` (1..6) of n x n pixels, deterministic from `seed`.
function SkyGen.face(face: number, n: number, seed: number): buffer
	local out = buffer.create(n * n * 4)
	-- background: deep blue-black with faint dust
	local F = Noise3.new(seed * 31 + face)
	local R = table.create(n * n, 0)
	local G = table.create(n * n, 0)
	local Bc = table.create(n * n, 0)
	local step = 8
	-- dust at 1/8 resolution, bilinear
	local m = n // step + 1
	local dust = table.create(m * m, 0)
	for j = 0, m - 1 do
		for i = 0, m - 1 do
			local d = Noise3.fbm(F, i / m * 3, j / m * 3, face * 7.1, 1, 4, 0.55)
			dust[j * m + i + 1] = MyMath.smoothstep(0.1, 0.9, d) * 0.035
		end
	end
	for y = 0, n - 1 do
		local gy = y / step
		local j = gy // 1
		if j > m - 2 then
			j = m - 2
		end
		local fy = gy - j
		for x = 0, n - 1 do
			local gx = x / step
			local i = gx // 1
			if i > m - 2 then
				i = m - 2
			end
			local fx = gx - i
			local a = dust[j * m + i + 1] + (dust[j * m + i + 2] - dust[j * m + i + 1]) * fx
			local b = dust[(j + 1) * m + i + 1] + (dust[(j + 1) * m + i + 2] - dust[(j + 1) * m + i + 1]) * fx
			local v = a + (b - a) * fy
			local k = y * n + x + 1
			R[k] = 0.004 + v * 0.8
			G[k] = 0.006 + v * 0.7
			Bc[k] = 0.014 + v
		end
	end
	-- stars on a jittered grid of cells
	local cell = 6
	local cells = n // cell
	for cj = 0, cells - 1 do
		for ci = 0, cells - 1 do
			local h = MyMath.hash32(MyMath.u32(((seed * 8 + face) * 4096 + cj) * 4096 + ci))
			if h % 100 < 30 then
				local jx = ((h // 128) % 1024) / 1024
				local jy = ((h // 131072) % 1024) / 1024
				local sxp = (ci + jx) * cell
				local syp = (cj + jy) * cell
				-- brightness: power law (many faint, few bright)
				local u = ((h // 4096) % 4096) / 4095
				local u2 = u * u
				local mag = u2 * u2 * u2 -- u^6: most stars faint, a few very bright
				local bright = 0.05 + 0.25 * u2 + 2.2 * mag
				local radius = 0.42 + 0.95 * mag
				local tr, tg, tb = starColor(((h // 512) % 1000) / 999)
				local reach = (radius + 1) // 1 + 1
				for yy = (syp - reach) // 1, (syp + reach) // 1 do
					for xx = (sxp - reach) // 1, (sxp + reach) // 1 do
						if xx >= 0 and xx < n and yy >= 0 and yy < n then
							local ddx, ddy = xx + 0.5 - sxp, yy + 0.5 - syp
							local d = sqrt(ddx * ddx + ddy * ddy)
							local cov
							if d > 1e-9 then
								cov = MyMath.coverageCurved(d - radius, ddx / d, ddy / d, 1 / radius)
							else
								cov = if radius >= 0.71 then 1 else math.pi * radius * radius
							end
							if cov > 0 then
								local k = yy * n + xx + 1
								local e = cov * bright
								R[k] += tr * e
								G[k] += tg * e
								Bc[k] += tb * e
							end
						end
					end
				end
			end
		end
	end
	for k = 1, n * n do
		buffer.writeu32(out, (k - 1) * 4, byte(R[k]) + byte(G[k]) * 256 + byte(Bc[k]) * 65536 + 4278190080)
	end
	return out
end

-- The sun's sprite: a white-hot disc of radius `core` (fraction of the half-size) with exact
-- edge coverage, inside a corona falling off as 1 / (1 + (d / w)^2)^1.5. Straight alpha.
function SkyGen.sun(n: number, core: number): buffer
	local out = buffer.create(n * n * 4)
	local c = n * 0.5
	local rCore = core * c
	local w = rCore * 0.9
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local dx, dy = x + 0.5 - c, y + 0.5 - c
			local d = sqrt(dx * dx + dy * dy)
			local disc
			if d > 1e-9 then
				disc = MyMath.coverageCurved(d - rCore, dx / d, dy / d, 1 / rCore)
			else
				disc = 1
			end
			local q = d / w
			local s = 1 + q * q
			local corona = 1 / (s * sqrt(s))
			-- fade the corona to zero at the sprite's edge so the square never shows
			local edge = MyMath.smoothstep(c, c * 0.72, d)
			corona *= edge
			local a = disc + corona * 0.85 * (1 - disc)
			local r = disc + (1 - disc) * 1.0
			local g = disc + (1 - disc) * 0.86
			local b = disc + (1 - disc) * 0.62
			buffer.writeu32(out, (y * n + x) * 4, byte(r) + byte(g) * 256 + byte(b) * 65536 + byte(a) * 16777216)
		end
	end
	return out
end

return SkyGen
