--!strict
-- Universe at Home: Planets :: PlanetLod
--
-- Drives the patch system for the one body the camera is close to (the focus): selects
-- the target cut (Quadtree.select), plans hole-free steps towards it (Quadtree.plan),
-- generates patches on the worker Actors, uploads them through the atlases, and swaps
-- them in with a two-phase fade.
--
--   bootstrap  the six face roots are generated and shown together (the plan needs a
--              displayed partition to start from)
--   generate   patches the plan asks for, most visible first, into free slots or slots
--              holding cached patches nobody needs (least recently used first)
--   results    applied on the main thread within a time budget (mesh writes), atlas
--              tiles queued on the Uploader; a patch is ready once its atlases flushed
--   swaps      phase 1: the new patches fade in over the old ones, pulled a hair towards
--              the camera so the depth test never lets the old surface win (no
--              z-fighting); phase 2: the old patches disappear behind them. With fades off
--              the swap is instant (the comparison the HUD toggle shows).
--   alpha      the whole mesh fades against the body's impostor when the focus changes

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Quadtree = require(Planets:WaitForChild("Quadtree")) :: any
local CubeSphere = require(Planets:WaitForChild("CubeSphere")) :: any
local Layout = require(Planets:WaitForChild("Layout")) :: any
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local PlanetLod = {}

local FADE_SECONDS = 0.35
local LEVEL_TINTS = {
	Color3.fromRGB(255, 140, 140),
	Color3.fromRGB(255, 205, 128),
	Color3.fromRGB(255, 255, 128),
	Color3.fromRGB(153, 255, 128),
	Color3.fromRGB(128, 255, 230),
	Color3.fromRGB(128, 190, 255),
	Color3.fromRGB(190, 140, 255),
	Color3.fromRGB(255, 140, 230),
}

type Slot = MeshPool.Slot

type Fade = {
	show: { Slot },
	hide: { Slot },
	t: number,
}

export type Options = {
	fades: boolean,
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
	fades: { Fade },
	opacity: { [Slot]: number },
	biased: { [Slot]: boolean },
	booted: boolean,
	alpha: number, -- whole-mesh opacity
	alphaTarget: number,
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
		rate: number, -- patches per second (smoothed)
		deepest: number,
		limited: boolean,
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
		fades = {},
		opacity = {},
		biased = {},
		booted = false,
		alpha = 0,
		alphaTarget = 0,
		frame = 0,
		lastSelect = -100,
		lastCam = Vector3.new(1e9, 0, 0),
		opts = { fades = true, frozen = false, greenUp = true, tint = false, splitPx = 1.6, capacity = 200 },
		stats = { generated = 0, failed = 0, lastError = nil, genMs = 0, swaps = 0, evicted = 0, rate = 0, deepest = 0, limited = false },
	}
end

local function levelOf(key: number): number
	local _, L = CubeSphere.unkey(key)
	return L
end

local function applyVisual(L: Lod, slot: Slot)
	local o = L.opacity[slot] or 0
	slot.part.Transparency = 1 - o * L.alpha
end

local function release(L: Lod, slot: Slot)
	local key = slot.key
	if key then
		L.ready[key] = nil
		if L.slotOf[key] == slot then
			L.slotOf[key] = nil
		end
	end
	slot.key = nil
	slot.state = "free"
	slot.ticket += 1
	L.opacity[slot] = nil
	L.biased[slot] = nil
	slot.part.Transparency = 1
	slot.part.CFrame = CFrame.new(L.bodyPos)
end

-- Drops every patch (focus change, normal-convention change).
function PlanetLod.reset(L: Lod)
	for _, slot in L.pool.slots do
		release(L, slot)
	end
	L.displayed = {}
	L.ready = {}
	L.slotOf = {}
	L.generating = {}
	L.wanted = {}
	L.results = {}
	L.fades = {}
	L.opacity = {}
	L.biased = {}
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
	end
end

-- A slot for a new patch: a free one, else the least recently used cached patch that is
-- neither displayed nor wanted. Grows the pool in the background when everything is busy.
local function acquire(L: Lod): Slot?
	local free: Slot? = nil
	local nFree = 0
	local best: Slot? = nil
	for _, slot in L.pool.slots do
		if slot.state == "free" then
			nFree += 1
			if not free then
				free = slot
			end
		elseif slot.state == "ready" and slot.key and not L.displayed[slot.key :: number] and not L.wanted[slot.key :: number] then
			if best == nil or slot.lastUsed < (best :: Slot).lastUsed then
				best = slot
			end
		end
	end
	-- grow before free slots run out: cached patches are worth keeping
	local pool = L.pool
	if nFree <= 4 and not pool.growing and #pool.slots < Layout.SLOTS and not pool.failed then
		pool.growing = true
		task.spawn(function()
			MeshPool.grow(pool, 8)
			pool.growing = false
		end)
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
		tint = false,
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

-- Applies finished jobs within `budget` seconds of main-thread time.
local function drainResults(L: Lod, budget: number)
	local t0 = os.clock()
	while #L.results > 0 and os.clock() - t0 < budget do
		local r = table.remove(L.results, 1) :: any
		local s: Slot = r.slot
		if s.ticket == r.ticket then
			local key = r.key
			L.heightLo[key] = r.result.hmin
			L.heightHi[key] = r.result.hmax
			MeshPool.assign(L.pool, L.U, s, r.result, function()
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

local function showSlot(L: Lod, slot: Slot, opacity: number)
	slot.state = "shown"
	slot.lastUsed = L.frame
	slot.part.CFrame = CFrame.new(L.bodyPos) -- vertices are body-local
	L.opacity[slot] = opacity
	if L.opts.tint and slot.key then
		MeshPool.tint(slot, LEVEL_TINTS[(levelOf(slot.key :: number) % #LEVEL_TINTS) + 1])
	else
		MeshPool.tint(slot, Color3.new(1, 1, 1))
	end
	applyVisual(L, slot)
end

local function hideSlot(L: Lod, slot: Slot)
	if slot.state == "shown" then
		slot.state = "ready"
	end
	L.opacity[slot] = 0
	L.biased[slot] = nil
	slot.part.Transparency = 1
	slot.part.CFrame = CFrame.new(L.bodyPos)
end

local function startSwap(L: Lod, swap: any)
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
	if L.opts.fades and #hide > 0 and L.alpha > 0.99 then
		for _, s in show do
			showSlot(L, s, 0)
			L.biased[s] = true
		end
		table.insert(L.fades, { show = show, hide = hide, t = 0 })
	else
		for _, s in show do
			showSlot(L, s, 1)
		end
		for _, s in hide do
			hideSlot(L, s)
		end
	end
end

local function stepFades(L: Lod, dt: number)
	local i = 1
	while i <= #L.fades do
		local fd = L.fades[i]
		fd.t += dt / FADE_SECONDS
		local o = math.clamp(fd.t, 0, 1)
		o = o * o * (3 - 2 * o)
		for _, s in fd.show do
			if s.state == "shown" then
				L.opacity[s] = o
				applyVisual(L, s)
			end
		end
		if fd.t >= 1 then
			-- phase 2: the old patches are now fully covered; remove them, then drop the bias
			for _, s in fd.hide do
				if s.state == "shown" and not (s.key and L.displayed[s.key :: number]) then
					hideSlot(L, s)
				end
			end
			for _, s in fd.show do
				L.biased[s] = nil
				s.part.CFrame = CFrame.new(L.bodyPos)
			end
			table.remove(L.fades, i)
		else
			i += 1
		end
	end
end

-- Per frame. `cam` is the current camera; `budget` the main-thread seconds allowed.
function PlanetLod.update(L: Lod, cam: Camera, dt: number, budget: number)
	L.frame += 1
	local body = L.body
	-- whole-mesh opacity follows alphaTarget (impostor crossfade)
	local target = if body and L.booted then L.alphaTarget else 0
	if L.alpha ~= target then
		local step = dt / 0.6
		if L.alpha < target then
			L.alpha = math.min(target, L.alpha + step)
		else
			L.alpha = math.max(target, L.alpha - step)
		end
		for slot, _ in L.opacity do
			applyVisual(L, slot)
		end
	end
	if not body then
		return
	end
	drainResults(L, budget * 0.5)
	stepFades(L, dt)
	-- depth bias for patches fading in: a hair towards the camera
	local camPos = cam.CFrame.Position
	for slot, _ in L.biased do
		local key = slot.key
		if key then
			local f, lev, i, j = CubeSphere.unkey(key)
			local x, y, z = CubeSphere.patchPoint(f, lev, i, j, 0.5, 0.5)
			local centre = L.bodyPos + Vector3.new(x, y, z) * body.radius
			local toCam = camPos - centre
			local d = toCam.Magnitude
			if d > 1e-3 then
				slot.part.CFrame = CFrame.new(L.bodyPos + toCam.Unit * (d * 0.0015 + 0.02))
			end
		end
	end

	local pool = L.pool
	local inUse = 0
	for _, slot in pool.slots do
		if slot.state ~= "free" then
			inUse += 1
		end
	end
	if #pool.slots < 24 and not pool.growing and not pool.failed then
		pool.growing = true
		task.spawn(function()
			MeshPool.grow(pool, 24)
			pool.growing = false
		end)
	end
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
				showSlot(L, L.slotOf[k], 1)
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
			capacity = L.opts.capacity,
			splitPx = L.opts.splitPx,
			hysteresis = 1.35,
			maxLevel = if body.id == "terra" then 11 else 10,
		}, L.split)
		L.split = sel.split
		L.target = sel.leaves
		L.metric = sel.metric
		L.stats.limited = sel.limited
	end

	local plan = Quadtree.plan(L.displayed, L.ready, L.target, L.metric, Layout.SLOTS - inUse < 32)
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
	-- deepest displayed level, for the HUD
	local deepest = 0
	for k in L.displayed do
		local lev = levelOf(k)
		if lev > deepest then
			deepest = lev
		end
	end
	L.stats.deepest = deepest
end

-- Counts for the HUD.
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

-- Re-tints every shown patch (debug view of the levels).
function PlanetLod.refreshTint(L: Lod)
	for _, s in L.pool.slots do
		if s.state == "shown" and s.key then
			MeshPool.tint(s, if L.opts.tint then LEVEL_TINTS[(levelOf(s.key :: number) % #LEVEL_TINTS) + 1] else Color3.new(1, 1, 1))
		end
	end
end

return PlanetLod
