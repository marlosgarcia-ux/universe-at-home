--!nonstrict
-- Renders every gallery panel in the Luau CLI and prints it as hex so tools/gallery_preview.py
-- can turn it into PNGs.   luau tools/gallery_preview.luau | python3 tools/gallery_preview.py OUTDIR
-- Lines:  TIME name ms   |   PANEL name w h  followed by h lines of w hex words (little-endian RGBA).

local MyMath = require("../src/MyMath")
local Panels = require("../gallery/shared/Panels")(MyMath)

local function dump(name: string, buf: buffer, w: number, h: number)
	print(string.format("PANEL %s %d %d", name, w, h))
	for y = 0, h - 1 do
		local parts = table.create(w, "")
		for x = 0, w - 1 do
			parts[x + 1] = string.format("%08x", buffer.readu32(buf, (y * w + x) * 4))
		end
		print(table.concat(parts))
	end
end

local function timed(name: string, fn: () -> ())
	local t0 = os.clock()
	fn()
	print(string.format("TIME %s %.2f", name, (os.clock() - t0) * 1000))
end

local only = ...

local function want(name: string): boolean
	return only == nil or only == name
end

if want("scene512") then
	local b = buffer.create(512 * 512 * 4)
	local edge, tiles = 0, 0
	timed("scene512", function()
		edge, tiles = Panels.renderScene(b, 512, 512)
	end)
	print(string.format("NOTE scene512 edge tiles %d of %d", edge, tiles))
	dump("scene512", b, 512, 512)
end

if want("scene64") then
	local b = buffer.create(64 * 64 * 4)
	timed("scene64", function()
		Panels.renderScene(b, 64, 64)
	end)
	dump("scene64", b, 64, 64)
end

if want("plasma") then
	local st = Panels.plasmaInit(192, 192)
	local b = buffer.create(192 * 192 * 4)
	timed("plasma frame", function()
		Panels.plasmaFrame(st, b, 3.0)
	end)
	dump("plasma", b, 192, 192)
end

if want("marble") then
	local b = buffer.create(256 * 256 * 4)
	timed("marble256", function()
		Panels.renderMarble(b, 256, 256, 1234)
	end)
	dump("marble", b, 256, 256)
end

if want("mandel") then
	local size, grid = 96, 3
	local full = buffer.create(size * grid * size * grid * 4)
	local tile = buffer.create(size * size * 4)
	timed("mandelbrot 9 tiles of 96", function()
		for ty = 0, grid - 1 do
			for tx = 0, grid - 1 do
				Panels.renderMandelbrotTile(tile, size, tx, ty, grid)
				for y = 0, size - 1 do
					buffer.copy(full, ((ty * size + y) * size * grid + tx * size) * 4, tile, y * size * 4, size * 4)
				end
			end
		end
	end)
	dump("mandel", full, size * grid, size * grid)
end

if want("green") then
	local g = buffer.create(256 * 256 * 4)
	local m = buffer.create(256 * 256 * 4)
	local c = buffer.create(256 * 256 * 4)
	timed("greenscreen256", function()
		Panels.renderGreenScreen(g, 256, 256)
	end)
	timed("keyMatte256", function()
		Panels.keyMatte(g, 256, 256, m, c)
	end)
	dump("green", g, 256, 256)
	dump("matte", m, 256, 256)
	dump("cutout", c, 256, 256)
end

if want("allan") then
	local Liquid = require("../src/Liquid")
	local Models = require("../gallery/shared/AlnModels")
	for _, name in Models.names do
		local blob = Models.load(name)
		local model, tree = Liquid.decode(blob)
		local plan = Liquid.prepare(model, tree, Models.scale(name))
		for level = 0, (if name == "ui_flat_256" then 2 else 0) do
			local w, h = Liquid.outputSize(plan, level)
			local out = buffer.create(w * h * 4)
			local stats
			timed("allan " .. name .. " level " .. level, function()
				stats = Liquid.render(plan, tree, out, w, { level = level })
			end)
			print(string.format("NOTE allan %s level %d: %d bytes of model, %d events for %d rows", name, level, Models.bytes(name), stats.segments, stats.rows))
			dump("allan_" .. name .. "_L" .. level, out, w, h)
		end
	end
end
