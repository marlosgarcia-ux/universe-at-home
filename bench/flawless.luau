--!native
--!optimize 2
-- universe-at-home :: bench/flawless.luau
--
-- Cost of the flawless pipeline (docs/COMPUTE.md "Flawless pipeline") against the
-- linear preview ramp, at 1024 x 1024:
--   * the 256-shape demo scene (Raster.demoScene(256, 1024, 7)), leaf 4:
--     MODE_LINEAR (preview), MODE_LAYERED (exact coverage F1, composited as alpha),
--     MODE_EXACT (flawless: F1 + exact visibility F2), with conflict-pixel counts;
--   * two seam-heavy scenes where every edge is shared: a jittered mesh of 4608
--     triangles, and a field of 64 pie charts (384 slices);
--   * the triangle mesh through the scanline painter: per-path Scanline.composite
--     (conflates) against Scanline.renderScene (exact).
-- Every time is the minimum over in-process repeats, ms per full frame.
--
--   luau bench/flawless.luau             (interpreter, what clients run)
--   luau --codegen bench/flawless.luau   (native, what servers can run)
--
-- tools/run_flawless_bench.sh runs both, interleaved, three rounds, and merges
-- with tools/merge_compute.py (per-key minimum: other agents share the 4 cores).
--
-- Output lines: RESULT <TAB> group <TAB> name <TAB> value <TAB> unit

local MyMath = require("../src/MyMath")
local Raster = require("../src/compute/Raster")
local Scanline = require("../src/compute/Scanline")
local Visibility = require("../src/compute/Visibility")
local Pixels = require("../src/Pixels")

local clock = os.clock
local S = 1024
local FRAME = S * S

local function emit(group: string, name: string, value: number, unit: string)
	print(string.format("RESULT\t%s\t%s\t%.3f\t%s", group, name, value, unit))
end

local function best(n: number, f: () -> ()): number
	local b = math.huge
	for _ = 1, n do
		local t = clock()
		f()
		local d = clock() - t
		if d < b then
			b = d
		end
	end
	return b * 1000
end

local img = buffer.create(FRAME * 4)

emit("calibration", "writeu32 constant, 1024^2", best(5, function()
	for i = 0, FRAME - 1 do
		buffer.writeu32(img, i * 4, 0xFF102030)
	end
end), "ms")

local MODES = { Raster.MODE_LINEAR, Raster.MODE_LAYERED, Raster.MODE_EXACT }
local MODE_NAMES = { "linear (preview)", "exact coverage, alpha compositing (F1)", "flawless (F1 + F2)" }

-- renders scene sc in every mode; reports time, conflict pixels and their share
local function raster(group: string, label: string, build: (mode: number) -> Raster.Scene, leaf: number, reps: number)
	for i, mode in MODES do
		local sc = build(mode)
		local bins = Raster.bin(sc, S, S)
		local t = best(reps, function()
			Raster.render(sc, bins, img, S, S, leaf)
		end)
		emit(group, string.format("%s, %s", label, MODE_NAMES[i]), t, "ms")
		if mode == Raster.MODE_EXACT then
			Raster.resetStats()
			Visibility.resetStats()
			Raster.render(sc, bins, img, S, S, leaf)
			emit(group, label .. ", conflict pixels", Raster.stats.conflicts, "count")
			emit(group, label .. ", conflict pixels per million", Raster.stats.conflicts / FRAME * 1e6, "ppm")
			emit(group, label .. ", exact region areas", Visibility.stats.areas, "count")
			emit(group, label .. ", visibility term cap reached", Visibility.stats.capped, "count")
		end
	end
end

----------------------------------------------------------------------------------
-- 256-shape demo scene
----------------------------------------------------------------------------------

raster("demo", "256 shapes, leaf 4", function(mode)
	return Raster.demoScene(256, S, 7, nil, mode)
end, 4, 3)

----------------------------------------------------------------------------------
-- Seam-heavy scenes: every edge is shared by two shapes
----------------------------------------------------------------------------------

local N = 48 -- mesh cells per side: 2 * 48 * 48 = 4608 triangles
local grid: { number } = {}
do
	local h = 31337
	local function rnd(): number
		h = MyMath.hash32((h + 0x9E3779B9) % 4294967296)
		return h / 4294967296
	end
	local cell = S / N
	for j = 0, N do
		for i = 0, N do
			local jx = if i == 0 or i == N then 0 else (rnd() - 0.5) * cell * 0.3
			local jy = if j == 0 or j == N then 0 else (rnd() - 0.5) * cell * 0.3
			grid[2 * (j * (N + 1) + i) + 1] = i * cell + jx
			grid[2 * (j * (N + 1) + i) + 2] = j * cell + jy
		end
	end
end
local function vtx(i: number, j: number): (number, number)
	local k = 2 * (j * (N + 1) + i)
	return grid[k + 1], grid[k + 2]
end
local triangles: { { number } } = {}
local triColors: { number } = {}
do
	local h = 777
	for j = 0, N - 1 do
		for i = 0, N - 1 do
			local ax, ay = vtx(i, j)
			local bx, by = vtx(i + 1, j)
			local cx, cy = vtx(i + 1, j + 1)
			local dx, dy = vtx(i, j + 1)
			for _, t in { { ax, ay, bx, by, cx, cy }, { ax, ay, cx, cy, dx, dy } } do
				h = MyMath.hash32(h + 1)
				table.insert(triangles, t)
				table.insert(triColors, 0xFF000000 + h % 0x1000000)
			end
		end
	end
end

raster("seams", string.format("triangle mesh, %d triangles", #triangles), function(mode)
	local sc = Raster.newScene(0xFF000000, 1, mode)
	for k, t in triangles do
		Raster.polygon(sc, triColors[k], t)
	end
	return sc
end, 4, 2)

raster("seams", "64 pie charts of 6 slices", function(mode)
	local sc = Raster.newScene(0xFF101010, 1, mode)
	local h = 4242
	local function rnd(): number
		h = MyMath.hash32((h + 0x9E3779B9) % 4294967296)
		return h / 4294967296
	end
	for j = 0, 7 do
		for i = 0, 7 do
			local cx, cy = (i + 0.5) * 128 + (rnd() - 0.5) * 8, (j + 0.5) * 128 + (rnd() - 0.5) * 8
			local r = 40 + rnd() * 20
			local rot = rnd()
			local dirs: { number } = {}
			for k = 0, 5 do
				dirs[2 * k + 1] = MyMath.dcosTurns(rot + k / 6)
				dirs[2 * k + 2] = MyMath.dsinTurns(rot + k / 6)
			end
			for k = 0, 5 do
				local a, b = 2 * k + 1, 2 * ((k + 1) % 6) + 1
				Raster.pie(sc, 0xFF000000 + (rnd() * 0xFFFFFF) // 1, cx, cy, r, dirs[a], dirs[a + 1], dirs[b], dirs[b + 1])
			end
		end
	end
	return sc
end, 4, 2)

-- the same triangle mesh through the scanline painter
do
	local acc = Scanline.new(S, S)
	emit("seams", "triangle mesh, Scanline.composite per path (conflates, C11)", best(2, function()
		Pixels.fill(img, 0xFF000000)
		for k, t in triangles do
			Scanline.addPolygon(acc, t)
			Scanline.composite(acc, img, triColors[k])
		end
	end), "ms")
	local paths: { Scanline.Path } = {}
	for k, t in triangles do
		paths[k] = { contours = { t }, color = triColors[k] }
	end
	local st: Scanline.SceneStats = { conflicts = 0, disjoint = 0, floatPixels = 0, spans = 0 }
	emit("seams", "triangle mesh, Scanline.renderScene (exact, F2)", best(2, function()
		st = Scanline.renderScene(img, S, S, paths, 0xFF000000)
	end), "ms")
	emit("seams", "triangle mesh, Scanline.renderScene conflict pixels", st.conflicts, "count")
	emit("seams", "triangle mesh, Scanline.renderScene pixels composited in floating point", st.floatPixels, "count")
end

print("done")
