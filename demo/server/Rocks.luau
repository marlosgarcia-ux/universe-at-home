--!strict
-- Universe at Home: Meadow :: Rocks (server)
--
-- Boulders on the slopes around the meadow (docs/DEMO.md section 2): positions picked
-- deterministically from the final heightmap, geometry (noise-displaced icospheres,
-- RockGen) built by the server Actors in parallel, EditableMesh assembled serially,
-- baked with CreateDataModelContentAsync so the mesh replicates as static content and
-- costs clients no editable budget. Fallback per rock: a Terrain:FillBall boulder.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local WorldGen = require(Demo:WaitForChild("WorldGen"))
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))
local Status = require(Demo:WaitForChild("Status"))
local MyMath = require(ReplicatedStorage:WaitForChild("Universe"):WaitForChild("MyMath"))
local Bake = require(script.Parent:WaitForChild("Bake"))

local Rocks = {}

Rocks.keep = {} :: { EditableMesh }

type Spot = { x: number, y: number, z: number, radius: number, seed: number, slope: number }

-- Deterministic rock spots: hashed column order, slope and height rules, spacing.
function Rocks.spots(world: WorldGen.World, heights: buffer, count: number): { Spot }
	local n = world.columns
	local candidates: { { number } } = {}
	local sp = world.cfg.spawn
	for k = 2, n - 3, 2 do
		for i = 2, n - 3, 2 do
			local h = WorldGen.heightAt(world, heights, i, k)
			local s = WorldGen.slopeAt(world, heights, i, k)
			if h > world.waterLevel + 2 and h < world.cfg.snowLine - 20 and s > 0.3 and s < 1.1 then
				local x, z = WorldGen.columnCenter(world, i, k)
				local dx, dz = x - sp.x, z - sp.z
				if dx * dx + dz * dz > 30 * 30 then
					table.insert(candidates, { MyMath.hash2(i, k, 4242), i, k })
				end
			end
		end
	end
	table.sort(candidates, function(a: { number }, b: { number }): boolean
		return a[1] < b[1]
	end)
	local out: { Spot } = {}
	local cfg = Config.rocks
	for _, c in candidates do
		if #out >= count then
			break
		end
		local i, k = c[2], c[3]
		local x, z = WorldGen.columnCenter(world, i, k)
		local far = true
		for _, o in out do
			local dx, dz = o.x - x, o.z - z
			if dx * dx + dz * dz < 26 * 26 then
				far = false
				break
			end
		end
		if far then
			local r = cfg.minRadius + (c[1] % 1000) / 1000 * (cfg.maxRadius - cfg.minRadius)
			table.insert(out, {
				x = x,
				y = WorldGen.heightAt(world, heights, i, k),
				z = z,
				radius = r,
				seed = c[1] % 1000003,
				slope = WorldGen.slopeAt(world, heights, i, k),
			})
		end
	end
	return out
end

-- Builds the rock mesh centred on its bounding box (so the MeshPart placement does
-- not depend on how the engine anchors an EditableMesh) and returns its half height.
local function buildMesh(rock: any): (EditableMesh?, number)
	local mesh = AssetService:CreateEditableMesh()
	if not mesh then
		return nil, 0
	end
	local n = rock.vertexCount
	local pos = table.create(n)
	local p = rock.positions
	local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for v = 1, n do
		local q = Vector3.new(p[3 * v - 2], p[3 * v - 1], p[3 * v])
		lo, hi = lo:Min(q), hi:Max(q)
	end
	local c = (lo + hi) * 0.5
	for v = 1, n do
		pos[v] = Vector3.new(p[3 * v - 2], p[3 * v - 1], p[3 * v]) - c
	end
	local ok = pcall(function()
		local vIds = mesh:BatchAdd(Enum.MeshAttribute.Vertex, pos) :: { number }
		local faces = table.create(rock.triangleCount)
		local tris = rock.triangles
		for t = 1, rock.triangleCount do
			faces[t] = { vIds[tris[3 * t - 2]], vIds[tris[3 * t - 1]], vIds[tris[3 * t]] }
		end
		local fIds = mesh:BatchAdd(Enum.MeshAttribute.Face, faces) :: { number }
		local colorIds = table.create(n)
		local c = rock.colors
		for v = 1, n do
			colorIds[v] = mesh:AddColor(Color3.new(c[3 * v - 2], c[3 * v - 1], c[3 * v]), 1)
		end
		local faceColors = table.create(rock.triangleCount)
		for t = 1, rock.triangleCount do
			faceColors[t] = { colorIds[tris[3 * t - 2]], colorIds[tris[3 * t - 1]], colorIds[tris[3 * t]] }
		end
		mesh:BatchSetFaceAttributes(fIds, faceColors)
		mesh:RemoveUnused()
	end)
	if not ok then
		mesh:Destroy()
		return nil, 0
	end
	return mesh, (hi.Y - lo.Y) * 0.5
end

function Rocks.run(reg: Status.Registry, pool: WorkerPool.Pool, terrain: any): (Status.State, string)
	local cfg = Config.rocks
	local spots = Rocks.spots(terrain.world, terrain.heights, cfg.count)
	local folder = Instance.new("Folder")
	folder.Name = "Rocks"
	folder.Parent = Workspace
	local pending = #spots
	local meshes, filled, failed = 0, 0, 0
	local firstError: string? = nil
	for idx, s in spots do
		WorkerPool.submit(pool, "rock", { seed = s.seed, radius = s.radius, subdivisions = cfg.subdivisions, roughness = cfg.roughness }, function(ok: boolean, rock: any)
			local placed = false
			if ok and type(rock) == "table" then
				local mesh, halfHeight = buildMesh(rock)
				if mesh then
					local content, why = Bake.object(mesh)
					if content then
						local pok, perr = pcall(function()
							local part = AssetService:CreateMeshPartAsync(content, {
								CollisionFidelity = Enum.CollisionFidelity.Hull,
								RenderFidelity = Enum.RenderFidelity.Precise,
							})
							part.Name = string.format("Rock%02d", idx)
							part.Anchored = true
							part.Material = Enum.Material.SmoothPlastic
							part.Color = Color3.new(1, 1, 1)
							part.CastShadow = true
							local yaw = (s.seed % 360) / 360
							-- sink the flat underside a little into the slope
							part.CFrame = CFrame.new(s.x, s.y + halfHeight - 0.25 * halfHeight - 0.4, s.z)
								* CFrame.Angles(0, yaw * 6.283185307179586, 0)
							part.Parent = folder
						end)
						if pok then
							placed = true
							meshes += 1
							table.insert(Rocks.keep, mesh)
						else
							firstError = firstError or tostring(perr)
							mesh:Destroy()
						end
					else
						firstError = firstError or why
						mesh:Destroy()
					end
				else
					firstError = firstError or "CreateEditableMesh or batch build failed"
				end
			else
				firstError = firstError or tostring(rock)
			end
			if not placed then
				local fok = pcall(function()
					Workspace.Terrain:FillBall(Vector3.new(s.x, s.y + s.radius * 0.2, s.z), s.radius * 0.75, Enum.Material.Rock)
				end)
				if fok then
					filled += 1
				else
					failed += 1
				end
			end
			pending -= 1
		end)
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < 120 do
		task.wait(0.05)
	end
	local detail = string.format("%d baked mesh rocks, %d terrain boulders (fallback), %d failed", meshes, filled, failed)
	if firstError then
		detail ..= "; first error: " .. firstError
	end
	if meshes == #spots then
		return "ok", detail
	end
	return "fallback", detail
end

return Rocks
