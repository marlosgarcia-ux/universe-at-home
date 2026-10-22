--!native
--!optimize 2
-- universe-at-home :: compute/Scanline
--
-- Exact-area polygon rasterizer by signed-area accumulation (the method of
-- R. Levien's font-rs). Every edge deposits, into the cells it crosses, the signed
-- area between itself and the right edge of the row; a running sum along the row
-- then gives the exact box-filtered coverage of every pixel. Cost is proportional
-- to the perimeter (cells crossed), not the area: between touched cells the running
-- sum is constant, so those spans are filled with buffer.copy (RUNTIME_AUDIT 6.7.3).
--
-- Fill rule: non-zero, coverage = min(1, |winding area|). Curves are flattened to
-- line segments with a sagitta tolerance (flattenEllipse), whose area error per
-- pixel is at most the tolerance.
--
-- Deterministic: + - * / floor ceil min max abs only.

local Pixels = require("../Pixels")
local MyMath = require("../MyMath")

local Scanline = {}

export type Accumulator = {
	width: number,
	height: number,
	stride: number, -- cells per row (width + 2)
	cells: buffer, -- f64 per cell
	ranges: { { number } }, -- per row: flat list of touched cell ranges (lo, hi, lo, hi, ...)
}

function Scanline.new(width: number, height: number): Accumulator
	local ranges = table.create(height)
	for y = 1, height do
		ranges[y] = {}
	end
	return {
		width = width,
		height = height,
		stride = width + 2,
		cells = buffer.create((width + 2) * height * 8),
		ranges = ranges,
	}
end

local floor, ceil = math.floor, math.ceil

-- Adds one edge with x already inside [0, width].
local function addLineInside(acc: Accumulator, x0: number, y0: number, x1: number, y1: number)
	if y0 == y1 then
		return
	end
	local dir = 1
	if y0 > y1 then
		dir = -1
		x0, y0, x1, y1 = x1, y1, x0, y0
	end
	local H = acc.height
	local stride = acc.stride
	local cells = acc.cells
	local ranges = acc.ranges
	local dxdy = (x1 - x0) / (y1 - y0)
	local x = x0
	if y0 < 0 then
		x -= y0 * dxdy
	end
	local yStart = if y0 > 0 then floor(y0) else 0
	local yEnd = if y1 < H then ceil(y1) else H
	for y = yStart, yEnd - 1 do
		local base = y * stride * 8
		local top = if y > y0 then y else y0
		local bot = if y + 1 < y1 then y + 1 else y1
		local dy = bot - top
		local xnext = x + dxdy * dy
		local d = dy * dir
		local xa, xb = x, xnext
		if xa > xb then
			xa, xb = xb, xa
		end
		local x0floor = floor(xa)
		local x1ceil = ceil(xb)
		local x0i, x1i = x0floor, x1ceil
		if x1i <= x0i + 1 then
			local xmf = 0.5 * (x + xnext) - x0floor
			local o = base + x0i * 8
			buffer.writef64(cells, o, buffer.readf64(cells, o) + d - d * xmf)
			buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * xmf)
			x1i = x0i + 1
		else
			local s = 1 / (xb - xa)
			local x0f = xa - x0floor
			local a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
			local x1f = xb - x1ceil + 1
			local am = 0.5 * s * x1f * x1f
			local o = base + x0i * 8
			buffer.writef64(cells, o, buffer.readf64(cells, o) + d * a0)
			if x1i == x0i + 2 then
				buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * (1 - a0 - am))
			else
				local a1 = s * (1.5 - x0f)
				buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * (a1 - a0))
				local ds = d * s
				for xi = x0i + 2, x1i - 2 do
					local oi = base + xi * 8
					buffer.writef64(cells, oi, buffer.readf64(cells, oi) + ds)
				end
				local a2 = a1 + (x1i - x0i - 3) * s
				local ol = base + (x1i - 1) * 8
				buffer.writef64(cells, ol, buffer.readf64(cells, ol) + d * (1 - a2 - am))
			end
			local oe = base + x1i * 8
			buffer.writef64(cells, oe, buffer.readf64(cells, oe) + d * am)
		end
		local r = ranges[y + 1]
		r[#r + 1] = x0i
		r[#r + 1] = x1i
		x = xnext
	end
end

-- Adds one edge, clipping x to [0, width]: parts left of 0 become a vertical edge
-- on x = 0 (they cover every pixel to their right), parts right of width a
-- vertical edge on x = width (they cover nothing visible).
local function addLine(acc: Accumulator, x0: number, y0: number, x1: number, y1: number)
	local W = acc.width
	for _, k in { 0, W } do
		if (x0 < k) ~= (x1 < k) and x0 ~= k and x1 ~= k then
			local t = (k - x0) / (x1 - x0)
			local ym = y0 + (y1 - y0) * t
			addLine(acc, x0, y0, k, ym)
			addLine(acc, k, ym, x1, y1)
			return
		end
	end
	local cx0 = if x0 < 0 then 0 elseif x0 > W then W else x0
	local cx1 = if x1 < 0 then 0 elseif x1 > W then W else x1
	addLineInside(acc, cx0, y0, cx1, y1)
end
Scanline.addLine = addLine

-- Adds a closed polygon (flat {x1, y1, x2, y2, ...}).
function Scanline.addPolygon(acc: Accumulator, pts: { number })
	local n = #pts // 2
	local px, py = pts[2 * n - 1], pts[2 * n]
	for i = 1, n do
		local qx, qy = pts[2 * i - 1], pts[2 * i]
		addLine(acc, px, py, qx, qy)
		px, py = qx, qy
	end
end

-- Resolves the accumulated coverage into a straight-alpha layer: every pixel gets
-- colour rgb (0..0xFFFFFF) and alpha round(coverage * alpha). Spans between touched
-- cells are constant and are filled with buffer.copy. Clears the accumulator.
-- Returns the number of pixels computed one by one.
function Scanline.resolve(acc: Accumulator, out: buffer, rgb: number, alpha: number): number
	local W, H, stride = acc.width, acc.height, acc.stride
	local cells = acc.cells
	local perPixel = 0
	for y = 0, H - 1 do
		local r = acc.ranges[y + 1]
		local rowOut = y * W * 4
		local base = y * stride * 8
		local n = #r
		if n == 0 then
			Pixels.fillSpan(out, rowOut, W, rgb)
			continue
		end
		-- sort ranges by start (insertion sort on pairs; rows hold few ranges)
		for i = 3, n, 2 do
			local lo, hi = r[i], r[i + 1]
			local j = i - 2
			while j >= 1 and r[j] > lo do
				r[j + 2], r[j + 3] = r[j], r[j + 1]
				j -= 2
			end
			r[j + 2], r[j + 3] = lo, hi
		end
		local sum = 0
		local pos = 0 -- next pixel to write
		local i = 1
		while i <= n do
			local lo, hi = r[i], r[i + 1]
			i += 2
			-- merge overlapping or touching ranges
			while i <= n and r[i] <= hi + 1 do
				if r[i + 1] > hi then
					hi = r[i + 1]
				end
				i += 2
			end
			if lo > pos and pos < W then
				local a = math.min(1, math.abs(sum))
				local stop = if lo < W then lo else W
				Pixels.fillSpan(out, rowOut + pos * 4, stop - pos, rgb + ((a * alpha + 0.5) // 1) * 16777216)
				pos = stop
			end
			for x = lo, hi do
				local o = base + x * 8
				sum += buffer.readf64(cells, o)
				buffer.writef64(cells, o, 0)
				if x < W then
					local a = sum
					if a < 0 then
						a = -a
					end
					if a > 1 then
						a = 1
					end
					buffer.writeu32(out, rowOut + x * 4, rgb + ((a * alpha + 0.5) // 1) * 16777216)
					perPixel += 1
				end
			end
			if hi + 1 > pos then
				pos = hi + 1
			end
		end
		if pos < W then
			local a = math.min(1, math.abs(sum))
			Pixels.fillSpan(out, rowOut + pos * 4, W - pos, rgb + ((a * alpha + 0.5) // 1) * 16777216)
		end
		table.clear(r)
	end
	return perPixel
end

-- Points of an ellipse (cx, cy, rx, ry) as a polygon whose chords deviate from the
-- curve by at most tol pixels (sagitta r (1 - cos(pi / n)) <= tol), so the
-- coverage error of any pixel is at most about 1.5 * tol (chord length inside a
-- pixel is at most sqrt(2)). Vertices come from MyMath's polynomial sine, so they
-- are bit-identical on every platform.
function Scanline.flattenEllipse(cx: number, cy: number, rx: number, ry: number, tol: number): { number }
	local r = math.max(rx, ry)
	-- 1 - cos(x) <= x^2 / 2, so n >= pi * sqrt(r / (2 tol)) guarantees the bound
	local n = math.max(8, ceil(3.14159265358979 * math.sqrt(r / (2 * tol))))
	local pts = table.create(2 * n, 0)
	for i = 0, n - 1 do
		local t = i / n
		pts[2 * i + 1] = cx + rx * MyMath.dcosTurns(t)
		pts[2 * i + 2] = cy + ry * MyMath.dsinTurns(t)
	end
	return pts
end

return Scanline
