--!strict
-- Universe at Home: Meadow :: WorkerPool
--
-- A pool of Actors cloned from a template, used the same way on the server
-- (worldgen, rocks, training) and on the client (tiles, grass, wind).
--
-- Protocol (docs/DEMO.md section 5):
--   coordinator -> worker   actor:SendMessage("Job", jobId, kind, payload)
--   worker                  BindToMessageParallel: handler.parallel(payload, state) runs
--                           desynchronized; if the handler has a serial part the worker
--                           calls task.synchronize() and runs handler.serial (engine
--                           writes such as WriteVoxels, WritePixelsBuffer, mesh edits)
--   worker -> coordinator   pool.Done:Fire(workerName, jobId, ok, result, ms)
--                           (BindableEvent:Fire is Safe in the dump; payloads arrive as
--                           copies, buffers included, so jobs return small tiles)
-- jobId 0 is the worker's hello. Payloads and results must be message-safe (numbers,
-- strings, booleans, buffers, Enum values, Instances, tables of those).
--
-- Fail soft: workers that never say hello leave the pool in "serial" mode, where every
-- job runs inline in the coordinator with the same handler code; a job that does not
-- come back within the timeout is redone inline. Callers never need to know.

local RunService = game:GetService("RunService")

local WorkerPool = {}

export type Handler = {
	parallel: ((payload: any, state: { [string]: any }) -> any)?,
	serial: ((payload: any, result: any, state: { [string]: any }) -> any)?,
}
export type Handlers = { [string]: Handler }
export type Callback = (ok: boolean, result: any, ms: number, worker: string) -> ()

type Job = {
	id: number,
	kind: string,
	payload: any,
	callback: Callback?,
	worker: string,
	sent: number,
}

export type Pool = {
	name: string,
	handlers: Handlers,
	folder: Instance?,
	done: BindableEvent?,
	workers: { Actor },
	byName: { [string]: Actor },
	ready: { [string]: boolean },
	busy: { [string]: number },
	readyCount: number,
	available: boolean,
	mode: string,
	nextId: number,
	pending: { [number]: Job },
	inflight: number,
	timeout: number,
	state: { [string]: any },
	stats: { sent: number, done: number, failed: number, lost: number, inline: number, ms: number },
	connections: { RBXScriptConnection },
	lastError: string?,
}

function WorkerPool.new(name: string, handlers: Handlers, timeout: number?): Pool
	return {
		name = name,
		handlers = handlers,
		folder = nil,
		done = nil,
		workers = {},
		byName = {},
		ready = {},
		busy = {},
		readyCount = 0,
		available = false,
		mode = "serial",
		nextId = 0,
		pending = {},
		inflight = 0,
		timeout = timeout or 20,
		state = {},
		stats = { sent = 0, done = 0, failed = 0, lost = 0, inline = 0, ms = 0 },
		connections = {},
		lastError = nil,
	}
end

-- Runs a job inline (serial mode, or a lost job). Never throws.
local function runInline(pool: Pool, kind: string, payload: any): (boolean, any, number)
	local t0 = os.clock()
	local h = pool.handlers[kind]
	if not h then
		return false, "unknown job kind " .. kind, 0
	end
	local ok, result = true, nil
	if h.parallel then
		ok, result = pcall(h.parallel, payload, pool.state)
	end
	if ok and h.serial then
		ok, result = pcall(h.serial, payload, result, pool.state)
	end
	pool.stats.inline += 1
	return ok, result, (os.clock() - t0) * 1000
end

local function finish(pool: Pool, job: Job, ok: boolean, result: any, ms: number, worker: string)
	pool.pending[job.id] = nil
	pool.inflight -= 1
	if pool.busy[job.worker] then
		pool.busy[job.worker] = math.max(0, pool.busy[job.worker] - 1)
	end
	if ok then
		pool.stats.done += 1
	else
		pool.stats.failed += 1
		pool.lastError = tostring(result)
	end
	pool.stats.ms += ms
	local cb = job.callback
	if cb then
		local cok, cerr = pcall(cb, ok, result, ms, worker)
		if not cok then
			warn(string.format("[WorkerPool %s] callback for %s failed: %s", pool.name, job.kind, tostring(cerr)))
		end
	end
end

local function enableScripts(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("BaseScript") then
			(d :: BaseScript).Enabled = true
		end
	end
end

-- Clones `count` workers from `template` under a new folder in `parent`, enables their
-- scripts and waits up to `wait` seconds for their hellos. Returns the ready count.
function WorkerPool.spawn(pool: Pool, template: Instance, parent: Instance, count: number, wait: number): number
	local folder = Instance.new("Folder")
	folder.Name = pool.name
	local done = Instance.new("BindableEvent")
	done.Name = "Done"
	done.Parent = folder
	pool.folder = folder
	pool.done = done
	table.insert(
		pool.connections,
		done.Event:Connect(function(worker: string, jobId: number, ok: boolean, result: any, ms: number)
			if jobId == 0 then
				if not pool.ready[worker] then
					pool.ready[worker] = true
					pool.readyCount += 1
				end
				return
			end
			local job = pool.pending[jobId]
			if job then
				finish(pool, job, ok, result, ms, worker)
			end
		end)
	)
	for i = 1, count do
		local a = template:Clone()
		local name = string.format("%s_%02d", pool.name, i)
		a.Name = name
		if a:IsA("Actor") then
			enableScripts(a)
			a.Parent = folder
			table.insert(pool.workers, a)
			pool.byName[name] = a
			pool.busy[name] = 0
		else
			a:Destroy()
		end
	end
	folder.Parent = parent
	local t0 = os.clock()
	while pool.readyCount < #pool.workers and os.clock() - t0 < wait do
		task.wait(0.05)
	end
	pool.available = pool.readyCount > 0
	pool.mode = if pool.available then "actors" else "serial"
	-- watchdog: redo lost jobs inline
	table.insert(
		pool.connections,
		RunService.Heartbeat:Connect(function()
			if pool.inflight == 0 then
				return
			end
			local now = os.clock()
			for _, job in pool.pending do
				if now - job.sent > pool.timeout then
					pool.stats.lost += 1
					local ok, result, ms = runInline(pool, job.kind, job.payload)
					finish(pool, job, ok, result, ms, "inline(lost)")
					break -- one per frame
				end
			end
		end)
	)
	return pool.readyCount
end

-- Removes the workers (used when a spawn variant failed and another is tried).
function WorkerPool.destroy(pool: Pool)
	for _, c in pool.connections do
		c:Disconnect()
	end
	pool.connections = {}
	if pool.folder then
		pool.folder:Destroy()
	end
	pool.folder = nil
	pool.done = nil
	pool.workers = {}
	pool.byName = {}
	pool.ready = {}
	pool.busy = {}
	pool.readyCount = 0
	pool.available = false
	pool.mode = "serial"
end

local function pickWorker(pool: Pool): Actor?
	local best: Actor? = nil
	local bestBusy = math.huge
	for _, a in pool.workers do
		if pool.ready[a.Name] then
			local b = pool.busy[a.Name] or 0
			if b < bestBusy then
				best, bestBusy = a, b
			end
		end
	end
	return best
end

-- Submits a job. With workers it is sent to the least busy one (or to `target`);
-- in serial mode it runs inline on a deferred thread. Returns the job id.
function WorkerPool.submit(pool: Pool, kind: string, payload: any, callback: Callback?, target: string?): number
	pool.nextId += 1
	local id = pool.nextId
	pool.stats.sent += 1
	local actor: Actor? = nil
	if pool.available then
		actor = if target then pool.byName[target] else pickWorker(pool)
	end
	local job: Job = {
		id = id,
		kind = kind,
		payload = payload,
		callback = callback,
		worker = if actor then actor.Name else "inline",
		sent = os.clock(),
	}
	pool.pending[id] = job
	pool.inflight += 1
	if actor then
		pool.busy[actor.Name] = (pool.busy[actor.Name] or 0) + 1
		local ok, err = pcall(function()
			(actor :: Actor):SendMessage("Job", id, kind, payload)
		end)
		if ok then
			return id
		end
		pool.lastError = tostring(err)
	end
	task.defer(function()
		local ok, result, ms = runInline(pool, kind, payload)
		if pool.pending[id] then
			finish(pool, job, ok, result, ms, "inline")
		end
	end)
	return id
end

-- Sends the same job to every ready worker (and runs it inline for the serial
-- state) and yields until all answered or `wait` seconds passed. Returns the number
-- of workers that acknowledged.
function WorkerPool.broadcast(pool: Pool, kind: string, payload: any, wait: number?): number
	local acks = 0
	local expected = 0
	-- inline copy so serial fallbacks (lost jobs) see the same state
	runInline(pool, kind, payload)
	if pool.available then
		for _, a in pool.workers do
			if pool.ready[a.Name] then
				expected += 1
				WorkerPool.submit(pool, kind, payload, function(ok: boolean)
					if ok then
						acks += 1
					end
				end, a.Name)
			end
		end
	end
	local t0 = os.clock()
	while acks < expected and os.clock() - t0 < (wait or 10) do
		task.wait(0.03)
	end
	return acks
end

-- Yields until no job is in flight (or timeout). Returns true when idle.
function WorkerPool.drain(pool: Pool, wait: number?): boolean
	local t0 = os.clock()
	while pool.inflight > 0 and os.clock() - t0 < (wait or 60) do
		task.wait(0.03)
	end
	return pool.inflight == 0
end

function WorkerPool.busyCount(pool: Pool): number
	local n = 0
	for _, b in pool.busy do
		if b > 0 then
			n += 1
		end
	end
	return n
end

function WorkerPool.describe(pool: Pool): string
	return string.format(
		"%s: %s, %d/%d ready, %d sent, %d done, %d failed, %d inline, %d lost",
		pool.name,
		pool.mode,
		pool.readyCount,
		#pool.workers,
		pool.stats.sent,
		pool.stats.done,
		pool.stats.failed,
		pool.stats.inline,
		pool.stats.lost
	)
end

return WorkerPool
