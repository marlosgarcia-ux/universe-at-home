--!strict
-- Tests for planets/shared/Atmos: the optical-depth table against direct integration, the
-- scattering tables against a fine integrator, physical colour behaviour (blue sky, red
-- sunset, reddened terminator), exact zeros on the night side, and the display curve.
-- Run by tests/run.sh in the interpreter and with native code.

local Atmos = require("../planets/shared/Atmos")
local MyMath = require("../src/MyMath")

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local abs, sqrt = math.abs, math.sqrt
local function lum(r: number, g: number, b: number): number
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

local spec = Atmos.terra()
local M = Atmos.new(spec, 1.0)

-- 1. optical-depth table against direct integration, compared where it matters: in the
-- transmittance exp(-tau) of every channel (optical depths themselves are large near the
-- horizon, where a small relative error costs almost no light)
do
	local worst = 0
	for k = 1, 400 do
		local h = MyMath.rand2(k, 1, 5) ^ 2 * spec.H
		local mh = -sqrt(1 - (spec.R / (spec.R + h)) ^ 2)
		local mu = mh + (1 - mh) * MyMath.rand2(k, 2, 5)
		local ar, am, ao = Atmos.odLookup(M, h, mu)
		local dr, dm, dO = Atmos.opticalDepthDirect(M, h, mu, 400)
		local function tr(r: number, m: number, o: number, bR: number, bO: number): number
			return math.exp(-(bR * r + M.bMe * m + bO * o))
		end
		worst = math.max(
			worst,
			abs(tr(ar, am, ao, M.bRr, M.bOr) - tr(dr, dm, dO, M.bRr, M.bOr)),
			abs(tr(ar, am, ao, M.bRg, M.bOg) - tr(dr, dm, dO, M.bRg, M.bOg)),
			abs(tr(ar, am, ao, M.bRb, M.bOb) - tr(dr, dm, dO, M.bRb, M.bOb))
		)
	end
	check(worst < 0.012, string.format("table transmittance matches direct integration (worst error %.4f)", worst))
end

-- 2. a vertical column at sea level: the transmittance is exp(-tau) of the specification
do
	local tr, tg, tb = Atmos.columnT(M, 1)
	local cut = 1 - math.exp(-spec.H / spec.hr) -- the column stops at the top of the atmosphere
	local wantR = math.exp(-spec.tauR[1] * cut - spec.tauM * 1.11 * (1 - math.exp(-spec.H / spec.hm)) - spec.tauO[1])
	check(abs(tr - wantR) < 0.01, string.format("vertical red transmittance %.4f, want %.4f", tr, wantR))
	check(tr > tg and tg > tb and tb > 0.5, "the vertical column is bluer-absorbing: red passes most")
	-- a grazing path loses far more, red least
	local gr, gg, gb = Atmos.columnT(M, 0.02)
	check(gr < tr and gg < tg and gb < tb, "a grazing path is more opaque in every channel")
	check(gr > gg and gg > gb, "and still reddens (red passes most)")
	check(gb < 0.1 and gr > gb * 3, string.format("blue is nearly gone at the horizon (%.3f) while red survives (%.3f)", gb, gr))
end

-- 3. sunlight at the ground reddens towards the horizon and vanishes behind it
do
	local noonR, _, noonB = Atmos.sunlight(M, 0, 1)
	local lowR, _, lowB = Atmos.sunlight(M, 0, 0.05)
	check(lowR / lowB > noonR / noonB * 2, "low sun is much redder than noon sun")
	local zr, zg, zb = Atmos.sunlight(M, 0, -0.05)
	check(zr == 0 and zg == 0 and zb == 0, "the sun below the horizon gives exactly zero")
	local hr, hg, hb = Atmos.sunlight(M, 120, -0.2)
	check(hr > 0 and hg >= 0 and hb >= 0, "high air still sees a sun that has set for the ground")
end

-- 4. scattering tables against a fine integrator
Atmos.buildAll(M)
do
	local sumErr, n, worst = 0, 0, 0
	for k = 1, 300 do
		local d0 = spec.R + 1 + MyMath.rand2(k, 1, 6) * (spec.H - 2)
		local a = MyMath.rand2(k, 2, 6) * 2 - 1
		local bl = sqrt(1 - a * a)
		local b = (MyMath.rand2(k, 3, 6) * 2 - 1) * bl
		local lr, lg, lb = Atmos.lookMiss(M, d0, a, b)
		local rr, rg, rb = Atmos.missRay(M, d0, a, b, 240)
		local ref = lum(rr, rg, rb)
		local got = lum(lr, lg, lb)
		if ref > 0.02 then
			local e = abs(got - ref) / ref
			sumErr += e
			n += 1
			worst = math.max(worst, e)
		end
	end
	check(n > 100, "enough sunlit rays were compared (" .. n .. ")")
	check(sumErr / n < 0.02, string.format("miss table: mean error %.3f against 240-step integration", sumErr / n))
	check(worst < 0.3, string.format("miss table: worst error %.3f", worst))
end
do
	local sumErr, n = 0, 0
	for k = 1, 300 do
		local muv = 0.05 + MyMath.rand2(k, 1, 7) * 0.95
		local mus = MyMath.rand2(k, 2, 7) * 2 - 1
		local sinA = sqrt(1 - muv * muv)
		local lim = sqrt(math.max(0, 1 - mus * mus))
		local sx = (MyMath.rand2(k, 3, 7) * 2 - 1) * lim
		local nu = sx * sinA - muv * mus
		local lr, lg, lb = Atmos.lookHit(M, muv, mus, nu)
		local rr, rg, rb = Atmos.hitRay(M, muv, mus, nu, 240)
		local ref = lum(rr, rg, rb)
		if ref > 0.01 then
			sumErr += abs(lum(lr, lg, lb) - ref) / ref
			n += 1
		end
	end
	check(n > 80, "enough lit surface rays were compared (" .. n .. ")")
	check(sumErr / n < 0.03, string.format("hit table: mean error %.3f against 240-step integration", sumErr / n))
end

-- 5. colours: blue sky, red sunset, blue limb, chord transmittance
do
	-- looking 60 degrees from a high sun at the ground
	local r, g, b = Atmos.skyRay(M, 0, 0.8, 0.9, 0.5, 40)
	check(b > g and g > r and b > r * 1.8, string.format("a daytime sky is blue (%.3f %.3f %.3f)", r, g, b))
	-- along the horizon, at a setting sun, towards it
	local sr, _, sb = Atmos.skyRay(M, 0, 0.02, 0.03, 0.95, 40)
	check(sr > sb, string.format("the sky towards a setting sun is red (%.3f vs %.3f)", sr, sb))
	-- the limb of the planet lit from the side: blue
	local lr, lg, lb = Atmos.lookMiss(M, spec.R + 6, 0, 0.9)
	check(lb > lg and lg > lr and lum(lr, lg, lb) > 0.05, string.format("the lit limb glows blue (%.3f %.3f %.3f)", lr, lg, lb))
	-- thicker chords lose more light
	local _, _, _, t1 = Atmos.lookMiss(M, spec.R + 2, 0, 0.5)
	local _, _, _, t2 = Atmos.lookMiss(M, spec.R + spec.H * 0.8, 0, 0.5)
	check(t1 < t2 and t2 <= 1, "chord transmittance grows with the closest approach")
	-- looking towards a sun that is nearly behind the limb, the light has crossed a long
	-- slant path and Mie forward scattering adds haze: warm and red-heavy; looking away
	-- from the sun it is blue
	local fr, _, fb = Atmos.lookMiss(M, spec.R + 4, 0.95, 0.1)
	local br, _, bb = Atmos.lookMiss(M, spec.R + 4, -0.95, 0.1)
	check(fr / fb > 3 and bb > br, string.format("limb towards the sun is warm (r/b %.2f), away from it blue (r/b %.2f)", fr / fb, br / bb))
end

-- 6. true black: no light from the night side, exactly zero
do
	local ar, ag, ab = Atmos.ambient(M, -1)
	check(ar == 0 and ag == 0 and ab == 0, "ambient sky light with the sun directly below is exactly 0")
	local nr, ng, nb = Atmos.ambient(M, -0.7)
	check(nr == 0 and ng == 0 and nb == 0, "ambient at mu_s = -0.7 is exactly 0")
	local tr, tg, tb = Atmos.ambient(M, -0.2)
	check(lum(tr, tg, tb) > 0, "twilight: air above is still sunlit just past the terminator")
	local dr, dg, db = Atmos.ambient(M, 1)
	check(db > dg and dg > dr, "daytime ambient is blue")
	check(lum(dr, dg, db) < 0.35, string.format("ambient is a fraction of the sun's light (%.3f)", lum(dr, dg, db)))
	-- a hit ray on the night side
	local hr, hg, hb = Atmos.lookHit(M, 0.8, -0.9, 0)
	check(hr == 0 and hg == 0 and hb == 0, "scattered light towards a point deep in night is exactly 0")
	-- the display curve keeps black black
	local t0, t1, t2 = Atmos.tonemap(0, 0, 0, 1)
	check(t0 == 0 and t1 == 0 and t2 == 0, "tonemap(0) is exactly 0")
	local last = 0
	for k = 0, 200 do
		local v = Atmos.tonemap(k / 20, 0, 0, 1)
		check(v >= last and v <= 1, "tonemap is monotone and bounded")
		last = v
	end
end

-- 7. determinism of the display values of a fixed set of lookups (same bits in both runtimes)
do
	local h = 0x811C9DC5
	for k = 1, 60 do
		local d0 = spec.R + 1 + MyMath.rand2(k, 1, 8) * 100
		local a = MyMath.rand2(k, 2, 8) * 2 - 1
		local bl = sqrt(1 - a * a)
		local b = (MyMath.rand2(k, 3, 8) * 2 - 1) * bl
		local r, g, bb = Atmos.lookMiss(M, d0, a, b)
		local tr, tg, tb = Atmos.tonemap(r, g, bb, 1)
		h = MyMath.hash32(bit32.bxor(h, math.floor(tr * 255 + 0.5) + math.floor(tg * 255 + 0.5) * 256 + math.floor(tb * 255 + 0.5) * 65536))
	end
	check(h == 3254113296, "display values of fixed lookups equal in both runtimes: " .. h)
end

print("planets_atmos: " .. checks .. " checks passed")
