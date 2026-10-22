--!strict
-- Correctness of the src/compute prototypes (docs/COMPUTE.md). Every check is an
-- assertion; tests/run.sh runs this file in the interpreter and with --codegen.
-- Cross-runtime identity (COMPUTE.md F3): each prototype's output is hashed and
-- compared against a constant, so both runtimes must produce the same bytes.

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
local ExprDemoRow = require("../bench/generated/ExprDemoRow")

local PRINT_HASHES = false -- set true to regenerate the constants below

-- Order-dependent 32-bit-ish hash of a buffer's u32 words (exact in doubles).
local function hashWords(b: buffer, count: number): number
	local h = 0
	for i = 0, count - 1 do
		h = (h * 31 + buffer.readu32(b, i * 4)) % 4294967291
	end
	return h
end

local function hashBytes(b: buffer): number
	local h = 0
	for i = 0, buffer.len(b) - 1 do
		h = (h * 31 + buffer.readu8(b, i)) % 4294967291
	end
	return h
end

local hashes: { [string]: number } = {}
local function checkHash(name: string, got: number, want: number)
	hashes[name] = got
	if not PRINT_HASHES then
		assert(got == want, string.format("%s: hash %d, expected %d (runtimes or platforms differ)", name, got, want))
	end
end

local function star(cx: number, cy: number, r: number, phase: number): { number }
	local pts = {}
	for k = 0, 9 do
		local rr = if k % 2 == 0 then r else r * 0.45
		local t = phase + k / 10
		table.insert(pts, cx + MyMath.dcosTurns(t) * rr)
		table.insert(pts, cy + MyMath.dsinTurns(t) * rr)
	end
	return pts
end

local function arcPts(pts: { number }, cx: number, cy: number, r: number, t0: number, t1: number, n: number)
	for i = 0, n do
		local t = t0 + (t1 - t0) * i / n
		table.insert(pts, cx + r * MyMath.dcosTurns(t))
		table.insert(pts, cy + r * MyMath.dsinTurns(t))
	end
end

----------------------------------------------------------------------------------
-- 1. Coverage primitives
----------------------------------------------------------------------------------

do
	local worst = 0
	for i = -1000, 1000 do
		local x = i / 1000
		local e = math.abs(Coverage.dasin(x) - math.asin(x))
		if e > worst then
			worst = e
		end
	end
	assert(worst < 1e-12, "dasin accuracy " .. worst)

	local wa = 0
	for _, R in { 0.3, 1.5, 7, 40 } do
		for k = 0, 6 do
			local cx, cy = 10 + k * 0.137, 10.3 + k * 0.071
			for y = 0, 20 do
				for x = 0, 20 do
					local e = math.abs(Coverage.circleArea(cx, cy, R, x, y) - Coverage.discRectArea(cx, cy, R, x, y, x + 1, y + 1))
					if e > wa then
						wa = e
					end
				end
			end
		end
	end
	assert(wa < 1e-10, "discRectArea vs circleArea " .. wa)

	-- C3: the linear ramp's worst error on a 45 degree edge is (sqrt(2)/2 - 1/2)^2
	local s = 0.70710678118654757
	local worst45 = 0
	for i = 0, 2000 do
		local d = -1 + i / 1000
		local e = math.abs(Coverage.linear(d, 1) - Coverage.halfPlane(d, s, s))
		if e > worst45 then
			worst45 = e
		end
	end
	assert(math.abs(worst45 - (s - 0.5) ^ 2) < 1e-6, "C3 closed form " .. worst45)

	-- C4: half-plane coverage equals the exact area for straight edges
	local hpWorst = 0
	for t = 1, 200 do
		local ang = MyMath.rand2(t, 1, 3)
		local nx, ny = MyMath.dcosTurns(ang), MyMath.dsinTurns(ang)
		local d = MyMath.rand2(t, 2, 3) * 1.6 - 0.8
		-- half-plane n . (q - c) <= -d around pixel centre c = (0.5, 0.5), as a big polygon
		local px, py = 0.5 - d * nx, 0.5 - d * ny -- point on the line
		local tx, ty = -ny, nx
		local L = 50
		local poly = {
			px + tx * L, py + ty * L,
			px - tx * L, py - ty * L,
			px - tx * L - nx * L, py - ty * L - ny * L,
			px + tx * L - nx * L, py + ty * L - ny * L,
		}
		local e = math.abs(Coverage.halfPlane(d, nx, ny) - Coverage.polygonArea(poly, 0, 0))
		if e > hpWorst then
			hpWorst = e
		end
	end
	assert(hpWorst < 1e-9, "half-plane exactness " .. hpWorst)
end

----------------------------------------------------------------------------------
-- 2. Raster: quadtree render == brute force, both modes; exact-mode accuracy
----------------------------------------------------------------------------------

do
	for _, cfg in { { 256, 64, 8 }, { 256, 64, 4 }, { 128, 300, 4 } } do
		for _, mode in { Raster.MODE_LINEAR, Raster.MODE_EXACT } do
			local size, n, leaf = cfg[1], cfg[2], cfg[3]
			local sc = Raster.demoScene(n, size, 7, nil, mode)
			local a = buffer.create(size * size * 4)
			local b = buffer.create(size * size * 4)
			Raster.renderBrute(sc, a, size, size)
			Raster.render(sc, Raster.bin(sc, size, size), b, size, size, leaf)
			assert(Pixels.diff(a, b, size * size) == 0, string.format("render != brute (size %d n %d leaf %d mode %d)", size, n, leaf, mode))
			if size == 256 and leaf == 8 then
				checkHash("raster mode " .. mode, hashWords(b, size * size), if mode == 0 then 657927456 else 2126128460)
			end
		end
	end

	-- dirty re-render after a move equals a full render
	local size = 256
	local sc = Raster.demoScene(64, size, 9, nil, Raster.MODE_EXACT)
	local bins = Raster.bin(sc, size, size)
	local img = buffer.create(size * size * 4)
	Raster.render(sc, bins, img, size, size, 8)
	local s = 5
	local before = { sc.bx0[s], sc.by0[s], sc.bx1[s], sc.by1[s] }
	Raster.move(sc, s, 13.25, -7.5)
	local after = { sc.bx0[s], sc.by0[s], sc.bx1[s], sc.by1[s] }
	bins = Raster.bin(sc, size, size)
	Raster.renderDirty(sc, bins, img, size, size, { before, after }, 8)
	local full = buffer.create(size * size * 4)
	Raster.render(sc, bins, full, size, size, 8)
	assert(Pixels.diff(img, full, size * size) == 0, "dirty re-render differs from full render")

	-- per-shape accuracy against exact area (alpha byte of a white shape on clear)
	local function maxErr(build: (Raster.Scene) -> (), exact: (number, number) -> number, x0: number, y0: number, x1: number, y1: number, mode: number): number
		local W = 160
		local scene = Raster.newScene(0x00000000, 1, mode)
		build(scene)
		local out = buffer.create(W * W * 4)
		Raster.renderBrute(scene, out, W, W)
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
	local EXACT = Raster.MODE_EXACT
	local F1 = 0.51 -- correctly rounded exact area (COMPUTE.md F1)
	for _, R in { 2.5, 6, 20 } do
		local cx, cy = 80.3, 79.6
		local e = maxErr(function(scene)
			Raster.circle(scene, 0xFFFFFFFF, cx, cy, R)
		end, function(x, y)
			return Coverage.circleArea(cx, cy, R, x, y)
		end, math.floor(cx - R - 2), math.floor(cy - R - 2), math.ceil(cx + R + 2), math.ceil(cy + R + 2), EXACT)
		assert(e <= F1, "exact circle R=" .. R .. " err " .. e)
	end
	do
		local cx, cy, r, t = 80.3, 79.6, 30, 3
		local e = maxErr(function(scene)
			Raster.ring(scene, 0xFFFFFFFF, cx, cy, r, t)
		end, function(x, y)
			return Coverage.circleArea(cx, cy, r + t, x, y) - Coverage.circleArea(cx, cy, r - t, x, y)
		end, 45, 45, 115, 115, EXACT)
		assert(e <= F1, "exact ring err " .. e)
	end
	for _, rad in { 0, 0.5, 2, 8 } do
		local cx, cy, hx, hy = 80.3, 79.6, 40.2, 25.7
		local pts: { number } = {}
		if rad == 0 then
			pts = { cx - hx, cy - hy, cx + hx, cy - hy, cx + hx, cy + hy, cx - hx, cy + hy }
		else
			arcPts(pts, cx + hx - rad, cy - hy + rad, rad, -0.25, 0, 400)
			arcPts(pts, cx + hx - rad, cy + hy - rad, rad, 0, 0.25, 400)
			arcPts(pts, cx - hx + rad, cy + hy - rad, rad, 0.25, 0.5, 400)
			arcPts(pts, cx - hx + rad, cy - hy + rad, rad, 0.5, 0.75, 400)
		end
		local e = maxErr(function(scene)
			Raster.box(scene, 0xFFFFFFFF, cx, cy, hx, hy, rad)
		end, function(x, y)
			return Coverage.polygonArea(pts, x, y)
		end, 37, 51, 123, 108, EXACT)
		assert(e <= F1, "exact box rad=" .. rad .. " err " .. e)
	end
	for _, rr in { 6, 20, 60 } do
		local pts = star(80.3, 79.7, rr, 0.03)
		local lo, hi = math.floor(80 - rr - 2), math.ceil(80 + rr + 2)
		local e = maxErr(function(scene)
			Raster.polygon(scene, 0xFFFFFFFF, pts)
		end, function(x, y)
			return Coverage.polygonArea(pts, x, y)
		end, lo, lo, hi, hi, EXACT)
		assert(e <= F1, "exact star r=" .. rr .. " err " .. e)
		-- the linear ramp is far from exact at the same corners (COMPUTE.md 9)
		local el = maxErr(function(scene)
			Raster.polygon(scene, 0xFFFFFFFF, pts)
		end, function(x, y)
			return Coverage.polygonArea(pts, x, y)
		end, lo, lo, hi, hi, Raster.MODE_LINEAR)
		assert(el > 20, "linear star error unexpectedly small " .. el)
	end
	do
		local ax, ay, bx, by, r = 40.3, 50.1, 120.7, 100.4, 5
		local ang = math.atan2(by - ay, bx - ax) / (2 * math.pi)
		local pts: { number } = {}
		arcPts(pts, bx, by, r, ang - 0.25, ang + 0.25, 600)
		arcPts(pts, ax, ay, r, ang + 0.25, ang + 0.75, 600)
		local e = maxErr(function(scene)
			Raster.segment(scene, 0xFFFFFFFF, ax, ay, bx, by, r)
		end, function(x, y)
			return Coverage.polygonArea(pts, x, y)
		end, 32, 42, 128, 108, EXACT)
		assert(e <= 1.0, "exact capsule err " .. e) -- caps use the curvature term: 0.74 measured
	end
end

----------------------------------------------------------------------------------
-- 3. Scanline: exact polygon area, conflation, composite
----------------------------------------------------------------------------------

do
	local W = 160
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
	local pts = star(80.3, 79.7, 60, 0.03)
	Scanline.addPolygon(acc, pts)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	assert(err(pts) <= 0.51, "scanline star")
	local sq = { 20.3, 20.7, 140.1, 20.7, 140.1, 139.6, 20.3, 139.6 }
	local A = { 20.3, 20.7, 140.1, 20.7, 140.1, 139.6 }
	local B = { 20.3, 20.7, 140.1, 139.6, 20.3, 139.6 }
	buffer.fill(dst, 0, 0)
	Scanline.addPolygon(acc, sq)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	assert(err(sq) <= 0.51, "scanline square (fractional spans)")
	buffer.fill(dst, 0, 0)
	Scanline.addPolygon(acc, A)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	Scanline.addPolygon(acc, B)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	local seam = err(sq)
	assert(math.abs(seam - 64) < 1, "conflation seam should be 64/255, got " .. seam)
	buffer.fill(dst, 0, 0)
	Scanline.addPolygon(acc, A)
	Scanline.addPolygon(acc, B)
	Scanline.composite(acc, dst, 0xFFFFFFFF)
	assert(err(sq) <= 0.51, "one accumulator removes the seam")
	-- resolve (layer output) agrees with composite onto clear
	local tri = { -30, -20, 300, 40, 100, 290 }
	Scanline.addPolygon(acc, tri)
	Scanline.resolve(acc, dst, 0xFFFFFF, 255)
	assert(err(tri) <= 0.51, "resolve clipped triangle")
	checkHash("scanline", hashWords(dst, W * W), 2698071151)
end

----------------------------------------------------------------------------------
-- 4. Distance transforms
----------------------------------------------------------------------------------

do
	local function mk(w: number, h: number, kind: string): buffer
		local m = buffer.create(w * h)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local on
				if kind == "rand" then
					on = MyMath.rand2(x, y, 3) < 0.003
				elseif kind == "disc" then
					on = (x - w * 0.4) ^ 2 + (y - h * 0.55) ^ 2 < (w * 0.3) ^ 2
				else
					on = MyMath.valueNoise2(x / 9, y / 9, 3) > 0.62
				end
				if on then
					buffer.writeu8(m, y * w + x, 1)
				end
			end
		end
		return m
	end
	local w, h = 96, 80
	for _, kind in { "rand", "disc", "blobs" } do
		local m = mk(w, h, kind)
		local ref = Distance.brute(m, w, h)
		local got = Distance.edt(m, w, h)
		for i = 0, w * h - 1 do
			assert(buffer.readu32(ref, i * 4) == buffer.readu32(got, i * 4), "edt not exact (" .. kind .. ")")
		end
		-- the approximate transforms stay within 2 px of exact
		for _, approx in { Distance.jfa(m, w, h), Distance.ssedt8(m, w, h) } do
			for i = 0, w * h - 1 do
				local a, b = buffer.readu32(ref, i * 4), buffer.readu32(approx, i * 4)
				assert(b >= a and math.sqrt(b) - math.sqrt(a) < 2, "approximate transform out of bounds")
			end
		end
		if kind == "blobs" then
			checkHash("edt", hashWords(got, w * h), 1507373726)
			local sd = Distance.signed(m, w, h)
			-- inside pixels negative, outside positive, |d| >= 1/2 at pixel centres
			for i = 0, w * h - 1 do
				local d = buffer.readf32(sd, i * 4)
				if buffer.readu8(m, i) ~= 0 then
					assert(d <= -0.5, "signed inside")
				else
					assert(d >= 0.5, "signed outside")
				end
			end
		end
	end
end

----------------------------------------------------------------------------------
-- 5. Filters
----------------------------------------------------------------------------------

do
	local function img(w: number, h: number, seed: number): buffer
		local b = buffer.create(w * h * 4)
		for i = 0, w * h - 1 do
			buffer.writeu32(b, i * 4, MyMath.hash32(i + seed * 7919))
		end
		return b
	end
	local w, h = 67, 45
	local src = img(w, h, 1)
	for _, r in { 1, 3, 20 } do
		assert(Pixels.diff(Filter.boxBlur(src, w, h, r), Filter.boxBlurBrute(src, w, h, r), w * h) == 0, "boxBlur r=" .. r)
	end
	local s2 = img(64, 48, 2)
	assert(Pixels.diff(Filter.areaResample(s2, 64, 48, 32, 24), Pixels.downsample2x(s2, 64, 48), 32 * 24) == 0, "area 2x == SWAR mip")
	-- fractional ratio: exact rational mean, rounded half up, by brute force
	for _, d in { { 47, 35 }, { 61, 13 }, { 9, 7 } } do
		local dw, dh = d[1], d[2]
		local out = Filter.areaResample(s2, 64, 48, dw, dh)
		for j = 0, dh - 1 do
			for i = 0, dw - 1 do
				for c = 0, 3 do
					-- weights in units of 1/dw and 1/dh: integers
					local S = 0
					for yy = 0, 47 do
						local oy = math.min((j + 1) * 48, (yy + 1) * dh) - math.max(j * 48, yy * dh)
						if oy > 0 then
							for xx = 0, 63 do
								local ox = math.min((i + 1) * 64, (xx + 1) * dw) - math.max(i * 64, xx * dw)
								if ox > 0 then
									S += ox * oy * buffer.readu8(s2, (yy * 64 + xx) * 4 + c)
								end
							end
						end
					end
					local T = 64 * 48
					assert(buffer.readu8(out, (j * dw + i) * 4 + c) == (2 * S + T) // (2 * T), "areaResample exact rational rounding")
				end
			end
		end
	end
	local sat = Filter.satBuild(s2, 64, 48)
	assert(Pixels.diff(Filter.satResample(sat, 32, 24), Pixels.downsample2x(s2, 64, 48), 32 * 24) == 0, "SAT 2x == SWAR mip")
	-- flat height field gives the straight-up normal (128, 128, 255)
	local flat = buffer.create(16 * 16)
	buffer.fill(flat, 0, 77)
	local nm = Filter.normalMap(flat, 16, 16, 3)
	assert(buffer.readu32(nm, 0) == 128 + 128 * 256 + 255 * 65536 + 0xFF000000, "flat normal")
	local hb = buffer.create(64 * 64)
	for i = 0, 64 * 64 - 1 do
		buffer.writeu8(hb, i, (MyMath.valueNoise2((i % 64) / 9, (i // 64) / 9, 9) * 255) // 1)
	end
	checkHash("filters", (hashWords(Filter.boxBlur(src, w, h, 3), w * h) + hashWords(Filter.normalMap(hb, 64, 64, 4), 64 * 64)) % 4294967291, 1077450458)
end

----------------------------------------------------------------------------------
-- 6. Tiles
----------------------------------------------------------------------------------

do
	for i = 0, 2000 do
		local x, y = MyMath.hash32(i) % 65536, MyMath.hash32(i + 99999) % 65536
		local c = Tiles.morton(x, y)
		assert(Tiles.mortonLUT(x, y) == c, "morton LUT")
		local a, b = Tiles.unmorton(c)
		assert(a == x and b == y, "morton round trip")
	end
	local order = Tiles.mortonOrder(5, 3)
	assert(#order == 15, "morton order covers the grid")
	local ring = Tiles.ringOrder(8, 8, 3, 4)
	assert(ring[1] == 4 * 8 + 3, "ring order starts at the focus")
	local W = 256
	local img = buffer.create(W * W * 4)
	local sc = Raster.demoScene(24, W, 7, nil, Raster.MODE_EXACT)
	Raster.render(sc, Raster.bin(sc, W, W), img, W, W, 8)
	local store = Tiles.newStore(16)
	local grid = Tiles.fromImage(store, img, W, W)
	assert(store.unique < grid.tilesX * grid.tilesY, "flat tiles deduplicate")
	local out = buffer.create(W * W * 4)
	Tiles.compose(grid, out)
	assert(Pixels.diff(out, img, W * W) == 0, "compose == source")
	local u0 = store.unique
	local t = Tiles.edit(grid, 0, 0)
	local old = buffer.readu32(t, 0)
	buffer.writeu32(t, 0, 0xFF0000FF)
	Tiles.commit(grid)
	t = Tiles.edit(grid, 0, 0)
	buffer.writeu32(t, 0, old)
	assert(Tiles.commit(grid) == 1 and store.unique == u0, "revert re-merges the tile")
	Tiles.compose(grid, out)
	assert(Pixels.diff(out, img, W * W) == 0, "compose after copy-on-write round trip")
end

----------------------------------------------------------------------------------
-- 7. Expressions: every backend gives the same bits; interval soundness
----------------------------------------------------------------------------------

do
	local size = 1024
	local root = Expr.demo(16, size, 11)
	local prog = Expr.compile(root)
	local fc = Expr.closure(root)
	local regs = table.create(prog.nregs, 0)
	local rows = Expr.newRows(prog, size)
	local gen = table.create(size, 0)
	-- loadstring exists in the CLI and on Roblox servers with LoadStringEnabled;
	-- read it through _G (getfenv would de-optimise this environment)
	local loadFn: ((string) -> any)? = (_G :: any).loadstring
	local loaded: ((number, number) -> number)? = nil
	if loadFn then
		local chunk: (() -> (number, number) -> number)? = loadFn(Expr.source(prog))
		if chunk then
			loaded = chunk()
		end
	end
	for _, y in { 0, 333, 511, 1023 } do
		local r = Expr.runRow(prog, rows, y, 0, size)
		ExprDemoRow(gen, y, 0, size)
		for i = 1, size do
			local px, py = i - 0.5, y + 0.5
			local a = fc(px, py)
			assert(a == Expr.run(prog, regs, px, py) and a == r[i] and a == gen[i], "expression backends differ")
			if loaded then
				assert(a == (loaded :: (number, number) -> number)(px, py), "loadstring backend differs")
			end
		end
	end
	for t = 1, 200 do
		local x0, y0 = MyMath.rand2(t, 1, 5) * 1000, MyMath.rand2(t, 2, 5) * 1000
		local s = 1 + MyMath.rand2(t, 3, 5) * 60
		local lo, hi = Expr.interval(root, x0, x0 + s, y0, y0 + s)
		for k = 0, 24 do
			local v = fc(x0 + (k % 5) / 4 * s, y0 + (k // 5) / 4 * s)
			assert(v >= lo - 1e-9 and v <= hi + 1e-9, "interval range not sound")
		end
	end
	-- quadtree renders: Lipschitz and interval classification both equal brute force
	local S = 128
	local small = Expr.demo(10, S, 4)
	local f = Expr.closure(small)
	local a, b, c = buffer.create(S * S * 4), buffer.create(S * S * 4), buffer.create(S * S * 4)
	Expr.renderQuad(small, f, "lipschitz", 1, a, S, 0x3366CC, 8)
	Expr.renderQuad(small, f, "interval", 1, b, S, 0x3366CC, 8)
	for y = 0, S - 1 do
		for x = 0, S - 1 do
			local cov = 0.5 - f(x + 0.5, y + 0.5)
			cov = if cov < 0 then 0 elseif cov > 1 then 1 else cov
			buffer.writeu32(c, (y * S + x) * 4, 0x3366CC + ((cov * 255 + 0.5) // 1) * 16777216)
		end
	end
	assert(Pixels.diff(a, c, S * S) == 0 and Pixels.diff(b, c, S * S) == 0, "quadtree expression render != brute force")
	checkHash("expr", hashWords(a, S * S), 4241246757)
end

----------------------------------------------------------------------------------
-- 8. Row kernels and sphere tracing
----------------------------------------------------------------------------------

do
	local W = 256
	local a, b, c = buffer.create(W * W * 4), buffer.create(W * W * 4), buffer.create(W * W * 4)
	for _, cfg in { { 128.375, 125.8125, 75 }, { 25.0625, 225.5, 3.25 }, { -5.5, 128, 50 }, { 128, 128, 0.75 } } do
		for y = 0, W - 1 do
			Rows.circleDirect(a, W, y, cfg[1], cfg[2], cfg[3], 0x3366CC)
			Rows.circleFD(b, W, y, cfg[1], cfg[2], cfg[3], 0x3366CC)
			Rows.circleSpans(c, W, y, cfg[1], cfg[2], cfg[3], 0x3366CC)
		end
		assert(Pixels.diff(a, b, W * W) == 0, "forward differencing changed bits")
		assert(Pixels.diff(a, c, W * W) == 0, "analytic spans changed bits")
	end
	checkHash("rows", hashWords(c, W * W), 1946074142)

	local size = 64
	local scn = Trace.demo(size)
	local n = buffer.create(size * size * 4)
	local hgt = buffer.create(size * size)
	local st = Trace.render(scn, size, n, hgt, 64, 0.01)
	assert(st.hits > 1000 and st.hits < st.rays, "trace hits")
	checkHash("trace", (hashWords(n, size * size) + hashBytes(hgt)) % 4294967291, 3933359165)
end

if PRINT_HASHES then
	for k, v in hashes do
		print(k, v)
	end
end
print("compute tests ok")
