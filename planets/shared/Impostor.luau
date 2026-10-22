--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Impostor
--
-- Raytraces a body into an EditableImage shown on a camera-facing BillboardGui. The
-- billboard is a square of half-size `half` studs through the body's centre, spanned by
-- the camera's right and up axes; pixel (x, y) is the ray from the camera through the
-- billboard point under it, so silhouette, phase, rings and atmosphere are exact for the
-- current view at any distance, and the billboard can be drawn nearer the camera at a
-- reduced size (scaled space) without changing the image.
--
-- LIGHT. Everything is computed in linear radiance and tone mapped once at the end
-- (Atmos.tonemap: exposure, ACES fit, sRGB; 0 stays exactly 0). Units: a Lambert surface
-- of albedo A facing the unobstructed sun has radiance A.
--   surface   A (T_sun(mu_s) max(0, n . s) + ambient(mu_s)): sunlight reddened by the air
--             it crosses, so the terminator turns orange, and exactly nothing on the night
--             side (the ambient table is exactly zero there)
--   air       a ray that ends on the ground adds the tabulated in-scatter and dims the
--             surface by the column's transmittance; a ray that grazes past the planet
--             reads the limb table: the blue halo, the orange rim against the sun, Mie glare
--   clouds    a shell above the surface, found by intersecting the ray with it (so clouds
--             shift against the ground with the view, parallax), lit through the air at
--             their height, self-shadowed by sampling the cloud field one step towards
--             the sun, with a silver lining when backlit; they shadow the ground the same way
--   rings     radii box-filtered exactly over the pixel (no shimmer in gaps), lit by the sun
--             at the ring plane, exactly dark in the planet's shadow
-- Exact anti-aliasing of the limb as before (MyMath.coverageHalfPlane on the distance
-- from the centre to the ray). The image is premultiplied-composited back to front and
-- written as straight alpha: planet coverage is the alpha of the disc; a faint halo has
-- a small alpha so stars show through it.

local Bodies = require("./Bodies")
local SphereCache = require("./SphereCache")
local Atmos = require("./Atmos")
local MyMath = require("../Universe/MyMath")

local Impostor = {}

export type Params = {
	body: string,
	n: number, -- image size (square)
	cx: number, -- camera relative to the body centre (studs)
	cy: number,
	cz: number,
	rx: number, -- billboard right axis (unit)
	ry: number,
	rz: number,
	ux: number, -- billboard up axis (unit)
	uy: number,
	uz: number,
	half: number, -- billboard half-size (studs, at the body's true distance)
	sx: number, -- unit vector towards the sun
	sy: number,
	sz: number,
	cloudAngle: number, -- cloud layer rotation about +Y (radians)
	exposure: number?, -- default 1
	cloudHeight: number?, -- studs above the surface (default 16)
}

local sqrt = math.sqrt
local smoothstep = MyMath.smoothstep
local coverageHalfPlane = MyMath.coverageHalfPlane
local sample, cloudAt = SphereCache.sample, SphereCache.cloud
local tonemap = Atmos.tonemap
local hash2 = MyMath.hash2

-- Half-size (studs) of the billboard that contains the body plus `extra` radii (atmosphere,
-- rings) seen from distance D: the tangent cone of that sphere crosses the billboard plane
-- (through the centre, facing the camera) at D tan(asin(r / D)). The margin keeps two
-- pixels of an n-pixel image clear on each side, so the limb's anti-aliased edge never
-- touches the border (a fixed percentage is less than a pixel on small images).
function Impostor.halfSize(radius: number, extra: number, D: number, n: number?): number
	local r = radius * extra
	if D <= r * 1.0001 then
		return r * 100
	end
	local px = n or 256
	local margin = 1 / (1 - 4 / px)
	if margin < 1.01 then
		margin = 1.01
	end
	return r * D / sqrt(D * D - r * r) * margin
end

local function byteOf(v: number): number
	local q = (v * 255 + 0.5) // 1
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

-- Renders rows [y0, y1) of the n x n image into `out` (RGBA8, straight alpha). With
-- `bandStart`, `out` holds only a band of rows starting at that row (worker jobs return
-- bands); otherwise it is the whole image.
function Impostor.render(out: buffer, p: Params, cache: SphereCache.Cache?, y0: number, y1: number, bandStart: number?)
	local base = bandStart or 0
	local B = Bodies.get(p.body)
	local R = B.radius
	local A = Atmos.get(p.body)
	local n = p.n
	local cx, cy, cz = p.cx, p.cy, p.cz
	local rx, ry, rz, ux, uy, uz = p.rx, p.ry, p.rz, p.ux, p.uy, p.uz
	local half = p.half
	local sx, sy, sz = p.sx, p.sy, p.sz
	local exposure = p.exposure or 1
	local cc = cx * cx + cy * cy + cz * cz
	local c2 = cc - R * R
	local Rt = if A then A.Rt else R
	local rings = B.rings
	local terra = p.body == "terra"
	local gas = B.kind == "gas"
	local cosA, sinA = math.cos(p.cloudAngle), math.sin(p.cloudAngle)
	local pix = 2 * half / n
	local hC = p.cloudHeight or 16
	local Rc = R + hC
	local useClouds = terra and cache ~= nil
	local hasSea = B.sea

	local function ray(x: number, y: number): (number, number, number)
		local qx = ((x + 0.5) / n * 2 - 1) * half
		local qy = (1 - (y + 0.5) / n * 2) * half
		local dx = qx * rx + qy * ux - cx
		local dy = qx * ry + qy * uy - cy
		local dz = qx * rz + qy * uz - cz
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		return dx / l, dy / l, dz / l
	end
	local function perp(dx: number, dy: number, dz: number): number
		local b = cx * dx + cy * dy + cz * dz
		local q = cc - b * b
		return if q > 0 then sqrt(q) else 0
	end
	local nrx, nry, nrz = 0, 1, 0
	if rings then
		nrx, nry, nrz = rings.nx, rings.ny, rings.nz
	end
	local function ringHit(dx: number, dy: number, dz: number): (number, number)
		local den = dx * nrx + dy * nry + dz * nrz
		if den > -1e-12 and den < 1e-12 then
			return -1, 0
		end
		local t = -(cx * nrx + cy * nry + cz * nrz) / den
		if t <= 0 then
			return -1, 0
		end
		local qx, qy, qz = cx + dx * t, cy + dy * t, cz + dz * t
		return sqrt(qx * qx + qy * qy + qz * qz) / R, t
	end
	-- cloud cover at a unit direction of the (rotating) shell
	local function cloudCover(hx: number, hy: number, hz: number): number
		local qx = hx * cosA - hz * sinA
		local qz = hx * sinA + hz * cosA
		return cloudAt(cache :: SphereCache.Cache, qx, hy, qz)
	end

	for y = y0, y1 - 1 do
		for x = 0, n - 1 do
			local dx, dy, dz = ray(x, y)
			local b = cx * dx + cy * dy + cz * dz
			local d0 = perp(dx, dy, dz)
			local tHit = math.huge
			local disc = b * b - c2
			if disc >= 0 and b < 0 then
				local t = -b - sqrt(disc)
				if t > 0 then
					tHit = t
				end
			end
			local hits = tHit < math.huge
			-- anything here at all? (the planet, its air, its clouds, its rings)
			local near = d0 < Rt + 2 * pix or d0 < Rc + 2 * pix
			local ringR, ringG, ringB, ringA, ringT = 0, 0, 0, 0, 0
			if rings then
				local rr, t = ringHit(dx, dy, dz)
				if rr > 0 and rr > rings.inner - 0.1 and rr < rings.outer + 0.1 then
					local ex, ey, ez = ray(x + 1, y)
					local fx, fy, fz = ray(x, y + 1)
					local r1 = ringHit(ex, ey, ez)
					local r2 = ringHit(fx, fy, fz)
					local w = (if r1 > 0 then math.abs(r1 - rr) else 0) + (if r2 > 0 then math.abs(r2 - rr) else 0)
					local dens, cr, cg, cb = Bodies.ringAt(rings, rr - w * 0.5, rr + w * 0.5)
					if dens > 0 then
						local qx, qy, qz = cx + dx * t, cy + dy * t, cz + dz * t
						local ndl = nrx * sx + nry * sy + nrz * sz
						local lit = 0.18 + 0.82 * math.abs(ndl)
						-- the planet's shadow on the rings: exactly dark
						local bq = qx * sx + qy * sy + qz * sz
						local cq = qx * qx + qy * qy + qz * qz - R * R
						if bq < 0 and bq * bq - cq > 0 then
							lit = 0
						end
						ringA = dens * 0.95
						ringR, ringG, ringB = cr * lit, cg * lit, cb * lit
						ringT = t
					end
				end
			end
			local pr, pg, pb, pa = 0, 0, 0, 0 -- premultiplied display colour and alpha so far
			if near or ringA > 0 then
				local t0 = -b -- parameter of the closest approach
				-- ---- the planet disc (exact coverage) and its air
				local cov = if hits then 1 else 0
				if d0 - R < 3 * pix and R - d0 < 3 * pix and b < 0 then
					local ex, ey, ez = ray(x + 1, y)
					local fx, fy, fz = ray(x, y + 1)
					local gx = perp(ex, ey, ez) - d0
					local gy = perp(fx, fy, fz) - d0
					local g = sqrt(gx * gx + gy * gy)
					if g > 1e-12 then
						cov = coverageHalfPlane((d0 - R) / g, gx / g, gy / g)
					end
				end
				-- ring behind the body (farther than the closest approach)
				local ringBehind = ringA > 0 and ringT >= t0
				local backR, backG, backB, backA = 0, 0, 0, 0
				if ringBehind then
					local ar, ag, ab = tonemap(ringR, ringG, ringB, exposure)
					backR, backG, backB, backA = ar * ringA, ag * ringA, ab * ringA, ringA
				end
				local planetR, planetG, planetB = 0, 0, 0
				-- clouds: the ray against the shell at R + hC
				local cl, clR, clG, clB = 0, 0, 0, 0
				if useClouds and d0 < Rc and b < 0 then
					local dcl = Rc * Rc - d0 * d0
					local tc = -b - sqrt(dcl)
					if tc > 0 and (not hits or tc < tHit) then
						local qx, qy, qz = (cx + dx * tc) / Rc, (cy + dy * tc) / Rc, (cz + dz * tc) / Rc
						local cover = cloudCover(qx, qy, qz)
						if cover > 0.01 then
							local mus = qx * sx + qy * sy + qz * sz
							local tr, tg, tb = 1, 1, 1
							if A then
								tr, tg, tb = Atmos.sunlight(A, hC, mus)
							elseif mus <= 0 then
								tr, tg, tb = 0, 0, 0
							end
							-- soft self shading from the cover gradient along the sun: a neighbour one
							-- texel towards the sun with less cover means a lit, sun-facing edge; with
							-- more cover, a shadowed one
							local stx, sty, stz = sx - qx * mus, sy - qy * mus, sz - qz * mus
							local sl = 0.02 / (if mus > 0.25 then mus else 0.25)
							local kx, ky, kz = qx + stx * sl, qy + sty * sl, qz + stz * sl
							local kl = sqrt(kx * kx + ky * ky + kz * kz)
							local cs = cloudCover(kx / kl, ky / kl, kz / kl)
							local shade = 0.92 + 0.9 * (cover - cs)
							if shade < 0.4 then
								shade = 0.4
							elseif shade > 1.1 then
								shade = 1.1
							end
							local lit = smoothstep(-0.1, 0.35, mus) * shade
							-- silver lining: forward scattering through thin cloud edges
							local cosv = -(dx * sx + dy * sy + dz * sz)
							local fwd = if cosv > 0 then cosv ^ 6 else 0
							local silver = 0.9 * fwd * (1 - cover) * smoothstep(-0.05, 0.3, mus)
							local ar, ag, ab = 0, 0, 0
							if A then
								ar, ag, ab = Atmos.ambient(A, mus)
							end
							local k = 0.95
							clR = k * (tr * (lit + silver) + ar * 0.8)
							clG = k * (tg * (lit + silver) + ag * 0.8)
							clB = k * (tb * (lit + silver) + ab * 0.8)
							cl = cover * 0.97
						end
					end
				end
				-- the air for rays that miss the planet (the halo), including limb pixels
				local mr, mg, mb = 0, 0, 0
				if A and d0 < Rt and b < 0 then
					local dd = if d0 < R + 0.001 then R + 0.001 else d0
					local qx, qy, qz = cx - dx * b, cy - dy * b, cz - dz * b
					local ql = sqrt(qx * qx + qy * qy + qz * qz)
					local a = dx * sx + dy * sy + dz * sz
					local bs = if ql > 1e-9 then (qx * sx + qy * sy + qz * sz) / ql else 0
					mr, mg, mb = Atmos.lookMiss(A, dd, a, bs)
				end
				-- ---- the planet's own surface
				if cov > 0 then
					local px, py, pz
					if hits then
						px, py, pz = cx + dx * tHit, cy + dy * tHit, cz + dz * tHit
					else
						px, py, pz = cx - dx * b, cy - dy * b, cz - dz * b
					end
					local pl = sqrt(px * px + py * py + pz * pz)
					local hx, hy, hz = px / pl, py / pl, pz / pl
					local alr, alg, alb, rough, nx, ny, nz = 0.5, 0.5, 0.5, 0.9, hx, hy, hz
					if cache then
						alr, alg, alb, rough, nx, ny, nz = sample(cache, hx, hy, hz)
					end
					local mus = hx * sx + hy * sy + hz * sz
					local mu = -(hx * dx + hy * dy + hz * dz)
					if mu < 0.001 then
						mu = 0.001
					end
					-- light reaching the ground
					local er, eg, eb = 1, 1, 1
					local amr, amg, amb = 0, 0, 0
					if A then
						er, eg, eb = Atmos.sunlight(A, 0, mus)
						amr, amg, amb = Atmos.ambient(A, mus)
					elseif mus <= 0 then
						er, eg, eb = 0, 0, 0
					end
					local ndl = nx * sx + ny * sy + nz * sz
					if ndl < 0 then
						ndl = 0
					end
					-- cloud shadow on the ground: the cover where the sun's ray crosses the shell
					if useClouds and mus > 0.05 then
						local kx, ky, kz = hx + (sx - hx * mus) * (hC / R) / mus, hy + (sy - hy * mus) * (hC / R) / mus, hz + (sz - hz * mus) * (hC / R) / mus
						local kl = sqrt(kx * kx + ky * ky + kz * kz)
						local sh = cloudCover(kx / kl, ky / kl, kz / kl)
						ndl *= 1 - 0.78 * sh
					end
					local Lr = alr * (er * ndl + amr)
					local Lg = alg * (eg * ndl + amg)
					local Lb = alb * (eb * ndl + amb)
					-- glint on smooth texels (water), Blinn-Phong exponent 64
					local gloss = 1 - rough
					if hasSea and gloss > 0.5 and ndl > 0 then
						local hvx, hvy, hvz = sx - dx, sy - dy, sz - dz
						local hl = sqrt(hvx * hvx + hvy * hvy + hvz * hvz)
						local nh = (nx * hvx + ny * hvy + nz * hvz) / hl
						if nh > 0 then
							local s2 = nh * nh
							local s4 = s2 * s2
							local s8 = s4 * s4
							local s16 = s8 * s8
							local s32 = s16 * s16
							local spec = s32 * s32 * (gloss - 0.5) * 2 * 0.9
							Lr += spec * er
							Lg += spec * eg
							Lb += spec * eb
						end
					end
					if gas then
						local ld = 0.55 + 0.45 * mu
						Lr, Lg, Lb = Lr * ld, Lg * ld, Lb * ld
					end
					-- clouds over the ground (parallax: they came from the shell hit above)
					if cl > 0 then
						Lr = clR * cl + Lr * (1 - cl)
						Lg = clG * cl + Lg * (1 - cl)
						Lb = clB * cl + Lb * (1 - cl)
					end
					-- through the air to the camera
					if A then
						local tr, tg, tb = Atmos.columnT(A, mu)
						local ir, ig, ib = Atmos.lookHit(A, mu, mus, dx * sx + dy * sy + dz * sz)
						Lr = Lr * tr + ir
						Lg = Lg * tg + ig
						Lb = Lb * tb + ib
					end
					planetR, planetG, planetB = tonemap(Lr, Lg, Lb, exposure)
				end
				-- ---- the uncovered part of the pixel: the ring behind, the halo over it, then
				-- clouds beyond the limb (a halo is an emission of opacity max(rgb): stars show
				-- through a faint one)
				local rest = 1 - cov
				local restR, restG, restB, restA = backR, backG, backB, backA
				if rest > 0 then
					if A and d0 < Rt then
						local hr, hg, hb = tonemap(mr, mg, mb, exposure)
						local ha = math.max(hr, hg, hb)
						if ha > 0 then
							restR = hr + (1 - ha) * restR
							restG = hg + (1 - ha) * restG
							restB = hb + (1 - ha) * restB
							restA = ha + (1 - ha) * restA
						end
					end
					if cl > 0 and not hits then
						local ar, ag, ab = tonemap(clR, clG, clB, exposure)
						restR = ar * cl + (1 - cl) * restR
						restG = ag * cl + (1 - cl) * restG
						restB = ab * cl + (1 - cl) * restB
						restA = cl + (1 - cl) * restA
					end
				end
				pr = planetR * cov + restR * rest
				pg = planetG * cov + restG * rest
				pb = planetB * cov + restB * rest
				pa = cov + restA * rest
				-- ring in front of the body
				if ringA > 0 and not ringBehind then
					local ar, ag, ab = tonemap(ringR, ringG, ringB, exposure)
					pr = ar * ringA + pr * (1 - ringA)
					pg = ag * ringA + pg * (1 - ringA)
					pb = ab * ringA + pb * (1 - ringA)
					pa = ringA + pa * (1 - ringA)
				end
			end
			local o = ((y - base) * n + x) * 4
			if pa <= 0 then
				buffer.writeu32(out, o, 0)
			else
				-- straight alpha; one least-significant-bit of dither on non-zero values so
				-- dark glows do not band (zero stays exactly zero)
				local inv = 1 / pa
				local dth = (hash2(x, y, 977) / 4294967296 - 0.5) / 255
				local r, g, bl = pr * inv, pg * inv, pb * inv
				if r > 0 then
					r += dth
				end
				if g > 0 then
					g += dth
				end
				if bl > 0 then
					bl += dth
				end
				buffer.writeu32(out, o, byteOf(r) + byteOf(g) * 256 + byteOf(bl) * 65536 + byteOf(pa) * 16777216)
			end
		end
	end
end

return Impostor
