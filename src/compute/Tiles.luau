--!native
--!optimize 2
-- universe-at-home :: compute/Tiles
--
-- Tile-level structure for images of any size (docs/COMPUTE.md 2.2 and 2.6):
--
--   morton / unmorton   Z-order codes from bit32 "part1by1" (5 ops per axis) or a
--                       256-entry lookup table; tile orders (Morton, focus-first
--                       rings for Saturn's progressive refinement).
--   Store               content-addressed tiles. The key of a tile is its own pixel
--                       bytes as a Luau string: string interning hashes every byte
--                       and compares the full content on a hash match
--                       (VM/src/lstring.cpp), so equal keys mean equal pixels with
--                       no false positives and the work runs in C (C10).
--   Grid                a tiles-wide by tiles-high array of tile ids into a Store,
--                       copy-on-write: writing into a shared tile clones it first;
--                       commit() re-interns edited tiles so duplicates merge again.
--
-- Everything is integer and bit32 work; the bytes stored are the bytes given.

local Tiles = {}

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

-- Spreads the low 16 bits of v to the even bit positions.
local function part1by1(v: number): number
	v = band(bor(v, lshift(v, 8)), 0x00FF00FF)
	v = band(bor(v, lshift(v, 4)), 0x0F0F0F0F)
	v = band(bor(v, lshift(v, 2)), 0x33333333)
	return band(bor(v, lshift(v, 1)), 0x55555555)
end

local function compact1by1(v: number): number
	v = band(v, 0x55555555)
	v = band(bor(v, rshift(v, 1)), 0x33333333)
	v = band(bor(v, rshift(v, 2)), 0x0F0F0F0F)
	v = band(bor(v, rshift(v, 4)), 0x00FF00FF)
	return band(bor(v, rshift(v, 8)), 0x0000FFFF)
end

-- Morton code of (x, y), 0 <= x, y < 65536: bits of x at even positions.
function Tiles.morton(x: number, y: number): number
	return part1by1(x) + 2 * part1by1(y)
end

function Tiles.unmorton(code: number): (number, number)
	return compact1by1(code), compact1by1(rshift(code, 1))
end

-- Lookup-table variant: 256 spread bytes, two lookups per axis.
local SPREAD: { number } = table.create(256, 0)
for i = 0, 255 do
	SPREAD[i + 1] = part1by1(i)
end
Tiles.SPREAD = SPREAD

function Tiles.mortonLUT(x: number, y: number): number
	return SPREAD[x % 256 + 1] + SPREAD[x // 256 + 1] * 65536 + 2 * (SPREAD[y % 256 + 1] + SPREAD[y // 256 + 1] * 65536)
end

-- Tile indices (ty * tilesX + tx) in Morton order, skipping codes outside the grid.
function Tiles.mortonOrder(tilesX: number, tilesY: number): { number }
	local side = 1
	while side < tilesX or side < tilesY do
		side *= 2
	end
	local order = table.create(tilesX * tilesY, 0)
	local n = 0
	for code = 0, side * side - 1 do
		local tx, ty = compact1by1(code), compact1by1(rshift(code, 1))
		if tx < tilesX and ty < tilesY then
			n += 1
			order[n] = ty * tilesX + tx
		end
	end
	return order
end

-- Tile indices ordered by Chebyshev ring around the focus tile (fx, fy), Morton
-- order inside a ring: Saturn's rings, rendered nearest first.
function Tiles.ringOrder(tilesX: number, tilesY: number, fx: number, fy: number): { number }
	local order = Tiles.mortonOrder(tilesX, tilesY)
	local ring = table.create(tilesX * tilesY, 0)
	local rank = table.create(tilesX * tilesY, 0)
	for i, t in order do
		local tx, ty = t % tilesX, t // tilesX
		ring[t + 1] = math.max(math.abs(tx - fx), math.abs(ty - fy))
		rank[t + 1] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		local ra, rb = ring[a + 1], ring[b + 1]
		if ra ~= rb then
			return ra < rb
		end
		return rank[a + 1] < rank[b + 1]
	end)
	return order
end

----------------------------------------------------------------------------------
-- Content-addressed tile store
----------------------------------------------------------------------------------

export type Store = {
	size: number, -- tile edge in pixels
	byKey: { [string]: number }, -- content -> tile id
	keys: { string }, -- id -> content key ("" when the tile is private / being edited)
	tiles: { buffer }, -- id -> pixels (size * size * 4 bytes, row-major)
	refs: { number }, -- id -> number of grid cells using it
	free: { number }, -- recycled ids
	unique: number,
}

function Tiles.newStore(size: number): Store
	return { size = size, byKey = {}, keys = {}, tiles = {}, refs = {}, free = {}, unique = 0 }
end

local scratch: buffer? = nil

local function newId(store: Store): number
	local n = #store.free
	if n > 0 then
		local id = store.free[n]
		store.free[n] = nil
		return id
	end
	return #store.tiles + 1
end

-- Interns a packed tile buffer; returns its id and adds one reference.
local function internBuffer(store: Store, tile: buffer): number
	local key = buffer.tostring(tile)
	local id = store.byKey[key]
	if id then
		store.refs[id] += 1
		return id
	end
	id = newId(store)
	store.byKey[key] = id
	store.keys[id] = key
	store.tiles[id] = tile
	store.refs[id] = 1
	store.unique += 1
	return id
end
Tiles.internBuffer = internBuffer

-- Interns the size x size tile at pixel (x, y) of an image `width` pixels wide
-- (the tile must lie inside the image).
function Tiles.intern(store: Store, img: buffer, width: number, x: number, y: number): number
	local s = store.size
	local bytes = s * s * 4
	local t = scratch
	if t == nil or buffer.len(t) ~= bytes then
		t = buffer.create(bytes)
		scratch = t
	end
	local tb = t :: buffer
	local rowBytes = s * 4
	for r = 0, s - 1 do
		buffer.copy(tb, r * rowBytes, img, ((y + r) * width + x) * 4, rowBytes)
	end
	local key = buffer.tostring(tb)
	local id = store.byKey[key]
	if id then
		store.refs[id] += 1
		return id
	end
	-- new content: keep a private copy of the pixels
	local own = buffer.create(bytes)
	buffer.copy(own, 0, tb, 0, bytes)
	id = newId(store)
	store.byKey[key] = id
	store.keys[id] = key
	store.tiles[id] = own
	store.refs[id] = 1
	store.unique += 1
	return id
end

-- Drops one reference; frees the tile when none remain.
function Tiles.release(store: Store, id: number)
	local r = store.refs[id] - 1
	store.refs[id] = r
	if r == 0 then
		local key = store.keys[id]
		if key ~= "" and store.byKey[key] == id then
			store.byKey[key] = nil
		end
		store.keys[id] = ""
		store.tiles[id] = buffer.create(0)
		table.insert(store.free, id)
		store.unique -= 1
	end
end

----------------------------------------------------------------------------------
-- Copy-on-write grid
----------------------------------------------------------------------------------

export type Grid = {
	store: Store,
	tilesX: number,
	tilesY: number,
	ids: { number },
	dirty: { [number]: boolean }, -- cells holding a private, edited tile
}

-- Builds a grid from a full image (width and height multiples of the tile size).
function Tiles.fromImage(store: Store, img: buffer, width: number, height: number): Grid
	local s = store.size
	local tx, ty = width // s, height // s
	local ids = table.create(tx * ty, 0)
	for j = 0, ty - 1 do
		for i = 0, tx - 1 do
			ids[j * tx + i + 1] = Tiles.intern(store, img, width, i * s, j * s)
		end
	end
	return { store = store, tilesX = tx, tilesY = ty, ids = ids, dirty = {} }
end

-- Writes the grid into a full image (row blits).
function Tiles.compose(grid: Grid, out: buffer)
	local store = grid.store
	local s = store.size
	local width = grid.tilesX * s
	local rowBytes = s * 4
	for j = 0, grid.tilesY - 1 do
		for i = 0, grid.tilesX - 1 do
			local tile = store.tiles[grid.ids[j * grid.tilesX + i + 1]]
			local base = (j * s * width + i * s) * 4
			for r = 0, s - 1 do
				buffer.copy(out, base + r * width * 4, tile, r * rowBytes, rowBytes)
			end
		end
	end
end

-- Returns a buffer for cell (i, j) that may be written: if the cell's tile is
-- shared or interned, it is cloned into a private tile first (copy on write).
function Tiles.edit(grid: Grid, i: number, j: number): buffer
	local cell = j * grid.tilesX + i + 1
	local store = grid.store
	local id = grid.ids[cell]
	if grid.dirty[cell] then
		return store.tiles[id]
	end
	local src = store.tiles[id]
	local copy = buffer.create(buffer.len(src))
	buffer.copy(copy, 0, src, 0, buffer.len(src))
	Tiles.release(store, id)
	local nid = newId(store)
	store.keys[nid] = ""
	store.tiles[nid] = copy
	store.refs[nid] = 1
	store.unique += 1
	grid.ids[cell] = nid
	grid.dirty[cell] = true
	return copy
end

-- Re-interns every edited tile so equal content is shared again. Returns the
-- number of edited tiles that turned out to duplicate an existing tile.
function Tiles.commit(grid: Grid): number
	local store = grid.store
	local merged = 0
	for cell in grid.dirty do
		local id = grid.ids[cell]
		local tile = store.tiles[id]
		-- detach the private tile, then intern its content
		store.refs[id] = 0
		store.keys[id] = ""
		store.tiles[id] = buffer.create(0)
		table.insert(store.free, id)
		store.unique -= 1
		local before = store.unique
		local nid = internBuffer(store, tile)
		if store.unique == before then
			merged += 1
		end
		grid.ids[cell] = nid
	end
	table.clear(grid.dirty)
	return merged
end

-- Bytes held by unique tiles (pixels plus their string keys).
function Tiles.bytes(store: Store): number
	local s = store.size
	return store.unique * s * s * 4 * 2
end

return Tiles
