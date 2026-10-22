--!strict
-- Universe at Home: Meadow :: Status
--
-- The self-check and capabilities registry. Every stage of the demo (terrain, sky,
-- rocks, each grass ring, each bench test, baking, Actors) reports here instead of
-- erroring: Status.stage runs a function inside pcall, records ok / fallback / failed
-- with a one-line detail, prints a clear line to Output and a machine-readable line
--     MEADOW|<side>|<feature>|<state>|<detail>
-- On the server the record is also mirrored to attributes of the replicated folder
-- ReplicatedStorage.DemoStatus, so every client's capabilities panel shows what the
-- server could and could not do.

local Config = require("./Config")

local Status = {}

export type State = "ok" | "fallback" | "failed" | "pending" | "skipped" | "info"

export type Entry = {
	feature: string,
	state: State,
	detail: string,
	order: number,
	time: number,
}

export type Registry = {
	side: string,
	entries: { [string]: Entry },
	count: number,
	mirror: Instance?,
	listeners: { (Entry) -> () },
}

local registries: { [string]: Registry } = {}

function Status.registry(side: string, mirror: Instance?): Registry
	local r = registries[side]
	if r then
		if mirror then
			r.mirror = mirror
		end
		return r
	end
	local created: Registry = { side = side, entries = {}, count = 0, mirror = mirror, listeners = {} }
	registries[side] = created
	return created
end

-- Attribute names allow letters, digits and underscores only.
local function attributeName(feature: string): string
	return "s_" .. (string.gsub(feature, "[^%w_]", "_"))
end
Status.attributeName = attributeName

local function oneLine(s: string): string
	local t = string.gsub(s, "[\r\n|]", " ")
	if #t > 240 then
		t = string.sub(t, 1, 237) .. "..."
	end
	return t
end

function Status.set(r: Registry, feature: string, state: State, detail: string?)
	local d = oneLine(detail or "")
	local e = r.entries[feature]
	if not e then
		r.count += 1
		e = { feature = feature, state = state, detail = d, order = r.count, time = os.clock() }
		r.entries[feature] = e
	else
		e.state = state
		e.detail = d
		e.time = os.clock()
	end
	local line = string.format("%s|%s|%s|%s|%s", Config.TAG, r.side, feature, state, d)
	if state == "failed" then
		warn(line)
	else
		print(line)
	end
	local mirror = r.mirror
	if mirror then
		pcall(function()
			mirror:SetAttribute(attributeName(feature), string.format("%03d|%s|%s", e.order, state, d))
		end)
	end
	for _, fn in r.listeners do
		task.spawn(fn, e)
	end
end

function Status.listen(r: Registry, fn: (Entry) -> ())
	table.insert(r.listeners, fn)
end

-- Runs fn inside pcall. fn returns (state?, detail?); a thrown error records
-- "failed" with the message and runs the optional fallback, which may itself
-- return (state?, detail?) and defaults to "fallback".
function Status.stage(
	r: Registry,
	feature: string,
	fn: () -> (State?, string?),
	fallback: ((string) -> (State?, string?))?
): boolean
	Status.set(r, feature, "pending", "starting")
	local t0 = os.clock()
	local ok, a, b = pcall(fn)
	local ms = (os.clock() - t0) * 1000
	if ok then
		local state: State = (a :: State?) or "ok"
		Status.set(r, feature, state, string.format("%s (%.0f ms)", (b :: string?) or "", ms))
		return state == "ok"
	end
	local message = tostring(a)
	if fallback then
		local fok, fa, fb = pcall(fallback, message)
		if fok then
			Status.set(r, feature, (fa :: State?) or "fallback", ((fb :: string?) or "fallback active") .. " | error: " .. message)
			return false
		end
		Status.set(r, feature, "failed", message .. " | fallback also failed: " .. tostring(fa))
		return false
	end
	Status.set(r, feature, "failed", message)
	return false
end

-- Entries sorted by first report.
function Status.list(r: Registry): { Entry }
	local out: { Entry } = {}
	for _, e in r.entries do
		table.insert(out, e)
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		return a.order < b.order
	end)
	return out
end

-- Parses the server mirror attributes back into entries (client side).
function Status.fromAttributes(attrs: { [string]: any }): { Entry }
	local out: { Entry } = {}
	for name, value in attrs do
		if string.sub(name, 1, 2) == "s_" and type(value) == "string" then
			local order, state, detail = string.match(value, "^(%d+)|(%a+)|(.*)$")
			if order and state then
				table.insert(out, {
					feature = string.sub(name, 3),
					state = state :: State,
					detail = detail or "",
					order = tonumber(order) or 0,
					time = 0,
				})
			end
		end
	end
	table.sort(out, function(a: Entry, b: Entry): boolean
		return a.order < b.order
	end)
	return out
end

-- One machine-readable result line for bench tests and measurements.
function Status.result(side: string, test: string, fields: { [string]: any })
	local keys: { string } = {}
	for k in fields do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = table.create(#keys)
	for _, k in keys do
		local v = fields[k]
		local s = if type(v) == "number" then string.format("%.6g", v) else tostring(v)
		table.insert(parts, k .. "=" .. oneLine(s))
	end
	print(string.format("%s|%s|result|%s|%s", Config.TAG, side, test, table.concat(parts, ";")))
end

return Status
