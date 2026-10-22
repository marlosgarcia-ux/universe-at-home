--!strict
--!native
--!optimize 2
-- Universe at Home: Meadow :: ServerJobs
--
-- Job handlers run by the server worker Actors (and inline by WorkerPool's serial
-- fallback). Pure computation in `parallel`; engine writes in `serial`, after
-- task.synchronize(). Kinds:
--   heights   rows [k0, k1) of base heights and carve targets (WorldGen stage 1)
--   setWorld  stores the eroded heightmap in the worker's state
--   chunk     builds one chunk's voxel arrays in parallel, writes them serially with
--             Terrain:WriteVoxelChannels (solid + liquid occupancy, clean shores) or,
--             if that call fails, Terrain:WriteVoxels (solid or water per voxel)
--   rock      builds a rock's vertex and triangle arrays (see Rocks.luau)
--   train     one slice of ALLAN statistics accumulation (see Training.luau)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local WorldGen = require(Demo:WaitForChild("WorldGen"))
local RockGen = require(Demo:WaitForChild("RockGen"))

local Jobs = {}

-- Enum.Material per WorldGen material index (+1), resolved once in the serial phase.
local MATERIALS: { Enum.Material } = {}
for i, name in WorldGen.MATERIAL_NAMES do
	local ok, m = pcall(function(): Enum.Material
		return (Enum.Material :: any)[name]
	end)
	MATERIALS[i] = if ok then m else Enum.Material.Air
end
local AIR_MAT = Enum.Material.Air

type ChunkBuild = {
	j0: number,
	ny: number,
	x0: number,
	z0: number,
	solid: { { { Enum.Material } } },
	occupancy: { { { number } } },
	liquid: { { { number } } },
	voxels: number,
}

Jobs.heights = {
	parallel = function(p: any, _state: { [string]: any }): any
		local world = WorldGen.new(p.seed)
		local h, t = WorldGen.bandHeights(world, p.k0, p.k1)
		return { k0 = p.k0, k1 = p.k1, heights = h, targets = t }
	end,
}

Jobs.setWorld = {
	parallel = function(p: any, state: { [string]: any }): any
		state.world = WorldGen.new(p.seed)
		state.heights = p.heights
		return true
	end,
}

local function buildChunk(world: WorldGen.World, heights: buffer, cx: number, cz: number): ChunkBuild
	local cc = world.cfg.chunkColumns
	local j0, ny = WorldGen.chunkRange(world, heights, cx, cz)
	local solid: { { { Enum.Material } } } = table.create(cc)
	local occupancy: { { { number } } } = table.create(cc)
	local liquid: { { { number } } } = table.create(cc)
	for x = 1, cc do
		local sx: { { Enum.Material } } = table.create(ny)
		local ox: { { number } } = table.create(ny)
		local lx: { { number } } = table.create(ny)
		for y = 1, ny do
			sx[y] = table.create(cc, AIR_MAT)
			ox[y] = table.create(cc, 0)
			lx[y] = table.create(cc, 0)
		end
		solid[x], occupancy[x], liquid[x] = sx, ox, lx
	end
	local i0, k0 = cx * cc, cz * cc
	for dz = 0, cc - 1 do
		for dx = 0, cc - 1 do
			local i, k = i0 + dx, k0 + dz
			local h = WorldGen.heightAt(world, heights, i, k)
			local f = WorldGen.fillBottom(world, heights, i, k)
			local m = WorldGen.classify(world, heights, i, k)
			local sx, ox, lx = solid[dx + 1], occupancy[dx + 1], liquid[dx + 1]
			for y = 1, ny do
				local mat, occ, liq = WorldGen.voxel(world, h, f, m, j0 + y - 1)
				sx[y][dz + 1] = MATERIALS[mat + 1]
				ox[y][dz + 1] = occ
				lx[y][dz + 1] = liq
			end
		end
	end
	local v = world.voxel
	return {
		j0 = j0,
		ny = ny,
		x0 = world.origin + i0 * v,
		z0 = world.origin + k0 * v,
		solid = solid,
		occupancy = occupancy,
		liquid = liquid,
		voxels = cc * cc * ny,
	}
end
Jobs.buildChunk = buildChunk

-- Converts the channel arrays to the single-channel WriteVoxels form.
local function toLegacy(b: ChunkBuild): ({ { { Enum.Material } } }, { { { number } } })
	local water = MATERIALS[WorldGen.WATER + 1]
	local mats: { { { Enum.Material } } } = {}
	local occs: { { { number } } } = {}
	local indexOf: { [Enum.Material]: number } = {}
	for i, m in MATERIALS do
		indexOf[m] = i - 1
	end
	for x, plane in b.solid do
		local mx: { { Enum.Material } } = {}
		local oxs: { { number } } = {}
		for y, row in plane do
			local mr: { Enum.Material } = {}
			local orow: { number } = {}
			for z, m in row do
				local mi, o = WorldGen.solidOrWater(indexOf[m] or 0, b.occupancy[x][y][z], b.liquid[x][y][z])
				mr[z] = if mi == WorldGen.WATER then water else MATERIALS[mi + 1]
				orow[z] = o
			end
			mx[y], oxs[y] = mr, orow
		end
		mats[x], occs[x] = mx, oxs
	end
	return mats, occs
end

Jobs.chunk = {
	parallel = function(p: any, state: { [string]: any }): any
		local world = state.world :: WorldGen.World?
		local heights = state.heights :: buffer?
		assert(world and heights, "setWorld has not run on this worker")
		return buildChunk(world, heights, p.cx, p.cz)
	end,
	serial = function(p: any, b: any, state: { [string]: any }): any
		local build = b :: ChunkBuild
		local terrain = Workspace.Terrain
		local cc = 16
		local v = 4
		local lo = Vector3.new(build.x0, build.j0 * v, build.z0)
		local hi = Vector3.new(build.x0 + cc * v, (build.j0 + build.ny) * v, build.z0 + cc * v)
		local region = Region3.new(lo, hi)
		local t0 = os.clock()
		local mode = state.writeMode or "channels"
		local channelError: string? = nil
		if mode == "channels" then
			local ok, err = pcall(function()
				terrain:WriteVoxelChannels(region, 4, {
					SolidMaterial = build.solid,
					SolidOccupancy = build.occupancy,
					LiquidOccupancy = build.liquid,
				})
			end)
			if not ok then
				channelError = tostring(err)
				mode = "voxels"
				state.writeMode = "voxels"
				state.channelError = channelError
			end
		end
		if mode == "voxels" then
			local mats, occs = toLegacy(build)
			terrain:WriteVoxels(region, 4, mats, occs)
		end
		return {
			cx = p.cx,
			cz = p.cz,
			voxels = build.voxels,
			writeMs = (os.clock() - t0) * 1000,
			mode = mode,
			channelError = channelError or state.channelError,
		}
	end,
}

Jobs.rock = {
	parallel = function(p: any, _state: { [string]: any }): any
		return RockGen.build(p.seed, p.radius, p.subdivisions, p.roughness)
	end,
}

return Jobs
