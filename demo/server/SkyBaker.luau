--!strict
-- Universe at Home: Meadow :: SkyBaker (server)
--
-- Renders the six SkyGen faces with native codegen, bakes each one and assigns the
-- baked Content to Lighting.Sky.Skybox*Content (replicates to every client). Any
-- failure leaves the Sky's default skybox in place (fallback) and says why.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))
local SkyGen = require(Demo:WaitForChild("SkyGen"))
local Status = require(Demo:WaitForChild("Status"))
local Bake = require(script.Parent:WaitForChild("Bake"))

local SkyBaker = {}

SkyBaker.keep = {} :: { EditableImage }

function SkyBaker.run(reg: Status.Registry): (Status.State, string)
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		local s = Instance.new("Sky")
		s.Parent = Lighting
		sky = s
	end
	assert(sky)
	local size = Config.sky.faceSize
	local sunE = Lighting:GetSunDirection().Y
	local t0 = os.clock()
	local contents: { [string]: Content } = {}
	local renderMs = 0
	for _, face in SkyGen.FACES do
		local r0 = os.clock()
		local pixels = SkyGen.renderFace(face, size, sunE, Config.sky :: any)
		renderMs += (os.clock() - r0) * 1000
		local content, img, why = Bake.pixels(size, size, pixels)
		if not content then
			if img then
				img:Destroy()
			end
			return "fallback", string.format("default sky: face %s not baked (%s)", face, tostring(why))
		end
		if img then
			table.insert(SkyBaker.keep, img)
		end
		contents[face] = content
		task.wait()
	end
	-- assign all six at once so the sky never shows a mix of faces (explicit property
	-- names so luau-lsp checks them against the API)
	local s = sky :: Sky
	s.SkyboxBackContent = contents.Bk
	s.SkyboxDownContent = contents.Dn
	s.SkyboxFrontContent = contents.Ft
	s.SkyboxLeftContent = contents.Lf
	s.SkyboxRightContent = contents.Rt
	s.SkyboxUpContent = contents.Up
	return "ok",
		string.format(
			"6 faces %dx%d baked; render %.0f ms (server), total %.1f s; sun elevation %.2f",
			size,
			size,
			renderMs,
			os.clock() - t0,
			sunE
		)
end

return SkyBaker
