--!strict
-- Tests for ALLAN's applications (docs/LIQUID.md "Applications results"): LiquidMatte
-- (background removal), LiquidControl (X5) and LiquidTime (X1). Run by tests/run.sh in the
-- interpreter and with native code generation; every check asserts. Golden hashes are the
-- same constants in both runtimes (T7-style lockstep).

local LiquidMatte = require("../src/LiquidMatte")
local LiquidControl = require("../src/LiquidControl")
local MyMath = require("../src/MyMath")

local checks = 0
local function check(cond: boolean, msg: string)
	checks += 1
	if not cond then
		error("FAILED: " .. msg, 2)
	end
end

local GOLDEN = {
	matteNoisyGlobal = 596313464,
	matteNoisyFlood = 207166819,
	matteCleanGlobal = 2530977287,
	control = 3022354662,
}
local PRINT_GOLDEN = false

----------------------------------------------------------------------------------------
-- scenes: a green screen with a red disc and a green hole inside the disc
----------------------------------------------------------------------------------------

type Scene = {
	img: buffer,
	w: number,
	h: number,
	cov: buffer, -- f64 coverage of the annulus (disc minus hole)
	covDisc: buffer, -- f64 coverage of the whole disc (hole kept)
	dist: buffer, -- f64 signed distance to the annulus boundary (negative inside)
	key: { number },
	fg: { number },
}

type SceneOpts = {
	noiseBg: number?,
	noiseFg: number?,
	grad: number?,
	fg: { number }?,
	key: { number }?,
	seed: number?,
}

local function scene(w: number, h: number, o: SceneOpts): Scene
	local K = o.key or { 0, 177, 64 }
	local FG = o.fg or { 220, 30, 40 }
	local nb, nf, grad, seed = o.noiseBg or 0, o.noiseFg or 0, o.grad or 0, o.seed or 1
	local img = buffer.create(w * h * 4)
	local cov = buffer.create(w * h * 8)
	local covDisc = buffer.create(w * h * 8)
	local dist = buffer.create(w * h * 8)
	local cx, cy = w * 0.5, h * 0.5
	local R1, R2 = math.min(w, h) * 0.3, math.min(w, h) * 0.09
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local px, py = x + 0.5, y + 0.5
			local d1 = MyMath.sdCircle(px, py, cx, cy, R1)
			local d2 = MyMath.sdCircle(px, py, cx, cy, R2)
			local dA = math.max(d1, -d2)
			local c = math.clamp(0.5 - dA, 0, 1)
			local cD = math.clamp(0.5 - d1, 0, 1)
			local light = 1 - grad * (x / w)
			local ch = table.create(3, 0)
			for k = 1, 3 do
				local v = c * FG[k] + (1 - c) * K[k] * light
				local amp = if c > 0 then nf else nb
				if c > 0 and c < 1 then
					amp = (1 - c) * nb + c * nf
				end
				if amp > 0 then
					local a = math.floor(amp + 0.5)
					v += MyMath.hash2(x, y, seed * 7919 + k) % (2 * a + 1) - a
				end
				ch[k] = math.clamp(math.floor(v + 0.5), 0, 255)
			end
			local i = y * w + x
			buffer.writeu32(img, i * 4, ch[1] + ch[2] * 256 + ch[3] * 65536 + 255 * 16777216)
			buffer.writef64(cov, i * 8, c)
			buffer.writef64(covDisc, i * 8, cD)
			buffer.writef64(dist, i * 8, dA)
		end
	end
	return { img = img, w = w, h = h, cov = cov, covDisc = covDisc, dist = dist, key = K, fg = FG }
end

type Stats = { errAll: number, errAA: number, maxErr: number, farBg: number, farFg: number, partial: number, truePartial: number }

local function score(sc: Scene, A: buffer, cov: buffer, farRegions: boolean): Stats
	local n = sc.w * sc.h
	local errAll, errAA, nAA, maxErr, farBg, farFg, partial, truePartial = 0, 0, 0, 0, 0, 0, 0, 0
	for i = 0, n - 1 do
		local c = buffer.readf64(cov, i * 8)
		local a = buffer.readu8(A, i)
		local e = math.abs(a - 255 * c)
		errAll += e
		if e > maxErr then
			maxErr = e
		end
		if c > 0 and c < 1 then
			errAA += e
			nAA += 1
			truePartial += 1
		end
		if a > 0 and a < 255 then
			partial += 1
		end
		if farRegions then
			local d = buffer.readf64(sc.dist, i * 8)
			if d > 3 and a ~= 0 then
				farBg += 1
			elseif d < -3 and a ~= 255 then
				farFg += 1
			end
		end
	end
	return {
		errAll = errAll / n,
		errAA = errAA / math.max(nAA, 1),
		maxErr = maxErr,
		farBg = farBg,
		farFg = farFg,
		partial = partial,
		truePartial = truePartial,
	}
end

----------------------------------------------------------------------------------------
-- M1. key detection
----------------------------------------------------------------------------------------
do
	local sc = scene(160, 128, {})
	local key = LiquidMatte.detectKey(sc.img, sc.w, sc.h)
	check(key.r == 0 and key.g == 177 and key.b == 64, "clean key is the screen colour")
	check(key.noiseD == 0 and key.noiseStep == 0, "clean border has no noise")
	local sn = scene(160, 128, { noiseBg = 12, grad = 0.15 })
	local kn = LiquidMatte.detectKey(sn.img, sn.w, sn.h)
	check(kn.r <= 8 and math.abs(kn.g - 165) <= 14 and math.abs(kn.b - 59) <= 8, "noisy key near the screen colour")
	check(kn.noiseD > 0 and kn.share > 0.95, "noisy border measured as background")
	-- explicit keys and the integer metric
	local k2 = LiquidMatte.detectKey(sc.img, sc.w, sc.h, 1, MyMath.pack(10, 20, 30, 255))
	check(k2.r == 10 and k2.g == 20 and k2.b == 30, "explicit key")
	check(LiquidMatte.dqOf(MyMath.pack(0, 177, 64, 255), 0, 177, 64, 1) == 0, "Dq of the key is 0")
	-- the quadratic form equals rule 1 exactly
	local bad = 0
	for t = 1, 400 do
		local p = MyMath.hash2(t, 3, 11) % 16777216
		local kr, kg, kb = MyMath.hash2(t, 4, 11) % 256, MyMath.hash2(t, 5, 11) % 256, MyMath.hash2(t, 6, 11) % 256
		local wy = t % 65
		local A, B, C, D, E, F = LiquidMatte.quadForm(wy)
		local dr, dg, db = p % 256 - kr, (p // 256) % 256 - kg, (p // 65536) % 256 - kb
		local q = dr * (A * dr + D * dg + E * db) + dg * (B * dg + F * db) + C * db * db
		local dy = 77 * dr + 150 * dg + 29 * db
		local dcb = 128 * db - 43 * dr - 85 * dg
		local dcr = 128 * dr - 107 * dg - 21 * db
		if q ~= 4 * (dcb * dcb + dcr * dcr) + wy * dy * dy then
			bad += 1
		end
	end
	check(bad == 0, "quadratic form is exact")
end

----------------------------------------------------------------------------------------
-- M2. flood keeps the green hole, global keying removes it
----------------------------------------------------------------------------------------
do
	local sc = scene(192, 160, {})
	local _, Ag, ig = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local _, Af, iff = LiquidMatte.matte(sc.img, sc.w, sc.h, { flood = true })
	local centre = (sc.h // 2) * sc.w + sc.w // 2
	local ring = (sc.h // 2) * sc.w + sc.w // 2 + math.floor(math.min(sc.w, sc.h) * 0.2)
	check(buffer.readu8(Ag, centre) == 0, "global: hole removed")
	check(buffer.readu8(Af, centre) == 255, "flood: hole kept")
	check(buffer.readu8(Ag, ring) == 255 and buffer.readu8(Af, ring) == 255, "disc opaque in both modes")
	check(buffer.readu8(Ag, 0) == 0 and buffer.readu8(Af, 0) == 0, "screen transparent in both modes")
	check(ig.protected == 0 and iff.protected > 0, "only flood protects pixels")
	local sg = score(sc, Ag, sc.cov, false)
	local sf = score(sc, Af, sc.covDisc, false)
	check(sg.maxErr <= 5 and sf.maxErr <= 5, "both modes match their ground truth within 5/255")
end

----------------------------------------------------------------------------------------
-- M3. anti-aliased edges preserved (clean image)
----------------------------------------------------------------------------------------
do
	local sc = scene(256, 256, {})
	local _, A = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local _, Araw = LiquidMatte.matte(sc.img, sc.w, sc.h, { refine = false })
	local s, sr = score(sc, A, sc.cov, true), score(sc, Araw, sc.cov, true)
	check(s.maxErr <= 5, "clean AA: max alpha error <= 5 (" .. s.maxErr .. ")")
	check(s.errAA <= 1, "clean AA: mean error on anti-aliased pixels <= 1 (" .. s.errAA .. ")")
	check(s.partial == sr.partial, "refinement keeps the clean edge width")
	check(s.partial <= s.truePartial, "no edge widening")
	-- per crossing on the centre row: partial pixels before (coverage) and after (alpha)
	local y = sc.h // 2
	local crossTrue, crossOut = 0, 0
	local runsTrue, runsOut = 0, 0
	local inT, inO = false, false
	for x = 0, sc.w - 1 do
		local i = y * sc.w + x
		local c = buffer.readf64(sc.cov, i * 8)
		local a = buffer.readu8(A, i)
		local pt = c > 0.02 and c < 0.98
		local po = a > 0 and a < 255
		if pt then
			crossTrue += 1
		end
		if po then
			crossOut += 1
		end
		if pt and not inT then
			runsTrue += 1
		end
		if po and not inO then
			runsOut += 1
		end
		inT, inO = pt, po
	end
	check(runsOut == 4 and runsTrue == 4, "four edge crossings on the centre row")
	check(math.abs(crossOut - crossTrue) <= 2, "edge width per crossing preserved")
	check(s.farBg == 0 and s.farFg == 0, "clean: plateaus exact")
end

----------------------------------------------------------------------------------------
-- M4. noisy key background
----------------------------------------------------------------------------------------
do
	-- noise on the screen only
	local sc = scene(256, 256, { noiseBg = 16, grad = 0.15, seed = 3 })
	local _, A = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local _, Araw = LiquidMatte.matte(sc.img, sc.w, sc.h, { refine = false })
	local s, sr = score(sc, A, sc.cov, true), score(sc, Araw, sc.cov, true)
	check(s.farBg == 0 and s.farFg == 0, "noisy screen: far background 0 and far foreground 255")
	check(s.errAll <= sr.errAll, "refinement lowers the total error (" .. s.errAll .. " vs " .. sr.errAll .. ")")
	check(s.partial <= sr.partial, "refinement does not widen edges")
	-- noise everywhere
	local sn = scene(256, 256, { noiseBg = 12, noiseFg = 12, grad = 0.15, seed = 5 })
	local _, An = LiquidMatte.matte(sn.img, sn.w, sn.h, {})
	local _, Anr = LiquidMatte.matte(sn.img, sn.w, sn.h, { refine = false })
	local t, tr = score(sn, An, sn.cov, true), score(sn, Anr, sn.cov, true)
	check(t.farBg == 0 and t.farFg == 0, "noisy image: plateaus exact after refinement")
	check(tr.farBg > 0, "raw matte at this t0 has background specks for the refinement to remove")
	check(t.errAll < 0.75 * tr.errAll, "refinement cuts the total error by a quarter or more")
	check(t.partial < tr.partial, "noisy image: fewer partial pixels after refinement")
end

----------------------------------------------------------------------------------------
-- M5. despill: unmixing and the spill limiter remove the key hue
----------------------------------------------------------------------------------------
do
	local sc = scene(256, 256, {})
	local out, A, info = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local key = info.key
	local pFg = LiquidMatte.keyShare(MyMath.pack(sc.fg[1], sc.fg[2], sc.fg[3], 255), key)
	local worstIn, worstOut, maxDev, n = -1, -1, 0, 0
	for i = 0, sc.w * sc.h - 1 do
		local a = buffer.readu8(A, i)
		if a >= 40 and a <= 215 then
			n += 1
			local pin = LiquidMatte.keyShare(buffer.readu32(sc.img, i * 4), key)
			local o = buffer.readu32(out, i * 4)
			local pout = LiquidMatte.keyShare(o, key)
			worstIn = math.max(worstIn, pin)
			worstOut = math.max(worstOut, pout)
			for k = 1, 3 do
				local dev = math.abs((o // 256 ^ (k - 1)) % 256 - sc.fg[k])
				maxDev = math.max(maxDev, dev)
			end
		end
	end
	check(n > 100, "enough partial pixels")
	check(worstIn > pFg + 0.2, "mixed pixels carry the key hue")
	check(worstOut <= pFg + 0.02, "unmixed pixels carry no more key hue than the foreground")
	check(maxDev <= 6, "unmixing recovers the foreground colour within 6 (" .. maxDev .. ")")
	-- spill limiter on a foreground lit by green spill
	local sp = scene(192, 160, { fg = { 150, 190, 110 } })
	local o2, A2, i2 = LiquidMatte.matte(sp.img, sp.w, sp.h, { spill = 1 })
	local o3 = LiquidMatte.matte(sp.img, sp.w, sp.h, { spill = 0 })
	local before, after = -1, -1
	for i = 0, sp.w * sp.h - 1 do
		if buffer.readu8(A2, i) == 255 then
			before = math.max(before, LiquidMatte.keyShare(buffer.readu32(o3, i * 4), i2.key))
			after = math.max(after, LiquidMatte.keyShare(buffer.readu32(o2, i * 4), i2.key))
		end
	end
	check(before > 0.3, "spill-lit foreground leans to the key")
	check(after <= 0.01, "spill limiter removes the key hue (" .. after .. ")")
	-- luma is kept: the limiter moves colour along K - Y_K, which has zero luma
	local c = buffer.readu32(sp.img, ((sp.h // 2) * sp.w + sp.w // 2 + 40) * 4)
	local c2 = buffer.readu32(o2, ((sp.h // 2) * sp.w + sp.w // 2 + 40) * 4)
	local function luma(p: number): number
		return (77 * (p % 256) + 150 * ((p // 256) % 256) + 29 * ((p // 65536) % 256)) / 256
	end
	check(math.abs(luma(c) - luma(c2)) <= 1, "spill limiter keeps luma")
end

----------------------------------------------------------------------------------------
-- M6. alpha bleeding: transparent pixels carry visible colours, never the key
----------------------------------------------------------------------------------------
do
	local sc = scene(192, 160, { noiseBg = 6, seed = 9 })
	local out, A, info = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local visible: { [number]: boolean } = {}
	for i = 0, sc.w * sc.h - 1 do
		if buffer.readu8(A, i) > 0 then
			visible[buffer.readu32(out, i * 4) % 16777216] = true
		end
	end
	local keyRgb = info.key.color % 16777216
	local bad, keyed, adj, adjBad = 0, 0, 0, 0
	for y = 0, sc.h - 1 do
		for x = 0, sc.w - 1 do
			local i = y * sc.w + x
			if buffer.readu8(A, i) == 0 then
				local p = buffer.readu32(out, i * 4)
				check(p // 16777216 == 0, "transparent pixels keep alpha 0")
				local rgb = p % 16777216
				if not visible[rgb] then
					bad += 1
				end
				if rgb == keyRgb then
					keyed += 1
				end
				local l = x > 0 and buffer.readu8(A, i - 1) > 0
				local r = x < sc.w - 1 and buffer.readu8(A, i + 1) > 0
				if l or r then
					adj += 1
					local ok = (l and rgb == buffer.readu32(out, (i - 1) * 4) % 16777216)
						or (r and rgb == buffer.readu32(out, (i + 1) * 4) % 16777216)
					if not ok then
						adjBad += 1
					end
				end
			end
		end
	end
	check(bad == 0, "every transparent pixel carries a visible colour")
	check(keyed == 0, "no transparent pixel carries the key colour")
	check(adj > 0 and adjBad == 0, "pixels next to visible ones take that neighbour's colour")
end

----------------------------------------------------------------------------------------
-- M7. the three refinements agree bit for bit; rawMatte matches its definition
----------------------------------------------------------------------------------------
do
	local cases = 0
	for seed = 1, 8 do
		local w = 41 + (seed * 13) % 50
		local h = 33 + (seed * 7) % 40
		local nz = ({ 0, 6, 12, 20 })[seed % 4 + 1]
		local sc = scene(w, h, { noiseBg = nz, noiseFg = nz // 2, grad = 0.1, seed = seed })
		for _, flood in { false, true } do
			for _, mode in { "ratio", "ramp" } do
				local key = LiquidMatte.detectKey(sc.img, w, h)
				local P = LiquidMatte.params(key, { flood = flood, mode = mode })
				local field = LiquidMatte.distanceField(sc.img, w, h, key, P.t0)
				local e, _, lit = LiquidMatte.rawMatte(field, w, h, P)
				if flood then
					LiquidMatte.floodProtect(e, w, h, P.headroom)
				end
				local A1 = LiquidMatte.refineRuns(e, field.dq, w, h, P.tau, P.kMax, P.clip, lit, P.snap)
				local A2 = LiquidMatte.refineReference(e, field.dq, w, h, P.tau, P.kMax, P.clip, P.snap)
				local A3 = LiquidMatte.refine(e, field.dq, w, h, P.tau, P.kMax, P.clip, P.snap)
				check(LiquidMatte.hash(A1) == LiquidMatte.hash(A2), "refineRuns == reference")
				check(LiquidMatte.hash(A3) == LiquidMatte.hash(A2), "refine == reference")
				cases += 1
				if mode == "ratio" and not flood then
					-- rule 4 pixel by pixel
					local OFF = LiquidMatte.OFFSET
					local bgS, fgS = OFF - P.headroom, OFF + 255 + P.headroom
					local r = P.radius
					local bad = 0
					for y = 0, h - 1 do
						for x = 0, w - 1 do
							local d = buffer.readu16(field.dq, (y * w + x) * 2)
							local want
							if d <= P.t0 then
								want = bgS
							else
								local nearBg = false
								for yy = math.max(0, y - r), math.min(h - 1, y + r) do
									for xx = math.max(0, x - r), math.min(w - 1, x + r) do
										if buffer.readu16(field.dq, (yy * w + xx) * 2) <= P.t0 then
											nearBg = true
										end
									end
								end
								if not nearBg then
									want = fgS
								else
									want = LiquidMatte.ratioValue(field.dq, w, h, x, y, r, P.t0, P.t1, key.noiseD, fgS)
									local function bgAt(xx: number, yy: number): boolean
										if xx < 0 or xx >= w or yy < 0 or yy >= h then
											return true
										end
										return buffer.readu16(field.dq, (yy * w + xx) * 2) <= P.t0
									end
									if want <= P.speck + OFF and bgAt(x - 1, y) and bgAt(x + 1, y) and bgAt(x, y - 1) and bgAt(x, y + 1) then
										want = bgS
									end
								end
							end
							if buffer.readu16(e, (y * w + x) * 2) ~= want then
								bad += 1
							end
						end
					end
					check(bad == 0, "rawMatte equals rule 4 at every pixel (" .. bad .. " differ)")
				end
			end
		end
	end
	-- random planes with the generic literal structure
	for seed = 1, 24 do
		local w = 5 + (seed * 17) % 60
		local h = 3 + (seed * 11) % 30
		local e = buffer.create(w * h * 2 + 8)
		local dq = buffer.create(w * h * 2)
		local runLen = 1 + seed % 9
		for i = 0, w * h - 1 do
			local blk = i // runLen
			local r = MyMath.hash2(blk, seed, 99) % 100
			buffer.writeu16(e, i * 2, if r < 35 then 192 elseif r < 70 then 575 else MyMath.hash2(blk, seed, 1) % 900)
			buffer.writeu16(dq, i * 2, MyMath.hash2(i, seed, 3) % (50 + seed * 10))
		end
		local lit = LiquidMatte.literalsOf(e, w, h)
		for _, tau in { 1, 30, 120, 600 } do
			for _, snap in { 1 / 64, 0.5 } do
				local A1 = LiquidMatte.refineRuns(e, dq, w, h, tau, 1 + seed % 3, 3, lit, snap)
				local A2 = LiquidMatte.refineReference(e, dq, w, h, tau, 1 + seed % 3, 3, snap)
				check(LiquidMatte.hash(A1) == LiquidMatte.hash(A2), "random plane: refineRuns == reference")
				cases += 1
			end
		end
	end
	check(cases == 8 * 4 + 24 * 8, "all agreement cases ran")
end

----------------------------------------------------------------------------------------
-- M8. the liquid pass is a normalised recursive bilateral filter with hard cuts
----------------------------------------------------------------------------------------
do
	local tau, kMax = 40, 3
	local GT = LiquidMatte.gainTable(tau, kMax)
	for seed = 1, 20 do
		local n = 30 + seed
		local v, d = table.create(n, 0), table.create(n, 0)
		for i = 1, n do
			v[i] = MyMath.hash2(i, seed, 1) % 600
			d[i] = MyMath.hash2(i, seed, 2) % (if seed % 2 == 0 then 30 else 90)
		end
		-- exact linear recursion (snap 0): h = sum_j w_j v_j, w_j = g_j prod_{m > j} (1 - g_m)
		local hf = LiquidMatte.linePass(v, d, tau, kMax, 0, false)
		local g = table.create(n, 0)
		g[1] = 1
		for i = 2, n do
			local s = math.abs(d[i] - d[i - 1])
			g[i] = if s >= tau then 1 else GT[s + 1]
		end
		for x = 1, n do
			local sum, wsum = 0, 0
			for j = 1, x do
				local wj = g[j]
				for m = j + 1, x do
					wj *= 1 - g[m]
				end
				sum += wj * v[j]
				wsum += wj
			end
			check(math.abs(wsum - 1) <= 1e-12, "bilateral weights sum to one")
			check(math.abs(hf[x] - sum) <= 1e-9 * 600, "pass equals its weighted sum")
		end
		-- max principle and hard cuts with the default snap
		local h1 = LiquidMatte.linePass(v, d, tau, kMax)
		local lo: number = math.huge
		local hi: number = -math.huge
		for i = 1, n do
			local vi: number = v[i]
			if vi < lo then
				lo = vi
			end
			if vi > hi then
				hi = vi
			end
		end
		local cut = 0
		for i = 2, n do
			check(h1[i] >= lo and h1[i] <= hi, "max principle")
			if math.abs(d[i] - d[i - 1]) >= tau then
				cut = i
			end
		end
		if cut > 0 then
			local v2 = table.clone(v)
			for i = 1, cut - 1 do
				v2[i] = MyMath.hash2(i, seed, 77) % 900
			end
			local h2 = LiquidMatte.linePass(v2, d, tau, kMax)
			for i = cut, n do
				check(h2[i] == h1[i], "nothing crosses a hard pair (bit-exact)")
			end
		end
	end
	-- 2-D: a disc whose boundary pairs are all hard keeps its values whatever lies outside
	local w, h = 48, 40
	local dq = buffer.create(w * h * 2)
	local inside = buffer.create(w * h)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local ins = MyMath.sdCircle(x + 0.5, y + 0.5, 22, 19, 12) < 0
			buffer.writeu8(inside, y * w + x, if ins then 1 else 0)
			buffer.writeu16(dq, (y * w + x) * 2, (if ins then 1000 else 0) + MyMath.hash2(x, y, 4) % 20)
		end
	end
	local function fillE(seed: number): buffer
		local e = buffer.create(w * h * 2 + 8)
		for i = 0, w * h - 1 do
			local v = if buffer.readu8(inside, i) == 1 then 300 + MyMath.hash2(i, 1, 5) % 280 else MyMath.hash2(i, seed, 6) % 800
			buffer.writeu16(e, i * 2, v)
		end
		return e
	end
	local Aa = LiquidMatte.refineReference(fillE(1), dq, w, h, 100, 2, 3)
	local Ab = LiquidMatte.refineReference(fillE(2), dq, w, h, 100, 2, 3)
	local differOutside, differInside = 0, 0
	for i = 0, w * h - 1 do
		if buffer.readu8(Aa, i) ~= buffer.readu8(Ab, i) then
			if buffer.readu8(inside, i) == 1 then
				differInside += 1
			else
				differOutside += 1
			end
		end
	end
	check(differOutside > 0 and differInside == 0, "zero leak into a region bounded by hard pairs")
	-- fixed points: a pixel whose four pairs are hard keeps its own value
	local e = buffer.create(w * h * 2 + 8)
	local dq2 = buffer.create(w * h * 2)
	for i = 0, w * h - 1 do
		buffer.writeu16(e, i * 2, MyMath.hash2(i, 9, 9) % 700)
		local x, y = i % w, i // w
		buffer.writeu16(dq2, i * 2, if (x + y) % 2 == 0 then 0 else 500) -- checkerboard: all pairs hard
	end
	local Af = LiquidMatte.refineReference(e, dq2, w, h, 100, 3, 3)
	local fixedBad = 0
	for i = 0, w * h - 1 do
		if buffer.readu8(Af, i) ~= LiquidMatte.toByte(buffer.readu16(e, i * 2), 3) then
			fixedBad += 1
		end
	end
	check(fixedBad == 0, "pixels with four hard pairs are fixed points")
end

----------------------------------------------------------------------------------------
-- M9. determinism (both runtimes produce these constants)
----------------------------------------------------------------------------------------
do
	local sn = scene(200, 168, { noiseBg = 12, noiseFg = 8, grad = 0.15, seed = 21 })
	local og = LiquidMatte.matte(sn.img, sn.w, sn.h, {})
	local of = LiquidMatte.matte(sn.img, sn.w, sn.h, { flood = true, spill = 0.5 })
	local sc = scene(200, 168, { seed = 22 })
	local oc = LiquidMatte.matte(sc.img, sc.w, sc.h, {})
	local hg, hf, hc = LiquidMatte.hash(og), LiquidMatte.hash(of), LiquidMatte.hash(oc)
	if PRINT_GOLDEN then
		print("matteNoisyGlobal", hg, "matteNoisyFlood", hf, "matteCleanGlobal", hc)
	else
		check(hg == GOLDEN.matteNoisyGlobal, "golden hash: noisy global matte")
		check(hf == GOLDEN.matteNoisyFlood, "golden hash: noisy flood matte")
		check(hc == GOLDEN.matteCleanGlobal, "golden hash: clean matte")
	end
end

----------------------------------------------------------------------------------------
-- C. LiquidControl (X5)
----------------------------------------------------------------------------------------

type Run = { c: LiquidControl.Controller, rungs: { number }, times: { number }, preds: { number }, resid: { number } }

-- Plant: the frame at rung q takes load(t) * trueCost(q) ms; memory is exogenous(t) plus the
-- resident set.
local function runCtl(cfg: LiquidControl.Config, frames: number, loadAt: (number) -> number, trueCost: ((number) -> number)?, memAt: ((number) -> number)?): Run
	local c = LiquidControl.new(cfg)
	local rungs, times, preds, resid = {}, {}, {}, {}
	local q, R = c.rung, c.resident
	for t = 1, frames do
		local cost = if trueCost then trueCost(q) else c.ladder[q + 1].cost
		local ms = loadAt(t) * cost
		local mb = if memAt then memAt(t) + R * c.unit else nil
		local kn = LiquidControl.step(c, ms, mb)
		q, R = kn.rung, kn.resident
		rungs[t], times[t], preds[t], resid[t] = q, ms, c.load.pred, R
	end
	return { c = c, rungs = rungs, times = times, preds = preds, resid = resid }
end

local function reversalsFrom(seq: { number }, from: number): number
	local n, dir = 0, 0
	for t = from + 1, #seq do
		local d = seq[t] - seq[t - 1]
		if d ~= 0 then
			local s = if d > 0 then 1 else -1
			if dir ~= 0 and s ~= dir then
				n += 1
			end
			dir = s
		end
	end
	return n
end

local function lastChange(seq: { number }): number
	local last = 1
	for t = 2, #seq do
		if seq[t] ~= seq[t - 1] then
			last = t
		end
	end
	return last
end

-- C1. constant load: exact prediction, monotone knobs, bounded settling
do
	local Q = #LiquidControl.DEFAULT_LADDER
	-- a dyadic ladder makes ms / cost exact, so the samples are bit-identical and so is P
	local dyadic: { LiquidControl.Rung } = {}
	for i = 1, 8 do
		dyadic[i] = { epsilon = 1, level = 0, neurons = 8, cost = 2 ^ (i - 6) }
	end
	for _, L in { 0.75, 3, 5.5, 100 } do
		local r = runCtl({ ladder = dyadic, dwell = 4 }, 120, function(_t: number): number
			return L
		end)
		for t = 1, 120 do
			check(r.preds[t] == L, "dyadic ladder, constant load: prediction is exactly L")
		end
		check(r.c.load.j == 0 and reversalsFrom(r.rungs, 1) == 0, "dyadic ladder: no jitter, no oscillation")
	end
	for _, L in { 0.5, 1, 2.2, 3, 4, 7.5, 13, 30, 60 } do
		for _, start in { 0, 3, Q - 1 } do
			local r = runCtl({ start = start, dwell = 6 }, 200, function(_t: number): number
				return L
			end)
			for t = 1, 200 do
				check(math.abs(r.preds[t] - L) <= 1e-12 * L, "constant load: prediction is L (to rounding of ms / cost)")
			end
			check(r.c.load.surprises == 0, "constant load: no surprises")
			check(reversalsFrom(r.rungs, 1) == 0 and r.c.reversals == 0, "constant load: no oscillation")
			check(lastChange(r.rungs) <= 1 + 6 * (Q - 1), "constant load: settles within 1 + dwell (Q - 1) frames")
			-- the rung it settles on is the one the hysteresis defines
			local q = r.rungs[200]
			local cost = LiquidControl.DEFAULT_LADDER
			check(L * cost[q + 1].cost <= 0.9 * 4 or q == 0, "settled rung fits the budget")
			if start <= q then
				check(q == Q - 1 or L * cost[q + 2].cost > 0.6 * 4, "raised as far as the lower threshold allows")
			end
		end
	end
end

-- C2. steps: one-frame re-anchoring, settling bounds, no oscillation afterwards
do
	local Q = #LiquidControl.DEFAULT_LADDER
	for _, pair in { { 4, 12 }, { 12, 4 }, { 2, 30 }, { 30, 2 }, { 6, 6.3 }, { 6.3, 6 } } do
		local L0, L1 = pair[1], pair[2]
		local r = runCtl({ dwell = 6 }, 400, function(t: number): number
			return if t < 150 then L0 else L1
		end)
		local big = math.abs(L1 - L0) > 0.125 * L0
		if big then
			check(math.abs(r.preds[150] - L1) <= 1e-12 * L1, "large step: prediction re-anchored on the step frame")
		else
			local nConv = LiquidControl.convergenceFrames(r.c, L0, L1, 0.01)
			check(math.abs(r.preds[150 + nConv] - L1) <= 0.01 * L1, "small step: converges within the bound")
		end
		check(reversalsFrom(r.rungs, 150) <= 1, "after a step: at most the reversal the step itself causes")
		local settleBound = 150 + (if big then 1 else LiquidControl.convergenceFrames(r.c, L0, L1, 0.05)) + 6 * (Q - 1) + 1
		check(lastChange(r.rungs) <= settleBound, "step: settles within the bound")
		for t = 152, 400 do
			check(r.times[t] <= 4, "step: no overrun after the step frame")
		end
	end
end

-- C3. ramps: extrapolation keeps every frame at or under hi * budget; a reactive controller
-- with the same thresholds does not
do
	local predWorst, reactWorst = 0, 0
	for _, slope in { 0.25, 0.5, 1, 1.5, 2 } do
		local function la(t: number): number
			return math.min(100, if t < 40 then 1 else 1 + slope * (t - 40))
		end
		local rp = runCtl({ start = 7 }, 160, la)
		local rr = runCtl({ start = 7, predictive = false, margin = 0 }, 160, la)
		for t = 44, 160 do
			predWorst = math.max(predWorst, rp.times[t] / 4)
			reactWorst = math.max(reactWorst, rr.times[t] / 4)
		end
	end
	check(predWorst <= 0.9 + 1e-12, "predictive: ramps never exceed hi * budget (" .. predWorst .. ")")
	check(reactWorst > 1, "reactive: a fast ramp overruns the budget (" .. reactWorst .. ")")
end

-- C4. noisy load: hysteresis keeps the knobs still
do
	for _, amp in { 0.05, 0.15 } do
		local r = runCtl({}, 2000, function(t: number): number
			return 6 * (1 + amp * ((MyMath.hash2(t, 1, 3) % 2001) / 1000 - 1))
		end)
		check(r.c.changes <= 3, "noisy load: a few changes at most (" .. r.c.changes .. ")")
		check(reversalsFrom(r.rungs, 2) <= 2, "noisy load: no oscillation")
	end
end

-- C5. wrong cost model: failed probes bounded by 1 + floor(log_{1/rho}(l_q / l_{q-1}))
do
	local ladder = LiquidControl.DEFAULT_LADDER
	for _, rho in { 0.75, 0.5 } do
		local r = runCtl({ backoff = rho }, 800, function(_t: number): number
			return 1.8
		end, function(q: number): number
			return ladder[q + 1].cost * (if q == 6 then 2.5 else 1)
		end)
		local probes = 0
		for t = 2, 800 do
			if r.rungs[t - 1] == 6 and r.times[t] > 4 then
				probes += 1
			end
		end
		local bound = 1 + math.floor(math.log(2.5) / math.log(1 / rho))
		check(probes <= bound, "failed probes within the backoff bound (" .. probes .. " <= " .. bound .. ")")
		check(lastChange(r.rungs) < 400, "model error: knobs constant after finitely many probes")
	end
end

-- C6. residency follows exogenous memory with the same guarantees
do
	local r = runCtl({}, 400, function(_t: number): number
		return 3
	end, nil, function(t: number): number
		return if t < 150 then 20 else 50
	end)
	-- constant 20 MB: raise one unit per dwell until 20 + 4 R <= 0.7 * 64
	check(r.resid[149] == 6, "residency rises to the largest R under the lower threshold")
	check(reversalsFrom(r.resid, 1) <= 1, "residency: only the step reverses it")
	check(r.resid[150] == 1, "residency: eviction on the step frame")
	for t = 151, 400 do
		check(50 + r.resid[t] * 4 <= 0.9 * 64 or r.resid[t] == 1, "residency within the cap after the step")
	end
end

-- C7. determinism of a scripted session
do
	local r = runCtl({}, 3000, function(t: number): number
		local base = if t < 1000 then 3 elseif t < 2000 then 3 + (t - 1000) * 0.01 else 9
		return base * (1 + 0.1 * ((MyMath.hash2(t, 7, 7) % 2001) / 1000 - 1))
	end, nil, function(t: number): number
		return 16 + (t % 700) * 0.05
	end)
	local h = 0x811C9DC5
	for t = 1, 3000 do
		h = MyMath.hash32(bit32.bxor(h, r.rungs[t] * 256 + r.resid[t]))
		local p = r.preds[t]
		h = MyMath.hash32(bit32.bxor(h, math.floor(p * 65536) % 4294967296))
	end
	if PRINT_GOLDEN then
		print("control", h)
	else
		check(h == GOLDEN.control, "golden hash: controller session")
	end
end

print("liquid_apps: " .. checks .. " checks passed")
