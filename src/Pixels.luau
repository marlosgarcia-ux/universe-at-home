--!native
--!optimize 2
-- universe-at-home :: Pixels
--
-- Buffer-level pixel ops on row-major RGBA8 (the EditableImage layout: bytes R, G,
-- B, A, so a pixel read with readu32 is r + g*256 + b*65536 + a*16777216).
-- Every op here follows the measured economics in docs/RUNTIME_AUDIT.md 6.7:
-- spans go through buffer.copy, per-pixel loops pack with arithmetic, and no
-- non-builtin call happens per pixel.

local MyMath = require("./MyMath")

local Pixels = {}

local pack = MyMath.pack

-- Fills count pixels starting at byte offset `at` with one colour.
-- One writeu32, then buffer.copy doubling: log2(count) C calls instead of count
-- interpreted writes (about 50x faster for a 1024 px row).
local function fillSpan(buf: buffer, at: number, count: number, color: number)
	if count <= 0 then
		return
	end
	buffer.writeu32(buf, at, color)
	if count < 8 then
		for i = 1, count - 1 do
			buffer.writeu32(buf, at + i * 4, color)
		end
		return
	end
	local bytes = count * 4
	local filled = 4
	while filled < bytes do
		local n = if filled < bytes - filled then filled else bytes - filled
		buffer.copy(buf, at + filled, buf, at, n)
		filled += n
	end
end
Pixels.fillSpan = fillSpan

-- Fills a w x h rectangle at (x, y) of an image `width` pixels wide.
function Pixels.fillRect(buf: buffer, width: number, x: number, y: number, w: number, h: number, color: number)
	if w <= 0 or h <= 0 then
		return
	end
	local row = width * 4
	local first = (y * width + x) * 4
	fillSpan(buf, first, w, color)
	local bytes = w * 4
	for r = 1, h - 1 do
		buffer.copy(buf, first + r * row, buf, first, bytes)
	end
end

-- Fills the whole buffer with one colour.
function Pixels.fill(buf: buffer, color: number)
	fillSpan(buf, 0, buffer.len(buf) // 4, color)
end

-- Copies a w x h block between two row-major images (row blits; memmove semantics).
function Pixels.copyRect(
	dst: buffer,
	dstWidth: number,
	dx: number,
	dy: number,
	src: buffer,
	srcWidth: number,
	sx: number,
	sy: number,
	w: number,
	h: number
)
	local bytes = w * 4
	for r = 0, h - 1 do
		buffer.copy(dst, ((dy + r) * dstWidth + dx) * 4, src, ((sy + r) * srcWidth + sx) * 4, bytes)
	end
end

-- Extracts a rectangle into a new tightly packed buffer (the shape WritePixelsBuffer wants).
function Pixels.extract(src: buffer, srcWidth: number, x: number, y: number, w: number, h: number, into: buffer?): buffer
	local out = into or buffer.create(w * h * 4)
	Pixels.copyRect(out, w, 0, 0, src, srcWidth, x, y, w, h)
	return out
end

-- 2 x 2 box filter: (w, h) -> (w // 2, h // 2). Channels are averaged in pairs
-- inside 16-bit lanes (mask 0x00FF00FF): four bytes sum to at most 1020, so lanes
-- never carry into each other. Rounds half up. Measured 20 percent faster than a
-- per-channel version in the interpreter.
function Pixels.downsample2x(src: buffer, w: number, h: number, dst: buffer?): (buffer, number, number)
	local hw, hh = w // 2, h // 2
	local out = dst or buffer.create(math.max(hw * hh * 4, 4))
	local srcRow = w * 4
	local o = 0
	for y = 0, hh - 1 do
		local r0 = y * 2 * srcRow
		local r1 = r0 + srcRow
		for x = 0, hw - 1 do
			local a0 = r0 + x * 8
			local b0 = r1 + x * 8
			local p = buffer.readu32(src, a0)
			local q = buffer.readu32(src, a0 + 4)
			local s = buffer.readu32(src, b0)
			local t = buffer.readu32(src, b0 + 4)
			local rb = bit32.band(p, 0x00FF00FF)
				+ bit32.band(q, 0x00FF00FF)
				+ bit32.band(s, 0x00FF00FF)
				+ bit32.band(t, 0x00FF00FF)
				+ 0x00020002
			local ga = bit32.band(bit32.rshift(p, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(q, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(s, 8), 0x00FF00FF)
				+ bit32.band(bit32.rshift(t, 8), 0x00FF00FF)
				+ 0x00020002
			buffer.writeu32(
				out,
				o,
				bit32.band(bit32.rshift(rb, 2), 0x00FF00FF) + bit32.band(bit32.rshift(ga, 2), 0x00FF00FF) * 256
			)
			o += 4
		end
	end
	return out, hw, hh
end

-- Premultiplied-correct 2 x 2 box filter: averages colour weighted by alpha, so a
-- transparent neighbour never darkens or tints an edge. Slower than the SWAR one
-- (about 2x); use it for content with soft alpha edges.
function Pixels.downsample2xAlphaWeighted(src: buffer, w: number, h: number, dst: buffer?): (buffer, number, number)
	local hw, hh = w // 2, h // 2
	local out = dst or buffer.create(math.max(hw * hh * 4, 4))
	local srcRow = w * 4
	local o = 0
	for y = 0, hh - 1 do
		local r0 = y * 2 * srcRow
		local r1 = r0 + srcRow
		for x = 0, hw - 1 do
			local a0 = r0 + x * 8
			local b0 = r1 + x * 8
			local sr, sg, sb, sa = 0, 0, 0, 0
			for k = 1, 4 do
				local at = if k == 1 then a0 elseif k == 2 then a0 + 4 elseif k == 3 then b0 else b0 + 4
				local px = buffer.readu32(src, at)
				local a = px // 16777216
				sr += (px % 256) * a
				sg += ((px // 256) % 256) * a
				sb += ((px // 65536) % 256) * a
				sa += a
			end
			if sa > 0 then
				buffer.writeu32(out, o, pack((sr / sa + 0.5) // 1, (sg / sa + 0.5) // 1, (sb / sa + 0.5) // 1, (sa + 2) // 4))
			else
				-- fully transparent: keep the plain average colour so later mips still bleed
				local p = buffer.readu32(src, a0)
				buffer.writeu32(out, o, p % 16777216)
			end
			o += 4
		end
	end
	return out, hw, hh
end

-- Source-over for straight alpha, in place: dst = src over dst, `count` pixels.
-- The float form measured fastest in the interpreter (fewer builtin calls than SWAR).
function Pixels.blendOver(dst: buffer, dstAt: number, src: buffer, srcAt: number, count: number)
	for i = 0, count - 1 do
		local s = buffer.readu32(src, srcAt + i * 4)
		local sa = s // 16777216
		if sa == 0 then
			continue
		end
		local o = dstAt + i * 4
		if sa == 255 then
			buffer.writeu32(dst, o, s)
			continue
		end
		local d = buffer.readu32(dst, o)
		local da = d // 16777216
		local fs = sa / 255
		local fd = (da / 255) * (1 - fs)
		local oa = fs + fd
		local ws, wd = fs / oa, fd / oa
		local r = (s % 256) * ws + (d % 256) * wd
		local g = ((s // 256) % 256) * ws + ((d // 256) % 256) * wd
		local b = ((s // 65536) % 256) * ws + ((d // 65536) % 256) * wd
		buffer.writeu32(dst, o, pack((r + 0.5) // 1, (g + 0.5) // 1, (b + 0.5) // 1, (oa * 255 + 0.5) // 1))
	end
end

-- Alpha bleeding (colour dilation): every fully transparent pixel next to a visible
-- one takes that neighbour's RGB while keeping alpha 0, repeated `passes` times.
-- Bilinear filtering of straight-alpha textures then never pulls in a foreign
-- colour at the edge: if RGB is constant across an alpha edge, filtering straight
-- alpha equals filtering premultiplied alpha (docs/DESIGN.md, axiom A8).
function Pixels.bleed(buf: buffer, w: number, h: number, passes: number?)
	local n = w * h
	local known = buffer.create(n) -- 1 = pixel has a trusted colour
	for i = 0, n - 1 do
		if buffer.readu8(buf, i * 4 + 3) > 0 then
			buffer.writeu8(known, i, 1)
		end
	end
	local frontier = {}
	for _ = 1, passes or 4 do
		table.clear(frontier)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local i = y * w + x
				if buffer.readu8(known, i) == 0 then
					local sr, sg, sb, c = 0, 0, 0, 0
					if x > 0 and buffer.readu8(known, i - 1) == 1 then
						local p = buffer.readu32(buf, (i - 1) * 4)
						sr += p % 256
						sg += (p // 256) % 256
						sb += (p // 65536) % 256
						c += 1
					end
					if x < w - 1 and buffer.readu8(known, i + 1) == 1 then
						local p = buffer.readu32(buf, (i + 1) * 4)
						sr += p % 256
						sg += (p // 256) % 256
						sb += (p // 65536) % 256
						c += 1
					end
					if y > 0 and buffer.readu8(known, i - w) == 1 then
						local p = buffer.readu32(buf, (i - w) * 4)
						sr += p % 256
						sg += (p // 256) % 256
						sb += (p // 65536) % 256
						c += 1
					end
					if y < h - 1 and buffer.readu8(known, i + w) == 1 then
						local p = buffer.readu32(buf, (i + w) * 4)
						sr += p % 256
						sg += (p // 256) % 256
						sb += (p // 65536) % 256
						c += 1
					end
					if c > 0 then
						table.insert(frontier, i)
						table.insert(frontier, pack((sr / c + 0.5) // 1, (sg / c + 0.5) // 1, (sb / c + 0.5) // 1, 0))
					end
				end
			end
		end
		if #frontier == 0 then
			break
		end
		for k = 1, #frontier, 2 do
			local i = frontier[k]
			buffer.writeu32(buf, i * 4, frontier[k + 1])
			buffer.writeu8(known, i, 1)
		end
	end
end

-- Expands an 8-bit indexed image through a 256-entry palette buffer of u32 colours.
function Pixels.expandIndexed(indices: buffer, palette: buffer, dst: buffer, count: number)
	local o = 0
	for i = 0, count - 1 do
		buffer.writeu32(dst, o, buffer.readu32(palette, buffer.readu8(indices, i) * 4))
		o += 4
	end
end

-- Counts pixels that differ between two equal-sized images; optional channel mask
-- (default all four bytes).
function Pixels.diff(a: buffer, b: buffer, count: number, ignoreRgbUnderZeroAlpha: boolean?): number
	local n = 0
	for i = 0, count - 1 do
		local p = buffer.readu32(a, i * 4)
		local q = buffer.readu32(b, i * 4)
		if p ~= q then
			if ignoreRgbUnderZeroAlpha and p // 16777216 == 0 and q // 16777216 == 0 then
				continue
			end
			n += 1
		end
	end
	return n
end

return Pixels
