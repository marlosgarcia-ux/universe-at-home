--!strict
-- Tests for src/Liquid.luau (ALLAN renderer). Run by tests/run.sh in the interpreter and
-- with native code generation; every check asserts. Claims tested here are the ones in
-- docs/LIQUID.md "Renderer results": T1, T2 (with the quantisation margin), T4, T5, the
-- vertical box filter, regions and Canvas dirty marking, X2, X3 and T7.

local Liquid = require("../src/Liquid")
local MyMath = require("../src/MyMath")
local Canvas = require("../src/Canvas")

type Model = Liquid.Model
type Tree = Liquid.Tree

local function rnd(i: number, j: number, s: number): number
	return MyMath.hash2(i, j, s) / 4294967296
end

local function log2ceil(v: number): number
	local p = 0
	while 2 ^ p < v do
		p += 1
	end
	return p
end

-- Random model whose gains span instant to slow across leaf sizes.
local function makeModel(seed: number, N: number, I: number, M: number, K: number, P: number, scale: number?): Model
	local amp = scale or 50
	local beta, B, kBase, Cf, Cb, d = {}, {}, {}, {}, {}, {}
	local c = 0
	local function r(): number
		c += 1
		return rnd(c, seed, 99) * 2 - 1
	end
	for i = 1, N do
		beta[i] = r()
		kBase[i] = math.floor(rnd(i, seed, 7) * (K + 4)) - P - 2
	end
	for j = 1, N * I do
		B[j] = r()
	end
	for j = 1, M * N do
		Cf[j] = r() * amp
		Cb[j] = r() * amp
	end
	for m = 1, M do
		d[m] = 128 + r() * 40
	end
	return Liquid.newModel({ N = N, I = I, M = M, K = K, beta = beta, B = B, kBase = kBase, Cf = Cf, Cb = Cb, d = d })
end

-- Random multi-scale quadtree.
local function makeTree(seed: number, W: number, H: number, I: number, maxDepth: number?): Tree
	local P = log2ceil(math.max(W, H))
	return Liquid.buildTree(W, H, maxDepth or math.min(P, 7), I, function(x0: number, y0: number, _side: number, depth: number): boolean
		return depth < 1 or rnd(x0 + depth * 7919, y0, seed) < 0.75 - 0.1 * depth
	end, function(x0: number, y0: number, _side: number, _depth: number, out: buffer, at: number)
		for t = 0, I - 1 do
			buffer.writeu8(out, at + t, MyMath.hash2(x0 // 4, y0 // 4, t + seed) % 256)
		end
	end)
end

local function byteOf(px: number, m: number): number
	return (px // 256 ^ m) % 256
end

local function clamp255(z: number): number
	return if z < 0 then 0 elseif z > 255 then 255 else z
end

local FP = 1e-7 -- floating-point slack in output units (measured differences are ~1e-12)

----------------------------------------------------------------------------------------
-- codec, segmentation and bands
----------------------------------------------------------------------------------------
do
	local tree = makeTree(3, 100, 77, 3)
	local model = makeModel(3, 8, 3, 3, 8, tree.P)
	local blob = Liquid.encode(model, tree)
	assert(buffer.readstring(blob, 0, 3) == "ALN" and buffer.readu8(blob, 3) == 1, "magic and version")
	local m2, t2, after = Liquid.decode(blob)
	assert(after == buffer.len(blob), "decode consumes the whole blob")
	assert(t2.nodeCount == tree.nodeCount and t2.leafCount == tree.leafCount, "tree counts")
	assert(buffer.tostring(Liquid.encode(m2, t2)) == buffer.tostring(blob), "encode(decode(x)) == x")
	local bad = buffer.create(buffer.len(blob))
	buffer.copy(bad, 0, blob)
	buffer.writeu8(bad, 3, 2)
	assert(not pcall(function()
		Liquid.decode(bad)
	end), "unknown version is rejected")

	for _, R in { 0, 1 } do
		local plan = Liquid.prepare(model, tree, R)
		local sf = 2 ^ R
		for y = 0, plan.Hr - 1 do
			local segs, bandEnd = Liquid.rowSegments(plan, tree, y)
			local x = 0
			for _, s in segs do
				assert(s[1] == x, "segments tile the row")
				for xx = s[1], s[1] + s[2] - 1 do
					local leaf, depth = Liquid.leafAt(tree, xx // sf, y // sf)
					assert(depth == s[4], "segment depth")
					assert(buffer.readu32(tree.leafKey, leaf * 4) == buffer.readu32(tree.leafKey, s[3] * 4), "segment content")
				end
				x += s[2]
			end
			assert(x == plan.Wr, "segments cover the row")
			for yy = y + 1, bandEnd - 1 do
				for xx = 0, plan.Wr - 1, 3 do
					assert(Liquid.leafAt(tree, xx // sf, yy // sf) == Liquid.leafAt(tree, xx // sf, y // sf), "band rows cross the same leaves")
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------
-- T1: closed-form jumps match stepping within the stated tolerance
--   |jump - step| <= 4u (|e0| (n + 2) + Hm (min(n, 2^k) + 2)), u = 2^-53, Hm = max(|b|, |h0|)
----------------------------------------------------------------------------------------
do
	local tree = makeTree(5, 256, 256, 3)
	local model = makeModel(5, 8, 3, 3, 16, tree.P)
	local plan = Liquid.prepare(model, tree)
	local u = 2 ^ -53
	local worstRatio = 0
	for trial = 1, 400 do
		local k = trial % 16
		local g = plan.gk[k + 1]
		local b = (rnd(trial, 1, 11) * 2 - 1) * 3
		local h0 = (rnd(trial, 2, 11) * 2 - 1) * 3
		local n = math.floor(rnd(trial, 3, 11) * plan.T)
		local h = h0
		for _ = 1, n do
			h = h + (b - h) * g
		end
		local e0 = h0 - b
		local jump = b + e0 * plan.pw[k * plan.TP1 + n + 1]
		local Hm = math.max(math.abs(b), math.abs(h0))
		local tol = 4 * u * (math.abs(e0) * (n + 2) + Hm * (math.min(n, 2 ^ k) + 2))
		local diff = math.abs(jump - h)
		assert(diff <= tol, `T1 tolerance exceeded: k={k} n={n} diff={diff} tol={tol}`)
		if tol > 0 and diff / tol > worstRatio then
			worstRatio = diff / tol
		end
	end
	assert(worstRatio < 1, "T1")
end

----------------------------------------------------------------------------------------
-- T2 (every byte within eps + 0.5 of the exact value, within 1 LSB of the reference
-- byte, and equal to it for eps = 0), T4 (real-valued output within eps), T5 (levels are
-- exact horizontal box averages), the exact vertical box filter, and regions
----------------------------------------------------------------------------------------
local valuesChecked = 0
local function checkBytes(name: string, out: buffer, stride: number, X: number, Y: number, M: number, zExact: number, eps: number, m: number)
	local byte = byteOf(buffer.readu32(out, (Y * stride + X) * 4), m)
	local err = math.abs(byte - clamp255(zExact))
	valuesChecked += 1
	if err > eps + 0.5 + FP then
		error(string.format("%s: T2 bound violated eps=%g X=%d Y=%d m=%d byte=%d z=%.9f", name, eps, X, Y, m, byte, zExact))
	end
	local q = Liquid.quantize(zExact)
	assert(math.abs(byte - q) <= 1, name .. ": more than 1 LSB from the reference byte")
	if eps == 0 and byte ~= q then
		error(string.format("%s: lossless mode differs from the reference X=%d Y=%d m=%d byte=%d z=%.12f", name, X, Y, m, byte, zExact))
	end
end

for trial = 1, 6 do
	local M = ({ 1, 3, 4, 3, 4, 2 })[trial % 6 + 1]
	local W, H = 60 + trial * 11, 40 + trial * 7
	local P = log2ceil(math.max(W, H))
	local K = 4 + trial % 9
	local model = makeModel(trial, 6 + trial % 5, 3, M, K, P)
	local tree = makeTree(trial, W, H, 3)
	local plan = Liquid.prepare(model, tree)
	local Z: { { number } } = {}
	for y = 0, H - 1 do
		local z = {}
		Liquid.referenceRow(plan, tree, y, z)
		Z[y + 1] = z
	end
	for _, eps in { 0, 0.25, 0.75 } do
		-- level 0
		local out = buffer.create(W * H * 4)
		Liquid.render(plan, tree, out, W, { epsilon = eps })
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				for m = 0, math.min(M, 4) - 1 do
					checkBytes("L0", out, W, x, y, M, Z[y + 1][x * M + m + 1], eps, m)
				end
			end
		end
		-- T4: real values within eps (no rounding term)
		if eps > 0 then
			local vals = {}
			for y = 0, H - 1, 3 do
				Liquid.renderRowValues(plan, tree, y, 0, eps, vals)
				for j = 1, W * M do
					local diff = math.abs(vals[j] - Z[y + 1][j])
					assert(diff <= eps + FP, `T4: real value off by {diff} > eps {eps}`)
				end
			end
		end
		for L = 1, 3 do
			local F = 2 ^ L
			local Wl = (W + F - 1) // F
			-- T5 horizontal ("rows")
			local o = buffer.create(Wl * H * 4)
			Liquid.render(plan, tree, o, Wl, { epsilon = eps, level = L, vertical = "rows" })
			for y = 0, H - 1 do
				for X = 0, Wl - 1 do
					for m = 0, math.min(M, 4) - 1 do
						local s, n = 0, 0
						for x = X * F, math.min(W, X * F + F) - 1 do
							s += Z[y + 1][x * M + m + 1]
							n += 1
						end
						checkBytes("T5 rows L" .. L, o, Wl, X, y, M, s / n, eps, m)
					end
				end
			end
			-- exact 2D box ("box", the default vertical strategy)
			local Hl = (H + F - 1) // F
			local ob = buffer.create(Wl * Hl * 4)
			Liquid.render(plan, tree, ob, Wl, { epsilon = eps, level = L })
			for Y = 0, Hl - 1 do
				for X = 0, Wl - 1 do
					for m = 0, math.min(M, 4) - 1 do
						local s, n = 0, 0
						for y = Y * F, math.min(H, Y * F + F) - 1 do
							for x = X * F, math.min(W, X * F + F) - 1 do
								s += Z[y + 1][x * M + m + 1]
								n += 1
							end
						end
						checkBytes("box L" .. L, ob, Wl, X, Y, M, s / n, eps, m)
					end
				end
			end
			-- T4 at a level (real values within eps of the footprint average)
			if eps > 0 then
				local vals = {}
				for y = 1, H - 1, 5 do
					Liquid.renderRowValues(plan, tree, y, L, eps, vals)
					for X = 0, Wl - 1 do
						for m = 0, M - 1 do
							local s, n = 0, 0
							for x = X * F, math.min(W, X * F + F) - 1 do
								s += Z[y + 1][x * M + m + 1]
								n += 1
							end
							local diff = math.abs(vals[X * M + m + 1] - s / n)
							assert(diff <= eps + FP, `T4 at level {L}: off by {diff}`)
						end
					end
				end
			end
		end
		-- a region equals the same crop of the full render
		local full = buffer.create(W * H * 4)
		Liquid.render(plan, tree, full, W, { epsilon = eps })
		local rx, ry, rw, rh = 7, 5, W - 20, H - 13
		local crop = buffer.create(rw * rh * 4)
		Liquid.render(plan, tree, crop, rw, { epsilon = eps, x = rx, y = ry, w = rw, h = rh })
		for y = 0, rh - 1 do
			for x = 0, rw - 1 do
				assert(buffer.readu32(crop, (y * rw + x) * 4) == buffer.readu32(full, ((y + ry) * W + x + rx) * 4), "region render equals crop")
			end
		end
	end
end
assert(valuesChecked > 100000, "T2 coverage")

----------------------------------------------------------------------------------------
-- M > 4: channels 4..7 go to the second target; render scale r = 1 matches the reference
----------------------------------------------------------------------------------------
do
	local W, H = 70, 45
	local tree = makeTree(21, W, H, 2)
	local model = makeModel(21, 9, 2, 7, 9, tree.P)
	local plan = Liquid.prepare(model, tree)
	local out, out2 = buffer.create(W * H * 4), buffer.create(W * H * 4)
	Liquid.render(plan, tree, out, W, { epsilon = 0.25, out2 = out2 })
	local z = {}
	for y = 0, H - 1 do
		Liquid.referenceRow(plan, tree, y, z)
		for x = 0, W - 1 do
			for m = 0, 6 do
				local target = if m < 4 then out else out2
				checkBytes("M=7", target, W, x, y, 7, z[x * 7 + m + 1], 0.25, m % 4)
			end
			assert(byteOf(buffer.readu32(out2, (y * W + x) * 4), 3) == 255, "missing alpha is 255")
		end
	end
	local plan1 = Liquid.prepare(model, tree, 1)
	local o1 = buffer.create(plan1.Wr * plan1.Hr * 4)
	Liquid.render(plan1, tree, o1, plan1.Wr, { epsilon = 0 })
	for y = 0, plan1.Hr - 1, 7 do
		Liquid.referenceRow(plan1, tree, y, z)
		for x = 0, plan1.Wr - 1 do
			for m = 0, 3 do
				checkBytes("r=1", o1, plan1.Wr, x, y, 7, z[x * 7 + m + 1], 0, m)
			end
		end
	end
end

----------------------------------------------------------------------------------------
-- "point" vertical strategy: output row Y is the horizontal level-L row of rendered row
-- Y * 2^L + 2^(L-1) (clamped to the image)
----------------------------------------------------------------------------------------
do
	local W, H = 120, 90
	local tree = makeTree(81, W, H, 3)
	local model = makeModel(81, 8, 3, 4, 9, tree.P)
	local plan = Liquid.prepare(model, tree)
	for L = 1, 3 do
		local F = 2 ^ L
		local Wl, Hl = (W + F - 1) // F, (H + F - 1) // F
		local pt = buffer.create(Wl * Hl * 4)
		Liquid.render(plan, tree, pt, Wl, { epsilon = 0.5, level = L, vertical = "point" })
		local rows = buffer.create(Wl * H * 4)
		Liquid.render(plan, tree, rows, Wl, { epsilon = 0.5, level = L, vertical = "rows" })
		for Y = 0, Hl - 1 do
			local ys = math.min(Y * F + F // 2, H - 1)
			assert(buffer.readstring(pt, Y * Wl * 4, Wl * 4) == buffer.readstring(rows, ys * Wl * 4, Wl * 4), "point row")
		end
	end
end

----------------------------------------------------------------------------------------
-- cross-band deduplication only ever copies identical rows
----------------------------------------------------------------------------------------
do
	-- a tree with stacked equal leaves: many bands repeat earlier segment sequences
	local W, H = 128, 128
	local tree = Liquid.buildTree(W, H, 5, 3, function(x0: number, y0: number, _side: number, depth: number): boolean
		return depth < 3 or (x0 // 4 + y0 // 16) % 5 == 0
	end, function(x0: number, _y0: number, _side: number, _depth: number, out: buffer, at: number)
		for t = 0, 2 do
			buffer.writeu8(out, at + t, (x0 * 37 + t * 91) % 256)
		end
	end)
	local model = makeModel(71, 8, 3, 3, 8, tree.P)
	local plan = Liquid.prepare(model, tree)
	for _, L in { 0, 1 } do
		local F = 2 ^ L
		local a, b = buffer.create((W // F) * (H // F) * 4), buffer.create((W // F) * (H // F) * 4)
		local st = Liquid.newStats()
		Liquid.render(plan, tree, a, W // F, { epsilon = 0.5, level = L, stats = st })
		Liquid.render(plan, tree, b, W // F, { epsilon = 0.5, level = L, dedup = false })
		assert(buffer.tostring(a) == buffer.tostring(b), "dedup must not change pixels")
		assert(st.deduped > 0, "dedup exercised")
	end
end

----------------------------------------------------------------------------------------
-- Canvas: only the rendered rows are marked dirty
----------------------------------------------------------------------------------------
do
	local W, H = 128, 128
	local tree = makeTree(31, W, H, 3)
	local model = makeModel(31, 8, 3, 3, 8, tree.P)
	local plan = Liquid.prepare(model, tree)
	local canvas = Canvas.new(W, H, 0, 32)
	canvas:clearDirty()
	Liquid.renderCanvas(plan, tree, canvas, { epsilon = 0.5, x = 0, y = 40, w = W, h = 20, dx = 0, dy = 40 })
	for ty = 0, canvas.tilesY - 1 do
		for tx = 0, canvas.tilesX - 1 do
			local dirty = buffer.readu8(canvas.dirty, ty * canvas.tilesX + tx) == 1
			local touches = ty * 32 < 60 and ty * 32 + 32 > 40
			assert(dirty == touches, "dirty tiles are exactly the rendered rows")
		end
	end
	local ref = buffer.create(W * H * 4)
	Liquid.render(plan, tree, ref, W, { epsilon = 0.5 })
	for y = 40, 59 do
		for x = 0, W - 1 do
			assert(canvas:get(x, y) == buffer.readu32(ref, (y * W + x) * 4), "canvas pixels")
		end
	end
	assert(canvas:get(5, 10) == 0 and canvas:get(5, 70) == 0, "untouched rows stay untouched")
end

----------------------------------------------------------------------------------------
-- X3 endless textures: tiling invariance, T2 against the windowed reference, seam bound
----------------------------------------------------------------------------------------
do
	local W, H = 64, 64
	local tree = makeTree(41, W, H, 3, 6)
	local model = makeModel(41, 8, 3, 3, 7, tree.P, 30)
	local plan = Liquid.prepare(model, tree)
	local seed = 1234567
	local horizon = 2
	local endless: Liquid.Endless = { seed = seed, horizon = horizon }
	-- every virtual leaf carries the content of a stored leaf
	for _ = 1, 200 do
		local xs = math.floor(rnd(valuesChecked, 1, 3) * 2000) - 1000
		local ys = math.floor(rnd(valuesChecked, 2, 3) * 2000) - 1000
		valuesChecked += 1
		local leaf, depth = Liquid.virtualLeafAt(tree, xs, ys, seed)
		assert(leaf >= 0 and leaf < tree.leafCount and depth >= 0 and depth <= tree.maxDepth, "virtual leaf")
	end
	for _, L in { 0, 1 } do
		local F = 2 ^ L
		local rx, ry, rw, rh = -100 // F, -30 // F, 250 // F, 120 // F
		local big = buffer.create(rw * rh * 4)
		Liquid.render(plan, tree, big, rw, { epsilon = 0.5, level = L, x = rx, y = ry, w = rw, h = rh, endless = endless })
		-- tiles of every size and offset give the same pixels
		for _, tile in { 64 // F, 37, 23 } do
			local t = buffer.create(tile * tile * 4)
			for ty = ry, ry + rh - 1, tile do
				for tx = rx, rx + rw - 1, tile do
					Liquid.render(plan, tree, t, tile, { epsilon = 0.5, level = L, x = tx, y = ty, w = tile, h = tile, endless = endless })
					for yy = 0, tile - 1 do
						for xx = 0, tile - 1 do
							local X, Y = tx + xx, ty + yy
							if X < rx + rw and Y < ry + rh then
								assert(
									buffer.readu32(t, (yy * tile + xx) * 4) == buffer.readu32(big, ((Y - ry) * rw + X - rx) * 4),
									"X3: a pixel must not depend on the tiling"
								)
							end
						end
					end
				end
			end
		end
		-- T2 against the endless reference (each block stepped over its canonical window)
		if L == 0 then
			local z = {}
			for Y = ry, ry + rh - 1, 7 do
				for block = rx // plan.Sr, (rx + rw - 1) // plan.Sr do
					local wa = Liquid.referenceEndless(plan, tree, Y, block, horizon, seed, z)
					for X = math.max(rx, block * plan.Sr), math.min(rx + rw, (block + 1) * plan.Sr) - 1 do
						for m = 0, 2 do
							checkBytes("X3 T2", big, rw, X - rx, Y - ry, 3, z[(X - wa) * 3 + m + 1], 0.5, m)
						end
					end
				end
			end
		end
	end
	-- seam bound: two windows that both contain a pixel at distance >= horizon * Sr from
	-- their ends disagree there by at most seamBound
	local bound = Liquid.seamBound(plan, tree, horizon)
	local z1, z2 = {}, {}
	local worst = 0
	for Y = -20, 70, 9 do
		local wa1 = Liquid.referenceEndless(plan, tree, Y, 0, horizon, seed, z1) -- [-128, 192)
		local wa2 = Liquid.referenceEndless(plan, tree, Y, 1, horizon, seed, z2) -- [-64, 256)
		-- pixels at distance >= horizon * Sr = 128 from both windows' ends: [64, 64]
		for X = 64, 64 do
			for m = 0, 2 do
				local d = math.abs(z1[(X - wa1) * 3 + m + 1] - z2[(X - wa2) * 3 + m + 1])
				if d > worst then
					worst = d
				end
			end
		end
	end
	assert(worst <= bound, `X3 seam bound violated: {worst} > {bound}`)
	-- a-posteriori certificates: two windows overlapping at a pixel disagree there by at most
	-- the sum of their certificates (each bounds its distance to the infinite-row model)
	local tight = 0
	for Y = -20, 70, 3 do
		for _, X in { 0, 31, 64, 100, 127 } do
			local wa1 = Liquid.referenceEndless(plan, tree, Y, 0, horizon, seed, z1) -- [-128, 192)
			local wa2 = Liquid.referenceEndless(plan, tree, Y, 1, horizon, seed, z2) -- [-64, 256)
			local c1 = Liquid.windowCertificate(plan, tree, Y, wa1, wa1 + 5 * plan.Sr, X, X + 1, seed)
			local c2 = Liquid.windowCertificate(plan, tree, Y, wa2, wa2 + 5 * plan.Sr, X, X + 1, seed)
			for m = 0, 2 do
				local d = math.abs(z1[(X - wa1) * 3 + m + 1] - z2[(X - wa2) * 3 + m + 1])
				assert(d <= c1 + c2 + FP, `X3 certificate violated: {d} > {c1 + c2}`)
				if d > 0 and (c1 + c2) > 0 and d / (c1 + c2) > tight then
					tight = d / (c1 + c2)
				end
			end
		end
	end
	assert(tight > 0, "certificate test must be non-trivial")
	local st = Liquid.newStats()
	local tile = buffer.create(64 * 64 * 4)
	Liquid.render(plan, tree, tile, 64, { epsilon = 0.5, x = 64, y = 0, w = 64, h = 64, endless = endless, stats = st })
	assert(st.seam > 0 and st.seam < math.huge, "render reports its X3 certificate")
end

----------------------------------------------------------------------------------------
-- X2 Richardson LOD
----------------------------------------------------------------------------------------
do
	-- (a) exact on single exponentials: one tracked neuron, two segments per row, so each
	-- segment carries one exponential (forward in the right one, backward in the left one)
	local W = 256
	local tree = Liquid.buildTree(W, 4, 8, 1, function(_x0: number, _y0: number, _side: number, depth: number): boolean
		return depth < 1
	end, function(x0: number, _y0: number, _side: number, _depth: number, out: buffer, at: number)
		buffer.writeu8(out, at, if x0 < 128 then 20 else 230)
	end)
	local model = Liquid.newModel({ N = 2, I = 1, M = 1, K = 12, beta = { 0, 0 }, B = { 1, 1 }, kBase = { -64, -3 }, Cf = { 100, 80 }, Cb = { 100, 60 }, d = { 10 } })
	local plan = Liquid.prepare(model, tree)
	for L = 1, 4 do
		local zL, zU, zF, zE, disc, zLin, discLin = {}, {}, {}, {}, {}, {}, {}
		local nL = Liquid.renderRowValues(plan, tree, 0, L, 0, zL)
		Liquid.renderRowValues(plan, tree, 0, L + 1, 0, zU)
		local nF = Liquid.renderRowValues(plan, tree, 0, L - 1, 0, zE)
		Liquid.richardsonRow(zL, zU, nL, 1, zF, disc, true)
		Liquid.richardsonRow(zL, zU, nL, 1, zLin, discLin, false)
		local Fl = 2 ^ L
		local exactCount = 0
		for X = 0, nF - 1 do
			local XL = X // 2
			local sib = (XL // 2) * 2
			local lo = math.min(XL - 1, sib) * Fl
			local hi = math.max(XL + 3, sib + 2) * Fl
			local single = XL >= 1 and XL <= nL - 3 and ((lo >= 0 and hi <= 128) or (lo >= 128 and hi <= 256))
			local errGeo = math.abs(zF[X + 1] - zE[X + 1])
			local errLin = math.abs(zLin[X + 1] - zE[X + 1])
			if single then
				exactCount += 1
				assert(errGeo <= 1e-9, `X2 geometric prediction must be exact on single exponentials ({errGeo})`)
				-- the discrepancy bounds the affine error on single exponentials: |err| <= 1.5 e
				assert(errLin <= 1.5 * discLin[XL + 1] + 1e-9, "X2 discrepancy bound")
			end
			assert(errGeo <= errLin + 1e-9 or not single, "X2")
		end
		assert(exactCount > 10, "X2 exact case must be exercised")
		-- (c) mean preservation: each predicted pair averages back to the coarse value
		for X = 0, nL - 1 do
			assert(math.abs((zF[2 * X + 1] + zF[2 * X + 2]) / 2 - zL[X + 1]) <= 1e-9, "X2 mean preservation")
		end
	end
	-- (b) affine coefficients on arbitrary data: |err| <= (3|d2a| + |d2b|) / 8 <= max|d2| / 2
	for trial = 1, 50 do
		local n = 16
		local w = {}
		for j = 1, 4 * n do
			w[j] = rnd(j, trial, 77) * 255
		end
		local zL, zU = {}, {}
		for X = 0, 2 * n - 1 do
			zL[X + 1] = (w[2 * X + 1] + w[2 * X + 2]) / 2
		end
		for X = 0, n - 1 do
			zU[X + 1] = (w[4 * X + 1] + w[4 * X + 2] + w[4 * X + 3] + w[4 * X + 4]) / 4
		end
		local zF, disc = {}, {}
		Liquid.richardsonRow(zL, zU, 2 * n, 1, zF, disc, false)
		for P = 0, n - 1 do
			local w0, w1, w2, w3 = w[4 * P + 1], w[4 * P + 2], w[4 * P + 3], w[4 * P + 4]
			local d2a, d2b = w0 - 2 * w1 + w2, w1 - 2 * w2 + w3
			for p = 0, 3 do
				local err = math.abs(zF[4 * P + p + 1] - w[4 * P + p + 1])
				local bound = if p < 2 then (3 * math.abs(d2a) + math.abs(d2b)) / 8 else (math.abs(d2a) + 3 * math.abs(d2b)) / 8
				assert(err <= bound + 1e-9, "X2 affine error identity")
			end
		end
	end
	-- (d) predict, then refine rows in discrepancy order: after every row is refined the
	-- frame equals the exact render, and rows with zero discrepancy were already exact
	local W2, H2 = 128, 96
	local tree2 = makeTree(51, W2, H2, 3)
	local model2 = makeModel(51, 8, 3, 3, 9, tree2.P)
	local plan2 = Liquid.prepare(model2, tree2)
	local L = 2
	local Fm = 2 ^ (L - 1)
	local nF = W2 // Fm
	local pred = buffer.create(nF * H2 * 4)
	local order, rowDisc = Liquid.predictFiner(plan2, tree2, L, 0.25, pred, nF)
	local exact = buffer.create(nF * H2 * 4)
	Liquid.render(plan2, tree2, exact, nF, { epsilon = 0.25, level = L - 1, vertical = "rows" })
	assert(#order == H2 and rowDisc[order[1] + 1] >= rowDisc[order[H2] + 1], "refinement order")
	Liquid.renderRows(plan2, tree2, order, L - 1, 0.25, pred, nF)
	assert(buffer.tostring(pred) == buffer.tostring(exact), "X2 refinement converges to the exact level")
end

----------------------------------------------------------------------------------------
-- T7: bit-identical output in the interpreter and in native code. The constants were
-- recorded from this file's renders; tests/run.sh runs it in both runtimes, so a
-- difference in any op between them fails here. (Changing the renderer's arithmetic
-- schedule changes the constants: update them deliberately, never to silence a mismatch
-- between runtimes.)
----------------------------------------------------------------------------------------
do
	local hashes: { number } = {}
	local W, H = 200, 160
	local tree = makeTree(61, W, H, 3)
	local model = makeModel(61, 8, 3, 3, 12, tree.P)
	local plan = Liquid.prepare(model, tree)
	local out = buffer.create(W * H * 4)
	Liquid.render(plan, tree, out, W, { epsilon = 0.5 })
	table.insert(hashes, Liquid.hashBuffer(out))
	Liquid.render(plan, tree, out, W, { epsilon = 0 })
	table.insert(hashes, Liquid.hashBuffer(out))
	local o2 = buffer.create(50 * 40 * 4)
	Liquid.render(plan, tree, o2, 50, { epsilon = 0.25, level = 2 })
	table.insert(hashes, Liquid.hashBuffer(o2))
	local oe = buffer.create(90 * 70 * 4)
	Liquid.render(plan, tree, oe, 90, { epsilon = 0.5, level = 1, x = -40, y = 100, w = 90, h = 70, endless = { seed = 99, horizon = 1 } })
	table.insert(hashes, Liquid.hashBuffer(oe))
	local tree4 = makeTree(62, 96, 96, 2)
	local model7 = makeModel(62, 9, 2, 7, 9, tree4.P)
	local plan7 = Liquid.prepare(model7, tree4)
	local a7, b7 = buffer.create(96 * 96 * 4), buffer.create(96 * 96 * 4)
	Liquid.render(plan7, tree4, a7, 96, { epsilon = 0.5, out2 = b7 })
	table.insert(hashes, Liquid.hashBuffer(a7))
	table.insert(hashes, Liquid.hashBuffer(b7))
	local fine = buffer.create(100 * H * 4)
	Liquid.predictFiner(plan, tree, 2, 0.25, fine, 100)
	table.insert(hashes, Liquid.hashBuffer(fine))
	-- raw f64 bits of real-valued rows (event renderer at levels 0 and 2, and the reference):
	-- a single ulp of difference between the runtimes changes these hashes
	local vals = {}
	local bits = buffer.create(8 * W * 3 * 3)
	local at = 0
	for _, y in { 0, 37, 99 } do
		local nL = Liquid.renderRowValues(plan, tree, y, 0, 0.5, vals)
		for j = 1, nL * 3 do
			buffer.writef64(bits, at, vals[j])
			at += 8
		end
	end
	table.insert(hashes, Liquid.hashBuffer(bits))
	local bits2 = buffer.create(8 * 50 * 3)
	local nL2 = Liquid.renderRowValues(plan, tree, 41, 2, 0.5, vals)
	for j = 1, nL2 * 3 do
		buffer.writef64(bits2, (j - 1) * 8, vals[j])
	end
	table.insert(hashes, Liquid.hashBuffer(bits2))
	Liquid.referenceRow(plan, tree, 37, vals)
	local bits3 = buffer.create(8 * W * 3)
	for j = 1, W * 3 do
		buffer.writef64(bits3, (j - 1) * 8, vals[j])
	end
	table.insert(hashes, Liquid.hashBuffer(bits3))
	local RECORDED = { 1662153913, 2200940450, 207576219, 411133616, 3953465183, 3239534142, 4013711530, 3261783181, 1074859803, 1740988340 }
	local same = true
	for j = 1, #hashes do
		if hashes[j] ~= RECORDED[j] then
			same = false
		end
	end
	if not same then
		error("T7 hashes differ from the recorded constants: { " .. table.concat(hashes, ", ") .. " }")
	end
end

print("liquid tests ok", valuesChecked)
