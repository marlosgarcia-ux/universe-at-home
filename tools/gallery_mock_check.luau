
-- ===== checks =====
local Panels = PanelsFactory(MyMathReal)
local t0 = os.clock()
local frames = 0
local function allWritten()
	if #images < 21 then -- plasma, badge, 64 px level, marble, 3 green-screen images, 5 ALLAN images, 9 tiles
		return false
	end
	for _, im in images do
		for y = 1, #im.rowsWritten do
			if im.rowsWritten[y] == 0 then
				return false
			end
		end
	end
	return true
end
assert(frameCb, "the script never connected to RenderStepped")
while os.clock() - t0 < 180 do
	frameCb(1 / 60)
	frames += 1
	if allWritten() and frames > 3 then
		break
	end
end
-- a few more frames so the plasma is rewritten repeatedly and the HUD refreshes
for _ = 1, 30 do
	frameCb(1 / 60)
end
local wall = os.clock() - t0
local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL " .. msg)
	else
		print("ok   " .. msg)
	end
end

print(string.format("frames %d, wall %.2f s, images %d, warnings %d", frames, wall, #images, #warnings))
for _, w in warnings do
	print("WARN " .. w)
end
check(#warnings == 0, "no warnings (no stage reported an error)")
check(allWritten(), "every pixel row of every image was written at least once")

-- creation order is deterministic: plasma, badge 512, badge 64, marble, green, matte, cut-out,
-- ALLAN logo, ALLAN UI levels 0 to 2, ALLAN marble, then the 9 tiles
local expectSizes = { 192, 512, 64, 256, 256, 256, 256, 256, 256, 128, 64, 64, 384, 384, 384, 384, 384, 384, 384, 384, 384 }
check(#images == #expectSizes, "created exactly " .. #expectSizes .. " images, got " .. #images)
for i, sz in expectSizes do
	if images[i] then
		check(images[i].Size.X == sz and images[i].Size.Y == sz, string.format("image %d is %d x %d", i, sz, sz))
	end
end

local function hashOf(img)
	return Panels.hashBuffer(img.pixels)
end
local function direct(w, h, fn)
	local b = buffer.create(w * h * 4)
	fn(b)
	return Panels.hashBuffer(b)
end

check(hashOf(images[2]) == direct(512, 512, function(b) Panels.renderScene(b, 512, 512) end), "badge image equals a direct render")
check(hashOf(images[3]) == direct(64, 64, function(b) Panels.renderScene(b, 64, 64) end), "64 px level equals a direct render")
check(hashOf(images[4]) == direct(256, 256, function(b) Panels.renderMarble(b, 256, 256, 1234) end), "marble image equals a direct render")
local g = buffer.create(256 * 256 * 4)
local m = buffer.create(256 * 256 * 4)
local c = buffer.create(256 * 256 * 4)
Panels.renderGreenScreen(g, 256, 256)
Panels.keyMatte(g, 256, 256, m, c)
check(hashOf(images[5]) == Panels.hashBuffer(g), "green-screen image equals a direct render")
check(hashOf(images[6]) == Panels.hashBuffer(m), "matte image equals a direct render")
check(hashOf(images[7]) == Panels.hashBuffer(c), "cut-out image equals a direct render")
-- ALLAN images must equal a direct, un-banded render of the same model
local function allanDirect(name, level, size)
	local model, tree = LiquidReal.decode(ModelsReal.load(name))
	local plan = LiquidReal.prepare(model, tree, ModelsReal.scale(name))
	local w, h = LiquidReal.outputSize(plan, level)
	assert(w == size and h == size, "unexpected ALLAN output size " .. w .. "x" .. h)
	local out = buffer.create(w * h * 4)
	LiquidReal.render(plan, tree, out, w, { level = level })
	return Panels.hashBuffer(out)
end
check(hashOf(images[8]) == allanDirect("sdf_logo_256", 0, 256), "ALLAN logo equals a direct render (banded upload)")
check(hashOf(images[9]) == allanDirect("ui_flat_256", 0, 256), "ALLAN UI level 0 equals a direct render")
check(hashOf(images[10]) == allanDirect("ui_flat_256", 1, 128), "ALLAN UI level 1 equals a direct render")
check(hashOf(images[11]) == allanDirect("ui_flat_256", 2, 64), "ALLAN UI level 2 equals a direct render")
check(hashOf(images[12]) == allanDirect("marble_64", 0, 64), "ALLAN marble equals a direct render")

local tile = buffer.create(384 * 384 * 4)
for i = 0, 8 do
	Panels.renderMandelbrotTile(tile, 384, i % 3, i // 3, 3)
	check(hashOf(images[13 + i]) == Panels.hashBuffer(tile), "mandelbrot tile " .. (i + 1) .. " equals a direct render")
end

-- the plasma image must have been rewritten every frame
check(images[1].writeCalls >= frames, string.format("plasma written every frame (%d writes in %d frames)", images[1].writeCalls, frames + 30))

print("--- card and HUD text")
for _, inst in allInstances do
	if inst.ClassName == "TextLabel" and inst.Text and inst.Text ~= "" and (inst.TextSize == 12 or inst.TextSize == 13 and inst.Text:sub(1, 3) == "FPS") then
		print("  " .. inst.Text:gsub("\n", " / "))
	end
end

local gui, labels, decals = 0, 0, 0
for _, inst in allInstances do
	if inst.ClassName == "ImageLabel" then
		labels += 1
	elseif inst.ClassName == "Decal" then
		decals += 1
	end
end
print(string.format("ImageLabels %d, Decals %d", labels, decals))
check(decals == 6, "the cube wears 6 decals")
check(labels == 3 + 1 + 1 + 1 + 9 + 4 + 1 + 4, "expected ImageLabel count " .. labels)

print(failures == 0 and "ALL OK" or (failures .. " FAILURES"))
if failures > 0 then
	error("gallery mock run failed")
end
