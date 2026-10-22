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
-- Fill rule: non-zero, coverage = min(1, |winding area|), which is the exact area
-- for paths whose winding number is 0 or +-1 everywhere (simple, non-overlapping
-- contours; holes wound the other way). Curves are flattened to line segments with
-- a sagitta tolerance (flattenEllipse), whose area error per pixel is at most about
-- 1.5 times the tolerance (that is the polygon's distance from the curve; the
-- polygon itself is rendered exactly).
--
-- Single path versus scenes (docs/COMPUTE.md F2, C11):
--   resolve, composite   one path. Exact (F1): the byte is the correctly rounded
--                        coverage, composited once over the destination.
--                        Painting a multi-path scene by calling composite per path
--                        is NOT exact: shared edges conflate (a 64/255 seam) and
--                        translucent layers round to 8 bits after every path.
--   renderScene          many paths, exact (F2): rows are processed top to bottom;
--                        each path's coverage comes from a one-row accumulator, is
--                        composited in floating point where the byte would be
--                        inexact (edges, translucent paths) and with span fills
--                        where it is exact (opaque interiors), and every pixel
--                        where two or more paths' edges enter is recomputed with
--                        exact visibility (compute/Visibility.luau) from the
--                        paths' geometry. Each output byte is rounded once.
--
-- Deterministic: + - * / floor ceil min max abs only (plus Coverage.dasin inside
-- Visibility's disc areas, unused for polygons).

local Pixels = require("../Pixels")
local MyMath = require("../MyMath")
local Visibility = require("./Visibility")

local Scanline = {}

export type Accumulator = {
	width: number,
	height: number,
	stride: number, -- cells per row (width + 2)
	cells: buffer, -- f64 per cell
	ranges: { { number } }, -- per row: flat list of touched cell ranges (lo, hi, lo, hi, ...)
}

function Scanline.new(width: number, height: number): Accumulator
	local ranges: { { number } } = {}
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

-- Composites the accumulated coverage onto an RGBA8 destination with straight-alpha
-- source-over, in colour `color` (packed RGBA8): the exact-area vector painter.
-- Rows without touched cells are not visited at all. Between touched ranges the
-- running sum is constant: 0 (span skipped), 1 (fully covered: one span fill for
-- an opaque colour) or a fraction, in rows that a horizontal edge or a vertex
-- crosses (blended pixel by pixel with that constant coverage). Clears the
-- accumulator. Returns the number of touched cells blended one by one.
function Scanline.composite(acc: Accumulator, dst: buffer, color: number): number
	local W, H, stride = acc.width, acc.height, acc.stride
	local cells = acc.cells
	local cr, cg, cb = color % 256, (color // 256) % 256, (color // 65536) % 256
	local ca = (color // 16777216) / 255
	local opaque = ca >= 1
	local perPixel = 0
	local function blend(o: number, cov: number)
		local sa = cov * ca
		if sa <= 0 then
			return
		end
		if sa >= 1 then
			buffer.writeu32(dst, o, color)
			return
		end
		local p = buffer.readu32(dst, o)
		local da = (p // 16777216) / 255 * (1 - sa)
		local oa = sa + da
		local r = (cr * sa + (p % 256) * da) / oa
		local g = (cg * sa + ((p // 256) % 256) * da) / oa
		local b = (cb * sa + ((p // 65536) % 256) * da) / oa
		buffer.writeu32(dst, o, (r + 0.5) // 1 + ((g + 0.5) // 1) * 256 + ((b + 0.5) // 1) * 65536 + ((oa * 255 + 0.5) // 1) * 16777216)
	end
	-- span [x0, x1) with constant winding sum s
	local function spanFill(rowOut: number, x0: number, x1: number, s: number)
		local a = if s < 0 then -s else s
		if a < 1e-9 then
			return
		end
		if a >= 1 - 1e-9 and opaque then
			Pixels.fillSpan(dst, rowOut + x0 * 4, x1 - x0, color)
			return
		end
		if a > 1 then
			a = 1
		end
		for x = x0, x1 - 1 do
			blend(rowOut + x * 4, a)
		end
	end
	for y = 0, H - 1 do
		local r = acc.ranges[y + 1]
		local n = #r
		if n == 0 then
			continue
		end
		local rowOut = y * W * 4
		local base = y * stride * 8
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
		local pos = 0
		local i = 1
		while i <= n do
			local lo, hi = r[i], r[i + 1]
			i += 2
			while i <= n and r[i] <= hi + 1 do
				if r[i + 1] > hi then
					hi = r[i + 1]
				end
				i += 2
			end
			if lo > pos and pos < W then
				spanFill(rowOut, pos, if lo < W then lo else W, sum)
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
					blend(rowOut + x * 4, a)
					perPixel += 1
				end
			end
			if hi + 1 > pos then
				pos = hi + 1
			end
		end
		if pos < W then
			spanFill(rowOut, pos, W, sum)
		end
		table.clear(r)
	end
	return perPixel
end

----------------------------------------------------------------------------------
-- Exact multi-path scenes (F2)
----------------------------------------------------------------------------------

-- A path: one or more closed contours (flat x, y lists; non-zero winding with
-- values 0 or +-1, e.g. outer contours one way and holes the other) filled with
-- a straight-alpha RGBA8 colour.
export type Path = { contours: { { number } }, color: number }
export type SceneStats = { conflicts: number, floatPixels: number, spans: number }

type Prepared = {
	edges: { number }, -- x0, y0, x1, y1, dir per edge; y0 < y1; x clamped to [0, W]; sorted by y0
	nf: number, -- number of floats in edges
	act: { number }, -- indices (into edges) of active edges
	nact: number,
	cursor: number, -- next edge to activate
	row0: number,
	row1: number,
	r: number,
	g: number,
	b: number,
	a: number,
	color: number,
	sigma: number, -- orientation of the path (sign of its total signed area)
	contours: { { number } },
}

-- Appends edge (x0, y0)-(x1, y1) to e with x split at 0 and W and clamped to [0, W]
-- (left of 0 it covers every pixel to its right, right of W nothing visible).
local function prepEdge(e: { number }, x0: number, y0: number, x1: number, y1: number, W: number)
	if y0 == y1 then
		return
	end
	for _, k in { 0, W } do
		if (x0 < k) ~= (x1 < k) and x0 ~= k and x1 ~= k then
			local t = (k - x0) / (x1 - x0)
			local ym = y0 + (y1 - y0) * t
			prepEdge(e, x0, y0, k, ym, W)
			prepEdge(e, k, ym, x1, y1, W)
			return
		end
	end
	x0 = if x0 < 0 then 0 elseif x0 > W then W else x0
	x1 = if x1 < 0 then 0 elseif x1 > W then W else x1
	local dir = 1
	if y0 > y1 then
		dir = -1
		x0, y0, x1, y1 = x1, y1, x0, y0
	end
	local n = #e
	e[n + 1], e[n + 2], e[n + 3], e[n + 4], e[n + 5] = x0, y0, x1, y1, dir
end

local function prepare(path: Path, W: number, H: number): Prepared
	local raw: { number } = {}
	local area = 0
	local ymin, ymax = math.huge, -math.huge
	for _, c in path.contours do
		local n = #c // 2
		local px, py = c[2 * n - 1], c[2 * n]
		for i = 1, n do
			local qx, qy = c[2 * i - 1], c[2 * i]
			prepEdge(raw, px, py, qx, qy, W)
			area += px * qy - qx * py
			if qy < ymin then
				ymin = qy
			end
			if qy > ymax then
				ymax = qy
			end
			px, py = qx, qy
		end
	end
	-- sort edges by y0
	local ne = #raw // 5
	local idx = table.create(ne, 0)
	for i = 1, ne do
		idx[i] = i
	end
	table.sort(idx, function(a: number, b: number): boolean
		return raw[5 * a - 3] < raw[5 * b - 3]
	end)
	local edges = table.create(#raw, 0)
	for k, i in idx do
		for j = 1, 5 do
			edges[5 * (k - 1) + j] = raw[5 * (i - 1) + j]
		end
	end
	local color = path.color
	local row0 = if ymin > 0 then floor(ymin) else 0
	local row1 = if ymax < H then ceil(ymax) - 1 else H - 1
	return {
		edges = edges,
		nf = #edges,
		act = table.create(16, 0),
		nact = 0,
		cursor = 1,
		row0 = row0,
		row1 = row1,
		r = color % 256,
		g = (color // 256) % 256,
		b = (color // 65536) % 256,
		a = (color // 16777216) / 255,
		color = color,
		sigma = if area >= 0 then 1 else -1,
		contours = path.contours,
	}
end

-- Deposits the part of edge (x0, y0)-(x1, y1) (y0 < y1, x in [0, W]) inside row y
-- into the row's cells (the per-row body of addLineInside) and records the
-- touched cell range in R. Returns the new range count.
local function rowEdge(cells: buffer, y: number, x0: number, y0: number, x1: number, y1: number, dir: number, R: { number }, nr: number): number
	local top = if y > y0 then y else y0
	local bot = if y + 1 < y1 then y + 1 else y1
	if bot <= top then
		return nr
	end
	local dxdy = (x1 - x0) / (y1 - y0)
	local xt = x0 + (top - y0) * dxdy
	local xn = x0 + (bot - y0) * dxdy
	local d = (bot - top) * dir
	local xa, xb = xt, xn
	if xa > xb then
		xa, xb = xb, xa
	end
	local x0floor = floor(xa)
	local x0i, x1i = x0floor, ceil(xb)
	if x1i <= x0i + 1 then
		local xmf = 0.5 * (xt + xn) - x0floor
		local o = x0i * 8
		buffer.writef64(cells, o, buffer.readf64(cells, o) + d - d * xmf)
		buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * xmf)
		x1i = x0i + 1
	else
		local s = 1 / (xb - xa)
		local x0f = xa - x0floor
		local a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
		local x1f = xb - x1i + 1
		local am = 0.5 * s * x1f * x1f
		local o = x0i * 8
		buffer.writef64(cells, o, buffer.readf64(cells, o) + d * a0)
		if x1i == x0i + 2 then
			buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * (1 - a0 - am))
		else
			local a1 = s * (1.5 - x0f)
			buffer.writef64(cells, o + 8, buffer.readf64(cells, o + 8) + d * (a1 - a0))
			local ds = d * s
			for xi = x0i + 2, x1i - 2 do
				local oi = xi * 8
				buffer.writef64(cells, oi, buffer.readf64(cells, oi) + ds)
			end
			local a2 = a1 + (x1i - x0i - 3) * s
			local ol = (x1i - 1) * 8
			buffer.writef64(cells, ol, buffer.readf64(cells, ol) + d * (1 - a2 - am))
		end
		local oe = x1i * 8
		buffer.writef64(cells, oe, buffer.readf64(cells, oe) + d * am)
	end
	R[nr + 1] = x0i
	R[nr + 2] = x1i
	return nr + 2
end

local CTX: { number } = table.create(256, 0)
local CTY: { number } = table.create(256, 0)

-- Pieces of path P at pixel (x, y) for exact visibility.
local function pathPieces(P: Prepared, x: number, y: number)
	local px, py = x + 0.5, y + 0.5
	for _, c in P.contours do
		local n = #c // 2
		for i = 1, n do
			CTX[i] = c[2 * i - 1] - px
			CTY[i] = c[2 * i] - py
		end
		Visibility.polygon(CTX, CTY, n, P.sigma)
	end
end

-- Renders paths (bottom to top) onto dst (width x height RGBA8, straight alpha),
-- over a background colour if given (else over dst's current content), as the
-- exact box filter of the source-over composite (F2): every pixel is computed in
-- floating point from exact coverages and rounded once; pixels where two or more
-- paths' edges enter use exact visibility. Opaque interiors are span fills.
function Scanline.renderScene(dst: buffer, width: number, height: number, paths: { Path }, background: number?): SceneStats
	local W, H = width, height
	if background then
		Pixels.fill(dst, background)
	end
	local np = #paths
	local P: { Prepared } = {}
	for i = 1, np do
		P[i] = prepare(paths[i], W, H)
	end
	local cells = buffer.create((W + 2) * 8)
	local R: { number } = table.create(64, 0)
	local rowF = buffer.create(W * 32) -- premultiplied r, g, b (0..255 * a), a (0..1)
	local snapF = buffer.create(W * 32) -- base below the first edge since the last opaque cover
	local flag = buffer.create(W) -- 1: rowF holds this pixel's (inexact as a byte) value
	local nfB = buffer.create(W) -- paths with fractional coverage since the last opaque cover
	local head = buffer.create(W * 4) -- event list head per pixel (0: none)
	local conf = buffer.create(W) -- 1: pixel is in the conflict list
	local EVp: { number } = table.create(256, 0)
	local EVc: { number } = table.create(256, 0)
	local EVn: { number } = table.create(256, 0)
	local CL: { number } = table.create(64, 0)
	local st: SceneStats = { conflicts = 0, floatPixels = 0, spans = 0 }
	for y = 0, H - 1 do
		local rowOut = y * W * 4
		buffer.fill(flag, 0, 0)
		buffer.fill(nfB, 0, 0)
		buffer.fill(head, 0, 0)
		local nev = 0
		local ncl = 0
		local minX, maxX = W, -1
		for pi = 1, np do
			local Q = P[pi]
			if y < Q.row0 or y > Q.row1 then
				continue
			end
			-- activate edges starting above the row's bottom, deposit active ones
			local E, act = Q.edges, Q.act
			local nact = Q.nact
			local cursor = Q.cursor
			while cursor <= Q.nf and E[cursor + 1] < y + 1 do
				nact += 1
				act[nact] = cursor
				cursor += 5
			end
			Q.cursor = cursor
			local nr = 0
			local keep = 0
			for i = 1, nact do
				local e = act[i]
				local ey1 = E[e + 3]
				if ey1 > y then
					nr = rowEdge(cells, y, E[e], E[e + 1], E[e + 2], ey1, E[e + 4], R, nr)
				end
				if ey1 > y + 1 then
					keep += 1
					act[keep] = e
				end
			end
			Q.nact = keep
			if nr == 0 then
				continue
			end
			local cr, cg, cb, ca = Q.r, Q.g, Q.b, Q.a
			local color = Q.color
			local opaque = ca >= 1
			-- composite coverage c of this path at pixel x
			local function pixel(x: number, c: number)
				if c < 1e-9 then
					return
				end
				if c > 1 - 1e-9 then
					c = 1
				end
				local sa = c * ca
				if sa >= 1 then
					buffer.writeu32(dst, rowOut + x * 4, color)
					buffer.writeu8(flag, x, 0)
					buffer.writeu8(nfB, x, 0)
					buffer.writeu32(head, x * 4, 0)
					return
				end
				local o = x * 32
				local pr, pg, pb, pa = 0, 0, 0, 0
				if buffer.readu8(flag, x) == 1 then
					pr = buffer.readf64(rowF, o)
					pg = buffer.readf64(rowF, o + 8)
					pb = buffer.readf64(rowF, o + 16)
					pa = buffer.readf64(rowF, o + 24)
				else
					local p = buffer.readu32(dst, rowOut + x * 4)
					pa = (p // 16777216) / 255
					pr = (p % 256) * pa
					pg = ((p // 256) % 256) * pa
					pb = ((p // 65536) % 256) * pa
					buffer.writeu8(flag, x, 1)
					if x < minX then
						minX = x
					end
					if x > maxX then
						maxX = x
					end
				end
				local n = buffer.readu8(nfB, x)
				if c < 1 then
					if n == 0 then
						buffer.writef64(snapF, o, pr)
						buffer.writef64(snapF, o + 8, pg)
						buffer.writef64(snapF, o + 16, pb)
						buffer.writef64(snapF, o + 24, pa)
						buffer.writeu32(head, x * 4, 0)
					end
					n += 1
					buffer.writeu8(nfB, x, if n < 255 then n else 255)
					if n == 2 and buffer.readu8(conf, x) == 0 then
						buffer.writeu8(conf, x, 1)
						ncl += 1
						CL[ncl] = x
					end
				end
				if n >= 1 then
					nev += 1
					EVp[nev] = pi
					EVc[nev] = c
					EVn[nev] = buffer.readu32(head, x * 4)
					buffer.writeu32(head, x * 4, nev)
				end
				local ia = 1 - sa
				buffer.writef64(rowF, o, cr * sa + pr * ia)
				buffer.writef64(rowF, o + 8, cg * sa + pg * ia)
				buffer.writef64(rowF, o + 16, cb * sa + pb * ia)
				buffer.writef64(rowF, o + 24, sa + pa * ia)
			end
			local function span(x0: number, x1: number, s: number)
				local a = if s < 0 then -s else s
				if a < 1e-9 or x1 <= x0 then
					return
				end
				if a > 1 - 1e-9 and opaque then
					local n = x1 - x0
					Pixels.fillSpan(dst, rowOut + x0 * 4, n, color)
					buffer.fill(flag, x0, 0, n)
					buffer.fill(nfB, x0, 0, n)
					buffer.fill(head, x0 * 4, 0, n * 4)
					st.spans += 1
					return
				end
				if a > 1 then
					a = 1
				end
				for x = x0, x1 - 1 do
					pixel(x, a)
				end
			end
			-- sort the touched ranges and sweep the running sum
			for i = 3, nr, 2 do
				local lo, hi = R[i], R[i + 1]
				local j = i - 2
				while j >= 1 and R[j] > lo do
					R[j + 2], R[j + 3] = R[j], R[j + 1]
					j -= 2
				end
				R[j + 2], R[j + 3] = lo, hi
			end
			local sum = 0
			local pos = 0
			local i = 1
			while i <= nr do
				local lo, hi = R[i], R[i + 1]
				i += 2
				while i <= nr and R[i] <= hi + 1 do
					if R[i + 1] > hi then
						hi = R[i + 1]
					end
					i += 2
				end
				if lo > pos and pos < W then
					span(pos, if lo < W then lo else W, sum)
				end
				for x = lo, hi do
					local o = x * 8
					sum += buffer.readf64(cells, o)
					buffer.writef64(cells, o, 0)
					if x < W then
						local a = if sum < 0 then -sum else sum
						pixel(x, if a > 1 then 1 else a)
					end
				end
				if hi + 1 > pos then
					pos = hi + 1
				end
			end
			if pos < W then
				span(pos, W, sum)
			end
		end
		-- exact visibility where two or more edges entered
		for k = 1, ncl do
			local x = CL[k]
			buffer.writeu8(conf, x, 0)
			if buffer.readu8(nfB, x) < 2 then
				continue
			end
			st.conflicts += 1
			Visibility.reset()
			local e = buffer.readu32(head, x * 4)
			while e ~= 0 do
				local Q = P[EVp[e]]
				local c = EVc[e]
				if c >= 1 then
					Visibility.full(Q.r, Q.g, Q.b, Q.a)
				else
					Visibility.begin(Q.r, Q.g, Q.b, Q.a)
					pathPieces(Q, x, y)
					Visibility.commit()
				end
				e = EVn[e]
			end
			local o = x * 32
			local sr = buffer.readf64(snapF, o)
			local sg = buffer.readf64(snapF, o + 8)
			local sb = buffer.readf64(snapF, o + 16)
			local sa = buffer.readf64(snapF, o + 24)
			if sa > 0 then
				sr, sg, sb = sr / sa, sg / sa, sb / sa
			end
			local r, g, b, a = Visibility.finish(sr, sg, sb, sa)
			buffer.writef64(rowF, o, r * a)
			buffer.writef64(rowF, o + 8, g * a)
			buffer.writef64(rowF, o + 16, b * a)
			buffer.writef64(rowF, o + 24, a)
		end
		-- round every float pixel once
		for x = minX, maxX do
			if buffer.readu8(flag, x) == 1 then
				st.floatPixels += 1
				local o = x * 32
				local a = buffer.readf64(rowF, o + 24)
				local px = 0
				if a > 0 then
					px = (buffer.readf64(rowF, o) / a + 0.5) // 1
						+ ((buffer.readf64(rowF, o + 8) / a + 0.5) // 1) * 256
						+ ((buffer.readf64(rowF, o + 16) / a + 0.5) // 1) * 65536
						+ ((a * 255 + 0.5) // 1) * 16777216
				end
				buffer.writeu32(dst, rowOut + x * 4, px)
			end
		end
	end
	return st
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
