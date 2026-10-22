-- Tests for the pure generators of the Meadow demo (demo/shared): WorldGen, RockGen,
-- Metrics, Net validation, Config, and (when present) GrassGen and SkyGen.
-- Run by tests/run.sh in the interpreter and with native code generation; the hash
-- constants below must be reproduced bit for bit by both runtimes (and by every
-- Roblox client and server, which run the same code).

local Config = require("../demo/shared/Config")
local WorldGen = require("../demo/shared/WorldGen")
local RockGen = require("../demo/shared/RockGen")
local Metrics = require("../demo/shared/Metrics")
local Net = require("../demo/shared/Net")

local failures = 0
local function check(cond: boolean, msg: string)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	end
end

local function near(a: number, b: number, eps: number): boolean
	return math.abs(a - b) <= eps
end

----------------------------------------------------------------------------------
-- Config
----------------------------------------------------------------------------------
do
	local w = Config.world
	check(w.size == w.columns * w.voxel, "world size = columns * voxel")
	check(w.columns % w.chunkColumns == 0, "chunks tile the map")
	check(w.voxel == 4, "WriteVoxels resolution must be 4")
	check(w.maxHeight % 4 == 0, "max height on the voxel grid")
	check(w.waterLevel > w.minHeight and w.waterLevel < w.maxHeight, "water level inside the height range")
	check(#w.river.points % 2 == 0 and #w.river.points >= 4, "river polyline has pairs")
	check(Config.grass.ring0 < Config.grass.ring1, "ring 0 inside ring 1")
	check(Config.grass.hysteresis > 1, "LOD hysteresis above 1")
end

----------------------------------------------------------------------------------
-- WorldGen: one band, determinism, ranges
----------------------------------------------------------------------------------
local world = WorldGen.new()
do
	local h1, t1 = WorldGen.bandHeights(world, 100, 104)
	local h2, t2 = WorldGen.bandHeights(world, 100, 104)
	check(buffer.tostring(h1) == buffer.tostring(h2), "bandHeights deterministic (heights)")
	check(buffer.tostring(t1) == buffer.tostring(t2), "bandHeights deterministic (targets)")
	check(buffer.len(h1) == 4 * world.columns * 4, "band size")
	-- a band computed alone equals the same rows of a bigger band (no hidden state)
	local h3 = WorldGen.bandHeights(world, 98, 106)
	local same = true
	for o = 0, buffer.len(h1) - 4, 4 do
		if buffer.readf32(h1, o) ~= buffer.readf32(h3, o + 2 * world.columns * 4) then
			same = false
			break
		end
	end
	check(same, "band rows independent of band extent")
end

local heights, targets = WorldGen.generateHeights(world)
do
	local lo, hi = math.huge, -math.huge
	local below = 0
	for o = 0, buffer.len(heights) - 4, 4 do
		local h = buffer.readf32(heights, o)
		if h < lo then
			lo = h
		end
		if h > hi then
			hi = h
		end
		if h < world.waterLevel then
			below += 1
		end
		local t = buffer.readf32(targets, o)
		if t < math.huge then
			check(h <= t + 1e-3, "eroded height respects the water carve")
		end
	end
	check(lo >= Config.world.minHeight - 1e-6, "heights >= minHeight")
	check(hi <= Config.world.maxHeight - 6 + 1e-6, "heights <= maxHeight - 6")
	check(hi > 180, "mountains reach above 180 studs")
	local total = world.columns * world.columns
	check(below > total * 0.02 and below < total * 0.2, "between 2 and 20 percent of columns under water")
end

-- Bit-identical across runtimes and platforms: these constants were produced by the
-- interpreter and confirmed by --codegen.
local HEIGHTS_HASH = 1969077229
local CHUNK_8_8_HASH = 3488744759
check(WorldGen.hashBuffer(heights) == HEIGHTS_HASH, "heightmap hash " .. tostring(WorldGen.hashBuffer(heights)))
check(WorldGen.chunkHash(world, heights, 8, 8) == CHUNK_8_8_HASH, "chunk (8, 8) hash " .. tostring(WorldGen.chunkHash(world, heights, 8, 8)))

do
	-- biomes: every main material occurs, grass dominates the meadow
	local hist = WorldGen.histogram(world, heights)
	local total = world.columns * world.columns
	local grass = hist[WorldGen.GRASS + 1] + hist[WorldGen.LEAFY + 1]
	check(grass > total * 0.35, "grass covers more than 35 percent")
	for _, m in { WorldGen.GRASS, WorldGen.LEAFY, WorldGen.GROUND, WorldGen.SAND, WorldGen.ROCK, WorldGen.SNOW, WorldGen.MUD } do
		check(hist[m + 1] > 0, "material present: " .. WorldGen.MATERIAL_NAMES[m + 1])
	end
	check(hist[WorldGen.AIR + 1] == 0 and hist[WorldGen.WATER + 1] == 0, "surface is never air or water")
end

do
	-- spawn on dry gentle ground near the configured point
	local sx, sy, sz = WorldGen.findSpawn(world, heights)
	check(sy > world.waterLevel + 3, "spawn above water")
	check(math.abs(sx - Config.world.spawn.x) < 120 and math.abs(sz - Config.world.spawn.z) < 120, "spawn near the configured point")
end

do
	-- voxel invariants
	for _, h in { 10.5, 44.2, 46, 47.9, 60.25, 200 } do
		for j = 0, 63 do
			local mat, occ, liq = WorldGen.voxel(world, h, 0, WorldGen.GRASS, j)
			check(occ >= 0 and occ <= 1 and liq >= 0 and liq <= 1, "occupancies in [0, 1]")
			if j * 4 >= world.waterLevel then
				check(liq == 0, "no water above the water plane")
			end
			if occ == 0 then
				check(mat == WorldGen.AIR, "empty voxels are air")
			end
			if occ >= 1 then
				check(liq == 0, "full solid holds no water")
			end
			local m2, o2 = WorldGen.solidOrWater(mat, occ, liq)
			check(o2 >= 0 and o2 <= 1, "legacy occupancy in [0, 1]")
			if j * 4 + 4 <= world.waterLevel and occ < 1 then
				check(o2 == 1, "under water a voxel is full (solid or water), no air pockets")
			end
			check(m2 >= 0 and m2 < WorldGen.MATERIAL_COUNT, "legacy material index")
		end
	end
	-- a chunk range covers surface and water
	local j0, ny = WorldGen.chunkRange(world, heights, 8, 8)
	check(j0 >= 0 and ny > 0 and j0 + ny <= world.maxHeight // 4, "chunk range inside the world")
	local order = WorldGen.chunkOrder(world)
	check(#order == (world.columns // 16) ^ 2, "chunk order covers every chunk")
	local seen = {}
	for _, id in order do
		check(not seen[id], "chunk order has no duplicates")
		seen[id] = true
	end
end

----------------------------------------------------------------------------------
-- RockGen
----------------------------------------------------------------------------------
do
	local r = RockGen.build(1234, 4, 2, 0.3)
	check(r.vertexCount == 162, "icosphere subdivided twice has 162 vertices, got " .. r.vertexCount)
	check(r.triangleCount == 320, "and 320 triangles, got " .. r.triangleCount)
	check(#r.colors == #r.positions, "one colour per vertex")
	for i = 1, #r.triangles do
		local v = r.triangles[i]
		check(v >= 1 and v <= r.vertexCount, "triangle index in range")
	end
	for i = 1, #r.positions do
		local p = r.positions[i]
		check(p == p and math.abs(p) < 4 * 3, "finite position")
	end
	for i = 1, #r.colors do
		check(r.colors[i] >= 0 and r.colors[i] <= 1, "colour in [0, 1]")
	end
	local b = buffer.create(#r.positions * 8)
	for i, p in r.positions do
		buffer.writef64(b, (i - 1) * 8, p)
	end
	local r2 = RockGen.build(1234, 4, 2, 0.3)
	local b2 = buffer.create(#r2.positions * 8)
	for i, p in r2.positions do
		buffer.writef64(b2, (i - 1) * 8, p)
	end
	check(buffer.tostring(b) == buffer.tostring(b2), "rocks deterministic")
	check(WorldGen.hashBuffer(b) == 3190023006, "rock hash " .. tostring(WorldGen.hashBuffer(b)))
end

----------------------------------------------------------------------------------
-- Metrics
----------------------------------------------------------------------------------
do
	local r = Metrics.ring(4)
	for _, v in { 1, 2, 3, 4, 5, 6 } do
		Metrics.push(r, v)
	end
	check(r.count == 4, "ring keeps its size")
	check(near(Metrics.mean(r), 4.5, 1e-12), "ring mean over the last values")
	check(Metrics.percentile(r, 0) == 3 and Metrics.percentile(r, 1) == 6, "percentiles")
	local f = Metrics.ring(10)
	for _ = 1, 10 do
		Metrics.push(f, 1 / 60)
	end
	check(near(Metrics.fps(f), 60, 1e-9), "fps from frame times")
	check(Metrics.formatMb(2048) == "2.00 GB", "formatMb")
end

----------------------------------------------------------------------------------
-- Net: validation and rate limiting (pure parts)
----------------------------------------------------------------------------------
do
	check(Net.validateHello({ version = "M1", summary = "client features 5 of 6 ok" }), "valid hello")
	check(not Net.validateHello({ version = string.rep("x", 40) }), "hello: long version rejected")
	check(not Net.validateHello("nope"), "hello: non-table rejected")
	local good = { run = 3, test = "T2", entries = { { key = "raster_1", hash = 123 }, { key = "allan_0", hash = 4294967295 } } }
	check(Net.validateHashes(good), "valid hashes")
	check(not Net.validateHashes({ run = 3, test = "T2", entries = {} }), "hashes: empty rejected")
	check(not Net.validateHashes({ run = 3, test = "T2", entries = { { key = "k", hash = -1 } } }), "hashes: negative rejected")
	check(not Net.validateHashes({ run = 3, test = "T2", entries = { { key = "k", hash = 1.5 } } }), "hashes: fractional rejected")
	check(not Net.validateHashes({ run = 0, test = "T2", entries = { { key = "k", hash = 1 } } }), "hashes: run 0 rejected")
	check(not Net.validateHashes({ run = 1, test = "T2<script>", entries = { { key = "k", hash = 1 } } }), "hashes: bad test name rejected")
	local many = {}
	for i = 1, 65 do
		many[i] = { key = "k" .. i, hash = i }
	end
	check(not Net.validateHashes({ run = 1, test = "T2", entries = many }), "hashes: too many entries rejected")
	local trainOk = Net.validateTrain({ slices = 4 })
	local trainBad = Net.validateTrain({ slices = 1000 })
	check(trainOk, "train validation accepts 4 slices")
	check(not trainBad, "train validation rejects 1000 slices")
	local l = Net.newLimiter(1, 2)
	local first = Net.allow(l, "p", 0)
	local second = Net.allow(l, "p", 0)
	check(first and second, "burst of 2 allowed")
	check(not Net.allow(l, "p", 0), "third call in the same instant limited")
	check(Net.allow(l, "p", 1.01), "refills at the rate")
end

----------------------------------------------------------------------------------
-- Optional generators added in later milestones
----------------------------------------------------------------------------------
local okGrass, GrassGen = pcall(require, "../demo/shared/GrassGen")
if okGrass and type(GrassGen) == "table" and (GrassGen :: any).selfTest then
	local ok, err = (GrassGen :: any).selfTest()
	check(ok, "GrassGen self test: " .. tostring(err))
end
local okSky, SkyGen = pcall(require, "../demo/shared/SkyGen")
if okSky and type(SkyGen) == "table" and (SkyGen :: any).selfTest then
	local ok, err = (SkyGen :: any).selfTest()
	check(ok, "SkyGen self test: " .. tostring(err))
end

if failures > 0 then
	error(string.format("%d demo checks failed", failures))
end
