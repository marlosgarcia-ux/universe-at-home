--!native
--!optimize 2
-- universe-at-home :: Canvas
--
-- A CPU-side RGBA8 image (row-major buffer, EditableImage byte layout) that
-- remembers which tiles changed. flush() uploads only the changed area, merged into
-- as few rectangles as possible, through any writer function, so the same code
-- drives a real EditableImage, a tile of a giant virtual canvas, or a test mock.
--
-- Why: the display side refreshes only one EditableImage per frame (PUBLIC
-- CONTRACT), and every byte written costs engine time. Writing only what changed is
-- axiom A1 (change locality) in docs/DESIGN.md.

local Pixels = require("./Pixels")

local Canvas = {}
Canvas.__index = Canvas

export type Rect = { x: number, y: number, w: number, h: number }
export type Writer = (x: number, y: number, w: number, h: number, pixels: buffer) -> ()

export type Canvas = typeof(setmetatable(
	{} :: {
		width: number,
		height: number,
		buf: buffer,
		tile: number,
		tilesX: number,
		tilesY: number,
		dirty: buffer,
		dirtyCount: number,
		scratch: { [number]: buffer },
	},
	Canvas
))

-- tile: dirty-tracking granularity in pixels (default 32)
function Canvas.new(width: number, height: number, fill: number?, tile: number?): Canvas
	assert(width >= 1 and height >= 1, "canvas size must be positive")
	local t = tile or 32
	local self = setmetatable({
		width = width,
		height = height,
		buf = buffer.create(width * height * 4),
		tile = t,
		tilesX = (width + t - 1) // t,
		tilesY = (height + t - 1) // t,
		dirty = buffer.create(((width + t - 1) // t) * ((height + t - 1) // t)),
		dirtyCount = 0,
		scratch = {},
	}, Canvas)
	if fill and fill ~= 0 then
		Pixels.fill(self.buf, fill)
	end
	self:markAll()
	return self
end

-- Wraps an existing buffer (no copy).
function Canvas.fromBuffer(buf: buffer, width: number, height: number, tile: number?): Canvas
	assert(buffer.len(buf) == width * height * 4, "buffer size does not match width * height * 4")
	local self = Canvas.new(1, 1, nil, tile)
	self.width, self.height = width, height
	self.buf = buf
	local t = self.tile
	self.tilesX = (width + t - 1) // t
	self.tilesY = (height + t - 1) // t
	self.dirty = buffer.create(self.tilesX * self.tilesY)
	self.dirtyCount = 0
	self:markAll()
	return self
end

function Canvas.get(self: Canvas, x: number, y: number): number
	return buffer.readu32(self.buf, (y * self.width + x) * 4)
end

function Canvas.set(self: Canvas, x: number, y: number, color: number)
	buffer.writeu32(self.buf, (y * self.width + x) * 4, color)
	self:markDirty(x, y, 1, 1)
end

-- Marks a pixel rectangle as changed (clipped to the canvas).
function Canvas.markDirty(self: Canvas, x: number, y: number, w: number, h: number)
	local x0 = math.max(0, x)
	local y0 = math.max(0, y)
	local x1 = math.min(self.width, x + w) - 1
	local y1 = math.min(self.height, y + h) - 1
	if x1 < x0 or y1 < y0 then
		return
	end
	local t = self.tile
	local tx0, tx1 = x0 // t, x1 // t
	local ty0, ty1 = y0 // t, y1 // t
	local tilesX = self.tilesX
	local dirty = self.dirty
	for ty = ty0, ty1 do
		for tx = tx0, tx1 do
			local i = ty * tilesX + tx
			if buffer.readu8(dirty, i) == 0 then
				buffer.writeu8(dirty, i, 1)
				self.dirtyCount += 1
			end
		end
	end
end

function Canvas.markAll(self: Canvas)
	buffer.fill(self.dirty, 0, 1)
	self.dirtyCount = self.tilesX * self.tilesY
end

function Canvas.clearDirty(self: Canvas)
	buffer.fill(self.dirty, 0, 0)
	self.dirtyCount = 0
end

function Canvas.isDirty(self: Canvas): boolean
	return self.dirtyCount > 0
end

function Canvas.fill(self: Canvas, color: number)
	Pixels.fill(self.buf, color)
	self:markAll()
end

function Canvas.fillRect(self: Canvas, x: number, y: number, w: number, h: number, color: number)
	local x0, y0 = math.max(0, x), math.max(0, y)
	local x1, y1 = math.min(self.width, x + w), math.min(self.height, y + h)
	if x1 <= x0 or y1 <= y0 then
		return
	end
	Pixels.fillRect(self.buf, self.width, x0, y0, x1 - x0, y1 - y0, color)
	self:markDirty(x0, y0, x1 - x0, y1 - y0)
end

-- Turns dirty tiles into rectangles: horizontal runs per tile row, merged
-- vertically when consecutive rows have identical runs. If that yields more than
-- maxRects rectangles, or the bounding box is at least `densityThreshold` dirty,
-- one bounding rectangle is returned instead (fewer calls beats fewer bytes).
function Canvas.planFlush(self: Canvas, maxRects: number?, densityThreshold: number?): { Rect }
	local rects: { Rect } = {}
	if self.dirtyCount == 0 then
		return rects
	end
	local t = self.tile
	local tilesX, tilesY = self.tilesX, self.tilesY
	local dirty = self.dirty
	local open: { [number]: Rect } = {} -- key: run start * 65536 + run end
	local minTx, minTy, maxTx, maxTy = math.huge, math.huge, -1, -1
	for ty = 0, tilesY - 1 do
		local nextOpen: { [number]: Rect } = {}
		local tx = 0
		while tx < tilesX do
			if buffer.readu8(dirty, ty * tilesX + tx) == 1 then
				local start = tx
				while tx < tilesX and buffer.readu8(dirty, ty * tilesX + tx) == 1 do
					tx += 1
				end
				local stop = tx - 1
				if start < minTx then
					minTx = start
				end
				if stop > maxTx then
					maxTx = stop
				end
				if ty < minTy then
					minTy = ty
				end
				maxTy = ty
				local key = start * 65536 + stop
				local r = open[key]
				if r then
					r.h += t
					nextOpen[key] = r
				else
					r = { x = start * t, y = ty * t, w = (stop - start + 1) * t, h = t }
					table.insert(rects, r)
					nextOpen[key] = r
				end
			else
				tx += 1
			end
		end
		open = nextOpen
	end
	-- clip to canvas
	for _, r in rects do
		r.w = math.min(r.w, self.width - r.x)
		r.h = math.min(r.h, self.height - r.y)
	end
	local bx, by = minTx * t, minTy * t
	local bw = math.min((maxTx + 1) * t, self.width) - bx
	local bh = math.min((maxTy + 1) * t, self.height) - by
	local dirtyArea = 0
	for _, r in rects do
		dirtyArea += r.w * r.h
	end
	if #rects > (maxRects or 8) or dirtyArea >= (densityThreshold or 0.75) * bw * bh then
		return { { x = bx, y = by, w = bw, h = bh } }
	end
	return rects
end

function Canvas.scratchFor(self: Canvas, bytes: number): buffer
	local b = self.scratch[bytes]
	if not b then
		b = buffer.create(bytes)
		self.scratch[bytes] = b
	end
	return b
end

-- Uploads dirty pixels through `write`. Returns the number of pixels written.
-- A full-canvas rectangle passes the canvas buffer itself with no copy.
function Canvas.flush(self: Canvas, write: Writer, maxRects: number?, densityThreshold: number?): number
	local rects = self:planFlush(maxRects, densityThreshold)
	local written = 0
	for _, r in rects do
		if r.x == 0 and r.y == 0 and r.w == self.width and r.h == self.height then
			write(0, 0, r.w, r.h, self.buf)
		else
			local tmp = self:scratchFor(r.w * r.h * 4)
			Pixels.copyRect(tmp, r.w, 0, 0, self.buf, self.width, r.x, r.y, r.w, r.h)
			write(r.x, r.y, r.w, r.h, tmp)
		end
		written += r.w * r.h
	end
	self:clearDirty()
	return written
end

-- Writer for a Roblox EditableImage (or anything with WritePixelsBuffer).
-- vector2 is the Vector2 constructor, injected so this module stays engine-free.
function Canvas.editableImageWriter(image: any, vector2: (number, number) -> any, offsetX: number?, offsetY: number?): Writer
	local ox, oy = offsetX or 0, offsetY or 0
	return function(x: number, y: number, w: number, h: number, pixels: buffer)
		image:WritePixelsBuffer(vector2(x + ox, y + oy), vector2(w, h), pixels)
	end
end

return Canvas
