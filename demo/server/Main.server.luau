--!strict
-- Universe at Home: Meadow :: server entry point (ServerScriptService.Server.Main)
--
-- Starts every server stage inside Status.stage (pcall + Output line + capabilities
-- mirror + fallback), so one broken feature never takes down the rest:
--   environment, remotes, worker pool (8 worldgen Actors), terrain, spawn, sky bake,
--   rocks, determinism referee and server training (stress bench T9, T10).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local Status = require(Demo:WaitForChild("Status"))
local Net = require(Demo:WaitForChild("Net"))
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))

local Server = script.Parent :: Instance

-- Replicated status mirror (attributes read by every client's HUD).
local mirror = ReplicatedStorage:FindFirstChild("DemoStatus")
if not mirror then
	local f = Instance.new("Folder")
	f.Name = "DemoStatus"
	f.Parent = ReplicatedStorage
	mirror = f
end
assert(mirror, "DemoStatus")
local statusFolder: Instance = mirror
statusFolder:SetAttribute("WorldStage", "starting")
statusFolder:SetAttribute("WorldProgress", 0)
statusFolder:SetAttribute("WorldReady", false)
statusFolder:SetAttribute("ServerVersion", Config.VERSION)
statusFolder:SetAttribute("ServerStudio", RunService:IsStudio())

local reg = Status.registry("server", statusFolder)
Status.set(reg, "server_start", "info", "Universe at Home: Meadow " .. Config.VERSION)

-- Optional modules: a missing or broken one becomes a failed stage, not a crash.
local function optionalRequire(name: string): any
	local m = Server:FindFirstChild(name)
	if not m or not m:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, m)
	if ok then
		return result
	end
	Status.set(reg, "module_" .. name, "failed", tostring(result))
	return nil
end

-- Remotes ---------------------------------------------------------------------------
Status.stage(reg, "remotes", function()
	Net.serverInit(ReplicatedStorage)
	return "ok", "RemoteEvents in ReplicatedStorage." .. Net.FOLDER
end)

-- Players: characters load only once the ground under the spawn exists ---------------
local spawnReady = false
local spawnPosition = Vector3.new(0, 80, 0)

local function loadCharacter(player: Player)
	local ok, err = pcall(function()
		player:LoadCharacterAsync()
	end)
	if not ok then
		local ok2, err2 = pcall(function()
			(player :: any):LoadCharacter()
		end)
		if not ok2 then
			warn(string.format("%s|server|character|failed|%s; %s", Config.TAG, tostring(err), tostring(err2)))
		end
	end
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				task.wait(Players.RespawnTime)
				if player.Parent then
					loadCharacter(player)
				end
			end)
		end
	end)
	if spawnReady and not player.Character then
		task.spawn(loadCharacter, player)
	end
end

Status.stage(reg, "players", function()
	Players.CharacterAutoLoads = false
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	return "ok", "characters load when the spawn chunks are written"
end)

local function placeSpawn(pos: Vector3)
	spawnPosition = pos
	local old = Workspace:FindFirstChild("MeadowSpawn")
	if old then
		old:Destroy()
	end
	local s = Instance.new("SpawnLocation")
	s.Name = "MeadowSpawn"
	s.Anchored = true
	s.CanCollide = false
	s.CanQuery = false
	s.CanTouch = true
	s.Transparency = 1
	s.Size = Vector3.new(6, 1, 6)
	s.CFrame = CFrame.new(pos + Vector3.new(0, 1.5, 0))
	s.Neutral = true
	s.Duration = 0
	s.Parent = Workspace
end

local function onSpawnReady(pos: Vector3)
	if spawnReady then
		return
	end
	placeSpawn(pos)
	spawnReady = true
	statusFolder:SetAttribute("SpawnReady", true)
	for _, p in Players:GetPlayers() do
		if not p.Character then
			task.spawn(loadCharacter, p)
		end
	end
	Status.set(reg, "spawn", "ok", string.format("spawn at %.0f, %.0f, %.0f", pos.X, pos.Y, pos.Z))
end

-- Environment ------------------------------------------------------------------------
Status.stage(reg, "environment", function()
	local Environment = require(Server:WaitForChild("Environment"))
	return "ok", Environment.apply()
end)

-- Server worker pool -------------------------------------------------------------------
local ServerJobs = optionalRequire("ServerJobs") or {}
local pool = WorkerPool.new("WorldGenPool", ServerJobs, Config.actors.jobTimeout)
Status.stage(reg, "actors_server", function()
	local workers = ServerScriptService:FindFirstChild("Workers")
	local template = workers and workers:FindFirstChild("ServerWorker")
	if not template then
		return "fallback", "no ServerScriptService.Workers.ServerWorker template; serial mode"
	end
	local container = Instance.new("Folder")
	container.Name = "WorkerPools"
	container.Parent = ServerScriptService
	local ready = WorkerPool.spawn(pool, template, container, Config.actors.serverWorldGen, 8)
	if ready == 0 then
		WorkerPool.destroy(pool)
		return "fallback", "no worker said hello within 8 s; generation runs serially"
	end
	return "ok", string.format("%d of %d worldgen Actors ready", ready, Config.actors.serverWorldGen)
end)
statusFolder:SetAttribute("ServerActors", pool.readyCount)

-- Terrain ----------------------------------------------------------------------------
local terrainResult: any = nil
task.spawn(function()
	local TerrainBuilder = require(Server:WaitForChild("TerrainBuilder"))
	local ok = Status.stage(reg, "terrain", function()
		terrainResult = TerrainBuilder.run(reg, pool, statusFolder, onSpawnReady)
		return "ok", string.format("%d chunks in %.1f s (%s)", terrainResult.chunks, terrainResult.seconds, terrainResult.mode)
	end, function(message: string)
		local pos = TerrainBuilder.flatFallback(statusFolder)
		onSpawnReady(pos)
		return "fallback", "flat grass field: " .. message
	end)
	statusFolder:SetAttribute("TerrainOk", ok)
	-- Rocks need the final heights.
	local Rocks = optionalRequire("Rocks")
	if Rocks and terrainResult then
		Status.stage(reg, "rocks", function()
			return Rocks.run(reg, pool, terrainResult)
		end, function(message: string)
			return "fallback", "rocks skipped"
		end)
	elseif not Rocks then
		Status.set(reg, "rocks", "skipped", "Rocks module not present")
	end
end)

-- Watchdog: never leave players without a character.
task.delay(120, function()
	if not spawnReady then
		Status.set(reg, "spawn", "fallback", "terrain too slow; spawning on a platform")
		local p = Instance.new("Part")
		p.Name = "FallbackPlatform"
		p.Anchored = true
		p.Size = Vector3.new(40, 2, 40)
		p.Material = Enum.Material.Grass
		p.CFrame = CFrame.new(spawnPosition)
		p.Parent = Workspace
		onSpawnReady(spawnPosition + Vector3.new(0, 1, 0))
	end
end)

-- Sky ----------------------------------------------------------------------------------
task.spawn(function()
	local SkyBaker = optionalRequire("SkyBaker")
	if not SkyBaker then
		Status.set(reg, "sky", "fallback", "SkyBaker not present; default sky")
		return
	end
	Status.stage(reg, "sky", function()
		return SkyBaker.run(reg)
	end, function(message: string)
		return "fallback", "default sky"
	end)
end)

-- Clients say hello with a capability summary ------------------------------------------
Status.stage(reg, "hello", function()
	local hello = Net.serverGet(ReplicatedStorage, "Hello")
	local lim = Net.LIMITS.Hello
	local limiter = Net.newLimiter(lim.rate, lim.burst)
	hello.OnServerEvent:Connect(function(player: Player, payload: any)
		if not Net.allow(limiter, player.UserId, os.clock()) then
			return
		end
		local ok, why = Net.validateHello(payload)
		if not ok then
			warn(string.format("%s|server|hello|rejected|%s: %s", Config.TAG, player.Name, tostring(why)))
			return
		end
		print(string.format("%s|server|client|info|%s v%s %s", Config.TAG, player.Name, payload.version, tostring(payload.summary or "")))
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		Net.forget(limiter, player.UserId)
	end)
	return "ok", "listening"
end)

-- Bench services (T9 referee, T10 training) -------------------------------------------
task.spawn(function()
	local Referee = optionalRequire("Referee")
	if Referee then
		Status.stage(reg, "referee", function()
			return Referee.start(reg)
		end)
	else
		Status.set(reg, "referee", "skipped", "Referee module not present")
	end
	local Training = optionalRequire("Training")
	if Training then
		Status.stage(reg, "training", function()
			return Training.start(reg, pool)
		end)
	else
		Status.set(reg, "training", "skipped", "Training module not present")
	end
end)

-- Periodic pool summary for the HUD.
task.spawn(function()
	while true do
		task.wait(1)
		statusFolder:SetAttribute("ServerPool", WorkerPool.describe(pool))
		statusFolder:SetAttribute("ServerBusyActors", WorkerPool.busyCount(pool))
	end
end)
