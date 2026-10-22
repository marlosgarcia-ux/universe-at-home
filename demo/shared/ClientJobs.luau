--!strict
-- Universe at Home: Meadow :: ClientJobs
--
-- Job handlers of the client worker Actors (render x8, grass x4, wind x1), also run
-- inline by WorkerPool's serial fallback. Pure work in `parallel`; engine writes
-- (BulkMoveTo, WritePixelsBuffer) only in `serial` or after task.synchronize().
--
--   grassPatch    GrassGen.patch arrays for one ring-0 variant
--   shellMask     one shell layer's alpha mask (Raster, exact coverage) as a buffer
--   sheetHeights  terrain heights under the ring-1 sheet (Workspace:Raycast is Safe)
--   windSet       installs/updates the wind loop: Heartbeat:ConnectParallel computes
--                 every patch and shell CFrame in parallel, then task.synchronize()
--                 and one Workspace:BulkMoveTo
--   bench jobs    raster tiles, ALLAN rows, matte (see Bench.luau)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local GrassGen = require(Demo:WaitForChild("GrassGen"))
local Config = require(Demo:WaitForChild("Config"))

local Jobs: { [string]: any } = {}

Jobs.grassPatch = {
	parallel = function(p: any, _state: { [string]: any }): any
		return GrassGen.patch(p)
	end,
}

Jobs.shellMask = {
	parallel = function(p: any, _state: { [string]: any }): any
		local t0 = os.clock()
		local buf, how = GrassGen.renderMask(p.k, p.layers, p.size, p.seed, p.count, p.radius, p.lean)
		return { k = p.k, pixels = buf, how = how, ms = (os.clock() - t0) * 1000 }
	end,
}

Jobs.sheetHeights = {
	parallel = function(p: any, _state: { [string]: any }): any
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { Workspace.Terrain }
		params.IgnoreWater = true
		local n, half, spacing = p.n, p.half, p.spacing
		local out = buffer.create(n * n * 4)
		local misses, buried = 0, 0
		local down = Vector3.new(0, -600, 0)
		local last = p.baseY - 4
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local x = p.cx + (i - half) * spacing
				local z = p.cz + (j - half) * spacing
				local hit = Workspace:Raycast(Vector3.new(x, 500, z), down, params)
				local h: number
				if hit then
					h = hit.Position.Y
					-- shells only on grass: elsewhere the sheet dips under the ground
					local m = hit.Material
					if m ~= Enum.Material.Grass and m ~= Enum.Material.LeafyGrass then
						h -= 3
						buried += 1
					end
					last = h
				else
					h = last - 3
					misses += 1
				end
				buffer.writef32(out, (j * n + i) * 4, h)
			end
		end
		return { cx = p.cx, cz = p.cz, heights = out, misses = misses, buried = buried, stamp = p.stamp }
	end,
}

-- Wind -----------------------------------------------------------------------------
-- kind[i] = 0: a ring-0 patch, tilted about the axis across the wind at its base;
-- kind[i] = k >= 1: shell layer k (of K), shifted along the wind by amp * (k/K)^2.
local function gust(px: number, pz: number, t: number, w: any): number
	local phase = (px * w.dirX + pz * w.dirZ) / w.wavelength - t * w.speed
	return 0.55 + 0.35 * math.sin(phase * 6.283185307179586) + 0.12 * math.sin(phase * 14.45 + 1.7)
end

Jobs.windSet = {
	serial = function(p: any, _r: any, state: { [string]: any }): any
		state.windParts = p.parts
		state.windBase = p.base
		state.windKind = p.kind
		state.windParams = p.params
		if not state.windConn then
			state.windFrames = 0
			state.windConn = RunService.Heartbeat:ConnectParallel(function()
				local parts = state.windParts :: { BasePart }
				local base = state.windBase :: { CFrame }
				local kind = state.windKind :: { number }
				local w = state.windParams
				if not parts or #parts == 0 then
					return
				end
				local t = os.clock()
				local n = #parts
				local out = table.create(n)
				local axisX, axisZ = -w.dirZ, w.dirX
				local layers = w.layers
				for i = 1, n do
					local cf = base[i]
					local pos = cf.Position
					local g = gust(pos.X, pos.Z, t, w)
					local k = kind[i]
					if k == 0 then
						local localAxis = cf:VectorToObjectSpace(Vector3.new(axisX, 0, axisZ))
						out[i] = cf * CFrame.fromAxisAngle(localAxis, w.strength * g)
					else
						local f = k / layers
						local s = w.shellAmp * f * f * g
						out[i] = cf + Vector3.new(w.dirX * s, 0, w.dirZ * s)
					end
				end
				task.synchronize()
				pcall(function()
					Workspace:BulkMoveTo(parts, out, Enum.BulkMoveMode.FireCFrameChanged)
				end)
				state.windFrames += 1
			end)
		end
		return #p.parts
	end,
}

Jobs.windStats = {
	parallel = function(_p: any, state: { [string]: any }): any
		return { frames = state.windFrames or 0, parts = if state.windParts then #state.windParts else 0 }
	end,
}

-- Bench jobs live in BenchJobs (added in M3); merged here so one worker script serves all.
local benchModule = Demo:FindFirstChild("BenchJobs")
local okBench, BenchJobs = false, nil :: any
if benchModule and benchModule:IsA("ModuleScript") then
	okBench, BenchJobs = pcall(require, benchModule)
end
if okBench and type(BenchJobs) == "table" then
	for k, v in BenchJobs do
		Jobs[k] = v
	end
end

Jobs.ping = {
	parallel = function(p: any, _state: { [string]: any }): any
		return { echo = p, version = Config.VERSION }
	end,
}

return Jobs
