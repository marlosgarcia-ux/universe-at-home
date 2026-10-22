--!native
--!optimize 2
-- ALLAN renderer benchmark (src/Liquid.luau). Run in both runtimes:
--   /home/user/luau-lang/luau/build/luau bench/liquid.luau
--   /home/user/luau-lang/luau/build/luau --codegen bench/liquid.luau
-- Optional program args: -a <runs> <scene filter> (default 3 runs, all scenes).
--
-- Scenes (1024 x 1024): a flat UI, an SDF logo and fbm noise, rendered with exact pixel
-- coverage on the CPU. Each becomes a shell-byte quadtree with the learning builder's rule
-- (split while the max channel deviation from the integer mean exceeds theta; leaf bytes =
-- integer means) and gets a readout fitted by ridge regression on a Walsh reservoir (the
-- learning builder's default reservoir; this file's small trainer only exists to make the
-- readout realistic, the real one is src/LiquidLearn.luau). Timings are the minimum over
-- `runs` repetitions; the reference is every pixel stepped (Liquid.reference, fast lookup).

local Liquid = require("../src/Liquid")
local MyMath = require("../src/MyMath")

local args: { string } = { ... }
local RUNS = tonumber(args[1]) or 3
local FILTER: string? = args[2]
local SIZE = 1024

local clock = os.clock

local function minTime(runs: number, f: () -> ()): number
	local best = math.huge
	for _ = 1, runs do
		local t0 = clock()
		f()
		local dt = clock() - t0
		if dt < best then
			best = dt
		end
	end
	return best * 1000
end

----------------------------------------------------------------------------------------
-- scenes: RGBA8 images with exact-coverage anti-aliasing (coverage = clamp(0.5 - d, 0, 1))
----------------------------------------------------------------------------------------

type Shape = { kind: string, col: number, p: { number } }

local function sdShape(s: Shape, px: number, py: number): number
	local p = s.p
	if s.kind == "box" then
		return MyMath.sdRoundBox(px, py, p[1], p[2], p[3], p[4], p[5])
	elseif s.kind == "circle" then
		return MyMath.sdCircle(px, py, p[1], p[2], p[3])
	elseif s.kind == "ring" then
		return math.abs(MyMath.sdCircle(px, py, p[1], p[2], p[3])) - p[4]
	elseif s.kind == "seg" then
		return MyMath.sdSegment(px, py, p[1], p[2], p[3], p[4], p[5])
	else
		return MyMath.sdPolygon(px, py, p)
	end
end

local function hexc(s: string): number
	return MyMath.hex(s)
end

local function paint(img: buffer, W: number, H: number, bg: number, shapes: { Shape })
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local r, g, b = bg % 256, (bg // 256) % 256, (bg // 65536) % 256
			local px, py = x + 0.5, y + 0.5
			for _, s in shapes do
				local dist = sdShape(s, px, py)
				if dist < 0.5 then
					local a = if dist <= -0.5 then 1 else 0.5 - dist
					local c = s.col
					r = r + ((c % 256) - r) * a
					g = g + (((c // 256) % 256) - g) * a
					b = b + (((c // 65536) % 256) - b) * a
				end
			end
			buffer.writeu32(img, (y * W + x) * 4, math.floor(r + 0.5) + math.floor(g + 0.5) * 256 + math.floor(b + 0.5) * 65536 + 255 * 16777216)
		end
	end
end

local function uiScene(): buffer
	local shapes: { Shape } = {}
	local function box(x: number, y: number, w: number, h: number, r: number, col: string)
		table.insert(shapes, { kind = "box", col = hexc(col), p = { x + w / 2, y + h / 2, w / 2, h / 2, r } })
	end
	box(0, 0, 1024, 64, 0, "#2D6CDF")
	box(0, 64, 220, 960, 0, "#2A2F3A")
	for k = 0, 7 do
		table.insert(shapes, { kind = "circle", col = hexc("#FFC107"), p = { 40, 112 + 64 * k, 12 } })
		box(64, 106 + 64 * k, 120 - (k % 3) * 20, 12, 6, "#AEB4BF")
	end
	for j = 0, 2 do
		for i = 0, 2 do
			local x0, y0 = 252 + i * 254, 96 + j * 304
			box(x0, y0, 230, 280, 16, "#3A4150")
			box(x0 + 16, y0 + 16, 198, 110, 10, if (i + j) % 2 == 0 then "#5C6BC0" else "#26A69A")
			for t = 0, 3 do
				box(x0 + 16, y0 + 146 + t * 22, 198 - ((t * 37 + i * 11) % 90), 10, 5, "#C8CCD4")
			end
			box(x0 + 16, y0 + 236, 96, 28, 14, if (i + 2 * j) % 3 == 0 then "#E91E63" else "#4CAF50")
		end
	end
	local img = buffer.create(SIZE * SIZE * 4)
	paint(img, SIZE, SIZE, hexc("#20242C"), shapes)
	return img
end

local function logoScene(): buffer
	local shapes: { Shape } = {}
	table.insert(shapes, { kind = "circle", col = hexc("#E9ECEF"), p = { 512, 512, 380 } })
	table.insert(shapes, { kind = "ring", col = hexc("#1D3557"), p = { 512, 512, 340, 22 } })
	local star = {}
	for k = 0, 9 do
		local rr = if k % 2 == 0 then 250 else 105
		local t = 0.75 + k / 10
		table.insert(star, 512 + MyMath.dcosTurns(t) * rr)
		table.insert(star, 520 + MyMath.dsinTurns(t) * rr)
	end
	table.insert(shapes, { kind = "poly", col = hexc("#E63946"), p = star })
	table.insert(shapes, { kind = "seg", col = hexc("#457B9D"), p = { 250, 820, 774, 820, 26 } })
	for k = 0, 5 do
		local t = k / 6
		table.insert(shapes, {
			kind = "circle",
			col = hexc("#F4A261"),
			p = { 512 + MyMath.dcosTurns(t) * 440, 512 + MyMath.dsinTurns(t) * 440, 30 },
		})
	end
	local img = buffer.create(SIZE * SIZE * 4)
	paint(img, SIZE, SIZE, hexc("#F4F1EA"), shapes)
	return img
end

local function noiseScene(): buffer
	local img = buffer.create(SIZE * SIZE * 4)
	for y = 0, SIZE - 1 do
		for x = 0, SIZE - 1 do
			local n1 = MyMath.fbm2(x / 24, y / 24, 11, 5)
			local n2 = MyMath.fbm2(x / 16 + 17.3, y / 16 - 4.1, 23, 4)
			local r = 60 + 170 * n1
			local g = 40 + 120 * n2 + 50 * n1
			local b = 30 + 90 * (1 - n1) * n2
			buffer.writeu32(img, (y * SIZE + x) * 4, math.floor(r) + math.floor(g) * 256 + math.floor(b) * 65536 + 255 * 16777216)
		end
	end
	return img
end

----------------------------------------------------------------------------------------
-- shell-byte quadtree (same rule as tools/liquid_train.py build_tree)
----------------------------------------------------------------------------------------

local function buildTree(img: buffer, W: number, H: number, theta: number, minLeaf: number): Liquid.Tree
	local P = 0
	while 2 ^ P < math.max(W, H) do
		P += 1
	end
	local ml = 0
	while 2 ^ ml < minLeaf do
		ml += 1
	end
	local maxDepth = P - ml
	-- pyramid: per level, per node: count, sums (3), min (3), max (3)
	local levels: { { cnt: buffer, sum: buffer, mn: buffer, mx: buffer } } = {}
	for l = 1, P do
		local n = 2 ^ (P - l)
		local cnt = buffer.create(n * n * 4)
		local sum = buffer.create(n * n * 12)
		local mn = buffer.create(n * n * 3)
		local mx = buffer.create(n * n * 3)
		buffer.fill(mn, 0, 255)
		for ny = 0, n - 1 do
			for nx = 0, n - 1 do
				local c = 0
				local s = { 0, 0, 0 }
				local lo = { 255, 255, 255 }
				local hi = { 0, 0, 0 }
				for q = 0, 3 do
					local cx, cy = nx * 2 + q % 2, ny * 2 + q // 2
					if l == 1 then
						if cx < W and cy < H then
							c += 1
							local px = buffer.readu32(img, (cy * W + cx) * 4)
							for ch = 1, 3 do
								local v = (px // 256 ^ (ch - 1)) % 256
								s[ch] += v
								if v < lo[ch] then
									lo[ch] = v
								end
								if v > hi[ch] then
									hi[ch] = v
								end
							end
						end
					else
						local pl = levels[l - 1]
						local pn = 2 ^ (P - l + 1)
						local j = cy * pn + cx
						local cc = buffer.readu32(pl.cnt, j * 4)
						if cc > 0 then
							c += cc
							for ch = 1, 3 do
								s[ch] += buffer.readu32(pl.sum, j * 12 + (ch - 1) * 4)
								local a = buffer.readu8(pl.mn, j * 3 + ch - 1)
								local b = buffer.readu8(pl.mx, j * 3 + ch - 1)
								if a < lo[ch] then
									lo[ch] = a
								end
								if b > hi[ch] then
									hi[ch] = b
								end
							end
						end
					end
				end
				local j = ny * n + nx
				buffer.writeu32(cnt, j * 4, c)
				for ch = 1, 3 do
					buffer.writeu32(sum, j * 12 + (ch - 1) * 4, s[ch])
					buffer.writeu8(mn, j * 3 + ch - 1, lo[ch])
					buffer.writeu8(mx, j * 3 + ch - 1, hi[ch])
				end
			end
		end
		levels[l] = { cnt = cnt, sum = sum, mn = mn, mx = mx }
	end
	local function stats(x0: number, y0: number, side: number): (number, { number }, number)
		local l = 0
		while 2 ^ l < side do
			l += 1
		end
		if l == 0 then
			if x0 >= W or y0 >= H then
				return 0, { 0, 0, 0 }, 0
			end
			local px = buffer.readu32(img, (y0 * W + x0) * 4)
			return 1, { px % 256, (px // 256) % 256, (px // 65536) % 256 }, 0
		end
		local pl = levels[l]
		local n = 2 ^ (P - l)
		local j = (y0 // side) * n + x0 // side
		local c = buffer.readu32(pl.cnt, j * 4)
		if c == 0 then
			return 0, { 0, 0, 0 }, 0
		end
		local means = {}
		local dev = 0
		for ch = 1, 3 do
			local s = buffer.readu32(pl.sum, j * 12 + (ch - 1) * 4)
			local mean = (2 * s + c) // (2 * c)
			means[ch] = mean
			dev = math.max(dev, buffer.readu8(pl.mx, j * 3 + ch - 1) - mean, mean - buffer.readu8(pl.mn, j * 3 + ch - 1))
		end
		return c, means, dev
	end
	return Liquid.buildTree(W, H, maxDepth, 3, function(x0: number, y0: number, side: number, _depth: number): boolean
		local c, _, dev = stats(x0, y0, side)
		return c > 0 and dev > theta
	end, function(x0: number, y0: number, side: number, _depth: number, out: buffer, at: number)
		local _, means = stats(x0, y0, side)
		for ch = 1, 3 do
			buffer.writeu8(out, at + ch - 1, means[ch])
		end
	end)
end

----------------------------------------------------------------------------------------
-- reservoir (learning builder's Walsh reservoir) and a ridge readout fit
----------------------------------------------------------------------------------------

local INSTANT = -64

local function walsh(N: number, I: number, K: number, scales: { number }): { beta: { number }, B: { number }, kBase: { number }, K: number }
	local Hd = { { 1, 1, 1, 1 }, { 1, -1, 1, -1 }, { 1, 1, -1, -1 }, { 1, -1, -1, 1 } }
	local beta, B, kBase = {}, {}, {}
	for i = 0, N - 1 do
		local p = i % I
		local s = 0
		for t = 1, I do
			s += Hd[p + 1][t]
		end
		beta[i + 1] = 0.5 - s / (2 * I)
		for t = 1, I do
			B[i * I + t] = Hd[p + 1][t] / I
		end
		kBase[i + 1] = scales[(i // I) % #scales + 1]
	end
	return { beta = beta, B = B, kBase = kBase, K = K }
end

-- Fits Cf, Cb, d by ridge regression on states sampled every `rs` rows and `cs` columns.
local function fit(res: { beta: { number }, B: { number }, kBase: { number }, K: number }, tree: Liquid.Tree, img: buffer, rs: number, cs: number): Liquid.Model
	local N, I, M = #res.beta, 3, 3
	local D = 2 * N + 1
	local zeroModel = Liquid.newModel({
		N = N,
		I = I,
		M = M,
		K = res.K,
		beta = res.beta,
		B = res.B,
		kBase = res.kBase,
		Cf = table.create(M * N, 0),
		Cb = table.create(M * N, 0),
		d = table.create(M, 0),
	})
	local plan = Liquid.prepare(zeroModel, tree)
	local W = plan.Wr
	local G = table.create(D * D, 0)
	local Pm = table.create(D * M, 0)
	local count = 0
	local bs = table.create(W * N, 0)
	local gs = table.create(W * N, 0)
	local hb = table.create(W * N, 0)
	local h = table.create(N, 0)
	local s = table.create(D, 0)
	local tmpModel = zeroModel
	for y = 0, plan.Hr - 1, rs do
		local segs = Liquid.rowSegments(plan, tree, y)
		for _, sg in segs do
			local leaf, depth = sg[3], sg[4]
			for i = 1, N do
				local b = tmpModel.beta[i]
				for t = 0, I - 1 do
					b = b + tmpModel.B[(i - 1) * I + t + 1] * plan.U[buffer.readu8(tree.leafBytes, leaf * I + t) + 1]
				end
				local g = plan.gk[plan.kOf[depth * N + i] + 1]
				for x = sg[1], sg[1] + sg[2] - 1 do
					bs[x * N + i] = b
					gs[x * N + i] = g
				end
			end
		end
		for i = 1, N do
			h[i] = bs[(W - 1) * N + i]
		end
		for x = W - 1, 0, -1 do
			for i = 1, N do
				local hi = h[i]
				hi = hi + (bs[x * N + i] - hi) * gs[x * N + i]
				h[i] = hi
				hb[x * N + i] = hi
			end
		end
		for i = 1, N do
			h[i] = bs[i]
		end
		for x = 0, W - 1 do
			for i = 1, N do
				local hi = h[i]
				h[i] = hi + (bs[x * N + i] - hi) * gs[x * N + i]
			end
			if x % cs == 0 then
				for i = 1, N do
					s[i] = h[i]
					s[N + i] = hb[x * N + i]
				end
				s[D] = 1
				local px = buffer.readu32(img, (y * W + x) * 4)
				for a = 1, D do
					local sa = s[a]
					for b = a, D do
						G[(a - 1) * D + b] += sa * s[b]
					end
					for m = 1, M do
						Pm[(a - 1) * M + m] += sa * ((px // 256 ^ (m - 1)) % 256)
					end
				end
				count += 1
			end
		end
	end
	for a = 1, D do
		for b = 1, a - 1 do
			G[(a - 1) * D + b] = G[(b - 1) * D + a]
		end
	end
	local lam = 1e-6 * count
	for a = 1, D do
		G[(a - 1) * D + a] += lam
	end
	-- Cholesky G = L L^T
	local Lc = table.create(D * D, 0)
	for a = 1, D do
		for b = 1, a do
			local v = G[(a - 1) * D + b]
			for k = 1, b - 1 do
				v -= Lc[(a - 1) * D + k] * Lc[(b - 1) * D + k]
			end
			if a == b then
				Lc[(a - 1) * D + a] = math.sqrt(math.max(v, 1e-300))
			else
				Lc[(a - 1) * D + b] = v / Lc[(b - 1) * D + b]
			end
		end
	end
	local Cf, Cb, d = table.create(M * N, 0), table.create(M * N, 0), table.create(M, 0)
	for m = 1, M do
		local yv = table.create(D, 0)
		for a = 1, D do
			local v = Pm[(a - 1) * M + m]
			for k = 1, a - 1 do
				v -= Lc[(a - 1) * D + k] * yv[k]
			end
			yv[a] = v / Lc[(a - 1) * D + a]
		end
		local xv = table.create(D, 0)
		for a = D, 1, -1 do
			local v = yv[a]
			for k = a + 1, D do
				v -= Lc[(k - 1) * D + a] * xv[k]
			end
			xv[a] = v / Lc[(a - 1) * D + a]
		end
		for i = 1, N do
			Cf[(m - 1) * N + i] = xv[i]
			Cb[(m - 1) * N + i] = xv[N + i]
		end
		d[m] = xv[D]
	end
	return Liquid.newModel({ N = N, I = I, M = M, K = res.K, beta = res.beta, B = res.B, kBase = res.kBase, Cf = Cf, Cb = Cb, d = d })
end

local function psnr(a: buffer, b: buffer, n: number): (number, number)
	local se, mx = 0, 0
	for j = 0, n - 1 do
		local p, q = buffer.readu32(a, j * 4), buffer.readu32(b, j * 4)
		for c = 0, 2 do
			local e = math.abs((p // 256 ^ c) % 256 - (q // 256 ^ c) % 256)
			se += e * e
			if e > mx then
				mx = e
			end
		end
	end
	local mse = se / (3 * n)
	return if mse == 0 then 99 else 10 * math.log10(255 * 255 / mse), mx
end

local function maxDiff(a: buffer, b: buffer, n: number): number
	local mx = 0
	for j = 0, n - 1 do
		local p, q = buffer.readu32(a, j * 4), buffer.readu32(b, j * 4)
		if p ~= q then
			for c = 0, 3 do
				local e = math.abs((p // 256 ^ c) % 256 - (q // 256 ^ c) % 256)
				if e > mx then
					mx = e
				end
			end
		end
	end
	return mx
end

----------------------------------------------------------------------------------------
-- benchmark
----------------------------------------------------------------------------------------

local runtime = if args[3] then args[3] else "?"
print(string.format("# ALLAN renderer benchmark (%s), %dx%d, minimum of %d runs per timing", runtime, SIZE, SIZE, RUNS))

type Scene = { name: string, make: () -> buffer, theta: number }
type Res = { name: string, scales: { number } }
type Cfg = { eps: number, L: number, vert: string }

local scenes: { Scene } = {
	{ name = "flat UI", make = uiScene, theta = 8 },
	{ name = "SDF logo", make = logoScene, theta = 8 },
	{ name = "noise", make = noiseScene, theta = 8 },
}
local reservoirs: { Res } = {
	{ name = "walsh[inst,0,-2]", scales = { INSTANT, 0, -2 } },
	{ name = "walsh[inst,-2,-4]", scales = { INSTANT, -2, -4 } },
}
local configs: { Cfg } = {
	{ eps = 0.5, L = 0, vert = "box" },
	{ eps = 0, L = 0, vert = "box" },
	{ eps = 0.25, L = 0, vert = "box" },
	{ eps = 1, L = 0, vert = "box" },
	{ eps = 0.5, L = 1, vert = "box" },
	{ eps = 0.5, L = 2, vert = "box" },
	{ eps = 0.5, L = 2, vert = "point" },
}

local function byteAt(b: buffer, j: number, c: number): number
	return buffer.readu8(b, j * 4 + c)
end

for _, sc in scenes do
	if FILTER and FILTER ~= "" and not string.find(sc.name, FILTER, 1, true) then
		continue
	end
	local t0 = clock()
	local img = sc.make()
	local tImg = clock() - t0
	t0 = clock()
	local tree = buildTree(img, SIZE, SIZE, sc.theta, 1)
	local tTree = clock() - t0
	print(string.format(
		"\n## %s: image %.1f s, tree %.1f s, %d leaves, %d nodes, %d distinct leaf contents",
		sc.name,
		tImg,
		tTree,
		tree.leafCount,
		tree.nodeCount,
		tree.keyCount
	))
	for _, rv in reservoirs do
		local res = walsh(8, 3, 16, rv.scales)
		t0 = clock()
		local model = fit(res, tree, img, 4, 2)
		local tFit = clock() - t0
		local plan = Liquid.prepare(model, tree)
		local ref = buffer.create(SIZE * SIZE * 4)
		local tRef = minTime(RUNS, function()
			Liquid.reference(plan, tree, ref, SIZE, true)
		end)
		local refB = buffer.create(SIZE * SIZE * 4)
		local tRefB = minTime(RUNS, function()
			Liquid.reference(plan, tree, refB, SIZE, true, nil, true)
		end)
		assert(buffer.tostring(refB) == buffer.tostring(ref), "band-copied reference must equal the reference")
		local p, mx = psnr(ref, img, SIZE * SIZE)
		print(string.format(
			"\n### reservoir %s (N 8, K 16, %d tracked groups): fit %.1f s; model vs source PSNR %.2f dB (max err %d)",
			rv.name,
			plan.NG,
			tFit,
			p,
			mx
		))
		print(string.format("reference (every pixel stepped) %.1f ms; reference with band copies %.1f ms", tRef, tRefB))
		print("")
		print("| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |")
		print("|---|---|---|---|---|---|---|---|---|---|---|---|")
		local outs: { [string]: buffer } = {}
		for _, cfg in configs do
			local F = 2 ^ cfg.L
			local Wl = SIZE // F
			local out = buffer.create(Wl * Wl * 4)
			local st = Liquid.newStats()
			local ms = minTime(RUNS, function()
				st = Liquid.newStats()
				Liquid.render(plan, tree, out, Wl, { epsilon = cfg.eps, level = cfg.L, vertical = cfg.vert, stats = st })
			end)
			outs[cfg.vert .. cfg.L .. "_" .. cfg.eps] = out
			local md = if cfg.L == 0 then string.format("%d", maxDiff(out, ref, SIZE * SIZE)) else "-"
			print(string.format(
				"| %g | %d | %s | %.2f | %.1fx | %s | %d | %d | %.1f | %.1f | %.1f | %s |",
				cfg.eps,
				cfg.L,
				cfg.vert,
				ms,
				tRef / ms,
				if cfg.L == 0 then string.format("%.1fx", tRefB / ms) else "-",
				st.rendered,
				st.deduped,
				st.segments / math.max(st.rendered, 1),
				st.evals / math.max(st.rendered, 1),
				100 * st.fillPixels / math.max(st.rendered * Wl, 1),
				md
			))
		end

		-- vertical strategy at level 2: exact 2D box of the reference vs "box" and "point"
		local W2 = SIZE // 4
		local z = {}
		local acc = table.create(W2 * 3, 0)
		local box, point = outs["box2_0.5"], outs["point2_0.5"]
		local eBoxMax, eBoxSum, ePtMax, ePtSum = 0, 0, 0, 0
		for Y = 0, W2 - 1 do
			table.clear(acc)
			for j = 1, W2 * 3 do
				acc[j] = 0
			end
			for y = 4 * Y, 4 * Y + 3 do
				Liquid.referenceRow(plan, tree, y, z)
				for X = 0, W2 - 1 do
					for c = 0, 2 do
						local s2 = 0
						for x = 4 * X, 4 * X + 3 do
							s2 += z[x * 3 + c + 1]
						end
						acc[X * 3 + c + 1] += s2 / 16
					end
				end
			end
			for X = 0, W2 - 1 do
				for c = 0, 2 do
					local exact = math.clamp(acc[X * 3 + c + 1], 0, 255)
					local eb = math.abs(byteAt(box, Y * W2 + X, c) - exact)
					local ep = math.abs(byteAt(point, Y * W2 + X, c) - exact)
					eBoxSum += eb
					ePtSum += ep
					if eb > eBoxMax then
						eBoxMax = eb
					end
					if ep > ePtMax then
						ePtMax = ep
					end
				end
			end
		end
		local nv = W2 * W2 * 3
		print(string.format(
			"\nvertical strategy at level 2 against the exact 2D box average of the reference: box max %.2f mean %.3f; point max %.2f mean %.3f (output units)",
			eBoxMax,
			eBoxSum / nv,
			ePtMax,
			ePtSum / nv
		))

		-- X2: predict level 0 from levels 1 and 2 (rows layout), then refine by discrepancy
		local exact0 = outs["box0_0.5"]
		local pred = buffer.create(SIZE * SIZE * 4)
		local order: { number } = {}
		local tPred = minTime(RUNS, function()
			order = Liquid.predictFiner(plan, tree, 1, 0.5, pred, SIZE)
		end)
		-- the part of that time spent rendering the two coarse levels (real values)
		local zc1, zc2 = {}, {}
		local tCoarse = minTime(RUNS, function()
			local y = 0
			while y < SIZE do
				local segs, bandEnd = Liquid.rowSegments(plan, tree, y)
				local _ = segs
				Liquid.renderRowValues(plan, tree, y, 1, 0.5, zc1)
				Liquid.renderRowValues(plan, tree, y, 2, 0.5, zc2)
				y = bandEnd
			end
		end)
		local rowErr = table.create(SIZE, 0)
		local rowSum = table.create(SIZE, 0)
		local same, sumErr, maxErr = 0, 0, 0
		for y = 0, SIZE - 1 do
			for x = 0, SIZE - 1 do
				local j = y * SIZE + x
				if buffer.readu32(pred, j * 4) == buffer.readu32(exact0, j * 4) then
					same += 1
				end
				for c = 0, 2 do
					local e = math.abs(byteAt(pred, j, c) - byteAt(exact0, j, c))
					sumErr += e
					rowSum[y + 1] += e
					if e > rowErr[y + 1] then
						rowErr[y + 1] = e
					end
					if e > maxErr then
						maxErr = e
					end
				end
			end
		end
		-- share of the total absolute error removed by refining the first 10% / 25% of rows
		-- in discrepancy order, against the same number of rows spread uniformly
		local function removed(frac: number): (number, number)
			local k = math.floor(SIZE * frac)
			local byOrder, uniform = 0, 0
			for i = 1, k do
				byOrder += rowSum[order[i] + 1]
			end
			local step = SIZE / k
			for i = 0, k - 1 do
				uniform += rowSum[math.floor(i * step) + 1]
			end
			return byOrder / math.max(sumErr, 1e-12), uniform / math.max(sumErr, 1e-12)
		end
		local r10, u10 = removed(0.1)
		local r25, u25 = removed(0.25)
		print(string.format(
			"X2 (level 0 predicted from levels 1 and 2): %.2f ms in all, of which %.2f ms render the two coarse levels (prediction pass %.2f ms); %.1f%% of pixels exact, mean abs err %.3f, max err %d. Refining 10%% of rows in discrepancy order removes %.0f%% of the error (uniform rows: %.0f%%); 25%%: %.0f%% (uniform %.0f%%)",
			tPred,
			tCoarse,
			math.max(tPred - tCoarse, 0),
			100 * same / (SIZE * SIZE),
			sumErr / (SIZE * SIZE * 3),
			maxErr,
			100 * r10,
			100 * u10,
			100 * r25,
			100 * u25
		))

		-- X3: one virtual block and one straddling the stored edge
		local tile = buffer.create(SIZE * SIZE * 4)
		for _, at in { { 1024, 0 }, { 512, 512 } } do
			local st = Liquid.newStats()
			local ms = minTime(RUNS, function()
				st = Liquid.newStats()
				Liquid.render(plan, tree, tile, SIZE, { epsilon = 0.5, x = at[1], y = at[2], w = SIZE, h = SIZE, endless = { seed = 7, horizon = 2 }, stats = st })
			end)
			print(string.format(
				"X3 endless tile at (%d, %d): %.2f ms, rows evaluated %d (deduplicated %d), largest certificate %.3g output units",
				at[1],
				at[2],
				ms,
				st.rendered,
				st.deduped,
				st.seam
			))
		end
	end
end
