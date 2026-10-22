--!native
--!optimize 2
-- universe-at-home :: bench/compute.luau
--
-- Benchmarks and quality measurements for the src/compute prototypes
-- (docs/COMPUTE.md). Every time is the minimum over in-process repeats, reported
-- as milliseconds for a full 1024 x 1024 frame (sampled kernels are scaled and
-- say so in their name). Quality numbers are deterministic and identical in both
-- runtimes.
--
--   luau bench/compute.luau             (interpreter, what clients run)
--   luau --codegen bench/compute.luau   (native, what servers can run)
--
-- tools/run_compute_bench.sh runs both, interleaved, three rounds; then
-- tools/merge_compute.py keeps the per-key minimum (other agents share the
-- machine's 4 cores, so the minimum is the least disturbed run).
--
-- Output lines: RESULT <TAB> group <TAB> name <TAB> value <TAB> unit

local MyMath = require("../src/MyMath")
local Pixels = require("../src/Pixels")
local Coverage = require("../src/compute/Coverage")
local Raster = require("../src/compute/Raster")
local Scanline = require("../src/compute/Scanline")
local Distance = require("../src/compute/Distance")
local Filter = require("../src/compute/Filter")
local Tiles = require("../src/compute/Tiles")
local Expr = require("../src/compute/Expr")
local Rows = require("../src/compute/Rows")
local Trace = require("../src/compute/Trace")
local ExprDemoRow = require("./generated/ExprDemoRow")

local clock = os.clock
local S = 1024
local FRAME = S * S

local function emit(group: string, name: string, value: number, unit: string)
	print(string.format("RESULT\t%s\t%s\t%.3f\t%s", group, name, value, unit))
end

-- minimum wall time of f over n runs, in ms
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

local function time(group: string, name: string, n: number, f: () -> (), scale: number?)
	emit(group, name, best(n, f) * (scale or 1), "ms")
end

local img = buffer.create(FRAME * 4)
local img2 = buffer.create(FRAME * 4)

----------------------------------------------------------------------------------
-- Calibration (docs/RUNTIME_AUDIT.md 6.6: 10.3 ms interpreter O2, 2.9 ms native)
----------------------------------------------------------------------------------

time("calibration", "writeu32 constant, 1024^2", 5, function()
	for i = 0, FRAME - 1 do
		buffer.writeu32(img, i * 4, 0xFF102030)
	end
end)

----------------------------------------------------------------------------------
-- Quadtree SDF rasterizer, 256 shapes
----------------------------------------------------------------------------------

do
	for _, mode in { Raster.MODE_LINEAR, Raster.MODE_EXACT } do
		local label = if mode == Raster.MODE_LINEAR then "linear" else "exact"
		local sc = Raster.demoScene(256, S, 7, nil, mode)
		local bins = Raster.bin(sc, S, S)
		time("raster", "bin 256 shapes into 64px tiles", 3, function()
			Raster.bin(sc, S, S)
		end)
		for _, leaf in { 4, 8 } do
			time("raster", string.format("quadtree render, 256 shapes, %s, leaf %d", label, leaf), 3, function()
				Raster.render(sc, bins, img, S, S, leaf)
			end)
		end
		-- brute force on 16 rows, scaled to the frame
		local rows = {}
		for i = 0, 15 do
			table.insert(rows, i * 64 + 31)
		end
		time("raster", string.format("brute force, 256 shapes, %s (16 rows x 64)", label), 1, function()
			Raster.renderBrute(sc, img2, S, S, rows)
		end, 64)
		-- dirty update: move one mid-size shape, re-render the tiles it touched
		local s = 40
		time("raster", string.format("dirty update after moving 1 shape, %s", label), 3, function()
			local before = { sc.bx0[s], sc.by0[s], sc.bx1[s], sc.by1[s] }
			Raster.move(sc, s, 3, 2)
			local after = { sc.bx0[s], sc.by0[s], sc.bx1[s], sc.by1[s] }
			local b2 = Raster.bin(sc, S, S)
			Raster.renderDirty(sc, b2, img, S, S, { before, after }, 4)
			Raster.move(sc, s, -3, -2)
		end)
		if mode == Raster.MODE_LINEAR then
			time("raster", "painter (bbox per shape, 8-bit RMW), linear", 2, function()
				Raster.renderPainter(sc, img2, S, S)
			end)
		end
		-- time slicing: tiles finished inside an 8 ms slice
		local order = Tiles.ringOrder(bins.tilesX, bins.tilesY, 8, 8)
		local deadline = clock() + 0.008
		local nextTile = Raster.renderUntil(sc, bins, img, S, S, order, 1, deadline, 4)
		emit("raster", string.format("tiles of 64px finished in one 8 ms slice, %s", label), nextTile - 1, "count")
	end
end

----------------------------------------------------------------------------------
-- Coverage quality against exact area (deterministic; 1/255 units)
----------------------------------------------------------------------------------

do
	local W = 160
	local function maxErr(build: (Raster.Scene) -> (), exact: (number, number) -> number, x0: number, y0: number, x1: number, y1: number, mode: number): number
		local sc = Raster.newScene(0x00000000, 1, mode)
		build(sc)
		local out = buffer.create(W * W * 4)
		Raster.renderBrute(sc, out, W, W)
		local m = 0
		for y = y0, y1 do
			for x = x0, x1 do
				local e = math.abs(buffer.readu8(out, (y * W + x) * 4 + 3) - 255 * exact(x, y))
				if e > m then
					m = e
				end
			end
		end
		return m
	end
	for _, R in { 2.5, 20, 300 } do
		local cx, cy = 80.3, 79.6
		local Wd = if R > 70 then 0 else 1
		if Wd == 1 then
			for _, mode in { Raster.MODE_LINEAR, Raster.MODE_EXACT } do
				emit("quality", string.format("circle R=%g, %s", R, if mode == 0 then "linear" else "exact"), maxErr(function(sc)
					Raster.circle(sc, 0xFFFFFFFF, cx, cy, R)
				end, function(x, y)
					return Coverage.circleArea(cx, cy, R, x, y)
				end, math.floor(cx - R - 2), math.floor(cy - R - 2), math.ceil(cx + R + 2), math.ceil(cy + R + 2), mode), "err255")
			end
		end
	end
	local pts = {}
	for k = 0, 9 do
		local rr = if k % 2 == 0 then 60 else 27
		local t = 0.03 + k / 10
		table.insert(pts, 80.3 + MyMath.dcosTurns(t) * rr)
		table.insert(pts, 79.7 + MyMath.dsinTurns(t) * rr)
	end
	for _, mode in { Raster.MODE_LINEAR, Raster.MODE_EXACT } do
		emit("quality", string.format("star r=60, %s", if mode == 0 then "linear" else "exact"), maxErr(function(sc)
			Raster.polygon(sc, 0xFFFFFFFF, pts)
		end, function(x, y)
			return Coverage.polygonArea(pts, x, y)
		end, 15, 15, 145, 145, mode), "err255")
	end
	-- scanline exact polygon and the conflation seam
	local acc = Scanline.new(W, W)
	local dst = buffer.create(W * W * 4)
	local function err(ref: { number }): number
		local m = 0
		for y = 0, W - 1 do
			for x = 0, W - 1 do
				local e = math.abs(buffer.readu8(dst, (y * W + x) * 4 + 3) - 255 * Coverage.polygonArea(ref, x, y))
				if e > m then
					m = e
				end
			end
		end
		return m
	end
	Scanline.addPolygon(acc, pts)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	emit("quality", "star r=60, scanline exact area", err(pts), "err255")
	local A = { 20.3, 20.7, 140.1, 20.7, 140.1, 139.6 }
	local B = { 20.3, 20.7, 140.1, 139.6, 20.3, 139.6 }
	local sq = { 20.3, 20.7, 140.1, 20.7, 140.1, 139.6, 20.3, 139.6 }
	buffer.fill(dst, 0, 0)
	Scanline.addPolygon(acc, A)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	Scanline.addPolygon(acc, B)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	emit("quality", "two triangles sharing an edge, separate layers (conflation)", err(sq), "err255")
	buffer.fill(dst, 0, 0)
	Scanline.addPolygon(acc, A)
	Scanline.addPolygon(acc, B)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	emit("quality", "two triangles sharing an edge, one accumulator", err(sq), "err255")
	-- C5: estimator error (before byte rounding), worst over 16 sub-pixel placements
	for _, Rr in { 1.5, 2.5, 4, 8, 16 } do
		local wH, wC = 0, 0
		for k = 0, 15 do
			local ccx, ccy = 40 + k * 0.0625 + Rr, 40.3 + ((k * 7) % 16) * 0.0625 + Rr
			local x0, y0 = math.floor(ccx - Rr - 2), math.floor(ccy - Rr - 2)
			local x1, y1 = math.ceil(ccx + Rr + 2), math.ceil(ccy + Rr + 2)
			local function exact(x: number, y: number): number
				return Coverage.circleArea(ccx, ccy, Rr, x, y)
			end
			local a = Coverage.compare(x0, y0, x1, y1, function(x, y)
				return Coverage.circleHalfPlane(x + 0.5, y + 0.5, ccx, ccy, Rr)
			end, exact)
			local b = Coverage.compare(x0, y0, x1, y1, function(x, y)
				return Coverage.circleCurved(x + 0.5, y + 0.5, ccx, ccy, Rr)
			end, exact)
			wH = math.max(wH, a.max)
			wC = math.max(wC, b.max)
		end
		emit("quality", string.format("circle R=%g, half-plane estimator, worst of 16 placements", Rr), wH, "err255")
		emit("quality", string.format("circle R=%g, curvature-corrected estimator, worst of 16 placements", Rr), wC, "err255")
	end
	-- C14: bilinear magnification of a low-resolution distance field to 1024
	local function magnify(sdf: (number, number) -> number, N: number): number
		local h = 1024 / N
		local tex = table.create(N * N, 0)
		for j = 0, N - 1 do
			for i = 0, N - 1 do
				tex[j * N + i + 1] = sdf((i + 0.5) * h, (j + 0.5) * h)
			end
		end
		local function T(i: number, j: number): number
			i = if i < 0 then 0 elseif i > N - 1 then N - 1 else i
			j = if j < 0 then 0 elseif j > N - 1 then N - 1 else j
			return tex[j * N + i + 1]
		end
		local worst = 0
		for y = 0, 1023, 3 do
			for x = 0, 1023, 3 do
				local px, py = x + 0.5, y + 0.5
				local t = sdf(px, py)
				if math.abs(t) < 1 then
					local u, v = px / h - 0.5, py / h - 0.5
					local i0, j0 = math.floor(u), math.floor(v)
					local fu, fv = u - i0, v - j0
					local a = T(i0, j0) + (T(i0 + 1, j0) - T(i0, j0)) * fu
					local b = T(i0, j0 + 1) + (T(i0 + 1, j0 + 1) - T(i0, j0 + 1)) * fu
					local e = math.abs(a + (b - a) * fv - t)
					if e > worst then
						worst = e
					end
				end
			end
		end
		return worst * 255
	end
	local function bigCircle(x: number, y: number): number
		local dx, dy = x - 512.3, y - 497.6
		return math.sqrt(dx * dx + dy * dy) - 300
	end
	local function bigBox(x: number, y: number): number
		local qx, qy = math.abs(x - 512.3) - 300, math.abs(y - 497.6) - 200
		local ox, oy = math.max(qx, 0), math.max(qy, 0)
		return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0)
	end
	for _, N in { 64, 128, 256, 512 } do
		emit("quality", string.format("SDF %d^2 magnified to 1024, circle R=300", N), magnify(bigCircle, N), "err255")
	end
	for _, N in { 256, 512 } do
		emit("quality", string.format("SDF %d^2 magnified to 1024, sharp box corners", N), magnify(bigBox, N), "err255")
	end
	-- supersampling as a would-be reference
	local cx, cy, R = 144.37, 144.81, 80
	local function inside(x: number, y: number): boolean
		local dx, dy = x - cx, y - cy
		return dx * dx + dy * dy <= R * R
	end
	for _, n in { 4, 16 } do
		local st = Coverage.compare(60, 60, 230, 230, function(x, y)
			return Coverage.supersample(inside, x, y, n)
		end, function(x, y)
			return Coverage.circleArea(cx, cy, R, x, y)
		end)
		emit("quality", string.format("circle R=80, %dx%d supersampling", n, n), st.max, "err255")
	end
end

----------------------------------------------------------------------------------
-- Vector polygons: scanline exact-area painter vs the SDF raster, 256 stars
----------------------------------------------------------------------------------

do
	local stars = {}
	local h = 12345
	local function rnd(): number
		h = MyMath.hash32((h + 0x9E3779B9) % 4294967296)
		return h / 4294967296
	end
	for i = 1, 256 do
		local cx, cy, r = rnd() * S, rnd() * S, 4 + rnd() * 60
		local p = {}
		for k = 0, 9 do
			local rr = if k % 2 == 0 then r else r * 0.45
			table.insert(p, cx + MyMath.dcosTurns(k / 10 + 0.05) * rr)
			table.insert(p, cy + MyMath.dsinTurns(k / 10 + 0.05) * rr)
		end
		stars[i] = { p = p, c = ((rnd() * 0xFFFFFF) // 1) + 0xFF000000 }
	end
	local acc = Scanline.new(S, S)
	time("vector", "256 stars, scanline exact-area painter", 3, function()
		Pixels.fill(img, 0xFF201810)
		for i = 1, 256 do
			Scanline.addPolygon(acc, stars[i].p)
			Scanline.composite(acc, img, stars[i].c)
		end
	end)
	for _, mode in { Raster.MODE_LINEAR, Raster.MODE_EXACT } do
		local sc = Raster.newScene(0xFF201810, 1, mode)
		for i = 1, 256 do
			Raster.polygon(sc, stars[i].c, stars[i].p)
		end
		local bins = Raster.bin(sc, S, S)
		time("vector", string.format("256 stars, SDF quadtree raster, %s, leaf 8", if mode == 0 then "linear" else "exact"), 2, function()
			Raster.render(sc, bins, img, S, S, 8)
		end)
	end
end

----------------------------------------------------------------------------------
-- Row kernels: one exact-coverage disc R = 300
----------------------------------------------------------------------------------

do
	local cx, cy, r = 512.375, 500.8125, 300
	time("rows", "disc R=300 exact coverage, direct per pixel", 3, function()
		for y = 0, S - 1 do
			Rows.circleDirect(img, S, y, cx, cy, r, 0x3366CC)
		end
	end)
	time("rows", "disc R=300, forward-differenced e = dx^2 + dy^2", 3, function()
		for y = 0, S - 1 do
			Rows.circleFD(img, S, y, cx, cy, r, 0x3366CC)
		end
	end)
	time("rows", "disc R=300, analytic spans (band only)", 5, function()
		for y = 0, S - 1 do
			Rows.circleSpans(img, S, y, cx, cy, r, 0x3366CC)
		end
	end)
end

----------------------------------------------------------------------------------
-- Distance transforms (mask of value-noise blobs)
----------------------------------------------------------------------------------

do
	local function mask(w: number, seed: number): buffer
		local m = buffer.create(w * w)
		for y = 0, w - 1 do
			for x = 0, w - 1 do
				if MyMath.valueNoise2(x / 37, y / 37, seed) > 0.62 then
					buffer.writeu8(m, y * w + x, 1)
				end
			end
		end
		return m
	end
	local m = mask(S, 5)
	time("distance", "exact EDT (Felzenszwalb-Huttenlocher)", 3, function()
		Distance.edt(m, S, S)
	end)
	time("distance", "8SSEDT (approximate)", 2, function()
		Distance.ssedt8(m, S, S)
	end)
	local m512 = mask(512, 5)
	time("distance", "jump flooding (approximate), 512^2 scaled x4", 1, function()
		Distance.jfa(m512, 512, 512)
	end, 4)
	-- background removal: signed distance from a mask, then a 2 px feathered matte
	time("distance", "matte: signed EDT (2 transforms) + feathered alpha", 2, function()
		local sd = Distance.signed(m, S, S)
		Distance.applyMatte(img, sd, FRAME, 2)
	end)
	-- quality of the approximate transforms on a 256^2 mask (exact = brute force)
	local w = 256
	local mm = buffer.create(w * w)
	for i = 0, w * w - 1 do
		if MyMath.rand2(i % w, i // w, 17) < 0.0004 then
			buffer.writeu8(mm, i, 1)
		end
	end
	local ref = Distance.edt(mm, w, w)
	for _, alg in { "jfa", "ssedt8" } do
		local got = if alg == "jfa" then Distance.jfa(mm, w, w) else Distance.ssedt8(mm, w, w)
		local wrong, maxe = 0, 0
		for i = 0, w * w - 1 do
			local a, b = buffer.readu32(ref, i * 4), buffer.readu32(got, i * 4)
			if a ~= b then
				wrong += 1
				local e = math.sqrt(b) - math.sqrt(a)
				if e > maxe then
					maxe = e
				end
			end
		end
		emit("quality", string.format("%s wrong pixels of 65536 (sparse seeds)", alg), wrong, "count")
		emit("quality", string.format("%s max distance error (sparse seeds)", alg), maxe, "px")
	end
end

----------------------------------------------------------------------------------
-- Filters
----------------------------------------------------------------------------------

do
	for i = 0, FRAME - 1 do
		buffer.writeu32(img, i * 4, MyMath.hash32(i))
	end
	time("filter", "box blur r=8 (running sums, SWAR)", 3, function()
		Filter.boxBlur(img, S, S, 8, img2)
	end)
	time("filter", "box blur r=100 (same cost)", 2, function()
		Filter.boxBlur(img, S, S, 100, img2)
	end)
	local sat = Filter.satBuild(img, S, S)
	time("filter", "summed-area table build (4 x u32 planes)", 3, function()
		sat = Filter.satBuild(img, S, S)
	end)
	time("filter", "SAT resample 1024 -> 737 (any footprint)", 1, function()
		Filter.satResample(sat, 737, 737)
	end)
	time("filter", "area resample 1024 -> 737 (exact, integer weights)", 3, function()
		Filter.areaResample(img, S, S, 737, 737)
	end)
	time("filter", "area resample 1024 -> 512", 3, function()
		Filter.areaResample(img, S, S, 512, 512)
	end)
	time("filter", "SWAR 2x2 box mip 1024 -> 512 (Pixels.downsample2x)", 3, function()
		Pixels.downsample2x(img, S, S)
	end)
	local hb = buffer.create(FRAME)
	for i = 0, FRAME - 1 do
		buffer.writeu8(hb, i, (MyMath.valueNoise2((i % S) / 37, (i // S) / 37, 9) * 255) // 1)
	end
	time("filter", "height field -> normal map", 3, function()
		Filter.normalMap(hb, S, S, 4, img2)
	end)
end

----------------------------------------------------------------------------------
-- Tiles: Morton codes, content-addressed dedup
----------------------------------------------------------------------------------

do
	local acc = 0
	time("tiles", "Morton encode, bit32 part1by1 (1M codes)", 3, function()
		for i = 0, FRAME - 1 do
			acc += Tiles.morton(i % 1024, i // 1024)
		end
	end)
	time("tiles", "Morton encode, byte lookup table (1M codes)", 3, function()
		for i = 0, FRAME - 1 do
			acc += Tiles.mortonLUT(i % 1024, i // 1024)
		end
	end)
	local sc = Raster.demoScene(64, S, 7, nil, Raster.MODE_EXACT)
	Raster.render(sc, Raster.bin(sc, S, S), img, S, S, 8)
	for _, ts in { 16, 64 } do
		local store = Tiles.newStore(ts)
		local grid = Tiles.fromImage(store, img, S, S)
		time("tiles", string.format("intern a 1024^2 image as %dpx tiles (string keys)", ts), 3, function()
			store = Tiles.newStore(ts)
			grid = Tiles.fromImage(store, img, S, S)
		end)
		emit("tiles", string.format("unique %dpx tiles, 64-shape scene (of %d)", ts, (S // ts) * (S // ts)), store.unique, "count")
		time("tiles", string.format("compose %dpx tiles into a frame", ts), 3, function()
			Tiles.compose(grid, img2)
		end)
	end
	assert(acc >= 0)
end

----------------------------------------------------------------------------------
-- Expression evaluation strategies (45-node SDF expression, no culling)
----------------------------------------------------------------------------------

do
	local root = Expr.demo(16, S, 11)
	local prog = Expr.compile(root)
	local fc = Expr.closure(root)
	local regs = table.create(prog.nregs, 0)
	local rowsReg = Expr.newRows(prog, S)
	local outRow = table.create(S, 0)
	local loadFn: ((string) -> any)? = (_G :: any).loadstring
	local acc = 0
	local function sampled(name: string, f: (y: number) -> ())
		time("expr", name .. " (128 rows x 8)", 3, function()
			for y = 0, S - 1, 8 do
				f(y)
			end
		end, 8)
	end
	sampled("closure tree, per pixel", function(y)
		local py = y + 0.5
		for x = 0, S - 1 do
			acc += fc(x + 0.5, py)
		end
	end)
	sampled("op array interpreter, per pixel", function(y)
		local py = y + 0.5
		for x = 0, S - 1 do
			acc += Expr.run(prog, regs, x + 0.5, py)
		end
	end)
	sampled("op array interpreter, column at a time per row", function(y)
		acc += Expr.runRow(prog, rowsReg, y, 0, S)[1]
	end)
	sampled("build-time generated module, row kernel", function(y)
		ExprDemoRow(outRow, y, 0, S)
		acc += outRow[1]
	end)
	if loadFn then
		local fs = loadFn(Expr.source(prog))()
		local fsr = loadFn(Expr.sourceRow(prog))()
		sampled("loadstring per pixel", function(y)
			local py = y + 0.5
			for x = 0, S - 1 do
				acc += fs(x + 0.5, py)
			end
		end)
		sampled("loadstring row kernel", function(y)
			fsr(outRow, y, 0, S)
			acc += outRow[1]
		end)
		-- Roblox documents that loadstring "disables certain Luau optimizations":
		-- the chunk's environment is not safe, so builtins lose their fast path
		local unsafe = loadFn(Expr.sourceRow(prog))
		setfenv(unsafe, setmetatable({}, { __index = _G }))
		local fsrU = unsafe()
		sampled("loadstring row kernel, unsafe env (Roblox-like)", function(y)
			fsrU(outRow, y, 0, S)
			acc += outRow[1]
		end)
	end
	for _, cls in { "lipschitz", "interval" } do
		local st = Expr.renderQuad(root, fc, cls, 1, img, S, 0xFFFFFF, 8)
		time("expr", string.format("quadtree render, %s classification, leaf 8", cls), 3, function()
			st = Expr.renderQuad(root, fc, cls, 1, img, S, 0xFFFFFF, 8)
		end)
		emit("expr", string.format("pixels shaded, %s classification", cls), st.shaded, "count")
	end
	assert(acc == acc)
end

----------------------------------------------------------------------------------
-- Sphere tracing a 3D SDF to a normal map
----------------------------------------------------------------------------------

do
	local size = 256
	local sc = Trace.demo(size)
	local n = buffer.create(size * size * 4)
	local hgt = buffer.create(size * size)
	local st = Trace.render(sc, size, n, hgt, 64, 0.01)
	time("trace", "sphere-traced normal map 256^2, scaled x16", 2, function()
		st = Trace.render(sc, size, n, hgt, 64, 0.01)
	end, 16)
	emit("trace", "steps per ray (256^2)", st.steps / st.rays, "count")
end

print("done")
