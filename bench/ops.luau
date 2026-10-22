--!native
--!optimize 2
-- universe-at-home :: bench/ops.luau
--
-- Portable micro-benchmark for every Luau op a CPU pixel pipeline depends on.
-- It runs unchanged in two places:
--
--   * the open-source Luau CLI
--       luau bench/ops.luau              (interpreter)
--       luau --codegen bench/ops.luau    (native code generation)
--   * Roblox (paste into a Script or LocalScript, or require it as a ModuleScript).
--     Server Scripts honour --!native. Client LocalScripts currently run in the
--     interpreter (Roblox documents native code generation for server scripts only).
--
-- The `--!optimize 2` line pins the live-game optimization level. Studio playtests
-- default to level 1, so without it Studio numbers understate live performance.
--
-- Output: one machine-readable line per measurement
--   RESULT <TAB> group <TAB> name <TAB> value <TAB> unit
-- tools/merge_bench.py turns several runs into a markdown table.

local clock = os.clock
local IS_ROBLOX = typeof(game) == "Instance"

local function yieldNow()
	if IS_ROBLOX then
		task.wait()
	end
end

local function emit(group: string, name: string, value: number, unit: string)
	print(string.format("RESULT\t%s\t%s\t%.3f\t%s", group, name, value, unit))
end

----------------------------------------------------------------------------------
-- Shared fixtures
----------------------------------------------------------------------------------

local N = 65536 -- iterations per pass for op benchmarks
local B = buffer.create(N * 8) -- 512 KiB, fits in L2 so we time ops not DRAM
for i = 0, N * 8 - 1 do
	buffer.writeu8(B, i, (i * 37 + 11) % 256)
end

local T = table.create(N, 0)
for i = 1, N do
	T[i] = i
end

local PAL = table.create(16, 0)
for i = 1, 16 do
	PAL[i] = 0xFF000000 + i * 0x00010203
end

local V1 = vector.create(1.25, 2.5, 3.75)
local V2 = vector.create(-4, 8, 0.5)
local VMIN = vector.create(0, 0, 0)
local VMAX = vector.create(1000, 1000, 1000)

----------------------------------------------------------------------------------
-- Op benchmarks. Every function runs P passes of a 65536-iteration inner loop and
-- returns a value derived from its work so nothing can be optimized away.
----------------------------------------------------------------------------------

type OpBench = { group: string, name: string, fn: (number, ...any) -> number, args: { any }? }

local ops: { OpBench } = {}
local function op(group: string, name: string, fn: (number, ...any) -> number, args: { any }?)
	table.insert(ops, { group = group, name = name, fn = fn, args = args })
end

-- Baselines ---------------------------------------------------------------------

op("base", "loop+add (step 1)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += o
		end
	end
	return acc
end)

-- buffer reads -------------------------------------------------------------------

op("buffer", "readu8", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += buffer.readu8(B, o)
		end
	end
	return acc
end)

op("buffer", "readu16", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 2, 2 do
			acc += buffer.readu16(B, o)
		end
	end
	return acc
end)

op("buffer", "readu32", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += buffer.readu32(B, o)
		end
	end
	return acc
end)

op("buffer", "readu32 (buffer cached in a local)", function(P)
	local b = B
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += buffer.readu32(b, o)
		end
	end
	return acc
end)

op("buffer", "readi32", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += buffer.readi32(B, o)
		end
	end
	return acc
end)

op("buffer", "readf32", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += buffer.readf32(B, o)
		end
	end
	return acc
end)

op("buffer", "readf64", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 8, 8 do
			acc += buffer.readf64(B, o)
		end
	end
	return acc
end)

op("buffer", "readbits (8, byte aligned)", function(P)
	local acc = 0
	for _ = 1, P do
		for bo = 0, (N - 1) * 8, 8 do
			acc += buffer.readbits(B, bo, 8)
		end
	end
	return acc
end)

op("buffer", "readbits (12, unaligned)", function(P)
	local acc = 0
	for _ = 1, P do
		for bo = 0, (N - 1) * 12, 12 do
			acc += buffer.readbits(B, bo, 12)
		end
	end
	return acc
end)

op("buffer", "readstring (4 bytes)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += #buffer.readstring(B, o, 4)
		end
	end
	return acc
end)

-- buffer writes ------------------------------------------------------------------

op("buffer", "writeu8", function(P)
	for _ = 1, P do
		for o = 0, N - 1 do
			buffer.writeu8(B, o, o)
		end
	end
	return buffer.readu8(B, 7)
end)

op("buffer", "writeu16", function(P)
	for _ = 1, P do
		for o = 0, (N - 1) * 2, 2 do
			buffer.writeu16(B, o, o)
		end
	end
	return buffer.readu16(B, 8)
end)

op("buffer", "writeu32", function(P)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, o)
		end
	end
	return buffer.readu32(B, 8)
end)

op("buffer", "writef32", function(P)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writef32(B, o, o)
		end
	end
	return buffer.readf32(B, 8)
end)

op("buffer", "writef64", function(P)
	for _ = 1, P do
		for o = 0, (N - 1) * 8, 8 do
			buffer.writef64(B, o, o)
		end
	end
	return buffer.readf64(B, 8)
end)

op("buffer", "writebits (8, byte aligned)", function(P)
	for _ = 1, P do
		for bo = 0, (N - 1) * 8, 8 do
			buffer.writebits(B, bo, 8, bo)
		end
	end
	return buffer.readu8(B, 3)
end)

op("buffer", "copy (4 bytes, C call)", function(P)
	local src = buffer.create(4)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.copy(B, o, src, 0, 4)
		end
	end
	return buffer.readu8(B, 3)
end)

op("buffer", "len", function(P)
	local acc = 0
	for _ = 1, P do
		for _ = 0, N - 1 do
			acc += buffer.len(B)
		end
	end
	return acc
end)

-- tables (comparison point for buffer storage) --------------------------------------

op("table", "array read t[i]", function(P)
	local acc = 0
	for _ = 1, P do
		for i = 1, N do
			acc += T[i]
		end
	end
	return acc
end)

op("table", "array write t[i]=v", function(P)
	for _ = 1, P do
		for i = 1, N do
			T[i] = i
		end
	end
	return T[5]
end)

-- bit32 ----------------------------------------------------------------------------

op("bit32", "band(x, k)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.band(o, 255)
		end
	end
	return acc
end)

op("bit32", "bor(x, k)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.bor(o, 0x10000)
		end
	end
	return acc
end)

op("bit32", "bor(a, b, c, d)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.bor(o, 0x100, 0x20000, 0x4000000)
		end
	end
	return acc
end)

op("bit32", "bxor(x, k)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.bxor(o, 0x5555)
		end
	end
	return acc
end)

op("bit32", "lshift(x, 8)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.lshift(o, 8)
		end
	end
	return acc
end)

op("bit32", "rshift(x, 3)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.rshift(o, 3)
		end
	end
	return acc
end)

op("bit32", "arshift(x, 3)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.arshift(o, 3)
		end
	end
	return acc
end)

op("bit32", "extract(x, 4, 8) const field", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.extract(o, 4, 8)
		end
	end
	return acc
end)

op("bit32", "extract(x, f, w) dynamic", function(P, f, w)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.extract(o, f, w)
		end
	end
	return acc
end, { 4, 8 })

op("bit32", "replace(x, v, 8, 8)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.replace(o, 7, 8, 8)
		end
	end
	return acc
end)

op("bit32", "byteswap(x)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.byteswap(o)
		end
	end
	return acc
end)

op("bit32", "countlz(x)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.countlz(o)
		end
	end
	return acc
end)

op("bit32", "lrotate(x, 7)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += bit32.lrotate(o, 7)
		end
	end
	return acc
end)

-- arithmetic and math ------------------------------------------------------------

op("math", "x * k", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += o * 1.5
		end
	end
	return acc
end)

op("math", "x / k", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += o / 7
		end
	end
	return acc
end)

op("math", "x // k", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += o // 7
		end
	end
	return acc
end)

op("math", "x % k", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += o % 7
		end
	end
	return acc
end)

op("math", "x ^ 2.2 (gamma via pow)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += (o * 1.5e-5) ^ 2.2
		end
	end
	return acc
end)

op("math", "math.floor", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.floor(o * 0.5)
		end
	end
	return acc
end)

op("math", "math.floor via local alias", function(P)
	local floor = math.floor
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += floor(o * 0.5)
		end
	end
	return acc
end)

op("math", "math.round", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.round(o * 0.3)
		end
	end
	return acc
end)

op("math", "math.clamp", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.clamp(o, 1000, 60000)
		end
	end
	return acc
end)

op("math", "math.min(a, b)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.min(o, 30000)
		end
	end
	return acc
end)

op("math", "math.max(a, b)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.max(o, 30000)
		end
	end
	return acc
end)

op("math", "math.abs", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.abs(o - 30000)
		end
	end
	return acc
end)

op("math", "math.sqrt", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.sqrt(o)
		end
	end
	return acc
end)

op("math", "math.lerp", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.lerp(0, 255, o * 1.5e-5)
		end
	end
	return acc
end)

op("math", "math.sign", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.sign(o - 30000)
		end
	end
	return acc
end)

op("math", "math.sin (libm)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.sin(o)
		end
	end
	return acc
end)

op("math", "math.exp (libm)", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += math.exp(o * 1e-5)
		end
	end
	return acc
end)

op("math", "if-expression select", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += if o > 30000 then o else 30000
		end
	end
	return acc
end)

-- vector ------------------------------------------------------------------------

op("vector", "vector.create + .X", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			local v = vector.create(o, o, o)
			acc += v.X
		end
	end
	return acc
end)

op("vector", "v * s", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			local v = V1 * o
			acc += v.X
		end
	end
	return acc
end)

op("vector", "v + v", function(P)
	local acc = 0
	local v = V1
	for _ = 1, P do
		for _ = 0, N - 1 do
			v = v + V2
		end
	end
	return acc + v.X
end)

op("vector", "vector.dot", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += vector.dot(V1, vector.create(o, 1, 2))
		end
	end
	return acc
end)

op("vector", "vector.magnitude", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += vector.magnitude(vector.create(o, 1, 2))
		end
	end
	return acc
end)

op("vector", "vector.floor", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += vector.floor(V1 * o).X
		end
	end
	return acc
end)

op("vector", "vector.lerp", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += vector.lerp(V1, V2, o * 1e-5).X
		end
	end
	return acc
end)

op("vector", "vector.clamp", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, N - 1 do
			acc += vector.clamp(V1 * o, VMIN, VMAX).X
		end
	end
	return acc
end)

-- pixel packing: one RGBA8 pixel written per iteration ----------------------------

op("pack", "4x writeu8", function(P, r, g, b, a)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu8(B, o, r)
			buffer.writeu8(B, o + 1, g)
			buffer.writeu8(B, o + 2, b)
			buffer.writeu8(B, o + 3, a)
		end
	end
	return buffer.readu32(B, 4)
end, { 12, 34, 56, 255 })

op("pack", "writeu32(r + g*256 + b*65536 + a*16777216)", function(P, r, g, b, a)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, r + g * 256 + b * 65536 + a * 16777216)
		end
	end
	return buffer.readu32(B, 4)
end, { 12, 34, 56, 255 })

op("pack", "writeu32(bor(r, lshift(g,8), lshift(b,16), lshift(a,24)))", function(P, r, g, b, a)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, bit32.bor(r, bit32.lshift(g, 8), bit32.lshift(b, 16), bit32.lshift(a, 24)))
		end
	end
	return buffer.readu32(B, 4)
end, { 12, 34, 56, 255 })

op("pack", "writeu32(prepacked)", function(P, packed)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, packed)
		end
	end
	return buffer.readu32(B, 4)
end, { 0xFF382210 })

op("pack", "writeu32(PAL[band(i,15)+1])", function(P)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, PAL[bit32.band(o, 15) + 1])
		end
	end
	return buffer.readu32(B, 4)
end)

local function packHelper(r: number, g: number, b: number, a: number): number
	return r + g * 256 + b * 65536 + a * 16777216
end

op("pack", "writeu32(packHelper(r,g,b,a)) local fn", function(P, r, g, b, a)
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			buffer.writeu32(B, o, packHelper(r, g, b, a))
		end
	end
	return buffer.readu32(B, 4)
end, { 12, 34, 56, 255 })

-- pixel unpacking: one RGBA8 pixel read and split per iteration ------------------------

op("unpack", "4x readu8", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			acc += buffer.readu8(B, o) + buffer.readu8(B, o + 1) + buffer.readu8(B, o + 2) + buffer.readu8(B, o + 3)
		end
	end
	return acc
end)

op("unpack", "readu32 + 4x extract", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			local p = buffer.readu32(B, o)
			acc += bit32.extract(p, 0, 8) + bit32.extract(p, 8, 8) + bit32.extract(p, 16, 8) + bit32.extract(p, 24, 8)
		end
	end
	return acc
end)

op("unpack", "readu32 + band/rshift", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			local p = buffer.readu32(B, o)
			acc += bit32.band(p, 255)
				+ bit32.band(bit32.rshift(p, 8), 255)
				+ bit32.band(bit32.rshift(p, 16), 255)
				+ bit32.rshift(p, 24)
		end
	end
	return acc
end)

op("unpack", "readu32 + // and %", function(P)
	local acc = 0
	for _ = 1, P do
		for o = 0, (N - 1) * 4, 4 do
			local p = buffer.readu32(B, o)
			acc += p % 256 + (p // 256) % 256 + (p // 65536) % 256 + p // 16777216
		end
	end
	return acc
end)

----------------------------------------------------------------------------------
-- Full-frame kernels at 1024 x 1024 RGBA8 (4 MiB per frame)
----------------------------------------------------------------------------------

local W, H = 1024, 1024
local PIX = W * H
local BYTES = PIX * 4
local FB = buffer.create(BYTES)
local SRC = buffer.create(BYTES)
local DST2 = buffer.create(BYTES)
local HALF = buffer.create(BYTES // 4)
local IDX = buffer.create(PIX)
local PALB = buffer.create(256 * 4)

for i = 0, 255 do
	buffer.writeu32(PALB, i * 4, 0xFF000000 + i * 0x00010101)
end
for i = 0, PIX - 1 do
	buffer.writeu8(IDX, i, (i * 7) % 256)
	-- source image with a gradient alpha so blend kernels hit every path
	buffer.writeu32(SRC, i * 4, ((i % 256) * 0x01000000) + (i % 251) * 0x10000 + (i % 241) * 0x100 + (i % 239))
	buffer.writeu32(DST2, i * 4, 0xFF000000 + (i % 233) * 0x10000 + (i % 227) * 0x100 + (i % 223))
end

type Kernel = { name: string, fn: () -> number }
local kernels: { Kernel } = {}
local function kernel(name: string, fn: () -> number)
	table.insert(kernels, { name = name, fn = fn })
end

kernel("fill: buffer.fill (memset)", function()
	buffer.fill(FB, 0, 0x7F)
	return buffer.readu8(FB, 100)
end)

kernel("fill: u32 seed + buffer.copy doubling", function()
	buffer.writeu32(FB, 0, 0xFF336699)
	local filled = 4
	while filled < BYTES do
		local n = math.min(filled, BYTES - filled)
		buffer.copy(FB, filled, FB, 0, n)
		filled += n
	end
	return buffer.readu32(FB, BYTES - 4)
end)

kernel("fill: writeu32 per pixel", function()
	local c = 0xFF336699
	for o = 0, BYTES - 4, 4 do
		buffer.writeu32(FB, o, c)
	end
	return buffer.readu32(FB, BYTES - 4)
end)

kernel("blit: 1024 row buffer.copy", function()
	local row = W * 4
	for y = 0, H - 1 do
		local o = y * row
		buffer.copy(FB, o, SRC, o, row)
	end
	return buffer.readu32(FB, 4096)
end)

kernel("gradient: per pixel arithmetic pack", function()
	local o = 0
	for y = 0, H - 1 do
		local gy = (y // 4) * 256 + 0xFF000000
		for x = 0, W - 1 do
			buffer.writeu32(FB, o, gy + x // 4)
			o += 4
		end
	end
	return buffer.readu32(FB, 4096)
end)

kernel("sdf circle: sqrt + clamp per pixel", function()
	local cx, cy, R = 512, 512, 300
	local rgb = 0x00FFAA33
	local o = 0
	for y = 0, H - 1 do
		local dy = y + 0.5 - cy
		local dy2 = dy * dy
		for x = 0, W - 1 do
			local dx = x + 0.5 - cx
			local d = math.sqrt(dx * dx + dy2) - R
			local a = math.clamp(0.5 - d, 0, 1)
			buffer.writeu32(FB, o, rgb + (a * 255 // 1) * 16777216)
			o += 4
		end
	end
	return buffer.readu32(FB, BYTES // 2)
end)

kernel("sdf circle: vector.magnitude per pixel", function()
	local C = vector.create(512, 512, 0)
	local R = 300
	local rgb = 0x00FFAA33
	local o = 0
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local d = vector.magnitude(vector.create(x + 0.5, y + 0.5, 0) - C) - R
			local a = math.clamp(0.5 - d, 0, 1)
			buffer.writeu32(FB, o, rgb + (a * 255 // 1) * 16777216)
			o += 4
		end
	end
	return buffer.readu32(FB, BYTES // 2)
end)

kernel("sdf circle: span skip (only the AA ring)", function()
	-- Axiom: an SDF tells you where nothing changes. Interior and exterior spans are
	-- solid runs and go through buffer.fill/copy; only the 1-px edge ring runs math.
	local cx, cy, R = 512, 512, 300
	local inside = 0xFFFFAA33
	local outside = 0x00FFAA33 -- transparent pixels keep the edge colour (no dark fringe)
	local row = W * 4
	-- clear the whole frame with one seed write + buffer.copy doubling (memcpy speed)
	buffer.writeu32(FB, 0, outside)
	local filled = 4
	while filled < BYTES do
		local m = math.min(filled, BYTES - filled)
		buffer.copy(FB, filled, FB, 0, m)
		filled += m
	end
	local outerR = R + 1
	local innerR = R - 1
	for y = 0, H - 1 do
		local dy = y + 0.5 - cy
		local dy2 = dy * dy
		if dy2 < outerR * outerR then
			local halfOuter = math.sqrt(outerR * outerR - dy2)
			local halfInner = if dy2 < innerR * innerR then math.sqrt(innerR * innerR - dy2) else -1
			local x0 = math.max(0, math.floor(cx - halfOuter))
			local x1 = math.min(W - 1, math.ceil(cx + halfOuter))
			-- interior pixels are those whose centre lies within innerR, so alpha is exactly 1
			local i0 = if halfInner >= 0 then math.ceil(cx - halfInner - 0.5) else x1 + 1
			local i1 = if halfInner >= 0 then math.floor(cx + halfInner - 0.5) else x1
			local base = y * row
			local leftEnd = math.min(i0 - 1, x1)
			for x = x0, leftEnd do
				local dx = x + 0.5 - cx
				local d = math.sqrt(dx * dx + dy2) - R
				local a = math.clamp(0.5 - d, 0, 1)
				buffer.writeu32(FB, base + x * 4, outside + (a * 255 // 1) * 16777216)
			end
			if i1 >= i0 then
				-- solid interior span: seed one pixel then double with buffer.copy
				local s = base + i0 * 4
				local n = (i1 - i0 + 1) * 4
				buffer.writeu32(FB, s, inside)
				local done = 4
				while done < n do
					local m = math.min(done, n - done)
					buffer.copy(FB, s + done, FB, s, m)
					done += m
				end
			end
			for x = math.max(i1 + 1, leftEnd + 1), x1 do
				local dx = x + 0.5 - cx
				local d = math.sqrt(dx * dx + dy2) - R
				local a = math.clamp(0.5 - d, 0, 1)
				buffer.writeu32(FB, base + x * 4, outside + (a * 255 // 1) * 16777216)
			end
		end
	end
	return buffer.readu32(FB, BYTES // 2)
end)

kernel("mip 2x2 box: per channel extract", function()
	local srcRow = W * 4
	local o = 0
	for y = 0, H - 2, 2 do
		local r0 = y * srcRow
		local r1 = r0 + srcRow
		for x = 0, W - 2, 2 do
			local a0 = r0 + x * 4
			local b0 = r1 + x * 4
			local p, q, s, t = buffer.readu32(SRC, a0), buffer.readu32(SRC, a0 + 4), buffer.readu32(SRC, b0), buffer.readu32(SRC, b0 + 4)
			local cr = (bit32.extract(p, 0, 8) + bit32.extract(q, 0, 8) + bit32.extract(s, 0, 8) + bit32.extract(t, 0, 8) + 2) // 4
			local cg = (bit32.extract(p, 8, 8) + bit32.extract(q, 8, 8) + bit32.extract(s, 8, 8) + bit32.extract(t, 8, 8) + 2) // 4
			local cb = (bit32.extract(p, 16, 8) + bit32.extract(q, 16, 8) + bit32.extract(s, 16, 8) + bit32.extract(t, 16, 8) + 2) // 4
			local ca = (bit32.extract(p, 24, 8) + bit32.extract(q, 24, 8) + bit32.extract(s, 24, 8) + bit32.extract(t, 24, 8) + 2) // 4
			buffer.writeu32(HALF, o, cr + cg * 256 + cb * 65536 + ca * 16777216)
			o += 4
		end
	end
	return buffer.readu32(HALF, 1024)
end)

kernel("mip 2x2 box: SWAR (2 channels per op)", function()
	-- Pairs of channels live in 16-bit lanes (mask 0x00FF00FF). Four 8-bit values
	-- sum to at most 1020, so lanes never carry into each other.
	local srcRow = W * 4
	local o = 0
	for y = 0, H - 2, 2 do
		local r0 = y * srcRow
		local r1 = r0 + srcRow
		for x = 0, W - 2, 2 do
			local a0 = r0 + x * 4
			local b0 = r1 + x * 4
			local p, q, s, t = buffer.readu32(SRC, a0), buffer.readu32(SRC, a0 + 4), buffer.readu32(SRC, b0), buffer.readu32(SRC, b0 + 4)
			local rb = bit32.band(p, 0x00FF00FF) + bit32.band(q, 0x00FF00FF) + bit32.band(s, 0x00FF00FF) + bit32.band(t, 0x00FF00FF) + 0x00020002
			local ga = bit32.band(bit32.rshift(p, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(q, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(s, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(t, 8), 0x00FF00FF)
				+ 0x00020002
			buffer.writeu32(HALF, o, bit32.bor(bit32.band(bit32.rshift(rb, 2), 0x00FF00FF), bit32.lshift(bit32.band(bit32.rshift(ga, 2), 0x00FF00FF), 8)))
			o += 4
		end
	end
	return buffer.readu32(HALF, 1024)
end)

kernel("blend over opaque dst: float per channel", function()
	for o = 0, BYTES - 4, 4 do
		local s = buffer.readu32(SRC, o)
		local d = buffer.readu32(DST2, o)
		local a = bit32.rshift(s, 24) / 255
		local ia = 1 - a
		local r = bit32.band(s, 255) * a + bit32.band(d, 255) * ia
		local g = bit32.extract(s, 8, 8) * a + bit32.extract(d, 8, 8) * ia
		local b = bit32.extract(s, 16, 8) * a + bit32.extract(d, 16, 8) * ia
		buffer.writeu32(FB, o, (r + 0.5) // 1 + ((g + 0.5) // 1) * 256 + ((b + 0.5) // 1) * 65536 + 0xFF000000)
	end
	return buffer.readu32(FB, 4096)
end)

kernel("blend over opaque dst: SWAR exact /255", function()
	-- out = (s*a + d*(255-a)) / 255 with exact rounding, two channels per multiply.
	-- Lane identity used: for 0 <= t <= 65025, round(t/255) = (x + (x >> 8)) >> 8, x = t + 128.
	for o = 0, BYTES - 4, 4 do
		local s = buffer.readu32(SRC, o)
		local d = buffer.readu32(DST2, o)
		local a = bit32.rshift(s, 24)
		local ia = 255 - a
		local rb = bit32.band(s, 0x00FF00FF) * a + bit32.band(d, 0x00FF00FF) * ia + 0x00800080
		rb = bit32.band(bit32.rshift(rb + bit32.band(bit32.rshift(rb, 8), 0x00FF00FF), 8), 0x00FF00FF)
		local g = bit32.band(bit32.rshift(s, 8), 0xFF) * a + bit32.band(bit32.rshift(d, 8), 0xFF) * ia + 128
		g = bit32.rshift(g + bit32.rshift(g, 8), 8)
		buffer.writeu32(FB, o, rb + g * 256 + 0xFF000000)
	end
	return buffer.readu32(FB, 4096)
end)

kernel("lod crossfade t=0.37: SWAR lerp (CPU path)", function()
	local t = 94 -- 0.37 * 255
	local it = 255 - t
	for o = 0, BYTES - 4, 4 do
		local s = buffer.readu32(SRC, o)
		local d = buffer.readu32(DST2, o)
		local rb = bit32.band(s, 0x00FF00FF) * t + bit32.band(d, 0x00FF00FF) * it + 0x00800080
		rb = bit32.band(bit32.rshift(rb + bit32.band(bit32.rshift(rb, 8), 0x00FF00FF), 8), 0x00FF00FF)
		local ga = bit32.band(bit32.rshift(s, 8), 0x00FF00FF) * t + bit32.band(bit32.rshift(d, 8), 0x00FF00FF) * it + 0x00800080
		ga = bit32.band(bit32.rshift(ga + bit32.band(bit32.rshift(ga, 8), 0x00FF00FF), 8), 0x00FF00FF)
		buffer.writeu32(FB, o, rb + ga * 256)
	end
	return buffer.readu32(FB, 4096)
end)

kernel("palette expand: u8 index -> u32 via readu32(PALB)", function()
	local o = 0
	for i = 0, PIX - 1 do
		buffer.writeu32(FB, o, buffer.readu32(PALB, buffer.readu8(IDX, i) * 4))
		o += 4
	end
	return buffer.readu32(FB, 4096)
end)

kernel("chroma key: squared distance + smooth alpha", function()
	local kr, kg, kb = 0, 200, 0
	local lo, hi = 40 * 40, 90 * 90
	local span = 255 / (hi - lo)
	for o = 0, BYTES - 4, 4 do
		local p = buffer.readu32(DST2, o)
		local dr = bit32.band(p, 255) - kr
		local dg = bit32.extract(p, 8, 8) - kg
		local db = bit32.extract(p, 16, 8) - kb
		local d2 = dr * dr + dg * dg + db * db
		local a = math.clamp((d2 - lo) * span, 0, 255) // 1
		buffer.writeu32(FB, o, bit32.band(p, 0x00FFFFFF) + a * 16777216)
	end
	return buffer.readu32(FB, 4096)
end)

kernel("bilinear resample 1024->512 at scale 0.73", function()
	local scale = 1 / 0.73
	local o = 0
	for y = 0, 511 do
		local sy = math.min((y + 0.5) * scale - 0.5, H - 2)
		local y0 = sy // 1
		local fy = sy - y0
		local row0 = y0 * W * 4
		local row1 = row0 + W * 4
		for x = 0, 511 do
			local sx = math.min((x + 0.5) * scale - 0.5, W - 2)
			local x0 = sx // 1
			local fx = sx - x0
			local p00 = buffer.readu32(SRC, row0 + x0 * 4)
			local p10 = buffer.readu32(SRC, row0 + x0 * 4 + 4)
			local p01 = buffer.readu32(SRC, row1 + x0 * 4)
			local p11 = buffer.readu32(SRC, row1 + x0 * 4 + 4)
			local w00 = (1 - fx) * (1 - fy)
			local w10 = fx * (1 - fy)
			local w01 = (1 - fx) * fy
			local w11 = fx * fy
			local r = bit32.band(p00, 255) * w00 + bit32.band(p10, 255) * w10 + bit32.band(p01, 255) * w01 + bit32.band(p11, 255) * w11
			local g = bit32.extract(p00, 8, 8) * w00 + bit32.extract(p10, 8, 8) * w10 + bit32.extract(p01, 8, 8) * w01 + bit32.extract(p11, 8, 8) * w11
			local b = bit32.extract(p00, 16, 8) * w00 + bit32.extract(p10, 16, 8) * w10 + bit32.extract(p01, 16, 8) * w01 + bit32.extract(p11, 16, 8) * w11
			local a = bit32.rshift(p00, 24) * w00 + bit32.rshift(p10, 24) * w10 + bit32.rshift(p01, 24) * w01 + bit32.rshift(p11, 24) * w11
			buffer.writeu32(HALF, o, (r + 0.5) // 1 + ((g + 0.5) // 1) * 256 + ((b + 0.5) // 1) * 65536 + ((a + 0.5) // 1) * 16777216)
			o += 4
		end
	end
	return buffer.readu32(HALF, 1024)
end)

kernel("dirty tiles: 16 tiles of 64x64 rewritten", function()
	local row = W * 4
	local c = 0xFF00FF00
	for t = 0, 15 do
		local tx = (t % 4) * 256
		local ty = (t // 4) * 256
		for y = ty, ty + 63 do
			local base = y * row + tx * 4
			for o = base, base + 63 * 4, 4 do
				buffer.writeu32(FB, o, c)
			end
		end
	end
	return buffer.readu32(FB, 0)
end)

----------------------------------------------------------------------------------
-- Driver
----------------------------------------------------------------------------------

local REPS = 5

local function timeOp(entry: OpBench, passes: number): number
	local best = math.huge
	local args = entry.args or {}
	for _ = 1, REPS do
		local t0 = clock()
		entry.fn(passes, table.unpack(args))
		local dt = clock() - t0
		if dt < best then
			best = dt
		end
		yieldNow()
	end
	return best
end

local function run()
	-- Calibrate pass count so the baseline loop takes roughly 20 ms.
	local passes = 8
	while true do
		local dt = timeOp(ops[1], passes)
		if dt >= 0.02 or passes >= 4096 then
			break
		end
		passes *= 2
	end
	local iters = passes * N
	local baseline = timeOp(ops[1], passes)
	emit("meta", "passes", passes, "count")
	emit("meta", "baseline loop", baseline / iters * 1e9, "ns/iter")
	for i = 2, #ops do
		local entry = ops[i]
		local dt = timeOp(entry, passes)
		-- ns/op subtracts the loop+add baseline: meaningful in the interpreter, where
		-- dispatch dominates. Native loops are bound by the latency of the add chain, so
		-- cheap native ops hide under it; ns/iter (raw) is the honest native number.
		emit(entry.group, entry.name, (dt - baseline) / iters * 1e9, "ns/op")
		emit(entry.group, entry.name, dt / iters * 1e9, "ns/iter")
	end
	for _, k in kernels do
		local best = math.huge
		for _ = 1, 3 do
			local t0 = clock()
			k.fn()
			local dt = clock() - t0
			if dt < best then
				best = dt
			end
			yieldNow()
		end
		emit("kernel", k.name, best * 1000, "ms/frame")
	end
end

run()
return nil
