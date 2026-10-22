--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Atmos
--
-- Physically based atmosphere for the planet billboards, built to be cheap per pixel.
--
-- MODEL. Rayleigh scattering (blue, scale height hr), Mie scattering (haze and glare, scale
-- height hm, Henyey-Greenstein phase), ozone absorption (a tent layer; it keeps sunsets
-- from going grey), single scattering along every ray with the sun's own transmittance
-- through the atmosphere, plus an isotropic second-order term that fills in twilight and
-- shadowed air. Densities are exp(-h / H); optical depths come from a table.
-- Radiance is in units where a Lambert surface of albedo A facing the sun at the top of
-- the atmosphere has radiance A (sun irradiance = pi).
--
-- WHY IT IS CHEAP. The scattered light of a ray through a spherical atmosphere depends
-- only on a handful of invariants, not on the camera, so it is tabulated once:
--   Miss rays (past the planet): (d0, a, b)  d0 = distance of the ray's closest approach
--     from the centre, a = s . v (sun against the ray), b = s . q (sun against the closest
--     point's direction). Table of RGB radiance (view-independent).
--   Hit rays (ending on the ground): (mu_v, mu_s, nu)  cosines of the view and sun against
--     the surface normal, nu = s . v. Table of RGB radiance.
--   Sunlight at the ground: transmittance and an ambient sky irradiance, both by mu_s.
-- A pixel then costs a trilinear lookup (about 150 operations) instead of a 16-step
-- integral (about 3000). Tables are built from the same integrator that the tests use as
-- reference; builders take slices so worker Actors can share the work.
--
-- TRUE BLACK. Nothing here adds a floor: where no sunlight reaches (the night side, the
-- shadow behind the planet), scattered radiance and ambient are exactly 0. `tonemap` maps
-- 0 to 0 (ACES fit) and sRGB encodes 0 as 0.

local Atmos = {}

export type Spec = {
	R: number, -- planet radius (studs)
	H: number, -- atmosphere height
	hr: number, -- Rayleigh scale height
	hm: number, -- Mie scale height
	tauR: { number }, -- Rayleigh optical depth of the vertical column at sea level (rgb)
	tauM: number, -- Mie scattering optical depth of the vertical column
	tauO: { number }, -- ozone absorption optical depth (rgb)
	ozoneCenter: number, -- height of the ozone layer's middle
	ozoneWidth: number,
	g: number, -- Mie asymmetry
	ms: number, -- second-order scattering strength (0 = single scattering only)
}

export type Model = {
	spec: Spec,
	R: number,
	H: number,
	Rt: number,
	bRr: number,
	bRg: number,
	bRb: number,
	bM: number,
	bMe: number,
	bOr: number,
	bOg: number,
	bOb: number,
	-- optical depth table
	NH: number,
	NU: number,
	od: { number }, -- 3 per entry: odR, odM, odO
	-- scattering tables (filled by the builders / install)
	ND: number,
	NA: number,
	NB: number,
	miss: buffer?, -- ND * NA * NB * 9 f32 (phase-free parts)
	tMiss: { number }?, -- ND * 3: transmittance along the whole chord
	NMV: number,
	NMS: number,
	NNU: number,
	hit: buffer?, -- NMV * NMS * NNU * 9 f32 (phase-free parts)
	NAM: number,
	amb: { number }?, -- NAM * 3: sky irradiance on the ground by mu_s (already / pi)
	steps: number,
}

local sqrt, exp, floor = math.sqrt, math.exp, math.floor
local PI = math.pi

function Atmos.terra(): Spec
	return {
		R = 1600,
		H = 130,
		hr = 26,
		hm = 9,
		tauR = { 0.0464 * 1.15, 0.108 * 1.15, 0.265 * 1.15 },
		tauM = 0.03,
		tauO = { 0.0045, 0.013, 0.0006 },
		ozoneCenter = 40,
		ozoneWidth = 30,
		g = 0.78,
		ms = 0.22,
	}
end

function Atmos.saturnia(): Spec
	return {
		R = 2400,
		H = 90,
		hr = 22,
		hm = 8,
		tauR = { 0.03, 0.04, 0.05 },
		tauM = 0.02,
		tauO = { 0, 0, 0 },
		ozoneCenter = 30,
		ozoneWidth = 20,
		g = 0.7,
		ms = 0.3,
	}
end

----------------------------------------------------------------------------------------
-- optical depth table
----------------------------------------------------------------------------------------

local function ozoneDensity(M: Model, h: number): number
	local w = M.spec.ozoneWidth
	local d = (h - M.spec.ozoneCenter) / w
	if d < 0 then
		d = -d
	end
	return if d < 1 then 1 - d else 0
end

-- cosine of the horizon at altitude h (rays with a smaller cosine hit the planet)
local function muHorizon(M: Model, h: number): number
	local r = M.R + h
	local q = 1 - (M.R * M.R) / (r * r)
	return -sqrt(if q > 0 then q else 0)
end

-- Direct integral of the three optical depths along a ray from altitude h with cosine mu
-- to the top of the atmosphere (midpoint rule, n steps).
local function opticalDepthDirect(M: Model, h: number, mu: number, n: number): (number, number, number)
	local r0 = M.R + h
	local disc = r0 * r0 * (mu * mu - 1) + M.Rt * M.Rt
	if disc <= 0 then
		return 0, 0, 0
	end
	local len = -r0 * mu + sqrt(disc)
	if len <= 0 then
		return 0, 0, 0
	end
	local ds = len / n
	local hr, hm = M.spec.hr, M.spec.hm
	local R = M.R
	local aR, aM, aO = 0, 0, 0
	for k = 0, n - 1 do
		local s = (k + 0.5) * ds
		local r2 = r0 * r0 + 2 * r0 * mu * s + s * s
		local alt = sqrt(if r2 > 0 then r2 else 0) - R
		if alt < 0 then
			alt = 0
		end
		aR += exp(-alt / hr)
		aM += exp(-alt / hm)
		aO += ozoneDensity(M, alt)
	end
	return aR * ds, aM * ds, aO * ds
end
Atmos.opticalDepthDirect = opticalDepthDirect

local function hOf(M: Model, i: number): number
	local u = i / (M.NH - 1)
	return M.H * u * u
end

-- table coordinate of a cosine at altitude h: u in [0, 1], 0 at the horizon
local function uOfMu(M: Model, h: number, mu: number): number
	local mh = muHorizon(M, h)
	local t = (mu - mh) / (1 - mh)
	if t < 0 then
		t = 0
	elseif t > 1 then
		t = 1
	end
	return sqrt(t)
end

function Atmos.new(spec: Spec, quality: number?): Model
	local q = quality or 1
	local hr, hm = spec.hr, spec.hm
	local M: Model = {
		spec = spec,
		R = spec.R,
		H = spec.H,
		Rt = spec.R + spec.H,
		bRr = spec.tauR[1] / hr,
		bRg = spec.tauR[2] / hr,
		bRb = spec.tauR[3] / hr,
		bM = spec.tauM / hm,
		bMe = spec.tauM / hm * 1.11,
		bOr = spec.tauO[1] / (spec.ozoneWidth * 1.0),
		bOg = spec.tauO[2] / (spec.ozoneWidth * 1.0),
		bOb = spec.tauO[3] / (spec.ozoneWidth * 1.0),
		NH = 32,
		NU = 96,
		od = {},
		ND = math.max(8, floor(28 * q)),
		NA = math.max(6, floor(16 * q)),
		NB = math.max(8, floor(24 * q)),
		miss = nil,
		tMiss = nil,
		NMV = math.max(6, floor(16 * q)),
		NMS = math.max(10, floor(32 * q)),
		NNU = math.max(6, floor(16 * q)),
		hit = nil,
		NAM = math.max(16, floor(64 * q)),
		amb = nil,
		steps = math.max(12, floor(24 * q)),
	}
	local od = M.od
	local n = 0
	for i = 0, M.NH - 1 do
		local h = hOf(M, i)
		local mh = muHorizon(M, h)
		for j = 0, M.NU - 1 do
			local u = j / (M.NU - 1)
			local mu = mh + (1 - mh) * u * u
			local a, b, c = opticalDepthDirect(M, h, mu, 48)
			od[n + 1], od[n + 2], od[n + 3] = a, b, c
			n += 3
		end
	end
	return M
end

-- Optical depths (Rayleigh, Mie, ozone: path integrals of the density profiles, in studs)
-- from altitude h along cosine mu to space, by bilinear lookup.
local function odLookup(M: Model, h: number, mu: number): (number, number, number)
	if h < 0 then
		h = 0
	elseif h > M.H then
		h = M.H
	end
	local fi = sqrt(h / M.H) * (M.NH - 1)
	local i = floor(fi)
	if i > M.NH - 2 then
		i = M.NH - 2
	end
	local fy = fi - i
	-- the two altitude rows have different horizons: look each up with its own u
	local u0 = uOfMu(M, hOf(M, i), mu)
	local u1 = uOfMu(M, hOf(M, i + 1), mu)
	local NU = M.NU
	local od = M.od
	local f0 = u0 * (NU - 1)
	local j0 = floor(f0)
	if j0 > NU - 2 then
		j0 = NU - 2
	end
	local gx0 = f0 - j0
	local f1 = u1 * (NU - 1)
	local j1 = floor(f1)
	if j1 > NU - 2 then
		j1 = NU - 2
	end
	local gx1 = f1 - j1
	local a0 = (i * NU + j0) * 3
	local a1 = (i * NU + j0 + 1) * 3
	local b0 = ((i + 1) * NU + j1) * 3
	local b1 = ((i + 1) * NU + j1 + 1) * 3
	local r0 = od[a0 + 1] + (od[a1 + 1] - od[a0 + 1]) * gx0
	local m0 = od[a0 + 2] + (od[a1 + 2] - od[a0 + 2]) * gx0
	local o0 = od[a0 + 3] + (od[a1 + 3] - od[a0 + 3]) * gx0
	local r1 = od[b0 + 1] + (od[b1 + 1] - od[b0 + 1]) * gx1
	local m1 = od[b0 + 2] + (od[b1 + 2] - od[b0 + 2]) * gx1
	local o1 = od[b0 + 3] + (od[b1 + 3] - od[b0 + 3]) * gx1
	return r0 + (r1 - r0) * fy, m0 + (m1 - m0) * fy, o0 + (o1 - o0) * fy
end
Atmos.odLookup = odLookup

-- Transmittance (rgb) of sunlight reaching altitude h whose local sun cosine is mu; 0 when
-- the planet blocks the sun.
local function sunT(M: Model, h: number, mu: number): (number, number, number)
	if mu <= muHorizon(M, h) then
		return 0, 0, 0
	end
	local a, b, c = odLookup(M, h, mu)
	return exp(-(M.bRr * a + M.bMe * b + M.bOr * c)), exp(-(M.bRg * a + M.bMe * b + M.bOg * c)), exp(-(M.bRb * a + M.bMe * b + M.bOb * c))
end
Atmos.sunT = sunT

local function phaseR(c: number): number
	return 3 / (16 * PI) * (1 + c * c)
end

local function phaseM(g: number, c: number): number
	local g2 = g * g
	local d = 1 + g2 - 2 * g * c
	return (1 - g2) / (4 * PI * d * sqrt(d))
end
Atmos.phaseR, Atmos.phaseM = phaseR, phaseM

----------------------------------------------------------------------------------------
-- the integrator (shared by the tables and the tests)
----------------------------------------------------------------------------------------

-- A ray's scattered light splits into three phase-free parts, each rgb:
--   R  Rayleigh single scattering per unit Rayleigh phase
--   M  Mie single scattering per unit Mie phase
--   I  the isotropic second-order term
-- so the radiance is pi (phaseR(nu) R + phaseM(nu) M + I). Tabulating the parts keeps the
-- sharp Mie lobe out of the tables: the phase is applied analytically at lookup.
export type Parts = { number } -- R rgb, M rgb, I rgb (9 numbers)

-- Parts and chord transmittance of a ray that misses the planet: closest approach d0
-- (>= R), a = s . v, b = s . q. `steps` samples along the chord.
local function missParts(M: Model, d0: number, a: number, b: number, steps: number): (Parts, number, number, number)
	local c2 = 1 - a * a - b * b
	if c2 < 0 then
		local bl = sqrt(1 - a * a)
		b = if b > 0 then bl else -bl
	end
	local Rt, R = M.Rt, M.R
	local t2 = Rt * Rt - d0 * d0
	if t2 <= 0 then
		return { 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 1, 1, 1
	end
	local tmax = sqrt(t2)
	local ds = 2 * tmax / steps
	local hr, hm = M.spec.hr, M.spec.hm
	local ms = M.spec.ms
	local oR, oM, oO = 0, 0, 0
	local Rr, Rg, Rb, Mr, Mg, Mb, Ir, Ig, Ib = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local bRr, bRg, bRb, bM, bMe = M.bRr, M.bRg, M.bRb, M.bM, M.bMe
	local bOr, bOg, bOb = M.bOr, M.bOg, M.bOb
	local d02 = d0 * d0
	for k = 0, steps - 1 do
		local t = -tmax + (k + 0.5) * ds
		local r = sqrt(d02 + t * t)
		local h = r - R
		if h < 0 then
			h = 0
		end
		local rhoR, rhoM, rhoO = exp(-h / hr), exp(-h / hm), ozoneDensity(M, h)
		local dR, dM, dO = rhoR * ds, rhoM * ds, rhoO * ds
		local vR, vM, vO = oR + dR * 0.5, oM + dM * 0.5, oO + dO * 0.5
		local tvr = exp(-(bRr * vR + bMe * vM + bOr * vO))
		local tvg = exp(-(bRg * vR + bMe * vM + bOg * vO))
		local tvb = exp(-(bRb * vR + bMe * vM + bOb * vO))
		local mus = (d0 * b + t * a) / r
		local sr, sg, sb = sunT(M, h, mus)
		if sr > 0 or sg > 0 or sb > 0 then
			local iso = ms / (4 * PI) * (rhoR + rhoM * bM / bRb * 0.4)
			Rr += tvr * rhoR * bRr * sr * ds
			Rg += tvg * rhoR * bRg * sg * ds
			Rb += tvb * rhoR * bRb * sb * ds
			Mr += tvr * rhoM * bM * sr * ds
			Mg += tvg * rhoM * bM * sg * ds
			Mb += tvb * rhoM * bM * sb * ds
			Ir += tvr * iso * bRr * sr ^ 0.45 * ds
			Ig += tvg * iso * bRg * sg ^ 0.45 * ds
			Ib += tvb * iso * bRb * sb ^ 0.45 * ds
		end
		oR += dR
		oM += dM
		oO += dO
	end
	return { Rr * PI, Rg * PI, Rb * PI, Mr * PI, Mg * PI, Mb * PI, Ir * PI, Ig * PI, Ib * PI },
		exp(-(bRr * oR + bMe * oM + bOr * oO)),
		exp(-(bRg * oR + bMe * oM + bOg * oO)),
		exp(-(bRb * oR + bMe * oM + bOb * oO))
end
Atmos.missParts = missParts

local function compose(M: Model, p: Parts, nu: number): (number, number, number)
	local pr, pm = phaseR(nu), phaseM(M.spec.g, nu)
	return pr * p[1] + pm * p[4] + p[7], pr * p[2] + pm * p[5] + p[8], pr * p[3] + pm * p[6] + p[9]
end

-- Radiance (rgb) and chord transmittance of a ray that misses the planet.
local function missRay(M: Model, d0: number, a: number, b: number, steps: number): (number, number, number, number, number, number)
	local parts, tr, tg, tb = missParts(M, d0, a, b, steps)
	local r, g, bl = compose(M, parts, a)
	return r, g, bl, tr, tg, tb
end
Atmos.missRay = missRay

-- Parts of a ray that ends on the ground: mu_v = -n . v (> 0), mu_s = n . s, nu = s . v.
local function hitParts(M: Model, muv: number, mus0: number, nu: number, steps: number): Parts
	if muv < 1e-4 then
		muv = 1e-4
	end
	local R, Rt = M.R, M.Rt
	local len = -R * muv + sqrt(R * R * (muv * muv - 1) + Rt * Rt)
	if len <= 0 then
		return { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	end
	local ds = len / steps
	local hr, hm = M.spec.hr, M.spec.hm
	local ms = M.spec.ms
	local oR, oM, oO = 0, 0, 0
	local Rr, Rg, Rb, Mr, Mg, Mb, Ir, Ig, Ib = 0, 0, 0, 0, 0, 0, 0, 0, 0
	local bRr, bRg, bRb, bM, bMe = M.bRr, M.bRg, M.bRb, M.bM, M.bMe
	local bOr, bOg, bOb = M.bOr, M.bOg, M.bOb
	for k = 0, steps - 1 do
		-- from the top of the atmosphere down to the ground
		local sd = len - (k + 0.5) * ds
		local r2 = R * R + 2 * R * muv * sd + sd * sd
		local r = sqrt(r2)
		local h = r - R
		if h < 0 then
			h = 0
		end
		local rhoR, rhoM, rhoO = exp(-h / hr), exp(-h / hm), ozoneDensity(M, h)
		local dR, dM, dO = rhoR * ds, rhoM * ds, rhoO * ds
		local vR, vM, vO = oR + dR * 0.5, oM + dM * 0.5, oO + dO * 0.5
		local tvr = exp(-(bRr * vR + bMe * vM + bOr * vO))
		local tvg = exp(-(bRg * vR + bMe * vM + bOg * vO))
		local tvb = exp(-(bRb * vR + bMe * vM + bOb * vO))
		-- (P . s) / r with P = R z + (-v) sd: R mu_s - sd nu
		local mus = (R * mus0 - sd * nu) / r
		local sr, sg, sb = sunT(M, h, mus)
		if sr > 0 or sg > 0 or sb > 0 then
			local iso = ms / (4 * PI) * (rhoR + rhoM * bM / bRb * 0.4)
			Rr += tvr * rhoR * bRr * sr * ds
			Rg += tvg * rhoR * bRg * sg * ds
			Rb += tvb * rhoR * bRb * sb * ds
			Mr += tvr * rhoM * bM * sr * ds
			Mg += tvg * rhoM * bM * sg * ds
			Mb += tvb * rhoM * bM * sb * ds
			Ir += tvr * iso * bRr * sr ^ 0.45 * ds
			Ig += tvg * iso * bRg * sg ^ 0.45 * ds
			Ib += tvb * iso * bRb * sb ^ 0.45 * ds
		end
		oR += dR
		oM += dM
		oO += dO
	end
	return { Rr * PI, Rg * PI, Rb * PI, Mr * PI, Mg * PI, Mb * PI, Ir * PI, Ig * PI, Ib * PI }
end
Atmos.hitParts = hitParts

-- Radiance (rgb) of a ray that ends on the ground.
local function hitRay(M: Model, muv: number, mus0: number, nu: number, steps: number): (number, number, number)
	return compose(M, hitParts(M, muv, mus0, nu, steps), nu)
end
Atmos.hitRay = hitRay

-- Transmittance (rgb) of the whole column from the ground to space along cosine mu_v.
function Atmos.columnT(M: Model, muv: number): (number, number, number)
	local a, b, c = odLookup(M, 0, if muv < 1e-4 then 1e-4 else muv)
	return exp(-(M.bRr * a + M.bMe * b + M.bOr * c)), exp(-(M.bRg * a + M.bMe * b + M.bOg * c)), exp(-(M.bRb * a + M.bMe * b + M.bOb * c))
end

-- Sky radiance (rgb) seen from altitude h0 (inside the atmosphere) along a unit direction
-- with elevation cosine `mu` (against the local up) and sun cosines: sunUp = s . up and
-- the scattering cosine `nu` = s . v. Direct integration, for the ambient table and for
-- deriving the engine's atmosphere settings.
function Atmos.skyRay(M: Model, h0: number, mu: number, sunUp: number, nu: number, steps: number): (number, number, number)
	local R, Rt = M.R, M.Rt
	local r0 = R + h0
	local disc = r0 * r0 * (mu * mu - 1) + Rt * Rt
	if disc <= 0 then
		return 0, 0, 0
	end
	local len = -r0 * mu + sqrt(disc)
	-- a ray that meets the ground stops there
	local hitG = r0 * r0 * (mu * mu - 1) + R * R
	if mu < 0 and hitG >= 0 then
		len = -r0 * mu - sqrt(hitG)
	end
	if len <= 0 then
		return 0, 0, 0
	end
	local ds = len / steps
	local hr, hm = M.spec.hr, M.spec.hm
	local g = M.spec.g
	local pR, pM = phaseR(nu), phaseM(g, nu)
	local ms = M.spec.ms
	local oR, oM, oO = 0, 0, 0
	local Lr, Lg, Lb = 0, 0, 0
	local bRr, bRg, bRb, bM, bMe = M.bRr, M.bRg, M.bRb, M.bM, M.bMe
	local bOr, bOg, bOb = M.bOr, M.bOg, M.bOb
	for k = 0, steps - 1 do
		local s = (k + 0.5) * ds
		local r = sqrt(r0 * r0 + 2 * r0 * mu * s + s * s)
		local h = r - R
		if h < 0 then
			h = 0
		end
		local rhoR, rhoM, rhoO = exp(-h / hr), exp(-h / hm), ozoneDensity(M, h)
		local dR, dM, dO = rhoR * ds, rhoM * ds, rhoO * ds
		local vR, vM, vO = oR + dR * 0.5, oM + dM * 0.5, oO + dO * 0.5
		local tvr = exp(-(bRr * vR + bMe * vM + bOr * vO))
		local tvg = exp(-(bRg * vR + bMe * vM + bOg * vO))
		local tvb = exp(-(bRb * vR + bMe * vM + bOb * vO))
		-- local sun cosine: (P . s) / r, P = r0 up + v s, with up . s = sunUp and v . s = nu
		local mus = (r0 * sunUp + s * nu) / r
		local sr, sg, sb = sunT(M, h, mus)
		if sr > 0 or sg > 0 or sb > 0 then
			local mie = rhoM * bM * pM
			local fr = rhoR * bRr * pR + mie
			local fg = rhoR * bRg * pR + mie
			local fb = rhoR * bRb * pR + mie
			local iso = ms / (4 * PI) * (rhoR + rhoM * bM / bRb * 0.4)
			Lr += tvr * (fr * sr + iso * bRr * sr ^ 0.45) * ds
			Lg += tvg * (fg * sg + iso * bRg * sg ^ 0.45) * ds
			Lb += tvb * (fb * sb + iso * bRb * sb ^ 0.45) * ds
		end
		oR += dR
		oM += dM
		oO += dO
	end
	return Lr * PI, Lg * PI, Lb * PI
end

----------------------------------------------------------------------------------------
-- table builders (slices, so workers can share the work)
----------------------------------------------------------------------------------------

local function dOf(M: Model, i: number): number
	local u = i / (M.ND - 1)
	return M.R + M.H * u * u * 0.9999 + 1e-3
end

local function writeParts(buf: buffer, n: number, p: Parts)
	for q = 1, 9 do
		buffer.writef32(buf, (n + q - 1) * 4, p[q])
	end
end

-- d0 rows [i0, i1) of the miss table: an f32 buffer of (i1 - i0) * NA * NB * 9 numbers.
function Atmos.buildMiss(M: Model, i0: number, i1: number): buffer
	local out = buffer.create((i1 - i0) * M.NA * M.NB * 9 * 4)
	local n = 0
	for i = i0, i1 - 1 do
		local d0 = dOf(M, i)
		for j = 0, M.NA - 1 do
			-- a = cos(angle) with the angle uniform: dense where the sun is along the ray, where
			-- the planet's shadow edge makes the radiance change fastest
			local ang = math.pi * j / (M.NA - 1)
			local a = math.cos(ang)
			local bl = math.sin(ang)
			for k = 0, M.NB - 1 do
				local b = bl * (-1 + 2 * k / (M.NB - 1)) -- b in its feasible interval
				local parts = missParts(M, d0, a, b, M.steps)
				writeParts(out, n, parts)
				n += 9
			end
		end
	end
	return out
end

-- Chord transmittance per d0 row (rgb); cheap.
function Atmos.buildChord(M: Model): { number }
	local out = table.create(M.ND * 3, 0)
	for i = 0, M.ND - 1 do
		local _, tr, tg, tb = missParts(M, dOf(M, i), 1, 0, 8)
		out[i * 3 + 1], out[i * 3 + 2], out[i * 3 + 3] = tr, tg, tb
	end
	return out
end

local function muvOf(M: Model, i: number): number
	local u = i / (M.NMV - 1)
	return 0.02 + 0.98 * u * u -- dense near grazing views
end

local function musOf(M: Model, j: number): number
	local u = j / (M.NMS - 1) * 2 - 1
	-- dense around the terminator
	return if u < 0 then -(-u) ^ 0.7 else u ^ 0.7
end

-- mu_v rows [i0, i1) of the hit table: an f32 buffer of (i1 - i0) * NMS * NNU * 9 numbers.
-- The table is indexed by (mu_v, mu_s, tau) with tau in [-1, 1] the position of nu inside
-- its feasible interval, so that every entry is a real geometry (nu itself is not
-- independent of the other two cosines).
function Atmos.buildHit(M: Model, i0: number, i1: number): buffer
	local out = buffer.create((i1 - i0) * M.NMS * M.NNU * 9 * 4)
	local n = 0
	for i = i0, i1 - 1 do
		local muv = muvOf(M, i)
		local sinA = sqrt(1 - muv * muv)
		for j = 0, M.NMS - 1 do
			local mus = musOf(M, j)
			local lim = sqrt(math.max(0, 1 - mus * mus))
			for k = 0, M.NNU - 1 do
				local tau = -1 + 2 * k / (M.NNU - 1)
				local nu = tau * lim * sinA - muv * mus
				writeParts(out, n, hitParts(M, muv, mus, nu, M.steps))
				n += 9
			end
		end
	end
	return out
end

-- Ambient sky irradiance on the ground / pi (rgb) by mu_s: the radiance a white Lambert
-- surface of albedo 1 returns from the sky alone. Zero when no sunlit air is above.
function Atmos.buildAmbient(M: Model): { number }
	local out = table.create(M.NAM * 3, 0)
	local elevations = { 15 / 180 * PI, 45 / 180 * PI, 75 / 180 * PI }
	local dE = 30 / 180 * PI
	for i = 0, M.NAM - 1 do
		local mus = -1 + 2 * i / (M.NAM - 1)
		local sx = sqrt(math.max(0, 1 - mus * mus))
		local Er, Eg, Eb = 0, 0, 0
		for _, el in elevations do
			local sinE, cosE = math.sin(el), math.cos(el)
			for q = 0, 7 do
				local ph = (q + 0.5) * PI / 4
				-- v = (cosE cos ph, cosE sin ph, sinE); s = (sx, 0, mus)
				local nu = cosE * math.cos(ph) * sx + sinE * mus
				local r, g, b = Atmos.skyRay(M, 0, sinE, mus, nu, 14)
				local w = sinE * cosE * dE * (PI / 4)
				Er += r * w
				Eg += g * w
				Eb += b * w
			end
		end
		out[i * 3 + 1], out[i * 3 + 2], out[i * 3 + 3] = Er / PI, Eg / PI, Eb / PI
	end
	return out
end

-- Joins buffers (slices of a table, in order) into one.
function Atmos.concat(parts: { buffer }): buffer
	local total = 0
	for _, p in parts do
		total += buffer.len(p)
	end
	local out = buffer.create(total)
	local o = 0
	for _, p in parts do
		buffer.copy(out, o, p)
		o += buffer.len(p)
	end
	return out
end

-- Installs finished tables into the model.
function Atmos.install(M: Model, miss: buffer, chord: { number }, hit: buffer, amb: { number })
	assert(buffer.len(miss) == M.ND * M.NA * M.NB * 9 * 4, "miss table size")
	assert(#chord == M.ND * 3, "chord table size")
	assert(buffer.len(hit) == M.NMV * M.NMS * M.NNU * 9 * 4, "hit table size")
	assert(#amb == M.NAM * 3, "ambient table size")
	M.miss, M.tMiss, M.hit, M.amb = miss, chord, hit, amb
end

-- Builds every table inline (tests, serial fallback).
function Atmos.buildAll(M: Model)
	local miss = Atmos.buildMiss(M, 0, M.ND)
	local hit = Atmos.buildHit(M, 0, M.NMV)
	Atmos.install(M, miss, Atmos.buildChord(M), hit, Atmos.buildAmbient(M))
end

----------------------------------------------------------------------------------------
-- lookups
----------------------------------------------------------------------------------------

-- Radiance and chord transmittance for a ray that misses the planet (trilinear lookup of
-- the three phase-free parts, then the analytic phases).
function Atmos.lookMiss(M: Model, d0: number, a: number, b: number): (number, number, number, number, number, number)
	local tab = M.miss :: buffer
	local ch = M.tMiss :: { number }
	local u = sqrt(math.max(0, (d0 - M.R) / (M.H * 0.9999)))
	if u > 1 then
		return 0, 0, 0, 1, 1, 1
	end
	local fi = u * (M.ND - 1)
	local i = floor(fi)
	if i > M.ND - 2 then
		i = M.ND - 2
	end
	local fx = fi - i
	if a > 1 then
		a = 1
	elseif a < -1 then
		a = -1
	end
	local bl = sqrt(math.max(0, 1 - a * a))
	local bn = if bl > 1e-6 then b / bl else 0
	if bn > 1 then
		bn = 1
	elseif bn < -1 then
		bn = -1
	end
	local fj = math.acos(a) / PI * (M.NA - 1)
	local j = floor(fj)
	if j > M.NA - 2 then
		j = M.NA - 2
	end
	local fy = fj - j
	local fk = (bn + 1) * 0.5 * (M.NB - 1)
	local k = floor(fk)
	if k > M.NB - 2 then
		k = M.NB - 2
	end
	local fz = fk - k
	local NA, NB = M.NA, M.NB
	local P1, P2, P3, P4, P5, P6, P7, P8, P9 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for di = 0, 1 do
		local wi = if di == 0 then 1 - fx else fx
		for dj = 0, 1 do
			local wj = if dj == 0 then 1 - fy else fy
			local base = (((i + di) * NA + (j + dj)) * NB + k) * 36
			local w0 = wi * wj * (1 - fz)
			local w1 = wi * wj * fz
			P1 += buffer.readf32(tab, base) * w0 + buffer.readf32(tab, base + 36) * w1
			P2 += buffer.readf32(tab, base + 4) * w0 + buffer.readf32(tab, base + 40) * w1
			P3 += buffer.readf32(tab, base + 8) * w0 + buffer.readf32(tab, base + 44) * w1
			P4 += buffer.readf32(tab, base + 12) * w0 + buffer.readf32(tab, base + 48) * w1
			P5 += buffer.readf32(tab, base + 16) * w0 + buffer.readf32(tab, base + 52) * w1
			P6 += buffer.readf32(tab, base + 20) * w0 + buffer.readf32(tab, base + 56) * w1
			P7 += buffer.readf32(tab, base + 24) * w0 + buffer.readf32(tab, base + 60) * w1
			P8 += buffer.readf32(tab, base + 28) * w0 + buffer.readf32(tab, base + 64) * w1
			P9 += buffer.readf32(tab, base + 32) * w0 + buffer.readf32(tab, base + 68) * w1
		end
	end
	local pr, pm = phaseR(a), phaseM(M.spec.g, a)
	local c0, c1 = i * 3, (i + 1) * 3
	return pr * P1 + pm * P4 + P7,
		pr * P2 + pm * P5 + P8,
		pr * P3 + pm * P6 + P9,
		ch[c0 + 1] + (ch[c1 + 1] - ch[c0 + 1]) * fx,
		ch[c0 + 2] + (ch[c1 + 2] - ch[c0 + 2]) * fx,
		ch[c0 + 3] + (ch[c1 + 3] - ch[c0 + 3]) * fx
end

-- Radiance for a ray that ends on the ground.
function Atmos.lookHit(M: Model, muv: number, mus: number, nu: number): (number, number, number)
	local tab = M.hit :: buffer
	local NMV, NMS, NNU = M.NMV, M.NMS, M.NNU
	local uv = sqrt(math.max(0, (muv - 0.02) / 0.98))
	local fi = uv * (NMV - 1)
	local i = floor(fi)
	if i > NMV - 2 then
		i = NMV - 2
	end
	local fx = fi - i
	if mus > 1 then
		mus = 1
	elseif mus < -1 then
		mus = -1
	end
	local su = if mus < 0 then -((-mus) ^ (1 / 0.7)) else mus ^ (1 / 0.7)
	local fj = (su + 1) * 0.5 * (NMS - 1)
	local j = floor(fj)
	if j > NMS - 2 then
		j = NMS - 2
	end
	local fy = fj - j
	-- position of nu in its feasible interval for this geometry
	local sinA = sqrt(math.max(0, 1 - muv * muv))
	local lim = sqrt(math.max(0, 1 - mus * mus)) * sinA
	local tau = 0
	if lim > 1e-6 then
		tau = (nu + muv * mus) / lim
		if tau > 1 then
			tau = 1
		elseif tau < -1 then
			tau = -1
		end
	end
	local fk = (tau + 1) * 0.5 * (NNU - 1)
	local k = floor(fk)
	if k > NNU - 2 then
		k = NNU - 2
	end
	local fz = fk - k
	local P1, P2, P3, P4, P5, P6, P7, P8, P9 = 0, 0, 0, 0, 0, 0, 0, 0, 0
	for di = 0, 1 do
		local wi = if di == 0 then 1 - fx else fx
		for dj = 0, 1 do
			local wj = if dj == 0 then 1 - fy else fy
			local base = (((i + di) * NMS + (j + dj)) * NNU + k) * 36
			local w0 = wi * wj * (1 - fz)
			local w1 = wi * wj * fz
			P1 += buffer.readf32(tab, base) * w0 + buffer.readf32(tab, base + 36) * w1
			P2 += buffer.readf32(tab, base + 4) * w0 + buffer.readf32(tab, base + 40) * w1
			P3 += buffer.readf32(tab, base + 8) * w0 + buffer.readf32(tab, base + 44) * w1
			P4 += buffer.readf32(tab, base + 12) * w0 + buffer.readf32(tab, base + 48) * w1
			P5 += buffer.readf32(tab, base + 16) * w0 + buffer.readf32(tab, base + 52) * w1
			P6 += buffer.readf32(tab, base + 20) * w0 + buffer.readf32(tab, base + 56) * w1
			P7 += buffer.readf32(tab, base + 24) * w0 + buffer.readf32(tab, base + 60) * w1
			P8 += buffer.readf32(tab, base + 28) * w0 + buffer.readf32(tab, base + 64) * w1
			P9 += buffer.readf32(tab, base + 32) * w0 + buffer.readf32(tab, base + 68) * w1
		end
	end
	local pr, pm = phaseR(nu), phaseM(M.spec.g, nu)
	return pr * P1 + pm * P4 + P7, pr * P2 + pm * P5 + P8, pr * P3 + pm * P6 + P9
end

-- Sky irradiance / pi (rgb) on the ground for sun cosine mu_s.
function Atmos.ambient(M: Model, mus: number): (number, number, number)
	local tab = M.amb :: { number }
	local f = (mus + 1) * 0.5 * (M.NAM - 1)
	if f < 0 then
		f = 0
	end
	local i = floor(f)
	if i > M.NAM - 2 then
		i = M.NAM - 2
	end
	local t = f - i
	local a, b = i * 3, (i + 1) * 3
	return tab[a + 1] + (tab[b + 1] - tab[a + 1]) * t, tab[a + 2] + (tab[b + 2] - tab[a + 2]) * t, tab[a + 3] + (tab[b + 3] - tab[a + 3]) * t
end

-- Sunlight at altitude h with local sun cosine mu: rgb transmittance times 1 (the Lambert
-- convention: radiance of albedo-1 facing the sun).
function Atmos.sunlight(M: Model, h: number, mu: number): (number, number, number)
	return sunT(M, h, mu)
end

----------------------------------------------------------------------------------------
-- display
----------------------------------------------------------------------------------------

-- ACES filmic fit (Narkowicz): 0 maps to exactly 0.
local function aces(x: number): number
	if x <= 0 then
		return 0
	end
	local v = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
	return if v > 1 then 1 else v
end

-- sRGB encode of a linear value in [0, 1]; 0 -> 0.
local function srgb(v: number): number
	if v <= 0 then
		return 0
	end
	if v >= 1 then
		return 1
	end
	if v <= 0.0031308 then
		return v * 12.92
	end
	return 1.055 * v ^ (1 / 2.4) - 0.055
end

-- Linear HDR radiance (rgb) to 0..1 display values: exposure, filmic curve, sRGB.
function Atmos.tonemap(r: number, g: number, b: number, exposure: number): (number, number, number)
	return srgb(aces(r * exposure)), srgb(aces(g * exposure)), srgb(aces(b * exposure))
end

----------------------------------------------------------------------------------------
-- registry: one model per body in this Luau state (every worker Actor has its own)
----------------------------------------------------------------------------------------

-- Table quality used by the planets place (dims scale with it; tests use less).
Atmos.QUALITY = 1.5

Atmos.models = {} :: { [string]: Model }

function Atmos.specFor(id: string): Spec?
	if id == "terra" then
		return Atmos.terra()
	elseif id == "saturnia" then
		return Atmos.saturnia()
	end
	return nil
end

-- The installed model of a body, or nil.
function Atmos.get(id: string): Model?
	local M = Atmos.models[id]
	if M and M.miss then
		return M
	end
	return nil
end

-- Model of a body with its tables, built inline when absent (serial fallback, tests).
function Atmos.ensure(id: string, quality: number?): Model?
	local have = Atmos.get(id)
	if have then
		return have
	end
	local spec = Atmos.specFor(id)
	if not spec then
		return nil
	end
	local M = Atmos.new(spec, quality or Atmos.QUALITY)
	Atmos.buildAll(M)
	Atmos.models[id] = M
	return M
end

-- Installs tables sent by the table jobs (see PlanetJobs): creates the model if needed.
function Atmos.installFor(id: string, quality: number, miss: buffer, chord: { number }, hit: buffer, amb: { number }): boolean
	local spec = Atmos.specFor(id)
	if not spec then
		return false
	end
	local M = Atmos.new(spec, quality)
	Atmos.install(M, miss, chord, hit, amb)
	Atmos.models[id] = M
	return true
end

return Atmos
