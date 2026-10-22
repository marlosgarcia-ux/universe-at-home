--!strict
-- Universe at Home: Planets :: Impostors
--
-- Every body is also a raytraced billboard (planets/shared/Impostor): the whole body when
-- it is far away, the atmosphere halo around the mesh when it is the focus.
--
-- PLACEMENT. Bodies lie tens of thousands of studs apart. A billboard is drawn at a
-- compressed distance along its true direction and scaled by the same factor, which keeps
-- its angular size and position on screen exactly (scaled space) while staying well
-- inside the renderer's depth range. Order against the focus planet's mesh, which is at
-- true scale: a body nearer than the planet's surface is drawn on top; a body behind it is
-- placed beyond the planet's horizon distance, where the planet hides it correctly.
--
-- RENDERING. The image is re-rendered on the worker Actors in bands of rows whenever the
-- view has changed by a fraction of a pixel (direction, distance, roll, sun, clouds),
-- into a back buffer, and the finished image replaces the old one in a single atlas-style
-- flush. Resolution follows the on-screen size (32 to 512 px, shown through
-- ImageRectSize), so a distant moon costs a few hundred pixels and a close planet a full
-- 512 x 512.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Bodies = require(Planets:WaitForChild("Bodies")) :: any
local Impostor = require(Planets:WaitForChild("Impostor")) :: any
local SphereCache = require(Planets:WaitForChild("SphereCache")) :: any
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local Impostors = {}

local MAX_N = 512
local BAND = 32

export type Item = {
	def: any,
	img: EditableImage?,
	entry: Uploader.Entry?,
	anchor: Part,
	gui: BillboardGui,
	label: ImageLabel,
	n: number,
	shown: boolean,
	back: buffer?,
	bandsLeft: number,
	renderId: number,
	rendering: boolean,
	lastStart: number,
	last: any?,
	cacheReady: boolean,
	renders: number,
	ms: number,
	screenPx: number,
}

export type Manager = {
	items: { Item },
	byId: { [string]: Item },
	U: Uploader.Uploader,
	workers: any,
	cachesReady: number,
	stats: { renders: number, bands: number, failed: number, lastError: string? },
}

function Impostors.compress(D: number): number
	if D <= 1200 then
		return D
	end
	local e = D - 1200
	return 1200 + 2300 * e / (e + 2300)
end

local function extraFor(def: any): number
	if def.rings then
		return def.rings.outer * 1.02
	end
	if def.atmosphere then
		return 1 + def.atmosphere.thickness * 1.5
	end
	return 1.02
end

function Impostors.new(U: Uploader.Uploader, workers: any, folder: Instance): Manager
	local M: Manager = { items = {}, byId = {}, U = U, workers = workers, cachesReady = 0, stats = { renders = 0, bands = 0, failed = 0, lastError = nil } }
	for _, def in Bodies.list do
		local img = MeshPool.createImage(MAX_N, MAX_N)
		local anchor = Instance.new("Part")
		anchor.Name = "Impostor_" .. def.name
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Parent = folder
		local gui = Instance.new("BillboardGui")
		gui.Name = "Billboard"
		gui.LightInfluence = 0
		gui.Brightness = 1
		gui.AlwaysOnTop = false
		gui.ClipsDescendants = false
		gui.Enabled = false
		gui.Size = UDim2.fromScale(1, 1)
		gui.Adornee = anchor
		gui.Parent = anchor
		local label = Instance.new("ImageLabel")
		label.Name = "Image"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.ImageRectOffset = Vector2.zero
		label.ImageRectSize = Vector2.new(MAX_N, MAX_N)
		if img then
			label.ImageContent = Content.fromObject(img)
		end
		label.Parent = gui
		local item: Item = {
			def = def,
			img = img,
			entry = if img then Uploader.register(U, "impostor " .. def.name, img) else nil,
			anchor = anchor,
			gui = gui,
			label = label,
			n = 256,
			shown = false,
			back = nil,
			bandsLeft = 0,
			renderId = 0,
			rendering = false,
			lastStart = -1,
			last = nil,
			cacheReady = false,
			renders = 0,
			ms = 0,
			screenPx = 0,
		}
		table.insert(M.items, item)
		M.byId[def.id] = item
	end
	return M
end

-- Builds every body's sphere cache on the workers (six faces each) and hands each worker a
-- copy. Yields; run it in its own thread.
function Impostors.buildCaches(M: Manager)
	local n = SphereCache.N
	for _, item in M.items do
		local faces: { buffer } = {}
		local got = 0
		for f = 1, 6 do
			WorkerPool.submit(M.workers, "cacheFace", { body = item.def.id, face = f, n = n }, function(ok: boolean, result: any)
				if ok then
					faces[f] = result
				else
					M.stats.failed += 1
					M.stats.lastError = tostring(result)
				end
				got += 1
			end)
		end
		local t0 = os.clock()
		while got < 6 and os.clock() - t0 < 60 do
			task.wait(0.05)
		end
		if #faces == 6 then
			WorkerPool.broadcast(M.workers, "setCache", { body = item.def.id, n = n, faces = faces }, 20)
			item.cacheReady = true
			item.last = nil -- re-render with the cache
			M.cachesReady += 1
		end
	end
end

local function angleBetween(a: Vector3, b: Vector3): number
	local d = a:Dot(b)
	return if d >= 1 then 0 elseif d <= -1 then math.pi else math.acos(d)
end

local function sizeFor(px: number): number
	local n = 32
	while n < px * 1.1 and n < MAX_N do
		n *= 2
	end
	return n
end

-- Starts a render of `item` for the given view on the workers.
local function startRender(M: Manager, item: Item, params: any, now: number)
	local n = params.n
	item.renderId += 1
	local id = item.renderId
	item.rendering = true
	item.lastStart = now
	item.back = buffer.create(n * n * 4)
	item.bandsLeft = (n + BAND - 1) // BAND
	item.last = params
	local t0 = os.clock()
	for y0 = 0, n - 1, BAND do
		local y1 = math.min(n, y0 + BAND)
		WorkerPool.submit(M.workers, "impostor", { params = params, y0 = y0, y1 = y1 }, function(ok: boolean, res: any)
			if item.renderId ~= id then
				return
			end
			M.stats.bands += 1
			local back = item.back
			if ok and back then
				buffer.copy(back, res.y0 * n * 4, res.band, 0, (res.y1 - res.y0) * n * 4)
			elseif not ok then
				M.stats.failed += 1
				M.stats.lastError = tostring(res)
			end
			item.bandsLeft -= 1
			if item.bandsLeft == 0 then
				item.rendering = false
				item.ms = (os.clock() - t0) * 1000
				local entry = item.entry
				if entry and back then
					Uploader.queue(M.U, entry, 0, 0, n, n, back, function()
						-- switch the visible region together with the new pixels
						item.label.ImageRectOffset = Vector2.zero
						item.label.ImageRectSize = Vector2.new(n, n)
						item.n = n
						item.shown = true
					end)
				end
				item.renders += 1
				M.stats.renders += 1
			end
		end)
	end
end

-- Per frame: placement of every billboard, and re-renders where the view changed.
-- `focus` is the body whose mesh is active (or nil) and `focusAlpha` its opacity.
function Impostors.update(M: Manager, cam: Camera, sun: Vector3, focus: any?, focusAlpha: number, cloudAngle: number, now: number)
	local cf = cam.CFrame
	local camPos = cf.Position
	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
	local viewport = cam.ViewportSize
	local focal = viewport.Y / (2 * math.tan(math.rad(cam.FieldOfView * 0.5)))
	local fD, fR = 0, 0
	if focus and focusAlpha > 0 then
		local fc = Vector3.new(focus.px, focus.py, focus.pz)
		fD = (fc - camPos).Magnitude
		fR = focus.radius
	end
	local tangent = if fD > fR then math.sqrt(fD * fD - fR * fR) else 0
	-- bodies behind the focus planet, nearest first, get increasing distances
	local rank = 0
	for _, item in M.items do
		local def = item.def
		local center = Vector3.new(def.px, def.py, def.pz)
		local toB = center - camPos
		local D = toB.Magnitude
		local dir = if D > 1e-6 then toB / D else look
		local extra = extraFor(def)
		local halfTrue = Impostor.halfSize(def.radius, extra, D, item.n)
		local insideAtmosphere = D <= def.radius * extra * 1.001
		item.screenPx = 2 * halfTrue / math.max(D, 1) * focal
		local isFocus = focus == def and focusAlpha > 0
		local place, onTop
		if isFocus then
			place, onTop = D, false
		elseif fD > 0 then
			if D + def.radius * extra < fD - fR then
				place, onTop = math.min(D, Impostors.compress(D)), true
			else
				rank += 1
				place, onTop = tangent + 250 + rank * 40, false
			end
		else
			place, onTop = Impostors.compress(D), false
		end
		local scale = place / math.max(D, 1e-6)
		item.anchor.CFrame = CFrame.new(camPos + dir * place)
		item.gui.AlwaysOnTop = onTop
		item.gui.Size = UDim2.fromScale(2 * halfTrue * scale, 2 * halfTrue * scale)
		-- inside the atmosphere the halo surrounds the camera: the engine's Atmosphere takes over
		local visible = item.shown and item.img ~= nil and not insideAtmosphere
		if isFocus and D < def.radius * 1.12 then
			visible = false
		end
		item.gui.Enabled = visible
		-- re-render when the view changed by a fraction of a pixel
		if item.img and not insideAtmosphere and not item.rendering and now - item.lastStart > 0.12 and item.screenPx >= 2 and look:Dot(dir) > -0.3 then
			local n = sizeFor(item.screenPx)
			local half = Impostor.halfSize(def.radius, extra, D, n)
			local pixelAngle = 2 * half / n / D
			local last = item.last
			local need = last == nil or last.n ~= n
			if not need then
				local lastDir = Vector3.new(-last.cx, -last.cy, -last.cz).Unit
				local lastD = math.sqrt(last.cx * last.cx + last.cy * last.cy + last.cz * last.cz)
				need = angleBetween(dir, lastDir) > pixelAngle * 0.35
					or math.abs(D - lastD) / D > 0.004
					or angleBetween(right, Vector3.new(last.rx, last.ry, last.rz)) > 0.01
					or angleBetween(up, Vector3.new(last.ux, last.uy, last.uz)) > 0.01
					or angleBetween(sun, Vector3.new(last.sx, last.sy, last.sz)) > 0.003
					or (def.id == "terra" and math.abs(cloudAngle - last.cloudAngle) > 0.004)
			end
			if need then
				local rel = camPos - center
				startRender(M, item, {
					body = def.id,
					n = n,
					cx = rel.X,
					cy = rel.Y,
					cz = rel.Z,
					rx = right.X,
					ry = right.Y,
					rz = right.Z,
					ux = up.X,
					uy = up.Y,
					uz = up.Z,
					half = half,
					sx = sun.X,
					sy = sun.Y,
					sz = sun.Z,
					cloudAngle = cloudAngle,
				}, now)
			end
		end
	end
end

-- Pixels held by the impostor images.
function Impostors.pixels(M: Manager): number
	local n = 0
	for _, item in M.items do
		if item.img then
			n += MAX_N * MAX_N
		end
	end
	return n
end

return Impostors
