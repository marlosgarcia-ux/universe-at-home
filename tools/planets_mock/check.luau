
----------------------------------------------------------------------------------------
-- scenario and checks (appended after the wrapped client sources)
----------------------------------------------------------------------------------------

local Quadtree = realRequire("../planets/shared/Quadtree")
local TileGen = realRequire("../planets/shared/TileGen")
local Layout = realRequire("../planets/shared/Layout")
local CubeSphere = realRequire("../planets/shared/CubeSphere")
local Bodies = realRequire("../planets/shared/Bodies")

-- the DataModel as the place builds it
local Universe = makeClass("Folder")
Universe.Name = "Universe"
Universe.Parent = ReplicatedStorage
moduleInstance(Universe, "MyMath", { file = "../src/MyMath" })
local PlanetsF = makeClass("Folder")
PlanetsF.Name = "Planets"
PlanetsF.Parent = ReplicatedStorage
for _, n in { "Config", "Atmos", "Layout", "Noise3", "CubeSphere", "Bodies", "TileGen", "Quadtree", "SphereCache", "Impostor", "SkyGen", "Clouds", "PlanetJobs" } do
	moduleInstance(PlanetsF, n, { file = "../planets/shared/" .. n })
end
moduleInstance(PlanetsF, "WorkerPool", { wrapped = "WorkerPool" })
moduleInstance(PlanetsF, "WorkerMain", { wrapped = "WorkerMain" })
local ClientF = makeClass("Folder")
ClientF.Name = "Client"
ClientF.Parent = playerScripts
for _, n in { "Uploader", "MeshPool", "PlanetLod", "Impostors", "Sky", "CloudLayer", "Flight", "Hud", "Workers" } do
	moduleInstance(ClientF, n, { wrapped = n })
end
local CfgReal = realRequire("../planets/shared/Config")
CfgReal.atlasSets = 1 -- the main flight uses one set (faster); the sets and limits tests build their own pools
local mainScript = makeClass("LocalScript")
mainScript.Name = "Main"
mainScript.Parent = ClientF

local failures = 0
local function check(cond, msg)
	if cond then
		realPrint("ok   " .. msg)
	else
		failures += 1
		realPrint("FAIL " .. msg)
	end
end

local function frame(dt)
	MOCK.frame += 1
	MOCK.time += dt
	RunService.RenderStepped:Fire(dt)
	RunService.Heartbeat:Fire(dt)
	local due = {}
	for i = #waiting, 1, -1 do
		if waiting[i].wake <= MOCK.time then
			table.insert(due, waiting[i])
			table.remove(waiting, i)
		end
	end
	for i = #due, 1, -1 do
		resume(due[i].co, dt)
	end
	local list = deferred
	deferred = {}
	for _, d in list do
		task.spawn(d.fn, table.unpack(d.args, 1, d.args.n))
	end
end

local function run(n)
	for _ = 1, n do
		frame(1 / 60)
	end
end

local function key(code)
	local input = { UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode[code], Position = v3(0, 0, 0), Delta = v3(0, 0, 0) }
	UserInputService.InputBegan:Fire(input, false)
	UserInputService.InputEnded:Fire(input, false)
end

local function statusLine(stage)
	for i = #MOCK.prints, 1, -1 do
		local line = MOCK.prints[i]
		if string.sub(line, 1, 9 + #stage) == "PLANETS|" .. stage .. "|" then
			return line
		end
	end
	return nil
end

-- the LocalScript runs
task.spawn(__defs["Main"], mainScript, mockRequire)
local Hud = mockRequire(ClientF.Hud)
local MeshPool = mockRequire(ClientF.MeshPool)
local D = Hud.debug

-- 1. start-up: workers (serial here: no Actors run in the CLI), every stage, caches
local t0 = os.clock()
for _ = 1, 400 do
	frame(1 / 60)
	if D.ready and D.imps and D.imps.cachesReady == 3 then
		break
	end
end
check(D.ready == true, "setup finished")
for _, stage in { "sky", "atlases", "impostors", "clouds", "sphere caches" } do
	local line = statusLine(stage)
	check(line ~= nil and string.find(line, "|failed|", 1, true) == nil, "stage " .. stage .. ": " .. tostring(line))
end
check(D.pool and D.pool.mode == "pbr", "surface path: PBR maps through CreateSurfaceAppearanceAsync")
run(120)
check(#MOCK.errors == 0, "no errors in threads or handlers so far (" .. #MOCK.errors .. ")")
for _, e in MOCK.errors do
	realPrint("     " .. string.sub(e, 1, 400))
end

-- impostors: every body rendered from orbit, sky faces and clouds written
local imps = D.imps
local camCF = Workspace.CurrentCamera.CFrame
for _, item in imps.items do
	local dir = (v3(item.def.px, item.def.py, item.def.pz) - camCF.Position).Unit
	if dir:Dot(camCF.LookVector) > 0.2 then
		check(item.renders > 0 and item.img.writes > 0, "impostor of " .. item.def.name .. " (in view) rendered (" .. item.renders .. " renders, " .. item.n .. " px)")
	else
		check(item.renders == 0, "impostor of " .. item.def.name .. " (behind the camera) not rendered")
	end
end
local skyWrites, cloudWrites = 0, 0
for _, img in D.sky.faces do
	skyWrites += img.writes
end
cloudWrites = D.clouds.img.writes
check(skyWrites >= 6, "six sky faces written (" .. skyWrites .. ")")
check(cloudWrites >= 6, "six cloud faces written (" .. cloudWrites .. ")")
check(D.lod.body == nil, "from orbit no mesh is active")
-- the atmosphere tables were built (by jobs) and installed for both atmospheric bodies
do
	local AtmosReal = realRequire("../planets/shared/Atmos")
	for _ = 1, 600 do
		if D.imps.atmosReady == 2 then
			break
		end
		frame(1 / 60)
	end
	check(D.imps.atmosReady == 2 and AtmosReal.get("terra") ~= nil and AtmosReal.get("saturnia") ~= nil, "atmosphere tables built and installed for Terra and Saturnia")
	local line = statusLine("atmosphere")
	check(line ~= nil and string.find(line, "|ok|", 1, true) ~= nil, "atmosphere stage reported ok: " .. tostring(line))
end
-- a billboard beyond 1024 is four tile images that appear together
do
	local Impostors = mockRequire(ClientF.Impostors)
	local item = D.imps.byId.selene
	local n = 2048
	local big = buffer.create(n * n * 4)
	for i = 0, n * n - 1 do
		buffer.writeu32(big, i * 4, (i * 2654435761 + 12345) % 4294967296)
	end
	Impostors.present(D.imps, item, big, n)
	check(#item.images == 4, "a 2048 billboard allocated four tile images")
	check(item.labels[2].Visible == false, "tiles stay hidden until all four are written")
	run(12)
	check(item.n == 2048 and item.labels[1].Visible and item.labels[2].Visible and item.labels[3].Visible and item.labels[4].Visible, "all four tiles become visible together")
	local h = n // 2
	local same = true
	for k = 1, 4 do
		local tx, ty = (k - 1) % 2, (k - 1) // 2
		local img = item.images[k]
		for _, probe in { { 0, 0 }, { h - 1, 0 }, { 0, h - 1 }, { h - 1, h - 1 }, { 511, 733 }, { 1000, 17 } } do
			local px, py = probe[1], probe[2]
			local got = buffer.readu32(img.pixels, (py * img.w + px) * 4)
			local want = buffer.readu32(big, ((ty * h + py) * n + tx * h + px) * 4)
			if got ~= want then
				same = false
			end
		end
	end
	check(same, "each tile holds its quadrant of the 2048 render")
	check(item.labels[1].Size.X.Scale == 0.5 and item.labels[4].Position.X.Scale == 0.5 and item.labels[4].Position.Y.Scale == 0.5, "tiles are laid out as a 2 x 2 grid")
end

-- the Uploader rule: at most one image refreshed per frame, ever
local function uploaderRule(label)
	local worst = 0
	for _, set in MOCK.writesByFrame do
		local n = 0
		for _ in set do
			n += 1
		end
		if n > worst then
			worst = n
		end
	end
	check(worst <= 1, label .. ": at most one EditableImage written per frame (worst " .. worst .. ")")
end
uploaderRule("orbit")

-- 2. approach: the mesh boots from the six roots and refines; the shown patches always
-- partition the sphere; atlas tiles and meshes hold exactly the generated patches
local function partition(set)
	local area, n = 0, 0
	for k in set do
		area += Quadtree.area(k)
		n += 1
		local a = Quadtree.parent(k)
		while a do
			if set[a] then
				return false, "a patch and its ancestor both displayed"
			end
			a = Quadtree.parent(a)
		end
	end
	if area ~= 6 then
		return false, "area " .. area .. " over " .. n .. " patches"
	end
	return true, "ok"
end

-- lets a morph in progress finish so shown vertices equal their generation
local function settle()
	for _ = 1, 140 do
		frame(1 / 60)
		if #D.lod.morphing == 0 and #D.lod.results == 0 then
			break
		end
	end
	run(4)
end

local function inspect(label)
	settle()
	local L = D.lod
	local ok, why = partition(L.displayed)
	check(ok, label .. ": displayed patches partition the sphere (" .. why .. ")")
	-- every displayed patch is held by a shown slot; every part sits on the body
	local shown, bad = 0, 0
	local body = L.body
	local c = v3(body.px, body.py, body.pz)
	for k in L.displayed do
		local s = L.slotOf[k]
		if not s or s.state ~= "shown" or s.key ~= k then
			bad += 1
		else
			shown += 1
		end
	end
	for _, chunk in D.pool.chunks do
		if (chunk.part.CFrame.Position - c).Magnitude > 1e-6 then
			bad += 1
		end
	end
	check(bad == 0 and shown > 0, label .. ": " .. shown .. " displayed patches are shown slots, every mesh part on the body (" .. bad .. " wrong)")
	-- every slot that is not shown is parked at the centre
	local parkedOk, parkedN = true, 0
	for _, s in D.pool.slots do
		if s.state ~= "shown" then
			parkedN += 1
			local mesh = s.chunk.mesh
			for v = 1, MeshPool.VS, 37 do
				local p = mesh.pos[s.vIds[v]]
				local q = D.pool.park[v]
				if (p - q).Magnitude > 1e-9 then
					parkedOk = false
				end
			end
		end
	end
	check(parkedOk, label .. ": " .. parkedN .. " slots that are not shown are parked at the body's centre")
	-- byte-exact: a shown slot's colour tile and vertices equal a fresh generation
	local sample = nil
	for _, s in D.pool.slots do
		if s.state == "shown" and s.key then
			local _, lev = CubeSphere.unkey(s.key)
			if not sample or lev > select(2, CubeSphere.unkey(sample.key)) then
				sample = s
			end
		end
	end
	if sample then
		local f, lev, i, j = CubeSphere.unkey(sample.key)
		local ref = TileGen.generate({ body = body.id, face = f, level = lev, i = i, j = j, greenUp = L.opts.greenUp, tint = L.opts.tint })
		local atlas = sample.set.color
		local T = Layout.TILE
		local same = true
		for row = 0, T - 1 do
			for col = 0, T - 1 do
				local a = buffer.readu32(atlas.pixels, ((sample.ty * T + row) * atlas.w + sample.tx * T + col) * 4)
				local b = buffer.readu32(ref.color, (row * T + col) * 4)
				if a ~= b then
					same = false
				end
			end
		end
		check(same, string.format("%s: colour atlas tile of patch L%d (%d,%d) equals its generation", label, lev, i, j))
		local nrm = sample.set.normal
		local sameN = true
		for row = 0, T - 1, 7 do
			for col = 0, T - 1, 7 do
				local a = buffer.readu32(nrm.pixels, ((sample.ty * T + row) * nrm.w + sample.tx * T + col) * 4)
				local b = buffer.readu32(ref.normal, (row * T + col) * 4)
				if a ~= b then
					sameN = false
				end
			end
		end
		check(sameN, label .. ": normal atlas tile equals its generation")
		local mesh = sample.chunk.mesh
		local worst = 0
		for v = 0, MeshPool.VS - 1 do
			local p = mesh.pos[sample.vIds[v + 1]]
			worst = math.max(worst, math.abs(p.X - buffer.readf32(ref.positions, v * 12)), math.abs(p.Y - buffer.readf32(ref.positions, v * 12 + 4)), math.abs(p.Z - buffer.readf32(ref.positions, v * 12 + 8)))
		end
		check(worst < 1e-3, string.format("%s: mesh vertices equal the generated positions (%.1e)", label, worst))
		-- UVs land inside the slot's tile
		local inside = true
		local base = (sample.tile - sample.chunk.first) * MeshPool.VS
		for v = 0, Layout.GRID_VERTS - 1 do
			local uv = mesh.uv[sample.chunk.uvIds[base + v + 1]]
			local u = uv.X * Layout.ATLAS
			local w = (if D.pool.flipV then 1 - uv.Y else uv.Y) * Layout.ATLAS
			if u < sample.tx * T + 1.5 - 1e-6 or u > sample.tx * T + 62.5 + 1e-6 or w < sample.ty * T + 1.5 - 1e-6 or w > sample.ty * T + 62.5 + 1e-6 then
				inside = false
			end
		end
		check(inside, label .. ": UVs inside the slot's tile")
	end
	return shown
end

key("Two")
run(30)
check(D.lod.body ~= nil and D.lod.body.id == "terra", "approach: Terra's mesh is the focus")
for _ = 1, 900 do
	frame(1 / 60)
	if D.lod.booted and D.lod.alpha >= 1 and D.lod.stats.deepest >= 3 then
		break
	end
end
check(D.lod.booted, "the six roots booted")
run(240)
local approachShown = inspect("approach")
check(D.lod.alpha >= 1, "mesh fully faded in over the impostor")
uploaderRule("approach")

-- one mesh per atlas set, the surface in a single EditableMesh
check(#D.pool.sets == 1 and #D.pool.chunks == 1 and D.pool.chunks[1].count == 256, string.format("one atlas set is ONE mesh part holding 256 slots (%d sets, %d parts)", #D.pool.sets, #D.pool.chunks))
check(D.pool.chunks[1].mesh.verts == 256 * MeshPool.VS + 6, "the single mesh has " .. D.pool.chunks[1].mesh.verts .. " vertices")
check(D.pool.chunks[1].part.Transparency == 0, "the surface part is opaque once the mesh is fully faded in")

-- geomorph continuity: a child's starting positions lie on its parent's surface exactly at
-- shared grid points, and close to its own final surface elsewhere
do
	local TileGenR = TileGen
	local bodyId = "terra"
	local parentSpec = { body = bodyId, face = 5, level = 5, i = 14, j = 16 }
	local parent = TileGenR.generate(parentSpec)
	local G = Layout.GRID
	for _, q in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
		local qx, qy = q[1], q[2]
		local child = TileGenR.generate({ body = bodyId, face = 5, level = 6, i = 2 * 14 + qx, j = 2 * 16 + qy })
		local start = MeshPool.startFromParent(parent, qx, qy, TileGenR.skirtDepth(Bodies.get(bodyId).radius, 6))
		local exact, worstShared, worstOwn = true, 0, 0
		for vj = 0, G do
			for vi = 0, G do
				local s = start[vj * (G + 1) + vi + 1]
				local cp = v3(buffer.readf32(child.positions, (vj * (G + 1) + vi) * 12), buffer.readf32(child.positions, (vj * (G + 1) + vi) * 12 + 4), buffer.readf32(child.positions, (vj * (G + 1) + vi) * 12 + 8))
				worstOwn = math.max(worstOwn, (s - cp).Magnitude)
				if vi % 2 == 0 and vj % 2 == 0 then
					local pi, pj = (qx * G + vi) // 2, (qy * G + vj) // 2
					local o = (pj * (G + 1) + pi) * 12
					local pp = v3(buffer.readf32(parent.positions, o), buffer.readf32(parent.positions, o + 4), buffer.readf32(parent.positions, o + 8))
					worstShared = math.max(worstShared, (s - pp).Magnitude)
				end
			end
		end
		check(worstShared < 1e-3, string.format("child quadrant %d,%d starts exactly on the parent's vertices (%.1e)", qx, qy, worstShared))
		check(worstOwn < 12, string.format("and within %.1f studs of its own surface (so the slide is short)", worstOwn))
	end
	-- a merge: the parent starts on the children's vertices
	local kids = {}
	for qy = 0, 1 do
		for qx = 0, 1 do
			kids[qy * 2 + qx] = TileGenR.generate({ body = bodyId, face = 5, level = 6, i = 2 * 14 + qx, j = 2 * 16 + qy })
		end
	end
	local slotLike = { result = parent }
	local finals = MeshPool.finals(slotLike :: any)
	local start = MeshPool.startFromChildren(finals, kids)
	local worst = 0
	for vj = 0, G do
		for vi = 0, G do
			local qx = if vi * 2 > G then 1 else 0
			local qy = if vj * 2 > G then 1 else 0
			local ci, cj = 2 * vi - qx * G, 2 * vj - qy * G
			local o = (cj * (G + 1) + ci) * 12
			local cpb = kids[qy * 2 + qx].positions
			local cp = v3(buffer.readf32(cpb, o), buffer.readf32(cpb, o + 4), buffer.readf32(cpb, o + 8))
			worst = math.max(worst, (start[vj * (G + 1) + vi + 1] - cp).Magnitude)
		end
	end
	check(worst < 1e-3, string.format("a merged parent starts exactly on its children's vertices (%.1e)", worst))
end

-- 3. the coast at 25 studs: deep levels near the camera
key("Three")
for _ = 1, 1500 do
	frame(1 / 60)
	if D.lod.stats.deepest >= 8 then
		break
	end
end
run(120)
local coastShown = inspect("coast")
check(D.lod.stats.deepest >= 8, "full detail near the ground (deepest level " .. D.lod.stats.deepest .. ")")
check(D.lod.stats.swaps > 10, "refinement swaps happened (" .. D.lod.stats.swaps .. ")")
check(D.lod.stats.morphs > 20 and D.lod.stats.morphWrites > 100, string.format("swaps slid vertices instead of fading parts (%d geomorphs, %d vertex writes of %d)", D.lod.stats.morphs, D.lod.stats.morphWrites, MeshPool.VS))
check(#D.pool.slots <= 256, "the pool never exceeds the atlas (" .. #D.pool.slots .. " slots)")
uploaderRule("coast")
realPrint(string.format("     approach %d patches shown, coast %d, deepest L%d, %d generated, %d swaps, %d evicted", approachShown, coastShown, D.lod.stats.deepest, D.lod.stats.generated, D.lod.stats.swaps, D.lod.stats.evicted))

-- 4. fades off: swaps become instant and the cut stays a partition
key("F")
run(200)
inspect("fades off")
key("F")

-- 5. normal-map convention flip: everything rebuilds from the roots
key("N")
run(5)
check(D.lod.opts.greenUp == false and D.lod.booted == false, "N flips the green convention and restarts the surface")
for _ = 1, 600 do
	frame(1 / 60)
	if D.lod.booted and D.lod.stats.deepest >= 4 then
		break
	end
end
inspect("after N")
key("N")
for _ = 1, 600 do
	frame(1 / 60)
	if D.lod.booted and D.lod.stats.deepest >= 4 then
		break
	end
end

-- 6. UV origin flip rewrites every slot's UVs (and back)
key("V")
run(2)
check(D.pool.flipV == true, "V flips the UV origin")
inspect("after V")
key("V")
run(2)

-- 7. focus moves to Selene: Terra's mesh fades out first, then Selene boots
key("Five")
for _ = 1, 1200 do
	frame(1 / 60)
	if D.lod.body and D.lod.body.id == "selene" and D.lod.booted and D.lod.stats.deepest >= 3 then
		break
	end
end
check(D.lod.body ~= nil and D.lod.body.id == "selene", "focus moved to Selene")
run(120)
inspect("selene")

-- 8. Saturnia: no mesh, only impostors
key("Six")
run(240)
check(D.lod.body == nil, "at Saturnia no mesh is active")
local sat = D.imps.byId.saturnia
check(sat.renders > 1 and sat.n >= 128, "Saturnia's impostor re-rendered at " .. sat.n .. " px")

-- 8b. atlas sets, and the engine's mesh size limit: a fresh two-set pool under a 30,000
-- vertex limit finds the largest mesh the engine accepts by halving (256 slots is 91,449
-- vertices, 128 is 45,702, 64 is 22,854)
do
	MOCK.maxMeshVerts = 30000
	local folder2 = makeClass("Folder")
	folder2.Parent = Workspace
	local U2 = mockRequire(ClientF.Uploader).new()
	local pool2 = MeshPool.new(U2, folder2)
	local done2, ok1, ok2 = false, false, false
	task.spawn(function()
		ok1 = (MeshPool.addSet(pool2))
		ok2 = (MeshPool.addSet(pool2))
		done2 = true
	end)
	for _ = 1, 4000 do
		if done2 then
			break
		end
		frame(1 / 60)
	end
	check(done2 and ok1 and ok2, "two atlas sets were added under a mesh size limit")
	check(pool2.slotsPerMesh == 64, "the pool settled on 64 slots per mesh (" .. pool2.slotsPerMesh .. ")")
	check(#pool2.sets == 2 and #pool2.slots == 512 and #pool2.chunks == 8, string.format("two sets, 512 patch tiles, 8 mesh parts (%d, %d, %d)", #pool2.sets, #pool2.slots, #pool2.chunks))
	local within = true
	for _, chunk in pool2.chunks do
		if chunk.mesh.verts > 30000 then
			within = false
		end
	end
	check(within, "every mesh is within the limit")
	check(string.find(pool2.meshMode, "64 slots per mesh", 1, true) ~= nil, "the pool reports what it settled on: " .. pool2.meshMode)
	-- slots of different sets have their own atlas images and tiles
	local s0, s300 = pool2.slots[1], pool2.slots[300]
	check(s0.set ~= s300.set and s0.set.color ~= s300.set.color and s300.tile == 299 - 256, "slots of the second set use the second set's atlases")
	MOCK.maxMeshVerts = math.huge
end

-- 9. the memory-budget probe stops at the engine's refusal and reports it
MOCK.budgetPx = MOCK.usedPx + 40 * 65536 + 100
key("X")
run(30)
local probe = statusLine("budget probe")
check(probe ~= nil and string.find(probe, "refused", 1, true) ~= nil, "budget probe reports the refusal: " .. tostring(probe))
check(MOCK.refusals >= 1, "the mock budget refused an image")

-- final
uploaderRule("whole run")
check(#MOCK.errors == 0, "no errors in threads or handlers (" .. #MOCK.errors .. ")")
for _, e in MOCK.errors do
	realPrint("     " .. string.sub(e, 1, 600))
end
check(#MOCK.warnings == 0, "no warnings (" .. #MOCK.warnings .. ")")
for _, w in MOCK.warnings do
	realPrint("     " .. w)
end
local live = 0
for _, img in MOCK.images do
	if not img.destroyed then
		live += 1
	end
end
realPrint(string.format("frames %d, %.1f s wall, %d EditableImages live (%.2f Mpx), %d meshes, %d tiles generated", MOCK.frame, os.clock() - t0, live, MOCK.usedPx / 1e6, #MOCK.meshes, D.lod.stats.generated))
realPrint(if failures == 0 then "ALL OK" else failures .. " FAILURES")
if failures > 0 then
	error("planets mock run failed")
end
