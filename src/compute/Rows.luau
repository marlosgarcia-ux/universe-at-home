--!native
--!optimize 2
-- universe-at-home :: compute/Rows
--
-- Batch row kernels (docs/COMPUTE.md 3.4 and 4.2): one exact-coverage disc, one
-- row at a time, three ways that write identical bytes:
--
--   direct   per pixel: e = dx^2 + dy^2, d = sqrt(e) - r, exact coverage
--   fd       forward differencing: e(x + 1) = e(x) + (2 dx + 1), so the square is
--            replaced by two additions. With the centre on a 1/16 grid every
--            value is a multiple of 1/256 below 2^45, so the additions are exact
--            and e is bit-identical to the direct square (C7).
--   spans    analytic spans: per row, the x-interval where the pixel can be
--            partly covered is solved from e = (r +- reach)^2; pixels well
--            inside are one span fill (buffer.copy doubling), pixels well
--            outside another, and only the band in between is shaded with the
--            same per-pixel formula. Cost per row: O(band), not O(width).
--
-- Output: straight-alpha RGBA8, colour rgb, alpha = round(255 * coverage).

local Pixels = require("../Pixels")
local Raster = require("./Raster")

local Rows = {}

local covCurved = Raster.covCurved
local sqrt = math.sqrt
local REACH = 0.70710678118654757

local function shadePixel(dx: number, dy: number, e: number, r: number, k: number): number
	local len = sqrt(e)
	if len > 0 then
		return covCurved(len - r, dx / len, dy / len, k)
	end
	return covCurved(-r, 1, 0, 0)
end

function Rows.circleDirect(out: buffer, width: number, y: number, cx: number, cy: number, r: number, rgb: number)
	local dy = y + 0.5 - cy
	local k = 1 / r
	local o = y * width * 4
	for x = 0, width - 1 do
		local dx = x + 0.5 - cx
		local e = dx * dx + dy * dy
		local c = shadePixel(dx, dy, e, r, k)
		buffer.writeu32(out, o, rgb + ((c * 255 + 0.5) // 1) * 16777216)
		o += 4
	end
end

function Rows.circleFD(out: buffer, width: number, y: number, cx: number, cy: number, r: number, rgb: number)
	local dy = y + 0.5 - cy
	local k = 1 / r
	local o = y * width * 4
	local dx = 0.5 - cx
	local e = dx * dx + dy * dy
	for _ = 0, width - 1 do
		local c = shadePixel(dx, dy, e, r, k)
		buffer.writeu32(out, o, rgb + ((c * 255 + 0.5) // 1) * 16777216)
		o += 4
		e += 2 * dx + 1 -- (dx + 1)^2 - dx^2
		dx += 1
	end
end

-- Returns the number of pixels shaded one by one.
function Rows.circleSpans(out: buffer, width: number, y: number, cx: number, cy: number, r: number, rgb: number): number
	local dy = y + 0.5 - cy
	local k = 1 / r
	local row = y * width * 4
	local ro = r + REACH
	local ro2 = ro * ro - dy * dy
	if ro2 <= 0 then
		Pixels.fillSpan(out, row, width, rgb) -- whole row outside the band
		return 0
	end
	-- pixel centres x + 0.5 with |x + 0.5 - cx| < hwOuter can be partly covered;
	-- widen by one pixel so the per-pixel formula, not the solve, decides edges
	local hwOuter = sqrt(ro2)
	local xa = math.max(0, math.floor(cx - hwOuter - 0.5) - 1)
	local xb = math.min(width - 1, math.ceil(cx + hwOuter - 0.5) + 1)
	local ri = r - REACH
	local ia, ib = xb + 1, xb -- empty interior unless the row crosses the inner disc
	if ri > 0 and ri * ri - dy * dy > 0 then
		local hwInner = sqrt(ri * ri - dy * dy)
		ia = math.ceil(cx - hwInner - 0.5) + 1
		ib = math.floor(cx + hwInner - 0.5) - 1
		if ia < xa then
			ia = xa
		end
		if ib > xb then
			ib = xb
		end
	end
	Pixels.fillSpan(out, row, xa, rgb)
	Pixels.fillSpan(out, row + (xb + 1) * 4, width - 1 - xb, rgb)
	local shaded = 0
	local function band(x0: number, x1: number)
		local o = row + x0 * 4
		for x = x0, x1 do
			local dx = x + 0.5 - cx
			local c = shadePixel(dx, dy, dx * dx + dy * dy, r, k)
			buffer.writeu32(out, o, rgb + ((c * 255 + 0.5) // 1) * 16777216)
			o += 4
		end
		shaded += x1 - x0 + 1
	end
	if ia <= ib then
		band(xa, ia - 1)
		Pixels.fillSpan(out, row + ia * 4, ib - ia + 1, rgb + 0xFF000000)
		band(ib + 1, xb)
	else
		band(xa, xb)
	end
	return shaded
end

return Rows
