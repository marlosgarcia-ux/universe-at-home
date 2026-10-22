--!strict
-- Universe at Home: Meadow :: ClientActors
--
-- Spawns the client worker pools (docs/DEMO.md section 5): 8 render workers (tile
-- jobs: shell masks, raster, ALLAN, matte), 4 grass workers (patch geometry, sheet
-- heights) and 1 wind worker. Templates live disabled in ReplicatedStorage.DemoWorkers:
--   1. ClientWorker (Script, RunContext Client) cloned into a client-side folder in
--      ReplicatedStorage, where RunContext Client scripts run;
--   2. if no worker answers, ClientWorkerLocal (LocalScript) cloned into PlayerScripts;
--   3. if still nothing, serial mode: every job runs inline with the same code.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))
local Status = require(Demo:WaitForChild("Status"))

local ClientActors = {}

local function spawnPool(name: string, count: number, handlers: any, timeout: number): (WorkerPool.Pool, string)
	local templates = ReplicatedStorage:WaitForChild("DemoWorkers", 10)
	local pool = WorkerPool.new(name, handlers, timeout)
	if not templates then
		return pool, "no ReplicatedStorage.DemoWorkers; serial"
	end
	local scriptTemplate = templates:FindFirstChild("ClientWorker")
	if scriptTemplate then
		local folder = ReplicatedStorage:FindFirstChild("ClientWorkerPools")
		if not folder then
			local f = Instance.new("Folder")
			f.Name = "ClientWorkerPools"
			f.Parent = ReplicatedStorage
			folder = f
		end
		assert(folder)
		local ready = WorkerPool.spawn(pool, scriptTemplate, folder, count, 6)
		if ready > 0 then
			return pool, string.format("%d/%d Script(RunContext Client) Actors", ready, count)
		end
		WorkerPool.destroy(pool)
	end
	local localTemplate = templates:FindFirstChild("ClientWorkerLocal")
	local playerScripts = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
	if localTemplate and playerScripts then
		local ready = WorkerPool.spawn(pool, localTemplate, playerScripts, count, 6)
		if ready > 0 then
			return pool, string.format("%d/%d LocalScript Actors (RunContext Client variant did not answer)", ready, count)
		end
		WorkerPool.destroy(pool)
	end
	return pool, "no worker answered; serial mode"
end

function ClientActors.start(ctx: { [string]: any }): (string, string)
	local Config = ctx.config
	local reg = ctx.reg
	local jobs = require(Demo:WaitForChild("ClientJobs")) :: any
	local timeout = Config.actors.jobTimeout
	local render, renderNote = spawnPool("Render", Config.actors.clientRender, jobs, timeout)
	local grass, grassNote = spawnPool("Grass", Config.actors.clientGrass, jobs, timeout)
	local wind, windNote = spawnPool("Wind", Config.actors.clientWind, jobs, timeout)
	ctx.pools = { render = render, grass = grass, wind = wind }
	ctx.clientPool = {
		busyCount = function(): number
			return WorkerPool.busyCount(render) + WorkerPool.busyCount(grass) + WorkerPool.busyCount(wind)
		end,
		size = function(): number
			return render.readyCount + grass.readyCount + wind.readyCount
		end,
		mode = function(): string
			if render.available and grass.available and wind.available then
				return "actors"
			elseif render.available or grass.available then
				return "partial"
			end
			return "serial"
		end,
	}
	Status.set(reg, "actors_render", if render.available then "ok" else "fallback", renderNote)
	Status.set(reg, "actors_grass", if grass.available then "ok" else "fallback", grassNote)
	Status.set(reg, "actors_wind", if wind.available then "ok" else "fallback", windNote)
	local all = render.available and grass.available and wind.available
	return if all then "ok" else "fallback", string.format("render %d, grass %d, wind %d ready", render.readyCount, grass.readyCount, wind.readyCount)
end

return ClientActors
