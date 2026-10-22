--!nonstrict
-- A stand-in for the parts of the Roblox API that gallery/Gallery.client.luau uses, so the real
-- script can run in the Luau CLI. tools/gallery_mock_run.py glues this prelude, the script and
-- the checks in tools/gallery_mock_check.luau into one file. This is NOT the engine: it checks
-- the script's own logic (scheduler, row uploads, buffer sizes, image bounds), not whether a
-- property name exists. Type-check the script against the real API with luau-lsp for that.

local realRequire = require
local MyMathReal = realRequire("../src/MyMath")
local PanelsFactory = realRequire("../gallery/shared/Panels")

local warnings = {}
function warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(warnings, table.concat(parts, " "))
end

Vector2 = {}
Vector2.new = function(x, y)
	return { X = x, Y = y }
end
Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)
Vector3 = {
	new = function(x, y, z)
		return { X = x, Y = y, Z = z }
	end,
}
UDim = {
	new = function(s, o)
		return { Scale = s, Offset = o }
	end,
}
UDim2 = {
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
Color3 = {
	fromRGB = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
}
local cfMeta = {}
cfMeta.__mul = function(a, b)
	return setmetatable({}, cfMeta)
end
CFrame = {
	new = function(...)
		return setmetatable({}, cfMeta)
	end,
	Angles = function(...)
		return setmetatable({}, cfMeta)
	end,
}
Font = {
	fromEnum = function(e)
		return { enum = e }
	end,
}
Content = {
	fromObject = function(o)
		assert(o ~= nil, "Content.fromObject(nil)")
		return { Object = o }
	end,
	none = {},
}

local function enumProxy(name)
	return setmetatable({ Name = name }, {
		__index = function(_, key)
			if key == "GetEnumItems" then
				return function()
					return {}
				end
			end
			return enumProxy(key)
		end,
	})
end
Enum = enumProxy("Enum")

local allInstances = {}
Instance = {
	new = function(className)
		local inst = { ClassName = className, _children = {} }
		setmetatable(inst, {
			__newindex = function(t, k, v)
				rawset(t, k, v)
				if k == "Parent" and type(v) == "table" and v._children then
					table.insert(v._children, t)
				end
			end,
		})
		table.insert(allInstances, inst)
		return inst
	end,
}

local images = {}
local AssetService = {}
function AssetService:CreateEditableImage(opts)
	local size = opts.Size
	assert(size.X >= 1 and size.Y >= 1 and size.X <= 1024 and size.Y <= 1024, "bad EditableImage size")
	local img = { Size = size, pixels = buffer.create(size.X * size.Y * 4), rowsWritten = table.create(size.Y, 0), writeCalls = 0, bytesWritten = 0 }
	function img:WritePixelsBuffer(pos, sz, buf)
		assert(typeof(buf) == "buffer", "WritePixelsBuffer: not a buffer")
		assert(pos.X >= 0 and pos.Y >= 0 and pos.X % 1 == 0 and pos.Y % 1 == 0, "WritePixelsBuffer: bad position")
		assert(sz.X >= 1 and sz.Y >= 1, "WritePixelsBuffer: bad size")
		assert(pos.X + sz.X <= self.Size.X and pos.Y + sz.Y <= self.Size.Y, "WritePixelsBuffer: outside the image")
		assert(buffer.len(buf) == sz.X * sz.Y * 4, "WritePixelsBuffer: buffer length " .. buffer.len(buf) .. " but size needs " .. sz.X * sz.Y * 4)
		for r = 0, sz.Y - 1 do
			buffer.copy(self.pixels, ((pos.Y + r) * self.Size.X + pos.X) * 4, buf, r * sz.X * 4, sz.X * 4)
			self.rowsWritten[pos.Y + r + 1] += 1
		end
		self.writeCalls += 1
		self.bytesWritten += sz.X * sz.Y * 4
	end
	table.insert(images, img)
	return img
end

local frameCb = nil
local playerGui = { _children = {} }
local services = {
	AssetService = AssetService,
	Players = {
		LocalPlayer = {
			WaitForChild = function(_, name)
				return playerGui
			end,
		},
	},
	ReplicatedStorage = (function()
		local universe = { MyMath = { __module = MyMathReal } }
		local gallery = { Panels = { __module = PanelsFactory } }
		function universe:WaitForChild(n)
			return assert(self[n], "Universe has no child " .. tostring(n))
		end
		function gallery:WaitForChild(n)
			return assert(self[n], "Gallery has no child " .. tostring(n))
		end
		local rs = { Universe = universe, Gallery = gallery }
		function rs:WaitForChild(n)
			return assert(self[n], "ReplicatedStorage has no child " .. tostring(n))
		end
		return rs
	end)(),
	RunService = {
		RenderStepped = {
			Connect = function(_, fn)
				frameCb = fn
				return { Disconnect = function() end }
			end,
		},
	},
	Stats = {
		GetTotalMemoryUsageMb = function()
			return 321
		end,
		GetMemoryUsageMbForTag = function(_, tag)
			return 12
		end,
	},
	UserInputService = {
		InputBegan = {
			Connect = function()
				return { Disconnect = function() end }
			end,
		},
	},
}
game = {
	GetService = function(_, name)
		local s = services[name]
		assert(s, "unexpected service " .. tostring(name))
		return s
	end,
}
workspace = { _children = {} }

local function require(m)
	assert(type(m) == "table" and m.__module ~= nil, "mock require: unexpected argument")
	return m.__module
end

-- ===== the script under test follows =====
