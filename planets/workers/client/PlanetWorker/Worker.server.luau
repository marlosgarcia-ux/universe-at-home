--!strict
-- Universe at Home: Planets :: client worker (template, Script with RunContext Client)
--
-- Lives disabled in ReplicatedStorage.PlanetWorkers.PlanetWorker (an Actor). The client
-- (Workers.luau) clones the Actor into a client-side folder in ReplicatedStorage, where
-- RunContext Client scripts run, and enables this Script. The file name ends in
-- .server.luau only because Rojo emits a Script for it; Worker.meta.json sets
-- RunContext = Client.

local actor = script:GetActor()
if not actor then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Planets = ReplicatedStorage:WaitForChild("Planets")
local WorkerMain = require(Planets:WaitForChild("WorkerMain")) :: any
local jobs = require(Planets:WaitForChild("PlanetJobs")) :: any
WorkerMain.run(actor, jobs)
