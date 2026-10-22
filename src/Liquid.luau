--!native
--!optimize 2
-- universe-at-home :: Liquid (ALLAN, the Alpha Liquid network renderer)
--
-- docs/LIQUID.md is the specification; this header is the single source of truth for the
-- binary layout and for the exact arithmetic every implementation (Luau, the Python and
-- Luau learning builders, future GPU backends) must follow.
--
-- BINARY LAYOUT, version 1. All multi-byte values little-endian.
--
--   offset  field        type             meaning
--   0       magic        3 bytes          "ALN" (0x41 0x4C 0x4E)
--   3       version      u8               1
--   4       N            u8               neurons, 1..32
--   5       I            u8               input bytes per leaf, 1..16
--   6       M            u8               output channels, 1..8
--   7       K            u8               gain exponents, 1..31 (k in [0, K))
--   8       beta[N]      f64              neuron target bias
--           B[N*I]       f64              B[i*I + t] = weight of leaf byte t for neuron i
--           kBase[N]     f64              integer valued, may be negative
--           Cf[M*N]      f64              forward readout, Cf[m*N + i]
--           Cb[M*N]      f64              backward readout, Cb[m*N + i]
--           d[M]         f64              readout bias
--   then the quadtree:
--           width        u16              1..65535 pixels
--           height       u16              1..65535 pixels
--           maxDepth     u8               0..P (P defined below)
--           flags        ceil(F/8) bytes  one bit per visited node of depth < maxDepth, in
--                                         preorder, packed least significant bit first;
--                                         1 = split, 0 = leaf. F is the number of such nodes.
--           leaves       I bytes per leaf leaf bytes in preorder
--
-- Quadtree geometry. The root is the square [0, S) x [0, S), S = 2^P, P the smallest integer
-- with 2^P >= max(width, height). A node of depth t has side S >> t. Every split node has
-- all four children, visited in this order: (x0, y0), (x0 + h, y0), (x0, y0 + h),
-- (x0 + h, y0 + h), h = half the side. Nodes of depth maxDepth are leaves and have no
-- flag bit. The bit stream is self-delimiting; leaf bytes start at the next byte. A node
-- with no pixel inside [0, width) x [0, height) is still stored (builders make it a leaf
-- with zero bytes); the renderer never shows it, except the endless mode (X3) which may.
-- (Same layout as src/LiquidLearn.luau and tools/liquid_train.py.)
--
-- THE MODEL, in exactly this arithmetic (any reference implementation reproduces its bits):
--   u_t      = byte_t / 255                                  (one division)
--   b_i      = beta_i;  for t = 0..I-1: b_i = b_i + B[i*I + t] * u_t
--   k_i      = clamp(kBase_i + log2(leafSide) + r, 0, K - 1), leafSide = S >> depth in
--              stored pixels and r >= 0 the log2 render scale (r = 0: native resolution;
--              r > 0 renders 2^r x larger, every leaf scaled, docs/LIQUID.md X4). This is
--              "depthShift": small leaves are fast. kBase <= -K - r gives an instant
--              neuron (k = 0, g = 1, h = b).
--   g_i      = 2^-k_i (exact),  a_i = 1 - g_i (exact)
--   step     h_i = h_i + (b_i - h_i) * g_i                     (one base pixel)
--   passes   forward over x = 0..W-1 and backward over x = W-1..0 (W = width << r rendered
--            pixels); each pass starts at rest, h = b of its first pixel; hf(x), hb(x) are
--            the states after stepping pixel x
--   output   z_m = d_m; for i: z_m = z_m + Cf[m*N+i] * hf_i; for i: z_m = z_m + Cb[m*N+i] * hb_i
--   byte     clamp(floor(z_m + 0.5), 0, 255)
--   pixel    channel m is byte m of the RGBA8 pixel for m < 4 (missing channels: alpha 255,
--            others 0); channels 4..7 go to a second RGBA8 target with the same rule.
-- Liquid.reference* implement this literally (step by step). The event renderer evaluates the
-- same model in closed form (T1) and differs from it by the bounds proved in docs/LIQUID.md
-- ("Renderer results"): every byte within epsilon + 0.5 of the reference value (T2).
--
-- Deterministic ops only (docs/RUNTIME_AUDIT.md 6.5): + - * / floor, comparisons, integer
-- // and %, bit32 and integer buffer ops. No exp, log, pow, lerp, noise or random. Floor of
-- fractional values uses math.floor, never // (MSVC fast-math caveat).

local MyMath = require("./MyMath")
local Pixels = require("./Pixels")

local Liquid = {}
Liquid.VERSION = 1

local floor = math.floor
local hash32 = MyMath.hash32
local hash2 = MyMath.hash2
local fillSpan = Pixels.fillSpan

local JMAX = 62 -- drop tables cover residual ratios up to 2^62
local ETA = 1 / 16777216 -- 2^-24: slack of the quantisation-margin skip, in output units
local SHRINK = 1 - 1 / 1099511627776 -- 1 - 2^-40: absorbs rounding of computed bounds
local TWO32 = 4294967296
local NONE = -math.huge -- "no output pixel" (output pixels may be negative in the endless mode)

export type Model = {
	N: number,
	I: number,
	M: number,
	K: number,
	beta: { number },
	B: { number },
	kBase: { number },
	Cf: { number },
	Cb: { number },
	d: { number },
}

export type Tree = {
	width: number,
	height: number,
	maxDepth: number,
	P: number,
	S: number,
	I: number,
	nodeCount: number,
	leafCount: number,
	flagCount: number,
	nodes: buffer, -- u32 per node, preorder: leaf -> leafIndex * 2 + 1, internal -> subtreeSize * 2
	leafBytes: buffer, -- I bytes per leaf in preorder, plus 8 zero bytes of padding
	leafDepth: buffer, -- u8 per leaf
	leafKey: buffer, -- u32 per leaf: content id; equal bytes <=> equal id
	keyCount: number,
	keyLeaf: buffer, -- u32 per key: a leaf carrying that content
	virt: VirtualStats?, -- lazily built statistics for the endless mode (X3)
}

export type VirtualStats = {
	nodesAt: { number }, -- [t + 1] = nodes of depth t with a pixel inside the image
	splitsAt: { number }, -- [t + 1] = split ones among them
	leavesAt: { { number } }, -- [t + 1] = leaf indices of depth t inside the image
	all: { number }, -- every leaf inside the image
}

----------------------------------------------------------------------------------------
-- Model
----------------------------------------------------------------------------------------

local function checkArray(name: string, a: { number }, n: number)
	assert(#a == n, `{name} must have {n} entries, has {#a}`)
	for j = 1, n do
		local v = a[j]
		assert(v == v and v > -math.huge and v < math.huge, `{name}[{j}] is not finite`)
	end
end

-- Validates and copies a model table.
function Liquid.newModel(spec: Model): Model
	local N, I, M, K = spec.N, spec.I, spec.M, spec.K
	assert(N >= 1 and N <= 32 and N % 1 == 0, "N must be an integer in 1..32")
	assert(I >= 1 and I <= 16 and I % 1 == 0, "I must be an integer in 1..16")
	assert(M >= 1 and M <= 8 and M % 1 == 0, "M must be an integer in 1..8")
	assert(K >= 1 and K <= 31 and K % 1 == 0, "K must be an integer in 1..31")
	checkArray("beta", spec.beta, N)
	checkArray("B", spec.B, N * I)
	checkArray("kBase", spec.kBase, N)
	checkArray("Cf", spec.Cf, M * N)
	checkArray("Cb", spec.Cb, M * N)
	checkArray("d", spec.d, M)
	for j = 1, N do
		assert(spec.kBase[j] % 1 == 0, "kBase entries must be integers")
	end
	return {
		N = N,
		I = I,
		M = M,
		K = K,
		beta = table.clone(spec.beta),
		B = table.clone(spec.B),
		kBase = table.clone(spec.kBase),
		Cf = table.clone(spec.Cf),
		Cb = table.clone(spec.Cb),
		d = table.clone(spec.d),
	}
end

----------------------------------------------------------------------------------------
-- Tree: parsing from the flag bit stream, building, encoding
----------------------------------------------------------------------------------------

local function rootLog2(width: number, height: number): number
	local m = if width > height then width else height
	local p, s = 0, 1
	while s < m do
		s *= 2
		p += 1
	end
	return p
end

-- Parses a quadtree whose flag bits start at byte `fo` of `src` and whose leaf bytes follow.
-- Returns the tree and the offset just past the leaf bytes.
local function parseTree(
	src: buffer,
	fo: number,
	width: number,
	height: number,
	maxDepth: number,
	I: number
): (Tree, number)
	assert(width >= 1 and width <= 65535 and height >= 1 and height <= 65535, "bad tree size")
	local P = rootLog2(width, height)
	assert(maxDepth >= 0 and maxDepth <= P, "maxDepth must be in 0..P")
	local S = 2 ^ P
	local srcLen = buffer.len(src)

	-- pass 1: count nodes, leaves and flags
	local flagPos = 0
	local nodeCount, leafCount = 0, 0
	local function readFlag(): number
		local byteAt = fo + flagPos // 8
		assert(byteAt < srcLen, "flag stream truncated")
		local bit = bit32.extract(buffer.readu8(src, byteAt), flagPos % 8)
		flagPos += 1
		return bit
	end
	local function count(depth: number)
		nodeCount += 1
		if depth < maxDepth and readFlag() == 1 then
			count(depth + 1)
			count(depth + 1)
			count(depth + 1)
			count(depth + 1)
		else
			leafCount += 1
		end
	end
	count(0)
	local flagCount = flagPos
	local leafAt = fo + (flagCount + 7) // 8
	local leafEnd = leafAt + leafCount * I
	assert(leafEnd <= srcLen, "leaf bytes truncated")

	-- pass 2: node records
	local nodes = buffer.create(nodeCount * 4)
	local leafDepth = buffer.create(leafCount)
	flagPos = 0
	local nextNode, nextLeaf = 0, 0
	local function fill(depth: number): number
		local idx = nextNode
		nextNode += 1
		if depth < maxDepth and readFlag() == 1 then
			local size = 1 + fill(depth + 1)
			size += fill(depth + 1)
			size += fill(depth + 1)
			size += fill(depth + 1)
			buffer.writeu32(nodes, idx * 4, size * 2)
			return size
		end
		buffer.writeu32(nodes, idx * 4, nextLeaf * 2 + 1)
		buffer.writeu8(leafDepth, nextLeaf, depth)
		nextLeaf += 1
		return 1
	end
	fill(0)

	local leafBytes = buffer.create(leafCount * I + 8)
	buffer.copy(leafBytes, 0, src, leafAt, leafCount * I)

	-- content keys: equal bytes <=> equal key (exact integer keys for I <= 6, strings otherwise)
	local leafKey = buffer.create(leafCount * 4)
	local keyOf: { [any]: number } = {}
	local keyLeafList: { number } = {}
	local keyCount = 0
	for l = 0, leafCount - 1 do
		local at = l * I
		local key: any
		if I <= 6 then
			local v = 0
			for t = I - 1, 0, -1 do
				v = v * 256 + buffer.readu8(leafBytes, at + t)
			end
			key = v
		else
			key = buffer.readstring(leafBytes, at, I)
		end
		local id = keyOf[key]
		if id == nil then
			id = keyCount
			keyOf[key] = id
			keyCount += 1
			keyLeafList[keyCount] = l
		end
		buffer.writeu32(leafKey, l * 4, id)
	end
	local keyLeaf = buffer.create(math.max(keyCount, 1) * 4)
	for j = 1, keyCount do
		buffer.writeu32(keyLeaf, (j - 1) * 4, keyLeafList[j])
	end

	local tree: Tree = {
		width = width,
		height = height,
		maxDepth = maxDepth,
		P = P,
		S = S,
		I = I,
		nodeCount = nodeCount,
		leafCount = leafCount,
		flagCount = flagCount,
		nodes = nodes,
		leafBytes = leafBytes,
		leafDepth = leafDepth,
		leafKey = leafKey,
		keyCount = keyCount,
		keyLeaf = keyLeaf,
		virt = nil,
	}
	return tree, leafEnd
end

-- Builds a tree from a preorder bit stream (flags) and leaf bytes, as stored in the binary.
function Liquid.newTree(width: number, height: number, maxDepth: number, I: number, flags: buffer, leaves: buffer): Tree
	local fbytes = buffer.len(flags)
	local tmp = buffer.create(fbytes + buffer.len(leaves))
	buffer.copy(tmp, 0, flags, 0, fbytes)
	-- the flag stream may be longer than needed; parseTree finds the true length, so place
	-- the leaves right after the bytes the flags actually use by parsing twice
	local probe = parseTree(tmp, 0, width, height, maxDepth, I)
	local used = (probe.flagCount + 7) // 8
	local src = buffer.create(used + buffer.len(leaves))
	buffer.copy(src, 0, flags, 0, used)
	buffer.copy(src, used, leaves, 0, buffer.len(leaves))
	local tree = parseTree(src, 0, width, height, maxDepth, I)
	return tree
end

-- Builds a tree by preorder traversal. split(x0, y0, side, depth) decides whether a present
-- node of depth < maxDepth splits; leaf(x0, y0, side, depth, out, at) writes the leaf's I
-- bytes into `out` at byte offset `at`.
function Liquid.buildTree(
	width: number,
	height: number,
	maxDepth: number,
	I: number,
	split: (number, number, number, number) -> boolean,
	leaf: (number, number, number, number, buffer, number) -> ()
): Tree
	local P = rootLog2(width, height)
	assert(maxDepth >= 0 and maxDepth <= P, "maxDepth must be in 0..P")
	local flags: { number } = {}
	local leafCap = 1024
	local leaves = buffer.create(leafCap * I)
	local leafCount = 0
	local function visit(depth: number, x0: number, y0: number, side: number)
		local s = false
		if depth < maxDepth then
			s = split(x0, y0, side, depth)
			table.insert(flags, if s then 1 else 0)
		end
		if s then
			local h = side // 2
			visit(depth + 1, x0, y0, h)
			visit(depth + 1, x0 + h, y0, h)
			visit(depth + 1, x0, y0 + h, h)
			visit(depth + 1, x0 + h, y0 + h, h)
		else
			if leafCount == leafCap then
				local bigger = buffer.create(leafCap * 2 * I)
				buffer.copy(bigger, 0, leaves, 0, leafCap * I)
				leaves = bigger
				leafCap *= 2
			end
			leaf(x0, y0, side, depth, leaves, leafCount * I)
			leafCount += 1
		end
	end
	visit(0, 0, 0, 2 ^ P)
	local fb = buffer.create((#flags + 7) // 8 + leafCount * I)
	for j = 1, #flags do
		if flags[j] == 1 then
			local p = j - 1
			local at = p // 8
			buffer.writeu8(fb, at, buffer.readu8(fb, at) + 2 ^ (p % 8))
		end
	end
	local fo = (#flags + 7) // 8
	buffer.copy(fb, fo, leaves, 0, leafCount * I)
	local tree = parseTree(fb, 0, width, height, maxDepth, I)
	return tree
end

-- Reconstructs the preorder flag bits of a parsed tree (for encoding).
local function treeFlags(tree: Tree): buffer
	local out = buffer.create((tree.flagCount + 7) // 8)
	local pos = 0
	local nodes, D = tree.nodes, tree.maxDepth
	local function walk(n: number, depth: number): number
		local v = buffer.readu32(nodes, n * 4)
		local isLeaf = v % 2 == 1
		if depth < D then
			if not isLeaf then
				local at = pos // 8
				buffer.writeu8(out, at, buffer.readu8(out, at) + 2 ^ (pos % 8))
			end
			pos += 1
		end
		if isLeaf then
			return 1
		end
		local c = n + 1
		local size = 1
		for _ = 1, 4 do
			local sz = walk(c, depth + 1)
			size += sz
			c += sz
		end
		return size
	end
	walk(0, 0)
	assert(pos == tree.flagCount, "flag count mismatch")
	return out
end

local function writeF64s(b: buffer, at: number, a: { number }): number
	for j = 1, #a do
		buffer.writef64(b, at, a[j])
		at += 8
	end
	return at
end

local function readF64s(b: buffer, at: number, n: number): ({ number }, number)
	local a = table.create(n, 0)
	for j = 1, n do
		a[j] = buffer.readf64(b, at)
		at += 8
	end
	return a, at
end

-- Serialises a model and a tree into one version-1 blob.
function Liquid.encode(model: Model, tree: Tree): buffer
	local N, I, M = model.N, model.I, model.M
	assert(tree.I == I, "tree and model disagree on I")
	local flags = treeFlags(tree)
	local floats = N + N * I + N + 2 * M * N + M
	local size = 8 + floats * 8 + 5 + buffer.len(flags) + tree.leafCount * I
	local b = buffer.create(size)
	buffer.writeu8(b, 0, 0x41)
	buffer.writeu8(b, 1, 0x4C)
	buffer.writeu8(b, 2, 0x4E)
	buffer.writeu8(b, 3, Liquid.VERSION)
	buffer.writeu8(b, 4, N)
	buffer.writeu8(b, 5, I)
	buffer.writeu8(b, 6, M)
	buffer.writeu8(b, 7, model.K)
	local at = 8
	at = writeF64s(b, at, model.beta)
	at = writeF64s(b, at, model.B)
	at = writeF64s(b, at, model.kBase)
	at = writeF64s(b, at, model.Cf)
	at = writeF64s(b, at, model.Cb)
	at = writeF64s(b, at, model.d)
	buffer.writeu16(b, at, tree.width)
	buffer.writeu16(b, at + 2, tree.height)
	buffer.writeu8(b, at + 4, tree.maxDepth)
	at += 5
	buffer.copy(b, at, flags, 0, buffer.len(flags))
	at += buffer.len(flags)
	buffer.copy(b, at, tree.leafBytes, 0, tree.leafCount * I)
	return b
end

-- Parses a version-1 blob. Returns the model, the tree and the offset after the blob.
function Liquid.decode(b: buffer, offset: number?): (Model, Tree, number)
	local at = offset or 0
	assert(buffer.len(b) >= at + 8, "blob too short")
	assert(
		buffer.readu8(b, at) == 0x41 and buffer.readu8(b, at + 1) == 0x4C and buffer.readu8(b, at + 2) == 0x4E,
		"not an ALLAN blob (magic)"
	)
	local version = buffer.readu8(b, at + 3)
	assert(version == 1, `unsupported ALLAN version {version}`)
	local N, I, M, K = buffer.readu8(b, at + 4), buffer.readu8(b, at + 5), buffer.readu8(b, at + 6), buffer.readu8(b, at + 7)
	at += 8
	local floats = N + N * I + N + 2 * M * N + M
	assert(buffer.len(b) >= at + floats * 8 + 5, "blob truncated in the model arrays")
	local beta, B, kBase, Cf, Cb, d
	beta, at = readF64s(b, at, N)
	B, at = readF64s(b, at, N * I)
	kBase, at = readF64s(b, at, N)
	Cf, at = readF64s(b, at, M * N)
	Cb, at = readF64s(b, at, M * N)
	d, at = readF64s(b, at, M)
	local model = Liquid.newModel({ N = N, I = I, M = M, K = K, beta = beta, B = B, kBase = kBase, Cf = Cf, Cb = Cb, d = d })
	local width, height, maxDepth = buffer.readu16(b, at), buffer.readu16(b, at + 2), buffer.readu8(b, at + 4)
	local tree, after = parseTree(b, at + 5, width, height, maxDepth, I)
	return model, tree, after
end

local function sizeOf(nodes: buffer, n: number): number
	local v = buffer.readu32(nodes, n * 4)
	return if v % 2 == 1 then 1 else v // 2
end

-- Leaf containing pixel (x, y) of the stored tree: leaf index and depth. It walks the tree
-- independently of the row traversal used by the event renderer; the reference uses it.
-- Returns -1, -1 outside the image.
function Liquid.leafAt(tree: Tree, x: number, y: number): (number, number)
	if x < 0 or y < 0 or x >= tree.width or y >= tree.height then
		return -1, -1
	end
	local nodes = tree.nodes
	local n, x0, y0, side, depth = 0, 0, 0, tree.S, 0
	while true do
		local v = buffer.readu32(nodes, n * 4)
		if v % 2 == 1 then
			return (v - 1) // 2, depth
		end
		local h = side // 2
		local c = n + 1
		local right = x >= x0 + h
		local bottom = y >= y0 + h
		if bottom then
			c += sizeOf(nodes, c) -- skip child 0
			c += sizeOf(nodes, c) -- skip child 1
		end
		if right then
			c += sizeOf(nodes, c) -- skip the left child of the chosen pair
		end
		n = c
		if right then
			x0 += h
		end
		if bottom then
			y0 += h
		end
		side = h
		depth += 1
	end
end

----------------------------------------------------------------------------------------
-- Plan: everything that depends only on the model and the root size, precomputed once.
-- Every table is filled by a fixed sequence of deterministic operations, so every client
-- holds bit-identical tables (part of the fixed evaluation schedule of T1 and T7).
----------------------------------------------------------------------------------------

export type Plan = {
	model: Model,
	N: number,
	I: number,
	M: number,
	K: number,
	P: number, -- log2 of the stored root side
	S: number, -- stored root side
	R: number, -- log2 render scale r (X4); rendered geometry is the stored one times 2^R
	Wr: number, -- rendered width = width * 2^R
	Hr: number, -- rendered height
	Sr: number, -- rendered root side
	T: number, -- longest segment the power tables cover (= Sr)
	TP1: number, -- T + 1
	U: { number }, -- U[byte + 1] = byte / 255
	gk: { number }, -- gk[k + 1] = 2^-k
	pw: { number }, -- pw[k * TP1 + n + 1] = a_k^n, n = 0..T
	S1: { number }, -- S1[k * TP1 + n + 1] = sum_{t < n} a_k^t
	NT: { number }, -- NT[k * (JMAX + 1) + j + 1] = smallest n <= T with a_k^n <= 2^-j, else T + 1
	Csum: { number }, -- Cf + Cb
	kOf: { number }, -- kOf[t * N + i] = gain exponent of neuron i (1-based) in a leaf of depth t
	pwOff: { number }, -- pwOff[t * N + i] = kOf * TP1 + 1
	nCls: { number }, -- nCls[t + 1] = number of distinct gains k >= 1 at depth t
	clsK: { number }, -- clsK[t * K + c] = gain of class c at depth t, ascending
	clsOf: { number }, -- clsOf[t * N + i] = class of neuron i at depth t, 0 when k = 0
	G: { number }, -- G[L * K + k + 1] = S1[k][2^L] / 2^L (T5 footprint factor)
	-- fast path (M <= 4): tracked neurons are those with k >= 1 at some depth; the others
	-- are instant everywhere (h = b exactly) and never enter a transient
	nt: number,
	trk: { number }, -- trk[j] = neuron index of tracked neuron j
	trkOff: { number }, -- trkOff[t * nt + j] = pw offset of tracked neuron j at depth t
	trkCls: { number }, -- trkCls[t * nt + j] = its class at depth t (0 when k = 0 there)
	CfT4: { number }, -- CfT4[(j - 1) * 4 + m] = Cf[m][trk[j]], zero for m > M
	CbT4: { number },
	maxSeg: number,
	scratch: any,
}

-- renderScale: log2 of the render scale r (default 0). The plan depends on the tree only
-- through its root size, so trees of equal root size can share a plan.
function Liquid.prepare(model: Model, tree: Tree, renderScale: number?): Plan
	local N, I, M, K = model.N, model.I, model.M, model.K
	assert(tree.I == I, "tree and model disagree on I")
	local R = renderScale or 0
	assert(R >= 0 and R <= 8 and R % 1 == 0, "render scale must be an integer in 0..8")
	local P, S = tree.P, tree.S
	local sf = 2 ^ R
	local T = S * sf
	assert(T <= 65536, "rendered root side above 65536")
	local TP1 = T + 1
	local U = table.create(256, 0)
	for v = 0, 255 do
		U[v + 1] = v / 255
	end
	local gk = table.create(K, 0)
	for k = 0, K - 1 do
		gk[k + 1] = 1 / 2 ^ k -- exact power of two
	end
	local pw = table.create(K * TP1, 0)
	local S1 = table.create(K * TP1, 0)
	local NT = table.create(K * (JMAX + 1), 0)
	for k = 0, K - 1 do
		local a = 1 - gk[k + 1]
		local base = k * TP1
		pw[base + 1] = 1
		if T >= 1 then
			pw[base + 2] = a
		end
		for n = 2, T do
			local h = n // 2
			pw[base + n + 1] = pw[base + h + 1] * pw[base + n - h + 1]
		end
		S1[base + 1] = 0
		for n = 1, T do
			S1[base + n + 1] = S1[base + n] + pw[base + n]
		end
		local j = 0
		local thr = 1
		local nb = k * (JMAX + 1)
		for n = 0, T do
			local p = pw[base + n + 1]
			while j <= JMAX and p <= thr do
				NT[nb + j + 1] = n
				j += 1
				thr *= 0.5
			end
		end
		while j <= JMAX do
			NT[nb + j + 1] = T + 1
			j += 1
		end
	end
	local Csum = table.create(M * N, 0)
	for j = 1, M * N do
		Csum[j] = model.Cf[j] + model.Cb[j]
	end
	local kOf = table.create((P + 1) * N, 0)
	local pwOff = table.create((P + 1) * N, 0)
	local nCls = table.create(P + 1, 0)
	local clsK = table.create((P + 1) * K, 0)
	local clsOf = table.create((P + 1) * N, 0)
	for t = 0, P do
		local present = table.create(K, false)
		for i = 1, N do
			local k = model.kBase[i] + (P - t) + R
			if k < 0 then
				k = 0
			elseif k > K - 1 then
				k = K - 1
			end
			kOf[t * N + i] = k
			pwOff[t * N + i] = k * TP1 + 1
			if k >= 1 then
				present[k + 1] = true
			end
		end
		local nc = 0
		local idx = table.create(K, 0)
		for k = 1, K - 1 do
			if present[k + 1] then
				nc += 1
				clsK[t * K + nc] = k
				idx[k + 1] = nc
			end
		end
		nCls[t + 1] = nc
		for i = 1, N do
			local k = kOf[t * N + i]
			clsOf[t * N + i] = if k >= 1 then idx[k + 1] else 0
		end
	end
	local G = table.create((P + R + 1) * K, 0)
	for L = 0, P + R do
		local F = 2 ^ L
		for k = 0, K - 1 do
			G[L * K + k + 1] = S1[k * TP1 + F + 1] / F
		end
	end
	local trk: { number } = {}
	for i = 1, N do
		local tracked = false
		for t = 0, P do
			if kOf[t * N + i] >= 1 then
				tracked = true
			end
		end
		if tracked then
			table.insert(trk, i)
		end
	end
	local nt = #trk
	local trkOff = table.create((P + 1) * math.max(nt, 1), 0)
	local trkCls = table.create((P + 1) * math.max(nt, 1), 0)
	for t = 0, P do
		for j = 1, nt do
			trkOff[t * nt + j] = pwOff[t * N + trk[j]]
			trkCls[t * nt + j] = clsOf[t * N + trk[j]]
		end
	end
	local CfT4 = table.create(math.max(nt, 1) * 4, 0)
	local CbT4 = table.create(math.max(nt, 1) * 4, 0)
	for j = 1, nt do
		for m = 1, math.min(M, 4) do
			CfT4[(j - 1) * 4 + m] = model.Cf[(m - 1) * N + trk[j]]
			CbT4[(j - 1) * 4 + m] = model.Cb[(m - 1) * N + trk[j]]
		end
	end
	local plan: Plan = {
		model = model,
		N = N,
		I = I,
		M = M,
		K = K,
		P = P,
		S = S,
		R = R,
		Wr = tree.width * sf,
		Hr = tree.height * sf,
		Sr = T,
		T = T,
		TP1 = TP1,
		U = U,
		gk = gk,
		pw = pw,
		S1 = S1,
		NT = NT,
		Csum = Csum,
		kOf = kOf,
		pwOff = pwOff,
		nCls = nCls,
		clsK = clsK,
		clsOf = clsOf,
		G = G,
		nt = nt,
		trk = trk,
		trkOff = trkOff,
		trkCls = trkCls,
		CfT4 = CfT4,
		CbT4 = CbT4,
		maxSeg = T + 2,
		scratch = nil,
	}
	return plan
end

-- Smallest j >= 0 with 2^j >= r, for r > 0, by exact binary exponent search (multiplying
-- by powers of two is exact): at most 10 comparisons, no logarithm. Proof in LIQUID.md T3.
local function ceilLog2(r: number): number
	if r <= 1 then
		return 0
	end
	local e = 0
	if r > 2 ^ 512 then
		r *= 2 ^ -512
		e += 512
	end
	if r > 2 ^ 256 then
		r *= 2 ^ -256
		e += 256
	end
	if r > 2 ^ 128 then
		r *= 2 ^ -128
		e += 128
	end
	if r > 2 ^ 64 then
		r *= 2 ^ -64
		e += 64
	end
	if r > 2 ^ 32 then
		r *= 2 ^ -32
		e += 32
	end
	if r > 65536 then
		r *= 2 ^ -16
		e += 16
	end
	if r > 256 then
		r *= 2 ^ -8
		e += 8
	end
	if r > 16 then
		r *= 2 ^ -4
		e += 4
	end
	if r > 4 then
		r *= 0.25
		e += 2
	end
	if r > 2 then
		e += 1
	end
	return e + 1
end
Liquid.ceilLog2 = ceilLog2

-- Distance from z to the nearest point where clamp(floor(z + 0.5), 0, 255) changes.
local function margin(z: number): number
	if z < 0.5 then
		return 0.5 - z
	end
	if z >= 254.5 then
		return z - 254.5
	end
	local f = z + 0.5 - floor(z + 0.5)
	return if f < 0.5 then f else 1 - f
end
Liquid.margin = margin

----------------------------------------------------------------------------------------
-- Scratch space (per plan): segment arrays, traversal stack, per-segment work arrays
----------------------------------------------------------------------------------------

type Scratch = {
	cap: number,
	sx: { number }, -- segment start (base pixels, absolute)
	sl: { number }, -- segment length
	skey: { number }, -- leaf content key (equal key and depth <=> identical dynamics)
	sleaf: { number }, -- a leaf index carrying the content (for its bytes)
	sdep: { number }, -- leaf depth
	sb: { number }, -- targets b, N per segment
	seb: { number }, -- backward entering residuals, N per segment
	h: { number },
	ef: { number },
	stN: { number },
	stX: { number },
	stY: { number },
	stS: { number },
	stD: { number },
	stV: { number }, -- 1 if the stack entry is a virtual node (endless mode)
	zinf: { number },
	tau: { number },
	Qf: { number },
	Qb: { number },
	fOff: { number },
	fQ: { number },
	fDrop: { number },
	bOff: { number },
	bQ: { number },
	bDrop: { number },
	wf: { number },
	wb: { number },
	z: { number },
	pend: { number },
	acc: { number },
	stats: Stats,
}

export type Stats = {
	rows: number, -- output rows produced
	rendered: number, -- row renders (band rows actually evaluated)
	copied: number, -- output rows produced by buffer.copy of an identical row
	deduped: number, -- band rows reused from an identical earlier band (cross-band dedup)
	multiBand: number, -- output rows needing the vertical box merge
	segments: number, -- segments rendered (events)
	evals: number, -- per-pixel closed-form evaluations (transients)
	pieces: number, -- partial footprint pieces
	fills: number, -- fill spans
	fillPixels: number, -- pixels written by fills
	searchProbes: number, -- bound evaluations made by the n0 search
	seam: number, -- endless mode: largest X3 certificate of the rendered block rows
}

local function newStats(): Stats
	return {
		rows = 0,
		rendered = 0,
		copied = 0,
		deduped = 0,
		multiBand = 0,
		segments = 0,
		evals = 0,
		pieces = 0,
		fills = 0,
		fillPixels = 0,
		searchProbes = 0,
		seam = 0,
	}
end
Liquid.newStats = newStats

local function getScratch(plan: Plan, minCap: number): Scratch
	local sc: Scratch? = plan.scratch
	if sc and sc.cap >= minCap then
		return sc
	end
	local cap = math.max(minCap, plan.maxSeg)
	local N, K = plan.N, plan.K
	local M = math.max(plan.M, 4)
	local depthCap = 4 * (plan.P + 40)
	local new: any = {
		slot = table.create(cap, 0),
		tmpB = table.create(N, 0),
		rowB = table.create(cap * math.max(plan.nt, 1), 0),
		rowZ = table.create(cap * 4, 0),
		rowMg = table.create(cap * 4, 0),
		rowCol = table.create(cap, 0),
		cacheTree = nil,
		cacheOn = false,
		fW = table.create(K, 0),
		fThr = table.create(K, 0),
		bW = table.create(K, 0),
		bThr = table.create(K, 0),
		aOff = table.create(K, 0),
		aQ = table.create(K * 4, 0),
		aThr = table.create(K, 0),
		oOff = table.create(K, 0),
		oQ = table.create(K * 4, 0),
		certF = table.create(math.max(plan.nt, 1), 1),
		certB = table.create(math.max(plan.nt, 1), 1),
		rangeTree = nil,
		ranges = nil,
	}
	local base: Scratch = {
		cap = cap,
		sx = table.create(cap, 0),
		sl = table.create(cap, 0),
		skey = table.create(cap, 0),
		sleaf = table.create(cap, 0),
		sdep = table.create(cap, 0),
		sb = table.create(cap * N, 0),
		seb = table.create(cap * N, 0),
		h = table.create(N, 0),
		ef = table.create(N, 0),
		stN = table.create(depthCap, 0),
		stX = table.create(depthCap, 0),
		stY = table.create(depthCap, 0),
		stS = table.create(depthCap, 0),
		stD = table.create(depthCap, 0),
		stV = table.create(depthCap, 0),
		zinf = table.create(M, 0),
		tau = table.create(M, 0),
		Qf = table.create(K * M, 0),
		Qb = table.create(K * M, 0),
		fOff = table.create(K, 0),
		fQ = table.create(K * M, 0),
		fDrop = table.create(K, 0),
		bOff = table.create(K, 0),
		bQ = table.create(K * M, 0),
		bDrop = table.create(K, 0),
		wf = table.create(K, 0),
		wb = table.create(K, 0),
		z = table.create(M, 0),
		pend = table.create(M, 0),
		acc = {},
		stats = newStats(),
	}
	for k, v in base :: any do
		new[k] = v
	end
	plan.scratch = new
	return new
end

----------------------------------------------------------------------------------------
-- Row segmentation of the stored tree. Fills the scratch segment arrays with the leaves
-- crossed by row y inside [xa, xb), left to right, merging neighbours with identical
-- content and depth (identical dynamics). Returns the count and the band end: the smallest
-- bottom edge among the crossed leaves, so rows y .. bandEnd - 1 cross the same leaves.
----------------------------------------------------------------------------------------

-- Coordinates are rendered pixels (stored geometry times 2^R).
local function segmentStored(plan: Plan, tree: Tree, sc: Scratch, y: number, xa: number, xb: number, count: number): (number, number)
	local nodes = tree.nodes
	local leafKey, leafDepth = tree.leafKey, tree.leafDepth
	local W, H, T = plan.Wr, plan.Hr, plan.T
	local stN, stX, stY, stS, stD = sc.stN, sc.stX, sc.stY, sc.stS, sc.stD
	local sx, sl, skey, sleaf, sdep = sc.sx, sc.sl, sc.skey, sc.sleaf, sc.sdep
	local bandEnd = math.huge
	if y < 0 or y >= H then
		return count, bandEnd
	end
	if xb > W then
		xb = W
	end
	local sp = 1
	stN[1], stX[1], stY[1], stS[1], stD[1] = 0, 0, 0, plan.Sr, 0
	while sp > 0 do
		local n, x0, y0, side, dep = stN[sp], stX[sp], stY[sp], stS[sp], stD[sp]
		sp -= 1
		if x0 >= xb or x0 + side <= xa then
			continue
		end
		local v = buffer.readu32(nodes, n * 4)
		if v % 2 == 1 then
			local leaf = (v - 1) // 2
			local yEnd = y0 + side
			if yEnd < bandEnd then
				bandEnd = yEnd
			end
			local s0 = if x0 > xa then x0 else xa
			local e0 = x0 + side
			if e0 > xb then
				e0 = xb
			end
			local key = buffer.readu32(leafKey, leaf * 4)
			local ld = buffer.readu8(leafDepth, leaf)
			if count > 0 and skey[count] == key and sdep[count] == ld and e0 - sx[count] <= T then
				sl[count] = e0 - sx[count]
			else
				count += 1
				sx[count] = s0
				sl[count] = e0 - s0
				skey[count] = key
				sleaf[count] = leaf
				sdep[count] = ld
			end
		else
			local h = side // 2
			local c = n + 1
			local d1 = dep + 1
			local yy = y0
			if y >= y0 + h then
				c += sizeOf(nodes, c)
				c += sizeOf(nodes, c)
				yy = y0 + h
			end
			-- push the right child first so the left one is processed first
			sp += 1
			stN[sp], stX[sp], stY[sp], stS[sp], stD[sp] = c + sizeOf(nodes, c), x0 + h, yy, h, d1
			sp += 1
			stN[sp], stX[sp], stY[sp], stS[sp], stD[sp] = c, x0, yy, h, d1
		end
	end
	if bandEnd > H then
		bandEnd = H
	end
	return count, bandEnd
end

-- Targets b (N values) of leaf `leaf` into dst[at + 1 .. at + N], in the header's order.
local function leafTargets(plan: Plan, tree: Tree, leaf: number, dst: { number }, at: number)
	local model = plan.model
	local N, I = plan.N, plan.I
	local beta, B, U = model.beta, model.B, plan.U
	local lb = tree.leafBytes
	local o = leaf * I
	for i = 1, N do
		local b = beta[i]
		local bi = (i - 1) * I
		for t = 0, I - 1 do
			b = b + B[bi + t + 1] * U[buffer.readu8(lb, o + t) + 1]
		end
		dst[at + i] = b
	end
end

----------------------------------------------------------------------------------------
-- X3 endless textures. The plane is tiled by blocks of the rendered root side Sr; block
-- (0, 0) holds the stored tree. Every other block, and every stored node with no pixel
-- inside the image, is a virtual quadtree: a node of depth t at stored-pixel origin
-- (xs, ys) splits iff t < maxDepth and hash2(xs, ys, seedT) mod nodesAt[t] < splitsAt[t]
-- (the stored tree's split ratio at that depth), and a virtual leaf takes the content of
-- the stored leaf leavesAt[t][hash2(xs, ys, seedL) mod #leavesAt[t]] (any inside leaf when
-- the stored tree has none at that depth). Only stored contents ever appear, so the
-- trained readout sees inputs from its own distribution. Integers and bit32 only: every
-- client generates the same leaves.
----------------------------------------------------------------------------------------

local function virtualStats(tree: Tree): VirtualStats
	local v = tree.virt
	if v then
		return v
	end
	local D = tree.maxDepth
	local nodesAt, splitsAt = table.create(D + 1, 0), table.create(D + 1, 0)
	local leavesAt: { { number } } = {}
	for t = 1, D + 1 do
		leavesAt[t] = {}
	end
	local all: { number } = {}
	local nodes, W, H = tree.nodes, tree.width, tree.height
	local function walk(n: number, depth: number, x0: number, y0: number, side: number): number
		local val = buffer.readu32(nodes, n * 4)
		local inside = x0 < W and y0 < H
		if val % 2 == 1 then
			if inside then
				nodesAt[depth + 1] += 1
				table.insert(leavesAt[depth + 1], (val - 1) // 2)
				table.insert(all, (val - 1) // 2)
			end
			return 1
		end
		if inside then
			nodesAt[depth + 1] += 1
			splitsAt[depth + 1] += 1
		end
		local h = side // 2
		local c = n + 1
		c += walk(c, depth + 1, x0, y0, h)
		c += walk(c, depth + 1, x0 + h, y0, h)
		c += walk(c, depth + 1, x0, y0 + h, h)
		c += walk(c, depth + 1, x0 + h, y0 + h, h)
		return c - n
	end
	walk(0, 0, 0, 0, tree.S)
	local stats: VirtualStats = { nodesAt = nodesAt, splitsAt = splitsAt, leavesAt = leavesAt, all = all }
	tree.virt = stats
	return stats
end

export type Endless = {
	seed: number, -- any integer; selects the virtual canvas
	horizon: number?, -- h >= 1 blocks of warm-up on each side of a block (default 2)
}

-- Leaf of the virtual canvas containing stored pixel (xs, ys): (stored leaf index whose
-- content it carries, depth). Independent of the row traversal; the endless reference uses it.
function Liquid.virtualLeafAt(tree: Tree, xs: number, ys: number, seed: number): (number, number)
	local V = virtualStats(tree)
	local S, D = tree.S, tree.maxDepth
	local W, H = tree.width, tree.height
	local bx, by = xs // S, ys // S
	local x0, y0, side, depth = bx * S, by * S, S, 0
	local n = if bx == 0 and by == 0 then 0 else -1
	local seedL = hash2(0, 0x1EAF, seed)
	while true do
		if n >= 0 and not (x0 < W and y0 < H) then
			n = -1 -- stored node outside the image: virtual from here on
		end
		if n >= 0 then
			local val = buffer.readu32(tree.nodes, n * 4)
			if val % 2 == 1 then
				return (val - 1) // 2, depth
			end
		else
			local cnt = V.nodesAt[depth + 1]
			local split = depth < D and cnt > 0 and hash2(x0, y0, hash2(depth, 0x5B1, seed)) % cnt < V.splitsAt[depth + 1]
			if not split then
				local list = V.leavesAt[depth + 1]
				if #list == 0 then
					list = V.all
				end
				return list[hash2(x0, y0, seedL) % #list + 1], depth
			end
		end
		local h = side // 2
		local right = xs >= x0 + h
		local bottom = ys >= y0 + h
		if n >= 0 then
			local c = n + 1
			if bottom then
				c += sizeOf(tree.nodes, c)
				c += sizeOf(tree.nodes, c)
			end
			if right then
				c += sizeOf(tree.nodes, c)
			end
			n = c
		end
		if right then
			x0 += h
		end
		if bottom then
			y0 += h
		end
		side = h
		depth += 1
	end
end

-- Endless counterpart of segmentStored: segments of rendered row y over [xa, xb) on the
-- virtual canvas (any integers), merged like the stored ones.
local function segmentEndless(plan: Plan, tree: Tree, sc: Scratch, y: number, xa: number, xb: number, seed: number): (number, number)
	local V = virtualStats(tree)
	local nodes = tree.nodes
	local leafKey = tree.leafKey
	local sf = 2 ^ plan.R
	local Sr, T, D = plan.Sr, plan.T, tree.maxDepth
	local Wr, Hr = plan.Wr, plan.Hr
	local nodesAt, splitsAt, leavesAt, all = V.nodesAt, V.splitsAt, V.leavesAt, V.all
	local stN, stX, stY, stS, stD = sc.stN, sc.stX, sc.stY, sc.stS, sc.stD
	local sx, sl, skey, sleaf, sdep = sc.sx, sc.sl, sc.skey, sc.sleaf, sc.sdep
	local seedL = hash2(0, 0x1EAF, seed)
	local count = 0
	local bandEnd = math.huge
	local by = y // Sr
	for bx = xa // Sr, (xb - 1) // Sr do
		local sp = 1
		stN[1], stX[1], stY[1], stS[1], stD[1] = if bx == 0 and by == 0 then 0 else -1, bx * Sr, by * Sr, Sr, 0
		while sp > 0 do
			local n, x0, y0, side, dep = stN[sp], stX[sp], stY[sp], stS[sp], stD[sp]
			sp -= 1
			if x0 >= xb or x0 + side <= xa then
				continue
			end
			if n >= 0 and not (x0 < Wr and y0 < Hr) then
				n = -1
			end
			local leaf = -1
			if n >= 0 then
				local val = buffer.readu32(nodes, n * 4)
				if val % 2 == 1 then
					leaf = (val - 1) // 2
				end
			else
				local xs, ys = x0 // sf, y0 // sf
				local cnt = nodesAt[dep + 1]
				local split = dep < D and cnt > 0 and hash2(xs, ys, hash2(dep, 0x5B1, seed)) % cnt < splitsAt[dep + 1]
				if not split then
					local list = leavesAt[dep + 1]
					if #list == 0 then
						list = all
					end
					leaf = list[hash2(xs, ys, seedL) % #list + 1]
				end
			end
			if leaf >= 0 then
				local yEnd = y0 + side
				if yEnd < bandEnd then
					bandEnd = yEnd
				end
				local s0 = if x0 > xa then x0 else xa
				local e0 = x0 + side
				if e0 > xb then
					e0 = xb
				end
				local key = buffer.readu32(leafKey, leaf * 4)
				if count > 0 and skey[count] == key and sdep[count] == dep and e0 - sx[count] <= T then
					sl[count] = e0 - sx[count]
				else
					count += 1
					sx[count] = s0
					sl[count] = e0 - s0
					skey[count] = key
					sleaf[count] = leaf
					sdep[count] = dep
				end
			else
				local h = side // 2
				local yy = y0
				local c0, c1 = -1, -1
				if n >= 0 then
					local c = n + 1
					if y >= y0 + h then
						c += sizeOf(nodes, c)
						c += sizeOf(nodes, c)
					end
					c0, c1 = c, c + sizeOf(nodes, c)
				end
				if y >= y0 + h then
					yy = y0 + h
				end
				sp += 1
				stN[sp], stX[sp], stY[sp], stS[sp], stD[sp] = c1, x0 + h, yy, h, dep + 1
				sp += 1
				stN[sp], stX[sp], stY[sp], stS[sp], stD[sp] = c0, x0, yy, h, dep + 1
			end
		end
	end
	return count, bandEnd
end

-- Seam bound of the endless mode (output units, per channel): two block windows that
-- overlap at a pixel disagree there by at most this much, so neighbouring pixels of two
-- blocks differ from a seamless canvas by at most this. Proof in docs/LIQUID.md (X3).
function Liquid.seamBound(plan: Plan, tree: Tree, horizon: number): number
	local model = plan.model
	local N, M = plan.N, plan.M
	local tmp = table.create(N, 0)
	local lo, hi = table.create(N, math.huge), table.create(N, -math.huge)
	for key = 0, tree.keyCount - 1 do
		leafTargets(plan, tree, buffer.readu32(tree.keyLeaf, key * 4), tmp, 0)
		for i = 1, N do
			if tmp[i] < lo[i] then
				lo[i] = tmp[i]
			end
			if tmp[i] > hi[i] then
				hi[i] = tmp[i]
			end
		end
	end
	local worst = 0
	local dist = horizon * plan.Sr
	for m = 0, M - 1 do
		local sum = 0
		for i = 1, N do
			local kmax = 0
			for t = 0, plan.P do
				local k = plan.kOf[t * N + i]
				if k > kmax then
					kmax = k
				end
			end
			local a = 1 - plan.gk[kmax + 1]
			-- a^dist by squaring (an upper estimate is fine here: rounding is 1e-13 relative)
			local p, base, e = 1, a, dist
			while e > 0 do
				if e % 2 == 1 then
					p *= base
				end
				base *= base
				e //= 2
			end
			sum += (math.abs(model.Cf[m * N + i]) + math.abs(model.Cb[m * N + i])) * (hi[i] - lo[i]) * p
		end
		if sum > worst then
			worst = sum
		end
	end
	return worst * (1 + 1e-9)
end

-- Range (max - min) of each tracked neuron's target over the stored contents: every state
-- of either pass lies in that range, so it bounds any state difference (X3 certificates).
local function trackedRanges(plan: Plan, tree: Tree, sc: any): { number }
	if sc.rangeTree == tree then
		return sc.ranges
	end
	local N, nt, trk = plan.N, plan.nt, plan.trk
	local tmp = table.create(N, 0)
	local lo, hi = table.create(nt, math.huge), table.create(nt, -math.huge)
	for key = 0, tree.keyCount - 1 do
		leafTargets(plan, tree, buffer.readu32(tree.keyLeaf, key * 4), tmp, 0)
		for j = 1, nt do
			local b = tmp[trk[j]]
			if b < lo[j] then
				lo[j] = b
			end
			if b > hi[j] then
				hi[j] = b
			end
		end
	end
	local r = table.create(nt, 0)
	for j = 1, nt do
		r[j] = if hi[j] >= lo[j] then hi[j] - lo[j] else 0
	end
	sc.rangeTree = tree
	sc.ranges = r
	return r
end

-- A-posteriori X3 certificate for the segments 1..n in the scratch, which cover a window
-- [wa, wb) whose passes start at rest: every output of a pixel in [xl, xr) differs from the
-- infinite-row model (any history beyond the window) by at most the returned value, per
-- channel. It is the actual contraction of each neuron from wa to xl and from wb to xr,
-- times its state range and readout weights (proof in docs/LIQUID.md, X3).
local function windowCert(plan: Plan, tree: Tree, sc: any, n: number, xl: number, xr: number): number
	local nt = plan.nt
	if nt == 0 then
		return 0
	end
	local E = trackedRanges(plan, tree, sc)
	local pw, trkOff = plan.pw, plan.trkOff
	local sx, sl, sdep = sc.sx, sc.sl, sc.sdep
	local cf, cb = sc.certF, sc.certB
	for j = 1, nt do
		cf[j], cb[j] = 1, 1
	end
	for s = 1, n do
		local x0 = sx[s]
		local x1 = x0 + sl[s]
		local to = sdep[s] * nt
		local f1 = if x1 < xl then x1 else xl
		if f1 > x0 then
			for j = 1, nt do
				cf[j] *= pw[trkOff[to + j] + f1 - x0]
			end
		end
		local b0 = if x0 > xr then x0 else xr
		if x1 > b0 then
			for j = 1, nt do
				cb[j] *= pw[trkOff[to + j] + x1 - b0]
			end
		end
	end
	local CfT4, CbT4 = plan.CfT4, plan.CbT4
	local worst = 0
	for m = 1, math.min(plan.M, 4) do
		local sum = 0
		for j = 1, nt do
			local co = (j - 1) * 4 + m
			sum += (math.abs(CfT4[co]) * cf[j] + math.abs(CbT4[co]) * cb[j]) * E[j]
		end
		if sum > worst then
			worst = sum
		end
	end
	return worst * (1 + 1e-9) -- covers the rounding of the products (relative 1e-13)
end

-- Certificate of the window [wa, wb) of rendered row y on the endless canvas for pixels in
-- [xl, xr) (see windowCert). Exposed for tests and tools.
function Liquid.windowCertificate(plan: Plan, tree: Tree, y: number, wa: number, wb: number, xl: number, xr: number, seed: number): number
	local sc: any = getScratch(plan, wb - wa + 2)
	local n = segmentEndless(plan, tree, sc, y, wa, wb, seed)
	return windowCert(plan, tree, sc, n, xl, xr)
end

-- Public helper for tests: segments of row y as { {x, len, leaf, depth}, ... } plus band end.
function Liquid.rowSegments(plan: Plan, tree: Tree, y: number): ({ { number } }, number)
	local sc = getScratch(plan, plan.Wr + 2)
	local n, bandEnd = segmentStored(plan, tree, sc, y, 0, plan.Wr, 0)
	local out = {}
	for s = 1, n do
		out[s] = { sc.sx[s], sc.sl[s], sc.sleaf[s], sc.sdep[s] }
	end
	return out, bandEnd
end

----------------------------------------------------------------------------------------
-- Reference renderer: the model stepped pixel by pixel, literally as in the header.
----------------------------------------------------------------------------------------

-- Real-valued outputs of rendered row y over the window [xa, xb), both passes at rest at
-- the window ends: zOut[((x - xa) * M + m) + 1], m in [0, M). leafFn(x, y) -> (leaf,
-- depth) gives the leaf of each rendered pixel.
function Liquid.referenceSpan(plan: Plan, tree: Tree, y: number, xa: number, xb: number, zOut: { number }, leafFn: (number, number) -> (number, number))
	local model = plan.model
	local N, M = plan.N, plan.M
	local W = xb - xa
	local Cf, Cb, d = model.Cf, model.Cb, model.d
	local kOf, gk = plan.kOf, plan.gk
	local lookup = function(x: number, yy: number): (number, number)
		return leafFn(x + xa, yy)
	end
	-- per-pixel b and g
	local bs = table.create(W * N, 0)
	local gs = table.create(W * N, 0)
	local lastLeaf, lastDepth = -2, -2
	local tmp = table.create(N, 0)
	for x = 0, W - 1 do
		local leaf, depth = lookup(x, y)
		if leaf ~= lastLeaf or depth ~= lastDepth then
			leafTargets(plan, tree, leaf, tmp, 0)
			lastLeaf, lastDepth = leaf, depth
		end
		for i = 1, N do
			bs[x * N + i] = tmp[i]
			gs[x * N + i] = gk[kOf[depth * N + i] + 1]
		end
	end
	-- backward pass, at rest at its first pixel (x = W - 1)
	local hb = table.create(W * N, 0)
	local h = table.create(N, 0)
	for i = 1, N do
		h[i] = bs[(W - 1) * N + i]
	end
	for x = W - 1, 0, -1 do
		local o = x * N
		for i = 1, N do
			local hi = h[i]
			hi = hi + (bs[o + i] - hi) * gs[o + i]
			h[i] = hi
			hb[o + i] = hi
		end
	end
	-- forward pass and output
	for i = 1, N do
		h[i] = bs[i]
	end
	for x = 0, W - 1 do
		local o = x * N
		for i = 1, N do
			local hi = h[i]
			h[i] = hi + (bs[o + i] - hi) * gs[o + i]
		end
		for m = 0, M - 1 do
			local z = d[m + 1]
			local cm = m * N
			for i = 1, N do
				z = z + Cf[cm + i] * h[i]
			end
			for i = 1, N do
				z = z + Cb[cm + i] * hb[o + i]
			end
			zOut[x * M + m + 1] = z
		end
	end
end

-- Real-valued outputs of rendered row y: zOut[(x * M + m) + 1] for x in [0, Wr), m in
-- [0, M). leafFn(x, y) -> (leaf, depth) gives the leaf of each rendered pixel (default:
-- Liquid.leafAt on the stored pixel (x >> R, y >> R)).
function Liquid.referenceRow(plan: Plan, tree: Tree, y: number, zOut: { number }, leafFn: ((number, number) -> (number, number))?)
	local sf = 2 ^ plan.R
	local lookup = leafFn or function(x: number, yy: number): (number, number)
		return Liquid.leafAt(tree, x // sf, yy // sf)
	end
	Liquid.referenceSpan(plan, tree, y, 0, plan.Wr, zOut, lookup)
end

-- Endless reference (X3): real values of the block column containing rendered pixel x,
-- stepped over that block's canonical window: zOut[((x - wa) * M + m) + 1] for x in the
-- window [wa, wb). Returns wa, wb.
function Liquid.referenceEndless(plan: Plan, tree: Tree, y: number, block: number, horizon: number, seed: number, zOut: { number }): (number, number)
	local Sr = plan.Sr
	local sf = 2 ^ plan.R
	local wa, wb = (block - horizon) * Sr, (block + 1 + horizon) * Sr
	Liquid.referenceSpan(plan, tree, y, wa, wb, zOut, function(x: number, yy: number): (number, number)
		return Liquid.virtualLeafAt(tree, x // sf, yy // sf, seed)
	end)
	return wa, wb
end

local function quant(z: number): number
	local q = floor(z + 0.5)
	return if q < 0 then 0 elseif q > 255 then 255 else q
end
Liquid.quantize = quant

local function packZ(z: { number }, M: number, base: number): number
	-- channels base+1 .. base+4 of z (1-based) into RGBA8; missing alpha 255, others 0
	local n = M - base
	local r = if n >= 1 then quant(z[base + 1]) else 0
	local g = if n >= 2 then quant(z[base + 2]) else 0
	local b = if n >= 3 then quant(z[base + 3]) else 0
	local a = if n >= 4 then quant(z[base + 4]) else 255
	return r + g * 256 + b * 65536 + a * 16777216
end

----------------------------------------------------------------------------------------
-- Event renderer: one row.
--
-- Within a segment (constant b and a), with e = (state entering the segment) - b, the
-- state after n steps is b + e a^n (T1). Neurons of equal gain k at a depth form a class;
-- the readout collapses each class to one amplitude per channel, Qf[c][m] =
-- sum_{i in c} Cf[m][i] ef_i (Qb likewise), and k = 0 classes vanish after one step. For
-- an output pixel at level L (footprint F = 2^L rendered pixels, first forward step nf,
-- smallest backward step nb), the exact footprint average is (T5)
--     zinf_m + sum_c G[L][k_c] (Qf[c][m] a_c^nf + Qb[c][m] a_c^nb),
-- with zinf_m = d_m + sum_i (Cf + Cb)[m][i] b_i and G[L][k] = (1 - a^F) / (F g).
-- Fill rule (T2 with the quantisation margin): with tau_m = max(eps, margin(zinf_m) - ETA),
-- once sum_c |Qf'| a^nf <= tau_m / 2 (forward) and sum_c |Qb'| a^nb <= tau_m / 2
-- (backward), the pixel is the quantised zinf; it is within eps + 0.5 of the exact value,
-- and exactly the exact value's byte whenever tau_m exceeds eps. The fill region is found
-- by a galloping search capped by the logarithm-free T3 bound; transient pixels are
-- evaluated in closed form with the T4 decaying active set (dropped classes share eps).
----------------------------------------------------------------------------------------

-- Inserts class j (drop key `key`) keeping keys sorted descending (forward lists) or
-- ascending (backward lists); returns the new count.
local function insertSorted(off: { number }, q: { number }, drop: { number }, n: number, M: number, o: number, src: { number }, srcAt: number, key: number, descending: boolean): number
	local pos = n + 1
	while pos > 1 do
		local prev = drop[pos - 1]
		if (descending and prev >= key) or (not descending and prev <= key) then
			break
		end
		off[pos] = off[pos - 1]
		drop[pos] = prev
		local a, b = (pos - 1) * M, (pos - 2) * M
		for m = 1, M do
			q[a + m] = q[b + m]
		end
		pos -= 1
	end
	off[pos] = o
	drop[pos] = key
	local a = (pos - 1) * M
	for m = 1, M do
		q[a + m] = src[srcAt + m]
	end
	return n + 1
end

-- Renders output pixels X in [X0, X1) of one row at level L from the segments 1..nseg in
-- the scratch. mode 0 quantises and writes RGBA8 pixels at out[rowAt + (X - X0) * 4]
-- (channels 4..7 into out2 at the same offset); mode 1 adds wgt * z_m into
-- sc.acc[(X - X0) * M + m]. xEnd is the right edge (rendered pixels) used to clip the last
-- footprint.
local function eventRow(
	plan: Plan,
	tree: Tree,
	sc: Scratch,
	nseg: number,
	L: number,
	X0: number,
	X1: number,
	eps: number,
	mode: number,
	out: buffer,
	rowAt: number,
	out2: buffer?,
	wgt: number,
	xEnd: number
)
	local N, M, K = plan.N, plan.M, plan.K
	local model = plan.model
	local Cf, Cb, d = model.Cf, model.Cb, model.d
	local Csum, pw, S1, NT, G = plan.Csum, plan.pw, plan.S1, plan.NT, plan.G
	local pwOff, clsOf, clsK, nClsT = plan.pwOff, plan.clsOf, plan.clsK, plan.nCls
	local TP1, T = plan.TP1, plan.T
	local sx, sl, sleaf, sdep, sb, seb = sc.sx, sc.sl, sc.sleaf, sc.sdep, sc.sb, sc.seb
	local h, ef = sc.h, sc.ef
	local zinf, tau, Qf, Qb = sc.zinf, sc.tau, sc.Qf, sc.Qb
	local fOff, fQ, fDrop, bOff, bQ, bDrop = sc.fOff, sc.fQ, sc.fDrop, sc.bOff, sc.bQ, sc.bDrop
	local wfA, wbA = sc.wf, sc.wb
	local z, pend, acc = sc.z, sc.pend, sc.acc
	local stats = sc.stats
	local F = 2 ^ L
	local GL = L * K
	local JW = JMAX + 1
	local hasEps = eps > 0
	local invEps = if hasEps then 1 / eps else 0

	-- emits one output pixel from z[1..M]
	local function emit(X: number)
		if mode == 0 then
			local at = rowAt + (X - X0) * 4
			buffer.writeu32(out, at, packZ(z, M, 0))
			if out2 and M > 4 then
				buffer.writeu32(out2, at, packZ(z, M, 4))
			end
		else
			local a = (X - X0) * M
			for m = 1, M do
				acc[a + m] += wgt * z[m]
			end
		end
	end

	-- 1. targets
	for s = 1, nseg do
		leafTargets(plan, tree, sleaf[s], sb, (s - 1) * N)
	end

	-- 2. backward sweep (closed-form jumps), at rest at the right end
	local last = (nseg - 1) * N
	for i = 1, N do
		h[i] = sb[last + i]
	end
	for s = nseg, 1, -1 do
		local base = (s - 1) * N
		local po = sdep[s] * N
		local len = sl[s]
		for i = 1, N do
			local b = sb[base + i]
			local e = h[i] - b
			seb[base + i] = e
			h[i] = b + e * pw[pwOff[po + i] + len]
		end
	end

	-- 3. forward sweep and output
	for i = 1, N do
		h[i] = sb[i]
	end
	local pendX, pendCnt = NONE, 0
	local xFirst, xLast = X0 * F, X1 * F
	for s = 1, nseg do
		local x0 = sx[s]
		if x0 >= xLast then
			break
		end
		local len = sl[s]
		local x1 = x0 + len
		local base = (s - 1) * N
		local dep = sdep[s]
		local po = dep * N
		for i = 1, N do
			ef[i] = h[i] - sb[base + i]
		end
		if x1 > xFirst then
			stats.segments += 1
			-- limit colour and class amplitudes
			for m = 0, M - 1 do
				local zz = d[m + 1]
				local cm = m * N
				for i = 1, N do
					zz = zz + Csum[cm + i] * sb[base + i]
				end
				zinf[m + 1] = zz
			end
			local nc = nClsT[dep + 1]
			local cK = dep * K
			for j = 1, nc * M do
				Qf[j] = 0
				Qb[j] = 0
			end
			for i = 1, N do
				local c = clsOf[po + i]
				if c > 0 then
					local e1, e2 = ef[i], seb[base + i]
					local qo = (c - 1) * M
					for m = 0, M - 1 do
						Qf[qo + m + 1] += Cf[m * N + i] * e1
						Qb[qo + m + 1] += Cb[m * N + i] * e2
					end
				end
			end

			local xe = if x1 < xEnd then x1 else xEnd
			local Xfirst = x0 // F
			local Xlast = (xe - 1) // F
			local Xfa = if x0 % F == 0 then Xfirst else Xfirst + 1
			local Xfb = if (Xlast + 1) * F <= xe then Xlast else Xlast - 1

			-- partial footprints: exact sums, accumulated across segments
			for pass = 1, 2 do
				local X: number, p0: number, p1: number = NONE, 0, 0
				if pass == 1 and Xfirst < Xfa then
					local e1 = (Xfirst + 1) * F
					X, p0, p1 = Xfirst, x0, if xe < e1 then xe else e1
				elseif pass == 2 and Xlast > Xfb and (Xlast ~= Xfirst or Xfirst >= Xfa) then
					local s2 = Xlast * F
					X, p0, p1 = Xlast, if x0 > s2 then x0 else s2, xe
				end
				if X >= X0 and X < X1 then
					stats.pieces += 1
					if pendX ~= X then
						if pendX ~= NONE then
							for m = 1, M do
								z[m] = pend[m] / pendCnt
							end
							emit(pendX)
						end
						pendX, pendCnt = X, 0
						for m = 1, M do
							pend[m] = 0
						end
					end
					local cnt = p1 - p0
					local nf1 = p0 - x0 + 1
					local nb1 = x1 - p1 + 1
					for m = 1, M do
						pend[m] += cnt * zinf[m]
					end
					for c = 1, nc do
						local off = clsK[cK + c] * TP1 + 1
						local sfac = S1[off + cnt]
						local pf = pw[off + nf1] * sfac
						local pb = pw[off + nb1] * sfac
						local qo = (c - 1) * M
						for m = 1, M do
							pend[m] += Qf[qo + m] * pf + Qb[qo + m] * pb
						end
					end
					pendCnt += cnt
					local full = (if (X + 1) * F < xEnd then (X + 1) * F else xEnd) - X * F
					if pendCnt == full then
						for m = 1, M do
							z[m] = pend[m] / pendCnt
						end
						emit(pendX)
						pendX = NONE
					end
				end
			end

			-- full footprints
			if Xfa <= Xfb and Xfb >= X0 and Xfa < X1 then
				local nf0 = Xfa * F - x0 + 1
				local nb0 = x1 - Xfa * F - F + 1
				-- thresholds (the quantisation margin only counts when the value is quantised
				-- right away, mode 0; accumulated values keep the plain eps bound)
				local noFill = false
				for m = 1, M do
					local t = if mode == 0 then margin(zinf[m]) - ETA else eps
					if t < eps then
						t = eps
					end
					if t <= 0 then
						noFill = true
						t = 1
					end
					tau[m] = 1 / t
				end
				-- scaled amplitudes and normalised weights
				local Wf, Wb = 0, 0
				local kmaxF, kmaxB = 0, 0
				for c = 1, nc do
					local k = clsK[cK + c]
					local gfac = G[GL + k + 1]
					local qo = (c - 1) * M
					local wf, wb = 0, 0
					for m = 1, M do
						local qf = Qf[qo + m] * gfac
						local qb = Qb[qo + m] * gfac
						Qf[qo + m] = qf
						Qb[qo + m] = qb
						local af = math.abs(qf) * tau[m]
						local ab = math.abs(qb) * tau[m]
						if af > wf then
							wf = af
						end
						if ab > wb then
							wb = ab
						end
					end
					wfA[c], wbA[c] = wf, wb
					if wf > 0 then
						Wf += wf
						kmaxF = k
					end
					if wb > 0 then
						Wb += wb
						kmaxB = k
					end
				end
				local hF = (if Wb == 0 then 1 else 0.5) * SHRINK
				local hB = (if Wf == 0 then 1 else 0.5) * SHRINK

				-- forward fill start: first X with sum_c wf_c a_c^nf(X) <= hF
				local X1f, X2b
				if noFill then
					X1f, X2b = Xfb + 1, Xfa - 1
				else
					if Wf == 0 then
						X1f = Xfa
					else
						local nHi = NT[kmaxF * JW + ceilLog2(Wf / hF) + 1]
						local hi = Xfb + 1
						if nHi <= T then
							local c = if nHi > nf0 then Xfa + (nHi - nf0 + F - 1) // F else Xfa
							if c < hi then
								hi = c
							end
						end
						local lo = Xfa - 1
						-- galloping: probe lo + 1, lo + 2, lo + 4, ...
						local step = 1
						while lo + step < hi do
							local X = lo + step
							local nfX = nf0 + (X - Xfa) * F
							local r = 0
							for c = 1, nc do
								r += wfA[c] * pw[clsK[cK + c] * TP1 + 1 + nfX]
							end
							stats.searchProbes += 1
							if r <= hF then
								hi = X
								break
							end
							lo = X
							step *= 2
						end
						while hi - lo > 1 do
							local X = (lo + hi) // 2
							local nfX = nf0 + (X - Xfa) * F
							local r = 0
							for c = 1, nc do
								r += wfA[c] * pw[clsK[cK + c] * TP1 + 1 + nfX]
							end
							stats.searchProbes += 1
							if r <= hF then
								hi = X
							else
								lo = X
							end
						end
						X1f = hi
					end
					-- backward fill end: last X with sum_c wb_c a_c^nb(X) <= hB
					if Wb == 0 then
						X2b = Xfb
					else
						local nHi = NT[kmaxB * JW + ceilLog2(Wb / hB) + 1]
						local lo = Xfa - 1
						if nHi <= T then
							if nHi <= nb0 then
								local c = Xfa + (nb0 - nHi) // F
								if c > lo then
									lo = c
								end
							end
						end
						if lo > Xfb then
							lo = Xfb
						end
						local hi = Xfb + 1
						local step = 1
						while hi - step > lo do
							local X = hi - step
							local nbX = nb0 - (X - Xfa) * F
							local r = 0
							for c = 1, nc do
								r += wbA[c] * pw[clsK[cK + c] * TP1 + 1 + nbX]
							end
							stats.searchProbes += 1
							if r <= hB then
								lo = X
								break
							end
							hi = X
							step *= 2
						end
						while hi - lo > 1 do
							local X = (lo + hi) // 2
							local nbX = nb0 - (X - Xfa) * F
							local r = 0
							for c = 1, nc do
								r += wbA[c] * pw[clsK[cK + c] * TP1 + 1 + nbX]
							end
							stats.searchProbes += 1
							if r <= hB then
								lo = X
							else
								hi = X
							end
						end
						X2b = lo
					end
				end

				-- fill
				local tEnd1, tStart2
				if X1f <= X2b then
					local fa = if X1f > X0 then X1f else X0
					local fb = if X2b < X1 - 1 then X2b else X1 - 1
					if fa <= fb then
						stats.fills += 1
						stats.fillPixels += fb - fa + 1
						if mode == 0 then
							for m = 1, M do
								z[m] = zinf[m]
							end
							local col = packZ(z, M, 0)
							fillSpan(out, rowAt + (fa - X0) * 4, fb - fa + 1, col)
							if out2 and M > 4 then
								fillSpan(out2, rowAt + (fa - X0) * 4, fb - fa + 1, packZ(z, M, 4))
							end
						else
							for X = fa, fb do
								local a = (X - X0) * M
								for m = 1, M do
									acc[a + m] += wgt * zinf[m]
								end
							end
						end
					end
					tEnd1, tStart2 = X1f - 1, X2b + 1
				else
					tEnd1, tStart2 = Xfb, Xfb + 1
				end

				-- transients: closed-form evaluation with the decaying active set (T4)
				local ta = if Xfa > X0 then Xfa else X0
				local tb = if Xfb < X1 - 1 then Xfb else X1 - 1
				if ta <= tb and (ta <= tEnd1 or tb >= tStart2) then
					local nF, nB = 0, 0
					local cntF0, cntB0 = 0, 0
					for c = 1, nc do
						if wfA[c] > 0 then
							cntF0 += 1
						end
						if wbA[c] > 0 then
							cntB0 += 1
						end
					end
					local shF = (if cntB0 == 0 then 1 else 0.5) * SHRINK / math.max(cntF0, 1)
					local shB = (if cntF0 == 0 then 1 else 0.5) * SHRINK / math.max(cntB0, 1)
					for c = 1, nc do
						local k = clsK[cK + c]
						local off = k * TP1 + 1
						local qo = (c - 1) * M
						if wfA[c] > 0 then
							local key = math.huge
							if hasEps then
								local om = 0
								for m = 1, M do
									local v = math.abs(Qf[qo + m])
									if v > om then
										om = v
									end
								end
								local nStar = NT[k * JW + ceilLog2(om * invEps / shF) + 1]
								if nStar <= T then
									key = if nStar > nf0 then Xfa + (nStar - nf0 + F - 1) // F else Xfa
								end
							end
							nF = insertSorted(fOff, fQ, fDrop, nF, M, off, Qf, qo, key, true)
						end
						if wbA[c] > 0 then
							local key = -math.huge
							if hasEps then
								local om = 0
								for m = 1, M do
									local v = math.abs(Qb[qo + m])
									if v > om then
										om = v
									end
								end
								local nStar = NT[k * JW + ceilLog2(om * invEps / shB) + 1]
								if nStar <= T then
									-- negligible while nb(X) >= nStar, i.e. X <= Xfa + (nb0 - nStar) // F
									key = if nStar <= nb0 then Xfa + (nb0 - nStar) // F else Xfa - 1
								end
							end
							nB = insertSorted(bOff, bQ, bDrop, nB, M, off, Qb, qo, key, false)
						end
					end
					local cntF, cntB = nF, 0
					local X = ta
					while X <= tb do
						if X > tEnd1 and X < tStart2 then
							X = tStart2
							if X > tb then
								break
							end
						end
						while cntF > 0 and fDrop[cntF] <= X do
							cntF -= 1
						end
						while cntB < nB and bDrop[cntB + 1] < X do
							cntB += 1
						end
						local nfX = nf0 + (X - Xfa) * F
						local nbX = nb0 - (X - Xfa) * F
						for m = 1, M do
							z[m] = zinf[m]
						end
						for j = 1, cntF do
							local p = pw[fOff[j] + nfX]
							local qo = (j - 1) * M
							for m = 1, M do
								z[m] += fQ[qo + m] * p
							end
						end
						for j = 1, cntB do
							local p = pw[bOff[j] + nbX]
							local qo = (j - 1) * M
							for m = 1, M do
								z[m] += bQ[qo + m] * p
							end
						end
						stats.evals += 1
						emit(X)
						X += 1
					end
				end
			end
		end
		for i = 1, N do
			h[i] = sb[base + i] + ef[i] * pw[pwOff[po + i] + len]
		end
	end
	if pendX ~= NONE then
		for m = 1, M do
			z[m] = pend[m] / pendCnt
		end
		emit(pendX)
	end
end

----------------------------------------------------------------------------------------
-- Fast path for M <= 4 (channels padded to four locals). Same mathematics and bounds as
-- eventRow above; differences: always-instant neurons are not tracked (their state is b
-- exactly), per-content constants come from a cache, and the hot loops are inlined.
----------------------------------------------------------------------------------------

local CACHE_MAX_KEYS = 32768
local SHORT_LEN = 4 -- segments up to this length (level 0) skip the class machinery

-- Per-(plan, tree) cache of what depends only on a leaf's content: tracked targets b,
-- limit colour zinf (4 channels), quantisation margins and the packed fill colour.
local function ensureCache(plan: Plan, tree: Tree, sc: any): boolean
	if sc.cacheTree == tree then
		return sc.cacheOn
	end
	sc.cacheTree = tree
	local on = tree.keyCount <= CACHE_MAX_KEYS
	sc.cacheOn = on
	local nk = if on then tree.keyCount else 0
	sc.keyB = table.create(nk * math.max(plan.nt, 1), 0)
	sc.keyZ = table.create(nk * 4, 0)
	sc.keyMg = table.create(nk * 4, 0)
	sc.keyCol = table.create(nk, 0)
	sc.keyOk = table.create(nk, false)
	return on
end

local function fillSlot(plan: Plan, tree: Tree, sc: any, leaf: number, slot: number, Bt: { number }, Zt: { number }, MGt: { number }, COLt: { number })
	local tmp = sc.tmpB
	leafTargets(plan, tree, leaf, tmp, 0)
	local nt, trk = plan.nt, plan.trk
	for j = 1, nt do
		Bt[slot * nt + j] = tmp[trk[j]]
	end
	local M, N = plan.M, plan.N
	local Csum, d = plan.Csum, plan.model.d
	local q = { 0, 0, 0, 255 }
	for m = 1, 4 do
		if m <= M then
			local z = d[m]
			local cm = (m - 1) * N
			for i = 1, N do
				z = z + Csum[cm + i] * tmp[i]
			end
			Zt[slot * 4 + m] = z
			MGt[slot * 4 + m] = margin(z)
			q[m] = quant(z)
		else
			Zt[slot * 4 + m] = 0
			MGt[slot * 4 + m] = math.huge
		end
	end
	COLt[slot + 1] = q[1] + q[2] * 256 + q[3] * 65536 + q[4] * 16777216
end

local function eventRow4(
	plan: Plan,
	tree: Tree,
	sc: any,
	nseg: number,
	L: number,
	X0: number,
	X1: number,
	eps: number,
	mode: number,
	out: buffer,
	rowAt: number,
	wgt: number,
	xEnd: number
)
	local M, K, nt = plan.M, plan.K, plan.nt
	local pw, S1, NT, G = plan.pw, plan.S1, plan.NT, plan.G
	local trkOff, trkCls, CfT4, CbT4 = plan.trkOff, plan.trkCls, plan.CfT4, plan.CbT4
	local clsK, nClsT = plan.clsK, plan.nCls
	local TP1, T = plan.TP1, plan.T
	local sx, sl, sleaf, sdep, skey = sc.sx, sc.sl, sc.sleaf, sc.sdep, sc.skey
	local slotOf, h, ef, seb = sc.slot, sc.h, sc.ef, sc.seb
	local Qf, Qb = sc.Qf, sc.Qb
	local fOff, fQ, fW, fThr = sc.fOff, sc.fQ, sc.fW, sc.fThr
	local bOff, bQ, bW, bThr = sc.bOff, sc.bQ, sc.bW, sc.bThr
	local aOff, aQ, aThr = sc.aOff, sc.aQ, sc.aThr
	local oOff, oQ = sc.oOff, sc.oQ
	local acc = sc.acc
	local stats = sc.stats
	local hasA = M >= 4
	local F = 2 ^ L
	local GL = L * K
	local JW = JMAX + 1
	local nEval, nFill, nFillPx, nProbe, nSeg, nPiece = 0, 0, 0, 0, 0, 0

	-- 0. per-content constants
	local cacheOn = ensureCache(plan, tree, sc)
	local Bt, Zt, MGt, COLt
	if cacheOn then
		Bt, Zt, MGt, COLt = sc.keyB, sc.keyZ, sc.keyMg, sc.keyCol
		local ok = sc.keyOk
		for s = 1, nseg do
			local key = skey[s]
			if not ok[key + 1] then
				fillSlot(plan, tree, sc, sleaf[s], key, Bt, Zt, MGt, COLt)
				ok[key + 1] = true
			end
			slotOf[s] = key
		end
	else
		Bt, Zt, MGt, COLt = sc.rowB, sc.rowZ, sc.rowMg, sc.rowCol
		for s = 1, nseg do
			fillSlot(plan, tree, sc, sleaf[s], s - 1, Bt, Zt, MGt, COLt)
			slotOf[s] = s - 1
		end
	end

	-- 1. backward sweep over tracked neurons (closed-form jumps), at rest at the right end
	do
		local bo = slotOf[nseg] * nt
		for j = 1, nt do
			h[j] = Bt[bo + j]
		end
	end
	for s = nseg, 1, -1 do
		local bo = slotOf[s] * nt
		local to = sdep[s] * nt
		local len = sl[s]
		local eo = (s - 1) * nt
		for j = 1, nt do
			local b = Bt[bo + j]
			local e = h[j] - b
			seb[eo + j] = e
			h[j] = b + e * pw[trkOff[to + j] + len]
		end
	end

	-- writes or accumulates one output pixel (pieces only; hot loops inline this)
	local function put(X: number, z0: number, z1: number, z2: number, z3: number)
		if mode == 0 then
			local q0 = floor(z0 + 0.5)
			if q0 < 0 then
				q0 = 0
			elseif q0 > 255 then
				q0 = 255
			end
			local q1 = floor(z1 + 0.5)
			if q1 < 0 then
				q1 = 0
			elseif q1 > 255 then
				q1 = 255
			end
			local q2 = floor(z2 + 0.5)
			if q2 < 0 then
				q2 = 0
			elseif q2 > 255 then
				q2 = 255
			end
			local q3 = 255
			if hasA then
				q3 = floor(z3 + 0.5)
				if q3 < 0 then
					q3 = 0
				elseif q3 > 255 then
					q3 = 255
				end
			end
			buffer.writeu32(out, rowAt + (X - X0) * 4, q0 + q1 * 256 + q2 * 65536 + q3 * 16777216)
		else
			local a = (X - X0) * 4
			acc[a + 1] += wgt * z0
			acc[a + 2] += wgt * z1
			acc[a + 3] += wgt * z2
			acc[a + 4] += wgt * z3
		end
	end

	-- one fill span [fa, fb] of the limit colour (mode 0) or the limit value (mode 1)
	local function fillRun(fa: number, fb: number, col: number, zi0: number, zi1: number, zi2: number, zi3: number)
		local cnt = fb - fa + 1
		if mode == 0 then
			local at = rowAt + (fa - X0) * 4
			buffer.writeu32(out, at, col)
			if cnt < 8 then
				for q = 1, cnt - 1 do
					buffer.writeu32(out, at + q * 4, col)
				end
			else
				local bytes = cnt * 4
				local filled = 4
				while filled < bytes do
					local n = if filled < bytes - filled then filled else bytes - filled
					buffer.copy(out, at + filled, out, at, n)
					filled += n
				end
			end
		else
			for X = fa, fb do
				local a = (X - X0) * 4
				acc[a + 1] += wgt * zi0
				acc[a + 2] += wgt * zi1
				acc[a + 3] += wgt * zi2
				acc[a + 4] += wgt * zi3
			end
		end
	end

	-- Walks cnt output pixels from Xs in steps of dX. The lazy list (aOff, aQ, aThr; na
	-- terms, slowest first) holds the direction whose powers shrink along the walk; a term
	-- whose power is at or below its threshold is skipped (T4). The decision depends only on
	-- the pixel, never on where the walk started, and the summation order is fixed, so a
	-- region render equals the same crop of a full render bit for bit. Trailing skipped
	-- terms are trimmed for good (powers only shrink along the walk). The other list (oOff,
	-- oQ; no terms) is fixed. nl and nOther are the two step indices at Xs; nl grows by F
	-- per pixel and nOther shrinks by F.
	local function walk(Xs: number, cnt: number, dX: number, na: number, nl: number, no: number, nOther: number, zi0: number, zi1: number, zi2: number, zi3: number)
		local X = Xs
		for _ = 1, cnt do
			while na > 0 and pw[aOff[na] + nl] <= aThr[na] do
				na -= 1
			end
			local z0, z1, z2, z3 = zi0, zi1, zi2, zi3
			for j = 1, na do
				local p = pw[aOff[j] + nl]
				if p > aThr[j] then
					local a = (j - 1) * 4
					z0 += aQ[a + 1] * p
					z1 += aQ[a + 2] * p
					z2 += aQ[a + 3] * p
					z3 += aQ[a + 4] * p
				end
			end
			for j2 = 1, no do
				local p = pw[oOff[j2] + nOther]
				local a = (j2 - 1) * 4
				z0 += oQ[a + 1] * p
				z1 += oQ[a + 2] * p
				z2 += oQ[a + 3] * p
				z3 += oQ[a + 4] * p
			end
			if mode == 0 then
				local q0 = floor(z0 + 0.5)
				if q0 < 0 then
					q0 = 0
				elseif q0 > 255 then
					q0 = 255
				end
				local q1 = floor(z1 + 0.5)
				if q1 < 0 then
					q1 = 0
				elseif q1 > 255 then
					q1 = 255
				end
				local q2 = floor(z2 + 0.5)
				if q2 < 0 then
					q2 = 0
				elseif q2 > 255 then
					q2 = 255
				end
				local q3 = 255
				if hasA then
					q3 = floor(z3 + 0.5)
					if q3 < 0 then
						q3 = 0
					elseif q3 > 255 then
						q3 = 255
					end
				end
				buffer.writeu32(out, rowAt + (X - X0) * 4, q0 + q1 * 256 + q2 * 65536 + q3 * 16777216)
			else
				local a = (X - X0) * 4
				acc[a + 1] += wgt * z0
				acc[a + 2] += wgt * z1
				acc[a + 3] += wgt * z2
				acc[a + 4] += wgt * z3
			end
			X += dX
			nl += F
			nOther -= F
		end
	end

	-- 2. forward sweep and output
	do
		local bo = slotOf[1] * nt
		for j = 1, nt do
			h[j] = Bt[bo + j]
		end
	end
	local pendX, pendCnt = NONE, 0
	local p0s, p1s, p2s, p3s = 0, 0, 0, 0
	local xFirst, xLast = X0 * F, X1 * F
	for s = 1, nseg do
		local x0 = sx[s]
		if x0 >= xLast then
			break
		end
		local len = sl[s]
		local x1 = x0 + len
		local slot = slotOf[s]
		local bo = slot * nt
		local dep = sdep[s]
		local to = dep * nt
		local eo = (s - 1) * nt
		for j = 1, nt do
			ef[j] = h[j] - Bt[bo + j]
		end
		if x1 > xFirst then
			nSeg += 1
			local zo = slot * 4
			local zi0, zi1, zi2, zi3 = Zt[zo + 1], Zt[zo + 2], Zt[zo + 3], Zt[zo + 4]
			if F == 1 and nClsT[dep + 1] == 0 then
				-- every neuron is instant in this leaf: the segment is exactly its limit colour
				local fa = if x0 > X0 then x0 else X0
				local fb = if x1 < X1 then x1 - 1 else X1 - 1
				if fa <= fb then
					nFill += 1
					nFillPx += fb - fa + 1
					fillRun(fa, fb, COLt[slot + 1], zi0, zi1, zi2, zi3)
				end
			elseif F == 1 and len <= SHORT_LEN then
				-- short segment at level 0: every pixel straight from the tracked states
				local xa = if x0 > X0 then x0 else X0
				local xb = if x1 < X1 then x1 - 1 else X1 - 1
				for X = xa, xb do
					local nf = X - x0 + 1
					local nb = x1 - X
					local z0, z1, z2, z3 = zi0, zi1, zi2, zi3
					for j = 1, nt do
						if trkCls[to + j] > 0 then
							local off = trkOff[to + j]
							local pf = ef[j] * pw[off + nf]
							local pb = seb[eo + j] * pw[off + nb]
							local co = (j - 1) * 4
							z0 += CfT4[co + 1] * pf + CbT4[co + 1] * pb
							z1 += CfT4[co + 2] * pf + CbT4[co + 2] * pb
							z2 += CfT4[co + 3] * pf + CbT4[co + 3] * pb
							z3 += CfT4[co + 4] * pf + CbT4[co + 4] * pb
						end
					end
					if mode == 0 then
						local q0 = floor(z0 + 0.5)
						if q0 < 0 then
							q0 = 0
						elseif q0 > 255 then
							q0 = 255
						end
						local q1 = floor(z1 + 0.5)
						if q1 < 0 then
							q1 = 0
						elseif q1 > 255 then
							q1 = 255
						end
						local q2 = floor(z2 + 0.5)
						if q2 < 0 then
							q2 = 0
						elseif q2 > 255 then
							q2 = 255
						end
						local q3 = 255
						if hasA then
							q3 = floor(z3 + 0.5)
							if q3 < 0 then
								q3 = 0
							elseif q3 > 255 then
								q3 = 255
							end
						end
						buffer.writeu32(out, rowAt + (X - X0) * 4, q0 + q1 * 256 + q2 * 65536 + q3 * 16777216)
					else
						local a = (X - X0) * 4
						acc[a + 1] += wgt * z0
						acc[a + 2] += wgt * z1
						acc[a + 3] += wgt * z2
						acc[a + 4] += wgt * z3
					end
				end
				if xb >= xa then
					nEval += xb - xa + 1
				end
			else
				-- class amplitudes
				local nc = nClsT[dep + 1]
				local cK = dep * K
				for q = 1, nc * 4 do
					Qf[q] = 0
					Qb[q] = 0
				end
				for j = 1, nt do
					local c = trkCls[to + j]
					if c > 0 then
						local e1, e2 = ef[j], seb[eo + j]
						local qo = (c - 1) * 4
						local co = (j - 1) * 4
						Qf[qo + 1] += CfT4[co + 1] * e1
						Qf[qo + 2] += CfT4[co + 2] * e1
						Qf[qo + 3] += CfT4[co + 3] * e1
						Qf[qo + 4] += CfT4[co + 4] * e1
						Qb[qo + 1] += CbT4[co + 1] * e2
						Qb[qo + 2] += CbT4[co + 2] * e2
						Qb[qo + 3] += CbT4[co + 3] * e2
						Qb[qo + 4] += CbT4[co + 4] * e2
					end
				end

				local xe = if x1 < xEnd then x1 else xEnd
				local Xfirst = x0 // F
				local Xlast = (xe - 1) // F
				local Xfa = if x0 % F == 0 then Xfirst else Xfirst + 1
				local Xfb = if (Xlast + 1) * F <= xe then Xlast else Xlast - 1

				-- partial footprints (F > 1): exact sums, accumulated across segments
				if F > 1 then
					for pass = 1, 2 do
						local X: number, pa: number, pb: number = NONE, 0, 0
						if pass == 1 and Xfirst < Xfa then
							local e1 = (Xfirst + 1) * F
							X, pa, pb = Xfirst, x0, if xe < e1 then xe else e1
						elseif pass == 2 and Xlast > Xfb and (Xlast ~= Xfirst or Xfirst >= Xfa) then
							local s2 = Xlast * F
							X, pa, pb = Xlast, if x0 > s2 then x0 else s2, xe
						end
						if X >= X0 and X < X1 then
							nPiece += 1
							if pendX ~= X then
								if pendX ~= NONE then
									put(pendX, p0s / pendCnt, p1s / pendCnt, p2s / pendCnt, p3s / pendCnt)
								end
								pendX, pendCnt = X, 0
								p0s, p1s, p2s, p3s = 0, 0, 0, 0
							end
							local cnt = pb - pa
							local nf1 = pa - x0 + 1
							local nb1 = x1 - pb + 1
							p0s += cnt * zi0
							p1s += cnt * zi1
							p2s += cnt * zi2
							p3s += cnt * zi3
							for c = 1, nc do
								local off = clsK[cK + c] * TP1 + 1
								local sfac = S1[off + cnt]
								local pf = pw[off + nf1] * sfac
								local pbk = pw[off + nb1] * sfac
								local qo = (c - 1) * 4
								p0s += Qf[qo + 1] * pf + Qb[qo + 1] * pbk
								p1s += Qf[qo + 2] * pf + Qb[qo + 2] * pbk
								p2s += Qf[qo + 3] * pf + Qb[qo + 3] * pbk
								p3s += Qf[qo + 4] * pf + Qb[qo + 4] * pbk
							end
							pendCnt += cnt
							local fe = (X + 1) * F
							local full = (if fe < xEnd then fe else xEnd) - X * F
							if pendCnt == full then
								put(pendX, p0s / pendCnt, p1s / pendCnt, p2s / pendCnt, p3s / pendCnt)
								pendX = NONE
							end
						end
					end
				end

				-- full footprints
				if Xfa <= Xfb and Xfb >= X0 and Xfa < X1 then
					local nf0 = Xfa * F - x0 + 1
					local nb0 = x1 - Xfa * F - F + 1
					-- fill thresholds: quantisation margin (mode 0) or eps
					local t0, t1, t2, t3
					if mode == 0 then
						t0, t1, t2, t3 = MGt[zo + 1] - ETA, MGt[zo + 2] - ETA, MGt[zo + 3] - ETA, MGt[zo + 4] - ETA
						if t0 < eps then
							t0 = eps
						end
						if t1 < eps then
							t1 = eps
						end
						if t2 < eps then
							t2 = eps
						end
						if t3 < eps then
							t3 = eps
						end
					else
						t0, t1, t2, t3 = eps, eps, eps, eps
					end
					local noFill = t0 <= 0 or t1 <= 0 or t2 <= 0 or t3 <= 0
					if noFill then
						t0, t1, t2, t3 = 1, 1, 1, 1
					end
					local i0, i1, i2, i3 = 1 / t0, 1 / t1, 1 / t2, 1 / t3
					-- compact term lists: weight normalised by tau (fill), max |Q| (drops)
					local nF, nB = 0, 0
					local Wf, Wb = 0, 0
					local kmaxF, kmaxB = 0, 0
					for c = 1, nc do
						local k = clsK[cK + c]
						local off = k * TP1 + 1
						local qo = (c - 1) * 4
						local q0, q1, q2, q3 = Qf[qo + 1], Qf[qo + 2], Qf[qo + 3], Qf[qo + 4]
						local r0, r1, r2, r3 = Qb[qo + 1], Qb[qo + 2], Qb[qo + 3], Qb[qo + 4]
						if L > 0 then
							local gfac = G[GL + k + 1]
							q0, q1, q2, q3 = q0 * gfac, q1 * gfac, q2 * gfac, q3 * gfac
							r0, r1, r2, r3 = r0 * gfac, r1 * gfac, r2 * gfac, r3 * gfac
						end
						local a0 = if q0 < 0 then -q0 else q0
						local a1 = if q1 < 0 then -q1 else q1
						local a2 = if q2 < 0 then -q2 else q2
						local a3 = if q3 < 0 then -q3 else q3
						local w = a0 * i0
						local v = a1 * i1
						if v > w then
							w = v
						end
						v = a2 * i2
						if v > w then
							w = v
						end
						v = a3 * i3
						if v > w then
							w = v
						end
						if w > 0 then
							nF += 1
							fOff[nF] = off
							fW[nF] = w
							local om = if a0 > a1 then a0 else a1
							if a2 > om then
								om = a2
							end
							if a3 > om then
								om = a3
							end
							fThr[nF] = om
							local a = (nF - 1) * 4
							fQ[a + 1], fQ[a + 2], fQ[a + 3], fQ[a + 4] = q0, q1, q2, q3
							Wf += w
							kmaxF = k
						end
						a0 = if r0 < 0 then -r0 else r0
						a1 = if r1 < 0 then -r1 else r1
						a2 = if r2 < 0 then -r2 else r2
						a3 = if r3 < 0 then -r3 else r3
						w = a0 * i0
						v = a1 * i1
						if v > w then
							w = v
						end
						v = a2 * i2
						if v > w then
							w = v
						end
						v = a3 * i3
						if v > w then
							w = v
						end
						if w > 0 then
							nB += 1
							bOff[nB] = off
							bW[nB] = w
							local om = if a0 > a1 then a0 else a1
							if a2 > om then
								om = a2
							end
							if a3 > om then
								om = a3
							end
							bThr[nB] = om
							local a = (nB - 1) * 4
							bQ[a + 1], bQ[a + 2], bQ[a + 3], bQ[a + 4] = r0, r1, r2, r3
							Wb += w
							kmaxB = k
						end
					end
					local hF = (if nB == 0 then 1 else 0.5) * SHRINK
					local hB = (if nF == 0 then 1 else 0.5) * SHRINK

					local X1f, X2b
					if noFill then
						X1f, X2b = Xfb + 1, Xfa - 1
					else
						-- forward fill start: probe Xfa, else T3 cap, galloping, bisection
						local r = 0
						for j = 1, nF do
							r += fW[j] * pw[fOff[j] + nf0]
						end
						if nF > 0 then
							nProbe += 1
						end
						if r <= hF then
							X1f = Xfa
						else
							local hi = Xfb + 1
							local nHi = NT[kmaxF * JW + ceilLog2(Wf / hF) + 1]
							if nHi <= T then
								local c = if nHi > nf0 then Xfa + (nHi - nf0 + F - 1) // F else Xfa
								if c < hi then
									hi = c
								end
							end
							local lo = Xfa
							local step = 1
							while lo + step < hi do
								local X = lo + step
								local nfX = nf0 + (X - Xfa) * F
								r = 0
								for j = 1, nF do
									r += fW[j] * pw[fOff[j] + nfX]
								end
								nProbe += 1
								if r <= hF then
									hi = X
									break
								end
								lo = X
								step *= 2
							end
							while hi - lo > 1 do
								local X = (lo + hi) // 2
								local nfX = nf0 + (X - Xfa) * F
								r = 0
								for j = 1, nF do
									r += fW[j] * pw[fOff[j] + nfX]
								end
								nProbe += 1
								if r <= hF then
									hi = X
								else
									lo = X
								end
							end
							X1f = hi
						end
						-- backward fill end: probe Xfb, else T3 cap, galloping, bisection
						local nbE = nb0 - (Xfb - Xfa) * F
						r = 0
						for j = 1, nB do
							r += bW[j] * pw[bOff[j] + nbE]
						end
						if nB > 0 then
							nProbe += 1
						end
						if r <= hB then
							X2b = Xfb
						else
							local lo = Xfa - 1
							local nHi = NT[kmaxB * JW + ceilLog2(Wb / hB) + 1]
							if nHi <= T and nHi <= nb0 then
								local c = Xfa + (nb0 - nHi) // F
								if c > lo then
									lo = c
								end
							end
							if lo > Xfb - 1 then
								lo = Xfb - 1
							end
							local hi = Xfb
							local step = 1
							while hi - step > lo do
								local X = hi - step
								local nbX = nb0 - (X - Xfa) * F
								r = 0
								for j = 1, nB do
									r += bW[j] * pw[bOff[j] + nbX]
								end
								nProbe += 1
								if r <= hB then
									lo = X
									break
								end
								hi = X
								step *= 2
							end
							while hi - lo > 1 do
								local X = (lo + hi) // 2
								local nbX = nb0 - (X - Xfa) * F
								r = 0
								for j = 1, nB do
									r += bW[j] * pw[bOff[j] + nbX]
								end
								nProbe += 1
								if r <= hB then
									lo = X
								else
									hi = X
								end
							end
							X2b = lo
						end
					end

					-- fill span (clipped to the output window): one writeu32, then buffer.copy
					-- doubling. Regions are defined on the unclipped footprint range.
					local la, lb, ra, rb
					if X1f <= X2b then
						local fa = if X1f > X0 then X1f else X0
						local fb = if X2b < X1 - 1 then X2b else X1 - 1
						if fa <= fb then
							nFill += 1
							nFillPx += fb - fa + 1
							fillRun(fa, fb, COLt[slot + 1], zi0, zi1, zi2, zi3)
						end
						la, lb, ra, rb = Xfa, X1f - 1, X2b + 1, Xfb
					else
						local mid = (Xfa + Xfb) // 2
						la, lb, ra, rb = Xfa, mid, mid + 1, Xfb
					end
					-- the parts inside the output window
					local wla = if la > X0 then la else X0
					local wlb = if lb < X1 - 1 then lb else X1 - 1
					local wra = if ra > X0 then ra else X0
					local wrb = if rb < X1 - 1 then rb else X1 - 1

					-- transients (T4: each skipped term stays below its share of eps)
					if wlb >= wla or wrb >= wra then
						local shF = eps * (if nB == 0 then 1 else 0.5) * SHRINK / (if nF > 0 then nF else 1)
						local shB = eps * (if nF == 0 then 1 else 0.5) * SHRINK / (if nB > 0 then nB else 1)
						for j = 1, nF do
							fThr[j] = shF / fThr[j] -- skip once a^n <= share / max|Q|
						end
						for j = 1, nB do
							bThr[j] = shB / bThr[j]
						end
						if wlb >= wla then
							-- left region, walked left to right: forward powers shrink
							for j = 1, nF do
								local d = nF + 1 - j -- slowest first, so fast terms trail
								aOff[d] = fOff[j]
								aThr[d] = fThr[j]
								local a, b = (d - 1) * 4, (j - 1) * 4
								aQ[a + 1], aQ[a + 2], aQ[a + 3], aQ[a + 4] = fQ[b + 1], fQ[b + 2], fQ[b + 3], fQ[b + 4]
							end
							local nbEnd = nb0 - (lb - Xfa) * F -- largest backward power in the region
							local no = 0
							for j = 1, nB do
								if pw[bOff[j] + nbEnd] > bThr[j] then
									no += 1
									oOff[no] = bOff[j]
									local a, b = (no - 1) * 4, (j - 1) * 4
									oQ[a + 1], oQ[a + 2], oQ[a + 3], oQ[a + 4] = bQ[b + 1], bQ[b + 2], bQ[b + 3], bQ[b + 4]
								end
							end
							walk(wla, wlb - wla + 1, 1, nF, nf0 + (wla - Xfa) * F, no, nb0 - (wla - Xfa) * F, zi0, zi1, zi2, zi3)
							nEval += wlb - wla + 1
						end
						if wrb >= wra then
							-- right region, walked right to left: backward powers shrink
							for j = 1, nB do
								local d = nB + 1 - j
								aOff[d] = bOff[j]
								aThr[d] = bThr[j]
								local a, b = (d - 1) * 4, (j - 1) * 4
								aQ[a + 1], aQ[a + 2], aQ[a + 3], aQ[a + 4] = bQ[b + 1], bQ[b + 2], bQ[b + 3], bQ[b + 4]
							end
							local nfStart = nf0 + (ra - Xfa) * F -- largest forward power in the region
							local no = 0
							for j = 1, nF do
								if pw[fOff[j] + nfStart] > fThr[j] then
									no += 1
									oOff[no] = fOff[j]
									local a, b = (no - 1) * 4, (j - 1) * 4
									oQ[a + 1], oQ[a + 2], oQ[a + 3], oQ[a + 4] = fQ[b + 1], fQ[b + 2], fQ[b + 3], fQ[b + 4]
								end
							end
							walk(wrb, wrb - wra + 1, -1, nB, nb0 - (wrb - Xfa) * F, no, nf0 + (wrb - Xfa) * F, zi0, zi1, zi2, zi3)
							nEval += wrb - wra + 1
						end
					end
				end
			end
		end
		for j = 1, nt do
			h[j] = Bt[bo + j] + ef[j] * pw[trkOff[to + j] + len]
		end
	end
	if pendX ~= NONE then
		put(pendX, p0s / pendCnt, p1s / pendCnt, p2s / pendCnt, p3s / pendCnt)
	end
	stats.segments += nSeg
	stats.evals += nEval
	stats.fills += nFill
	stats.fillPixels += nFillPx
	stats.searchProbes += nProbe
	stats.pieces += nPiece
end

----------------------------------------------------------------------------------------
-- Frame driver: bands, row deduplication, vertical strategies, targets
----------------------------------------------------------------------------------------

export type RenderOptions = {
	epsilon: number?, -- error budget per channel in output units (default 0.5); 0 = lossless
	level: number?, -- output level L >= 0: footprint 2^L rendered pixels (T5)
	x: number?, -- region in output pixels at this level (default: everything)
	y: number?,
	w: number?,
	h: number?,
	dx: number?, -- destination of the region's top-left pixel in `out` (default 0, 0)
	dy: number?,
	vertical: string?, -- "box" (default: exact 2D box filter), "point" (centre row), "rows"
	out2: buffer?, -- channels 4..7 when M > 4
	stats: Stats?,
	endless: Endless?, -- X3: render the endless virtual canvas (region may be anywhere)
}

-- Output size at a level: width ceil(Wr / 2^L); height ceil(Hr / 2^L), or Hr for "rows".
function Liquid.outputSize(plan: Plan, level: number?, vertical: string?): (number, number)
	local F = 2 ^ (level or 0)
	local w = (plan.Wr + F - 1) // F
	local h = if vertical == "rows" then plan.Hr else (plan.Hr + F - 1) // F
	return w, h
end

local function copyRow(out: buffer, out2: buffer?, M: number, dst: number, src: number, bytes: number)
	buffer.copy(out, dst, out, src, bytes)
	if out2 and M > 4 then
		buffer.copy(out2, dst, out2, src, bytes)
	end
end

-- Renders a region of the image at a level into an RGBA8 buffer whose rows are outWidth
-- pixels long. Returns the statistics (accumulated into opts.stats when given).
function Liquid.render(plan: Plan, tree: Tree, out: buffer, outWidth: number, opts: RenderOptions?): Stats
	local o: RenderOptions = opts or {}
	local eps = o.epsilon or 0.5
	assert(eps >= 0, "epsilon must be >= 0")
	local L = o.level or 0
	assert(L >= 0 and L % 1 == 0 and L <= plan.P + plan.R, "level out of range")
	local vertical = o.vertical or "box"
	assert(vertical == "box" or vertical == "point" or vertical == "rows", "vertical must be box, point or rows")
	local endless = o.endless
	local F = 2 ^ L
	local Wl, Hl = Liquid.outputSize(plan, L, vertical)
	local rx, ry = o.x or 0, o.y or 0
	local rw, rh = o.w or (Wl - rx), o.h or (Hl - ry)
	if not endless then
		if rx < 0 then
			rw += rx
			rx = 0
		end
		if ry < 0 then
			rh += ry
			ry = 0
		end
		if rx + rw > Wl then
			rw = Wl - rx
		end
		if ry + rh > Hl then
			rh = Hl - ry
		end
	end
	local stats = o.stats or newStats()
	if rw <= 0 or rh <= 0 then
		return stats
	end
	local dx, dy = o.dx or 0, o.dy or 0
	local out2 = o.out2
	local M = plan.M
	local Wr, Hr = plan.Wr, plan.Hr
	local fast = M <= 4
	local AS = if fast then 4 else M -- accumulator stride
	local horizon = if endless then endless.horizon or 2 else 0
	assert(horizon >= 1 or not endless, "endless horizon must be >= 1")
	local sc = getScratch(plan, if endless then (2 * horizon + 1) * plan.Sr + 2 else Wr + 2)
	sc.stats = stats
	assert(buffer.len(out) >= ((dy + rh - 1) * outWidth + dx + rw) * 4, "output buffer too small")

	-- Renders output columns [cx0, cx1) of output rows [ry, ry + rh). seg(y) segments
	-- rendered row y and returns (count, band end); xEnd clips the last footprint; rows at
	-- or beyond yLimit do not exist.
	local function column(cx0: number, cx1: number, seg: (number) -> (number, number), xEnd: number, yLimit: number)
		local colBytes = (cx1 - cx0) * 4
		local cw = cx1 - cx0
		local function rowAt(Y: number): number
			return ((dy + Y - ry) * outWidth + dx + cx0 - rx) * 4
		end
		local function row(n: number, mode: number, at: number, wgt: number)
			if fast then
				eventRow4(plan, tree, sc, n, L, cx0, cx1, eps, mode, out, at, wgt, xEnd)
			else
				eventRow(plan, tree, sc, n, L, cx0, cx1, eps, mode, out, at, out2, wgt, xEnd)
			end
		end
		if vertical == "rows" or L == 0 then
			local y = ry
			local yEndAll = ry + rh
			while y < yEndAll do
				local n, bandEnd = seg(y)
				local yEnd = if bandEnd < yEndAll then bandEnd else yEndAll
				row(n, 0, rowAt(y), 1)
				stats.rendered += 1
				stats.rows += 1
				local src = rowAt(y)
				for yy = y + 1, yEnd - 1 do
					copyRow(out, out2, M, rowAt(yy), src, colBytes)
					stats.copied += 1
					stats.rows += 1
				end
				y = yEnd
			end
		elseif vertical == "point" then
			local bandLo, bandHi = 0, -1
			for Y = ry, ry + rh - 1 do
				local ys = Y * F + F // 2
				if ys >= yLimit then
					ys = yLimit - 1
				end
				if Y > ry and ys >= bandLo and ys < bandHi then
					copyRow(out, out2, M, rowAt(Y), rowAt(Y - 1), colBytes)
					stats.copied += 1
				else
					local n, bandEnd = seg(ys)
					row(n, 0, rowAt(Y), 1)
					stats.rendered += 1
					bandLo, bandHi = ys, bandEnd
				end
				stats.rows += 1
			end
		else
			local acc = sc.acc
			local z = sc.z
			local prevEnd = -math.huge
			for Y = ry, ry + rh - 1 do
				local ya = Y * F
				local yb = if ya + F < yLimit then ya + F else yLimit
				stats.rows += 1
				if Y > ry and prevEnd >= yb then
					copyRow(out, out2, M, rowAt(Y), rowAt(Y - 1), colBytes)
					stats.copied += 1
					continue
				end
				local n, bandEnd = seg(ya)
				if bandEnd >= yb then
					row(n, 0, rowAt(Y), 1)
					stats.rendered += 1
					prevEnd = bandEnd
				else
					-- the footprint crosses band boundaries: exact weighted sum of the band rows
					prevEnd = -math.huge
					stats.multiBand += 1
					for j = 1, cw * AS do
						acc[j] = 0
					end
					local y = ya
					local inv = 1 / (yb - ya)
					while true do
						local e = if bandEnd < yb then bandEnd else yb
						row(n, 1, 0, (e - y) * inv)
						stats.rendered += 1
						y = e
						if y >= yb then
							break
						end
						n, bandEnd = seg(y)
					end
					local at = rowAt(Y)
					for X = 0, cw - 1 do
						local a = X * AS
						for m = 1, M do
							z[m] = acc[a + m]
						end
						buffer.writeu32(out, at + X * 4, packZ(z, M, 0))
						local o2 = out2
						if o2 and M > 4 then
							buffer.writeu32(o2, at + X * 4, packZ(z, M, 4))
						end
					end
				end
			end
		end
	end

	if endless then
		-- one column per block; its passes run over the canonical window of `horizon`
		-- blocks on each side, so a pixel never depends on the requested region (X3)
		local seed = endless.seed
		local Sr = plan.Sr
		local colW = Sr // F
		for beta = rx // colW, (rx + rw - 1) // colW do
			local cx0 = if beta * colW > rx then beta * colW else rx
			local cx1 = if (beta + 1) * colW < rx + rw then (beta + 1) * colW else rx + rw
			local wa, wb = (beta - horizon) * Sr, (beta + 1 + horizon) * Sr
			column(cx0, cx1, function(y: number): (number, number)
				local n, bandEnd = segmentEndless(plan, tree, sc, y, wa, wb, seed)
				if fast then
					local cert = windowCert(plan, tree, sc, n, beta * Sr, (beta + 1) * Sr)
					if cert > stats.seam then
						stats.seam = cert
					end
				end
				return n, bandEnd
			end, math.huge, math.huge)
		end
	else
		column(rx, rx + rw, function(y: number): (number, number)
			return segmentStored(plan, tree, sc, y, 0, Wr, 0)
		end, Wr, Hr)
	end
	return stats
end

-- Real values (no quantisation) of rendered row y at level L, horizontal footprints only:
-- dst[X * M + m + 1] for X in [0, ceil(Wr / 2^L)). Every value is within epsilon of the
-- exact model's footprint average (T2 and T4 without the rounding term).
function Liquid.renderRowValues(plan: Plan, tree: Tree, y: number, level: number, epsilon: number, dst: { number }, stats: Stats?): number
	local F = 2 ^ level
	local Wl = (plan.Wr + F - 1) // F
	local sc = getScratch(plan, plan.Wr + 2)
	sc.stats = stats or newStats()
	local n = segmentStored(plan, tree, sc, y, 0, plan.Wr, 0)
	local acc = sc.acc
	local M = plan.M
	local AS = if M <= 4 then 4 else M
	for j = 1, Wl * AS do
		acc[j] = 0
	end
	if M <= 4 then
		eventRow4(plan, tree, sc, n, level, 0, Wl, epsilon, 1, buffer.create(0), 0, 1, plan.Wr)
	else
		eventRow(plan, tree, sc, n, level, 0, Wl, epsilon, 1, buffer.create(0), 0, nil, 1, plan.Wr)
	end
	for X = 0, Wl - 1 do
		for m = 1, M do
			dst[X * M + m] = acc[X * AS + m]
		end
	end
	return Wl
end

-- Renders into a Canvas (src/Canvas.luau) and marks exactly the written rows dirty.
-- `canvas` needs fields buf and width and a markDirty(x, y, w, h) method.
function Liquid.renderCanvas(plan: Plan, tree: Tree, canvas: any, opts: RenderOptions?): Stats
	local o: RenderOptions = opts or {}
	local L = o.level or 0
	local vertical = o.vertical or "box"
	local Wl, Hl = Liquid.outputSize(plan, L, vertical)
	local rx, ry = o.x or 0, o.y or 0
	local rw, rh = o.w or (Wl - rx), o.h or (Hl - ry)
	local stats = Liquid.render(plan, tree, canvas.buf, canvas.width, o)
	local dx, dy = o.dx or 0, o.dy or 0
	if rx < 0 then
		dx -= rx
		rw += rx
		rx = 0
	end
	if ry < 0 then
		dy -= ry
		rh += ry
		ry = 0
	end
	rw = math.min(rw, Wl - rx)
	rh = math.min(rh, Hl - ry)
	if rw > 0 and rh > 0 then
		canvas:markDirty(dx, dy, rw, rh)
	end
	return stats
end

-- Reference frame at level 0: every pixel stepped (O(W * H * N)). Writes RGBA8 into `out`
-- (row stride outWidth pixels); channels 4..7 into out2 when M > 4. With fast = true the
-- leaf of each pixel comes from the row segments instead of a per-pixel tree walk (same
-- arithmetic, used by the benchmark as the honest per-pixel baseline).
-- With bands = true only the first row of every band is stepped and the others are copied
-- (rows of a band cross the same leaves, so they are identical): the per-pixel baseline
-- with the renderer's row deduplication, used to separate the two sources of speedup.
function Liquid.reference(plan: Plan, tree: Tree, out: buffer, outWidth: number, fast: boolean?, out2: buffer?, bands: boolean?)
	local W, H, M = plan.Wr, plan.Hr, plan.M
	local z = table.create(W * M, 0)
	local zp = table.create(M, 0)
	local leafFn: ((number, number) -> (number, number))? = nil
	local segLeaf = table.create(W, 0)
	local segDep = table.create(W, 0)
	if fast then
		leafFn = function(x: number, _y: number): (number, number)
			return segLeaf[x + 1], segDep[x + 1]
		end
	end
	local sc = getScratch(plan, W + 2)
	local y = 0
	while y < H do
		local bandEnd = y + 1
		if fast or bands then
			local n, be = segmentStored(plan, tree, sc, y, 0, W, 0)
			if bands then
				bandEnd = be
			end
			for s = 1, n do
				for x = sc.sx[s], sc.sx[s] + sc.sl[s] - 1 do
					segLeaf[x + 1] = sc.sleaf[s]
					segDep[x + 1] = sc.sdep[s]
				end
			end
		end
		Liquid.referenceRow(plan, tree, y, z, leafFn)
		local rowAt = y * outWidth * 4
		for x = 0, W - 1 do
			for m = 1, M do
				zp[m] = z[x * M + m]
			end
			buffer.writeu32(out, rowAt + x * 4, packZ(zp, M, 0))
			if out2 and M > 4 then
				buffer.writeu32(out2, rowAt + x * 4, packZ(zp, M, 4))
			end
		end
		for yy = y + 1, bandEnd - 1 do
			copyRow(out, out2, M, yy * outWidth * 4, rowAt, W * 4)
		end
		y = bandEnd
	end
end

return Liquid
