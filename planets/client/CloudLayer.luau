--!strict
-- Universe at Home: Planets :: CloudLayer
--
-- Terra's clouds as one rotating shell: a cube-sphere of six 16 x 16 grids at 14 studs
-- above sea level, textured from a 1024 x 512 atlas of six 256 px faces (Clouds.face, same
-- texel-centre rule as the surface atlas, so the faces meet without seams). The texture's
-- alpha is the cloud cover; the part is double-sided so the clouds are seen from below.
-- The shell rotates about the planet's axis; the impostor samples the same field rotated
-- by the same angle, so clouds match across the mesh/impostor crossfade.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Layout = require(Planets:WaitForChild("Layout")) :: any
local CubeSphere = require(Planets:WaitForChild("CubeSphere")) :: any
local Clouds = require(Planets:WaitForChild("Clouds")) :: any
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local CloudLayer = {}

export type Layer = {
	img: EditableImage,
	part: MeshPart?,
	radius: number,
	angle: number,
	pixels: number,
	note: string,
}

local SPIN = 0.0035 -- radians per second

function CloudLayer.new(U: Uploader.Uploader, workers: any, folder: Instance, body: any): (Layer?, string?)
	local W, H, T, span = Layout.CLOUD_ATLAS_W, Layout.CLOUD_ATLAS_H, Layout.CLOUD_TILE, Layout.CLOUD_SPAN
	local img, err = MeshPool.createImage(W, H)
	if not img then
		return nil, "cloud atlas: " .. tostring(err)
	end
	local entry = Uploader.register(U, "cloud atlas", img)
	for f = 1, 6 do
		local tx, ty = Clouds.tileOf(f)
		WorkerPool.submit(workers, "cloudFace", { face = f }, function(ok: boolean, buf: any)
			if ok then
				Uploader.queue(U, entry, tx * T, ty * T, T, T, buf)
			end
		end)
	end
	local layer: Layer = { img = img, part = nil, radius = body.radius + 14, angle = 0, pixels = W * H, note = "building" }
	-- the shell mesh
	local G = Layout.CLOUD_GRID
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		layer.note = "CreateEditableMesh returned nil (editable memory budget)"
		return layer, nil
	end
	local positions: { Vector3 } = {}
	local uvs: { Vector2 } = {}
	local faces: { { number } } = {}
	local Rc = layer.radius
	for f = 1, 6 do
		local tx, ty = Clouds.tileOf(f)
		local base = #positions
		for vj = 0, G do
			for vi = 0, G do
				local a, b = vi / G, vj / G
				local x, y, z = CubeSphere.facePoint(f, a, b)
				table.insert(positions, Vector3.new(x, y, z) * Rc)
				table.insert(uvs, Vector2.new((tx * T + Layout.GUTTER + 0.5 + a * span) / W, (ty * T + Layout.GUTTER + 0.5 + b * span) / H))
			end
		end
		for vj = 0, G - 1 do
			for vi = 0, G - 1 do
				local p = base + vj * (G + 1) + vi + 1
				local q, r, s = p + 1, p + G + 2, p + G + 1
				table.insert(faces, { p, q, r })
				table.insert(faces, { p, r, s })
			end
		end
	end
	-- pins centre the bounding box on the planet (see MeshPool)
	local P = Rc + 30
	local pinBase = #positions
	for _, v in { Vector3.new(P, P, P), Vector3.new(P - 0.01, P, P), Vector3.new(P, P - 0.01, P), Vector3.new(-P, -P, -P), Vector3.new(-P + 0.01, -P, -P), Vector3.new(-P, -P + 0.01, -P) } do
		table.insert(positions, v)
		table.insert(uvs, Vector2.new(0, 0))
	end
	table.insert(faces, { pinBase + 1, pinBase + 2, pinBase + 3 })
	table.insert(faces, { pinBase + 4, pinBase + 5, pinBase + 6 })
	local ok, buildErr = pcall(function()
		local vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, positions) :: { number }
		local uvIds = mesh:BatchAdd(Enum.MeshAttribute.UV, uvs) :: { number }
		local fl = table.create(#faces)
		local fu = table.create(#faces)
		for i, fc in faces do
			fl[i] = { vIds[fc[1]], vIds[fc[2]], vIds[fc[3]] }
			fu[i] = { uvIds[fc[1]], uvIds[fc[2]], uvIds[fc[3]] }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, fl) :: { number }
		mesh:BatchSetFaceAttributes(fIds, fu)
	end)
	if not ok then
		-- per-element fallback
		mesh:Destroy()
		local m2 = AssetService:CreateEditableMesh()
		if not m2 then
			layer.note = "cloud mesh: " .. tostring(buildErr)
			return layer, nil
		end
		mesh = m2
		local vIds, uvIds = {}, {}
		for i, p in positions do
			vIds[i] = m2:AddVertex(p)
			uvIds[i] = m2:AddUV(uvs[i])
		end
		for _, fc in faces do
			local id = m2:AddTriangle(vIds[fc[1]], vIds[fc[2]], vIds[fc[3]])
			m2:SetFaceUVs(id, { uvIds[fc[1]], uvIds[fc[2]], uvIds[fc[3]] })
		end
	end
	local partOk, part = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if not partOk or not part then
		layer.note = "cloud part: " .. tostring(part)
		return layer, nil
	end
	local mp = part :: MeshPart
	mp.Name = "Clouds"
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.CastShadow = false
	mp.DoubleSided = true
	mp.Material = Enum.Material.SmoothPlastic
	mp.Color = Color3.new(1, 1, 1)
	mp.Transparency = 1
	mp.TextureContent = Content.fromObject(img)
	mp.CFrame = CFrame.new(body.px, body.py, body.pz)
	mp.Parent = folder
	layer.part = mp
	layer.note = "cloud shell at +14 studs, 1024 x 512 atlas"
	return layer, nil
end

-- Per frame: spin, and fade with the planet's mesh.
function CloudLayer.update(layer: Layer, body: any, dt: number, alpha: number, enabled: boolean)
	layer.angle = (layer.angle + SPIN * dt) % (2 * math.pi)
	local part = layer.part
	if part then
		part.CFrame = CFrame.new(body.px, body.py, body.pz) * CFrame.Angles(0, layer.angle, 0)
		part.Transparency = if enabled then 1 - alpha else 1
	end
end

return CloudLayer
