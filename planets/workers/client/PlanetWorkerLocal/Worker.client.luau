--!strict
-- Universe at Home: Planets :: client worker (template, LocalScript variant)
--
-- Used only if no RunContext Client worker answers: the client clones this Actor into
-- PlayerScripts, where LocalScripts run, and enables the script.

local actor = script:GetActor()
if not actor then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Planets = ReplicatedStorage:WaitForChild("Planets")
local WorkerMain = require(Planets:WaitForChild("WorkerMain")) :: any
local jobs = require(Planets:WaitForChild("PlanetJobs")) :: any
WorkerMain.run(actor, jobs)
