--!strict
-- Universe at Home: Meadow :: GrassMesh
--
-- Engine half of the grass: turns GrassGen arrays into EditableMeshes and MeshParts.
-- Used by the client (ring 0 interactive patches, ring 1 sheet, density tests) and by
-- the server (variants baked with CreateDataModelContentAsync). Serial phase only:
-- every EditableMesh call is Unsafe in the API dump.
--
-- Placement rule. How a MeshPart positions an EditableMesh (local origin at the part
-- or bounding-box centre at the part) is NOT PUBLICLY SPECIFIED, so every mesh built
-- here has its bounding box centred on its local origin: both conventions then agree.
-- Patches are shifted by their bounding-box centre `offset` (place the part at
-- worldCFrame * CFrame.new(offset)); the sheet carries two degenerate triangles at
-- fixed heights so its box never moves when its vertex heights change.
--
-- Mesh calls use the batch API (BatchAdd, BatchSetFaceAttributes, BatchSetValues) and
-- fall back to per-element calls (AddVertex, AddTriangle, SetFaceColors) if a batch
-- call throws.

local GrassMesh = {}

export type PatchArrays = {
	positions: { number },
	tris: { number },
	colorIndex: { number },
	normalIndex: { number },
	vertexCount: number,
	triangleCount: number,
}

export type BuiltPatch = {
	mesh: EditableMesh,
	offset: Vector3,
	vertexIds: { number },
	mode: string,
}

local function bboxCenter(positions: { number }): Vector3
	local x0, y0, z0 = math.huge, math.huge, math.huge
	local x1, y1, z1 = -math.huge, -math.huge, -math.huge
	for i = 1, #positions, 3 do
		local x, y, z = positions[i], positions[i + 1], positions[i + 2]
		if x < x0 then
			x0 = x
		end
		if x > x1 then
			x1 = x
		end
		if y < y0 then
			y0 = y
		end
		if y > y1 then
			y1 = y
		end
		if z < z0 then
			z0 = z
		end
		if z > z1 then
			z1 = z
		end
	end
	return Vector3.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
end
GrassMesh.bboxCenter = bboxCenter

-- Builds an EditableMesh from patch arrays. palette: { {r, g, b} } (0..1); normals:
-- { {x, y, z} }. Returns nil (and a reason) if the budget refuses a mesh.
function GrassMesh.buildPatch(assetService: AssetService, p: PatchArrays, palette: { { number } }, normals: { { number } }): (BuiltPatch?, string?)
	local mesh = assetService:CreateEditableMesh()
	if not mesh then
		return nil, "CreateEditableMesh returned nil (editable budget)"
	end
	local offset = bboxCenter(p.positions)
	local ox, oy, oz = offset.X, offset.Y, offset.Z
	local n = p.vertexCount
	local pos = table.create(n)
	for i = 1, n do
		local o = 3 * i - 2
		pos[i] = Vector3.new(p.positions[o] - ox, p.positions[o + 1] - oy, p.positions[o + 2] - oz)
	end
	local mode = "batch"
	local vIds: { number } = {}
	local ok, err = pcall(function()
		vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, pos) :: { number }
		local faces = table.create(p.triangleCount)
		for t = 1, p.triangleCount do
			local o = 3 * t - 2
			faces[t] = { vIds[p.tris[o]], vIds[p.tris[o + 1]], vIds[p.tris[o + 2]] }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, faces) :: { number }
		-- colours and normals from small palettes, assigned per face corner
		local colorIds = table.create(#palette)
		for i, c in palette do
			colorIds[i] = mesh:AddColor(Color3.new(c[1], c[2], c[3]), 1)
		end
		local normalIds = table.create(#normals)
		for i, v in normals do
			normalIds[i] = mesh:AddNormal(Vector3.new(v[1], v[2], v[3]))
		end
		local faceColors = table.create(p.triangleCount)
		local faceNormals = table.create(p.triangleCount)
		for t = 1, p.triangleCount do
			local o = 3 * t - 2
			local a, b, c = p.tris[o], p.tris[o + 1], p.tris[o + 2]
			faceColors[t] = { colorIds[p.colorIndex[a]], colorIds[p.colorIndex[b]], colorIds[p.colorIndex[c]] }
			faceNormals[t] = { normalIds[p.normalIndex[a]], normalIds[p.normalIndex[b]], normalIds[p.normalIndex[c]] }
		end
		mesh:BatchSetFaceAttributes(fIds, faceColors)
		mesh:BatchSetFaceAttributes(fIds, faceNormals)
		mesh:RemoveUnused()
	end)
	if not ok then
		-- per-element fallback on a fresh mesh
		mode = "per-element (batch failed: " .. tostring(err) .. ")"
		mesh:Destroy()
		local m2 = assetService:CreateEditableMesh()
		if not m2 then
			return nil, "CreateEditableMesh returned nil on retry"
		end
		mesh = m2
		vIds = table.create(n)
		for i = 1, n do
			vIds[i] = m2:AddVertex(pos[i])
		end
		local colorIds = table.create(#palette)
		for i, c in palette do
			colorIds[i] = m2:AddColor(Color3.new(c[1], c[2], c[3]), 1)
		end
		for t = 1, p.triangleCount do
			local o = 3 * t - 2
			local a, b, c = p.tris[o], p.tris[o + 1], p.tris[o + 2]
			local f = m2:AddTriangle(vIds[a], vIds[b], vIds[c])
			m2:SetFaceColors(f, { colorIds[p.colorIndex[a]], colorIds[p.colorIndex[b]], colorIds[p.colorIndex[c]] })
		end
		m2:RemoveUnused()
	end
	return { mesh = mesh, offset = offset, vertexIds = vIds, mode = mode }, nil
end

-- Moves vertices (interaction): positions flat xyz in patch space; offset from build.
function GrassMesh.setPositions(b: BuiltPatch, positions: { number })
	local n = #b.vertexIds
	local values = table.create(n)
	local ox, oy, oz = b.offset.X, b.offset.Y, b.offset.Z
	for i = 1, n do
		local o = 3 * i - 2
		values[i] = Vector3.new(positions[o] - ox, positions[o + 1] - oy, positions[o + 2] - oz)
	end
	local ok = pcall(function()
		b.mesh:BatchSetValues(b.vertexIds, values)
	end)
	if not ok then
		for i = 1, n do
			b.mesh:SetPosition(b.vertexIds[i], values[i])
		end
	end
end

export type SheetArrays = {
	n: number,
	vx: { number },
	vz: { number },
	alpha: { number },
	quads: { number },
	quadCount: number,
}

export type BuiltSheet = {
	mesh: EditableMesh,
	vertexIds: { number },
	extent: number, -- pins at +-extent in X and Z
	yRange: number, -- pins at +-yRange in Y
	partY: number, -- world Y of the MeshPart; vertex Y = world height - partY
	mode: string,
}

-- The ring 1 sheet, world-anchored: its MeshPart never moves (CFrame.new(0, partY, 0)
-- plus the wind sway) and re-centring only rewrites vertex positions, so heights and
-- placement can never be out of step for a frame. UVs 0..1 per quad (one mask repeat
-- per quad, no reliance on texture wrapping), white vertex colours whose alpha carries
-- the ring crossfades, and two degenerate triangles at (+-extent, +-yRange, +-extent)
-- that pin the bounding box (centred on the local origin, see the placement rule).
function GrassMesh.buildSheet(assetService: AssetService, s: SheetArrays, extent: number, yRange: number, partY: number): (BuiltSheet?, string?)
	local mesh = assetService:CreateEditableMesh()
	if not mesh then
		return nil, "CreateEditableMesh returned nil (editable budget)"
	end
	local count = s.n * s.n
	local pos = table.create(count)
	for i = 1, count do
		pos[i] = Vector3.new(s.vx[i], 0, s.vz[i])
	end
	local vIds: { number } = {}
	local mode = "batch"
	local ok, err = pcall(function()
		vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, pos) :: { number }
		local faces = table.create(s.quadCount * 2)
		for q = 1, s.quadCount do
			local o = 4 * q - 3
			local a, b, c, d = vIds[s.quads[o]], vIds[s.quads[o + 1]], vIds[s.quads[o + 2]], vIds[s.quads[o + 3]]
			faces[2 * q - 1] = { a, d, b } -- counter-clockwise seen from above (+Y)
			faces[2 * q] = { a, c, d }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, faces) :: { number }
		local uv00 = mesh:AddUV(Vector2.new(0, 0))
		local uv10 = mesh:AddUV(Vector2.new(1, 0))
		local uv01 = mesh:AddUV(Vector2.new(0, 1))
		local uv11 = mesh:AddUV(Vector2.new(1, 1))
		local faceUVs = table.create(s.quadCount * 2)
		for q = 1, s.quadCount do
			faceUVs[2 * q - 1] = { uv00, uv11, uv10 }
			faceUVs[2 * q] = { uv00, uv01, uv11 }
		end
		mesh:BatchSetFaceAttributes(fIds, faceUVs)
		-- alpha quantised to 33 levels
		local levels = table.create(33)
		for l = 0, 32 do
			levels[l + 1] = mesh:AddColor(Color3.new(1, 1, 1), l / 32)
		end
		local function colorOf(v: number): number
			return levels[math.floor(s.alpha[v] * 32 + 0.5) + 1]
		end
		local faceColors = table.create(s.quadCount * 2)
		for q = 1, s.quadCount do
			local o = 4 * q - 3
			local a, b, c, d = s.quads[o], s.quads[o + 1], s.quads[o + 2], s.quads[o + 3]
			faceColors[2 * q - 1] = { colorOf(a), colorOf(d), colorOf(b) }
			faceColors[2 * q] = { colorOf(a), colorOf(c), colorOf(d) }
		end
		mesh:BatchSetFaceAttributes(fIds, faceColors)
	end)
	if not ok then
		mesh:Destroy()
		return nil, "sheet batch build failed: " .. tostring(err)
	end
	-- bounding-box pins (zero-area triangles)
	local pinOk = pcall(function()
		local lo = mesh:AddVertex(Vector3.new(-extent, -yRange, -extent))
		local lo2 = mesh:AddVertex(Vector3.new(-extent, -yRange, -extent + 0.001))
		local hi = mesh:AddVertex(Vector3.new(extent, yRange, extent))
		local hi2 = mesh:AddVertex(Vector3.new(extent, yRange, extent - 0.001))
		mesh:AddTriangle(lo, lo2, lo)
		mesh:AddTriangle(hi, hi2, hi)
	end)
	if not pinOk then
		mode = "batch, no bounding-box pins"
	end
	return { mesh = mesh, vertexIds = vIds, extent = extent, yRange = yRange, partY = partY, mode = mode }, nil
end

-- heights: f32 buffer of absolute world heights, one per sheet vertex; (cx, cz) the
-- world position of the sheet's centre vertex.
function GrassMesh.setSheetHeights(b: BuiltSheet, s: SheetArrays, heights: buffer, cx: number, cz: number)
	local count = s.n * s.n
	local values = table.create(count)
	local lo, hi = -b.yRange + 0.5, b.yRange - 0.5
	for i = 1, count do
		local h = buffer.readf32(heights, (i - 1) * 4) - b.partY
		if h ~= h then
			h = lo
		elseif h > hi then
			h = hi
		elseif h < lo then
			h = lo
		end
		values[i] = Vector3.new(cx + s.vx[i], h, cz + s.vz[i])
	end
	local ok = pcall(function()
		b.mesh:BatchSetValues(b.vertexIds, values)
	end)
	if not ok then
		for i = 1, count do
			b.mesh:SetPosition(b.vertexIds[i], values[i])
		end
	end
end

-- A MeshPart showing `mesh`, configured as decoration (anchored, no collision, no
-- queries, no touch, no shadow). Yields (CreateMeshPartAsync).
function GrassMesh.makePart(assetService: AssetService, content: Content, name: string, doubleSided: boolean): MeshPart
	local part = assetService:CreateMeshPartAsync(content, {
		CollisionFidelity = Enum.CollisionFidelity.Box,
		RenderFidelity = Enum.RenderFidelity.Precise,
	})
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.new(1, 1, 1)
	part.DoubleSided = doubleSided
	part.Locked = true
	return part
end

return GrassMesh
