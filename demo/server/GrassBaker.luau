--!strict
-- Universe at Home: Meadow :: GrassBaker (server)
--
-- "Static ones are baked" (docs/DEMO.md section 3, Budget): the ring-1 shell masks
-- and the four ring-0 variant meshes never change, so the server generates them
-- (native codegen; masks in the server Actors) and bakes them. Clients then use them
-- with zero editable budget:
--   ReplicatedStorage.DemoBaked.ShellMasks.L01..L12   Decals whose TextureContent is
--                                                     the baked mask
--   ReplicatedStorage.DemoBaked.GrassVariants.A/A2/B/C MeshParts with baked meshes
-- Clients that find nothing here build both themselves.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local GrassGen = require(Demo:WaitForChild("GrassGen"))
local GrassMesh = require(Demo:WaitForChild("GrassMesh"))
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))
local Status = require(Demo:WaitForChild("Status"))
local Bake = require(script.Parent:WaitForChild("Bake"))

local GrassBaker = {}

GrassBaker.keep = {} :: { any }

local function bakedFolder(name: string): Folder
	local root = ReplicatedStorage:FindFirstChild("DemoBaked")
	if not root then
		local f = Instance.new("Folder")
		f.Name = "DemoBaked"
		f.Parent = ReplicatedStorage
		root = f
	end
	assert(root)
	local existing = root:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	-- not parented yet: clients wait for the folder, so it appears complete
	return f
end

function GrassBaker.masks(reg: Status.Registry, pool: WorkerPool.Pool): (Status.State, string)
	local g = Config.grass
	local K = g.shellCount
	local size = g.shellTexture
	local folder = bakedFolder("ShellMasks")
	local pending = K
	local results: { buffer? } = table.create(K)
	local how = "?"
	local t0 = os.clock()
	for k = 1, K do
		WorkerPool.submit(pool, "shellMask", {
			k = k - 1,
			layers = K,
			size = size,
			seed = 3,
			count = g.shellBlades,
			radius = g.shellBladeRadius,
			lean = g.shellLeanPx,
		}, function(ok: boolean, res: any)
			pending -= 1
			if ok and type(res) == "table" then
				results[res.k + 1] = res.pixels
				how = res.how
			end
		end)
	end
	while pending > 0 and os.clock() - t0 < 120 do
		task.wait(0.05)
	end
	local renderSeconds = os.clock() - t0
	for k = 1, K do
		local px = results[k]
		if not px then
			return "fallback", string.format("mask %d not rendered; clients render their own", k)
		end
		local content, img, why = Bake.pixels(size, size, px)
		if not content then
			if img then
				img:Destroy()
			end
			return "fallback", "masks not baked (" .. tostring(why) .. "); clients render their own"
		end
		table.insert(GrassBaker.keep, img)
		local d = Instance.new("Decal")
		d.Name = string.format("L%02d", k)
		d.TextureContent = content
		d.Parent = folder
	end
	folder.Parent = ReplicatedStorage:FindFirstChild("DemoBaked")
	return "ok", string.format("%d masks %dx%d (%s) rendered in %.1f s, baked", K, size, size, how, renderSeconds)
end

function GrassBaker.variants(reg: Status.Registry): (Status.State, string)
	local folder = bakedFolder("GrassVariants")
	local tris = 0
	for v, spec in GrassGen.VARIANTS do
		local patch = GrassGen.patch(GrassGen.variantOptions(Config.grass, v, 1))
		local built, why = GrassMesh.buildPatch(AssetService, patch :: any, GrassGen.PALETTE, GrassGen.NORMALS)
		if not built then
			return "fallback", "variant " .. spec.name .. " not built (" .. tostring(why) .. "); clients build their own"
		end
		local content, bwhy = Bake.object(built.mesh)
		if not content then
			built.mesh:Destroy()
			return "fallback", "variant meshes not baked (" .. tostring(bwhy) .. "); clients build their own"
		end
		table.insert(GrassBaker.keep, built.mesh)
		local part = GrassMesh.makePart(AssetService, content, spec.name, true)
		part.Transparency = 1
		part.Parent = folder
		tris += patch.triangleCount
		task.wait()
	end
	folder.Parent = ReplicatedStorage:FindFirstChild("DemoBaked")
	return "ok", string.format("4 variant meshes baked (%d triangles in total)", tris)
end

return GrassBaker
