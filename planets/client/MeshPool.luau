--!strict
-- Universe at Home: Planets :: MeshPool
--
-- The GPU side of the surface: atlas sets and the EditableMeshes that carry every patch.
--
-- ATLAS SET. Colour (1024 x 1024), normal (1024 x 1024) and roughness (512 x 512)
-- EditableImages; patch slot i of a set owns tile i of each (Layout). One SurfaceAppearance
-- per mesh part, built by AssetService:CreateSurfaceAppearanceAsync from the set's three
-- atlases: the only way a game script gets normal and roughness maps on a mesh (their
-- properties are plugin-only). Its maps cannot be swapped, but the EditableImages behind
-- them can be rewritten, which is all the pool ever does. If the engine refuses, the pool
-- falls back to MeshPart.TextureContent (colour only) and says so. More sets, more tiles:
-- Config.atlasSets (9 MB each) is how the surface gets finer.
--
-- ONE MESH. All 256 slots of a set live in ONE EditableMesh (one MeshPart, one draw
-- call, one SurfaceAppearance): slot k owns vertices [k * 357, (k + 1) * 357) with fixed
-- topology and fixed per-vertex UVs into its own tile. Showing a patch is two batch writes
-- of its 357 vertices (positions, normals); hiding it parks the vertices in a tiny cluster
-- at the body's centre (small, not degenerate, in case the engine drops degenerate faces).
-- If the engine refuses a mesh that large (the limit is not publicly specified), the pool
-- halves the slots per mesh until it is accepted, and reports what it settled on.
-- All vertices are body-local and two tiny triangles pin each mesh's bounding box to
-- +-PIN_EXTENT on every axis: the box is centred on the body whichever origin rule the
-- engine uses and never changes size, so every part simply sits at the body's centre.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Layout = require(Planets:WaitForChild("Layout")) :: any
local TileGen = require(Planets:WaitForChild("TileGen")) :: any
local Config = require(Planets:WaitForChild("Config")) :: any
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local MeshPool = {}

local VS = Layout.VERTS - Layout.PIN_VERTS -- vertices per slot (grid + skirts): 357
local TS = Layout.TRIS - Layout.PIN_TRIS -- triangles per slot: 640
MeshPool.VS = VS

export type Morph = {
	t: number,
	start: { Vector3 },
	final: { Vector3 },
}

export type Set = {
	index: number,
	color: EditableImage,
	normal: EditableImage?,
	rough: EditableImage?,
	colorEntry: Uploader.Entry,
	normalEntry: Uploader.Entry?,
	roughEntry: Uploader.Entry?,
	template: SurfaceAppearance?,
	chunks: { Chunk },
}

export type Chunk = {
	set: Set,
	mesh: EditableMesh,
	part: MeshPart,
	sa: SurfaceAppearance?,
	first: number, -- first slot (index within the set)
	count: number,
	uvIds: { number }, -- every vertex's UV id (to rewrite the UV origin)
}

export type Slot = {
	index: number, -- 0-based over the whole pool
	set: Set,
	chunk: Chunk,
	tile: number, -- index within the set = atlas tile
	tx: number,
	ty: number,
	vIds: { number }, -- this slot's VS vertex ids
	nIds: { number },
	key: number?,
	state: string, -- "free" | "generating" | "uploading" | "ready" | "shown"
	lastUsed: number,
	ticket: number,
	result: any?, -- generated buffers while the patch is held
	final: { Vector3 }?,
	finalN: { Vector3 }?,
	morph: Morph?,
}

export type Pool = {
	sets: { Set },
	chunks: { Chunk },
	slots: { Slot },
	mode: string, -- "pbr" | "texture"
	note: string,
	folder: Folder,
	flipV: boolean,
	cloneWorks: boolean?,
	tris: { number },
	failed: string?,
	meshMode: string,
	slotsPerMesh: number,
	maxSlots: number, -- slots in the sets built so far
	stats: { created: number, writes: number, meshMs: number, pixels: number, meshVerts: number },
	park: { Vector3 },
	U: Uploader.Uploader,
}

local function createImage(w: number, h: number): (EditableImage?, string?)
	local ok, result = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	if not ok then
		return nil, tostring(result)
	end
	if not result then
		return nil, "CreateEditableImage returned nil (editable memory budget)"
	end
	return result :: EditableImage, nil
end
MeshPool.createImage = createImage

function MeshPool.new(U: Uploader.Uploader, folder: Folder): Pool
	local park: { Vector3 } = table.create(VS)
	for i = 0, VS - 1 do
		park[i + 1] = Vector3.new((i % 19) * 0.002, ((i // 19) % 19) * 0.002, (i // 361) * 0.002)
	end
	return {
		sets = {},
		chunks = {},
		slots = {},
		mode = "texture",
		note = "no atlas set yet",
		folder = folder,
		flipV = false,
		cloneWorks = nil,
		tris = TileGen.triangles(),
		failed = nil,
		meshMode = "batch",
		slotsPerMesh = math.clamp(Config.slotsPerMesh, 8, Layout.SLOTS),
		maxSlots = 0,
		stats = { created = 0, writes = 0, meshMs = 0, pixels = 0, meshVerts = 0 },
		park = park,
		U = U,
	}
end

-- One SurfaceAppearance for a mesh part of `set`: a clone of the set's template when cloning
-- keeps the maps, else a fresh CreateSurfaceAppearanceAsync call.
local function surfaceFor(pool: Pool, set: Set): SurfaceAppearance?
	local template = set.template
	if not template then
		return nil
	end
	if pool.cloneWorks ~= false then
		local ok, clone = pcall(function()
			return template:Clone()
		end)
		if ok and clone then
			if pool.cloneWorks == nil then
				local same = pcall(function()
					assert(((clone :: SurfaceAppearance).ColorMapContent.Object :: any) == set.color)
				end)
				pool.cloneWorks = same
			end
			if pool.cloneWorks then
				return clone :: SurfaceAppearance
			end
			(clone :: SurfaceAppearance):Destroy()
		else
			pool.cloneWorks = false
		end
	end
	local ok, sa = pcall(function()
		return AssetService:CreateSurfaceAppearanceAsync({
			ColorMap = Content.fromObject(set.color),
			NormalMap = Content.fromObject(set.normal :: EditableImage),
			RoughnessMap = Content.fromObject(set.rough :: EditableImage),
		})
	end)
	return if ok then sa else nil
end

local function uvOf(pool: Pool, uvs: { number }, v: number): Vector2
	local u, w = uvs[v * 2 + 1], uvs[v * 2 + 2]
	return Vector2.new(u, if pool.flipV then 1 - w else w)
end

-- Builds one mesh part carrying slots [first, first + count) of `set`. Yields between the
-- heavy calls. Returns nil and the reason when the engine refuses.
local function buildChunk(pool: Pool, set: Set, first: number, count: number): (Chunk?, string?)
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		return nil, "CreateEditableMesh returned nil (editable memory budget)"
	end
	local P = Layout.PIN_EXTENT
	local nV = count * VS + 6
	local positions: { Vector3 } = table.create(nV, Vector3.zero)
	local uvList: { Vector2 } = table.create(nV, Vector2.zero)
	local normals: { Vector3 } = table.create(nV, Vector3.yAxis)
	for k = 0, count - 1 do
		local tx, ty = Layout.tileOf(first + k)
		local uvs = TileGen.uvs(tx, ty)
		local base = k * VS
		for v = 0, VS - 1 do
			positions[base + v + 1] = pool.park[v + 1]
			uvList[base + v + 1] = uvOf(pool, uvs, v)
		end
	end
	local pins = { Vector3.new(P, P, P), Vector3.new(P - 0.01, P, P), Vector3.new(P, P - 0.01, P), Vector3.new(-P, -P, -P), Vector3.new(-P + 0.01, -P, -P), Vector3.new(-P, -P + 0.01, -P) }
	for k = 1, 6 do
		positions[count * VS + k] = pins[k]
	end
	local tris = pool.tris
	local vIds: { number } = {}
	local uvIds: { number } = {}
	local nIds: { number } = {}
	local ok, err = pcall(function()
		vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, positions) :: { number }
		task.wait()
		uvIds = mesh:BatchAdd(Enum.MeshAttribute.UV, uvList) :: { number }
		nIds = mesh:BatchAdd(Enum.MeshAttribute.Normal, normals) :: { number }
		task.wait()
		local T = count * TS + 2
		local faces = table.create(T)
		local faceUV = table.create(T)
		local faceN = table.create(T)
		local n = 0
		for k = 0, count - 1 do
			local base = k * VS
			for t = 0, TS - 1 do
				local a, b, c = base + tris[t * 3 + 1] + 1, base + tris[t * 3 + 2] + 1, base + tris[t * 3 + 3] + 1
				n += 1
				faces[n] = { vIds[a], vIds[b], vIds[c] }
				faceUV[n] = { uvIds[a], uvIds[b], uvIds[c] }
				faceN[n] = { nIds[a], nIds[b], nIds[c] }
			end
			if k % 32 == 31 then
				task.wait()
			end
		end
		local pb = count * VS
		for _, tri in { { 1, 2, 3 }, { 4, 5, 6 } } do
			n += 1
			faces[n] = { vIds[pb + tri[1]], vIds[pb + tri[2]], vIds[pb + tri[3]] }
			faceUV[n] = { uvIds[pb + tri[1]], uvIds[pb + tri[2]], uvIds[pb + tri[3]] }
			faceN[n] = { nIds[pb + tri[1]], nIds[pb + tri[2]], nIds[pb + tri[3]] }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, faces) :: { number }
		task.wait()
		mesh:BatchSetFaceAttributes(fIds, faceUV)
		mesh:BatchSetFaceAttributes(fIds, faceN)
	end)
	if not ok then
		mesh:Destroy()
		return nil, "mesh build with " .. count .. " slots: " .. tostring(err)
	end
	local partOk, partOrErr = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if not partOk or not partOrErr then
		mesh:Destroy()
		return nil, "CreateMeshPartAsync with " .. count .. " slots: " .. tostring(partOrErr)
	end
	local part = partOrErr :: MeshPart
	part.Name = string.format("Surface_%d_%d", set.index, first)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.new(1, 1, 1)
	part.Transparency = 1
	part.Locked = true
	local sa: SurfaceAppearance? = nil
	if pool.mode == "pbr" then
		sa = surfaceFor(pool, set)
		if sa then
			sa.Parent = part
		end
	end
	if not sa then
		pcall(function()
			part.TextureContent = Content.fromObject(set.color)
		end)
	end
	part.Parent = pool.folder
	local chunk: Chunk = { set = set, mesh = mesh, part = part, sa = sa, first = first, count = count, uvIds = uvIds }
	table.insert(set.chunks, chunk)
	table.insert(pool.chunks, chunk)
	for k = 0, count - 1 do
		local tile = first + k
		local tx, ty = Layout.tileOf(tile)
		local slotV: { number } = table.create(VS)
		local slotN: { number } = table.create(VS)
		table.move(vIds, k * VS + 1, k * VS + VS, 1, slotV)
		table.move(nIds, k * VS + 1, k * VS + VS, 1, slotN)
		table.insert(pool.slots, {
			index = #pool.slots,
			set = set,
			chunk = chunk,
			tile = tile,
			tx = tx,
			ty = ty,
			vIds = slotV,
			nIds = slotN,
			key = nil,
			state = "free",
			lastUsed = 0,
			ticket = 0,
			result = nil,
			final = nil,
			finalN = nil,
			morph = nil,
		})
	end
	pool.stats.created += 1
	pool.stats.meshVerts += nV
	return chunk, nil
end

-- Adds an atlas set: three images, the SurfaceAppearance template, and the meshes of its
-- 256 slots (one mesh, or fewer slots per mesh if the engine refuses). Yields. Returns
-- false and the reason when nothing could be added.
function MeshPool.addSet(pool: Pool): (boolean, string?)
	local index = #pool.sets + 1
	local color, err = createImage(Layout.ATLAS, Layout.ATLAS)
	if not color then
		return false, "set " .. index .. " colour atlas: " .. tostring(err)
	end
	local normal = createImage(Layout.ATLAS, Layout.ATLAS)
	local rough = createImage(Layout.ROUGH_ATLAS, Layout.ROUGH_ATLAS)
	local U = pool.U
	local set: Set = {
		index = index,
		color = color,
		normal = normal,
		rough = rough,
		colorEntry = Uploader.register(U, string.format("colour atlas %d", index), color),
		normalEntry = if normal then Uploader.register(U, string.format("normal atlas %d", index), normal) else nil,
		roughEntry = if rough then Uploader.register(U, string.format("roughness atlas %d", index), rough) else nil,
		template = nil,
		chunks = {},
	}
	pool.stats.pixels += Layout.ATLAS * Layout.ATLAS + (if normal then Layout.ATLAS * Layout.ATLAS else 0) + (if rough then Layout.ROUGH_ATLAS * Layout.ROUGH_ATLAS else 0)
	if index == 1 then
		if normal and rough then
			local ok, sa = pcall(function()
				return AssetService:CreateSurfaceAppearanceAsync({
					ColorMap = Content.fromObject(color),
					NormalMap = Content.fromObject(normal),
					RoughnessMap = Content.fromObject(rough),
				})
			end)
			if ok and sa then
				set.template = sa
				pool.mode = "pbr"
				pool.note = "colour + normal + roughness maps (CreateSurfaceAppearanceAsync)"
			else
				pool.note = "CreateSurfaceAppearanceAsync refused (" .. tostring(sa) .. "); colour only via TextureContent"
			end
		else
			pool.note = "normal/roughness atlases refused by the memory budget; colour only"
		end
	elseif pool.mode == "pbr" then
		if normal and rough then
			local ok, sa = pcall(function()
				return AssetService:CreateSurfaceAppearanceAsync({
					ColorMap = Content.fromObject(color),
					NormalMap = Content.fromObject(normal),
					RoughnessMap = Content.fromObject(rough),
				})
			end)
			if ok and sa then
				set.template = sa
			end
		end
		if not set.template then
			-- a later set without its normal maps cannot match the first: do not add it
			color:Destroy()
			if normal then
				normal:Destroy()
			end
			if rough then
				rough:Destroy()
			end
			Uploader.unregister(U, set.colorEntry)
			if set.normalEntry then
				Uploader.unregister(U, set.normalEntry :: Uploader.Entry)
			end
			if set.roughEntry then
				Uploader.unregister(U, set.roughEntry :: Uploader.Entry)
			end
			pool.stats.pixels -= Layout.ATLAS * Layout.ATLAS * 2 + Layout.ROUGH_ATLAS * Layout.ROUGH_ATLAS
			return false, "set " .. index .. ": the memory budget refused its normal or roughness atlas"
		end
	end
	-- meshes: all slots in one, halving on refusal
	table.insert(pool.sets, set)
	local per = pool.slotsPerMesh
	local first = 0
	while first < Layout.SLOTS do
		local count = math.min(per, Layout.SLOTS - first)
		local chunk, why = buildChunk(pool, set, first, count)
		if chunk then
			first += count
		else
			pool.meshMode = string.format("%d slots per mesh (a larger mesh was refused: %s)", math.max(8, per // 2), string.sub(tostring(why), 1, 80))
			if per <= 8 then
				pool.failed = why
				break
			end
			per //= 2
			pool.slotsPerMesh = per
		end
	end
	if first == 0 then
		table.remove(pool.sets)
		return false, tostring(pool.failed)
	end
	pool.maxSlots = #pool.slots
	if per == Layout.SLOTS or first >= Layout.SLOTS and #set.chunks == 1 then
		pool.meshMode = string.format("one mesh per set (%d vertices)", Layout.SLOTS * VS)
	end
	return true, nil
end

----------------------------------------------------------------------------------------
-- slot geometry
----------------------------------------------------------------------------------------

-- Final positions and normals of the patch a slot holds, as Vector3 arrays (cached).
function MeshPool.finals(slot: Slot): ({ Vector3 }, { Vector3 })
	local f, fn = slot.final, slot.finalN
	if f and fn then
		return f, fn
	end
	local r = slot.result
	local pb, nb = r.positions, r.normals
	local pos: { Vector3 } = table.create(VS)
	local nrm: { Vector3 } = table.create(VS)
	for v = 0, VS - 1 do
		local o = v * 12
		pos[v + 1] = Vector3.new(buffer.readf32(pb, o), buffer.readf32(pb, o + 4), buffer.readf32(pb, o + 8))
		nrm[v + 1] = Vector3.new(buffer.readf32(nb, o), buffer.readf32(nb, o + 4), buffer.readf32(nb, o + 8))
	end
	slot.final, slot.finalN = pos, nrm
	return pos, nrm
end

local function writeValues(mesh: EditableMesh, ids: { number }, values: { Vector3 }, setter: string)
	local ok = pcall(function()
		mesh:BatchSetValues(ids, values)
	end)
	if not ok then
		for i = 1, #ids do
			if setter == "pos" then
				mesh:SetPosition(ids[i], values[i])
			else
				mesh:SetNormal(ids[i], values[i])
			end
		end
	end
end

-- Hands a generated patch to a slot: queues its three atlas tiles and keeps the buffers.
-- The mesh is not touched until the slot is shown. `onReady` runs once every atlas holding
-- the patch has been refreshed.
function MeshPool.assign(pool: Pool, slot: Slot, result: any, onReady: () -> ())
	slot.key = result.key
	slot.state = "uploading"
	slot.result = result
	slot.final, slot.finalN = nil, nil
	slot.morph = nil
	local set = slot.set
	local T, RT = Layout.TILE, Layout.ROUGH_TILE
	local waiting = 1
	local function done()
		waiting -= 1
		if waiting == 0 then
			onReady()
		end
	end
	if pool.mode == "pbr" and set.normalEntry and set.roughEntry then
		waiting = 3
		Uploader.queue(pool.U, set.normalEntry :: Uploader.Entry, slot.tx * T, slot.ty * T, T, T, result.normal, done)
		Uploader.queue(pool.U, set.roughEntry :: Uploader.Entry, slot.tx * RT, slot.ty * RT, RT, RT, result.rough, done)
	end
	Uploader.queue(pool.U, set.colorEntry, slot.tx * T, slot.ty * T, T, T, result.color, done)
	pool.stats.writes += 1
end

-- Shows the patch a slot holds. With `start` (a Vector3 array of its vertices' starting
-- positions) the vertices begin there and slide to their final positions (geomorph): the
-- new patch appears exactly on the surface that was displayed, and refines into itself.
function MeshPool.show(pool: Pool, slot: Slot, start: { Vector3 }?)
	local t0 = os.clock()
	local pos, nrm = MeshPool.finals(slot)
	local mesh = slot.chunk.mesh
	writeValues(mesh, slot.nIds, nrm, "nrm")
	if start then
		writeValues(mesh, slot.vIds, start, "pos")
		slot.morph = { t = 0, start = start, final = pos }
	else
		writeValues(mesh, slot.vIds, pos, "pos")
		slot.morph = nil
	end
	slot.state = "shown"
	pool.stats.meshMs += (os.clock() - t0) * 1000
end

-- Advances a slot's geomorph by dt / seconds. Returns true while it is still morphing.
function MeshPool.stepMorph(slot: Slot, dt: number, seconds: number): boolean
	local m = slot.morph
	if not m then
		return false
	end
	m.t += dt / seconds
	local mesh = slot.chunk.mesh
	if m.t >= 1 then
		writeValues(mesh, slot.vIds, m.final, "pos")
		slot.morph = nil
		return false
	end
	local e = m.t * m.t * (3 - 2 * m.t)
	local out: { Vector3 } = table.create(VS)
	local a, b = m.start, m.final
	for i = 1, VS do
		out[i] = a[i]:Lerp(b[i], e)
	end
	writeValues(mesh, slot.vIds, out, "pos")
	return true
end

-- Hides a slot's patch: its vertices go back to the parking cluster at the body's centre.
function MeshPool.park(pool: Pool, slot: Slot)
	slot.morph = nil
	writeValues(slot.chunk.mesh, slot.vIds, pool.park, "pos")
end

-- Frees a slot's held patch (the slot must be parked or never shown).
function MeshPool.clear(slot: Slot)
	slot.result, slot.final, slot.finalN, slot.morph = nil, nil, nil, nil
end

-- Starting positions for a new child patch (quadrant qx, qy of its parent, whose generated
-- result is `parent`): the parent's displayed surface, bilinear between its grid vertices
-- (skirt vertices follow their grid neighbours down).
function MeshPool.startFromParent(parent: any, qx: number, qy: number, skirt: number): { Vector3 }
	local G = Layout.GRID
	local pb = parent.positions
	local function grid(i: number, j: number): (number, number, number)
		local o = (j * (G + 1) + i) * 12
		return buffer.readf32(pb, o), buffer.readf32(pb, o + 4), buffer.readf32(pb, o + 8)
	end
	local out: { Vector3 } = table.create(VS)
	local function at(vi: number, vj: number): Vector3
		local u = (qx * G + vi) / 2
		local w = (qy * G + vj) / 2
		local i0 = math.min(math.floor(u), G - 1)
		local j0 = math.min(math.floor(w), G - 1)
		local fx, fy = u - i0, w - j0
		local x00, y00, z00 = grid(i0, j0)
		local x10, y10, z10 = grid(i0 + 1, j0)
		local x01, y01, z01 = grid(i0, j0 + 1)
		local x11, y11, z11 = grid(i0 + 1, j0 + 1)
		local ax, ay, az = x00 + (x10 - x00) * fx, y00 + (y10 - y00) * fx, z00 + (z10 - z00) * fx
		local bx, by, bz = x01 + (x11 - x01) * fx, y01 + (y11 - y01) * fx, z01 + (z11 - z01) * fx
		return Vector3.new(ax + (bx - ax) * fy, ay + (by - ay) * fy, az + (bz - az) * fy)
	end
	for vj = 0, G do
		for vi = 0, G do
			out[vj * (G + 1) + vi + 1] = at(vi, vj)
		end
	end
	-- skirts: bottom, right, top, left (the order TileGen writes), each one skirt depth below
	-- its grid neighbour along the radial direction
	local base = Layout.GRID_VERTS
	local function drop(p: Vector3): Vector3
		local m = p.Magnitude
		return if m > 1e-6 then p * ((m - skirt) / m) else p
	end
	for vi = 0, G do
		out[base + vi + 1] = drop(out[vi + 1])
	end
	for vj = 0, G do
		out[base + (G + 1) + vj + 1] = drop(out[vj * (G + 1) + G + 1])
	end
	for vi = 0, G do
		out[base + 2 * (G + 1) + vi + 1] = drop(out[G * (G + 1) + vi + 1])
	end
	for vj = 0, G do
		out[base + 3 * (G + 1) + vj + 1] = drop(out[vj * (G + 1) + 1])
	end
	return out
end

-- Starting positions for a coarser parent patch that replaces its children: each of its
-- vertices begins exactly on the child vertex at the same place (a coarse grid is a
-- subsample of the fine one). `children` maps quadrant index (qy * 2 + qx) to the child's
-- generated result; missing children leave their quadrant at the parent's own position.
function MeshPool.startFromChildren(parentFinal: { Vector3 }, children: { [number]: any }): { Vector3 }
	local G = Layout.GRID
	local out: { Vector3 } = table.clone(parentFinal)
	for vj = 0, G do
		for vi = 0, G do
			-- the child quadrant containing this vertex (vertices on the middle line use the
			-- lower-index child: same position in both)
			local qx = if vi * 2 > G then 1 else 0
			local qy = if vj * 2 > G then 1 else 0
			local child = children[qy * 2 + qx]
			if child then
				local ci, cj = 2 * vi - qx * G, 2 * vj - qy * G
				local o = (cj * (G + 1) + ci) * 12
				local pb = child.positions
				out[vj * (G + 1) + vi + 1] = Vector3.new(buffer.readf32(pb, o), buffer.readf32(pb, o + 4), buffer.readf32(pb, o + 8))
			end
		end
	end
	-- skirts follow: parent skirts stay as generated (they are below the surface anyway)
	return out
end

-- Flips the V coordinate of every vertex's UV (for an engine whose UV origin is the
-- bottom-left corner). Tile contents stay; only the mapping changes.
function MeshPool.setFlipV(pool: Pool, flip: boolean)
	if pool.flipV == flip then
		return
	end
	pool.flipV = flip
	for _, chunk in pool.chunks do
		local nV = chunk.count * VS + 6
		local list: { Vector2 } = table.create(nV, Vector2.zero)
		for k = 0, chunk.count - 1 do
			local tx, ty = Layout.tileOf(chunk.first + k)
			local uvs = TileGen.uvs(tx, ty)
			for v = 0, VS - 1 do
				list[k * VS + v + 1] = uvOf(pool, uvs, v)
			end
		end
		local ok = pcall(function()
			chunk.mesh:BatchSetValues(chunk.uvIds, list)
		end)
		if not ok then
			for i = 1, nV do
				pcall(function()
					chunk.mesh:SetUV(chunk.uvIds[i], list[i])
				end)
			end
		end
		task.wait()
	end
end

-- Whole-surface opacity (crossfade with the impostor).
function MeshPool.setOpacity(pool: Pool, opacity: number)
	local tr = 1 - opacity
	for _, chunk in pool.chunks do
		if chunk.part.Transparency ~= tr then
			chunk.part.Transparency = tr
		end
	end
end

-- Places every part at the body's centre (all vertices are body-local).
function MeshPool.place(pool: Pool, center: Vector3)
	local cf = CFrame.new(center)
	for _, chunk in pool.chunks do
		chunk.part.CFrame = cf
	end
end

return MeshPool
