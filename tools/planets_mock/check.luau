
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
for _, n in { "Layout", "Noise3", "CubeSphere", "Bodies", "TileGen", "Quadtree", "SphereCache", "Impostor", "SkyGen", "Clouds", "PlanetJobs" } do
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

local function inspect(label)
	local L = D.lod
	local ok, why = partition(L.displayed)
	check(ok, label .. ": displayed patches partition the sphere (" .. why .. ")")
	-- every displayed patch is held by a shown slot whose part is placed on the body
	local shown, bad = 0, 0
	local body = L.body
	for k in L.displayed do
		local s = L.slotOf[k]
		if not s or s.state ~= "shown" or s.key ~= k then
			bad += 1
		else
			shown += 1
			local p = s.part.CFrame.Position
			local c = v3(body.px, body.py, body.pz)
			if not L.biased[s] and (p - c).Magnitude > 1e-6 then
				bad += 1
			end
		end
	end
	check(bad == 0 and shown > 0, label .. ": " .. shown .. " displayed patches are shown slots on the body (" .. bad .. " wrong)")
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
		local ref = TileGen.generate({ body = body.id, face = f, level = lev, i = i, j = j, greenUp = L.opts.greenUp })
		local atlas = D.pool.color
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
		local nrm = D.pool.normal
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
		local mesh = sample.mesh
		local worst = 0
		for v = 0, Layout.VERTS - 1 do
			local p = mesh.pos[sample.vIds[v + 1]]
			worst = math.max(worst, math.abs(p.X - buffer.readf32(ref.positions, v * 12)), math.abs(p.Y - buffer.readf32(ref.positions, v * 12 + 4)), math.abs(p.Z - buffer.readf32(ref.positions, v * 12 + 8)))
		end
		check(worst < 1e-3, string.format("%s: mesh vertices equal the generated positions (%.1e)", label, worst))
		-- UVs land inside the slot's tile
		local inside = true
		for v = 0, Layout.GRID_VERTS - 1 do
			local uv = mesh.uv[sample.uvIds[v + 1]]
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
