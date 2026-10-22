--!strict
-- Universe at Home: Meadow :: Net
--
-- The whole remote protocol in one place. The server creates the RemoteEvents at start
-- (Net.serverInit) under ReplicatedStorage.DemoNet; clients find them with WaitForChild
-- (Net.clientGet). Everything a client can send is validated (types, sizes, ranges)
-- and rate limited per player before the server acts on it.

local Net = {}

Net.FOLDER = "DemoNet"

-- name -> direction ("c2s" client to server, "s2c" server to client)
Net.EVENTS = ({
	Hello = "c2s", -- client ready: { version, capabilities summary }
	BenchHashes = "c2s", -- determinism referee input: { run, test, entries = { {key, hash} } }
	TrainRequest = "c2s", -- ask the server to run T10 training slices: { slices }
	BenchVerdict = "s2c", -- referee verdict broadcast: { run, test, text, ok }
	TrainProgress = "s2c", -- T10 progress: { slice, of, ms, done, text }
	ServerNote = "s2c", -- free-form status line for the HUD
} :: { [string]: string })

-- Per event: maximum calls per second (token bucket rate) and burst.
Net.LIMITS = {
	Hello = { rate = 0.5, burst = 3 },
	BenchHashes = { rate = 2, burst = 6 },
	TrainRequest = { rate = 0.2, burst = 2 },
}

-- Engine objects are passed in (`rs` is ReplicatedStorage, `new` is Instance.new) and
-- typed `any` here, so this module also loads in the Luau CLI tests; callers cast the
-- results (RemoteEvent) and luau-lsp checks them there.

local function folderOf(rs: any): any
	return rs:FindFirstChild(Net.FOLDER)
end

-- Server: creates the folder and every RemoteEvent (idempotent). Returns the folder.
function Net.serverInit(rs: any, new: (className: string) -> any): any
	local folder = folderOf(rs)
	if not folder then
		folder = new("Folder")
		folder.Name = Net.FOLDER
		folder.Parent = rs
	end
	for name in Net.EVENTS do
		if not folder:FindFirstChild(name) then
			local e = new("RemoteEvent")
			e.Name = name
			e.Parent = folder
		end
	end
	return folder
end

-- Server: the RemoteEvent called name (after serverInit).
function Net.serverGet(rs: any, name: string): any
	local folder = folderOf(rs)
	assert(folder, "Net.serverInit has not run")
	local e = folder:FindFirstChild(name)
	assert(e and e:IsA("RemoteEvent"), "unknown remote " .. name)
	return e
end

-- Client: waits (up to timeout seconds) for the RemoteEvent called name; nil if absent.
function Net.clientGet(rs: any, name: string, timeout: number?): any
	local folder = rs:WaitForChild(Net.FOLDER, timeout or 30)
	if not folder then
		return nil
	end
	local e = folder:WaitForChild(name, timeout or 30)
	if e and e:IsA("RemoteEvent") then
		return e
	end
	return nil
end

----------------------------------------------------------------------------------
-- Rate limiting: one token bucket per (player key, event).
----------------------------------------------------------------------------------

export type Limiter = {
	rate: number,
	burst: number,
	tokens: { [any]: number },
	stamp: { [any]: number },
}

function Net.newLimiter(rate: number, burst: number): Limiter
	return { rate = rate, burst = burst, tokens = {}, stamp = {} }
end

function Net.allow(l: Limiter, key: any, now: number): boolean
	local t = l.tokens[key]
	local s = l.stamp[key]
	if t == nil or s == nil then
		t = l.burst
		s = now
	end
	t = math.min(l.burst, t + (now - s) * l.rate)
	l.stamp[key] = now
	if t >= 1 then
		l.tokens[key] = t - 1
		return true
	end
	l.tokens[key] = t
	return false
end

function Net.forget(l: Limiter, key: any)
	l.tokens[key] = nil
	l.stamp[key] = nil
end

----------------------------------------------------------------------------------
-- Validation. Each returns (ok, reason).
----------------------------------------------------------------------------------

local function isInteger(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v >= lo and v <= hi and math.floor(v) == v
end
Net.isInteger = isInteger

local function isShortString(v: any, maxLen: number): boolean
	return type(v) == "string" and #v > 0 and #v <= maxLen and string.find(v, "^[%w_%-%.:/ ]+$") ~= nil
end
Net.isShortString = isShortString

function Net.validateHello(p: any): (boolean, string?)
	if type(p) ~= "table" then
		return false, "payload not a table"
	end
	if not isShortString(p.version, 16) then
		return false, "bad version"
	end
	if p.summary ~= nil and not isShortString(p.summary, 200) then
		return false, "bad summary"
	end
	return true, nil
end

-- { run = int, test = "T2"|"T3"|..., entries = { { key = string, hash = u32 }, ... } }
function Net.validateHashes(p: any): (boolean, string?)
	if type(p) ~= "table" then
		return false, "payload not a table"
	end
	if not isInteger(p.run, 1, 1e9) then
		return false, "bad run"
	end
	if not isShortString(p.test, 8) then
		return false, "bad test"
	end
	local entries = p.entries
	if type(entries) ~= "table" then
		return false, "entries not a table"
	end
	local n = 0
	for k, e in entries do
		n += 1
		if n > 64 then
			return false, "too many entries"
		end
		if not isInteger(k, 1, 64) or type(e) ~= "table" then
			return false, "bad entry"
		end
		if not isShortString(e.key, 48) then
			return false, "bad entry key"
		end
		if not isInteger(e.hash, 0, 4294967295) then
			return false, "bad entry hash"
		end
	end
	if n == 0 then
		return false, "no entries"
	end
	return true, nil
end

function Net.validateTrain(p: any): (boolean, string?)
	if type(p) ~= "table" then
		return false, "payload not a table"
	end
	if not isInteger(p.slices, 1, 64) then
		return false, "bad slice count"
	end
	return true, nil
end

return Net
