--!strict
-- Universe at Home: Meadow :: WorkerMain
--
-- The body of every worker Actor (server and client). The worker Script inside the
-- Actor template requires this module and its job-handler module in the serial
-- phase (require is not allowed while desynchronized, scripting/multithreading.md),
-- then calls WorkerMain.run. See WorkerPool for the protocol.

local WorkerMain = {}

type Handler = {
	parallel: ((payload: any, state: { [string]: any }) -> any)?,
	serial: ((payload: any, result: any, state: { [string]: any }) -> any)?,
}

function WorkerMain.run(actor: Actor, handlers: { [string]: Handler })
	local folder = actor.Parent
	local doneInstance = if folder then folder:FindFirstChild("Done") else nil
	if not doneInstance or not doneInstance:IsA("BindableEvent") then
		warn("[Worker " .. actor.Name .. "] no Done event next to the actor; worker idle")
		return
	end
	local done = doneInstance :: BindableEvent
	local name = actor.Name
	local state: { [string]: any } = {}
	actor:BindToMessageParallel("Job", function(jobId: number, kind: string, payload: any)
		local t0 = os.clock()
		local h = handlers[kind]
		if not h then
			done:Fire(name, jobId, false, "unknown job kind " .. tostring(kind), 0)
			return
		end
		local ok, result = true, nil
		local parallel = h.parallel
		if parallel then
			ok, result = pcall(parallel, payload, state)
		end
		local serial = h.serial
		if ok and serial then
			task.synchronize()
			ok, result = pcall(serial, payload, result, state)
		end
		done:Fire(name, jobId, ok, result, (os.clock() - t0) * 1000)
	end)
	done:Fire(name, 0, true, "hello", 0)
end

return WorkerMain
