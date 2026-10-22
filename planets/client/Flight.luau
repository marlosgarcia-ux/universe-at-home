--!strict
-- Universe at Home: Planets :: Flight
--
-- A free-flight camera for planetary scales.
--   mouse     hold the right button to look around
--   W A S D   move; E / Space up, Q / C down (relative to the view)
--   Shift     boost x5; mouse wheel changes the base speed
-- Speed scales with the altitude above the nearest body's actual terrain, so the same
-- keys cross an orbit in seconds and creep over a ridge. "Up" is the nearest body's
-- radial direction, so the horizon stays level anywhere on a sphere. The camera never
-- goes below 1.5 studs above the terrain under it (heights come from the same body
-- functions the patches use).

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local Bodies = require(Planets:WaitForChild("Bodies")) :: any

local Flight = {}

export type Flight = {
	cam: Camera,
	pos: Vector3,
	look: Vector3,
	speedScale: number,
	looking: boolean,
	nearest: any,
	altitude: number, -- above the nearest body's terrain (studs)
	ground: number, -- terrain height there (studs above the reference sphere)
	connections: { RBXScriptConnection },
	keys: { [Enum.KeyCode]: boolean },
}

local function surfaceHeight(body: any, dir: Vector3): number
	if body.kind ~= "rocky" then
		return 0
	end
	local x, y, z = dir.X, dir.Y, dir.Z
	local c1 = Bodies.coarseAt(body, x, y, z)
	local h = body.height(body, x, y, z, 2e-5, c1)
	if body.sea and h < 0 then
		h = 0
	end
	return h
end
Flight.surfaceHeight = surfaceHeight

-- Nearest body by distance to its surface.
function Flight.nearestBody(pos: Vector3): (any, number)
	local best, bestAlt = nil, math.huge
	for _, b in Bodies.list do
		local c = Vector3.new(b.px, b.py, b.pz)
		local alt = (pos - c).Magnitude - b.radius
		if alt < bestAlt then
			best, bestAlt = b, alt
		end
	end
	return best, bestAlt
end

function Flight.new(cam: Camera): Flight
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 70
	local F: Flight = {
		cam = cam,
		pos = Vector3.new(0, 1600 * 0.4, 1600 * 3.4),
		look = Vector3.new(0, -0.12, -1).Unit,
		speedScale = 1,
		looking = false,
		nearest = Bodies.list[1],
		altitude = 1e4,
		ground = 0,
		connections = {},
		keys = {},
	}
	table.insert(
		F.connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				F.looking = true
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			elseif input.UserInputType == Enum.UserInputType.Keyboard and not processed then
				F.keys[input.KeyCode] = true
			end
		end)
	)
	table.insert(
		F.connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				F.looking = false
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			elseif input.UserInputType == Enum.UserInputType.Keyboard then
				F.keys[input.KeyCode] = nil
			end
		end)
	)
	table.insert(
		F.connections,
		UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
			if input.UserInputType == Enum.UserInputType.MouseMovement and F.looking then
				local d = input.Delta
				Flight.turn(F, -d.X * 0.0035, -d.Y * 0.0035)
			elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
				F.speedScale = math.clamp(F.speedScale * (if input.Position.Z > 0 then 1.25 else 0.8), 0.05, 40)
			end
		end)
	)
	return F
end

local function localUp(F: Flight): Vector3
	local b = F.nearest
	local c = Vector3.new(b.px, b.py, b.pz)
	local r = F.pos - c
	return if r.Magnitude > 1e-6 then r.Unit else Vector3.yAxis
end

-- Yaw about the local up, pitch about the view's right; the horizon stays level.
function Flight.turn(F: Flight, yaw: number, pitch: number)
	local up = localUp(F)
	local look = CFrame.fromAxisAngle(up, yaw):VectorToWorldSpace(F.look)
	local right = look:Cross(up)
	if right.Magnitude < 1e-4 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local pitched = CFrame.fromAxisAngle(right, pitch):VectorToWorldSpace(look)
	-- keep away from straight up and straight down
	local d = pitched:Dot(up)
	if d < 0.985 and d > -0.985 then
		look = pitched
	end
	F.look = look.Unit
end

-- Places the camera at `pos` looking at `target`.
function Flight.teleport(F: Flight, pos: Vector3, target: Vector3)
	F.pos = pos
	F.look = (target - pos).Unit
	F.nearest = Flight.nearestBody(pos)
end

function Flight.update(F: Flight, dt: number)
	local body = Flight.nearestBody(F.pos)
	F.nearest = body
	local c = Vector3.new(body.px, body.py, body.pz)
	local rel = F.pos - c
	local dist = rel.Magnitude
	local dir = if dist > 1e-6 then rel / dist else Vector3.yAxis
	F.ground = surfaceHeight(body, dir)
	F.altitude = dist - body.radius - F.ground
	local up = localUp(F)
	local right = F.look:Cross(up)
	right = if right.Magnitude > 1e-4 then right.Unit else Vector3.xAxis
	local camUp = right:Cross(F.look).Unit
	local move = Vector3.zero
	local k = F.keys
	if k[Enum.KeyCode.W] then
		move += F.look
	end
	if k[Enum.KeyCode.S] then
		move -= F.look
	end
	if k[Enum.KeyCode.D] then
		move += right
	end
	if k[Enum.KeyCode.A] then
		move -= right
	end
	if k[Enum.KeyCode.E] or k[Enum.KeyCode.Space] then
		move += camUp
	end
	if k[Enum.KeyCode.Q] or k[Enum.KeyCode.C] then
		move -= camUp
	end
	if move.Magnitude > 0 then
		local speed = math.clamp(math.max(F.altitude, 0) * 0.6, 3, 6000) * F.speedScale
		if k[Enum.KeyCode.LeftShift] or k[Enum.KeyCode.RightShift] then
			speed *= 5
		end
		F.pos += move.Unit * speed * dt
	end
	-- stay above the terrain
	rel = F.pos - c
	dist = rel.Magnitude
	if dist > 1e-6 then
		dir = rel / dist
		local floor = body.radius + surfaceHeight(body, dir) + 1.5
		if dist < floor then
			F.pos = c + dir * floor
		end
	end
	F.cam.CFrame = CFrame.lookAt(F.pos, F.pos + F.look, localUp(F))
end

-- A coastline or mountain spot on Terra near a direction, found by sampling the surface.
local function findSpot(wantMountain: boolean): (Vector3, Vector3)
	local terra = Bodies.get("terra")
	local best, bestScore = Vector3.new(0, 0, 1), -math.huge
	for k = 0, 600 do
		local u = k / 600
		local ang = u * 40
		local x = math.cos(ang) * (0.2 + 0.6 * u)
		local y = math.sin(ang * 1.7) * 0.4
		local z = 1
		local d = Vector3.new(x, y, z).Unit
		local h = surfaceHeight(terra, d)
		local score
		if wantMountain then
			score = h
		else
			-- a coast: land just above sea level with sea close by
			local d2 = (d + Vector3.new(0.004, 0, 0)).Unit
			local h2 = surfaceHeight(terra, d2)
			score = if h > 0.3 and h < 3 and h2 <= 0 then 10 - h else -math.huge
		end
		if score > bestScore then
			best, bestScore = d, score
		end
	end
	local right = best:Cross(Vector3.yAxis).Unit
	return best, right
end

-- Presets: 1 orbit, 2 approach, 3 coast at 25 studs, 4 mountains, 5 Selene, 6 Saturnia.
function Flight.preset(F: Flight, i: number)
	local terra = Bodies.get("terra")
	local R = terra.radius
	if i == 1 then
		Flight.teleport(F, Vector3.new(0, R * 0.4, R * 3.4), Vector3.zero)
	elseif i == 2 then
		Flight.teleport(F, Vector3.new(R * 0.5, R * 0.35, R * 1.55), Vector3.new(0, 0, 0))
	elseif i == 3 or i == 4 then
		local d, right = findSpot(i == 4)
		local h = surfaceHeight(terra, d)
		local pos = d * (R + h + (if i == 4 then 60 else 25))
		Flight.teleport(F, pos, pos + right * 400 - d * 30)
	elseif i == 5 then
		local s = Bodies.get("selene")
		local c = Vector3.new(s.px, s.py, s.pz)
		Flight.teleport(F, c + Vector3.new(s.radius * 1.2, s.radius * 0.5, s.radius * 1.1), c)
	elseif i == 6 then
		local s = Bodies.get("saturnia")
		local c = Vector3.new(s.px, s.py, s.pz)
		Flight.teleport(F, c + Vector3.new(-s.radius * 3.2, s.radius * 1.1, s.radius * 3.6), c)
	end
	Flight.update(F, 0)
end

return Flight
