--!strict
-- Universe at Home: Meadow :: Grass (client)
--
-- Three rings around the player (docs/DEMO.md section 3):
--   ring 0  (0 to 24 studs)   blade geometry: 4 x 4 stud patches drawn from four shared
--                             variant meshes (full density A and A2, 60 percent B, 30
--                             percent C), each patch a MeshPart placed on the terrain's
--                             local plane with a random quarter turn. Variant geometry
--                             comes from GrassGen in the grass Actors; meshes are the
--                             server's baked variants when available (zero client
--                             editable budget), else client EditableMeshes. Level per
--                             patch from Saturn's selector with hysteresis, switches by
--                             Saturn's two-phase crossfade; the patch under the player
--                             is swapped for an interactive EditableMesh whose blades bend
--                             away from the player.
--   ring 1  (24 to 96 studs)  shell grass: one terrain-following sheet (an EditableMesh
--                             re-fitted by raycasts in a grass Actor) shown by 12 MeshParts
--                             stacked 0.1 stud apart, each textured with the alpha mask of
--                             its height (blade cross-sections, rendered by the flawless
--                             rasterizer; baked on the server, or rendered by the client
--                             render Actors). Vertex alpha fades the sheet in at 24 and out
--                             at 96 with the same two-phase rule, so no ring edge pops.
--   ring 2  (beyond 96)       engine Terrain decoration grass (set in the place file).
-- Wind: one Actor computes every patch tilt and shell sway in parallel and applies them
-- with Workspace:BulkMoveTo after task.synchronize().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local GrassGen = require(Demo:WaitForChild("GrassGen"))
local GrassMesh = require(Demo:WaitForChild("GrassMesh"))

-- Ring 1 sheet placement (GrassMesh.buildSheet): the MeshPart never moves, it sits at
-- (0, SHEET_PART_Y, 0); vertices carry world X and Z and heights relative to SHEET_PART_Y.
-- The bounding-box pins must cover the whole world (1024 studs) plus the sheet half-width,
-- and the vertical range the terrain (heights 6..256) plus the shell stack on top of it.
local SHEET_PART_Y = 128
local SHEET_Y_RANGE = 150
local SHEET_EXTENT = 640
local Rings = require(Demo:WaitForChild("Rings"))
local WorkerPool = require(Demo:WaitForChild("WorkerPool"))
local Status = require(Demo:WaitForChild("Status"))
local MyMath = require(ReplicatedStorage:WaitForChild("Universe"):WaitForChild("MyMath"))

local Grass = {}

type Slot = {
	key: number,
	sx: number,
	sz: number,
	ground: CFrame,
	ok: boolean,
	pick: number, -- level-0 variant index (1 = A, 2 = A2)
	lod: Rings.Lod,
	parts: { MeshPart? },
	partVariant: { number },
	d: number,
}

type State = {
	ctx: { [string]: any },
	cfg: any,
	folder: Folder,
	patches: { GrassGen.Patch },
	offsets: { Vector3 },
	templates: { MeshPart },
	free: { { MeshPart } },
	triangles: { number },
	slots: { [number]: Slot },
	interactive: { { part: MeshPart, built: GrassMesh.BuiltPatch }? },
	interactSlot: number?,
	interactPos: Vector3?,
	bendOut: { number },
	shellParts: { MeshPart },
	sheet: GrassGen.Sheet?,
	sheetBuilt: GrassMesh.BuiltSheet?,
	sheetCenter: Vector3?,
	sheetPending: boolean,
	sheetStamp: number,
	windDirty: boolean,
	windLast: number,
	windParams: { [string]: any },
	ring0: boolean,
	ring1: boolean,
	params: RaycastParams,
}

local function key(sx: number, sz: number): number
	return (sx + 32768) * 65536 + (sz + 32768)
end

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	local r = character:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then
		return r
	end
	return nil
end

-- Variant index for a level (0, 1, 2) at a slot.
local function variantFor(level: number, pick: number): number
	if level == 0 then
		return pick
	end
	return level + 2
end

local function acquire(st: State, v: number): MeshPart
	local list = st.free[v]
	local p = table.remove(list)
	if p then
		return p
	end
	local c = st.templates[v]:Clone()
	c.Parent = st.folder
	return c
end

local function release(st: State, v: number, part: MeshPart)
	part.Transparency = 1
	part.CFrame = CFrame.new(0, -2000, 0)
	table.insert(st.free[v], part)
end

-- Terrain plane under a slot: 5 raycasts; grass only on Grass and LeafyGrass.
local function fitSlot(st: State, sx: number, sz: number): (boolean, CFrame)
	local S = st.cfg.patch
	local cx, cz = (sx + 0.5) * S, (sz + 0.5) * S
	local down = Vector3.new(0, -600, 0)
	local function h(x: number, z: number): (number?, Enum.Material?)
		local hit = Workspace:Raycast(Vector3.new(x, 400, z), down, st.params)
		if hit then
			return hit.Position.Y, hit.Material
		end
		return nil, nil
	end
	local hc, mc = h(cx, cz)
	local hx1 = h(cx + 1.6, cz)
	local hx0 = h(cx - 1.6, cz)
	local hz1 = h(cx, cz + 1.6)
	local hz0 = h(cx, cz - 1.6)
	if not hc or not hx1 or not hx0 or not hz1 or not hz0 then
		return false, CFrame.new()
	end
	if mc ~= Enum.Material.Grass and mc ~= Enum.Material.LeafyGrass then
		return false, CFrame.new()
	end
	local up = Vector3.new(-(hx1 - hx0) / 3.2, 1, -(hz1 - hz0) / 3.2).Unit
	if up.Y < 0.8 then
		return false, CFrame.new() -- too steep for a rigid patch
	end
	local turn = (MyMath.hash2(sx, sz, 31) % 4) / 4
	local r = Vector3.new(MyMath.dcosTurns(turn), 0, MyMath.dsinTurns(turn))
	r = (r - up * r:Dot(up)).Unit
	return true, CFrame.fromMatrix(Vector3.new(cx, hc, cz), r, up)
end

local function newSlot(st: State, sx: number, sz: number, d: number): Slot
	local ok, ground = fitSlot(st, sx, sz)
	local g = st.cfg
	return {
		key = key(sx, sz),
		sx = sx,
		sz = sz,
		ground = ground,
		ok = ok,
		pick = (MyMath.hash2(sx, sz, 57) % 2) + 1,
		lod = Rings.lod({ g.lodNear, g.lodFar }, g.hysteresis, g.fadeSeconds, d),
		parts = { nil, nil },
		partVariant = { 0, 0 },
		d = d,
	}
end

local function dropSlot(st: State, s: Slot)
	for i = 1, 2 do
		local p = s.parts[i]
		if p then
			release(st, s.partVariant[i], p)
			s.parts[i] = nil
		end
	end
	st.windDirty = true
end

-- Applies one slot's LOD crossfade and ring-boundary fade.
local function updateSlot(st: State, s: Slot, now: number)
	local l1, t1, l2, t2 = Rings.lodStep(s.lod, s.d, now)
	local ringOpacity = Rings.boundary(s.d, st.cfg.ring0, st.cfg.fadeWidth)
	local levels = { l1, l2 }
	local trans = { t1, t2 }
	for i = 1, 2 do
		local level = levels[i]
		local want = if level >= 0 then variantFor(level, s.pick) else 0
		local part = s.parts[i]
		if part and s.partVariant[i] ~= want then
			release(st, s.partVariant[i], part)
			s.parts[i] = nil
			part = nil
			st.windDirty = true
		end
		if want > 0 and not part then
			local p = acquire(st, want)
			p.CFrame = s.ground * CFrame.new(st.offsets[want])
			s.parts[i] = p
			s.partVariant[i] = want
			part = p
			st.windDirty = true
		end
		if part then
			local opacity = (1 - trans[i]) * ringOpacity
			local t = 1 - opacity
			if st.interactSlot == s.key and want <= 2 then
				t = 1 -- the interactive copy stands in for this patch
			end
			if math.abs(part.Transparency - t) > 0.004 then
				part.Transparency = t
			end
		end
	end
end

local function sendWind(st: State)
	local parts: { BasePart } = {}
	local base: { CFrame } = {}
	local kind: { number } = {}
	local offsets: { Vector3 } = {}
	for _, s in st.slots do
		for i = 1, 2 do
			local p = s.parts[i]
			if p and p.Transparency < 1 then
				table.insert(parts, p)
				table.insert(base, s.ground)
				table.insert(offsets, st.offsets[s.partVariant[i]])
				table.insert(kind, 0)
			end
		end
	end
	if st.interactSlot then
		local s = st.slots[st.interactSlot]
		local it = s and st.interactive[s.pick]
		if s and it then
			table.insert(parts, it.part)
			table.insert(base, s.ground)
			table.insert(offsets, it.built.offset)
			table.insert(kind, 0)
		end
	end
	local center = st.sheetCenter
	if center then
		local K = #st.shellParts
		local g = st.cfg
		for k, p in st.shellParts do
			table.insert(parts, p)
			table.insert(base, CFrame.new(0, SHEET_PART_Y, 0))
			table.insert(offsets, Vector3.new(0, 0.14 + (k - 1) / math.max(1, K - 1) * g.shellHeight, 0))
			table.insert(kind, k)
		end
	end
	-- the wind job wants final base CFrames; fold the offsets in for shells, keep the
	-- ground pivot for patches by passing ground * offset with the pivot correction
	local finalBase: { CFrame } = table.create(#parts)
	for i = 1, #parts do
		if kind[i] == 0 then
			finalBase[i] = base[i] * CFrame.new(offsets[i])
		else
			finalBase[i] = base[i] + offsets[i]
		end
	end
	local pools = st.ctx.pools
	local wind = pools and pools.wind
	if wind and wind.available then
		WorkerPool.submit(wind, "windSet", { parts = parts, base = finalBase, kind = kind, params = st.windParams })
	else
		st.windParams.serialParts = parts
		st.windParams.serialBase = finalBase
		st.windParams.serialKind = kind
	end
	st.windDirty = false
	st.windLast = os.clock()
end

-- Serial wind for the no-Actor fallback (same formulas as ClientJobs.windSet).
local function serialWind(st: State)
	local w = st.windParams
	local parts = w.serialParts :: { BasePart }?
	if not parts or #parts == 0 then
		return
	end
	local base = w.serialBase :: { CFrame }
	local kind = w.serialKind :: { number }
	local t = os.clock()
	local out = table.create(#parts)
	for i = 1, #parts do
		local cf = base[i]
		local pos = cf.Position
		local phase = (pos.X * w.dirX + pos.Z * w.dirZ) / w.wavelength - t * w.speed
		local g = 0.55 + 0.35 * math.sin(phase * 6.283185307179586) + 0.12 * math.sin(phase * 14.45 + 1.7)
		if kind[i] == 0 then
			local axis = cf:VectorToObjectSpace(Vector3.new(-w.dirZ, 0, w.dirX))
			out[i] = cf * CFrame.fromAxisAngle(axis, w.strength * g)
		else
			local f = kind[i] / w.layers
			local s = w.shellAmp * f * f * g
			out[i] = cf + Vector3.new(w.dirX * s, 0, w.dirZ * s)
		end
	end
	pcall(function()
		Workspace:BulkMoveTo(parts, out, Enum.BulkMoveMode.FireCFrameChanged)
	end)
end

local function requestSheet(st: State, p: Vector3)
	local sheet = st.sheet
	local pools = st.ctx.pools
	if not sheet or st.sheetPending then
		return
	end
	local spacing = sheet.spacing
	local cx = math.floor(p.X / spacing + 0.5) * spacing
	local cz = math.floor(p.Z / spacing + 0.5) * spacing
	local baseY = math.floor(p.Y + 0.5)
	st.sheetPending = true
	st.sheetStamp += 1
	local payload = { cx = cx, cz = cz, baseY = baseY, top = baseY + 200, n = sheet.n, half = sheet.half, spacing = spacing, stamp = st.sheetStamp }
	local pool = pools and pools.grass
	local function apply(ok: boolean, res: any)
		st.sheetPending = false
		local built = st.sheetBuilt
		if not ok or type(res) ~= "table" or not built then
			return
		end
		GrassMesh.setSheetHeights(built, sheet, res.heights, res.cx, res.cz)
		st.sheetCenter = Vector3.new(res.cx, res.baseY, res.cz)
		st.windDirty = true
		for _, part in st.shellParts do
			part.CFrame = CFrame.new(0, SHEET_PART_Y, 0)
		end
	end
	if pool then
		WorkerPool.submit(pool, "sheetHeights", payload, apply)
	end
end

local function interaction(st: State, root: BasePart, now: number)
	local S = st.cfg.patch
	local p = root.Position
	local sx, sz = math.floor(p.X / S), math.floor(p.Z / S)
	local k = key(sx, sz)
	local s = st.slots[k]
	local current = st.interactSlot
	local eligible = s ~= nil and s.ok and s.lod.t0 < 0 and (s.partVariant[1] == s.pick or s.partVariant[2] == s.pick) and st.interactive[s.pick] ~= nil
	if not eligible then
		if current then
			local old = st.slots[current]
			if old then
				local it = st.interactive[old.pick]
				if it then
					it.part.Transparency = 1
				end
			end
			st.interactSlot = nil
			st.windDirty = true
		end
		return
	end
	assert(s)
	local it = st.interactive[s.pick]
	assert(it)
	if current ~= k then
		if current then
			local old = st.slots[current]
			if old then
				local oit = st.interactive[old.pick]
				if oit and oit ~= it then
					oit.part.Transparency = 1
				end
			end
		end
		st.interactSlot = k
		st.interactPos = nil
		it.part.CFrame = s.ground * CFrame.new(it.built.offset)
		it.part.Transparency = 0
		st.windDirty = true
	end
	-- bend: only when the player moved, at most every other frame (time slice)
	local lp = s.ground:PointToObjectSpace(p)
	local last = st.interactPos
	if last and (last - lp).Magnitude < 0.12 then
		return
	end
	st.interactPos = lp
	local patch = st.patches[s.pick]
	local bent = GrassGen.bend(patch, lp.X, lp.Z, st.cfg.interactRadius, 0.85, st.bendOut)
	GrassMesh.setPositions(it.built, st.bendOut)
	st.ctx.lastBend = bent
end

local function frame(st: State)
	local root = rootPart()
	if not root then
		return
	end
	local now = os.clock()
	local p = root.Position
	local g = st.cfg
	local S = g.patch
	if st.ring0 then
		local reach = g.ring0 + 2
		local sx0, sx1 = math.floor((p.X - reach) / S), math.floor((p.X + reach) / S)
		local sz0, sz1 = math.floor((p.Z - reach) / S), math.floor((p.Z + reach) / S)
		local created = 0
		for sz = sz0, sz1 do
			for sx = sx0, sx1 do
				local cx, cz = (sx + 0.5) * S - p.X, (sz + 0.5) * S - p.Z
				local d = math.sqrt(cx * cx + cz * cz)
				if d < reach then
					local k = key(sx, sz)
					local s = st.slots[k]
					if not s and created < 24 then
						s = newSlot(st, sx, sz, d)
						st.slots[k] = s
						created += 1
					end
					if s then
						s.d = d
					end
				end
			end
		end
		local tris = 0
		for k, s in st.slots do
			local cx, cz = (s.sx + 0.5) * S - p.X, (s.sz + 0.5) * S - p.Z
			s.d = math.sqrt(cx * cx + cz * cz)
			if s.d > reach + 3 then
				dropSlot(st, s)
				st.slots[k] = nil
			elseif s.ok then
				updateSlot(st, s, now)
				for i = 1, 2 do
					if s.parts[i] and (s.parts[i] :: MeshPart).Transparency < 1 then
						tris += st.triangles[s.partVariant[i]]
					end
				end
			end
		end
		interaction(st, root, now)
		st.ctx.counters.grassTriangles = tris + (if st.ring1 then (st.sheet :: GrassGen.Sheet).quadCount * 2 * #st.shellParts else 0)
	end
	if st.ring1 then
		local c = st.sheetCenter
		local dx = if c then p.X - c.X else math.huge
		local dz = if c then p.Z - c.Z else math.huge
		if not c or dx * dx + dz * dz > 64 or math.abs(p.Y - c.Y) > 30 then
			requestSheet(st, p)
		end
	end
	if st.windDirty and now - st.windLast > 0.12 then
		sendWind(st)
	end
	local pools = st.ctx.pools
	if not (pools and pools.wind and pools.wind.available) then
		serialWind(st)
	end
end

----------------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------------

local function bakedFolder(name: string, wait: number): Instance?
	local baked = ReplicatedStorage:WaitForChild("DemoBaked", wait)
	if not baked then
		return nil
	end
	return baked:WaitForChild(name, wait)
end

local function buildVariants(st: State, reg: any): (boolean, string)
	local g = st.cfg
	local pools = st.ctx.pools
	local n = #GrassGen.VARIANTS
	local results: { GrassGen.Patch? } = table.create(n)
	local pending = n
	for v = 1, n do
		local opts = GrassGen.variantOptions(g, v, 1)
		local function done(ok: boolean, res: any)
			if ok and type(res) == "table" then
				results[v] = res
			else
				results[v] = GrassGen.patch(opts)
			end
			pending -= 1
		end
		if pools and pools.grass then
			WorkerPool.submit(pools.grass, "grassPatch", opts, done)
		else
			done(false, nil)
		end
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < 30 do
		task.wait(0.05)
	end
	for v = 1, n do
		local r = results[v]
		if not r then
			return false, "variant geometry missing"
		end
		st.patches[v] = r
		st.offsets[v] = GrassMesh.bboxCenter(r.positions)
		st.triangles[v] = r.triangleCount
	end
	-- meshes: the server's baked variants (no client editable budget), else client meshes
	local source = "client EditableMesh"
	local baked = bakedFolder("GrassVariants", 10)
	local usedBaked = false
	if baked then
		local all = true
		for v, spec in GrassGen.VARIANTS do
			local m = baked:FindFirstChild(spec.name)
			if m and m:IsA("MeshPart") then
				local c = m:Clone()
				c.Anchored = true
				c.CanCollide = false
				c.CanQuery = false
				c.CanTouch = false
				c.CastShadow = false
				c.Transparency = 1
				st.templates[v] = c
			else
				all = false
			end
		end
		usedBaked = all
		if all then
			source = "server-baked meshes (no client editable budget)"
		end
	end
	if not usedBaked then
		for v = 1, n do
			local built, why = GrassMesh.buildPatch(AssetService, st.patches[v] :: any, GrassGen.PALETTE, GrassGen.NORMALS)
			if not built then
				return false, "variant " .. GrassGen.VARIANTS[v].name .. ": " .. tostring(why)
			end
			st.ctx.counters.editableMeshes += 1
			local part = GrassMesh.makePart(AssetService, Content.fromObject(built.mesh), "Variant" .. GrassGen.VARIANTS[v].name, true)
			part.Transparency = 1
			st.templates[v] = part
		end
	end
	for v = 1, n do
		st.free[v] = {}
	end
	-- interactive copies of the two full-density variants
	local interactNote = "interaction on"
	for v = 1, 2 do
		local ok, err = pcall(function()
			local built, why = GrassMesh.buildPatch(AssetService, st.patches[v] :: any, GrassGen.PALETTE, GrassGen.NORMALS)
			if not built then
				error(why)
			end
			st.ctx.counters.editableMeshes += 1
			local part = GrassMesh.makePart(AssetService, Content.fromObject(built.mesh), "Interactive" .. v, true)
			part.Transparency = 1
			part.Parent = st.folder
			st.interactive[v] = { part = part, built = built }
		end)
		if not ok then
			interactNote = "interaction off: " .. tostring(err)
		end
	end
	Status.set(reg, "grass_interaction", if st.interactive[1] then "ok" else "fallback", interactNote)
	return true, string.format("%s; %d + %d + %d + %d triangles per patch variant", source, st.triangles[1], st.triangles[2], st.triangles[3], st.triangles[4])
end

local function buildShells(st: State, reg: any): (boolean, string)
	local g = st.cfg
	local K = g.shellCount
	local sheet = GrassGen.sheet(g.ring0, g.ring1, g.shellRepeat, g.fadeWidth, g.fadeWidth + 4)
	st.sheet = sheet
	local built, why = GrassMesh.buildSheet(AssetService, sheet :: any, SHEET_EXTENT, SHEET_Y_RANGE, SHEET_PART_Y)
	if not built then
		return false, tostring(why)
	end
	st.sheetBuilt = built
	st.ctx.counters.editableMeshes += 1
	-- masks: baked by the server, else rendered by the render Actors
	local contents: { Content? } = table.create(K)
	local source = ""
	local baked = bakedFolder("ShellMasks", 12)
	if baked then
		local all = true
		for k = 1, K do
			local d = baked:FindFirstChild(string.format("L%02d", k))
			if d and d:IsA("Decal") then
				contents[k] = d.TextureContent
			else
				all = false
			end
		end
		if all then
			source = "server-baked masks"
		end
	end
	if source == "" then
		local pools = st.ctx.pools
		local pending = K
		local how = "?"
		local size = g.shellTexture
		for k = 1, K do
			local payload = {
				k = k - 1,
				layers = K,
				size = size,
				seed = 3,
				count = g.shellBlades,
				radius = g.shellBladeRadius,
				lean = g.shellLeanPx,
			}
			local function done(ok: boolean, res: any)
				pending -= 1
				if not ok or type(res) ~= "table" then
					return
				end
				how = res.how
				local img = AssetService:CreateEditableImage({ Size = Vector2.new(size, size) })
				if not img then
					return
				end
				img:WritePixelsBuffer(Vector2.zero, Vector2.new(size, size), res.pixels)
				st.ctx.counters.editableImages += 1
				st.ctx.counters.editablePixels += size * size
				st.ctx.counters.uploads += 1
				st.ctx.counters.uploadBytes += size * size * 4
				contents[res.k + 1] = Content.fromObject(img)
			end
			if pools and pools.render then
				WorkerPool.submit(pools.render, "shellMask", payload, done)
			else
				pending -= 1
			end
		end
		local t0 = os.clock()
		while pending > 0 and os.clock() - t0 < 60 do
			task.wait(0.05)
		end
		source = "client-rendered masks (" .. how .. ")"
	end
	local first = GrassMesh.makePart(AssetService, Content.fromObject(built.mesh), "Shell01", false)
	local made = 0
	for k = 1, K do
		local c = contents[k]
		if c then
			local part = if k == 1 then first else first:Clone()
			part.Name = string.format("Shell%02d", k)
			part.TextureContent = c
			part.Transparency = 0.001
			part.CFrame = CFrame.new(0, -2000, 0)
			part.Parent = st.folder
			table.insert(st.shellParts, part)
			made += 1
		end
	end
	if made == 0 then
		first:Destroy()
		return false, "no shell mask available"
	end
	return true, string.format("%d layers, %d quads, %s, sheet %s", made, sheet.quadCount, source, built.mode)
end

local function run(ctx: { [string]: any })
	local reg = ctx.reg
	local cfg = ctx.config.grass
	-- wait for a character standing on the generated ground
	local t0 = os.clock()
	while not rootPart() and os.clock() - t0 < 300 do
		task.wait(0.5)
	end
	if not rootPart() then
		Status.set(reg, "grass", "failed", "no character after 300 s")
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "MeadowGrass"
	folder.Parent = Workspace
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true
	local st: State = {
		ctx = ctx,
		cfg = cfg,
		folder = folder,
		patches = {},
		offsets = {},
		templates = {},
		free = {},
		triangles = {},
		slots = {},
		interactive = {},
		interactSlot = nil,
		interactPos = nil,
		bendOut = {},
		shellParts = {},
		sheet = nil,
		sheetBuilt = nil,
		sheetCenter = nil,
		sheetPending = false,
		sheetStamp = 0,
		windDirty = true,
		windLast = 0,
		windParams = {
			dirX = 0.8,
			dirZ = 0.6,
			wavelength = cfg.windWavelength,
			speed = cfg.windSpeed,
			strength = cfg.windStrength * 0.35,
			shellAmp = 0.3,
			layers = cfg.shellCount,
		},
		ring0 = false,
		ring1 = false,
		params = params,
	}
	ctx.grass = st
	Status.set(reg, "grass_crossfade", "info", "LOD and ring fades via " .. Rings.source)
	Status.set(reg, "grass_ring2", "ok", "engine Terrain decoration grass beyond " .. cfg.ring1 .. " studs (place file: Decoration, GrassLength)")
	Status.stage(reg, "grass_ring0", function()
		local ok, detail = buildVariants(st, reg)
		if not ok then
			error(detail)
		end
		st.ring0 = true
		return "ok", detail
	end, function(message: string)
		return "fallback", "ring 0 off, engine grass only"
	end)
	Status.stage(reg, "grass_ring1", function()
		local ok, detail = buildShells(st, reg)
		if not ok then
			error(detail)
		end
		st.ring1 = true
		return "ok", detail
	end, function(message: string)
		return "fallback", "ring 1 off, engine grass only"
	end)
	local pools = ctx.pools
	Status.set(
		reg,
		"grass_wind",
		if pools and pools.wind and pools.wind.available then "ok" else "fallback",
		if pools and pools.wind and pools.wind.available then "wind Actor: parallel CFrames + BulkMoveTo" else "serial wind on the main thread"
	)
	RunService.RenderStepped:Connect(function()
		local res = table.pack(pcall(frame, st))
		if not res[1] then
			st.ctx.grassError = tostring(res[2])
		end
	end)
	Status.set(reg, "grass", "ok", string.format("rings: 0 %s, 1 %s, 2 engine", if st.ring0 then "on" else "off", if st.ring1 then "on" else "off"))
end

function Grass.start(ctx: { [string]: any }): (string, string)
	task.spawn(run, ctx)
	return "pending", "waits for the character, then builds the rings"
end

-- T11: rebuilds the ring-0 variants at a density multiplier with client meshes.
-- Returns triangles per full-density patch.
function Grass.setDensity(ctx: { [string]: any }, mul: number): (boolean, string)
	local st = ctx.grass :: State?
	if not st or not st.ring0 then
		return false, "ring 0 is not running"
	end
	-- release every slot, rebuild templates, let the frame loop repopulate
	for k, s in st.slots do
		dropSlot(st, s)
		st.slots[k] = nil
	end
	for v = 1, #GrassGen.VARIANTS do
		for _, p in st.free[v] do
			p:Destroy()
		end
		st.free[v] = {}
		local patch = GrassGen.patch(GrassGen.variantOptions(st.cfg, v, mul))
		local built, why = GrassMesh.buildPatch(AssetService, patch :: any, GrassGen.PALETTE, GrassGen.NORMALS)
		if not built then
			return false, tostring(why)
		end
		st.ctx.counters.editableMeshes += 1
		local part = GrassMesh.makePart(AssetService, Content.fromObject(built.mesh), "Variant" .. GrassGen.VARIANTS[v].name, true)
		part.Transparency = 1
		st.templates[v] = part
		st.patches[v] = patch
		st.offsets[v] = built.offset
		st.triangles[v] = patch.triangleCount
	end
	return true, string.format("x%d: %d triangles per full-density patch", mul, st.triangles[1])
end

return Grass
