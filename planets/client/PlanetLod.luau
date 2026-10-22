--!strict
-- Universe at Home: Planets :: PlanetLod
--
-- Drives the surface of the one body the camera is close to (the focus): selects the target
-- cut (Quadtree.select), plans hole-free steps towards it (Quadtree.plan), generates patches
-- on the worker Actors, uploads their tiles through the atlases, and moves them into the
-- single mesh with a geomorph.
--
--   bootstrap  the six face roots are generated and shown together (the plan needs a
--              displayed partition to start from)
--   generate   the patches the plan asks for, most visible first, into free slots or slots
--              holding cached patches nobody needs (least recently used first)
--   results    applied on the main thread: atlas tiles queued on the Uploader; a patch is
--              ready once all its atlases have flushed. The mesh is not touched until the
--              patch is shown, which spreads the vertex writes over the swaps
--   swaps      GEOMORPH. A new patch is shown with its vertices on the surface that was
--              displayed (a child on its parent's bilinear surface, a parent on the
--              children's vertices) and they slide to their own heights over
--              Config.morphSeconds. There is no fade, no overlap and no depth trick: at every
--              instant the surface is one continuous mesh. (The tile contents switch at the
--              first frame; a child's tile refines its parent's, so that is a sharpening.)
--   alpha      the whole mesh fades against the body's impostor when the focus changes

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Quadtree = require(Planets:WaitForChild("Quadtree")) :: any
local CubeSphere = require(Planets:WaitForChild("CubeSphere")) :: any
local TileGen = require(Planets:WaitForChild("TileGen")) :: any
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local Config = require(Planets:WaitForChild("Config")) :: any
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local PlanetLod = {}

type Slot = MeshPool.Slot

export type Options = {
	fades: boolean, -- geomorph on (true) or hard swaps (false)
	frozen: boolean,
	greenUp: boolean,
	tint: boolean,
	splitPx: number,
	capacity: number,
}

export type Lod = {
	pool: MeshPool.Pool,
	U: Uploader.Uploader,
	workers: any,
	body: any?,
	bodyPos: Vector3,
	displayed: { [number]: boolean },
	ready: { [number]: boolean },
	slotOf: { [number]: Slot },
	generating: { [number]: boolean },
	wanted: { [number]: boolean },
	inflight: number,
	results: { { slot: Slot, ticket: number, key: number, result: any } },
	heightLo: { [number]: number },
	heightHi: { [number]: number },
	split: { [number]: boolean }?,
	metric: { [number]: number },
	target: { number },
	morphing: { Slot },
	morphAcc: { [Slot]: number },
	booted: boolean,
	alpha: number, -- whole-mesh opacity
	alphaTarget: number,
	shownAlpha: number,
	frame: number,
	lastSelect: number,
	lastCam: Vector3,
	opts: Options,
	stats: {
		generated: number,
		failed: number,
		lastError: string?,
		genMs: number,
		swaps: number,
		evicted: number,
		rate: number,
		deepest: number,
		limited: boolean,
		morphs: number,
		morphWrites: number,
	},
}

function PlanetLod.new(pool: MeshPool.Pool, U: Uploader.Uploader, workers: any): Lod
	return {
		pool = pool,
		U = U,
		workers = workers,
		body = nil,
		bodyPos = Vector3.zero,
		displayed = {},
		ready = {},
		slotOf = {},
		generating = {},
		wanted = {},
		inflight = 0,
		results = {},
		heightLo = {},
		heightHi = {},
		split = nil,
		metric = {},
		target = {},
		morphing = {},
		morphAcc = {},
		booted = false,
		alpha = 0,
		alphaTarget = 0,
		shownAlpha = -1,
		frame = 0,
		lastSelect = -100,
		lastCam = Vector3.new(1e9, 0, 0),
		opts = { fades = true, frozen = false, greenUp = true, tint = false, splitPx = Config.splitPx, capacity = Config.capacity },
		stats = { generated = 0, failed = 0, lastError = nil, genMs = 0, swaps = 0, evicted = 0, rate = 0, deepest = 0, limited = false, morphs = 0, morphWrites = 0 },
	}
end

local function levelOf(key: number): number
	local _, L = CubeSphere.unkey(key)
	return L
end

-- Frees a slot: forgets its patch and parks its vertices if they were visible.
local function release(L: Lod, slot: Slot)
	local key = slot.key
	if key then
		L.ready[key] = nil
		if L.slotOf[key] == slot then
			L.slotOf[key] = nil
		end
	end
	if slot.state == "shown" then
		MeshPool.park(L.pool, slot)
	end
	MeshPool.clear(slot)
	slot.key = nil
	slot.state = "free"
	slot.ticket += 1
end

-- Drops every patch (focus change, convention change).
function PlanetLod.reset(L: Lod)
	for _, slot in L.pool.slots do
		if slot.state ~= "free" then
			release(L, slot)
		end
	end
	L.displayed = {}
	L.ready = {}
	L.slotOf = {}
	L.generating = {}
	L.wanted = {}
	L.results = {}
	L.morphing = {}
	L.morphAcc = {}
	L.split = nil
	L.booted = false
	L.lastSelect = -100
	L.stats.deepest = 0
end

function PlanetLod.setBody(L: Lod, body: any?)
	if L.body == body then
		return
	end
	PlanetLod.reset(L)
	L.heightLo = {}
	L.heightHi = {}
	L.body = body
	L.alpha = 0
	if body then
		L.bodyPos = Vector3.new(body.px, body.py, body.pz)
		MeshPool.place(L.pool, L.bodyPos)
	end
end

-- A slot for a new patch: a free one, else the least recently used cached patch that is
-- neither displayed nor needed by a pending step.
local function acquire(L: Lod): Slot?
	local free: Slot? = nil
	local best: Slot? = nil
	for _, slot in L.pool.slots do
		if slot.state == "free" then
			free = slot
			break
		elseif slot.state == "ready" and slot.key and not L.displayed[slot.key :: number] and not L.wanted[slot.key :: number] then
			if best == nil or slot.lastUsed < (best :: Slot).lastUsed then
				best = slot
			end
		end
	end
	if free then
		return free
	end
	if best then
		L.stats.evicted += 1
		release(L, best)
		return best
	end
	return nil
end

local function submit(L: Lod, key: number): boolean
	local slot = acquire(L)
	if not slot then
		return false
	end
	local s = slot :: Slot
	local f, lev, i, j = CubeSphere.unkey(key)
	s.key = key
	s.state = "generating"
	s.ticket += 1
	local ticket = s.ticket
	L.slotOf[key] = s
	L.generating[key] = true
	L.inflight += 1
	local body = L.body
	WorkerPool.submit(L.workers, "tile", {
		body = body.id,
		face = f,
		level = lev,
		i = i,
		j = j,
		greenUp = L.opts.greenUp,
		tint = L.opts.tint,
	}, function(ok: boolean, result: any, ms: number)
		L.inflight -= 1
		L.generating[key] = nil
		if s.ticket ~= ticket or L.body ~= body then
			return -- reassigned or the focus moved on: drop the stale result
		end
		if not ok then
			L.stats.failed += 1
			L.stats.lastError = tostring(result)
			release(L, s)
			return
		end
		table.insert(L.results, { slot = s, ticket = ticket, key = key, result = result })
		L.stats.genMs += result.ms or ms
	end)
	return true
end

-- Applies finished jobs: tiles are queued, nothing is written to the mesh.
local function drainResults(L: Lod, budget: number)
	local t0 = os.clock()
	while #L.results > 0 and os.clock() - t0 < budget do
		local r = table.remove(L.results, 1) :: any
		local s: Slot = r.slot
		if s.ticket == r.ticket then
			local key = r.key
			L.heightLo[key] = r.result.hmin
			L.heightHi[key] = r.result.hmax
			MeshPool.assign(L.pool, s, r.result, function()
				if s.ticket == r.ticket then
					s.state = "ready"
					s.lastUsed = L.frame
					L.ready[key] = true
				end
			end)
			L.stats.generated += 1
			L.stats.rate = L.stats.rate * 0.97 + 0.03 * 60
		end
	end
end

local function startMorph(L: Lod, slot: Slot)
	if slot.morph then
		table.insert(L.morphing, slot)
		L.morphAcc[slot] = 0
		L.stats.morphs += 1
	end
end

-- Moves a displayed set of patches over to a new one (Quadtree swap) with a geomorph when
-- the mesh is fully visible, else instantly.
local function startSwap(L: Lod, swap: any)
	local pool = L.pool
	local show: { Slot } = {}
	local hide: { Slot } = {}
	for _, k in swap.show do
		local s = L.slotOf[k]
		if s then
			table.insert(show, s)
		end
	end
	for _, k in swap.hide do
		local s = L.slotOf[k]
		if s then
			table.insert(hide, s)
		end
	end
	Quadtree.apply(L.displayed, swap)
	L.stats.swaps += 1
	local R = L.body.radius
	local morph = L.opts.fades and L.alpha > 0.99
	local shownNew = false
	if morph and #hide == 1 and #show == 4 and hide[1].result then
		-- split: each child starts on its parent's surface
		local parent = hide[1]
		local pr = parent.result
		for _, s in show do
			local _, lev, i, j = CubeSphere.unkey(s.key :: number)
			local start = MeshPool.startFromParent(pr, i % 2, j % 2, TileGen.skirtDepth(R, lev))
			MeshPool.show(pool, s, start)
			startMorph(L, s)
		end
		shownNew = true
	elseif morph and #show == 1 and #hide >= 2 then
		-- merge: the coarser parent starts on its children's vertices
		local s = show[1]
		local f, lev, pi, pj = CubeSphere.unkey(s.key :: number)
		local kids: { [number]: any } = {}
		for _, h in hide do
			if h.result and h.key then
				local hf, hl, hi, hj = CubeSphere.unkey(h.key :: number)
				if hf == f and hl == lev + 1 and hi // 2 == pi and hj // 2 == pj then
					kids[(hj % 2) * 2 + (hi % 2)] = h.result
				end
			end
		end
		if next(kids) then
			local finals = MeshPool.finals(s)
			MeshPool.show(pool, s, MeshPool.startFromChildren(finals, kids))
			startMorph(L, s)
			shownNew = true
		end
	end
	for _, h in hide do
		MeshPool.park(pool, h)
		L.morphAcc[h] = nil
		h.state = "ready"
	end
	if not shownNew then
		for _, s in show do
			MeshPool.show(pool, s, nil)
		end
	end
	for _, s in show do
		s.lastUsed = L.frame
	end
end

-- Advances geomorphs, at most Config.morphPerFrame slots per frame (round robin; a slot that
-- waits catches up by the time it accumulated).
local function stepMorphs(L: Lod, dt: number)
	local n = #L.morphing
	if n == 0 then
		return
	end
	for _, s in L.morphing do
		L.morphAcc[s] = (L.morphAcc[s] or 0) + dt
	end
	local budget = Config.morphPerFrame
	local keep: { Slot } = {}
	for idx, s in L.morphing do
		if s.morph and s.state == "shown" then
			if budget > 0 then
				budget -= 1
				local acc = L.morphAcc[s] or dt
				L.morphAcc[s] = 0
				L.stats.morphWrites += 1
				if MeshPool.stepMorph(s, acc, Config.morphSeconds) then
					table.insert(keep, s)
				else
					L.morphAcc[s] = nil
				end
			else
				table.insert(keep, s)
			end
		else
			L.morphAcc[s] = nil
		end
		local _ = idx
	end
	L.morphing = keep
end

-- Per frame. `cam` is the current camera; `budget` the main-thread seconds allowed.
function PlanetLod.update(L: Lod, cam: Camera, dt: number, budget: number)
	L.frame += 1
	local body = L.body
	local pool = L.pool
	-- whole-mesh opacity follows alphaTarget (impostor crossfade)
	local target = if body and L.booted then L.alphaTarget else 0
	if L.alpha ~= target then
		local step = dt / 0.6
		if L.alpha < target then
			L.alpha = math.min(target, L.alpha + step)
		else
			L.alpha = math.max(target, L.alpha - step)
		end
	end
	if L.alpha ~= L.shownAlpha then
		L.shownAlpha = L.alpha
		MeshPool.setOpacity(pool, L.alpha)
	end
	if not body or #pool.slots == 0 then
		return
	end
	drainResults(L, budget * 0.5)
	stepMorphs(L, dt)

	local camPos = cam.CFrame.Position
	local inUse = 0
	for _, slot in pool.slots do
		if slot.state ~= "free" then
			inUse += 1
		end
	end
	local total = pool.maxSlots
	local maxInflight = if L.workers.available then math.max(2, L.workers.readyCount * 2) else 1

	-- bootstrap: the six roots, shown together
	if not L.booted then
		local all = true
		local roots = {}
		for f = 1, 6 do
			local k = CubeSphere.key(f, 0, 0, 0)
			table.insert(roots, k)
			if not L.ready[k] then
				all = false
				if not L.generating[k] and not L.slotOf[k] and L.inflight < maxInflight then
					submit(L, k)
				end
			end
		end
		if all then
			for _, k in roots do
				L.displayed[k] = true
				MeshPool.show(pool, L.slotOf[k], nil)
				L.slotOf[k].lastUsed = L.frame
			end
			L.booted = true
		end
		return
	end

	if L.opts.frozen then
		return
	end

	-- select (every few frames, or at once after a large move)
	local moved = (camPos - L.lastCam).Magnitude
	local rel = camPos - L.bodyPos
	if L.frame - L.lastSelect >= 4 or moved > rel.Magnitude * 0.02 then
		L.lastSelect = L.frame
		L.lastCam = camPos
		local viewport = cam.ViewportSize
		local look = cam.CFrame.LookVector
		local reserve = math.max(16, total // 5)
		local sel = Quadtree.select({
			x = rel.X,
			y = rel.Y,
			z = rel.Z,
			dx = look.X,
			dy = look.Y,
			dz = look.Z,
			tanHalfFov = math.tan(math.rad(cam.FieldOfView * 0.5)),
			aspect = viewport.X / math.max(1, viewport.Y),
			viewportH = viewport.Y,
		}, {
			radius = body.radius,
			maxHeight = body.maxHeight,
			heightLo = L.heightLo,
			heightHi = L.heightHi,
			capacity = math.min(L.opts.capacity, total - reserve),
			splitPx = L.opts.splitPx,
			hysteresis = 1.35,
			maxLevel = if body.id == "terra" then Config.maxLevelTerra else Config.maxLevelOther,
		}, L.split)
		L.split = sel.split
		L.target = sel.leaves
		L.metric = sel.metric
		L.stats.limited = sel.limited
	end

	local plan = Quadtree.plan(L.displayed, L.ready, L.target, L.metric, total - inUse < 32)
	L.wanted = plan.needed
	-- generation, most visible first
	local sent = 0
	for _, k in plan.generate do
		if L.inflight >= maxInflight or sent >= 8 then
			break
		end
		if not L.generating[k] and not L.ready[k] and not L.slotOf[k] then
			if not submit(L, k) then
				break
			end
			sent += 1
		end
	end
	-- swaps whose patches are all uploaded
	for _, swap in plan.swaps do
		startSwap(L, swap)
	end
	local deepest = 0
	for k in L.displayed do
		local lev = levelOf(k)
		if lev > deepest then
			deepest = lev
		end
	end
	L.stats.deepest = deepest
end

-- Counts for the HUD: shown, cached, generating, uploading.
function PlanetLod.counts(L: Lod): (number, number, number, number)
	local shown, ready, gen, uploading = 0, 0, 0, 0
	for _, s in L.pool.slots do
		if s.state == "shown" then
			shown += 1
		elseif s.state == "ready" then
			ready += 1
		elseif s.state == "generating" then
			gen += 1
		elseif s.state == "uploading" then
			uploading += 1
		end
	end
	return shown, ready, gen, uploading
end

-- Debug tint by level is a tile-generation option now (patches carry the tint in their
-- colour tiles), so changing it regenerates every patch.
function PlanetLod.refreshTint(L: Lod)
	PlanetLod.reset(L)
end

return PlanetLod
