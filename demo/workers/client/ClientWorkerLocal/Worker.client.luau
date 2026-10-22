--!strict
-- Universe at Home: Meadow :: client worker (template, LocalScript variant)
--
-- Fallback for ClientWorker: LocalScripts never run in ReplicatedStorage, and run in
-- Players.LocalPlayer.PlayerScripts (scripting/locations.md). If the RunContext
-- Client variant does not answer, ClientActors clones this Actor into PlayerScripts
-- and enables this LocalScript.

local actor = script:GetActor()
if not actor then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Demo = ReplicatedStorage:WaitForChild("Demo")
local WorkerMain = require(Demo:WaitForChild("WorkerMain"))
local jobs = require(Demo:WaitForChild("ClientJobs"))
WorkerMain.run(actor, jobs :: any)
