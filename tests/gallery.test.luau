--!nonstrict
-- Tests for gallery/shared/Panels.luau: the pixel generators behind the EditableImage gallery.
-- Runs in the interpreter and with native code generation (tests/run.sh); the recorded hashes
-- must come out identical in both. The Roblox-facing script is checked separately by
-- tools/gallery_mock_run.py.

local MyMath = require("../src/MyMath")
local Panels = require("../gallery/shared/Panels")(MyMath)

local function bufferOf(w: number, h: number, fn: (buffer) -> ()): buffer
	local b = buffer.create(w * h * 4)
	fn(b)
	return b
end

-- 1. The half-plane coverage formula against dense point sampling of the pixel square ------
do
	local N = 160
	local worst = 0
	for ai = 0, 23 do
		local ang = ai / 24 + 0.013
		local nx, ny = MyMath.dcosTurns(ang), MyMath.dsinTurns(ang)
		for di = -10, 10 do
			local d = di * 0.07
			local inside = 0
			for j = 0, N - 1 do
				for i = 0, N - 1 do
					local qx, qy = (i + 0.5) / N - 0.5, (j + 0.5) / N - 0.5
					if d + nx * qx + ny * qy <= 0 then
						inside += 1
					end
				end
			end
			local err = math.abs(Panels.halfPlane(d, nx, ny) - inside / (N * N))
			worst = math.max(worst, err)
		end
	end
	assert(worst < 0.0125, "half-plane coverage within sampling error of the sampled area, worst " .. worst)
	-- exact plateaus
	assert(Panels.halfPlane(0.8, 0.6, 0.8) == 0 and Panels.halfPlane(-0.8, 0.6, 0.8) == 1, "coverage is exactly 0 and 1 beyond the reach")
	assert(math.abs(Panels.halfPlane(0, 1, 0) - 0.5) < 1e-12, "an edge through the pixel centre covers half of it")
end

-- 2. Tile culling changes nothing: culled and brute-force renders are identical -------------
do
	for _, size in { 40, 96, 130 } do
		local culled = bufferOf(size, size, function(b)
			Panels.renderScene(b, size, size)
		end)
		Panels.noCull = true
		local brute = bufferOf(size, size, function(b)
			Panels.renderScene(b, size, size)
		end)
		Panels.noCull = false
		assert(Panels.hashBuffer(culled) == Panels.hashBuffer(brute), "badge: culled equals brute force at " .. size)
	end
	local g1 = bufferOf(100, 100, function(b)
		Panels.renderGreenScreen(b, 100, 100)
	end)
	Panels.noCull = true
	local g2 = bufferOf(100, 100, function(b)
		Panels.renderGreenScreen(b, 100, 100)
	end)
	Panels.noCull = false
	assert(Panels.hashBuffer(g1) == Panels.hashBuffer(g2), "green screen: culled equals brute force")
	local edge, tiles = 0, 0
	Panels.renderScene(buffer.create(512 * 512 * 4), 512, 512)
	local b = buffer.create(256 * 256 * 4)
	edge, tiles = Panels.renderScene(b, 256, 256)
	assert(edge < tiles, "some tiles are copy-filled")
end

-- 3. Levels agree: a 4x4 box average of the 256 render matches the 64 render ----------------
do
	local big = bufferOf(256, 256, function(b)
		Panels.renderScene(b, 256, 256)
	end)
	local small = bufferOf(64, 64, function(b)
		Panels.renderScene(b, 64, 64)
	end)
	local maxd, sum, cnt = 0, 0, 0
	for y = 0, 63 do
		for x = 0, 63 do
			local r, g, bl = 0, 0, 0
			for dy = 0, 3 do
				for dx = 0, 3 do
					local p = buffer.readu32(big, ((y * 4 + dy) * 256 + x * 4 + dx) * 4)
					r += p % 256
					g += (p // 256) % 256
					bl += (p // 65536) % 256
				end
			end
			local q = buffer.readu32(small, (y * 64 + x) * 4)
			for _, pair in { { r, q % 256 }, { g, (q // 256) % 256 }, { bl, (q // 65536) % 256 } } do
				local d = math.abs(pair[1] / 16 - pair[2])
				maxd = math.max(maxd, d)
				sum += d
				cnt += 1
			end
		end
	end
	-- mean error 0.3/255; the worst pixels are star tips, where no distance-and-direction
	-- coverage can be exact (docs/COMPUTE.md, C6)
	assert(sum / cnt < 0.5, "mean level disagreement " .. sum / cnt)
	assert(maxd < 24, "worst level disagreement " .. maxd)
end

-- 4. LOD blending is continuous; the hard switch is not --------------------------------------
do
	local prevC, prevF = Panels.twoPhase(Panels.lodBlend(30))
	local hPrevC, hPrevF = Panels.hardSwitch(Panels.lodBlend(30))
	local maxStep, maxHardStep = 0, 0
	for i = 1, 27000 do
		local size = 30 + i * 0.01
		local f = Panels.lodBlend(size)
		local c, fn = Panels.twoPhase(f)
		maxStep = math.max(maxStep, math.abs(c - prevC), math.abs(fn - prevF))
		assert(c >= prevC - 1e-12, "coarse transparency never decreases as the image grows")
		assert(fn <= prevF + 1e-12, "fine transparency never increases as the image grows")
		assert(c >= 0 and c <= 1 and fn >= 0 and fn <= 1, "transparencies stay in range")
		assert(c == 0 or fn == 0, "never both layers partly transparent: the dip-free property")
		prevC, prevF = c, fn
		local hc, hf = Panels.hardSwitch(f)
		maxHardStep = math.max(maxHardStep, math.abs(hc - hPrevC), math.abs(hf - hPrevF))
		hPrevC, hPrevF = hc, hf
	end
	assert(maxStep < 0.001, "two-phase fade moves less than 0.001 per 0.01 px, got " .. maxStep)
	assert(maxHardStep == 1, "the hard switch jumps by a full step")
	local lo, hi = math.huge, 0
	for i = 0, 1000 do
		local s = Panels.zoomSize(i * 0.01)
		lo, hi = math.min(lo, s), math.max(hi, s)
	end
	assert(math.abs(lo - 36) < 0.01 and math.abs(hi - 288) < 0.01, "zoom runs between 36 and 288 px")
	assert(math.abs(Panels.zoomSize(0) - Panels.zoomSize(10)) < 1e-9, "zoom is periodic")
end

-- 5. Determinism: identical bytes in both runtimes -------------------------------------------
do
	local h1 = Panels.hashBuffer(bufferOf(128, 128, function(b)
		Panels.renderScene(b, 128, 128)
	end))
	assert(h1 == 3203417403, "badge 128 hash " .. h1)
	local st = Panels.plasmaInit(64, 64)
	local h2 = Panels.hashBuffer(bufferOf(64, 64, function(b)
		Panels.plasmaFrame(st, b, 3.0)
	end))
	assert(h2 == 1408874208, "plasma hash " .. h2)
	local h3 = Panels.hashBuffer(bufferOf(64, 64, function(b)
		Panels.renderMarble(b, 64, 64, 1234, nil)
	end))
	assert(h3 == 2684048350, "marble hash " .. h3)
	local g = buffer.create(128 * 128 * 4)
	local m = buffer.create(128 * 128 * 4)
	local c = buffer.create(128 * 128 * 4)
	Panels.renderGreenScreen(g, 128, 128, nil)
	Panels.keyMatte(g, 128, 128, m, c, nil)
	assert(Panels.hashBuffer(g) == 35806085, "green screen hash " .. Panels.hashBuffer(g))
	assert(Panels.hashBuffer(m) == 175640531, "matte hash " .. Panels.hashBuffer(m))
	assert(Panels.hashBuffer(c) == 3014710526, "cut-out hash " .. Panels.hashBuffer(c))
	-- plasma at another time differs; the same time reproduces
	local h2b = Panels.hashBuffer(bufferOf(64, 64, function(b)
		Panels.plasmaFrame(st, b, 3.5)
	end))
	assert(h2b ~= h2, "plasma animates")
end

-- 6. Matte: background out, subject in, glass partly transparent ------------------------------
do
	local g = buffer.create(256 * 256 * 4)
	local m = buffer.create(256 * 256 * 4)
	local c = buffer.create(256 * 256 * 4)
	Panels.renderGreenScreen(g, 256, 256, nil)
	Panels.keyMatte(g, 256, 256, m, c, nil)
	local function alphaAt(x: number, y: number): number
		return buffer.readu32(m, (y * 256 + x) * 4) % 256
	end
	assert(alphaAt(4, 4) == 0 and alphaAt(250, 250) == 0 and alphaAt(4, 130) == 0, "green background is fully keyed out")
	assert(alphaAt(128, 222) == 255 and alphaAt(128, 110) == 255, "torso and face are fully opaque")
	local glass = alphaAt(204, 96)
	assert(glass > 70 and glass < 230, "the glass bubble is partly transparent, got " .. glass)
	-- no green fringe left on the cut-out around the head: no pixel is much greener than red and blue
	local fringe = 0
	for y = 0, 255 do
		for x = 0, 255 do
			local p = buffer.readu32(c, (y * 256 + x) * 4)
			local r, gg, b = p % 256, (p // 256) % 256, (p // 65536) % 256
			if y > 120 and gg - math.max(r, b) > 60 and alphaAt(x, y) > 250 then
				fringe += 1
			end
		end
	end
	assert(fringe == 0, "opaque pixels of the cut-out carry no key colour, got " .. fringe)
	for i = 0, 256 * 256 - 1 do
		assert(buffer.readu32(c, i * 4) // 16777216 == 255 and buffer.readu32(m, i * 4) // 16777216 == 255, "cut-out and matte are opaque images")
	end
end

-- 7. Mandelbrot tile sanity, progress callbacks cover every row exactly once --------------------
do
	local tile = buffer.create(48 * 48 * 4)
	local black, coloured = 0, 0
	for ty = 0, 2 do
		for tx = 0, 2 do
			Panels.renderMandelbrotTile(tile, 48, tx, ty, 3, nil)
			for i = 0, 48 * 48 - 1 do
				if buffer.readu32(tile, i * 4) == 0xFF000000 then
					black += 1
				else
					coloured += 1
				end
			end
		end
	end
	assert(coloured > 0 and black >= 0, "the tiles contain colour")

	local function coverage(name: string, h: number, run: (((number, number) -> ())) -> ())
		local seen = table.create(h, 0)
		local last = 0
		run(function(y0: number, y1: number)
			assert(y0 == last and y1 > y0, name .. ": batches are contiguous and ascending")
			last = y1
			for y = y0, y1 - 1 do
				seen[y + 1] += 1
			end
		end)
		for y = 1, h do
			assert(seen[y] == 1, string.format("%s: row %d reported %d times", name, y - 1, seen[y]))
		end
	end
	coverage("scene", 70, function(p)
		Panels.renderScene(buffer.create(70 * 70 * 4), 70, 70, p)
	end)
	coverage("marble", 37, function(p)
		Panels.renderMarble(buffer.create(40 * 37 * 4), 40, 37, 5, p)
	end)
	coverage("green screen", 50, function(p)
		Panels.renderGreenScreen(buffer.create(50 * 50 * 4), 50, 50, p)
	end)
	coverage("matte", 50, function(p)
		local g = buffer.create(50 * 50 * 4)
		Panels.renderGreenScreen(g, 50, 50, nil)
		Panels.keyMatte(g, 50, 50, buffer.create(50 * 50 * 4), buffer.create(50 * 50 * 4), p)
	end)
	coverage("mandelbrot", 21, function(p)
		Panels.renderMandelbrotTile(buffer.create(21 * 21 * 4), 21, 1, 1, 3, p)
	end)
end

print("gallery tests passed")
