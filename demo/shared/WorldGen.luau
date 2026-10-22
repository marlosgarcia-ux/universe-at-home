--!strict
--!native
--!optimize 2
-- Universe at Home: Meadow :: WorldGen
--
-- The landscape as pure, deterministic functions (no engine objects), so the same code
-- runs in server Actors, in the coordinator's serial fallback and in the CLI tests.
--
-- Pipeline (docs/DEMO.md section 2):
--   1. bandHeights   per row band, in parallel: MyMath value noise with domain warping,
--                    a meadow plateau, rolling hills, a ring of ridged mountains (base
--                    heights) and the river and lake carve targets (min-composited).
--   2. erode         serial, whole map: thermal erosion (talus slides), then the water
--                    carve is re-applied so beds stay under the water plane.
--   3. classify      per column: biome by height, slope and moisture.
--   4. voxel         per voxel: solid material and occupancy, liquid occupancy.
--
-- Deterministic ops only (docs/RUNTIME_AUDIT.md 6.5): + - * / sqrt floor abs min max,
-- comparisons, bit32, integer buffer ops, f32 buffer stores (IEEE rounding), MyMath
-- hashing and noise. No math.noise, math.random, math.lerp, ^, sin, exp. Floors of
-- fractional values use math.floor, never //.
--
-- Grid: column (i, k), i along +X, k along +Z, 0 <= i, k < columns. Column centre:
-- x = origin + 4 i + 2, z = origin + 4 k + 2. Heights are studs above y = 0, stored as
-- f32 in row-major buffers (k * columns + i).

local MyMath = require("../Universe/MyMath")
local Config = require("./Config")

local WorldGen = {}

-- Surface material indices (the server maps them to Enum.Material).
local AIR, GRASS, LEAFY, GROUND, MUD, SAND, ROCK, SLATE, LIMESTONE, SNOW, GLACIER, WATER = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
WorldGen.AIR, WorldGen.GRASS, WorldGen.LEAFY, WorldGen.GROUND = AIR, GRASS, LEAFY, GROUND
WorldGen.MUD, WorldGen.SAND, WorldGen.ROCK, WorldGen.SLATE = MUD, SAND, ROCK, SLATE
WorldGen.LIMESTONE, WorldGen.SNOW, WorldGen.GLACIER, WorldGen.WATER = LIMESTONE, SNOW, GLACIER, WATER
WorldGen.MATERIAL_COUNT = 12

-- Enum.Material item names, indexed by material index + 1.
WorldGen.MATERIAL_NAMES = {
	"Air",
	"Grass",
	"LeafyGrass",
	"Ground",
	"Mud",
	"Sand",
	"Rock",
	"Slate",
	"Limestone",
	"Snow",
	"Glacier",
	"Water",
}

-- What lies under a surface material (depth 3 to 9 studs), indexed by material + 1.
local SUBSURFACE = { AIR, GROUND, GROUND, GROUND, MUD, SAND, ROCK, SLATE, LIMESTONE, ROCK, SNOW, WATER }
WorldGen.SUBSURFACE = SUBSURFACE

export type WorldConfig = typeof(Config.world)

export type World = {
	seed: number,
	columns: number,
	origin: number,
	voxel: number,
	waterLevel: number,
	maxHeight: number,
	cfg: WorldConfig,
}

function WorldGen.new(seed: number?, cfg: WorldConfig?): World
	local c = cfg or Config.world
	return {
		seed = seed or Config.seed,
		columns = c.columns,
		origin = c.origin,
		voxel = c.voxel,
		waterLevel = c.waterLevel,
		maxHeight = c.maxHeight,
		cfg = c,
	}
end

local valueNoise2 = MyMath.valueNoise2
local fbm2 = MyMath.fbm2
local smoothstep = MyMath.smoothstep
local sqrt = math.sqrt
local abs = math.abs
local floor = math.floor

local function fbm(x: number, z: number, seed: number, octaves: number): number
	local v = fbm2(x, z, seed, octaves)
	return v
end

-- Ridged multifractal from value noise: ridges where the noise crosses 1/2, each
-- octave weighted by the previous one so ridges get sharper detail than valleys.
local function ridged(x: number, z: number, seed: number, octaves: number): number
	local sum, amp, freq, norm, weight = 0, 1, 1, 0, 1
	for o = 1, octaves do
		local n = valueNoise2(x * freq, z * freq, seed + o * 7919)
		n = 1 - abs(2 * n - 1)
		n = n * n * weight
		weight = n * 1.8
		if weight > 1 then
			weight = 1
		end
		sum += n * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	end
	return sum / norm
end
WorldGen.ridged = ridged

function WorldGen.columnCenter(world: World, i: number, k: number): (number, number)
	local v = world.voxel
	return world.origin + v * i + v * 0.5, world.origin + v * k + v * 0.5
end

-- Distance from (x, z) to the river polyline.
local function riverDistance(pts: { number }, x: number, z: number): number
	local best = math.huge
	for p = 1, #pts - 3, 2 do
		local ax, az, bx, bz = pts[p], pts[p + 1], pts[p + 2], pts[p + 3]
		local ex, ez = bx - ax, bz - az
		local wx, wz = x - ax, z - az
		local ee = ex * ex + ez * ez
		local t = if ee > 0 then (wx * ex + wz * ez) / ee else 0
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
		local dx, dz = wx - ex * t, wz - ez * t
		local d2 = dx * dx + dz * dz
		if d2 < best then
			best = d2
		end
	end
	return sqrt(best)
end
WorldGen.riverDistance = riverDistance

-- Base terrain height (studs) before water carving and erosion.
function WorldGen.baseHeight(world: World, x: number, z: number): number
	local c = world.cfg
	local s = world.seed
	local wa = c.warpAmplitude
	-- domain warp: low-frequency displacement of the sampling point
	local qx = x + wa * (2 * fbm(x / 310, z / 310, s + 101, 3) - 1)
	local qz = z + wa * (2 * fbm(x / 310 + 17.25, z / 310 - 9.125, s + 202, 3) - 1)
	-- meadow plateau
	local h = c.meadowBase + c.meadowAmplitude * (2 * fbm(qx / 190, qz / 190, s + 303, 4) - 1)
	-- rolling hills, absent at the centre
	local r = sqrt(x * x + z * z)
	local hillMask = smoothstep(80, 250, r + 60 * (2 * fbm(x / 240, z / 240, s + 404, 2) - 1))
	if hillMask > 0 then
		local hills = smoothstep(0.38, 0.86, fbm(qx / 150, qz / 150, s + 505, 5))
		h += c.hillAmplitude * hills * hillMask
	end
	-- ring of ridged mountains
	local rm = sqrt(qx * qx + qz * qz) + 70 * (2 * fbm(x / 200, z / 200, s + 606, 3) - 1)
	local mountainMask = smoothstep(c.mountainInner, c.mountainOuter, rm)
	if mountainMask > 0 then
		local rid = ridged(qx / 340, qz / 340, s + 707, 6)
		h += mountainMask * (c.mountainBase + c.mountainAmplitude * rid)
	end
	return h
end

-- Water carve target (studs): the river valley and the lake basin; math.huge where
-- neither applies. The final height is min(height, target). `h` is the base height,
-- used to widen valleys in high ground.
function WorldGen.carveTarget(world: World, x: number, z: number, h: number): number
	local c = world.cfg
	local s = world.seed
	local wl = world.waterLevel
	local target = math.huge
	-- river
	local rv = c.river
	local mx = x + rv.meander * (2 * fbm(x / 95, z / 95, s + 808, 2) - 1)
	local mz = z + rv.meander * (2 * fbm(x / 95 - 31.5, z / 95 + 12.75, s + 818, 2) - 1)
	local d = riverDistance(rv.points, mx, mz)
	local rise = h - wl
	if rise < 0 then
		rise = 0
	end
	local bankWidth = rv.bank + rise * 0.38
	if d < rv.width + bankWidth then
		local bed = wl - rv.depth
		local edge = bed + rv.depth * 0.45 -- height of the bed at its edge
		local t: number
		if d <= rv.width then
			local u = d / rv.width
			t = bed + (edge - bed) * u * u
		else
			t = edge + (h - edge) * smoothstep(rv.width, rv.width + bankWidth, d)
		end
		if t < target then
			target = t
		end
	end
	-- lake
	local lk = c.lake
	local ex = x + 30 * (2 * fbm(x / 80, z / 80, s + 909, 2) - 1)
	local ez = z + 30 * (2 * fbm(x / 80 + 7.5, z / 80 - 3.25, s + 919, 2) - 1)
	local dx, dz = ex - lk.x, ez - lk.z
	local dl = sqrt(dx * dx + dz * dz) - lk.radius
	if dl < lk.shore then
		local rim = wl - 2.5
		local t: number
		if dl <= 0 then
			t = rim - (lk.depth - 2.5) * smoothstep(0, lk.radius * 0.7, -dl)
		else
			t = rim + (h - rim) * smoothstep(0, lk.shore, dl)
		end
		if t < target then
			target = t
		end
	end
	return target
end

local function clampHeight(world: World, h: number): number
	local lo, hi = world.cfg.minHeight, world.maxHeight - 6
	return if h < lo then lo elseif h > hi then hi else h
end

-- Stage 1 (parallel): rows [k0, k1) of the map. Returns two f32 buffers of
-- (k1 - k0) * columns values: carved heights and carve targets (inf = none).
function WorldGen.bandHeights(world: World, k0: number, k1: number): (buffer, buffer)
	local n = world.columns
	local rows = k1 - k0
	local heights = buffer.create(rows * n * 4)
	local targets = buffer.create(rows * n * 4)
	local o = 0
	for k = k0, k1 - 1 do
		for i = 0, n - 1 do
			local x, z = WorldGen.columnCenter(world, i, k)
			local h = WorldGen.baseHeight(world, x, z)
			local t = WorldGen.carveTarget(world, x, z, h)
			if t < h then
				h = t
			end
			buffer.writef32(heights, o, clampHeight(world, h))
			buffer.writef32(targets, o, if t == math.huge then t else clampHeight(world, t))
			o += 4
		end
	end
	return heights, targets
end

-- Stage 2 (serial): thermal erosion. Each iteration moves rate * (excess) / 2 across
-- every 4-neighbour pair whose height difference exceeds the talus, computed from the
-- previous iteration's heights (Jacobi order, so the result does not depend on scan
-- order beyond the fixed accumulation order). Then beds are clamped to the carve.
function WorldGen.erode(world: World, heights: buffer, targets: buffer, iterations: number?)
	local n = world.columns
	local c = world.cfg
	local talus = c.talus
	local rate = c.erosionRate * 0.5
	local count = n * n * 4
	local old = buffer.create(count)
	local readf32, writef32 = buffer.readf32, buffer.writef32
	local rowBytes = n * 4
	for _ = 1, iterations or c.erosionIterations do
		buffer.copy(old, 0, heights, 0, count)
		for k = 0, n - 1 do
			local row = k * rowBytes
			for i = 0, n - 1 do
				local a = row + i * 4
				local ha = readf32(old, a)
				if i < n - 1 then
					local b = a + 4
					local d = ha - readf32(old, b)
					if d > talus then
						local m = rate * (d - talus)
						writef32(heights, a, readf32(heights, a) - m)
						writef32(heights, b, readf32(heights, b) + m)
					elseif d < -talus then
						local m = rate * (-d - talus)
						writef32(heights, a, readf32(heights, a) + m)
						writef32(heights, b, readf32(heights, b) - m)
					end
				end
				if k < n - 1 then
					local b = a + rowBytes
					local d = ha - readf32(old, b)
					if d > talus then
						local m = rate * (d - talus)
						writef32(heights, a, readf32(heights, a) - m)
						writef32(heights, b, readf32(heights, b) + m)
					elseif d < -talus then
						local m = rate * (-d - talus)
						writef32(heights, a, readf32(heights, a) + m)
						writef32(heights, b, readf32(heights, b) - m)
					end
				end
			end
		end
	end
	-- keep river and lake beds under the water plane
	for o = 0, count - 4, 4 do
		local t = readf32(targets, o)
		if t < readf32(heights, o) then
			writef32(heights, o, t)
		end
	end
end

-- The whole heightmap, serially (CLI tests and the coordinator's fallback).
function WorldGen.generateHeights(world: World): (buffer, buffer)
	local n = world.columns
	local heights, targets = WorldGen.bandHeights(world, 0, n)
	WorldGen.erode(world, heights, targets)
	return heights, targets
end

function WorldGen.heightAt(world: World, heights: buffer, i: number, k: number): number
	local n = world.columns
	if i < 0 then
		i = 0
	elseif i > n - 1 then
		i = n - 1
	end
	if k < 0 then
		k = 0
	elseif k > n - 1 then
		k = n - 1
	end
	return buffer.readf32(heights, (k * n + i) * 4)
end

-- Largest height difference to a 4-neighbour, per stud.
function WorldGen.slopeAt(world: World, heights: buffer, i: number, k: number): number
	local h = WorldGen.heightAt(world, heights, i, k)
	local a = abs(h - WorldGen.heightAt(world, heights, i - 1, k))
	local b = abs(h - WorldGen.heightAt(world, heights, i + 1, k))
	local c = abs(h - WorldGen.heightAt(world, heights, i, k - 1))
	local d = abs(h - WorldGen.heightAt(world, heights, i, k + 1))
	local m = if a > b then a else b
	if c > m then
		m = c
	end
	if d > m then
		m = d
	end
	return m / world.voxel
end

-- Stage 3: surface material of column (i, k).
function WorldGen.classify(world: World, heights: buffer, i: number, k: number): number
	local c = world.cfg
	local s = world.seed
	local wl = world.waterLevel
	local h = WorldGen.heightAt(world, heights, i, k)
	local slope = WorldGen.slopeAt(world, heights, i, k)
	local x, z = WorldGen.columnCenter(world, i, k)
	local detail = valueNoise2(x / 23, z / 23, s + 1212)
	if h < wl - 0.6 then
		if h > wl - 3.5 then
			return SAND
		end
		return if detail < 0.55 then MUD else GROUND
	end
	local moist = fbm(x / 140, z / 140, s + 1111, 3)
	if h < wl + 1.6 + 2.4 * detail and slope < 0.9 then
		return if moist > 0.6 then MUD else SAND
	end
	local snow = c.snowLine + 52 * (detail - 0.5)
	if slope > c.cliffSlope then
		if h > snow + 24 and slope < 1.7 then
			return SNOW
		end
		if h > 150 then
			return if detail < 0.6 then ROCK else SLATE
		end
		return if detail < 0.5 then SLATE elseif detail < 0.8 then ROCK else LIMESTONE
	end
	if h > snow then
		return if slope < 0.35 and h > snow + 26 then GLACIER else SNOW
	end
	if h > c.alpineLine + 36 * (detail - 0.5) then
		return if detail < 0.42 then ROCK else GROUND
	end
	if slope > 0.72 then
		return if detail < 0.3 then ROCK else GROUND
	end
	if moist > 0.62 and detail > 0.42 then
		return LEAFY
	end
	if moist < 0.3 and detail < 0.12 then
		return GROUND
	end
	return GRASS
end

-- Lowest surface among a column and its 4-neighbours, minus the shell thickness: the
-- column is solid from there up (terrain below is left hollow; nothing can see it).
function WorldGen.fillBottom(world: World, heights: buffer, i: number, k: number): number
	local h = WorldGen.heightAt(world, heights, i, k)
	local m = h
	local a = WorldGen.heightAt(world, heights, i - 1, k)
	local b = WorldGen.heightAt(world, heights, i + 1, k)
	local c = WorldGen.heightAt(world, heights, i, k - 1)
	local d = WorldGen.heightAt(world, heights, i, k + 1)
	if a < m then
		m = a
	end
	if b < m then
		m = b
	end
	if c < m then
		m = c
	end
	if d < m then
		m = d
	end
	m -= world.cfg.shell
	return if m < 0 then 0 else m
end

-- Stage 4: voxel layer j of a column with surface h, solid from `fill`, surface
-- material m. Returns (solid material, solid occupancy, liquid occupancy) for
-- WriteVoxelChannels; WriteVoxels callers use solidOrWater below.
function WorldGen.voxel(world: World, h: number, fill: number, m: number, j: number): (number, number, number)
	local yb = j * 4
	local wl = world.waterLevel
	local occ = (h - yb) * 0.25
	local liquid = (wl - yb) * 0.25
	if liquid < 0 then
		liquid = 0
	elseif liquid > 1 then
		liquid = 1
	end
	if occ > 0 and yb + 4 > fill then
		if occ >= 1 then
			occ = 1
			liquid = 0
		end
		local depth = h - (yb + 2)
		local mat = m
		if depth > 9 then
			mat = ROCK
		elseif depth > 3 then
			mat = SUBSURFACE[m + 1]
		end
		return mat, occ, liquid
	end
	return AIR, 0, liquid
end

-- Single-channel form for Terrain:WriteVoxels: a voxel is either solid or water.
-- Partially solid voxels under the water plane become full water below half
-- occupancy and full solid above it (no air pockets under water).
function WorldGen.solidOrWater(mat: number, occ: number, liquid: number): (number, number)
	if occ > 0 then
		if liquid > 0 and occ < 1 then
			if liquid >= 1 then
				if occ >= 0.5 then
					return mat, 1
				end
				return WATER, 1
			end
		end
		return mat, occ
	end
	if liquid > 0 then
		return WATER, liquid
	end
	return AIR, 0
end

-- Vertical voxel range [j0, j0 + ny) that a chunk needs.
function WorldGen.chunkRange(world: World, heights: buffer, cx: number, cz: number): (number, number)
	local cc = world.cfg.chunkColumns
	local lo, hi = math.huge, world.waterLevel
	for k = cz * cc, cz * cc + cc - 1 do
		for i = cx * cc, cx * cc + cc - 1 do
			local h = WorldGen.heightAt(world, heights, i, k)
			local f = WorldGen.fillBottom(world, heights, i, k)
			if f < lo then
				lo = f
			end
			if h > hi then
				hi = h
			end
		end
	end
	local j0 = floor(lo / 4)
	local j1 = floor(hi / 4) + 1
	local maxJ = world.maxHeight // 4
	if j1 > maxJ then
		j1 = maxJ
	end
	if j0 < 0 then
		j0 = 0
	end
	return j0, j1 - j0
end

-- Chunk order: rings of Chebyshev distance around the spawn chunk, so the area the
-- player stands on is written first (Saturn's refinement order, compute/Tiles.ringOrder).
function WorldGen.chunkOrder(world: World): { number }
	local cc = world.cfg.chunkColumns
	local nc = world.columns // cc
	local sp = world.cfg.spawn
	local scx = floor((sp.x - world.origin) / (world.voxel * cc))
	local scz = floor((sp.z - world.origin) / (world.voxel * cc))
	local order: { number } = {}
	local key: { number } = {}
	for cz = 0, nc - 1 do
		for cx = 0, nc - 1 do
			local id = cz * nc + cx
			local dx, dz = abs(cx - scx), abs(cz - scz)
			local ring = if dx > dz then dx else dz
			table.insert(order, id)
			key[id + 1] = ring * 65536 + (dz * nc + dx) * 4 + (if cx >= scx then 0 else 1) + (if cz >= scz then 0 else 2)
		end
	end
	table.sort(order, function(a: number, b: number): boolean
		local ka, kb = key[a + 1], key[b + 1]
		if ka ~= kb then
			return ka < kb
		end
		return a < b
	end)
	return order
end

-- Hash of a buffer (u32 words through MyMath.hash32). Same value in every runtime.
function WorldGen.hashBuffer(b: buffer, seed: number?): number
	local h = MyMath.hash32((seed or 0x811C9DC5) % 4294967296)
	local hash32 = MyMath.hash32
	local len = buffer.len(b)
	local words = len // 4
	local readu32 = buffer.readu32
	for w = 0, words - 1 do
		h = hash32(bit32.bxor(h, readu32(b, w * 4)))
	end
	for o = words * 4, len - 1 do
		h = hash32(bit32.bxor(h, buffer.readu8(b, o)))
	end
	return h
end

-- Deterministic digest of one chunk's voxels (material, occupancy and liquid as
-- bytes), used by the CLI tests and by the server to log what it wrote.
function WorldGen.chunkHash(world: World, heights: buffer, cx: number, cz: number): number
	local cc = world.cfg.chunkColumns
	local j0, ny = WorldGen.chunkRange(world, heights, cx, cz)
	local b = buffer.create(cc * cc * ny * 3)
	local o = 0
	for k = cz * cc, cz * cc + cc - 1 do
		for i = cx * cc, cx * cc + cc - 1 do
			local h = WorldGen.heightAt(world, heights, i, k)
			local f = WorldGen.fillBottom(world, heights, i, k)
			local m = WorldGen.classify(world, heights, i, k)
			for j = j0, j0 + ny - 1 do
				local mat, occ, liq = WorldGen.voxel(world, h, f, m, j)
				buffer.writeu8(b, o, mat)
				buffer.writeu8(b, o + 1, floor(occ * 255 + 0.5))
				buffer.writeu8(b, o + 2, floor(liq * 255 + 0.5))
				o += 3
			end
		end
	end
	return WorldGen.hashBuffer(b, cx * 4096 + cz)
end

-- The dry, gentle column nearest to the configured spawn point.
function WorldGen.findSpawn(world: World, heights: buffer): (number, number, number)
	local n = world.columns
	local sp = world.cfg.spawn
	local ci = floor((sp.x - world.origin) / world.voxel)
	local ck = floor((sp.z - world.origin) / world.voxel)
	for radius = 0, 40 do
		local best, bestScore = -1, math.huge
		for k = ck - radius, ck + radius do
			for i = ci - radius, ci + radius do
				if i >= 1 and k >= 1 and i < n - 1 and k < n - 1 then
					local h = WorldGen.heightAt(world, heights, i, k)
					local s = WorldGen.slopeAt(world, heights, i, k)
					if h > world.waterLevel + 3 and s < 0.45 then
						local score = (i - ci) * (i - ci) + (k - ck) * (k - ck)
						if score < bestScore then
							best, bestScore = k * n + i, score
						end
					end
				end
			end
		end
		if best >= 0 then
			local i, k = best % n, best // n
			local x, z = WorldGen.columnCenter(world, i, k)
			return x, WorldGen.heightAt(world, heights, i, k), z
		end
	end
	local x, z = WorldGen.columnCenter(world, ci, ck)
	return x, WorldGen.heightAt(world, heights, ci, ck), z
end

-- Material histogram (counts per index), for the HUD and tests.
function WorldGen.histogram(world: World, heights: buffer): { number }
	local counts = table.create(WorldGen.MATERIAL_COUNT, 0)
	local n = world.columns
	for k = 0, n - 1 do
		for i = 0, n - 1 do
			local m = WorldGen.classify(world, heights, i, k)
			counts[m + 1] += 1
		end
	end
	return counts
end

return WorldGen
