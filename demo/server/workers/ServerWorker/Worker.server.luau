--!strict
-- Universe at Home: Meadow :: server worker (template)
--
-- Lives disabled in ServerScriptService.Workers.ServerWorker (an Actor). The server
-- coordinator clones the Actor, enables this Script (RunContext Server) and parents
-- the clone under ServerScriptService.WorkerPools, where it runs. Requires happen
-- here, in the serial phase; WorkerMain binds the parallel message handler.

local actor = script:GetActor()
if not actor then
	return
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local WorkerMain = require(ReplicatedStorage:WaitForChild("Demo"):WaitForChild("WorkerMain"))
local jobs = require(ServerScriptService:WaitForChild("Server"):WaitForChild("ServerJobs"))
WorkerMain.run(actor, jobs :: any)
