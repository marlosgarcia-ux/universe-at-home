--!strict
-- Universe at Home: Planets :: Uploader
--
-- Roblox refreshes only one displayed EditableImage per frame (EditableImage reference,
-- "Update Limitations"; docs/RUNTIME_AUDIT.md). Writing several images in one frame does
-- not make them appear sooner; it only makes the order unpredictable. So every pixel write
-- in the planet system goes through this queue: rectangles pile up per image, and each
-- frame exactly one image (round robin among those with work, the oldest first) takes all
-- of its pending rectangles in one go. An atlas can therefore receive dozens of tiles in a
-- single refresh, and a patch counts as ready only once all of its atlases have flushed.

local Uploader = {}

type Rect = {
	x: number,
	y: number,
	w: number,
	h: number,
	buf: buffer,
	done: (() -> ())?,
}

export type Entry = {
	name: string,
	img: EditableImage,
	pending: { Rect },
	since: number, -- frame of the oldest pending rectangle
}

export type Uploader = {
	entries: { Entry },
	frame: number,
	stats: { flushes: number, rects: number, bytes: number, errors: number, lastError: string?, lastImage: string },
}

function Uploader.new(): Uploader
	return {
		entries = {},
		frame = 0,
		stats = { flushes = 0, rects = 0, bytes = 0, errors = 0, lastError = nil, lastImage = "" },
	}
end

function Uploader.register(U: Uploader, name: string, img: EditableImage): Entry
	local e: Entry = { name = name, img = img, pending = {}, since = math.huge }
	table.insert(U.entries, e)
	return e
end

function Uploader.unregister(U: Uploader, e: Entry)
	local i = table.find(U.entries, e)
	if i then
		table.remove(U.entries, i)
	end
end

-- Queues a w x h rectangle at (x, y). `done` runs right after the rectangle is written.
function Uploader.queue(U: Uploader, e: Entry, x: number, y: number, w: number, h: number, buf: buffer, done: (() -> ())?)
	if #e.pending == 0 then
		e.since = U.frame
	end
	table.insert(e.pending, { x = x, y = y, w = w, h = h, buf = buf, done = done })
end

-- Number of rectangles waiting.
function Uploader.backlog(U: Uploader): number
	local n = 0
	for _, e in U.entries do
		n += #e.pending
	end
	return n
end

-- Flushes the image that has waited longest. Call once per frame.
function Uploader.step(U: Uploader)
	U.frame += 1
	local best: Entry? = nil
	for _, e in U.entries do
		if #e.pending > 0 and (best == nil or e.since < (best :: Entry).since) then
			best = e
		end
	end
	if not best then
		return
	end
	local e = best :: Entry
	local list = e.pending
	e.pending = {}
	e.since = math.huge
	U.stats.flushes += 1
	U.stats.lastImage = e.name
	for _, r in list do
		local ok, err = pcall(function()
			e.img:WritePixelsBuffer(Vector2.new(r.x, r.y), Vector2.new(r.w, r.h), r.buf)
		end)
		if ok then
			U.stats.rects += 1
			U.stats.bytes += r.w * r.h * 4
		else
			U.stats.errors += 1
			U.stats.lastError = tostring(err)
		end
		local done = r.done
		if done then
			done()
		end
	end
end

return Uploader
