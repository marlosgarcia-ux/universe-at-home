--!optimize 2
-- universe-at-home :: studio/ParallelProbe.client.luau  (LocalScript inside an Actor)
--
-- Checks the API dump's thread-safety tags against what the engine enforces:
--   EditableImage.Size          ReadSafe
--   ReadPixelsBuffer            Safe      (callable in parallel)
--   WritePixelsBuffer, Draw*    Unsafe    (serial only)
--   CreateEditableImage         Unsafe
-- and shows the pattern the library relies on: compute pixels into a buffer in the
-- parallel phase, write them with WritePixelsBuffer in the serial phase.
--
-- Setup: create an Actor in StarterPlayerScripts and put this LocalScript inside it.
-- A server copy works the same way inside an Actor in ServerScriptService.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local W, H = 128, 128
local img = AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
if not img then
	warn("ParallelProbe: no editable budget left")
	return
end

local px = buffer.create(W * H * 4)
local results: { string } = {}
local function try(name: string, fn: () -> any)
	local ok, err = pcall(fn)
	table.insert(results, string.format("  %-46s %s", name, if ok then "allowed" else "blocked: " .. tostring(err)))
end

task.desynchronize()

try("EditableImage.Size (dump: ReadSafe)", function()
	return img.Size
end)
try("ReadPixelsBuffer (dump: Safe)", function()
	return img:ReadPixelsBuffer(Vector2.zero, Vector2.new(W, H))
end)
try("WritePixelsBuffer (dump: Unsafe)", function()
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), px)
end)
try("DrawRectangle (dump: Unsafe)", function()
	img:DrawRectangle(Vector2.zero, Vector2.new(8, 8), Color3.new(1, 0, 0), 0, Enum.ImageCombineType.Overwrite)
end)
try("AssetService:CreateEditableImage (dump: Unsafe)", function()
	local extra = AssetService:CreateEditableImage({ Size = Vector2.new(8, 8) })
	if extra then
		extra:Destroy()
	end
end)

-- Parallel compute into a plain buffer: always allowed, this is where the work goes.
local t0 = os.clock()
for y = 0, H - 1 do
	for x = 0, W - 1 do
		buffer.writeu32(px, (y * W + x) * 4, 0xFF000000 + x * 2 + y * 512)
	end
end
local computeMs = (os.clock() - t0) * 1000

local t1 = os.clock()
for _ = 1, 50 do
	img:ReadPixelsBuffer(Vector2.zero, Vector2.new(W, H))
end
local readMs = (os.clock() - t1) * 1000 / 50

task.synchronize()

local t2 = os.clock()
img:WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), px)
local writeMs = (os.clock() - t2) * 1000

print(string.format("ParallelProbe (%s)", if RunService:IsServer() then "server" else "client"))
for _, line in results do
	print(line)
end
print(string.format("  parallel compute %dx%d into buffer: %.3f ms", W, H, computeMs))
print(string.format("  parallel ReadPixelsBuffer %dx%d: %.3f ms per call", W, H, readMs))
print(string.format("  serial WritePixelsBuffer of the parallel result: %.3f ms", writeMs))
img:Destroy()
