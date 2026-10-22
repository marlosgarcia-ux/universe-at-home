--!strict
-- Universe at Home: Meadow :: client entry point (StarterPlayerScripts.Client.Main)
--
-- Builds the HUD (metrics, world progress, self-check and capabilities, bench), flies
-- the camera over the valley while the server writes the terrain, then hands the
-- camera back when the character spawns. Grass rings, client Actors and the stress
-- bench start as separate stages; each one reports to the self-check panel and to
-- Output, and none can take the others down.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Stats = game:GetService("Stats")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local Status = require(Demo:WaitForChild("Status"))
local Metrics = require(Demo:WaitForChild("Metrics"))
local Net = require(Demo:WaitForChild("Net"))

local Client = script.Parent :: Instance
local player = Players.LocalPlayer
local reg = Status.registry("client")
Status.set(reg, "client_start", "info", "Universe at Home: Meadow " .. Config.VERSION)

-- Shared client context handed to every client stage module.
local ctx: { [string]: any } = {
	reg = reg,
	config = Config,
	counters = {
		uploads = 0, -- WritePixelsBuffer calls this frame
		uploadBytes = 0,
		editableImages = 0, -- live EditableImages created by the demo
		editablePixels = 0, -- their pixel area
		editableMeshes = 0,
		grassTriangles = 0,
	},
	clientPool = nil,
}

local function optionalRequire(name: string): any
	local m = Client:FindFirstChild(name)
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

-- HUD ------------------------------------------------------------------------------
local Hud: any = nil
local hud: any = nil
Status.stage(reg, "hud", function()
	Hud = require(script.Parent:WaitForChild("Hud"))
	hud = Hud.new()
	ctx.hud = hud
	ctx.Hud = Hud
	return "ok", "metrics, progress, capabilities, bench"
end)

local function hudCall(fn: (any) -> ())
	if hud then
		pcall(fn, hud)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.H then
		hudCall(function(h)
			Hud.toggle(h)
		end)
	end
end)

-- Metrics ----------------------------------------------------------------------------
local frames = Metrics.ring(120)
local lastUploads, lastUploadBytes = 0, 0
RunService.RenderStepped:Connect(function(dt: number)
	Metrics.push(frames, dt)
	lastUploads = ctx.counters.uploads
	lastUploadBytes = ctx.counters.uploadBytes
	ctx.counters.uploads = 0
	ctx.counters.uploadBytes = 0
end)

local function mem(tag: Enum.DeveloperMemoryTag): string
	local ok, v = pcall(function(): number
		return Stats:GetMemoryUsageMbForTag(tag)
	end)
	return if ok then Metrics.formatMb(v) else "n/a"
end

local statusFolder = ReplicatedStorage:WaitForChild("DemoStatus", 30)

local function updateMetrics()
	local fps = Metrics.fps(frames)
	local p99 = Metrics.percentile(frames, 0.99) * 1000
	hudCall(function(h)
		Hud.setMetric(h, "FPS", string.format("<b>%.0f</b>  (p99 frame %.1f ms)", fps, p99))
		Hud.setMetric(h, "FrameTime", string.format("%.2f ms", Stats.FrameTime * 1000))
		Hud.setMetric(h, "Heartbeat", string.format("%.2f ms", Stats.HeartbeatTime * 1000))
		Hud.setMetric(h, "RenderCPU", string.format("%.2f ms", Stats.RenderCPUFrameTime * 1000))
		Hud.setMetric(h, "RenderGPU", string.format("%.2f ms", Stats.RenderGPUFrameTime * 1000))
		Hud.setMetric(h, "Triangles", string.format("%s  draws %d", Metrics.formatCount(Stats.SceneTriangleCount), Stats.SceneDrawcallCount))
		Hud.setMetric(h, "Memory", Metrics.formatMb(Stats:GetTotalMemoryUsageMb()))
		Hud.setMetric(h, "LuaHeap", mem(Enum.DeveloperMemoryTag.LuaHeap))
		Hud.setMetric(h, "GfxTexture", mem(Enum.DeveloperMemoryTag.GraphicsTexture))
		Hud.setMetric(h, "GfxMeshParts", mem(Enum.DeveloperMemoryTag.GraphicsMeshParts))
		Hud.setMetric(h, "GfxTerrain", mem(Enum.DeveloperMemoryTag.GraphicsTerrain))
		local c = ctx.counters
		Hud.setMetric(h, "Editables", string.format("%d images, %s px; %d meshes", c.editableImages, Metrics.formatCount(c.editablePixels), c.editableMeshes))
		Hud.setMetric(h, "Uploads", string.format("%d this frame (%s)", lastUploads, Metrics.formatCount(lastUploadBytes) .. " B"))
		local pool = ctx.clientPool
		local busy = if pool then string.format("%d busy of %d (%s)", pool.busyCount(), pool.size(), pool.mode()) else "not started"
		Hud.setMetric(h, "ClientActors", busy)
		if statusFolder then
			local sb = statusFolder:GetAttribute("ServerBusyActors")
			local sa = statusFolder:GetAttribute("ServerActors")
			Hud.setMetric(h, "ServerActors", string.format("%s busy of %s", tostring(sb or "?"), tostring(sa or "?")))
		end
		Hud.setMetric(h, "GrassTris", Metrics.formatCount(c.grassTriangles))
	end)
end

-- Capabilities panel: server mirror + client registry ---------------------------------
local function updateCapabilities()
	local entries: { { side: string, feature: string, state: string, detail: string } } = {}
	if statusFolder then
		for _, e in Status.fromAttributes(statusFolder:GetAttributes()) do
			table.insert(entries, { side = "server", feature = e.feature, state = e.state :: string, detail = e.detail })
		end
	end
	for _, e in Status.list(reg) do
		table.insert(entries, { side = "client", feature = e.feature, state = e.state :: string, detail = e.detail })
	end
	hudCall(function(h)
		Hud.setCapabilities(h, entries)
	end)
end

-- World progress ----------------------------------------------------------------------
local function updateProgress()
	if not statusFolder then
		hudCall(function(h)
			Hud.setProgress(h, 0, "No DemoStatus folder from the server (is the server script running?)")
		end)
		return
	end
	local ready = statusFolder:GetAttribute("WorldReady")
	local stage = statusFolder:GetAttribute("WorldStage") or "starting"
	local p = statusFolder:GetAttribute("WorldProgress") or 0
	local chunks = statusFolder:GetAttribute("WorldChunks") or 0
	local total = statusFolder:GetAttribute("WorldChunksTotal") or 0
	hudCall(function(h)
		if ready == true then
			Hud.hideProgress(h)
		else
			Hud.setProgress(h, tonumber(p) or 0, string.format("Generating the valley: %s  %d%%  (%s / %s chunks)", tostring(stage), math.floor((tonumber(p) or 0) * 100), tostring(chunks), tostring(total)))
		end
	end)
end

task.spawn(function()
	while true do
		pcall(updateMetrics)
		pcall(updateProgress)
		pcall(updateCapabilities)
		task.wait(Config.hud.refreshSeconds)
	end
end)

-- Camera: a slow orbit over the valley until the character exists ------------------------
Status.stage(reg, "camera", function()
	local camera = Workspace.CurrentCamera
	if not camera then
		return "fallback", "no CurrentCamera"
	end
	local t = 0
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function(dt: number)
		if player.Character then
			if conn then
				conn:Disconnect()
			end
			camera.CameraType = Enum.CameraType.Custom
			local hum = player.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				camera.CameraSubject = hum
			end
			return
		end
		t += dt
		camera.CameraType = Enum.CameraType.Scriptable
		local a = t * 0.05
		local eye = Vector3.new(math.cos(a) * 340, 190, math.sin(a) * 340)
		camera.CFrame = CFrame.lookAt(eye, Vector3.new(0, 60, 0))
	end)
	return "ok", "orbiting until the character spawns"
end)

-- Self-check on start: what the engine offers this client -------------------------------
Status.stage(reg, "editable_image", function()
	local AssetService = game:GetService("AssetService")
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(4, 4) })
	if not img then
		return "fallback", "CreateEditableImage returned nil (budget exhausted or APIs disabled)"
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(4, 4), buffer.create(64))
	img:Destroy()
	return "ok", "create, write and destroy work (max size 1024 documented)"
end, function(message: string)
	return "failed", "EditableImage unavailable; enable Allow Mesh / Image APIs in published places"
end)

Status.stage(reg, "editable_mesh", function()
	local AssetService = game:GetService("AssetService")
	local m = AssetService:CreateEditableMesh()
	if not m then
		return "fallback", "CreateEditableMesh returned nil (budget)"
	end
	local a = m:AddVertex(Vector3.new(0, 0, 0))
	local b = m:AddVertex(Vector3.new(1, 0, 0))
	local c = m:AddVertex(Vector3.new(0, 1, 0))
	m:AddTriangle(a, b, c)
	m:Destroy()
	return "ok", "create, add triangle and destroy work"
end, function(message: string)
	return "failed", "EditableMesh unavailable; enable Allow Mesh / Image APIs in published places"
end)

Status.stage(reg, "luau_speed", function()
	-- calibration kernel of docs/RUNTIME_AUDIT.md 6.6: constant writeu32 over 256 x 256
	local b = buffer.create(256 * 256 * 4)
	local t0 = os.clock()
	for o = 0, 256 * 256 * 4 - 4, 4 do
		buffer.writeu32(b, o, 0xFF336699)
	end
	local ms = (os.clock() - t0) * 1000
	ctx.calibrationMs = ms
	return "info", string.format("constant writeu32: %.2f ms per 64k px (x16 = %.1f ms per 1024^2; audit host 10.3 interp / 2.9 native)", ms, ms * 16)
end)

-- Later stages (grass, client Actors, bench): each module is optional ---------------------
task.spawn(function()
	local ClientActors = optionalRequire("ClientActors")
	if ClientActors then
		Status.stage(reg, "actors_client", function()
			return ClientActors.start(ctx)
		end)
	else
		Status.set(reg, "actors_client", "skipped", "ClientActors module not present")
	end
	local Grass = optionalRequire("Grass")
	if Grass then
		Status.stage(reg, "grass", function()
			return Grass.start(ctx)
		end)
	else
		Status.set(reg, "grass", "skipped", "Grass module not present")
	end
	local Bench = optionalRequire("Bench")
	if Bench then
		Status.stage(reg, "bench", function()
			return Bench.start(ctx)
		end)
	else
		Status.set(reg, "bench", "skipped", "Bench module not present")
	end
	-- Report to the server once the stages settled.
	task.wait(2)
	local hello = Net.clientGet(ReplicatedStorage, "Hello", 20) :: RemoteEvent?
	if hello then
		local okCount, total = 0, 0
		for _, e in Status.list(reg) do
			total += 1
			if e.state == "ok" or e.state == "info" then
				okCount += 1
			end
		end
		hello:FireServer({ version = Config.VERSION, summary = string.format("client features %d of %d ok", okCount, total) })
	end
	-- Self-check summary in Output.
	local lines = { "Self-check (client):" }
	for _, e in Status.list(reg) do
		table.insert(lines, string.format("  %-16s %-8s %s", e.feature, e.state, e.detail))
	end
	print(table.concat(lines, "\n"))
end)
