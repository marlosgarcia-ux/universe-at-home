--!strict
-- Universe at Home: Meadow :: TerrainBuilder
--
-- Server coordinator of the landscape (docs/DEMO.md section 2):
--   A. heights   32 bands of 8 rows sent to the worldgen Actors (parallel noise)
--   B. erosion   serial thermal erosion over the assembled 256 x 256 map
--   C. voxels    the eroded map is broadcast to every worker; chunks are dispatched in
--                rings around the spawn, a few per frame; each worker builds its
--                chunk's arrays in parallel and writes them after task.synchronize()
-- Progress is replicated to clients through attributes of ReplicatedStorage.DemoStatus.
-- Every stage falls back to inline (serial) work if the Actors do not answer.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local WorldGen = require(Demo:WaitForChild("WorldGen"))
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))
local Status = require(Demo:WaitForChild("Status"))

local TerrainBuilder = {}

export type Result = {
	world: WorldGen.World,
	heights: buffer,
	spawn: Vector3,
	chunks: number,
	voxels: number,
	seconds: number,
	mode: string,
}

local function setProgress(mirror: Instance, stage: string, progress: number)
	mirror:SetAttribute("WorldStage", stage)
	mirror:SetAttribute("WorldProgress", progress)
end

-- onSpawnReady(spawn) is called once the chunks around the spawn are written.
function TerrainBuilder.run(
	reg: Status.Registry,
	pool: WorkerPool.Pool,
	mirror: Instance,
	onSpawnReady: (Vector3) -> ()
): Result
	local t0 = os.clock()
	local world = WorldGen.new(Config.seed)
	local n = world.columns
	local rowBytes = n * 4

	-- A. heights
	setProgress(mirror, "heights", 0)
	local heights = buffer.create(n * rowBytes)
	local targets = buffer.create(n * rowBytes)
	local band = 8
	local bands = n // band
	local doneBands = 0
	local failures = 0
	for k0 = 0, n - 1, band do
		WorkerPool.submit(pool, "heights", { seed = world.seed, k0 = k0, k1 = k0 + band }, function(ok: boolean, res: any)
			if ok and type(res) == "table" and typeof(res.heights) == "buffer" and typeof(res.targets) == "buffer" then
				buffer.copy(heights, res.k0 * rowBytes, res.heights, 0, (res.k1 - res.k0) * rowBytes)
				buffer.copy(targets, res.k0 * rowBytes, res.targets, 0, (res.k1 - res.k0) * rowBytes)
			else
				failures += 1
				local h, t = WorldGen.bandHeights(world, k0, k0 + band)
				buffer.copy(heights, k0 * rowBytes, h, 0)
				buffer.copy(targets, k0 * rowBytes, t, 0)
			end
			doneBands += 1
			setProgress(mirror, "heights", doneBands / bands * 0.25)
		end)
	end
	while doneBands < bands do
		task.wait(0.05)
	end
	local tA = os.clock()
	Status.set(
		reg,
		"worldgen_heights",
		if failures == 0 then "ok" else "fallback",
		string.format("%d bands in %.2f s via %s (%d redone inline)", bands, tA - t0, pool.mode, failures)
	)

	-- B. erosion (serial; about 5 ms native, 20 ms interpreted)
	setProgress(mirror, "erosion", 0.26)
	WorldGen.erode(world, heights, targets)
	local hash = WorldGen.hashBuffer(heights)
	mirror:SetAttribute("WorldHash", hash)
	Status.result("server", "worldgen", { heightsHash = hash, seconds = os.clock() - t0, mode = pool.mode })

	-- spawn point
	local sx, sy, sz = WorldGen.findSpawn(world, heights)
	local spawn = Vector3.new(sx, sy, sz)
	mirror:SetAttribute("SpawnPosition", spawn)

	-- C. voxels
	setProgress(mirror, "voxels", 0.3)
	local acks = WorkerPool.broadcast(pool, "setWorld", { seed = world.seed, heights = heights }, 15)
	if pool.available and acks < pool.readyCount then
		Status.set(reg, "worldgen_broadcast", "fallback", string.format("%d of %d workers took the map", acks, pool.readyCount))
	end
	local order = WorldGen.chunkOrder(world)
	local total = #order
	mirror:SetAttribute("WorldChunksTotal", total)
	local nextIndex = 1
	local inflight = 0
	local done = 0
	local voxels = 0
	local writeMs = 0
	local mode = "?"
	local channelError: string? = nil
	local failedChunks = 0
	local spawnReady = false
	local spawnChunks = 9
	local nc = n // world.cfg.chunkColumns
	-- adaptive dispatch: keep the serial write time per frame near the budget
	local perFrame = 2
	local budgetMs = 14
	local conn: RBXScriptConnection? = nil
	local function dispatch()
		while inflight < perFrame and nextIndex <= total do
			local id = order[nextIndex]
			nextIndex += 1
			inflight += 1
			local cx, cz = id % nc, id // nc
			WorkerPool.submit(pool, "chunk", { cx = cx, cz = cz }, function(ok: boolean, res: any)
				inflight -= 1
				done += 1
				if ok and type(res) == "table" then
					voxels += res.voxels or 0
					writeMs += res.writeMs or 0
					mode = res.mode or mode
					if res.channelError then
						channelError = res.channelError
					end
					local w = res.writeMs or 0
					if w > budgetMs and perFrame > 1 then
						perFrame -= 1
					elseif w < budgetMs * 0.4 and perFrame < 8 then
						perFrame += 1
					end
				else
					failedChunks += 1
					warn(string.format("%s|server|chunk|failed|%d,%d %s", Config.TAG, cx, cz, tostring(res)))
				end
				mirror:SetAttribute("WorldChunks", done)
				setProgress(mirror, "voxels", 0.3 + 0.7 * done / total)
				if not spawnReady and done >= spawnChunks then
					spawnReady = true
					task.spawn(onSpawnReady, spawn)
				end
			end)
		end
	end
	conn = RunService.Heartbeat:Connect(dispatch)
	dispatch()
	while done < total do
		task.wait(0.1)
	end
	if conn then
		conn:Disconnect()
	end
	if not spawnReady then
		spawnReady = true
		task.spawn(onSpawnReady, spawn)
	end
	local seconds = os.clock() - t0
	setProgress(mirror, "done", 1)
	mirror:SetAttribute("WorldReady", true)
	mirror:SetAttribute("WorldSeconds", seconds)
	Status.set(
		reg,
		"terrain_write",
		if failedChunks > 0 then "fallback" elseif mode == "channels" then "ok" else "fallback",
		string.format(
			"%d chunks, %d voxels, %.0f ms of writes, mode %s%s%s",
			total,
			voxels,
			writeMs,
			mode,
			if failedChunks > 0 then string.format(", %d chunks failed", failedChunks) else "",
			if channelError then " (WriteVoxelChannels error: " .. channelError .. ")" else ""
		)
	)
	Status.result("server", "terrain", { chunks = total, voxels = voxels, writeMs = writeMs, seconds = seconds, mode = mode })
	return {
		world = world,
		heights = heights,
		spawn = spawn,
		chunks = total,
		voxels = voxels,
		seconds = seconds,
		mode = pool.mode,
	}
end

-- Last resort if everything above failed: a flat grass field so the place is still
-- walkable and the rest of the demo can run.
function TerrainBuilder.flatFallback(mirror: Instance): Vector3
	local terrain = Workspace.Terrain
	terrain:FillBlock(CFrame.new(0, 28, 0), Vector3.new(512, 56, 512), Enum.Material.Grass)
	mirror:SetAttribute("WorldReady", true)
	mirror:SetAttribute("WorldStage", "flat fallback")
	mirror:SetAttribute("WorldProgress", 1)
	return Vector3.new(0, 56, 0)
end

return TerrainBuilder
