--!nonstrict
-- Stress and fuzz tests for src/MyMath.luau: exact integer arithmetic, hashing statistics,
-- noise Lipschitz bounds, the polynomial sine, exact colour division, signed-distance
-- primitives against independent references, smooth minimum properties, and the budget
-- allocator against exhaustive search.

local H = require("./Harness")
local MyMath = require("../../src/MyMath")
H.setLevel((...))

local TWO32 = 4294967296
local floor, abs, sqrt, max, min = math.floor, math.abs, math.sqrt, math.max, math.min

H.suite("mul32 against an independent limb reference", function()
	local rng = H.rng(1)
	local function ref(a: number, b: number): number
		local al, ah = a % 65536, a // 65536
		local bl, bh = b % 65536, b // 65536
		return (((ah * bl + al * bh) % 65536) * 65536 + al * bl) % TWO32
	end
	local edge = { 0, 1, 2, 3, 0xFFFF, 0x10000, 0x10001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 0xFFFFFFFF, 0x9E3779B1, 0x85EBCA77 }
	for _, a in edge do
		for _, b in edge do
			H.check(MyMath.mul32(a, b) == ref(a, b), "edge case %d * %d: got %d want %d", a, b, MyMath.mul32(a, b), ref(a, b))
			H.tick()
		end
	end
	for i = 1, H.n(300000) do
		local a, b = rng.u32(), rng.u32()
		if i % 5 == 0 then
			a = a % 65536
		elseif i % 7 == 0 then
			b = b % 256
		end
		local got = MyMath.mul32(a, b)
		H.check(got == ref(a, b), "%d * %d: got %d want %d", a, b, got, ref(a, b))
		if i % 53 == 0 then
			H.digest(got)
		end
		H.tick()
	end
end)

H.suite("hash32: avalanche, bijectivity and no sequential collisions", function()
	local POP = table.create(65536, 0)
	for i = 1, 65535 do
		POP[i + 1] = POP[i // 2 + 1] + i % 2
	end
	local function pop(x: number): number
		return POP[x % 65536 + 1] + POP[x // 65536 + 1]
	end
	local rng = H.rng(2)
	local S = H.n(2500)
	for bitIndex = 0, 31 do
		local total = 0
		local flipMask = 2 ^ bitIndex
		for _ = 1, S do
			local x = rng.u32()
			local y = bit32.bxor(x, flipMask)
			total += pop(bit32.bxor(MyMath.hash32(x), MyMath.hash32(y)))
		end
		local mean = total / S
		H.check(mean > 15.35 and mean < 16.65, "flipping input bit %d changes %.3f output bits on average", bitIndex, mean)
		H.digestFloat(mean)
		H.tick(S)
	end
	-- a bijection on 32-bit values: no two of the first N inputs may collide
	local N = H.n(250000)
	local seen = {}
	for i = 0, N - 1 do
		local v = MyMath.hash32(i)
		H.check(not seen[v], "hash32 collision: inputs %d and %d both give %d", i, seen[v] or -1, v)
		seen[v] = i
		if i % 997 == 0 then
			H.digest(v)
		end
	end
	H.tick(N)
end)

H.suite("hash2 and rand2: range, uniformity, neighbour independence", function()
	local rng = H.rng(3)
	local N = H.n(240000)
	local buckets = table.create(64, 0)
	local sumX, sumY, sumXY, sumXX, sumYY = 0, 0, 0, 0, 0
	for _ = 1, N do
		local x, y = rng.int(-9000, 9000), rng.int(-9000, 9000)
		local v = MyMath.rand2(x, y, 77)
		H.check(v >= 0 and v < 1, "rand2(%d,%d) = %.17g outside [0,1)", x, y, v)
		buckets[floor(v * 64) + 1] += 1
		local w = MyMath.rand2(x + 1, y, 77)
		sumX += v
		sumY += w
		sumXY += v * w
		sumXX += v * v
		sumYY += w * w
		if _ % 211 == 0 then
			H.digestFloat(v)
		end
	end
	local expect = N / 64
	local chi2 = 0
	for i = 1, 64 do
		chi2 += (buckets[i] - expect) ^ 2 / expect
	end
	H.check(chi2 < 115, "chi-square over 64 buckets is %.1f (63 degrees of freedom)", chi2)
	local cov = sumXY / N - (sumX / N) * (sumY / N)
	local corr = cov / sqrt((sumXX / N - (sumX / N) ^ 2) * (sumYY / N - (sumY / N) ^ 2))
	H.check(abs(corr) < 0.011, "neighbouring lattice points correlate: r = %.5f", corr)
	-- different seeds decorrelate the same lattice point
	local same = 0
	for i = 1, 2000 do
		if MyMath.hash2(i, -i, 1) == MyMath.hash2(i, -i, 2) then
			same += 1
		end
	end
	H.check(same == 0, "different seeds produced %d identical hashes", same)
	H.tick(N)
end)

H.suite("valueNoise2 and fbm2: range and Lipschitz bounds", function()
	local rng = H.rng(4)
	local L = MyMath.VALUE_NOISE_LIPSCHITZ
	local worst = 0
	for _ = 1, H.n(120000) do
		local px, py = rng.range(-500, 500), rng.range(-500, 500)
		local seed = rng.int(0, 100000)
		local delta = 10 ^ rng.range(-5, 0.3)
		local ang = rng.float() * 6.283185307179586
		local qx, qy = px + delta * math.cos(ang), py + delta * math.sin(ang)
		local a, b = MyMath.valueNoise2(px, py, seed), MyMath.valueNoise2(qx, qy, seed)
		H.check(a >= 0 and a < 1 and b >= 0 and b < 1, "noise out of [0,1): %.17g %.17g", a, b)
		local ratio = abs(a - b) / delta
		worst = max(worst, ratio)
		H.check(ratio <= L * (1 + 1e-3), "noise changes %.6f per unit, bound %.4f (at %.4f,%.4f seed %d delta %.3g)", ratio, L, px, py, seed, delta)
		if _ % 97 == 0 then
			H.digestFloat(a)
		end
		-- fbm2 reports its own bound
		if _ % 5 == 0 then
			local oct = rng.int(1, 6)
			local fa, lipA = MyMath.fbm2(px, py, seed, oct)
			local fb = MyMath.fbm2(qx, qy, seed, oct)
			H.check(abs(fa - fb) <= lipA * delta * (1 + 1e-3) + 1e-12, "fbm2 exceeds its own Lipschitz bound %.4f: change %.6g over %.3g", lipA, abs(fa - fb), delta)
		end
		H.tick()
	end
	H.check(worst > 0.5, "the bound test is not vacuous (worst ratio seen %.3f)", worst)
end)

H.suite("dsinTurns, dcosTurns: accuracy, symmetry, periodicity", function()
	local rng = H.rng(5)
	local worst = 0
	for i = 1, H.n(400000) do
		local t = if i % 4 == 0 then rng.range(-1e9, 1e9) elseif i % 4 == 1 then rng.range(-100, 100) else rng.range(-1, 1)
		local frac = t - floor(t)
		local ref = math.sin(6.283185307179586 * frac)
		local got = MyMath.dsinTurns(t)
		local err = abs(got - ref)
		worst = max(worst, err)
		H.check(err < 1e-11, "dsinTurns(%.17g) = %.17g, sin = %.17g, error %.3g", t, got, ref, err)
		if i % 4 ~= 0 then
			H.check(abs(MyMath.dsinTurns(-t) + got) < 1e-11, "dsinTurns is odd: t=%.6g", t)
			H.check(abs(MyMath.dsinTurns(t + 0.5) + got) < 1e-9, "half-turn shift negates: t=%.6g", t)
			local c = MyMath.dcosTurns(t)
			H.check(abs(c * c + got * got - 1) < 1e-9, "sin^2 + cos^2 = %.12f at t=%.6g", c * c + got * got, t)
		end
		if i % 101 == 0 then
			H.digest(floor(got * 2 ^ 40))
		end
		H.tick()
	end
	H.check(MyMath.dsinTurns(0) == 0 and MyMath.dsinTurns(0.5) == 0 or abs(MyMath.dsinTurns(0.5)) < 1e-12, "zeros of sine")
	H.check(abs(MyMath.dsinTurns(0.25) - 1) < 1e-11 and abs(MyMath.dsinTurns(0.75) + 1) < 1e-11, "peaks of sine")
end)

H.suite("div255 is round(t / 255) for every t in [0, 65025]", function()
	for t = 0, 65025 do
		local want = (2 * t + 255) // 510
		H.check(MyMath.div255(t) == want, "div255(%d) = %d want %d", t, MyMath.div255(t), want)
		H.digest(MyMath.div255(t))
	end
	H.tick(65026)
end)

-- Random star-shaped polygon around the origin (simple, possibly concave).
local function randomPolygon(rng, n: number, radius: number): { number }
	local angles = {}
	for i = 1, n do
		angles[i] = (i - 1 + rng.range(0.1, 0.9)) / n
	end
	local pts = {}
	for i = 1, n do
		local r = radius * rng.range(0.35, 1)
		table.insert(pts, r * MyMath.dcosTurns(angles[i]))
		table.insert(pts, r * MyMath.dsinTurns(angles[i]))
	end
	return pts
end

local function segDist(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local t = if len2 > 0 then ((px - ax) * dx + (py - ay) * dy) / len2 else 0
	t = if t < 0 then 0 elseif t > 1 then 1 else t
	local ex, ey = px - (ax + dx * t), py - (ay + dy * t)
	return sqrt(ex * ex + ey * ey)
end

local function insidePolygon(px: number, py: number, pts: { number }): boolean
	local c = false
	local n = #pts // 2
	local j = n
	for i = 1, n do
		local xi, yi, xj, yj = pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]
		if (yi > py) ~= (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi then
			c = not c
		end
		j = i
	end
	return c
end

H.suite("sdPolygon: exact distance and sign against brute force", function()
	local rng = H.rng(6)
	for p = 1, H.n(150) do
		local n = rng.int(3, 14)
		local pts = randomPolygon(rng, n, rng.range(5, 100))
		H.context(string.format("polygon %d with %d vertices", p, n))
		for _ = 1, 200 do
			local x, y = rng.range(-130, 130), rng.range(-130, 130)
			local best = math.huge
			for i = 1, n do
				local j = if i == n then 1 else i + 1
				best = min(best, segDist(x, y, pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]))
			end
			local d = MyMath.sdPolygon(x, y, pts)
			H.check(abs(abs(d) - best) < 1e-9, "|d| = %.12f, brute force distance %.12f at (%.4f, %.4f)", abs(d), best, x, y)
			if best > 1e-7 then
				H.check((d < 0) == insidePolygon(x, y, pts), "sign of d=%.6f disagrees with even-odd test at (%.4f, %.4f)", d, x, y)
			end
			if _ % 20 == 0 then
				H.digestFloat(d)
			end
			H.tick()
		end
	end
end)

H.suite("signed distance primitives are 1-Lipschitz", function()
	local rng = H.rng(7)
	local function lipschitz(name: string, f: (number, number) -> number, span: number, pairs: number)
		for _ = 1, pairs do
			local px, py = rng.range(-span, span), rng.range(-span, span)
			local delta = 10 ^ rng.range(-3, 1)
			local ang = rng.float() * 6.283185307179586
			local qx, qy = px + delta * math.cos(ang), py + delta * math.sin(ang)
			local da, db = f(px, py), f(qx, qy)
			H.check(abs(da - db) <= delta * (1 + 1e-9) + 1e-9, "%s: |d(p) - d(q)| = %.9g exceeds |p - q| = %.9g at (%.4f, %.4f)", name, abs(da - db), delta, px, py)
			H.tick()
		end
	end
	local pairs = H.n(6000)
	for _ = 1, H.n(25) do
		local cx, cy, r = rng.range(-50, 50), rng.range(-50, 50), rng.range(0.5, 60)
		lipschitz("circle", function(x, y)
			return MyMath.sdCircle(x, y, cx, cy, r)
		end, 150, pairs)
		local hx, hy = rng.range(1, 60), rng.range(1, 60)
		local rad = rng.range(0, min(hx, hy))
		lipschitz("roundBox", function(x, y)
			return MyMath.sdRoundBox(x, y, cx, cy, hx, hy, rad)
		end, 150, pairs)
		local ax, ay, bx, by = rng.range(-60, 60), rng.range(-60, 60), rng.range(-60, 60), rng.range(-60, 60)
		lipschitz("segment", function(x, y)
			return MyMath.sdSegment(x, y, ax, ay, bx, by, r * 0.3)
		end, 150, pairs)
		local poly = randomPolygon(rng, rng.int(3, 12), rng.range(5, 70))
		lipschitz("polygon", function(x, y)
			return MyMath.sdPolygon(x, y, poly)
		end, 150, pairs)
	end
	-- rounded box sign: inside iff within the inner box inflated by the corner radius
	for _ = 1, H.n(20000) do
		local hx, hy = rng.range(2, 40), rng.range(2, 40)
		local rad = rng.range(0, min(hx, hy))
		local x, y = rng.range(-60, 60), rng.range(-60, 60)
		local ix, iy = max(abs(x) - (hx - rad), 0), max(abs(y) - (hy - rad), 0)
		local expectInside = sqrt(ix * ix + iy * iy) < rad
		local d = MyMath.sdRoundBox(x, y, 0, 0, hx, hy, rad)
		if abs(d) > 1e-9 then
			H.check((d < 0) == expectInside, "roundBox sign wrong at (%.4f, %.4f), d=%.6f", x, y, d)
		end
		H.tick()
	end
end)

H.suite("smin: monotone, Lipschitz, bounded below the minimum, symmetric", function()
	local rng = H.rng(8)
	for _ = 1, H.n(150000) do
		local a, b, k = rng.range(-10, 10), rng.range(-10, 10), rng.range(0.01, 5)
		local s = MyMath.smin(a, b, k)
		H.check(s <= min(a, b) + 1e-12, "smin %.9f above min %.9f", s, min(a, b))
		H.check(s >= min(a, b) - k * 0.25 - 1e-12, "smin %.9f more than k/4 below min %.9f (k=%.3f)", s, min(a, b), k)
		H.check(abs(s - MyMath.smin(b, a, k)) < 1e-12, "smin not symmetric")
		local d = rng.range(1e-6, 1)
		local sa = MyMath.smin(a + d, b, k)
		H.check(sa >= s - 1e-12 and sa - s <= d + 1e-12, "smin not monotone and 1-Lipschitz in a: change %.3g for step %.3g", sa - s, d)
		local sb = MyMath.smin(a, b + d, k)
		H.check(sb >= s - 1e-12 and sb - s <= d + 1e-12, "smin not monotone and 1-Lipschitz in b")
		if _ % 211 == 0 then
			H.digestFloat(s)
		end
		H.tick()
	end
	-- k = 0 is the hard minimum
	H.check(MyMath.smin(1, 2, 0) == 1 and MyMath.smin(3, -2, 0) == -2, "smin with k = 0 is min")
end)

H.suite("allocate: budget respected, valid sizes, close to the exhaustive optimum", function()
	local rng = H.rng(9)
	local sizes = { 32, 64, 128, 256 }
	local worstRatio = 1
	local function benefit(demands, weights, result): number
		local b = 0
		for i = 1, #demands do
			local s = result[i]
			b += (weights and weights[i] or 1) * min(s * s, demands[i])
		end
		return b
	end
	for case = 1, H.n(400) do
		local n = rng.int(1, 4)
		local demands, weights = {}, {}
		for i = 1, n do
			demands[i] = floor(rng.range(100, 90000))
			weights[i] = rng.range(0.5, 3)
		end
		local budget = floor(rng.range(1000, 200000))
		local useWeights = rng.bool()
		local got = MyMath.allocate(demands, if useWeights then weights else nil, budget, sizes)
		H.context(string.format("case %d n=%d budget=%d", case, n, budget))
		local used = 0
		for i = 1, n do
			local s = got[i]
			H.check(s == 0 or table.find(sizes, s) ~= nil, "size %d is not allowed", s)
			used += s * s
		end
		H.check(used <= budget, "allocated %d of budget %d", used, budget)
		-- exhaustive optimum over all level combinations
		local best = 0
		local levels = table.create(n, 0)
		local function recurse(i: number, cost: number)
			if cost > budget then
				return
			end
			if i > n then
				local r = {}
				for k = 1, n do
					r[k] = if levels[k] == 0 then 0 else sizes[levels[k]]
				end
				best = max(best, benefit(demands, if useWeights then weights else nil, r))
				return
			end
			for l = 0, #sizes do
				levels[i] = l
				recurse(i + 1, cost + (if l == 0 then 0 else sizes[l] * sizes[l]))
			end
		end
		recurse(1, 0)
		local mine = benefit(demands, if useWeights then weights else nil, got)
		H.check(mine <= best + 1e-6, "greedy beat the exhaustive optimum: %.3f vs %.3f", mine, best)
		if best > 0 then
			worstRatio = min(worstRatio, mine / best)
		end
		H.digest(used)
		H.tick()
	end
	print(string.format("      allocate worst greedy / optimal benefit ratio over the sample: %.4f", worstRatio))
	H.check(worstRatio > 0.6, "greedy fell to %.3f of the optimum", worstRatio)
end)

H.runAll("mymath.stress")
