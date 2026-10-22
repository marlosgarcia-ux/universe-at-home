--!strict
-- Universe at Home: Planets :: client entry point (StarterPlayerScripts.Client.Main)
--
-- A stress test of EditableImages at planetary scale. Every surface pixel on screen is
-- generated at run time on worker Actors and streamed through EditableImages:
--   Terra and Selene   cube-sphere quadtree of up to 256 pooled patch meshes, each with
--                      colour, normal and roughness tiles in three shared atlases
--                      (SurfaceAppearance via CreateSurfaceAppearanceAsync)
--   every body         a raytraced impostor billboard (exact limb, atmosphere, rings)
--   Terra's clouds     a rotating shell from a 1024 x 512 atlas
--   space              six star faces and the sun sprite
-- All pixel writes go through one queue that refreshes one image per frame (the engine's
-- rule). Each stage reports to the HUD status list; none can take the others down.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local Hud = require(script.Parent:WaitForChild("Hud"))
local hud = Hud.new()
Hud.set(hud, "client", "info", "Universe at Home: Planets, starting")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Bodies = require(Planets:WaitForChild("Bodies")) :: any
local Uploader = require(script.Parent:WaitForChild("Uploader"))
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local PlanetLod = require(script.Parent:WaitForChild("PlanetLod"))
local Impostors = require(script.Parent:WaitForChild("Impostors"))
local Sky = require(script.Parent:WaitForChild("Sky"))
local CloudLayer = require(script.Parent:WaitForChild("CloudLayer"))
local Flight = require(script.Parent:WaitForChild("Flight"))
local Workers = require(script.Parent:WaitForChild("Workers"))

local Config = require(Planets:WaitForChild("Config"))
local MESH_ON: number = Config.meshOn -- distance / radius below which a rocky body gets its mesh
local MESH_OFF: number = Config.meshOff -- and above which it goes back to the impostor (hysteresis)

local player = Players.LocalPlayer
local cam = Workspace.CurrentCamera
local folder = Instance.new("Folder")
folder.Name = "Planets"
folder.Parent = Workspace

local terra = Bodies.get("terra")
local U = Uploader.new()
local flight = Flight.new(cam)

-- state shared by the frame loop and the setup thread
local pool: MeshPool.Pool? = nil
local lod: PlanetLod.Lod? = nil
local imps: Impostors.Manager? = nil
local sky: Sky.SkyState? = nil
local clouds: CloudLayer.Layer? = nil
local cloudsOn = true
local impostorOnly = false
local sunCycle = false
local workersNote: string? = nil
local workers = Workers.start(Config.workers, function(note: string)
	workersNote = note
end)

local function stage(name: string, fn: () -> (string, string)): boolean
	local ok, state, detail = pcall(fn)
	if ok then
		Hud.set(hud, name, state, detail)
		return state ~= "failed"
	end
	Hud.set(hud, name, "failed", tostring(state))
	return false
end

-- setup: waits for the workers (so heavy jobs never run on the main thread at start), then
-- builds every stage
task.spawn(function()
	local t0 = os.clock()
	while workersNote == nil and os.clock() - t0 < 20 do
		task.wait(0.1)
	end
	Hud.set(hud, "workers", if workers.available then "ok" else "fallback", workersNote or "timed out; serial mode")
	stage("sky", function()
		local s = Sky.new(U, workers, folder)
		sky = s
		return "ok", s.note
	end)
	stage("atlases", function()
		local p, err = MeshPool.new(U, folder)
		if not p then
			return "failed", tostring(err)
		end
		pool = p
		lod = PlanetLod.new(p, U, workers)
		return if p.mode == "pbr" then "ok" else "fallback", p.note
	end)
	stage("impostors", function()
		local m = Impostors.new(U, workers, folder)
		imps = m
		task.spawn(function()
			Impostors.buildCaches(m)
			Hud.set(hud, "sphere caches", if m.cachesReady == #m.items then "ok" else "fallback", string.format("%d of %d bodies cached on the workers", m.cachesReady, #m.items))
			local t0 = os.clock()
			Impostors.buildAtmos(m)
			Hud.set(hud, "atmosphere", if m.atmosReady == 2 then "ok" else "fallback", string.format("%d of 2 scattering table sets built in %.1f s", m.atmosReady, os.clock() - t0))
		end)
		return "ok", string.format("%d raytraced billboards", #m.items)
	end)
	stage("clouds", function()
		local layer, err = CloudLayer.new(U, workers, folder, terra)
		if not layer then
			return "failed", tostring(err)
		end
		clouds = layer
		return if layer.part then "ok" else "fallback", layer.note
	end)
	Hud.set(hud, "client", "ok", "ready: fly with W A S D and the right mouse button")
	Hud.debug.lod = lod
	Hud.debug.pool = pool
	Hud.debug.imps = imps
	Hud.debug.sky = sky
	Hud.debug.clouds = clouds
	Hud.debug.ready = true
end)
Hud.debug.U = U
Hud.debug.flight = flight
Hud.debug.workers = workers

Flight.preset(flight, 1)

-- focus: the nearest rocky body close enough for its mesh
local function chooseFocus(current: any?): any?
	if impostorOnly then
		return nil
	end
	local camPos = cam.CFrame.Position
	local best, bestD = nil, math.huge
	for _, b in Bodies.list do
		if b.kind == "rocky" then
			local D = (camPos - Vector3.new(b.px, b.py, b.pz)).Magnitude / b.radius
			local limit = if b == current then MESH_OFF else MESH_ON
			if D < limit and D < bestD then
				best, bestD = b, D
			end
		end
	end
	return best
end

-- memory-budget probe: allocate 256 x 256 images until the engine refuses (or a cap)
local probing = false
local function probeBudget()
	if probing then
		return
	end
	probing = true
	Hud.set(hud, "budget probe", "info", "allocating 256 x 256 EditableImages ...")
	task.spawn(function()
		local made: { EditableImage } = {}
		local cap = 200
		local refused = false
		for _ = 1, cap do
			local ok, img = pcall(function()
				return AssetService:CreateEditableImage({ Size = Vector2.new(256, 256) })
			end)
			if not ok or not img then
				refused = true
				break
			end
			table.insert(made, img :: EditableImage)
			if #made % 20 == 0 then
				task.wait()
			end
		end
		local extra = #made * 65536
		for _, img in made do
			img:Destroy()
		end
		local own = (if pool then pool.stats.pixels else 0) + (if imps then Impostors.pixels(imps) else 0) + (if sky then sky.pixels else 0) + (if clouds then clouds.pixels else 0)
		local detail = string.format(
			"%s after %.1f Mpx more (%.0f MB) on top of the demo's %.1f Mpx: about %.1f Mpx (%.0f MB) usable here",
			if refused then "refused" else "no refusal (cap reached, likely Studio)",
			extra / 1e6,
			extra * 4 / 1048576,
			own / 1e6,
			(extra + own) / 1e6,
			(extra + own) * 4 / 1048576
		)
		Hud.set(hud, "budget probe", if refused then "ok" else "info", detail)
		probing = false
	end)
end

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local k = input.KeyCode
	local L = lod
	if k == Enum.KeyCode.H then
		Hud.toggle(hud)
	elseif k == Enum.KeyCode.One then
		Flight.preset(flight, 1)
	elseif k == Enum.KeyCode.Two then
		Flight.preset(flight, 2)
	elseif k == Enum.KeyCode.Three then
		Flight.preset(flight, 3)
	elseif k == Enum.KeyCode.Four then
		Flight.preset(flight, 4)
	elseif k == Enum.KeyCode.Five then
		Flight.preset(flight, 5)
	elseif k == Enum.KeyCode.Six then
		Flight.preset(flight, 6)
	elseif k == Enum.KeyCode.F and L then
		L.opts.fades = not L.opts.fades
	elseif k == Enum.KeyCode.T and L then
		L.opts.tint = not L.opts.tint
		PlanetLod.refreshTint(L)
	elseif k == Enum.KeyCode.L and L then
		L.opts.frozen = not L.opts.frozen
	elseif k == Enum.KeyCode.B and L then
		local stress = L.opts.splitPx > Config.stressSplitPx
		L.opts.splitPx = if stress then Config.stressSplitPx else Config.splitPx
		L.opts.capacity = math.min(if stress then Config.stressCapacity else Config.capacity, 256)
	elseif k == Enum.KeyCode.G then
		impostorOnly = not impostorOnly
	elseif k == Enum.KeyCode.N and L then
		L.opts.greenUp = not L.opts.greenUp
		PlanetLod.reset(L)
	elseif k == Enum.KeyCode.V and pool then
		MeshPool.setFlipV(pool :: MeshPool.Pool, not (pool :: MeshPool.Pool).flipV)
	elseif k == Enum.KeyCode.K then
		sunCycle = not sunCycle
	elseif k == Enum.KeyCode.M then
		cloudsOn = not cloudsOn
	elseif k == Enum.KeyCode.X then
		probeBudget()
	end
end)

-- frame loop
local frames, frameAcc, luauAcc = 0, 0, 0
local lastHud = 0
local lastGenerated, lastRateClock, tileRate = 0, os.clock(), 0
RunService.RenderStepped:Connect(function(dt: number)
	local t0 = os.clock()
	Flight.update(flight, dt)
	if sunCycle then
		Lighting.ClockTime = (Lighting.ClockTime + dt * 0.35) % 24
	end
	local sun = Lighting:GetSunDirection()
	local L = lod
	if L then
		local want = chooseFocus(L.body)
		if want ~= L.body then
			-- fade the old mesh out before switching
			if L.body == nil or L.alpha <= 0.001 then
				PlanetLod.setBody(L, want)
			else
				L.alphaTarget = 0
			end
		elseif L.body then
			L.alphaTarget = 1
		end
		PlanetLod.update(L, cam, dt, 0.004)
	end
	local cloudAngle = if clouds then clouds.angle else 0
	if imps then
		Impostors.update(imps, cam, sun, if L then L.body else nil, if L then L.alpha else 0, cloudAngle, os.clock())
	end
	if clouds then
		CloudLayer.update(clouds, terra, dt, if L and L.body == terra then L.alpha else 0, cloudsOn)
	end
	if sky then
		local alt = if flight.nearest == terra then flight.altitude else 1e9
		Sky.update(sky, cam, alt, terra.radius)
	end
	Uploader.step(U)
	-- stats
	frames += 1
	frameAcc += dt
	luauAcc += os.clock() - t0
	local now = os.clock()
	if now - lastHud > 0.25 then
		local fps = frames / math.max(frameAcc, 1e-6)
		local ms = frameAcc / math.max(frames, 1) * 1000
		local ours = luauAcc / math.max(frames, 1) * 1000
		frames, frameAcc, luauAcc = 0, 0, 0
		lastHud = now
		local lines = {}
		table.insert(lines, string.format("FPS %3.0f   frame %5.1f ms   our main-thread Luau %4.2f ms", fps, ms, ours))
		table.insert(lines, string.format("camera  %s, altitude %.0f studs, speed x%.2f", flight.nearest.name, flight.altitude, flight.speedScale))
		if L then
			local shown, cached, gen, up = PlanetLod.counts(L)
			if now - lastRateClock > 1 then
				tileRate = (L.stats.generated - lastGenerated) / (now - lastRateClock)
				lastGenerated = L.stats.generated
				lastRateClock = now
			end
			table.insert(
				lines,
				string.format(
					"mesh    %s %3.0f%%   patches shown %d  cached %d  generating %d  uploading %d   deepest L%d%s",
					if L.body then L.body.name else "none",
					L.alpha * 100,
					shown,
					cached,
					gen,
					up,
					L.stats.deepest,
					if L.stats.limited then " (atlas full)" else ""
				)
			)
			table.insert(
				lines,
				string.format(
					"tiles   %d generated (%.1f/s), %.0f ms mean on workers, %d swaps, %d evicted, %d failed%s",
					L.stats.generated,
					tileRate,
					L.stats.genMs / math.max(1, L.stats.generated),
					L.stats.swaps,
					L.stats.evicted,
					L.stats.failed,
					if L.stats.lastError then " (" .. string.sub(L.stats.lastError :: string, 1, 60) .. ")" else ""
				)
			)
			table.insert(lines, string.format("options fades %s   tint %s   frozen %s   stress %s   green %s   UV flip %s", if L.opts.fades then "on" else "off", if L.opts.tint then "on" else "off", if L.opts.frozen then "yes" else "no", if L.opts.splitPx < Config.splitPx then "on" else "off", if L.opts.greenUp then "up" else "down", if pool and pool.flipV then "on" else "off"))
		end
		local ws = workers.stats
		table.insert(lines, string.format("workers %s, %d ready, %d sent, %d done, %d inline, %d lost, %d in flight", workers.mode, workers.readyCount, ws.sent, ws.done, ws.inline, ws.lost, workers.inflight))
		local us = U.stats
		table.insert(lines, string.format("uploads %d flushes (one image per frame), %d rects, %.0f MB, backlog %d, last %s%s", us.flushes, us.rects, us.bytes / 1048576, Uploader.backlog(U), us.lastImage, if us.errors > 0 then string.format(", %d errors: %s", us.errors, tostring(us.lastError)) else ""))
		if imps then
			local parts = {}
			for _, item in imps.items do
				table.insert(parts, string.format("%s %dpx %.0fms", item.def.name, item.n, item.ms))
			end
			table.insert(lines, string.format("impost. %d renders, caches %d/%d   %s", imps.stats.renders, imps.cachesReady, #imps.items, table.concat(parts, "  ")))
		end
		local px = (if pool then pool.stats.pixels else 0) + (if imps then Impostors.pixels(imps) else 0) + (if sky then sky.pixels else 0) + (if clouds then clouds.pixels else 0)
		local tex = 0
		pcall(function()
			tex = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsTexture)
		end)
		table.insert(lines, string.format("images  %.2f Mpx live in EditableImages = %.1f MB RGBA   engine texture memory %.0f MB", px / 1e6, px * 4 / 1048576, tex))
		if pool then
			table.insert(lines, string.format("surface %s   mesh %s   slots %d of 256", pool.mode, pool.meshMode, #pool.slots))
		end
		Hud.stats(hud, table.concat(lines, "\n"))
	end
end)

player.CharacterAdded:Connect(function()
	-- no character is used; keep the scripted camera
	cam.CameraType = Enum.CameraType.Scriptable
end)
