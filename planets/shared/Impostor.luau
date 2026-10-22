--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Impostor
--
-- Raytraces a body into an EditableImage shown on a camera-facing BillboardGui. The
-- billboard is a square of half-size `half` studs through the body's centre, spanned by
-- the camera's right and up axes; pixel (x, y) is the ray from the camera through the
-- billboard point under it. Because every ray uses the true geometry, the silhouette,
-- phase, rings and atmosphere are exactly right for the current view, at any distance and
-- off-axis, and the billboard can be drawn nearer the camera at a reduced size (scaled
-- space) without changing the image.
--
-- Exact anti-aliasing, the project's axioms applied to a sphere:
--   limb   the distance from the centre to the ray, d, minus the radius is a signed
--          distance in studs; divided by its per-pixel change (central differences of d
--          over neighbouring rays) it is a signed distance in pixels, and the disc's share
--          of the pixel is the exact area MyMath.coverageHalfPlane gives against the limb's
--          tangent line.
--   rings  the ring radius under the pixel spans an interval (its per-pixel change); the
--          ring's opacity and colour are the exact box filter of the profile over that
--          interval (Bodies.ringAt, prefix integrals). Gaps narrower than a pixel dim it by
--          their share instead of shimmering.
-- Lighting: Lambert on the cached normal with a soft terminator, Blinn-Phong glint on
-- smooth (water) texels, ring shadows on the planet, the planet's shadow on the rings,
-- clouds lit by the sphere normal, and an atmosphere rim lit on the day side.

local Bodies = require("./Bodies")
local SphereCache = require("./SphereCache")
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
}

local sqrt = math.sqrt
local smoothstep = MyMath.smoothstep
local coverageHalfPlane = MyMath.coverageHalfPlane
local sample, cloudAt = SphereCache.sample, SphereCache.cloud

local function byte(v: number): number
	local q = (v * 255 + 0.5) // 1
	return if q < 0 then 0 elseif q > 255 then 255 else q
end

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

-- Renders rows [y0, y1) of the n x n image into `out` (RGBA8, straight alpha).
function Impostor.render(out: buffer, p: Params, cache: SphereCache.Cache?, y0: number, y1: number)
	local B = Bodies.get(p.body)
	local R = B.radius
	local n = p.n
	local cx, cy, cz = p.cx, p.cy, p.cz
	local rx, ry, rz, ux, uy, uz = p.rx, p.ry, p.rz, p.ux, p.uy, p.uz
	local half = p.half
	local sx, sy, sz = p.sx, p.sy, p.sz
	local cc = cx * cx + cy * cy + cz * cz
	local c2 = cc - R * R
	local atm = B.atmosphere
	local Ra = if atm then R * (1 + atm.thickness) else R
	local rings = B.rings
	local terra = p.body == "terra"
	local cosA, sinA = math.cos(p.cloudAngle), math.sin(p.cloudAngle)
	local pix = 2 * half / n -- billboard pixel size (studs)

	-- direction of the ray through pixel centre (x + 0.5, y + 0.5)
	local function ray(x: number, y: number): (number, number, number)
		local qx = ((x + 0.5) / n * 2 - 1) * half
		local qy = (1 - (y + 0.5) / n * 2) * half
		local dx = qx * rx + qy * ux - cx
		local dy = qx * ry + qy * uy - cy
		local dz = qx * rz + qy * uz - cz
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		return dx / l, dy / l, dz / l
	end
	-- distance from the centre to the ray's line
	local function perp(dx: number, dy: number, dz: number): number
		local b = cx * dx + cy * dy + cz * dz
		local q = cc - b * b
		return if q > 0 then sqrt(q) else 0
	end
	-- ring radius (body radii) where the ray crosses the ring plane, or -1
	local nrx, nry, nrz = 0, 1, 0
	if rings then
		nrx, nry, nrz = rings.nx, rings.ny, rings.nz
	end
	-- Atmosphere brightness 0..1 for a ray passing at distance d from the centre: density
	-- (1 - altitude / thickness) integrated along the chord through the shell (both sides of
	-- the closest approach for a ray that misses, the near side only for one that hits),
	-- normalised so the grazing ray is 1, then saturated as 1 - 1 / (1 + 3 tau).
	local Ra2, R2 = Ra * Ra, R * R
	local norm = if atm then 2 * sqrt(Ra2 - R2) * 0.5 else 1
	local function atmGlow(d: number, hits: boolean): number
		if not atm then
			return 0
		end
		local d2 = d * d
		local outer = if Ra2 > d2 then sqrt(Ra2 - d2) else 0
		local inner = if R2 > d2 then sqrt(R2 - d2) else 0
		-- mean density along the chord is about (1 - (d - R) / (Ra - R)) / 2 for a miss
		local path = if hits then outer - inner else 2 * outer
		local alt = (d - R) / (Ra - R)
		if alt < 0 then
			alt = 0
		end
		local tau = path / norm * (1 - alt) * 0.5
		return (1 - 1 / (1 + 3 * tau)) * atm.strength
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

	for y = y0, y1 - 1 do
		for x = 0, n - 1 do
			local dx, dy, dz = ray(x, y)
			local b = cx * dx + cy * dy + cz * dz
			local d0 = perp(dx, dy, dz)
			-- premultiplied accumulation, back to front
			local ar, ag, ab, aa = 0, 0, 0, 0
			local disc = b * b - c2
			local tHit = math.huge
			if disc >= 0 then
				local t = -b - sqrt(disc)
				if t > 0 then
					tHit = t
				end
			end
			-- planet coverage of the pixel (exact area against the limb's tangent line)
			local cov = if tHit < math.huge then 1 else 0
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
			-- rings: hit, footprint, box-filtered profile
			local ringA, ringR, ringG, ringB, ringT = 0, 0, 0, 0, 0
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
						local lit = 0.22 + 0.78 * math.abs(ndl)
						-- the planet's shadow on the rings
						local bq = qx * sx + qy * sy + qz * sz
						local cq = qx * qx + qy * qy + qz * qz - R * R
						if bq < 0 and bq * bq - cq > 0 then
							lit *= 0.07
						end
						ringA = dens * 0.95
						ringR, ringG, ringB = cr * lit, cg * lit, cb * lit
						ringT = t
					end
				end
			end
			local ringFront = ringA > 0 and ringT < tHit
			if ringA > 0 and not ringFront then
				ar, ag, ab, aa = ringR * ringA, ringG * ringA, ringB * ringA, ringA
			end
			-- atmosphere around the limb: light scattered along the ray's path through the
			-- shell, weighted by density (falling linearly with altitude) and lit by the
			-- sun at the ray's closest approach
			if atm and d0 < Ra and b < 0 and cov < 1 then
				local glow = atmGlow(d0, false)
				local px, py, pz = cx + dx * -b, cy + dy * -b, cz + dz * -b
				local pl = sqrt(px * px + py * py + pz * pz)
				local sdl = if pl > 0 then (px * sx + py * sy + pz * sz) / pl else 0
				glow *= smoothstep(-0.3, 0.35, sdl)
				local ga = glow * (1 - cov)
				ar = atm.r * ga + ar * (1 - ga)
				ag = atm.g * ga + ag * (1 - ga)
				ab = atm.b * ga + ab * (1 - ga)
				aa = ga + aa * (1 - ga)
			end
			-- the planet
			if cov > 0 then
				-- surface point: the hit, or the closest approach for limb pixels whose centre misses
				local px, py, pz
				if tHit < math.huge then
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
				local sdl = hx * sx + hy * sy + hz * sz
				local term = smoothstep(-0.06, 0.1, sdl)
				local ndl = nx * sx + ny * sy + nz * sz
				local diffuse = (if ndl > 0 then ndl else 0) * term
				-- ring shadow on the planet
				if rings then
					local den = sx * nrx + sy * nry + sz * nrz
					if den > 1e-9 or den < -1e-9 then
						local t = -(px * nrx + py * nry + pz * nrz) / den
						if t > 0 then
							local qx, qy, qz = px + sx * t, py + sy * t, pz + sz * t
							local rr = sqrt(qx * qx + qy * qy + qz * qz) / R
							local dens = Bodies.ringAt(rings, rr, rr)
							diffuse *= 1 - 0.85 * dens
						end
					end
				end
				local amb = 0.018
				local cr = alr * (amb + diffuse * 1.05)
				local cg = alg * (amb + diffuse * 1.05)
				local cb = alb * (amb + diffuse * 1.05)
				-- limb darkening for gas giants
				local mu = -(hx * dx + hy * dy + hz * dz)
				if B.kind == "gas" then
					local ld = 0.55 + 0.45 * mu
					cr, cg, cb = cr * ld, cg * ld, cb * ld
				end
				-- glint on smooth texels (Blinn-Phong, exponent 64 by squaring)
				local gloss = 1 - rough
				if gloss > 0.5 and diffuse > 0 then
					local hvx, hvy, hvz = sx - dx, sy - dy, sz - dz
					local hl = sqrt(hvx * hvx + hvy * hvy + hvz * hvz)
					local nh = (nx * hvx + ny * hvy + nz * hvz) / hl
					if nh > 0 then
						local s2 = nh * nh
						local s4 = s2 * s2
						local s8 = s4 * s4
						local s16 = s8 * s8
						local s32 = s16 * s16
						local spec = s32 * s32 * (gloss - 0.5) * 2 * 0.9 * term
						cr += spec
						cg += spec * 0.97
						cb += spec * 0.9
					end
				end
				-- clouds, lit by the sphere normal
				if terra and cache then
					local qx = hx * cosA - hz * sinA
					local qz = hx * sinA + hz * cosA
					local cl = cloudAt(cache, qx, hy, qz)
					if cl > 0 then
						local light = amb + 1.0 * (if sdl > 0 then sdl else 0) * term
						cr += (light - cr) * cl * 0.95
						cg += (light - cg) * cl * 0.95
						cb += (light - cb) * cl * 0.95
					end
				end
				-- atmospheric haze: the same path model for a ray that ends on the surface
				if atm then
					local haze = atmGlow(if d0 < R then d0 else R, true) * smoothstep(-0.3, 0.35, sdl)
					cr += (atm.r - cr) * haze
					cg += (atm.g - cg) * haze
					cb += (atm.b - cb) * haze
				end
				ar = cr * cov + ar * (1 - cov)
				ag = cg * cov + ag * (1 - cov)
				ab = cb * cov + ab * (1 - cov)
				aa = cov + aa * (1 - cov)
			end
			if ringFront then
				ar = ringR * ringA + ar * (1 - ringA)
				ag = ringG * ringA + ag * (1 - ringA)
				ab = ringB * ringA + ab * (1 - ringA)
				aa = ringA + aa * (1 - ringA)
			end
			local o = (y * n + x) * 4
			if aa <= 0 then
				buffer.writeu32(out, o, 0)
			else
				local inv = 1 / aa
				buffer.writeu32(out, o, byte(ar * inv) + byte(ag * inv) * 256 + byte(ab * inv) * 65536 + byte(aa) * 16777216)
			end
		end
	end
end

return Impostor
