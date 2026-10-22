--!nonstrict
-- Stress and differential tests for src/Pixels.luau: every operation against a naive
-- reference on thousands of random shapes of input, including the awkward ones (width 1,
-- odd sizes, empty spans, spans just below and above the copy-doubling threshold), with guard
-- bytes around every write to catch anything that strays.

local H = require("./Harness")
local Pixels = require("../../src/Pixels")
H.setLevel((...))

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local function randomBuffer(rng, pixels: number): buffer
	local b = buffer.create(pixels * 4)
	for i = 0, pixels - 1 do
		buffer.writeu32(b, i * 4, rng.u32())
	end
	return b
end

local function snapshot(b: buffer): buffer
	local c = buffer.create(buffer.len(b))
	buffer.copy(c, 0, b, 0, buffer.len(b))
	return c
end

local function sameBuffers(a: buffer, b: buffer): number
	-- index of the first differing pixel, or -1
	if buffer.len(a) ~= buffer.len(b) then
		return 0
	end
	for o = 0, buffer.len(a) - 4, 4 do
		if buffer.readu32(a, o) ~= buffer.readu32(b, o) then
			return o // 4
		end
	end
	return -1
end

H.suite("fillSpan: against naive writes, nothing outside the span touched", function()
	local rng = H.rng(11)
	local counts = { 0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 64, 255, 256, 257 }
	for case = 1, H.n(6000) do
		local P = rng.int(1, 700)
		local buf = randomBuffer(rng, P)
		local want = snapshot(buf)
		local start = rng.int(0, P - 1)
		local count = if rng.bool(0.5) then min(rng.pick(counts), P - start) else rng.int(0, P - start)
		local color = rng.u32()
		for i = 0, count - 1 do
			buffer.writeu32(want, (start + i) * 4, color)
		end
		Pixels.fillSpan(buf, start * 4, count, color)
		local bad = sameBuffers(buf, want)
		H.check(bad < 0, "fillSpan P=%d start=%d count=%d differs at pixel %d", P, start, count, bad)
		H.digest(buffer.readu32(buf, (P - 1) * 4))
		H.tick()
	end
end)

H.suite("fillRect and fill: against naive, including empty and clipped-to-edge rects", function()
	local rng = H.rng(12)
	for case = 1, H.n(3000) do
		local W, Hh = rng.int(1, 90), rng.int(1, 90)
		local buf = randomBuffer(rng, W * Hh)
		local want = snapshot(buf)
		local x, y = rng.int(0, W - 1), rng.int(0, Hh - 1)
		local w = if rng.bool(0.1) then rng.int(-2, 0) else rng.int(1, W - x)
		local h = if rng.bool(0.1) then rng.int(-2, 0) else rng.int(1, Hh - y)
		local color = rng.u32()
		if w > 0 and h > 0 then
			for yy = y, y + h - 1 do
				for xx = x, x + w - 1 do
					buffer.writeu32(want, (yy * W + xx) * 4, color)
				end
			end
		end
		Pixels.fillRect(buf, W, x, y, w, h, color)
		local bad = sameBuffers(buf, want)
		H.check(bad < 0, "fillRect %dx%d rect (%d,%d,%d,%d) differs at pixel %d", W, Hh, x, y, w, h, bad)
		H.digest(buffer.readu32(buf, 0))
		H.tick()
	end
	for _ = 1, H.n(300) do
		local P = rng.int(1, 3000)
		local buf = randomBuffer(rng, P)
		local color = rng.u32()
		Pixels.fill(buf, color)
		for i = 0, P - 1 do
			H.check(buffer.readu32(buf, i * 4) == color, "fill left pixel %d of %d unset", i, P)
		end
		H.tick()
	end
end)

H.suite("copyRect and extract: against naive crops", function()
	local rng = H.rng(13)
	for case = 1, H.n(2500) do
		local sw, sh = rng.int(1, 80), rng.int(1, 80)
		local dw, dh = rng.int(1, 80), rng.int(1, 80)
		local w, h = rng.int(1, min(sw, dw)), rng.int(1, min(sh, dh))
		local sx, sy = rng.int(0, sw - w), rng.int(0, sh - h)
		local dx, dy = rng.int(0, dw - w), rng.int(0, dh - h)
		local src = randomBuffer(rng, sw * sh)
		local dst = randomBuffer(rng, dw * dh)
		local want = snapshot(dst)
		for yy = 0, h - 1 do
			for xx = 0, w - 1 do
				buffer.writeu32(want, ((dy + yy) * dw + dx + xx) * 4, buffer.readu32(src, ((sy + yy) * sw + sx + xx) * 4))
			end
		end
		Pixels.copyRect(dst, dw, dx, dy, src, sw, sx, sy, w, h)
		local bad = sameBuffers(dst, want)
		H.check(bad < 0, "copyRect differs at pixel %d (src %dx%d at %d,%d  dst %dx%d at %d,%d  size %dx%d)", bad, sw, sh, sx, sy, dw, dh, dx, dy, w, h)
		local ex = Pixels.extract(src, sw, sx, sy, w, h)
		H.check(buffer.len(ex) == w * h * 4, "extract returned %d bytes for %dx%d", buffer.len(ex), w, h)
		for yy = 0, h - 1 do
			for xx = 0, w - 1 do
				H.check(buffer.readu32(ex, (yy * w + xx) * 4) == buffer.readu32(src, ((sy + yy) * sw + sx + xx) * 4), "extract pixel (%d,%d) wrong", xx, yy)
			end
		end
		H.digest(buffer.readu32(ex, 0))
		H.tick()
	end
end)

H.suite("downsample2x: exact round-half-up box average, odd sizes, tiny sizes", function()
	local rng = H.rng(14)
	for case = 1, H.n(1500) do
		local w, h = rng.int(1, 70), rng.int(1, 70)
		local src = randomBuffer(rng, w * h)
		local out, hw, hh = Pixels.downsample2x(src, w, h)
		H.check(hw == w // 2 and hh == h // 2, "downsample dims %dx%d -> %dx%d", w, h, hw, hh)
		for y = 0, hh - 1 do
			for x = 0, hw - 1 do
				local want = 0
				for c = 0, 3 do
					local sum = 0
					for dy = 0, 1 do
						for dx = 0, 1 do
							sum += buffer.readu8(src, ((y * 2 + dy) * w + x * 2 + dx) * 4 + c)
						end
					end
					want += ((sum + 2) // 4) * 256 ^ c
				end
				local got = buffer.readu32(out, (y * hw + x) * 4)
				H.check(got == want, "downsample %dx%d pixel (%d,%d): got %08x want %08x", w, h, x, y, got, want)
			end
		end
		H.digest(if hw * hh > 0 then buffer.readu32(out, 0) else 0)
		H.tick()
	end
end)

H.suite("downsample2xAlphaWeighted: against an independent alpha-weighted average", function()
	local rng = H.rng(15)
	for case = 1, H.n(900) do
		local w, h = rng.int(2, 40), rng.int(2, 40)
		local src = buffer.create(w * h * 4)
		local transparentBias = rng.float()
		for i = 0, w * h - 1 do
			local a = if rng.bool(transparentBias) then 0 else rng.int(1, 255)
			buffer.writeu32(src, i * 4, rng.u32() % 16777216 + a * 16777216)
		end
		local out, hw, hh = Pixels.downsample2xAlphaWeighted(src, w, h)
		for y = 0, hh - 1 do
			for x = 0, hw - 1 do
				local px = {}
				for _, off in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
					px[#px + 1] = buffer.readu32(src, ((y * 2 + off[2]) * w + x * 2 + off[1]) * 4)
				end
				local sr, sg, sb, sa = 0, 0, 0, 0
				for _, p in px do
					local a = p // 16777216
					sr += (p % 256) * a
					sg += ((p // 256) % 256) * a
					sb += ((p // 65536) % 256) * a
					sa += a
				end
				local want
				if sa > 0 then
					want = floor(sr / sa + 0.5) + floor(sg / sa + 0.5) * 256 + floor(sb / sa + 0.5) * 65536 + ((sa + 2) // 4) * 16777216
				else
					want = px[1] % 16777216
				end
				local got = buffer.readu32(out, (y * hw + x) * 4)
				H.check(got == want, "alpha-weighted downsample pixel (%d,%d) of %dx%d: got %08x want %08x", x, y, w, h, got, want)
			end
		end
		H.tick()
	end
end)

H.suite("blendOver: identities, convexity and agreement with the straight-alpha formula", function()
	local rng = H.rng(16)
	for case = 1, H.n(5000) do
		local n = rng.int(1, 40)
		local src = randomBuffer(rng, n)
		local dst = randomBuffer(rng, n)
		for i = 0, n - 1 do
			-- exercise the special alphas often
			local pick = rng.int(1, 6)
			local sp = buffer.readu32(src, i * 4)
			local a = if pick == 1 then 0 elseif pick == 2 then 255 elseif pick == 3 then 1 elseif pick == 4 then 254 else sp // 16777216
			buffer.writeu32(src, i * 4, sp % 16777216 + a * 16777216)
		end
		local want = snapshot(dst)
		Pixels.blendOver(dst, 0, src, 0, n)
		for i = 0, n - 1 do
			local s, d, o = buffer.readu32(src, i * 4), buffer.readu32(want, i * 4), buffer.readu32(dst, i * 4)
			local sa, da = s // 16777216, d // 16777216
			if sa == 0 then
				H.check(o == d, "alpha 0 source must leave the destination unchanged")
			elseif sa == 255 then
				H.check(o == s, "alpha 255 source must replace the destination")
			else
				local fs = sa / 255
				local fd = da / 255 * (1 - fs)
				local oa = fs + fd
				local oaByte = o // 16777216
				H.check(abs(oaByte - oa * 255) <= 1, "alpha: got %d want %.3f (sa=%d da=%d)", oaByte, oa * 255, sa, da)
				for c = 0, 2 do
					local sc, dc = floor(s / 256 ^ c) % 256, floor(d / 256 ^ c) % 256
					local wantC = (sc * fs + dc * fd) / oa
					local gotC = floor(o / 256 ^ c) % 256
					H.check(abs(gotC - wantC) <= 1, "channel %d: got %d want %.3f (src %08x dst %08x)", c, gotC, wantC, s, d)
					H.check(gotC >= min(sc, dc) - 1 and gotC <= max(sc, dc) + 1, "blend left the [src, dst] range on channel %d", c)
				end
			end
		end
		H.digest(buffer.readu32(dst, 0))
		H.tick(n)
	end
end)

-- multi-source breadth-first search distances on the 4-connected grid, independent of Pixels.bleed
local function bfsDistances(visible: { boolean }, w: number, h: number): { number }
	local dist = table.create(w * h, math.huge)
	local queue, head = {}, 1
	for i = 0, w * h - 1 do
		if visible[i + 1] then
			dist[i + 1] = 0
			queue[#queue + 1] = i
		end
	end
	while head <= #queue do
		local i = queue[head]
		head += 1
		local x, y = i % w, i // w
		for _, nb in { { x - 1, y }, { x + 1, y }, { x, y - 1 }, { x, y + 1 } } do
			if nb[1] >= 0 and nb[1] < w and nb[2] >= 0 and nb[2] < h then
				local j = nb[2] * w + nb[1]
				if dist[j + 1] == math.huge then
					dist[j + 1] = dist[i + 1] + 1
					queue[#queue + 1] = j
				end
			end
		end
	end
	return dist
end

H.suite("bleed: spreads colour exactly to the BFS distance, never touches alpha or visible pixels", function()
	local rng = H.rng(17)
	for case = 1, H.n(1500) do
		local w, h = rng.int(1, 36), rng.int(1, 36)
		local density = rng.range(0.01, 0.6)
		local passes = rng.int(0, 7)
		local buf = buffer.create(w * h * 4)
		local visible = {}
		for i = 0, w * h - 1 do
			if rng.bool(density) then
				visible[i + 1] = true
				local c = rng.int(50, 255) + rng.int(50, 255) * 256 + rng.int(50, 255) * 65536 + rng.int(1, 255) * 16777216
				buffer.writeu32(buf, i * 4, c)
			else
				visible[i + 1] = false
			end
		end
		local before = snapshot(buf)
		local dist = bfsDistances(visible, w, h)
		Pixels.bleed(buf, w, h, passes)
		for i = 0, w * h - 1 do
			local was, now = buffer.readu32(before, i * 4), buffer.readu32(buf, i * 4)
			H.check(was // 16777216 == now // 16777216, "bleed changed alpha at pixel %d", i)
			if visible[i + 1] then
				H.check(was == now, "bleed changed a visible pixel %d", i)
			elseif dist[i + 1] <= passes then
				local r, g, b = now % 256, (now // 256) % 256, (now // 65536) % 256
				H.check(r >= 50 and g >= 50 and b >= 50, "pixel %d at distance %d within %d passes got no colour (%08x)", i, dist[i + 1], passes, now)
			else
				H.check(now == was, "pixel %d at distance %s beyond %d passes changed", i, tostring(dist[i + 1]), passes)
			end
		end
		H.digest(buffer.readu32(buf, (w * h - 1) * 4))
		H.tick()
	end
end)

H.suite("expandIndexed and diff: against naive", function()
	local rng = H.rng(18)
	for case = 1, H.n(2500) do
		local n = rng.int(1, 300)
		local indices = buffer.create(n)
		for i = 0, n - 1 do
			buffer.writeu8(indices, i, rng.int(0, 255))
		end
		local palette = randomBuffer(rng, 256)
		local dst = buffer.create(n * 4)
		Pixels.expandIndexed(indices, palette, dst, n)
		for i = 0, n - 1 do
			H.check(buffer.readu32(dst, i * 4) == buffer.readu32(palette, buffer.readu8(indices, i) * 4), "expandIndexed pixel %d wrong", i)
		end
		local a, b = randomBuffer(rng, n), snapshot(dst)
		local want, wantIgnoring = 0, 0
		for i = 0, n - 1 do
			if rng.bool(0.5) then
				buffer.writeu32(b, i * 4, buffer.readu32(a, i * 4))
			end
			if rng.bool(0.1) then
				local v = rng.u32() % 16777216
				buffer.writeu32(a, i * 4, v)
				buffer.writeu32(b, i * 4, rng.u32() % 16777216)
			end
			local p, q = buffer.readu32(a, i * 4), buffer.readu32(b, i * 4)
			if p ~= q then
				want += 1
				if not (p // 16777216 == 0 and q // 16777216 == 0) then
					wantIgnoring += 1
				end
			end
		end
		H.check(Pixels.diff(a, b, n) == want, "diff counted %d want %d", Pixels.diff(a, b, n), want)
		H.check(Pixels.diff(a, b, n, true) == wantIgnoring, "diff ignoring hidden rgb counted %d want %d", Pixels.diff(a, b, n, true), wantIgnoring)
		H.digest(want)
		H.tick()
	end
end)

H.runAll("pixels.stress")
