--!strict
-- Universe at Home: Planets :: MeshPool
--
-- The GPU side of the patch system: three atlases and up to 256 pooled patch meshes.
--
-- ATLASES. Colour (1024 x 1024), normal (1024 x 1024) and roughness (512 x 512)
-- EditableImages; slot i owns tile i of each (Layout). One SurfaceAppearance per slot,
-- built by AssetService:CreateSurfaceAppearanceAsync from the three atlases: the only way a
-- game script gets normal and roughness maps on a mesh (their properties are plugin-only).
-- Its maps cannot be swapped, but the EditableImages behind them can be rewritten, which
-- is all the pool ever does. If the engine refuses, the pool falls back to
-- MeshPart.TextureContent (colour only; lighting from the sphere normals) and says so.
--
-- SLOTS. Each slot is an EditableMesh with the fixed patch topology (TileGen.triangles,
-- per-vertex UVs into its own tile, per-vertex normals) shown by a MeshPart. Assigning a
-- patch rewrites the vertex positions and normals; nothing is created or destroyed while
-- flying. All vertices are body-local and two zero-area triangles pin the bounding box to
-- +-PIN_EXTENT on every axis, so the box is centred on the body whichever origin rule the
-- engine uses and never changes size (no rescaling when vertices move): every part simply
-- sits at the body's centre.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Layout = require(Planets:WaitForChild("Layout")) :: any
local TileGen = require(Planets:WaitForChild("TileGen")) :: any
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local MeshPool = {}

export type Slot = {
	index: number, -- 0-based, = atlas tile
	tx: number,
	ty: number,
	mesh: EditableMesh,
	part: MeshPart,
	sa: SurfaceAppearance?,
	vIds: { number },
	nIds: { number },
	uvIds: { number },
	key: number?, -- patch currently held
	state: string, -- "free" | "generating" | "uploading" | "ready" | "shown"
	lastUsed: number,
	ticket: number, -- increments on every (re)assignment; stale job results are dropped
}

export type Pool = {
	color: EditableImage,
	normal: EditableImage?,
	rough: EditableImage?,
	colorEntry: Uploader.Entry,
	normalEntry: Uploader.Entry?,
	roughEntry: Uploader.Entry?,
	mode: string, -- "pbr" | "texture"
	note: string,
	slots: { Slot },
	folder: Folder,
	flipV: boolean,
	template: SurfaceAppearance?,
	cloneWorks: boolean?,
	tris: { number },
	growing: boolean,
	failed: string?,
	meshMode: string,
	stats: { created: number, writes: number, meshMs: number, pixels: number },
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

-- Creates the atlases. Returns nil and a reason when even the colour atlas cannot exist.
function MeshPool.new(U: Uploader.Uploader, folder: Folder): (Pool?, string?)
	local color, err = createImage(Layout.ATLAS, Layout.ATLAS)
	if not color then
		return nil, "colour atlas: " .. tostring(err)
	end
	local normal = createImage(Layout.ATLAS, Layout.ATLAS)
	local rough = createImage(Layout.ROUGH_ATLAS, Layout.ROUGH_ATLAS)
	local pool: Pool = {
		color = color,
		normal = normal,
		rough = rough,
		colorEntry = Uploader.register(U, "colour atlas", color),
		normalEntry = if normal then Uploader.register(U, "normal atlas", normal) else nil,
		roughEntry = if rough then Uploader.register(U, "roughness atlas", rough) else nil,
		mode = "texture",
		note = "not decided yet",
		slots = {},
		folder = folder,
		flipV = false,
		template = nil,
		cloneWorks = nil,
		tris = TileGen.triangles(),
		growing = false,
		failed = nil,
		meshMode = "batch",
		stats = { created = 0, writes = 0, meshMs = 0, pixels = Layout.ATLAS * Layout.ATLAS + (if normal then Layout.ATLAS * Layout.ATLAS else 0) + (if rough then Layout.ROUGH_ATLAS * Layout.ROUGH_ATLAS else 0) },
	}
	-- decide the surface path once: PBR maps through CreateSurfaceAppearanceAsync, or colour only
	if normal and rough then
		local ok, sa = pcall(function()
			return AssetService:CreateSurfaceAppearanceAsync({
				ColorMap = Content.fromObject(color),
				NormalMap = Content.fromObject(normal),
				RoughnessMap = Content.fromObject(rough),
			})
		end)
		if ok and sa then
			pool.template = sa
			pool.mode = "pbr"
			pool.note = "colour + normal + roughness maps (CreateSurfaceAppearanceAsync)"
		else
			pool.note = "CreateSurfaceAppearanceAsync refused (" .. tostring(sa) .. "); colour only via TextureContent"
		end
	else
		pool.note = "normal/roughness atlases refused by the memory budget; colour only"
	end
	return pool, nil
end

-- One SurfaceAppearance per slot: a clone of the template when cloning keeps the maps,
-- else a fresh CreateSurfaceAppearanceAsync call.
local function surfaceFor(pool: Pool): SurfaceAppearance?
	local template = pool.template
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
					assert(((clone :: SurfaceAppearance).ColorMapContent.Object :: any) == pool.color)
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
			ColorMap = Content.fromObject(pool.color),
			NormalMap = Content.fromObject(pool.normal :: EditableImage),
			RoughnessMap = Content.fromObject(pool.rough :: EditableImage),
		})
	end)
	return if ok then sa else nil
end

local function uvVector(pool: Pool, uvs: { number }, v: number): Vector2
	local u, w = uvs[v * 2 + 1], uvs[v * 2 + 2]
	return Vector2.new(u, if pool.flipV then 1 - w else w)
end

-- Builds one slot (yields: CreateMeshPartAsync). Returns nil and a reason on failure.
local function newSlot(pool: Pool, index: number): (Slot?, string?)
	local tx, ty = Layout.tileOf(index)
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		return nil, "CreateEditableMesh returned nil (editable memory budget)"
	end
	local V = Layout.VERTS
	local G = Layout.GRID
	local P = Layout.PIN_EXTENT
	-- initial geometry: a small flat grid (no zero-area triangles except the pins)
	local positions = table.create(V, Vector3.zero)
	local normals = table.create(V, Vector3.yAxis)
	for v = 0, Layout.GRID_VERTS + Layout.SKIRT_VERTS - 1 do
		local g = if v < Layout.GRID_VERTS then v else v % (G + 1)
		positions[v + 1] = Vector3.new(g % (G + 1), (g // (G + 1)) * 0.5 + (if v < Layout.GRID_VERTS then 0 else -1), g // (G + 1))
	end
	local pins = { Vector3.new(P, P, P), Vector3.new(P - 0.01, P, P), Vector3.new(P, P - 0.01, P), Vector3.new(-P, -P, -P), Vector3.new(-P + 0.01, -P, -P), Vector3.new(-P, -P + 0.01, -P) }
	for k = 1, 6 do
		positions[V - 6 + k] = pins[k]
	end
	local uvs = TileGen.uvs(tx, ty)
	local uvList = table.create(V, Vector2.zero)
	for v = 0, V - 1 do
		uvList[v + 1] = uvVector(pool, uvs, v)
	end
	local tris = pool.tris
	local T = #tris // 3
	local vIds: { number } = {}
	local nIds: { number } = {}
	local uvIds: { number } = {}
	local ok, err = pcall(function()
		vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, positions) :: { number }
		uvIds = mesh:BatchAdd(Enum.MeshAttribute.UV, uvList) :: { number }
		nIds = mesh:BatchAdd(Enum.MeshAttribute.Normal, normals) :: { number }
		local faces = table.create(T)
		local faceUV = table.create(T)
		local faceN = table.create(T)
		for t = 0, T - 1 do
			local a, b, c = tris[t * 3 + 1] + 1, tris[t * 3 + 2] + 1, tris[t * 3 + 3] + 1
			faces[t + 1] = { vIds[a], vIds[b], vIds[c] }
			faceUV[t + 1] = { uvIds[a], uvIds[b], uvIds[c] }
			faceN[t + 1] = { nIds[a], nIds[b], nIds[c] }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, faces) :: { number }
		mesh:BatchSetFaceAttributes(fIds, faceUV)
		mesh:BatchSetFaceAttributes(fIds, faceN)
	end)
	if not ok then
		-- per-element fallback on a fresh mesh
		pool.meshMode = "per-element (batch failed: " .. tostring(err) .. ")"
		mesh:Destroy()
		local m2 = AssetService:CreateEditableMesh()
		if not m2 then
			return nil, "CreateEditableMesh returned nil on retry"
		end
		mesh = m2
		vIds, nIds, uvIds = table.create(V), table.create(V), table.create(V)
		for v = 1, V do
			vIds[v] = m2:AddVertex(positions[v])
			uvIds[v] = m2:AddUV(uvList[v])
			nIds[v] = m2:AddNormal(normals[v])
		end
		for t = 0, T - 1 do
			local a, b, c = tris[t * 3 + 1] + 1, tris[t * 3 + 2] + 1, tris[t * 3 + 3] + 1
			local f = m2:AddTriangle(vIds[a], vIds[b], vIds[c])
			m2:SetFaceUVs(f, { uvIds[a], uvIds[b], uvIds[c] })
			m2:SetFaceNormals(f, { nIds[a], nIds[b], nIds[c] })
		end
	end
	local partOk, partOrErr = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if not partOk or not partOrErr then
		mesh:Destroy()
		return nil, "CreateMeshPartAsync: " .. tostring(partOrErr)
	end
	local part = partOrErr :: MeshPart
	part.Name = "Patch" .. index
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
		sa = surfaceFor(pool)
		if sa then
			sa.Parent = part
		end
	end
	if not sa then
		pcall(function()
			part.TextureContent = Content.fromObject(pool.color)
		end)
	end
	part.Parent = pool.folder
	pool.stats.created += 1
	return {
		index = index,
		tx = tx,
		ty = ty,
		mesh = mesh,
		part = part,
		sa = sa,
		vIds = vIds,
		nIds = nIds,
		uvIds = uvIds,
		key = nil,
		state = "free",
		lastUsed = 0,
		ticket = 0,
	},
		nil
end

-- Grows the pool by up to `count` slots (yields). Returns the number created.
function MeshPool.grow(pool: Pool, count: number): number
	local made = 0
	while made < count and #pool.slots < Layout.SLOTS do
		local slot, err = newSlot(pool, #pool.slots)
		if not slot then
			pool.failed = err
			break
		end
		table.insert(pool.slots, slot)
		made += 1
	end
	return made
end

-- Writes a generated patch into a slot: three tile uploads (queued) and the mesh (now).
-- `onReady` runs once every atlas holding the patch has been refreshed.
function MeshPool.assign(pool: Pool, U: Uploader.Uploader, slot: Slot, result: any, onReady: () -> ())
	local t0 = os.clock()
	slot.key = result.key
	slot.state = "uploading"
	local T, RT = Layout.TILE, Layout.ROUGH_TILE
	local waiting = 1
	local function done()
		waiting -= 1
		if waiting == 0 then
			onReady()
		end
	end
	if pool.mode == "pbr" and pool.normalEntry and pool.roughEntry then
		waiting = 3
		Uploader.queue(U, pool.normalEntry :: Uploader.Entry, slot.tx * T, slot.ty * T, T, T, result.normal, done)
		Uploader.queue(U, pool.roughEntry :: Uploader.Entry, slot.tx * RT, slot.ty * RT, RT, RT, result.rough, done)
	end
	Uploader.queue(U, pool.colorEntry, slot.tx * T, slot.ty * T, T, T, result.color, done)
	-- the mesh: positions and normals from the f32 buffers
	local V = Layout.VERTS
	local pb, nb = result.positions, result.normals
	local pos = table.create(V, Vector3.zero)
	local nrm = table.create(V, Vector3.yAxis)
	for v = 0, V - 1 do
		local o = v * 12
		pos[v + 1] = Vector3.new(buffer.readf32(pb, o), buffer.readf32(pb, o + 4), buffer.readf32(pb, o + 8))
		nrm[v + 1] = Vector3.new(buffer.readf32(nb, o), buffer.readf32(nb, o + 4), buffer.readf32(nb, o + 8))
	end
	local mesh = slot.mesh
	local ok = pcall(function()
		mesh:BatchSetValues(slot.vIds, pos)
	end)
	if not ok then
		for v = 1, V do
			mesh:SetPosition(slot.vIds[v], pos[v])
		end
	end
	ok = pcall(function()
		mesh:BatchSetValues(slot.nIds, nrm)
	end)
	if not ok then
		for v = 1, V do
			mesh:SetNormal(slot.nIds[v], nrm[v])
		end
	end
	pool.stats.writes += 1
	pool.stats.meshMs += (os.clock() - t0) * 1000
end

-- Flips the V coordinate of every slot's UVs (for an engine whose UV origin is the
-- bottom-left corner). Tile contents stay; only the mapping changes.
function MeshPool.setFlipV(pool: Pool, flip: boolean)
	if pool.flipV == flip then
		return
	end
	pool.flipV = flip
	for _, slot in pool.slots do
		local uvs = TileGen.uvs(slot.tx, slot.ty)
		local V = Layout.VERTS
		local list = table.create(V, Vector2.zero)
		for v = 0, V - 1 do
			list[v + 1] = uvVector(pool, uvs, v)
		end
		local ok = pcall(function()
			slot.mesh:BatchSetValues(slot.uvIds, list)
		end)
		if not ok then
			for v = 1, V do
				pcall(function()
					slot.mesh:SetUV(slot.uvIds[v], list[v])
				end)
			end
		end
	end
end

-- Debug tint of a slot's surface (SurfaceAppearance.Color multiplies the colour map).
function MeshPool.tint(slot: Slot, color: Color3)
	local sa = slot.sa
	if sa then
		pcall(function()
			sa.Color = color
		end)
	else
		slot.part.Color = color
	end
end

return MeshPool
