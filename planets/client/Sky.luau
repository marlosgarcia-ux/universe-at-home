--!strict
-- Universe at Home: Planets :: Sky
--
-- The backdrop: six star faces for the Sky (Sky.Skybox*Content takes EditableImages), the
-- sun as a glowing billboard along Lighting:GetSunDirection(), and the engine's Atmosphere
-- thickened as the camera descends towards Terra (the impostor's halo hands over to it
-- inside the atmosphere). Generation runs on the workers; pixels go through the Uploader.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Planets = ReplicatedStorage:WaitForChild("Planets")
local WorkerPool = require(Planets:WaitForChild("WorkerPool")) :: any
local MeshPool = require(script.Parent:WaitForChild("MeshPool"))
local Uploader = require(script.Parent:WaitForChild("Uploader"))

local Sky = {}

local FACE = 512
local SUN = 256
local SUN_DISTANCE = 3900

export type SkyState = {
	faces: { EditableImage },
	sunImg: EditableImage?,
	sunAnchor: Part,
	sunGui: BillboardGui,
	atmosphere: Atmosphere,
	pixels: number,
	note: string,
}

local PROPS = { "SkyboxRightContent", "SkyboxLeftContent", "SkyboxUpContent", "SkyboxDownContent", "SkyboxFrontContent", "SkyboxBackContent" }

function Sky.new(U: Uploader.Uploader, workers: any, folder: Instance): SkyState
	local sky: Instance? = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		local s = Instance.new("Sky")
		s.Parent = Lighting
		sky = s
	end
	pcall(function()
		(sky :: any).CelestialBodiesShown = false;
		(sky :: any).StarCount = 0
	end)
	local faces: { EditableImage } = {}
	local pixels = 0
	local note = "six star faces of " .. FACE .. " px"
	for f = 1, 6 do
		local img = MeshPool.createImage(FACE, FACE)
		if img then
			faces[f] = img
			pixels += FACE * FACE
			local entry = Uploader.register(U, "sky face " .. f, img)
			pcall(function()
				(sky :: any)[PROPS[f]] = Content.fromObject(img)
			end)
			WorkerPool.submit(workers, "skyFace", { face = f, n = FACE, seed = 5 }, function(ok: boolean, buf: any)
				if ok then
					Uploader.queue(U, entry, 0, 0, FACE, FACE, buf)
				end
			end)
		else
			note = "star faces refused by the memory budget (" .. (f - 1) .. " of 6)"
			break
		end
	end
	-- the sun
	local sunImg = MeshPool.createImage(SUN, SUN)
	local anchor = Instance.new("Part")
	anchor.Name = "Sun"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.LightInfluence = 0
	gui.Brightness = 4
	gui.AlwaysOnTop = false
	gui.Adornee = anchor
	local half = SUN_DISTANCE * math.tan(math.rad(3))
	gui.Size = UDim2.fromScale(2 * half, 2 * half)
	gui.Parent = anchor
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = gui
	if sunImg then
		pixels += SUN * SUN
		label.ImageContent = Content.fromObject(sunImg)
		local entry = Uploader.register(U, "sun", sunImg)
		WorkerPool.submit(workers, "sun", { n = SUN, core = 0.2 }, function(ok: boolean, buf: any)
			if ok then
				Uploader.queue(U, entry, 0, 0, SUN, SUN, buf)
			end
		end)
	end
	-- the engine's atmosphere, used only near Terra's surface
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atm then
		local a = Instance.new("Atmosphere")
		a.Parent = Lighting
		atm = a
	end
	local a = atm :: Atmosphere
	a.Density = 0
	a.Offset = 0.05
	a.Color = Color3.fromRGB(150, 190, 255)
	a.Decay = Color3.fromRGB(110, 120, 160)
	a.Glare = 0.3
	a.Haze = 1.2
	return { faces = faces, sunImg = sunImg, sunAnchor = anchor, sunGui = gui, atmosphere = a, pixels = pixels, note = note }
end

-- Per frame: the sun billboard follows the engine's sun; the Atmosphere follows altitude.
function Sky.update(S: SkyState, cam: Camera, terraAltitude: number, terraRadius: number)
	local sun = Lighting:GetSunDirection()
	local camPos = cam.CFrame.Position
	S.sunAnchor.CFrame = CFrame.new(camPos + sun * SUN_DISTANCE)
	-- thick near the ground, gone above a tenth of the radius
	local k = math.clamp(1 - terraAltitude / (terraRadius * 0.1), 0, 1)
	S.atmosphere.Density = 0.38 * k * k
end

return Sky
