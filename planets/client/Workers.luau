--!strict
-- Universe at Home: Planets :: Workers
--
-- Spawns the client worker Actors that generate tiles, caches, impostor bands, sky and
-- cloud faces (WorkerPool protocol, demo/shared/WorkerPool.luau). Templates live disabled
-- in ReplicatedStorage.PlanetWorkers:
--   1. PlanetWorker (Script, RunContext Client) cloned into a client-side folder in
--      ReplicatedStorage, where RunContext Client scripts run;
--   2. if none answers, PlanetWorkerLocal (LocalScript) cloned into PlayerScripts;
--   3. if still nothing, serial mode: every job runs inline with the same code.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local Jobs = require(Planets:WaitForChild("PlanetJobs")) :: any

local Workers = {}

-- Returns the pool (usable at once: jobs run inline until workers answer) and starts the
-- Actors in the background. `onReady(note)` runs once the pool settled.
function Workers.start(count: number, onReady: (string) -> ()): any
	local pool = WorkerPool.new("Planets", Jobs, 30)
	task.spawn(function()
		local templates = ReplicatedStorage:WaitForChild("PlanetWorkers", 10)
		if not templates then
			onReady("no ReplicatedStorage.PlanetWorkers; serial mode")
			return
		end
		local scriptTemplate = templates:FindFirstChild("PlanetWorker")
		if scriptTemplate then
			local folder = ReplicatedStorage:FindFirstChild("PlanetWorkerPools")
			if not folder then
				local f = Instance.new("Folder")
				f.Name = "PlanetWorkerPools"
				f.Parent = ReplicatedStorage
				folder = f
			end
			local ready = WorkerPool.spawn(pool, scriptTemplate, folder, count, 8)
			if ready > 0 then
				onReady(string.format("%d of %d Script (RunContext Client) Actors", ready, count))
				return
			end
			WorkerPool.destroy(pool)
		end
		local localTemplate = templates:FindFirstChild("PlanetWorkerLocal")
		local playerScripts = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
		if localTemplate and playerScripts then
			local ready = WorkerPool.spawn(pool, localTemplate, playerScripts, count, 8)
			if ready > 0 then
				onReady(string.format("%d of %d LocalScript Actors", ready, count))
				return
			end
			WorkerPool.destroy(pool)
		end
		onReady("no worker answered; serial mode (generation runs on the main thread)")
	end)
	return pool
end

return Workers
