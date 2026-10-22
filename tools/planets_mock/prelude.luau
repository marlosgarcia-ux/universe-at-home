--!nonstrict
-- A stand-in for the parts of the Roblox API that planets/client uses, so the real client
-- scripts can run in the Luau CLI (tools/planets_mock_run.py glues this prelude, the
-- wrapped client modules and tools/planets_mock/check.luau into one file).
--
-- Unlike a stub, this mock does real arithmetic and validation where the client depends
-- on it: Vector3 and CFrame math (lookAt, axis-angle, composition), an instance tree with
-- WaitForChild and events, a task scheduler on a frame clock, EditableImages that keep
-- their pixels and reject out-of-bounds or short writes and record the frame of every
-- write, EditableMeshes with the batch API and per-id validation, a memory budget that
-- refuses images beyond a limit. It is NOT the engine: it checks the client's own logic.
-- Property names and signatures are checked against the real API by luau-lsp.

local realRequire = require
local realPrint = print

local MOCK = {
	frame = 0,
	time = 0,
	prints = {},
	warnings = {},
	errors = {},
	writesByFrame = {}, -- frame -> { [image] = true }
	images = {},
	meshes = {},
	parts = {},
	budgetPx = 64 * 1024 * 1024, -- generous by default; the probe test lowers it
	usedPx = 0,
	refusals = 0,
	sunClock = 14.2,
}

local function print(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, "\t")
	table.insert(MOCK.prints, line)
	if string.sub(line, 1, 8) == "PLANETS|" then
		realPrint(line)
	end
end

local function warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(MOCK.warnings, table.concat(parts, " "))
end

----------------------------------------------------------------------------------------
-- datatypes
----------------------------------------------------------------------------------------

local V3 = {}
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
V3.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif k == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(v.X / m, v.Y / m, v.Z / m)
	end
	return rawget(V3, k)
end
V3.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return v3(a.X / b, a.Y / b, a.Z / b)
	end
	return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__unm = function(a)
	return v3(-a.X, -a.Y, -a.Z)
end
V3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3.__tostring = function(a)
	return string.format("%.3f, %.3f, %.3f", a.X, a.Y, a.Z)
end
function V3.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3.Cross(a, b)
	return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V3.Lerp(a, b, t)
	return a + (b - a) * t
end
local Vector3 = { new = v3, zero = v3(0, 0, 0), one = v3(1, 1, 1), xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1) }

local V2 = {}
local function v2(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2)
end
V2.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y)
	end
	return rawget(V2, k)
end
V2.__add = function(a, b)
	return v2(a.X + b.X, a.Y + b.Y)
end
V2.__sub = function(a, b)
	return v2(a.X - b.X, a.Y - b.Y)
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		return v2(a * b.X, a * b.Y)
	elseif type(b) == "number" then
		return v2(a.X * b, a.Y * b)
	end
	return v2(a.X * b.X, a.Y * b.Y)
end
V2.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
local Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1) }

-- CFrame: position and a rotation matrix r[1..9] in row-major order; the columns are the
-- right, up and back vectors (LookVector = -back), as in Roblox.
local CF = {}
local function cf(px, py, pz, r)
	return setmetatable({ px = px, py = py, pz = pz, r = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, CF)
end
CF.__index = function(c, k)
	local r = c.r
	if k == "Position" or k == "p" then
		return v3(c.px, c.py, c.pz)
	elseif k == "LookVector" then
		return v3(-r[3], -r[6], -r[9])
	elseif k == "RightVector" then
		return v3(r[1], r[4], r[7])
	elseif k == "UpVector" then
		return v3(r[2], r[5], r[8])
	elseif k == "X" then
		return c.px
	elseif k == "Y" then
		return c.py
	elseif k == "Z" then
		return c.pz
	end
	return rawget(CF, k)
end
local function matmul(a, b)
	local o = {}
	for i = 0, 2 do
		for j = 0, 2 do
			o[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
		end
	end
	return o
end
function CF.VectorToWorldSpace(c, v)
	local r = c.r
	return v3(r[1] * v.X + r[2] * v.Y + r[3] * v.Z, r[4] * v.X + r[5] * v.Y + r[6] * v.Z, r[7] * v.X + r[8] * v.Y + r[9] * v.Z)
end
function CF.PointToWorldSpace(c, v)
	local w = CF.VectorToWorldSpace(c, v)
	return v3(w.X + c.px, w.Y + c.py, w.Z + c.pz)
end
CF.__mul = function(a, b)
	if getmetatable(b) == CF then
		local p = CF.PointToWorldSpace(a, v3(b.px, b.py, b.pz))
		return cf(p.X, p.Y, p.Z, matmul(a.r, b.r))
	end
	return CF.PointToWorldSpace(a, b)
end
CF.__add = function(a, v)
	return cf(a.px + v.X, a.py + v.Y, a.pz + v.Z, a.r)
end
local CFrame = {}
function CFrame.new(x, y, z)
	if type(x) == "table" then
		return cf(x.X, x.Y, x.Z)
	end
	return cf(x or 0, y or 0, z or 0)
end
function CFrame.lookAt(pos, target, up)
	up = up or v3(0, 1, 0)
	local look = (target - pos).Unit
	local right = look:Cross(up).Unit
	local u = right:Cross(look)
	return cf(pos.X, pos.Y, pos.Z, { right.X, u.X, -look.X, right.Y, u.Y, -look.Y, right.Z, u.Z, -look.Z })
end
function CFrame.fromAxisAngle(axis, a)
	local k = axis.Unit
	local c, s = math.cos(a), math.sin(a)
	local t = 1 - c
	local x, y, z = k.X, k.Y, k.Z
	return cf(0, 0, 0, {
		t * x * x + c,
		t * x * y - s * z,
		t * x * z + s * y,
		t * x * y + s * z,
		t * y * y + c,
		t * y * z - s * x,
		t * x * z - s * y,
		t * y * z + s * x,
		t * z * z + c,
	})
end
function CFrame.Angles(rx, ry, rz)
	local X = CFrame.fromAxisAngle(v3(1, 0, 0), rx)
	local Y = CFrame.fromAxisAngle(v3(0, 1, 0), ry)
	local Z = CFrame.fromAxisAngle(v3(0, 0, 1), rz)
	return X * Y * Z
end
CFrame.identity = cf(0, 0, 0)

local Color3 = {
	new = function(r, g, b)
		return { R = r or 0, G = g or 0, B = b or 0 }
	end,
	fromRGB = function(r, g, b)
		return { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255 }
	end,
}
local UDim = {
	new = function(s, o)
		return { Scale = s or 0, Offset = o or 0 }
	end,
}
local UDim2 = {
	new = function(xs, xo, ys, yo)
		return { X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }
	end,
	fromOffset = function(x, y)
		return { X = UDim.new(0, x), Y = UDim.new(0, y) }
	end,
	fromScale = function(x, y)
		return { X = UDim.new(x, 0), Y = UDim.new(y, 0) }
	end,
}
local Content = {
	fromObject = function(o)
		assert(o ~= nil, "Content.fromObject(nil)")
		return { Object = o, SourceType = "Object" }
	end,
	none = { SourceType = "None" },
}

local enumCache = {}
local Enum = setmetatable({}, {
	__index = function(_, typeName)
		local t = enumCache[typeName]
		if not t then
			t = setmetatable({}, {
				__index = function(tt, item)
					local e = { Name = item, EnumType = typeName }
					rawset(tt, item, e)
					return e
				end,
			})
			enumCache[typeName] = t
		end
		return t
	end,
})

----------------------------------------------------------------------------------------
-- signals and the task scheduler (frame clock)
----------------------------------------------------------------------------------------

local function recordError(where, err)
	table.insert(MOCK.errors, where .. ": " .. tostring(err))
end

local function newSignal(name)
	local s = { handlers = {}, name = name }
	function s:Connect(fn)
		local entry = { fn = fn, on = true }
		table.insert(self.handlers, entry)
		return {
			Connected = true,
			Disconnect = function(c)
				entry.on = false
			end,
		}
	end
	function s:Fire(...)
		local list = table.clone(self.handlers)
		for _, h in list do
			if h.on then
				local ok, err = pcall(h.fn, ...)
				if not ok then
					recordError("signal " .. tostring(self.name), err)
				end
			end
		end
	end
	return s
end

local waiting = {}
local deferred = {}
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		recordError("thread", debug.traceback(co, tostring(err)))
	end
end
local task = {}
function task.spawn(fn, ...)
	local co = if type(fn) == "thread" then fn else coroutine.create(fn)
	resume(co, ...)
	return co
end
function task.defer(fn, ...)
	table.insert(deferred, { fn = fn, args = table.pack(...) })
end
function task.delay(t, fn, ...)
	local args = table.pack(...)
	task.spawn(function()
		task.wait(t)
		fn(table.unpack(args, 1, args.n))
	end)
end
function task.wait(t)
	local co = coroutine.running()
	assert(coroutine.isyieldable(), "task.wait outside a yieldable thread")
	table.insert(waiting, { co = co, wake = MOCK.time + (t or 0) })
	return coroutine.yield()
end
function task.synchronize() end
function task.desynchronize() end

----------------------------------------------------------------------------------------
-- instances
----------------------------------------------------------------------------------------

local Inst = {}
local function setParent(self, parent)
	local old = rawget(self, "_parent")
	if old then
		local kids = rawget(old, "_children")
		local i = table.find(kids, self)
		if i then
			table.remove(kids, i)
		end
	end
	rawset(self, "_parent", parent)
	if parent then
		table.insert(rawget(parent, "_children"), self)
	end
end
Inst.__index = function(self, k)
	if k == "Parent" then
		return rawget(self, "_parent")
	elseif k == "ClassName" then
		return rawget(self, "_class")
	end
	local props = rawget(self, "_props")
	local v = props[k]
	if v ~= nil then
		return v
	end
	local m = Inst[k]
	if m ~= nil then
		return m
	end
	for _, c in rawget(self, "_children") do
		if c.Name == k then
			return c
		end
	end
	return nil
end
Inst.__newindex = function(self, k, v)
	if k == "Parent" then
		setParent(self, v)
	else
		rawget(self, "_props")[k] = v
	end
end
Inst.__tostring = function(self)
	return self.Name
end
local function newInstance(className, props)
	local o = setmetatable({ _class = className, _props = { Name = className }, _children = {}, _parent = nil }, Inst)
	for k, v in props or {} do
		o[k] = v
	end
	table.insert(MOCK.parts, o)
	return o
end
function Inst.FindFirstChild(self, name)
	for _, c in rawget(self, "_children") do
		if c.Name == name then
			return c
		end
	end
	return nil
end
function Inst.FindFirstChildOfClass(self, cls)
	for _, c in rawget(self, "_children") do
		if rawget(c, "_class") == cls then
			return c
		end
	end
	return nil
end
function Inst.WaitForChild(self, name, timeout)
	local c = Inst.FindFirstChild(self, name)
	if c == nil and timeout == nil then
		error("mock WaitForChild would wait forever: " .. tostring(self.Name) .. "." .. name)
	end
	return c
end
function Inst.GetChildren(self)
	return table.clone(rawget(self, "_children"))
end
function Inst.IsA(self, cls)
	local mine = rawget(self, "_class")
	if mine == cls then
		return true
	end
	local bases = {
		MeshPart = { BasePart = true, Instance = true },
		Part = { BasePart = true, Instance = true },
		Script = { BaseScript = true, LuaSourceContainer = true },
		LocalScript = { BaseScript = true, LuaSourceContainer = true },
		ModuleScript = { LuaSourceContainer = true },
	}
	return bases[mine] ~= nil and bases[mine][cls] == true or cls == "Instance"
end
function Inst.Clone(self)
	local o = newInstance(rawget(self, "_class"))
	for k, v in rawget(self, "_props") do
		rawget(o, "_props")[k] = v
	end
	for _, c in rawget(self, "_children") do
		Inst.Clone(c).Parent = o
	end
	return o
end
function Inst.Destroy(self)
	setParent(self, nil)
	rawset(self, "_destroyed", true)
end
function Inst.GetDescendants(self)
	local out = {}
	local function walk(n)
		for _, c in rawget(n, "_children") do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end

local function makeClass(className)
	local o = newInstance(className)
	if className == "BindableEvent" then
		local ev = newSignal("BindableEvent")
		o.Event = ev
		o.Fire = function(self, ...)
			ev:Fire(...)
		end
	elseif className == "Part" or className == "MeshPart" then
		o.CFrame = CFrame.new()
		o.Transparency = 0
		o.Size = v3(1, 1, 1)
	elseif className == "BillboardGui" then
		o.Enabled = true
		o.Size = UDim2.fromScale(1, 1)
	elseif className == "Atmosphere" then
		o.Density = 0
	end
	return o
end
local Instance = { new = makeClass }

----------------------------------------------------------------------------------------
-- EditableImage, EditableMesh and AssetService
----------------------------------------------------------------------------------------

local ImageMeta = {}
ImageMeta.__index = ImageMeta
function ImageMeta.WritePixelsBuffer(self, pos, size, buf)
	assert(not self.destroyed, "write to a destroyed EditableImage")
	local x, y, w, h = pos.X, pos.Y, size.X, size.Y
	assert(x % 1 == 0 and y % 1 == 0 and w % 1 == 0 and h % 1 == 0, "non-integer rectangle")
	assert(x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= self.w and y + h <= self.h, string.format("rectangle %d,%d %dx%d outside %dx%d %s", x, y, w, h, self.w, self.h, self.name))
	assert(buffer.len(buf) >= w * h * 4, string.format("buffer of %d bytes for a %dx%d rectangle", buffer.len(buf), w, h))
	for row = 0, h - 1 do
		buffer.copy(self.pixels, ((y + row) * self.w + x) * 4, buf, row * w * 4, w * 4)
	end
	self.writes += 1
	local f = MOCK.writesByFrame[MOCK.frame]
	if not f then
		f = {}
		MOCK.writesByFrame[MOCK.frame] = f
	end
	f[self] = true
end
function ImageMeta.ReadPixelsBuffer(self, pos, size)
	local out = buffer.create(size.X * size.Y * 4)
	for row = 0, size.Y - 1 do
		buffer.copy(out, row * size.X * 4, self.pixels, ((pos.Y + row) * self.w + pos.X) * 4, size.X * 4)
	end
	return out
end
function ImageMeta.Destroy(self)
	if not self.destroyed then
		self.destroyed = true
		MOCK.usedPx -= self.w * self.h
	end
end

local MeshMeta = {}
MeshMeta.__index = MeshMeta
local function newMesh()
	local m = setmetatable({ next = 1, kind = {}, pos = {}, uv = {}, normal = {}, faces = {}, faceUV = {}, faceN = {}, destroyed = false, batchCalls = 0, setCalls = 0 }, MeshMeta)
	table.insert(MOCK.meshes, m)
	return m
end
local function newId(m, kind)
	local id = m.next
	m.next += 1
	m.kind[id] = kind
	return id
end
function MeshMeta.BatchAdd(m, attr, data)
	local kind = attr.Name
	local ids = table.create(#data)
	for i, d in data do
		if kind == "Vertex" then
			local id = newId(m, "vertex")
			m.pos[id] = d
			ids[i] = id
		elseif kind == "UV" then
			local id = newId(m, "uv")
			m.uv[id] = d
			ids[i] = id
		elseif kind == "Normal" then
			local id = newId(m, "normal")
			m.normal[id] = d
			ids[i] = id
		elseif kind == "Face" then
			assert(#d == 3, "face needs 3 vertices")
			for _, v in d do
				assert(m.kind[v] == "vertex", "face refers to a non-vertex id")
			end
			local id = newId(m, "face")
			m.faces[id] = d
			ids[i] = id
		else
			error("BatchAdd: unsupported attribute " .. tostring(kind))
		end
	end
	m.batchCalls += 1
	return ids
end
function MeshMeta.BatchSetFaceAttributes(m, fIds, arrays)
	assert(#fIds == #arrays, "BatchSetFaceAttributes: lengths differ")
	for i, f in fIds do
		assert(m.kind[f] == "face", "not a face id")
		local a = arrays[i]
		assert(#a == 3, "three attribute ids per face")
		local k = m.kind[a[1]]
		if k == "uv" then
			m.faceUV[f] = a
		elseif k == "normal" then
			m.faceN[f] = a
		else
			error("BatchSetFaceAttributes: unexpected id kind " .. tostring(k))
		end
	end
	m.batchCalls += 1
end
function MeshMeta.BatchSetValues(m, ids, values)
	assert(#ids == #values, "BatchSetValues: lengths differ")
	for i, id in ids do
		local k = m.kind[id]
		if k == "vertex" then
			m.pos[id] = values[i]
		elseif k == "normal" then
			m.normal[id] = values[i]
		elseif k == "uv" then
			m.uv[id] = values[i]
		else
			error("BatchSetValues: unexpected id kind " .. tostring(k))
		end
	end
	m.batchCalls += 1
end
function MeshMeta.AddVertex(m, p)
	local id = newId(m, "vertex")
	m.pos[id] = p
	return id
end
function MeshMeta.AddUV(m, uv)
	local id = newId(m, "uv")
	m.uv[id] = uv
	return id
end
function MeshMeta.AddNormal(m, n)
	local id = newId(m, "normal")
	m.normal[id] = n
	return id
end
function MeshMeta.AddTriangle(m, a, b, c)
	local id = newId(m, "face")
	m.faces[id] = { a, b, c }
	return id
end
function MeshMeta.SetFaceUVs(m, f, ids)
	m.faceUV[f] = ids
end
function MeshMeta.SetFaceNormals(m, f, ids)
	m.faceN[f] = ids
end
function MeshMeta.SetPosition(m, id, p)
	m.pos[id] = p
	m.setCalls += 1
end
function MeshMeta.SetNormal(m, id, n)
	m.normal[id] = n
	m.setCalls += 1
end
function MeshMeta.SetUV(m, id, uv)
	m.uv[id] = uv
	m.setCalls += 1
end
function MeshMeta.RemoveUnused(m)
	return {}
end
function MeshMeta.Destroy(m)
	m.destroyed = true
end

local AssetService = newInstance("AssetService")
AssetService.Name = "AssetService"
function AssetService.CreateEditableImage(self, opts)
	local size = opts and opts.Size or v2(512, 512)
	local w, h = size.X, size.Y
	assert(w >= 1 and h >= 1 and w <= 1024 and h <= 1024, "EditableImage size " .. w .. "x" .. h .. " outside 1..1024")
	if MOCK.usedPx + w * h > MOCK.budgetPx then
		MOCK.refusals += 1
		return nil
	end
	MOCK.usedPx += w * h
	local img = setmetatable({ w = w, h = h, Size = v2(w, h), pixels = buffer.create(w * h * 4), writes = 0, destroyed = false, name = "image" .. (#MOCK.images + 1) }, ImageMeta)
	table.insert(MOCK.images, img)
	return img
end
function AssetService.CreateEditableMesh(self, opts)
	return newMesh()
end
function AssetService.CreateMeshPartAsync(self, content, opts)
	assert(content and content.Object and getmetatable(content.Object) == MeshMeta, "CreateMeshPartAsync needs Content.fromObject(EditableMesh)")
	local p = makeClass("MeshPart")
	p._mesh = content.Object
	return p
end
function AssetService.CreateSurfaceAppearanceAsync(self, maps)
	for _, key in { "ColorMap", "NormalMap", "RoughnessMap" } do
		local c = maps[key]
		assert(c and c.Object and getmetatable(c.Object) == ImageMeta, "CreateSurfaceAppearanceAsync: " .. key .. " must be Content.fromObject(EditableImage)")
	end
	local sa = makeClass("SurfaceAppearance")
	sa.ColorMapContent = maps.ColorMap
	sa.NormalMapContent = maps.NormalMap
	sa.RoughnessMapContent = maps.RoughnessMap
	sa.Color = Color3.new(1, 1, 1)
	return sa
end

----------------------------------------------------------------------------------------
-- services and the DataModel
----------------------------------------------------------------------------------------

local RunService = newInstance("RunService")
RunService.RenderStepped = newSignal("RenderStepped")
RunService.Heartbeat = newSignal("Heartbeat")
RunService.IsClient = function()
	return true
end
local UserInputService = newInstance("UserInputService")
UserInputService.InputBegan = newSignal("InputBegan")
UserInputService.InputEnded = newSignal("InputEnded")
UserInputService.InputChanged = newSignal("InputChanged")
UserInputService.MouseBehavior = Enum.MouseBehavior.Default

local Workspace = newInstance("Workspace")
Workspace.Name = "Workspace"
local camera = makeClass("Camera")
camera.CFrame = CFrame.new()
camera.FieldOfView = 70
camera.ViewportSize = v2(1920, 1080)
camera.Parent = Workspace
Workspace.CurrentCamera = camera

local Lighting = newInstance("Lighting")
Lighting.Name = "Lighting"
makeClass("Sky").Parent = Lighting
Lighting.ClockTime = 14.2
function Lighting.GetSunDirection(self)
	-- a sun that moves with ClockTime: noon overhead-ish, tilted 23 degrees
	local a = (self.ClockTime / 24) * 2 * math.pi
	return v3(math.sin(a) * 0.92, -math.cos(a) * 0.92, 0.39).Unit
end

local Stats = newInstance("Stats")
function Stats.GetMemoryUsageMbForTag(self, tag)
	return 123
end

local ReplicatedStorage = newInstance("ReplicatedStorage")
ReplicatedStorage.Name = "ReplicatedStorage"

local Players = newInstance("Players")
local player = makeClass("Player")
player.Name = "Player"
player.CharacterAdded = newSignal("CharacterAdded")
makeClass("PlayerGui").Parent = player
local playerGui = player:FindFirstChildOfClass("PlayerGui")
playerGui.Name = "PlayerGui"
local playerScripts = makeClass("PlayerScripts")
playerScripts.Name = "PlayerScripts"
playerScripts.Parent = player
Players.LocalPlayer = player

local services = {
	AssetService = AssetService,
	RunService = RunService,
	UserInputService = UserInputService,
	Workspace = Workspace,
	Lighting = Lighting,
	Stats = Stats,
	ReplicatedStorage = ReplicatedStorage,
	Players = Players,
}
local game = newInstance("DataModel")
function game.GetService(self, name)
	local s = services[name]
	assert(s, "mock GetService: unknown service " .. tostring(name))
	return s
end
local workspace = Workspace

----------------------------------------------------------------------------------------
-- modules: wrapped client scripts and shared modules loaded from files
----------------------------------------------------------------------------------------

local __defs = {} -- filled by the generated part: name -> function(script, require)
local moduleCache = {}
local function mockRequire(inst)
	assert(type(inst) == "table" and rawget(inst, "_class") == "ModuleScript", "mock require: expected a ModuleScript instance, got " .. tostring(inst))
	local cached = moduleCache[inst]
	if cached ~= nil then
		return cached
	end
	local def = inst._def
	local result
	if def.file then
		result = realRequire(def.file)
	else
		local fn = __defs[def.wrapped]
		assert(fn, "no wrapped source for " .. tostring(def.wrapped))
		result = fn(inst, mockRequire)
	end
	moduleCache[inst] = result
	return result
end

local function moduleInstance(parent, name, def)
	local m = makeClass("ModuleScript")
	m.Name = name
	m._def = def
	m.Parent = parent
	return m
end
