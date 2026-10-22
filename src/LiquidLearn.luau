--!native
--!optimize 2
-- universe-at-home :: LiquidLearn
--
-- ALLAN's learning on the server (docs/LIQUID.md section 6; results and proofs in
-- docs/LIQUID_TRAINING.md). Pure Luau, deterministic ops only, no engine globals.
--
--   * shell-byte quadtree builder (exact integer means and deviations)
--   * the ALN binary codec (layout: header of src/Liquid.luau)
--   * exact row simulation in the Luau step order, bidirectional
--   * S1/S3 exact sufficient statistics: states quantised to 15-bit fixed point,
--     integer sums held in two limbs; plain mode (every pixel or every k-th) or
--     event mode (runs of identical state vectors, rows grouped by quadtree band),
--     which produces the same integers as plain mode with stride 1
--   * deterministic Cholesky ridge solve -> readout bytes
--   * S4 federated merge: messages of at most 1000 characters, a per-server
--     G-Counter ledger whose total does not depend on merge order, duplication or
--     delivery order
--   * S5 gain search: one superset accumulation, then coordinate descent over
--     kBase on exact sub-Gram matrices, scored on validation rows from statistics
--   * S6 online updates: add or subtract statistics, exact halving, re-solve
--   * a time-sliced trainer for Heartbeat
--   * renderExact: the reference renderer (every pixel stepped; epsilon = 0)
--
-- The ALN binary layout (version 1) and the model arithmetic are defined once, in the
-- header of src/Liquid.luau (the single source of truth). This module implements the
-- same layout and the same operation order (encode, decode, buildTree, renderExact)
-- without depending on the renderer; tests/liquid_learn.test.luau checks every byte
-- against tools/liquid_train.py and against Liquid.reference. Defaults used here:
-- Walsh reservoirs (b in [0, 1]) and INSTANT = -64 for neurons with k = 0 everywhere.
--
-- Training statistics (S3): q = floor(h * 32767 + 0.5), features s = (qf, qb, 32767),
-- D = 2N + 1. Entries in order: G upper triangle (row-major, i <= j), P (D x M,
-- row-major), YY (M), count; E = D(D+1)/2 + D*M + M + 1. Each entry is the exact
-- integer hi * 2^32 + lo, canonical when 0 <= lo < 2^32.

local MyMath = require("./MyMath")

local LiquidLearn = {}

local QSCALE = 32767
local TWO32 = 4294967296
local PENDING_LIMIT = 4194304 -- 2^22: max sample weight between limb normalisations
local MAX_RAW_CHUNK = 750 -- raw bytes per message (base64: 1000 characters <= 1 kB)
local HEADER = 22
local MAX_M = 8 -- output channels supported by the band accumulators

LiquidLearn.QSCALE = QSCALE
LiquidLearn.VERSION = 1
-- Maximum sample weight per accumulation pass and between limb normalisations. Any
-- value in [1, 2^22] keeps every partial sum below 2^53 (docs/LIQUID_TRAINING.md 7.1);
-- tests lower it to exercise band splitting.
LiquidLearn.pendingLimit = PENDING_LIMIT
LiquidLearn.INSTANT = -64
LiquidLearn.DEFAULT_SCALES = { -64, 0, -2, 2, -4, 4, 1, -1 }
LiquidLearn.DEFAULT_LAMBDA = 1e-7
LiquidLearn.MAX_MESSAGE_CHARS = 1000

export type Reservoir = {
	N: number,
	I: number,
	K: number,
	beta: { number },
	B: { number },
	kBase: { number },
}

export type Readout = {
	M: number,
	N: number,
	Cf: { number },
	Cb: { number },
	d: { number },
}

export type Tree = {
	width: number,
	height: number,
	maxDepth: number,
	rootLog2: number,
	I: number,
	bitCount: number,
	bits: buffer,
	leafCount: number,
	lx: { number },
	ly: { number },
	lsl: { number },
	bytes: buffer,
	nodeX: { number },
	nodeY: { number },
	nodeL: { number },
	nodeLeaf: { number }, -- 0-based leaf index, or -1 for an internal node
	nodeChild: { number }, -- 4 per node: 1-based child node ids (0 for leaves)
}

export type Stats = {
	D: number,
	M: number,
	E: number,
	hi: { number },
	lo: { number },
	pending: number,
}

local floor = math.floor
local sqrt = math.sqrt

----------------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------------

local function rootLog2For(w: number, h: number): number
	local s, l = 1, 0
	local m = if w > h then w else h
	while s < m do
		s *= 2
		l += 1
	end
	return l
end
LiquidLearn.rootLog2For = rootLog2For

local function gainTable(K: number): { number }
	local t = table.create(K, 1)
	for k = 2, K do
		t[k] = t[k - 1] * 0.5
	end
	return t
end

local function clampK(v: number, K: number): number
	if v < 0 then
		return 0
	elseif v > K - 1 then
		return K - 1
	end
	return v
end

-- Sylvester Hadamard entry (-1)^popcount(p & t).
local function walshSign(p: number, t: number): number
	local x = bit32.band(p, t)
	local par = 0
	while x ~= 0 do
		par = bit32.bxor(par, bit32.band(x, 1))
		x = bit32.rshift(x, 1)
	end
	return if par == 0 then 1 else -1
end

----------------------------------------------------------------------------------
-- structured reservoir: Walsh projections at a multi-scale spread of kBase
----------------------------------------------------------------------------------

-- Neuron i reads Walsh projection p(i) of the leaf bytes,
--   b = 1/2 + (1/I) * sum_t H[p][t] * (u_t - 1/2), in [0, 1] for u in [0, 1]^I,
-- stored as B[t] = H[p][t] / I and beta = 1/2 - s / (2 I) with s = sum_t H[p][t].
-- p(i) = proj[i] or (i - 1) % I; kBase[i] or scales[((i - 1) // I) % #scales + 1].
-- Same formulas and order as walsh_reservoir in tools/liquid_train.py.
function LiquidLearn.walshReservoir(
	N: number,
	I: number,
	K: number?,
	kBase: { number }?,
	scales: { number }?,
	proj: { number }?
): Reservoir
	local sc = scales or LiquidLearn.DEFAULT_SCALES
	local beta, B, kb = table.create(N, 0), table.create(N * I, 0), table.create(N, 0)
	for i = 1, N do
		local p = if proj then proj[i] else (i - 1) % I
		local s = 0
		for t = 0, I - 1 do
			local v = walshSign(p, t)
			s += v
			B[(i - 1) * I + t + 1] = v / I
		end
		beta[i] = 0.5 - s / (2 * I)
		kb[i] = if kBase then kBase[i] else sc[((i - 1) // I) % #sc + 1]
	end
	return { N = N, I = I, K = K or 16, beta = beta, B = B, kBase = kb }
end

-- Projection index of each neuron of a Walsh reservoir (matched against B rows).
function LiquidLearn.walshProjections(res: Reservoir): { number }
	local N, I = res.N, res.I
	local hn = 1
	while hn < I do
		hn *= 2
	end
	local out = table.create(N, 0)
	for i = 1, N do
		local found = -1
		for p = 0, hn - 1 do
			local ok = true
			for t = 0, I - 1 do
				if res.B[(i - 1) * I + t + 1] ~= walshSign(p, t) / I then
					ok = false
					break
				end
			end
			if ok then
				found = p
				break
			end
		end
		assert(found >= 0, "not a Walsh reservoir")
		out[i] = found
	end
	return out
end

----------------------------------------------------------------------------------
-- codec
----------------------------------------------------------------------------------

local function writeF64s(b: buffer, o: number, t: { number }): number
	for i = 1, #t do
		buffer.writef64(b, o, t[i])
		o += 8
	end
	return o
end

local function readF64s(b: buffer, o: number, n: number): ({ number }, number)
	local t = table.create(n, 0)
	for i = 1, n do
		t[i] = buffer.readf64(b, o)
		o += 8
	end
	return t, o
end

function LiquidLearn.encodeReservoir(res: Reservoir): buffer
	local b = buffer.create(8 * (2 * res.N + res.N * res.I))
	local o = writeF64s(b, 0, res.beta)
	o = writeF64s(b, o, res.B)
	writeF64s(b, o, res.kBase)
	return b
end

function LiquidLearn.encodeReadout(ro: Readout): buffer
	local b = buffer.create(8 * (2 * ro.M * ro.N + ro.M))
	local o = writeF64s(b, 0, ro.Cf)
	o = writeF64s(b, o, ro.Cb)
	writeF64s(b, o, ro.d)
	return b
end

function LiquidLearn.encodeTree(tree: Tree): buffer
	local nb = (tree.bitCount + 7) // 8
	local lb = tree.leafCount * tree.I
	local b = buffer.create(5 + nb + lb)
	buffer.writeu16(b, 0, tree.width)
	buffer.writeu16(b, 2, tree.height)
	buffer.writeu8(b, 4, tree.maxDepth)
	if nb > 0 then
		buffer.copy(b, 5, tree.bits, 0, nb)
	end
	if lb > 0 then
		buffer.copy(b, 5 + nb, tree.bytes, 0, lb)
	end
	return b
end

function LiquidLearn.encode(res: Reservoir, ro: Readout, tree: Tree): buffer
	assert(ro.N == res.N and tree.I == res.I, "model and tree disagree")
	local rb = LiquidLearn.encodeReservoir(res)
	local cb = LiquidLearn.encodeReadout(ro)
	local tb = LiquidLearn.encodeTree(tree)
	local b = buffer.create(8 + buffer.len(rb) + buffer.len(cb) + buffer.len(tb))
	buffer.writeu8(b, 0, 0x41)
	buffer.writeu8(b, 1, 0x4C)
	buffer.writeu8(b, 2, 0x4E)
	buffer.writeu8(b, 3, 1)
	buffer.writeu8(b, 4, res.N)
	buffer.writeu8(b, 5, res.I)
	buffer.writeu8(b, 6, ro.M)
	buffer.writeu8(b, 7, res.K)
	local o = 8
	buffer.copy(b, o, rb)
	o += buffer.len(rb)
	buffer.copy(b, o, cb)
	o += buffer.len(cb)
	buffer.copy(b, o, tb)
	return b
end

-- Walks the preorder split bits (bits buffer, starting at bit 0) and fills the node
-- arrays and leaf geometry. Returns the number of bits read.
local function attachNodes(tree: Tree): number
	local nodeX, nodeY, nodeL, nodeLeaf, nodeChild = {}, {}, {}, {}, {}
	local lx, ly, lsl = {}, {}, {}
	local bits = tree.bits
	local nbytes = buffer.len(bits)
	local bitPos = 0
	local leaf = 0
	local maxDepth = tree.maxDepth
	local function walk(x: number, y: number, l: number, depth: number): number
		local id = #nodeX + 1
		nodeX[id], nodeY[id], nodeL[id], nodeLeaf[id] = x, y, l, -1
		local base = (id - 1) * 4
		nodeChild[base + 1], nodeChild[base + 2], nodeChild[base + 3], nodeChild[base + 4] = 0, 0, 0, 0
		local split = false
		if depth < maxDepth then
			assert(bitPos // 8 < nbytes, "truncated split bits")
			split = bit32.extract(buffer.readu8(bits, bitPos // 8), bitPos % 8, 1) == 1
			bitPos += 1
		end
		if split then
			local h = bit32.lshift(1, l - 1)
			nodeChild[base + 1] = walk(x, y, l - 1, depth + 1)
			nodeChild[base + 2] = walk(x + h, y, l - 1, depth + 1)
			nodeChild[base + 3] = walk(x, y + h, l - 1, depth + 1)
			nodeChild[base + 4] = walk(x + h, y + h, l - 1, depth + 1)
		else
			nodeLeaf[id] = leaf
			leaf += 1
			lx[leaf], ly[leaf], lsl[leaf] = x, y, l
		end
		return id
	end
	walk(0, 0, tree.rootLog2, 0)
	tree.nodeX, tree.nodeY, tree.nodeL, tree.nodeLeaf, tree.nodeChild = nodeX, nodeY, nodeL, nodeLeaf, nodeChild
	tree.lx, tree.ly, tree.lsl = lx, ly, lsl
	tree.leafCount = leaf
	return bitPos
end

local function newTree(width: number, height: number, maxDepth: number, I: number, bits: buffer): Tree
	return {
		width = width,
		height = height,
		maxDepth = maxDepth,
		rootLog2 = rootLog2For(width, height),
		I = I,
		bitCount = 0,
		bits = bits,
		leafCount = 0,
		lx = {},
		ly = {},
		lsl = {},
		bytes = buffer.create(1),
		nodeX = {},
		nodeY = {},
		nodeL = {},
		nodeLeaf = {},
		nodeChild = {},
	}
end

-- Parses a quadtree section starting at byte offset o. Returns the tree and the end offset.
function LiquidLearn.decodeTree(b: buffer, o: number, I: number): (Tree, number)
	local width = buffer.readu16(b, o)
	local height = buffer.readu16(b, o + 2)
	local maxDepth = buffer.readu8(b, o + 4)
	local bitStart = o + 5
	local rest = buffer.len(b) - bitStart
	local view = buffer.create(math.max(rest, 1))
	if rest > 0 then
		buffer.copy(view, 0, b, bitStart, rest)
	end
	local tree = newTree(width, height, maxDepth, I, view)
	local nbits = attachNodes(tree)
	tree.bitCount = nbits
	local nb = (nbits + 7) // 8
	local bits = buffer.create(math.max(nb, 1))
	if nb > 0 then
		buffer.copy(bits, 0, b, bitStart, nb)
	end
	tree.bits = bits
	local lb = tree.leafCount * I
	local leafStart = bitStart + nb
	assert(leafStart + lb <= buffer.len(b), "truncated leaf bytes")
	tree.bytes = buffer.create(math.max(lb, 1))
	if lb > 0 then
		buffer.copy(tree.bytes, 0, b, leafStart, lb)
	end
	return tree, leafStart + lb
end

function LiquidLearn.decode(b: buffer): (Reservoir, Readout, Tree)
	assert(buffer.len(b) >= 8, "too short")
	assert(buffer.readu8(b, 0) == 0x41 and buffer.readu8(b, 1) == 0x4C and buffer.readu8(b, 2) == 0x4E, "bad magic")
	assert(buffer.readu8(b, 3) == 1, "unsupported ALN version")
	local N, I, M, K = buffer.readu8(b, 4), buffer.readu8(b, 5), buffer.readu8(b, 6), buffer.readu8(b, 7)
	local o = 8
	local beta, B, kBase, Cf, Cb, d
	beta, o = readF64s(b, o, N)
	B, o = readF64s(b, o, N * I)
	kBase, o = readF64s(b, o, N)
	Cf, o = readF64s(b, o, M * N)
	Cb, o = readF64s(b, o, M * N)
	d, o = readF64s(b, o, M)
	local tree = LiquidLearn.decodeTree(b, o, I)
	return { N = N, I = I, K = K, beta = beta, B = B, kBase = kBase }, { M = M, N = N, Cf = Cf, Cb = Cb, d = d }, tree
end

----------------------------------------------------------------------------------
-- shell-byte quadtree builder (exact integer arithmetic)
----------------------------------------------------------------------------------

-- pixels: `stride` bytes per pixel, channels at byte offsets 0 .. C-1, row-major
-- width x height. A node splits iff depth < maxDepth, it covers at least one pixel,
-- and max over channels of max(max_c - mean_c, mean_c - min_c) > theta, with the
-- integer mean (2 sum + count) // (2 count). Leaf bytes are the means (I = C).
-- Same rule as build_tree in tools/liquid_train.py: identical bytes.
function LiquidLearn.buildTree(pixels: buffer, width: number, height: number, stride: number, C: number, theta: number, minLeaf: number?): Tree
	local rl = rootLog2For(width, height)
	local S = bit32.lshift(1, rl)
	local ml = 0
	local mlv = minLeaf or 1
	while bit32.lshift(1, ml) < mlv do
		ml += 1
	end
	assert(bit32.lshift(1, ml) == mlv, "minLeaf must be a power of two")
	local maxDepth = rl - ml
	-- pyramid levels 1..rl: node (nx, ny) of side 2^l at index ny * (S >> l) + nx
	local sums: { { number } } = {}
	local mins: { buffer } = {}
	local maxs: { buffer } = {}
	local cnts: { { number } } = {}
	for l = 1, rl do
		local n = bit32.rshift(S, l)
		sums[l] = table.create(n * n * C, 0)
		mins[l] = buffer.create(n * n * C)
		maxs[l] = buffer.create(n * n * C)
		buffer.fill(mins[l], 0, 255)
		cnts[l] = table.create(n * n, 0)
	end
	if rl >= 1 then
		local n = bit32.rshift(S, 1)
		local s1, mn1, mx1, c1 = sums[1], mins[1], maxs[1], cnts[1]
		for y = 0, height - 1 do
			local nrow = (y // 2) * n
			for x = 0, width - 1 do
				local node = nrow + x // 2
				c1[node + 1] += 1
				local o = (y * width + x) * stride
				local base = node * C
				for c = 0, C - 1 do
					local v = buffer.readu8(pixels, o + c)
					s1[base + c + 1] += v
					if v < buffer.readu8(mn1, base + c) then
						buffer.writeu8(mn1, base + c, v)
					end
					if v > buffer.readu8(mx1, base + c) then
						buffer.writeu8(mx1, base + c, v)
					end
				end
			end
		end
		for l = 2, rl do
			local nf = bit32.rshift(S, l - 1)
			local nc = bit32.rshift(nf, 1)
			local sf, mnf, mxf, cf = sums[l - 1], mins[l - 1], maxs[l - 1], cnts[l - 1]
			local sc, mnc, mxc, cc = sums[l], mins[l], maxs[l], cnts[l]
			for y = 0, nc - 1 do
				for x = 0, nc - 1 do
					local node = y * nc + x
					local a = (2 * y) * nf + 2 * x
					local k1, k2, k3, k4 = a, a + 1, a + nf, a + nf + 1
					cc[node + 1] = cf[k1 + 1] + cf[k2 + 1] + cf[k3 + 1] + cf[k4 + 1]
					for c = 0, C - 1 do
						local s, lo, hi = 0, 255, 0
						for q = 1, 4 do
							local kid = if q == 1 then k1 elseif q == 2 then k2 elseif q == 3 then k3 else k4
							if cf[kid + 1] > 0 then
								local kc = kid * C + c
								s += sf[kc + 1]
								local a1 = buffer.readu8(mnf, kc)
								local b1 = buffer.readu8(mxf, kc)
								if a1 < lo then
									lo = a1
								end
								if b1 > hi then
									hi = b1
								end
							end
						end
						sc[node * C + c + 1] = s
						buffer.writeu8(mnc, node * C + c, lo)
						buffer.writeu8(mxc, node * C + c, hi)
					end
				end
			end
		end
	end
	local bitBuf = buffer.create(math.max(1, S * S // 4 + 1))
	local bitCount = 0
	local leafBytes = buffer.create(math.max(1, S * S * C))
	local leafCount = 0
	local means = table.create(C, 0)
	local function nodeStats(x: number, y: number, l: number): (number, number)
		if l == 0 then
			if x >= width or y >= height then
				for c = 1, C do
					means[c] = 0
				end
				return 0, 0
			end
			local o = (y * width + x) * stride
			for c = 1, C do
				means[c] = buffer.readu8(pixels, o + c - 1)
			end
			return 1, 0
		end
		local n = bit32.rshift(S, l)
		local node = bit32.rshift(y, l) * n + bit32.rshift(x, l)
		local cnt = cnts[l][node + 1]
		if cnt == 0 then
			for c = 1, C do
				means[c] = 0
			end
			return 0, 0
		end
		local dev = 0
		local s, mn, mx = sums[l], mins[l], maxs[l]
		for c = 1, C do
			local k = node * C + c - 1
			local mean = (2 * s[k + 1] + cnt) // (2 * cnt)
			means[c] = mean
			local d1 = buffer.readu8(mx, k) - mean
			local d2 = mean - buffer.readu8(mn, k)
			if d1 > dev then
				dev = d1
			end
			if d2 > dev then
				dev = d2
			end
		end
		return cnt, dev
	end
	local function walk(x: number, y: number, l: number, depth: number)
		local cnt, dev = nodeStats(x, y, l)
		local split = false
		if depth < maxDepth then
			split = cnt > 0 and dev > theta
			if split then
				local byte = bitCount // 8
				buffer.writeu8(bitBuf, byte, bit32.bor(buffer.readu8(bitBuf, byte), bit32.lshift(1, bitCount % 8)))
			end
			bitCount += 1
		end
		if split then
			local h = bit32.lshift(1, l - 1)
			walk(x, y, l - 1, depth + 1)
			walk(x + h, y, l - 1, depth + 1)
			walk(x, y + h, l - 1, depth + 1)
			walk(x + h, y + h, l - 1, depth + 1)
		else
			local o = leafCount * C
			for c = 1, C do
				buffer.writeu8(leafBytes, o + c - 1, means[c])
			end
			leafCount += 1
		end
	end
	walk(0, 0, rl, 0)
	local nb = (bitCount + 7) // 8
	local bits = buffer.create(math.max(nb, 1))
	if nb > 0 then
		buffer.copy(bits, 0, bitBuf, 0, nb)
	end
	local tree = newTree(width, height, maxDepth, C, bits)
	tree.bitCount = attachNodes(tree)
	assert(tree.leafCount == leafCount and tree.bitCount == bitCount, "tree walk mismatch")
	tree.bytes = buffer.create(math.max(leafCount * C, 1))
	buffer.copy(tree.bytes, 0, leafBytes, 0, leafCount * C)
	return tree
end

----------------------------------------------------------------------------------
-- rows: segments and exact bidirectional states
----------------------------------------------------------------------------------

export type Rows = {
	tree: Tree,
	res: Reservoir,
	r: number,
	W: number, -- row length at render scale
	N: number,
	D: number,
	leafB: { number }, -- index leaf * N + i (leaf 0-based, i 1-based)
	leafG: { number },
	segX0: { number },
	segX1: { number },
	segLeaf: { number },
	segCount: number,
	groupEnd: number, -- tree rows y .. groupEnd-1 cross the same leaves
	stack: { number },
	-- quantised features of the current band, feature-major: (j - 1) * W + x + 1
	feat: { number },
	-- band accumulators: sample weight per column, target sums per column
	-- ((m - 1) * W + x + 1), and the compacted terms of the band
	w: { number },
	colY: { number },
	termF: { number },
	termW: { number },
	termY: { number },
	termK: number,
	gF: { number }, -- active term source for bandGram: the term arrays or the band itself
	gW: { number },
	gY: { number },
	wf: { number },
	wf2: { number },
	uniq: { number },
	alias: { number },
	gu: { number },
	su: { number },
	pu: { number },
}

-- Per-leaf targets b and gains g in the exact order. r = log2(render scale).
function LiquidLearn.newRows(res: Reservoir, tree: Tree, r: number?): Rows
	local rr = r or 0
	local N, I, K = res.N, res.I, res.K
	local gt = gainTable(K)
	local L = tree.leafCount
	local leafB = table.create(L * N, 0)
	local leafG = table.create(L * N, 0)
	local bytes = tree.bytes
	local beta, B, kBase = res.beta, res.B, res.kBase
	local u = table.create(I, 0)
	for leaf = 0, L - 1 do
		for t = 1, I do
			u[t] = buffer.readu8(bytes, leaf * I + t - 1) / 255
		end
		local sl = tree.lsl[leaf + 1]
		for i = 1, N do
			local b = beta[i]
			for t = 1, I do
				b = b + B[(i - 1) * I + t] * u[t]
			end
			leafB[leaf * N + i] = b
			leafG[leaf * N + i] = gt[clampK(kBase[i] + sl + rr, K) + 1]
		end
	end
	local W = bit32.lshift(tree.width, rr)
	return {
		tree = tree,
		res = res,
		r = rr,
		W = W,
		N = N,
		D = 2 * N + 1,
		leafB = leafB,
		leafG = leafG,
		segX0 = {},
		segX1 = {},
		segLeaf = {},
		segCount = 0,
		groupEnd = 0,
		stack = {},
		feat = table.create(W * (2 * N + 1), 0),
		w = table.create(W, 0),
		colY = table.create(MAX_M * W, 0),
		termF = table.create(W * (2 * N + 1), 0),
		termW = table.create(W, 0),
		termY = table.create(MAX_M * W, 0),
		termK = 0,
		gF = {},
		gW = {},
		gY = {},
		wf = table.create(W, 0),
		wf2 = table.create(W, 0),
		uniq = table.create(2 * N, 0),
		alias = table.create(2 * N, 0),
		gu = table.create(4 * N * N, 0),
		su = table.create(2 * N, 0),
		pu = table.create(2 * N * MAX_M, 0),
	}
end

-- Leaves crossed by tree row y, in increasing x, at render scale. Also sets groupEnd.
function LiquidLearn.rowSegments(rows: Rows, y: number): number
	local tree = rows.tree
	local nodeX, nodeY, nodeL, nodeLeaf, nodeChild = tree.nodeX, tree.nodeY, tree.nodeL, tree.nodeLeaf, tree.nodeChild
	local width = tree.width
	local r = rows.r
	local segX0, segX1, segLeaf = rows.segX0, rows.segX1, rows.segLeaf
	local stack = rows.stack
	local sp = 1
	stack[1] = 1
	local n = 0
	local groupEnd = tree.height
	while sp > 0 do
		local id = stack[sp]
		sp -= 1
		local x0 = nodeX[id]
		if x0 < width then
			local leaf = nodeLeaf[id]
			if leaf >= 0 then
				local side = bit32.lshift(1, nodeL[id])
				local x1 = x0 + side
				if x1 > width then
					x1 = width
				end
				n += 1
				segX0[n] = bit32.lshift(x0, r)
				segX1[n] = bit32.lshift(x1, r)
				segLeaf[n] = leaf
				local bottom = nodeY[id] + side
				if bottom < groupEnd then
					groupEnd = bottom
				end
			else
				local base = (id - 1) * 4
				local h = bit32.lshift(1, nodeL[id] - 1)
				if y < nodeY[id] + h then
					stack[sp + 1] = nodeChild[base + 2]
					stack[sp + 2] = nodeChild[base + 1]
				else
					stack[sp + 1] = nodeChild[base + 4]
					stack[sp + 2] = nodeChild[base + 3]
				end
				sp += 2
			end
		end
	end
	rows.segCount = n
	rows.groupEnd = groupEnd
	return n
end

-- Exact float states of the current segments: hf, hb at index x * N + i.
function LiquidLearn.simulate(rows: Rows, hf: { number }, hb: { number })
	local N = rows.N
	local leafB, leafG = rows.leafB, rows.leafG
	local segX0, segX1, segLeaf = rows.segX0, rows.segX1, rows.segLeaf
	local n = rows.segCount
	for i = 1, N do
		local h = leafB[segLeaf[1] * N + i]
		for s = 1, n do
			local k = segLeaf[s] * N + i
			local b, g = leafB[k], leafG[k]
			for x = segX0[s], segX1[s] - 1 do
				h = h + (b - h) * g
				hf[x * N + i] = h
			end
		end
		h = leafB[segLeaf[n] * N + i]
		for s = n, 1, -1 do
			local k = segLeaf[s] * N + i
			local b, g = leafB[k], leafG[k]
			for x = segX1[s] - 1, segX0[s], -1 do
				h = h + (b - h) * g
				hb[x * N + i] = h
			end
		end
	end
end

-- Quantised features of the current segments into rows.feat, feature-major:
-- feat[(j - 1) * W + x + 1], j = 1..N forward, N+1..2N backward, D the constant.
-- Neurons are uncoupled, so a band's states can be computed in neuron ranges
-- [i0, i1] (the time-sliced trainer does this); the constant column is written
-- with the last neuron.
function LiquidLearn.simulateQ(rows: Rows, i0: number?, i1: number?)
	local N, D, W = rows.N, rows.D, rows.W
	local feat = rows.feat
	local leafB, leafG = rows.leafB, rows.leafG
	local segX0, segX1, segLeaf = rows.segX0, rows.segX1, rows.segLeaf
	local n = rows.segCount
	local last = i1 or N
	local i = i0 or 1
	-- four neurons per pass: four independent recurrences hide the latency of the
	-- step (each neuron's own operation sequence, and therefore its bits, is unchanged)
	while i + 3 <= last do
		local i2, i3, i4 = i + 1, i + 2, i + 3
		local k0 = segLeaf[1] * N
		local h1, h2, h3, h4 = leafB[k0 + i], leafB[k0 + i2], leafB[k0 + i3], leafB[k0 + i4]
		local o1, o2, o3, o4 = (i - 1) * W + 1, i * W + 1, (i + 1) * W + 1, (i + 2) * W + 1
		for sg = 1, n do
			local k = segLeaf[sg] * N
			local b1, b2, b3, b4 = leafB[k + i], leafB[k + i2], leafB[k + i3], leafB[k + i4]
			local g1, g2, g3, g4 = leafG[k + i], leafG[k + i2], leafG[k + i3], leafG[k + i4]
			for x = segX0[sg], segX1[sg] - 1 do
				h1 = h1 + (b1 - h1) * g1
				h2 = h2 + (b2 - h2) * g2
				h3 = h3 + (b3 - h3) * g3
				h4 = h4 + (b4 - h4) * g4
				feat[o1 + x] = floor(h1 * 32767 + 0.5)
				feat[o2 + x] = floor(h2 * 32767 + 0.5)
				feat[o3 + x] = floor(h3 * 32767 + 0.5)
				feat[o4 + x] = floor(h4 * 32767 + 0.5)
			end
		end
		local kn = segLeaf[n] * N
		h1, h2, h3, h4 = leafB[kn + i], leafB[kn + i2], leafB[kn + i3], leafB[kn + i4]
		o1, o2, o3, o4 = (N + i - 1) * W + 1, (N + i) * W + 1, (N + i + 1) * W + 1, (N + i + 2) * W + 1
		for sg = n, 1, -1 do
			local k = segLeaf[sg] * N
			local b1, b2, b3, b4 = leafB[k + i], leafB[k + i2], leafB[k + i3], leafB[k + i4]
			local g1, g2, g3, g4 = leafG[k + i], leafG[k + i2], leafG[k + i3], leafG[k + i4]
			for x = segX1[sg] - 1, segX0[sg], -1 do
				h1 = h1 + (b1 - h1) * g1
				h2 = h2 + (b2 - h2) * g2
				h3 = h3 + (b3 - h3) * g3
				h4 = h4 + (b4 - h4) * g4
				feat[o1 + x] = floor(h1 * 32767 + 0.5)
				feat[o2 + x] = floor(h2 * 32767 + 0.5)
				feat[o3 + x] = floor(h3 * 32767 + 0.5)
				feat[o4 + x] = floor(h4 * 32767 + 0.5)
			end
		end
		i += 4
	end
	while i <= last do
		local h = leafB[segLeaf[1] * N + i]
		local of = (i - 1) * W + 1
		for sg = 1, n do
			local k = segLeaf[sg] * N + i
			local b, g = leafB[k], leafG[k]
			for x = segX0[sg], segX1[sg] - 1 do
				h = h + (b - h) * g
				feat[of + x] = floor(h * 32767 + 0.5)
			end
		end
		h = leafB[segLeaf[n] * N + i]
		local ob = (N + i - 1) * W + 1
		for sg = n, 1, -1 do
			local k = segLeaf[sg] * N + i
			local b, g = leafB[k], leafG[k]
			for x = segX1[sg] - 1, segX0[sg], -1 do
				h = h + (b - h) * g
				feat[ob + x] = floor(h * 32767 + 0.5)
			end
		end
		i += 1
	end
	if last == N then
		local oc = (D - 1) * W + 1
		for x = 0, W - 1 do
			feat[oc + x] = QSCALE
		end
	end
end

----------------------------------------------------------------------------------
-- reference renderer (epsilon = 0: every pixel stepped and evaluated)
----------------------------------------------------------------------------------

-- M bytes per pixel, row-major, at render scale 2^r. Rows of one quadtree band are
-- identical and copied.
function LiquidLearn.renderExact(res: Reservoir, ro: Readout, tree: Tree, r: number?): buffer
	local rows = LiquidLearn.newRows(res, tree, r)
	local N, M = res.N, ro.M
	local W = rows.W
	local rep = bit32.lshift(1, rows.r)
	local out = buffer.create(W * tree.height * rep * M)
	local hf = table.create(W * N, 0)
	local hb = table.create(W * N, 0)
	local Cf, Cb, d = ro.Cf, ro.Cb, ro.d
	local rowBytes = W * M
	local y = 0
	while y < tree.height do
		LiquidLearn.rowSegments(rows, y)
		LiquidLearn.simulate(rows, hf, hb)
		local first = y * rep * rowBytes
		for x = 0, W - 1 do
			local hx = x * N
			for m = 1, M do
				local cm = (m - 1) * N
				local z = d[m]
				for i = 1, N do
					z = z + Cf[cm + i] * hf[hx + i]
				end
				for i = 1, N do
					z = z + Cb[cm + i] * hb[hx + i]
				end
				local v = floor(z + 0.5)
				buffer.writeu8(out, first + x * M + m - 1, if v < 0 then 0 elseif v > 255 then 255 else v)
			end
		end
		for k = y * rep + 1, rows.groupEnd * rep - 1 do
			buffer.copy(out, k * rowBytes, out, first, rowBytes)
		end
		y = rows.groupEnd
	end
	return out
end

----------------------------------------------------------------------------------
-- exact statistics (S1, S3)
----------------------------------------------------------------------------------

function LiquidLearn.newStats(D: number, M: number): Stats
	local E = D * (D + 1) // 2 + D * M + M + 1
	return { D = D, M = M, E = E, hi = table.create(E, 0), lo = table.create(E, 0), pending = 0 }
end

-- Canonical form: 0 <= lo < 2^32 for every entry. Exact while |lo| < 2^53.
local function normalise(st: Stats)
	local hi, lo = st.hi, st.lo
	for e = 1, st.E do
		local v = lo[e]
		if v >= TWO32 or v < 0 then
			local c = floor(v / TWO32)
			lo[e] = v - c * TWO32
			hi[e] += c
		end
	end
	st.pending = 0
end
LiquidLearn.normalise = normalise

local function weightLimit(): number
	local lim = LiquidLearn.pendingLimit
	assert(lim >= 1 and lim <= PENDING_LIMIT and lim % 1 == 0, "pendingLimit must be an integer in [1, 2^22]")
	return lim
end

function LiquidLearn.copyStats(st: Stats): Stats
	local o = LiquidLearn.newStats(st.D, st.M)
	table.move(st.hi, 1, st.E, 1, o.hi)
	table.move(st.lo, 1, st.E, 1, o.lo)
	o.pending = st.pending
	return o
end

local function canonical(st: Stats): Stats
	if st.pending == 0 then
		local ok = true
		local lo = st.lo
		for e = 1, st.E do
			local v = lo[e]
			if v >= TWO32 or v < 0 then
				ok = false
				break
			end
		end
		if ok then
			return st
		end
	end
	local c = LiquidLearn.copyStats(st)
	normalise(c)
	return c
end

-- a = a + b, exact; both stay canonical.
function LiquidLearn.addStats(a: Stats, b: Stats)
	assert(a.E == b.E and a.D == b.D and a.M == b.M, "stats shape mismatch")
	normalise(a)
	local bb = canonical(b)
	local ahi, alo, bhi, blo = a.hi, a.lo, bb.hi, bb.lo
	for e = 1, a.E do
		ahi[e] += bhi[e]
		alo[e] += blo[e]
	end
	normalise(a)
end

-- a = a - b, exact (sliding windows).
function LiquidLearn.subStats(a: Stats, b: Stats)
	assert(a.E == b.E, "stats shape mismatch")
	normalise(a)
	local bb = canonical(b)
	for e = 1, a.E do
		a.hi[e] -= bb.hi[e]
		a.lo[e] -= bb.lo[e]
	end
	normalise(a)
end

-- Every entry v becomes floor(v / 2), exactly: deterministic forgetting.
function LiquidLearn.halveStats(a: Stats)
	normalise(a)
	for e = 1, a.E do
		local h = a.hi[e]
		local hh = floor(h / 2)
		local carry = h - hh * 2
		a.hi[e] = hh
		a.lo[e] = floor((carry * TWO32 + a.lo[e]) / 2)
	end
	normalise(a)
end

function LiquidLearn.statsEqual(a: Stats, b: Stats): boolean
	if a.E ~= b.E then
		return false
	end
	local ca, cb = canonical(a), canonical(b)
	for e = 1, a.E do
		if ca.hi[e] ~= cb.hi[e] or ca.lo[e] ~= cb.lo[e] then
			return false
		end
	end
	return true
end

local function entryFloat(st: Stats, e: number): number
	return st.hi[e] * TWO32 + st.lo[e]
end
LiquidLearn.entryFloat = entryFloat

local function triOffsets(D: number): { number }
	local off = table.create(D, 0)
	local acc = 0
	for i = 1, D do
		off[i] = acc
		acc += D - i + 1
	end
	return off
end
LiquidLearn.triOffsets = triOffsets

export type AccumOptions = {
	stride: number?, -- sample render pixel (x, y) iff (x + y) % stride == 0 (default 1)
	event: boolean?, -- merge runs of identical feature vectors into weighted terms
	targetStride: number?, -- bytes per target pixel (default M); channels 0 .. M-1
	naive: boolean?, -- per-sample outer products (the S2 cost model; benchmark only)
}

local offCache: { [number]: { number } } = {}
local function offsetsFor(D: number): { number }
	local o = offCache[D]
	if o == nil then
		o = triOffsets(D)
		offCache[D] = o
	end
	return o
end

-- Band accumulation. The rows of one quadtree band share their features, so with
-- w(x) = number of sampled pixels in column x of the band and Y_m(x) their target
-- sum, the band contributes
--   G[i][j] += sum_x w(x) f_i(x) f_j(x),  P[i][m] += sum_x f_i(x) Y_m(x),
--   count += sum_x w(x),  YY_m += sum of y_m^2 over the sampled pixels.
-- These are the same integers as visiting every sampled pixel (exact arithmetic,
-- every partial sum below 2^53), at the cost of one row of products per band.
-- Event mode merges consecutive columns with identical features into one term.

-- Clears the band accumulators (call after simulateQ for a new band).
function LiquidLearn.bandReset(rows: Rows, M: number)
	local W = rows.W
	local w, colY = rows.w, rows.colY
	for x = 1, W do
		w[x] = 0
	end
	for i = 1, W * M do
		colY[i] = 0
	end
	rows.termK = 0
end

-- Adds the sampled targets of render rows [yr0, yr1), columns [x0, x1).
function LiquidLearn.bandTargets(st: Stats, rows: Rows, target: buffer, yr0: number, yr1: number, x0: number, x1: number, o: AccumOptions)
	local M = st.M
	local W = rows.W
	local w, colY = rows.w, rows.colY
	local tstride = o.targetStride or M
	local stride = o.stride or 1
	local lo = st.lo
	local D = rows.D
	local yb = D * (D + 1) // 2 + D * M
	local rowBytes = W * tstride
	for yr = yr0, yr1 - 1 do
		local rowOff = yr * rowBytes
		local first = x0 + (stride - ((x0 + yr) % stride)) % stride
		for x = first, x1 - 1, stride do
			w[x + 1] += 1
			local to = rowOff + x * tstride
			for m = 1, M do
				local v = buffer.readu8(target, to + m - 1)
				colY[(m - 1) * W + x + 1] += v
				lo[yb + m] += v * v
			end
		end
	end
end

-- True when every column of the band has at least one sampled pixel.
function LiquidLearn.bandAllSampled(rows: Rows): boolean
	local w = rows.w
	for x = 1, rows.W do
		if w[x] == 0 then
			return false
		end
	end
	return true
end

-- Plain mode with every column sampled: the band's columns are the terms, read in
-- place (no copy).
function LiquidLearn.bandTermsIdentity(rows: Rows): number
	rows.gF, rows.gW, rows.gY = rows.feat, rows.w, rows.colY
	rows.termK = rows.W
	return rows.W
end

-- Appends the terms of columns [x0, x1) with w > 0: one term per column, or per run
-- of identical features in event mode (runs never cross x1). x0 = 0 starts a new
-- list. Returns the number of terms so far.
function LiquidLearn.bandTerms(rows: Rows, M: number, o: AccumOptions, x0: number?, x1: number?): number
	local W, D = rows.W, rows.D
	local feat, w, colY = rows.feat, rows.w, rows.colY
	local tF, tW, tY = rows.termF, rows.termW, rows.termY
	rows.gF, rows.gW, rows.gY = tF, tW, tY
	local event = o.event == true
	local xa, xb = x0 or 0, x1 or W
	local K = if xa == 0 then 0 else rows.termK
	local x = xa
	while x < xb do
		if w[x + 1] == 0 then
			x += 1
			continue
		end
		local xe = x + 1
		if event then
			while xe < xb do
				local same = true
				for j = 1, D - 1 do
					local oj = (j - 1) * W + 1
					if feat[oj + xe] ~= feat[oj + x] then
						same = false
						break
					end
				end
				if not same then
					break
				end
				xe += 1
			end
		end
		local ws = 0
		for xx = x, xe - 1 do
			ws += w[xx + 1]
		end
		if ws > 0 then
			K += 1
			tW[K] = ws
			for j = 1, D do
				tF[(j - 1) * W + K] = feat[(j - 1) * W + x + 1]
			end
			for m = 1, M do
				local om = (m - 1) * W + 1
				local sy = 0
				for xx = x, xe - 1 do
					sy += colY[om + xx]
				end
				tY[(m - 1) * W + K] = sy
			end
		end
		x = xe
	end
	rows.termK = K
	return K
end

-- Adds terms [k0, k1) (1-based, inclusive k0) of the band to G, P and count.
--  * Exact column dedupe: varying feature columns that are bit-identical over these
--    terms (an instant neuron's forward and backward features almost always are) are
--    multiplied once and their products scattered to every aliased entry.
--  * Inner products with 2 x 4 register blocking: two unique columns against four
--    share each load.
--  * The constant feature's row and column are scaled sums.
-- Every partial sum is an integer below 2^53, so the result equals any other order.
function LiquidLearn.bandGram(st: Stats, rows: Rows, k0: number, k1: number)
	local D, M, W = rows.D, st.M, rows.W
	assert(st.D == D and M <= MAX_M, "statistics do not match the reservoir")
	local tF, tW, tY, wf, wf2 = rows.gF, rows.gW, rows.gY, rows.wf, rows.wf2
	local lo = st.lo
	local off = offsetsFor(D)
	local T = D * (D + 1) // 2
	local wsum = 0
	for k = k0, k1 - 1 do
		wsum += tW[k]
	end
	-- S3 invariant: one call adds at most 2^22 of sample weight, so every inner product
	-- (at most 2^22 * 2^30) and every accumulator stays below 2^53
	local lim = weightLimit()
	assert(wsum <= lim, "too much sample weight in one Gram call; split the band rows")
	if st.pending + wsum > lim then
		normalise(st)
	end
	local Dv = D - 1 -- varying features; feature D is the constant QSCALE
	-- 1. unique varying columns over these terms
	local uniq, alias = rows.uniq, rows.alias
	local U = 0
	for j = 1, Dv do
		local oj = (j - 1) * W
		local found = 0
		for u = 1, U do
			local ou = (uniq[u] - 1) * W
			local same = true
			for k = k0, k1 - 1 do
				if tF[oj + k] ~= tF[ou + k] then
					same = false
					break
				end
			end
			if same then
				found = u
				break
			end
		end
		if found == 0 then
			U += 1
			uniq[U] = j
			alias[j] = U
		else
			alias[j] = found
		end
	end
	-- 2. Gram of the unique columns: gu[(a - 1) * U + b] for a <= b, su[a] = sum w f_a
	local gu, su, pu = rows.gu, rows.su, rows.pu
	local a = 1
	while a <= U do
		local two = a + 1 <= U
		local ca = (uniq[a] - 1) * W
		local ca2 = if two then (uniq[a + 1] - 1) * W else 0
		local s1, s2 = 0, 0
		for k = k0, k1 - 1 do
			local w = tW[k]
			local x = w * tF[ca + k]
			wf[k] = x
			s1 += x
			if two then
				local y = w * tF[ca2 + k]
				wf2[k] = y
				s2 += y
			end
		end
		su[a] = s1
		local ra = (a - 1) * U
		local ra2 = a * U
		do
			local g11 = 0
			for k = k0, k1 - 1 do
				g11 += wf[k] * tF[ca + k]
			end
			gu[ra + a] = g11
			if two then
				su[a + 1] = s2
				local g12, g22 = 0, 0
				for k = k0, k1 - 1 do
					local f = tF[ca2 + k]
					g12 += wf[k] * f
					g22 += wf2[k] * f
				end
				gu[ra + a + 1] = g12
				gu[ra2 + a + 1] = g22
			end
		end
		local b = if two then a + 2 else a + 1
		while b + 3 <= U do
			local o1, o2, o3, o4 = (uniq[b] - 1) * W, (uniq[b + 1] - 1) * W, (uniq[b + 2] - 1) * W, (uniq[b + 3] - 1) * W
			local a1, a2, a3, a4, b1, b2, b3, b4 = 0, 0, 0, 0, 0, 0, 0, 0
			if two then
				for k = k0, k1 - 1 do
					local w, v = wf[k], wf2[k]
					local f1, f2, f3, f4 = tF[o1 + k], tF[o2 + k], tF[o3 + k], tF[o4 + k]
					a1 += w * f1
					a2 += w * f2
					a3 += w * f3
					a4 += w * f4
					b1 += v * f1
					b2 += v * f2
					b3 += v * f3
					b4 += v * f4
				end
				gu[ra2 + b] = b1
				gu[ra2 + b + 1] = b2
				gu[ra2 + b + 2] = b3
				gu[ra2 + b + 3] = b4
			else
				for k = k0, k1 - 1 do
					local w = wf[k]
					a1 += w * tF[o1 + k]
					a2 += w * tF[o2 + k]
					a3 += w * tF[o3 + k]
					a4 += w * tF[o4 + k]
				end
			end
			gu[ra + b] = a1
			gu[ra + b + 1] = a2
			gu[ra + b + 2] = a3
			gu[ra + b + 3] = a4
			b += 4
		end
		while b <= U do
			local o1 = (uniq[b] - 1) * W
			local a1, b1 = 0, 0
			for k = k0, k1 - 1 do
				local f = tF[o1 + k]
				a1 += wf[k] * f
				if two then
					b1 += wf2[k] * f
				end
			end
			gu[ra + b] = a1
			if two then
				gu[ra2 + b] = b1
			end
			b += 1
		end
		a += 2
	end
	-- 3. P of the unique columns: pu[(a - 1) * M + m], three channels per pass
	for u = 1, U do
		local cu = (uniq[u] - 1) * W
		local pb = (u - 1) * M
		local m = 1
		while m <= M do
			local om1 = (m - 1) * W
			if m + 2 <= M then
				local om2, om3 = m * W, (m + 1) * W
				local x1, x2, x3 = 0, 0, 0
				for k = k0, k1 - 1 do
					local f = tF[cu + k]
					x1 += f * tY[om1 + k]
					x2 += f * tY[om2 + k]
					x3 += f * tY[om3 + k]
				end
				pu[pb + m] = x1
				pu[pb + m + 1] = x2
				pu[pb + m + 2] = x3
				m += 3
			else
				local x1 = 0
				for k = k0, k1 - 1 do
					x1 += tF[cu + k] * tY[om1 + k]
				end
				pu[pb + m] = x1
				m += 1
			end
		end
	end
	-- 4. scatter to the statistics
	for i = 1, Dv do
		local ai = alias[i]
		local base = off[i] - i + 1
		for j = i, Dv do
			local aj = alias[j]
			if ai <= aj then
				lo[base + j] += gu[(ai - 1) * U + aj]
			else
				lo[base + j] += gu[(aj - 1) * U + ai]
			end
		end
		lo[base + D] += QSCALE * su[ai]
		local pb = T + (i - 1) * M
		local qb = (ai - 1) * M
		for m = 1, M do
			lo[pb + m] += pu[qb + m]
		end
	end
	lo[off[D] + 1] += QSCALE * QSCALE * wsum
	local pD = T + (D - 1) * M
	for m = 1, M do
		local om = (m - 1) * W
		local x1 = 0
		for k = k0, k1 - 1 do
			x1 += tY[om + k]
		end
		lo[pD + m] += QSCALE * x1
	end
	lo[T + D * M + M + 1] += wsum
	st.pending += wsum
end

-- The S2 cost model as written in docs/LIQUID.md: one outer product per sampled
-- pixel (benchmark reference; same integers as the band path).
local function naiveRange(st: Stats, rows: Rows, target: buffer, yr0: number, yr1: number, o: AccumOptions)
	local D, M, W = rows.D, st.M, rows.W
	local feat = rows.feat
	local lo = st.lo
	local off = offsetsFor(D)
	local T = D * (D + 1) // 2
	local yb = T + D * M
	local tstride = o.targetStride or M
	local stride = o.stride or 1
	local s = table.create(D, 0)
	local y = table.create(M, 0)
	for yr = yr0, yr1 - 1 do
		if st.pending + W > PENDING_LIMIT then
			normalise(st)
		end
		local rowOff = yr * W * tstride
		local n = 0
		for x = (stride - (yr % stride)) % stride, W - 1, stride do
			for j = 1, D do
				s[j] = feat[(j - 1) * W + x + 1]
			end
			for m = 1, M do
				local v = buffer.readu8(target, rowOff + x * tstride + m - 1)
				y[m] = v
				lo[yb + m] += v * v
			end
			for i = 1, D do
				local si = s[i]
				local base = off[i] - i + 1
				for j = i, D do
					lo[base + j] += si * s[j]
				end
				local pb = T + (i - 1) * M
				for m = 1, M do
					lo[pb + m] += si * y[m]
				end
			end
			n += 1
		end
		lo[T + D * M + M + 1] += n
		st.pending += n
	end
end

-- Accumulates render rows [yr0, yr1) and columns [x0, x1) of the current band (after
-- rowSegments and simulateQ). The result does not depend on how bands are cut.
function LiquidLearn.accumulateRange(st: Stats, rows: Rows, target: buffer, yr0: number, yr1: number, x0: number, x1: number, o: AccumOptions)
	if o.naive then
		assert(x0 == 0 and x1 == rows.W, "naive mode works on whole rows")
		naiveRange(st, rows, target, yr0, yr1, o)
		return
	end
	-- at most pendingLimit (<= 2^22) samples per pass (S3 invariant); large bands go in
	-- row chunks
	local maxRows = math.max(1, weightLimit() // rows.W)
	local ya = yr0
	while ya < yr1 do
		local yb = math.min(yr1, ya + maxRows)
		LiquidLearn.bandReset(rows, st.M)
		LiquidLearn.bandTargets(st, rows, target, ya, yb, x0, x1, o)
		local K
		if not o.event and LiquidLearn.bandAllSampled(rows) then
			K = LiquidLearn.bandTermsIdentity(rows)
		else
			K = LiquidLearn.bandTerms(rows, st.M, o)
		end
		LiquidLearn.bandGram(st, rows, 1, K + 1)
		ya = yb
	end
end

-- Accumulates every row of the tree (rendered at the scale of `rows`) against the
-- target (render-scale size). Every mode produces the same integers as visiting each
-- sampled pixel once.
function LiquidLearn.accumulate(st: Stats, rows: Rows, target: buffer, opts: AccumOptions?)
	local o: AccumOptions = opts or {}
	local tree = rows.tree
	local rep = bit32.lshift(1, rows.r)
	local y = 0
	while y < tree.height do
		LiquidLearn.rowSegments(rows, y)
		LiquidLearn.simulateQ(rows)
		LiquidLearn.accumulateRange(st, rows, target, y * rep, rows.groupEnd * rep, 0, rows.W, o)
		y = rows.groupEnd
	end
end

----------------------------------------------------------------------------------
-- deterministic ridge solve (S1): (G + lambda I') w = P by Cholesky
----------------------------------------------------------------------------------

-- A: dense D x D rows (overwritten), Pm: D x M. lambda = lamRel * mean diagonal of the
-- non-constant features, added to every diagonal entry but the constant's. Same
-- operations in the same order as cholesky_solve_exact in tools/liquid_train.py.
local function choleskySolve(A: { { number } }, Pm: { { number } }, D: number, M: number, lamRel: number, mult: { number }?): { { number } }?
	local tr = 0
	for i = 1, D - 1 do
		tr = tr + A[i][i]
	end
	local lam = lamRel * (tr / (D - 1))
	for i = 1, D - 1 do
		A[i][i] = A[i][i] + (if mult then lam * mult[i] else lam)
	end
	local L: { { number } } = {}
	for i = 1, D do
		L[i] = table.create(D, 0)
	end
	for j = 1, D do
		local Lj = L[j]
		local s = A[j][j]
		for k = 1, j - 1 do
			s = s - Lj[k] * Lj[k]
		end
		if not (s > 0) then
			return nil
		end
		local dj = sqrt(s)
		Lj[j] = dj
		for i = j + 1, D do
			local Li = L[i]
			local t = A[i][j]
			for k = 1, j - 1 do
				t = t - Li[k] * Lj[k]
			end
			Li[j] = t / dj
		end
	end
	local Wm: { { number } } = {}
	for i = 1, D do
		Wm[i] = table.create(M, 0)
	end
	local yv = table.create(D, 0)
	for m = 1, M do
		for i = 1, D do
			local Li = L[i]
			local s = Pm[i][m]
			for k = 1, i - 1 do
				s = s - Li[k] * yv[k]
			end
			yv[i] = s / Li[i]
		end
		for i = D, 1, -1 do
			local s = yv[i]
			for k = i + 1, D do
				s = s - L[k][i] * Wm[k][m]
			end
			Wm[i][m] = s / L[i][i]
		end
	end
	return Wm
end
LiquidLearn.choleskySolve = choleskySolve

-- Dense float matrices of the statistics.
function LiquidLearn.statsMatrices(st: Stats): ({ { number } }, { { number } })
	local D, M = st.D, st.M
	local c = canonical(st)
	local off = triOffsets(D)
	local A: { { number } } = {}
	for i = 1, D do
		A[i] = table.create(D, 0)
	end
	for i = 1, D do
		for j = i, D do
			local v = entryFloat(c, off[i] + (j - i) + 1)
			A[i][j] = v
			A[j][i] = v
		end
	end
	local T = D * (D + 1) // 2
	local Pm: { { number } } = {}
	for i = 1, D do
		local row = table.create(M, 0)
		for m = 1, M do
			row[m] = entryFloat(c, T + (i - 1) * M + m)
		end
		Pm[i] = row
	end
	return A, Pm
end

function LiquidLearn.statsYY(st: Stats): ({ number }, number)
	local c = canonical(st)
	local D, M = st.D, st.M
	local T = D * (D + 1) // 2
	local yy = table.create(M, 0)
	for m = 1, M do
		yy[m] = entryFloat(c, T + D * M + m)
	end
	return yy, entryFloat(c, T + D * M + M + 1)
end

local function readoutFromW(Wm: { { number } }, N: number, M: number): Readout
	local Cf, Cb, d = table.create(M * N, 0), table.create(M * N, 0), table.create(M, 0)
	for m = 1, M do
		for i = 1, N do
			Cf[(m - 1) * N + i] = Wm[i][m] * QSCALE
			Cb[(m - 1) * N + i] = Wm[N + i][m] * QSCALE
		end
		d[m] = Wm[2 * N + 1][m] * QSCALE
	end
	return { M = M, N = N, Cf = Cf, Cb = Cb, d = d }
end

-- Ridge readout from exact statistics: identical bytes in the interpreter, in native
-- code and in tools/liquid_train.py (cholesky_solve_exact). `mult` (length D - 1)
-- scales the ridge per feature; slowRidge builds the event-aware one.
function LiquidLearn.solve(st: Stats, N: number, lamRel: number?, mult: { number }?): Readout
	assert(st.D == 2 * N + 1, "statistics do not match N")
	local A, Pm = LiquidLearn.statsMatrices(st)
	local Wm = choleskySolve(A, Pm, st.D, st.M, lamRel or LiquidLearn.DEFAULT_LAMBDA, mult)
	assert(Wm, "ridge system not positive definite")
	return readoutFromW(Wm :: { { number } }, N, st.M)
end

-- Event-aware ridge: slowMult on the forward and backward features of every slow
-- neuron (kBase > -K), 1 on instant neurons. Large slowMult shrinks the weights that
-- keep pixels active under the T2 skip rule: 1 is the plain ridge, about 1e6 gives the
-- plain quadtree (events = segments); docs/LIQUID_TRAINING.md 3.3 measures the dial.
function LiquidLearn.slowRidge(res: Reservoir, slowMult: number): { number }
	local N = res.N
	local m = table.create(2 * N, 1)
	for i = 1, N do
		if res.kBase[i] > -res.K then
			m[i] = slowMult
			m[N + i] = slowMult
		end
	end
	return m
end

-- SSE of weights Wm on statistics: YY_m - 2 w.P_m + w^T G w, summed over channels.
local function sseFrom(A: { { number } }, Pm: { { number } }, yy: { number }, Wm: { { number } }, D: number, M: number): number
	local total = 0
	for m = 1, M do
		local cross = 0
		for i = 1, D do
			cross = cross + Wm[i][m] * Pm[i][m]
		end
		local quad = 0
		for i = 1, D do
			local gi = A[i]
			local acc = 0
			for j = 1, D do
				acc = acc + gi[j] * Wm[j][m]
			end
			quad = quad + Wm[i][m] * acc
		end
		total = total + (yy[m] - 2 * cross + quad)
	end
	return total
end

-- Mean squared error (per channel value, before quantisation) of a readout measured
-- on statistics alone: validation without rendering.
function LiquidLearn.mseOf(st: Stats, ro: Readout): number
	local D, M, N = st.D, st.M, ro.N
	local A, Pm = LiquidLearn.statsMatrices(st)
	local yy, count = LiquidLearn.statsYY(st)
	local Wm: { { number } } = {}
	for i = 1, D do
		Wm[i] = table.create(M, 0)
	end
	for m = 1, M do
		for i = 1, N do
			Wm[i][m] = ro.Cf[(m - 1) * N + i] / QSCALE
			Wm[N + i][m] = ro.Cb[(m - 1) * N + i] / QSCALE
		end
		Wm[D][m] = ro.d[m] / QSCALE
	end
	return sseFrom(A, Pm, yy, Wm, D, M) / (count * M)
end

----------------------------------------------------------------------------------
-- S4: federated messages and the merge ledger
----------------------------------------------------------------------------------

-- Everything that must agree before statistics can be merged: reservoir bytes, M,
-- the quantisation scale and the layout version.
function LiquidLearn.fingerprint(res: Reservoir, M: number): number
	local b = LiquidLearn.encodeReservoir(res)
	local h = 0x414C4E31
	for _, v in { 1, res.N, res.I, res.K, M, QSCALE } do
		h = MyMath.hash32(bit32.bxor(h, v))
	end
	for i = 0, buffer.len(b) - 1 do
		h = MyMath.hash32(bit32.bxor(h, buffer.readu8(b, i)))
	end
	return h
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64CH: { string } = {}
local B64DEC: { [number]: number } = {}
for i = 1, 64 do
	B64CH[i] = string.sub(B64, i, i)
	B64DEC[string.byte(B64, i)] = i - 1
end

function LiquidLearn.base64(b: buffer, n: number?): string
	local len = n or buffer.len(b)
	local out = table.create((len + 2) // 3 * 4, "")
	local k = 0
	for i = 0, len - 1, 3 do
		local a0 = buffer.readu8(b, i)
		local a1 = if i + 1 < len then buffer.readu8(b, i + 1) else 0
		local a2 = if i + 2 < len then buffer.readu8(b, i + 2) else 0
		local v = a0 * 65536 + a1 * 256 + a2
		out[k + 1] = B64CH[v // 262144 + 1]
		out[k + 2] = B64CH[(v // 4096) % 64 + 1]
		out[k + 3] = if i + 1 < len then B64CH[(v // 64) % 64 + 1] else "="
		out[k + 4] = if i + 2 < len then B64CH[v % 64 + 1] else "="
		k += 4
	end
	return table.concat(out)
end

function LiquidLearn.unbase64(s: string): buffer
	local n = #s
	assert(n % 4 == 0, "bad base64 length")
	local pad = 0
	if n >= 1 and string.byte(s, n) == 61 then
		pad += 1
	end
	if n >= 2 and string.byte(s, n - 1) == 61 then
		pad += 1
	end
	local len = n // 4 * 3 - pad
	local out = buffer.create(math.max(len, 0))
	local o = 0
	for i = 1, n, 4 do
		local v = 0
		for j = 0, 3 do
			local c = string.byte(s, i + j)
			local d = if c == 61 then 0 else B64DEC[c]
			assert(d ~= nil, "bad base64 character")
			v = v * 64 + d
		end
		if o < len then
			buffer.writeu8(out, o, v // 65536)
		end
		if o + 1 < len then
			buffer.writeu8(out, o + 1, (v // 256) % 256)
		end
		if o + 2 < len then
			buffer.writeu8(out, o + 2, v % 256)
		end
		o += 3
	end
	return out
end

local function putVarint(b: buffer, o: number, v: number): number
	assert(v >= 0 and v == floor(v), "varint needs a non-negative integer")
	while v >= 128 do
		buffer.writeu8(b, o, v % 128 + 128)
		v = floor(v / 128)
		o += 1
	end
	buffer.writeu8(b, o, v)
	return o + 1
end

local function getVarint(b: buffer, o: number): (number, number)
	local v, mul = 0, 1
	for _ = 1, 8 do
		local c = buffer.readu8(b, o)
		o += 1
		v += (c % 128) * mul
		if c < 128 then
			return v, o
		end
		mul *= 128
	end
	error("varint too long")
end

local function varintLen(v: number): number
	local n = 1
	while v >= 128 do
		v = floor(v / 128)
		n += 1
	end
	return n
end

-- Packs cumulative statistics into base64 strings of at most 1000 characters (750 raw
-- bytes): "ALS", version u8, fingerprint u32, sender u32, sequence u32, chunk index
-- u8, chunk count u8, first entry u16, entry count u16, then varint(hi) varint(lo)
-- per entry. Entries are non-negative for Walsh reservoirs (q >= 0, targets >= 0).
function LiquidLearn.packMessages(st: Stats, fingerprint: number, sender: number, sequence: number): { string }
	local c = canonical(st)
	local starts, counts = {}, {}
	local e = 1
	while e <= c.E do
		local size = HEADER
		local first = e
		while e <= c.E do
			assert(c.hi[e] >= 0, "negative statistics cannot be packed")
			local add = varintLen(c.hi[e]) + varintLen(c.lo[e])
			if size + add > MAX_RAW_CHUNK then
				break
			end
			size += add
			e += 1
		end
		table.insert(starts, first)
		table.insert(counts, e - first)
	end
	local nchunks = #starts
	assert(nchunks <= 255, "too many chunks")
	local msgs = table.create(nchunks, "")
	local raw = buffer.create(MAX_RAW_CHUNK)
	for k = 1, nchunks do
		buffer.writeu8(raw, 0, 0x41)
		buffer.writeu8(raw, 1, 0x4C)
		buffer.writeu8(raw, 2, 0x53)
		buffer.writeu8(raw, 3, 1)
		buffer.writeu32(raw, 4, fingerprint)
		buffer.writeu32(raw, 8, sender)
		buffer.writeu32(raw, 12, sequence)
		buffer.writeu8(raw, 16, k - 1)
		buffer.writeu8(raw, 17, nchunks)
		buffer.writeu16(raw, 18, starts[k] - 1)
		buffer.writeu16(raw, 20, counts[k])
		local o = HEADER
		for j = starts[k], starts[k] + counts[k] - 1 do
			o = putVarint(raw, o, c.hi[j])
			o = putVarint(raw, o, c.lo[j])
		end
		msgs[k] = LiquidLearn.base64(raw, o)
	end
	return msgs
end

export type Chunk = {
	fingerprint: number,
	sender: number,
	sequence: number,
	index: number,
	count: number,
	first: number,
	n: number,
	hi: { number },
	lo: { number },
}

function LiquidLearn.unpackMessage(s: string): Chunk
	local raw = LiquidLearn.unbase64(s)
	assert(buffer.len(raw) >= HEADER, "short message")
	assert(buffer.readu8(raw, 0) == 0x41 and buffer.readu8(raw, 1) == 0x4C and buffer.readu8(raw, 2) == 0x53, "not an ALS message")
	assert(buffer.readu8(raw, 3) == 1, "unsupported ALS version")
	local ch: Chunk = {
		fingerprint = buffer.readu32(raw, 4),
		sender = buffer.readu32(raw, 8),
		sequence = buffer.readu32(raw, 12),
		index = buffer.readu8(raw, 16),
		count = buffer.readu8(raw, 17),
		first = buffer.readu16(raw, 18),
		n = buffer.readu16(raw, 20),
		hi = {},
		lo = {},
	}
	local o = HEADER
	for j = 1, ch.n do
		local h, l
		h, o = getVarint(raw, o)
		l, o = getVarint(raw, o)
		assert(l < TWO32, "non-canonical entry")
		ch.hi[j] = h
		ch.lo[j] = l
	end
	assert(o == buffer.len(raw), "trailing bytes")
	return ch
end

-- Ledger: a state-based CRDT (a G-Counter whose slots hold statistics). Each sender
-- owns one slot with its latest cumulative statistics, ordered by sequence number.
-- Merging keeps the higher sequence per sender: idempotent, commutative and
-- associative. The total is the exact integer sum of the slots, so servers that have
-- seen the same latest sequences solve the same readout bytes.
export type Slot = { sequence: number, stats: Stats }
export type Ledger = {
	fingerprint: number,
	D: number,
	M: number,
	slots: { [number]: Slot },
	pendingChunks: { [number]: { sequence: number, parts: { [number]: Chunk } } },
	base: Stats,
	folded: { [number]: number },
}

function LiquidLearn.newLedger(fingerprint: number, D: number, M: number): Ledger
	return {
		fingerprint = fingerprint,
		D = D,
		M = M,
		slots = {},
		pendingChunks = {},
		base = LiquidLearn.newStats(D, M),
		folded = {},
	}
end

-- Records a sender's cumulative statistics. Returns true if the ledger changed.
function LiquidLearn.observe(led: Ledger, sender: number, sequence: number, st: Stats): boolean
	if led.folded[sender] ~= nil then
		return false
	end
	local cur = led.slots[sender]
	if cur ~= nil and cur.sequence >= sequence then
		return false
	end
	local c = LiquidLearn.copyStats(st)
	normalise(c)
	led.slots[sender] = { sequence = sequence, stats = c }
	return true
end

-- Feeds one message. Chunks are buffered per sender until the newest sequence is
-- complete; duplicates and reordering are harmless, older sequences are dropped.
-- Returns true when a complete contribution changed the ledger.
function LiquidLearn.receive(led: Ledger, msg: string): boolean
	local ok, res = pcall(LiquidLearn.unpackMessage, msg)
	if not ok then
		return false
	end
	local ch = res :: Chunk
	if ch.fingerprint ~= led.fingerprint or led.folded[ch.sender] ~= nil then
		return false
	end
	local cur = led.slots[ch.sender]
	if cur ~= nil and cur.sequence >= ch.sequence then
		return false
	end
	local pend = led.pendingChunks[ch.sender]
	if pend == nil or pend.sequence < ch.sequence then
		pend = { sequence = ch.sequence, parts = {} }
		led.pendingChunks[ch.sender] = pend
	elseif pend.sequence > ch.sequence then
		return false
	end
	local p = pend :: { sequence: number, parts: { [number]: Chunk } }
	p.parts[ch.index] = ch
	local filled = 0
	for k = 0, ch.count - 1 do
		local part = p.parts[k]
		if part == nil then
			return false
		end
		filled += part.n
	end
	local st = LiquidLearn.newStats(led.D, led.M)
	if filled ~= st.E then
		return false
	end
	for k = 0, ch.count - 1 do
		local part = p.parts[k]
		for j = 1, part.n do
			st.hi[part.first + j] = part.hi[j]
			st.lo[part.first + j] = part.lo[j]
		end
	end
	led.pendingChunks[ch.sender] = nil
	return LiquidLearn.observe(led, ch.sender, ch.sequence, st)
end

-- Exact total of the ledger (base plus every slot), independent of iteration order.
function LiquidLearn.total(led: Ledger): Stats
	local t = LiquidLearn.copyStats(led.base)
	for _, slot in led.slots do
		LiquidLearn.addStats(t, slot.stats)
	end
	normalise(t)
	return t
end

-- Folds a finished sender into the base, keeping only its final sequence number.
function LiquidLearn.fold(led: Ledger, sender: number)
	local slot = led.slots[sender]
	if slot == nil then
		return
	end
	LiquidLearn.addStats(led.base, slot.stats)
	led.folded[sender] = slot.sequence
	led.slots[sender] = nil
end

-- DataStore value for statistics: newline-separated messages (sender 0, sequence 0).
function LiquidLearn.serializeStats(st: Stats, fingerprint: number): string
	return table.concat(LiquidLearn.packMessages(st, fingerprint, 0, 0), "\n")
end

function LiquidLearn.deserializeStats(s: string, D: number, M: number): (Stats, number)
	local st = LiquidLearn.newStats(D, M)
	local fp = 0
	local filled = 0
	for line in string.gmatch(s, "[^\n]+") do
		local ch = LiquidLearn.unpackMessage(line)
		fp = ch.fingerprint
		for j = 1, ch.n do
			st.hi[ch.first + j] = ch.hi[j]
			st.lo[ch.first + j] = ch.lo[j]
		end
		filled += ch.n
	end
	assert(filled == st.E, "incomplete statistics")
	return st, fp
end

----------------------------------------------------------------------------------
-- S5: gain search on exact sub-Grams of one superset accumulation
----------------------------------------------------------------------------------

export type GainSearchOptions = {
	candidates: { number }?, -- kBase values tried for every neuron
	validationEvery: number?, -- tree rows y with y % v == v - 1 validate; others train
	sweeps: number?,
	lambda: number?,
	event: boolean?, -- event-mode accumulation (default true)
	targetStride: number?,
}

export type GainSearchResult = {
	kBase: { number },
	trainMSE: number,
	validationMSE: number,
	startValidationMSE: number,
	trials: number,
	superD: number,
	accumulateSeconds: number,
	searchSeconds: number,
}

local function subMatrices(A: { { number } }, Pm: { { number } }, map: { number }, M: number): ({ { number } }, { { number } })
	local D = #map
	local As: { { number } } = {}
	local Ps: { { number } } = {}
	for a = 1, D do
		local ra = A[map[a]]
		local row = table.create(D, 0)
		for b = 1, D do
			row[b] = ra[map[b]]
		end
		As[a] = row
		Ps[a] = table.clone(Pm[map[a]])
	end
	return As, Ps
end

-- Train and validation statistics of a reservoir: tree rows with y % every ==
-- every - 1 go to validation.
function LiquidLearn.accumulateSplit(res: Reservoir, tree: Tree, target: buffer, M: number, every: number, o: AccumOptions): (Stats, Stats)
	local D = 2 * res.N + 1
	local tr, va = LiquidLearn.newStats(D, M), LiquidLearn.newStats(D, M)
	local rows = LiquidLearn.newRows(res, tree, 0)
	local y = 0
	while y < tree.height do
		LiquidLearn.rowSegments(rows, y)
		LiquidLearn.simulateQ(rows)
		local band = rows.groupEnd
		-- rows of the band share features; split them by the validation rule
		local yy = y
		while yy < band do
			local isVal = yy % every == every - 1
			local ye = yy + 1
			while ye < band and ((ye % every == every - 1) == isVal) do
				ye += 1
			end
			LiquidLearn.accumulateRange(if isVal then va else tr, rows, target, yy, ye, 0, rows.W, o)
			yy = ye
		end
		y = band
	end
	return tr, va
end

-- Exact sub-statistics: features map[1..d] of a superset (map[d] must be the constant
-- feature). The integers are copied, so solving them gives the bytes a direct
-- accumulation of that configuration gives.
function LiquidLearn.extractStats(st: Stats, map: { number }): Stats
	local d, M, D = #map, st.M, st.D
	local c = canonical(st)
	local out = LiquidLearn.newStats(d, M)
	local offS, offD = triOffsets(D), triOffsets(d)
	for a = 1, d do
		for b = a, d do
			local i, j = map[a], map[b]
			if i > j then
				i, j = j, i
			end
			local src = offS[i] + (j - i) + 1
			local dst = offD[a] + (b - a) + 1
			out.hi[dst], out.lo[dst] = c.hi[src], c.lo[src]
		end
	end
	local TS, TD = D * (D + 1) // 2, d * (d + 1) // 2
	for a = 1, d do
		for m = 1, M do
			local src = TS + (map[a] - 1) * M + m
			local dst = TD + (a - 1) * M + m
			out.hi[dst], out.lo[dst] = c.hi[src], c.lo[src]
		end
	end
	for m = 1, M + 1 do
		out.hi[TD + d * M + m], out.lo[TD + d * M + m] = c.hi[TS + D * M + m], c.lo[TS + D * M + m]
	end
	return out
end

-- Feature map of a configuration inside a superset reservoir: for neuron i of the
-- configuration, superIndex[i] is its neuron in the superset (S neurons).
function LiquidLearn.superMap(superIndex: { number }, S: number): { number }
	local N = #superIndex
	local map = table.create(2 * N + 1, 0)
	for i = 1, N do
		map[i] = superIndex[i]
		map[N + i] = S + superIndex[i]
	end
	map[2 * N + 1] = 2 * S + 1
	return map
end

-- Coordinate descent over kBase (S5) on one superset accumulation. The superset
-- reservoir holds every (projection, candidate kBase) pair; neurons are uncoupled,
-- so the sub-Gram of a configuration is exactly the Gram a direct accumulation of
-- that configuration would produce, and each trial is a sub-matrix copy, a D x D
-- Cholesky solve on training rows and a validation score from statistics.
function LiquidLearn.gainSearch(base: Reservoir, tree: Tree, target: buffer, M: number, opts: GainSearchOptions?): GainSearchResult
	local o: GainSearchOptions = opts or {}
	local cands = o.candidates or { -64, -4, -3, -2, -1, 0, 1, 2, 3, 4 }
	local every = o.validationEvery or 4
	local lam = o.lambda or LiquidLearn.DEFAULT_LAMBDA
	local N, I = base.N, base.I
	local proj = LiquidLearn.walshProjections(base)
	local sp, sk = {}, {}
	local index: { [string]: number } = {}
	local function want(p: number, k: number)
		local key = p .. ":" .. k
		if index[key] == nil then
			table.insert(sp, p)
			table.insert(sk, k)
			index[key] = #sp
		end
	end
	for i = 1, N do
		want(proj[i], base.kBase[i])
		for _, k in cands do
			want(proj[i], k)
		end
	end
	local S = #sp
	local sup = LiquidLearn.walshReservoir(S, I, base.K, sk, nil, sp)
	local t0 = os.clock()
	local acc: AccumOptions = { event = o.event ~= false, targetStride = o.targetStride }
	local trS, vaS = LiquidLearn.accumulateSplit(sup, tree, target, M, every, acc)
	local t1 = os.clock()
	local DS = 2 * S + 1
	local At, Pt = LiquidLearn.statsMatrices(trS)
	local Av, Pv = LiquidLearn.statsMatrices(vaS)
	local yyv, cntv = LiquidLearn.statsYY(vaS)
	local yyt, cntt = LiquidLearn.statsYY(trS)
	local cur = table.clone(base.kBase)
	local trials = 0
	local function score(kb: { number }): (number, number)
		trials += 1
		local map = table.create(2 * N + 1, 0)
		for i = 1, N do
			local s = index[proj[i] .. ":" .. kb[i]]
			map[i] = s
			map[N + i] = S + s
		end
		map[2 * N + 1] = DS
		local As, Ps = subMatrices(At, Pt, map, M)
		local work: { { number } } = {}
		for a = 1, #map do
			work[a] = table.clone(As[a])
		end
		local Wm = choleskySolve(work, Ps, #map, M, lam)
		if Wm == nil then
			return math.huge, math.huge
		end
		local Av2, Pv2 = subMatrices(Av, Pv, map, M)
		local w = Wm :: { { number } }
		return sseFrom(Av2, Pv2, yyv, w, #map, M) / (cntv * M), sseFrom(As, Ps, yyt, w, #map, M) / (cntt * M)
	end
	local bestV, bestT = score(cur)
	local startV = bestV
	for _ = 1, o.sweeps or 3 do
		local improved = false
		for i = 1, N do
			for _, k in cands do
				if k ~= cur[i] then
					local clash = false
					for j = 1, N do
						if j ~= i and proj[j] == proj[i] and cur[j] == k then
							clash = true
							break
						end
					end
					if not clash then
						local old = cur[i]
						cur[i] = k
						local v, t = score(cur)
						if v < bestV then
							bestV, bestT = v, t
							improved = true
						else
							cur[i] = old
						end
					end
				end
			end
		end
		if not improved then
			break
		end
	end
	return {
		kBase = cur,
		trainMSE = bestT,
		validationMSE = bestV,
		startValidationMSE = startV,
		trials = trials,
		superD = DS,
		accumulateSeconds = t1 - t0,
		searchSeconds = os.clock() - t1,
	}
end

----------------------------------------------------------------------------------
-- time-sliced trainer (S2 on Heartbeat)
----------------------------------------------------------------------------------

export type Trainer = {
	stats: Stats,
	rows: Rows,
	target: buffer,
	opts: AccumOptions,
	y: number, -- tree row of the current band
	phase: number, -- 0 segments, 1 states, 2 reset, 3 targets, 4 terms, 5 Gram
	neuron: number, -- next neuron (states phase)
	subStart: number, -- first render row of the current sub-band
	bandEndR: number, -- render row after the band
	yr: number, -- next render row of the sub-band (targets phase)
	yrEnd: number, -- render row after the sub-band (at most 2^22 samples per sub-band)
	x: number, -- next column (terms phase)
	k: number, -- next term (Gram phase)
	neuronChunk: number, -- neurons per states unit
	rowChunk: number, -- render rows per targets unit
	xChunk: number, -- columns per terms unit
	kChunk: number, -- terms per Gram unit
	done: boolean,
	clock: () -> number,
	slices: number,
	units: number,
}

function LiquidLearn.newTrainer(res: Reservoir, tree: Tree, target: buffer, M: number, opts: AccumOptions?, r: number?, clock: (() -> number)?): Trainer
	return {
		stats = LiquidLearn.newStats(2 * res.N + 1, M),
		rows = LiquidLearn.newRows(res, tree, r),
		target = target,
		opts = opts or {},
		y = 0,
		phase = 0,
		neuron = 1,
		subStart = 0,
		bandEndR = 0,
		yr = 0,
		yrEnd = 0,
		x = 0,
		k = 1,
		neuronChunk = 2,
		rowChunk = 4,
		xChunk = 256,
		kChunk = 32,
		done = false,
		clock = clock or os.clock,
		slices = 0,
		units = 0,
	}
end

-- Runs bounded units of work until `budget` seconds have elapsed: a band's segments,
-- the states of neuronChunk neurons, clearing the band accumulators, rowChunk render
-- rows of targets, xChunk columns of the term list, or kChunk terms of Gram products. A slice
-- overshoots the budget by at most one unit. The final statistics equal
-- accumulate() bit for bit (integer sums do not depend on how work is cut).
function LiquidLearn.step(tr: Trainer, budget: number): boolean
	if tr.done then
		return true
	end
	tr.slices += 1
	local t0 = tr.clock()
	local rows = tr.rows
	local tree = rows.tree
	local st = tr.stats
	local rep = bit32.lshift(1, rows.r)
	while true do
		local phase = tr.phase
		if phase == 0 then
			if tr.y >= tree.height then
				tr.done = true
				return true
			end
			LiquidLearn.rowSegments(rows, tr.y)
			tr.neuron = 1
			tr.phase = 1
		elseif phase == 1 then
			local i1 = math.min(tr.neuron + tr.neuronChunk - 1, rows.N)
			LiquidLearn.simulateQ(rows, tr.neuron, i1)
			tr.neuron = i1 + 1
			if i1 >= rows.N then
				tr.subStart = tr.y * rep
				tr.bandEndR = rows.groupEnd * rep
				tr.phase = 2
			end
		elseif phase == 2 then
			LiquidLearn.bandReset(rows, st.M)
			tr.yr = tr.subStart
			tr.yrEnd = math.min(tr.bandEndR, tr.subStart + math.max(1, weightLimit() // rows.W))
			tr.phase = 3
		elseif phase == 3 then
			local ye = math.min(tr.yr + tr.rowChunk, tr.yrEnd)
			LiquidLearn.bandTargets(st, rows, tr.target, tr.yr, ye, 0, rows.W, tr.opts)
			tr.yr = ye
			if ye >= tr.yrEnd then
				tr.phase = 4
			end
		elseif phase == 4 then
			if tr.x == 0 and not tr.opts.event and LiquidLearn.bandAllSampled(rows) then
				LiquidLearn.bandTermsIdentity(rows)
				tr.x = rows.W
			else
				local xe = math.min(tr.x + tr.xChunk, rows.W)
				LiquidLearn.bandTerms(rows, st.M, tr.opts, tr.x, xe)
				tr.x = xe
			end
			if tr.x >= rows.W then
				tr.x = 0
				tr.k = 1
				tr.phase = 5
			end
		else
			local K = rows.termK
			local ke = math.min(tr.k + tr.kChunk, K + 1)
			LiquidLearn.bandGram(st, rows, tr.k, ke)
			tr.k = ke
			if ke > K then
				if tr.yrEnd < tr.bandEndR then
					tr.subStart = tr.yrEnd -- next sub-band of the same band (states reused)
					tr.phase = 2
				else
					tr.y = rows.groupEnd
					tr.phase = 0
				end
			end
		end
		tr.units += 1
		if tr.clock() - t0 >= budget then
			return false
		end
	end
end

return LiquidLearn
