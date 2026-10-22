--!strict
-- Universe at Home: Meadow :: client worker (template, Script with RunContext Client)
--
-- Lives disabled in ReplicatedStorage.DemoWorkers.ClientWorker (an Actor); a Script
-- with RunContext Client would run right there on every client, so the template is
-- saved Disabled. The client coordinator (ClientActors) clones the Actor into a
-- client-side folder in ReplicatedStorage, where RunContext Client scripts run
-- (scripting/locations.md), and enables this Script. The file name ends in
-- .server.luau only because Rojo emits a Script for it; Worker.meta.json sets
-- RunContext = Client.

local actor = script:GetActor()
if not actor then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Demo = ReplicatedStorage:WaitForChild("Demo")
local WorkerMain = require(Demo:WaitForChild("WorkerMain"))
local jobs = require(Demo:WaitForChild("ClientJobs"))
WorkerMain.run(actor, jobs :: any)
