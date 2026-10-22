--!strict
-- Universe at Home: Meadow :: Environment
--
-- Runtime half of the look. The project file sets what scripts cannot
-- (Lighting.Technology, Terrain.Decoration, Terrain.GrassLength are NotScriptable)
-- and the effect instances; this module sets the scriptable rest, recreates any
-- effect that is missing (so an edited place still looks right) and reports.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Demo = ReplicatedStorage:WaitForChild("Demo")
local Config = require(Demo:WaitForChild("Config"))

local Environment = {}

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function ensure(parent: Instance, className: string, name: string, init: (Instance) -> ()): (Instance, boolean)
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing, false
	end
	local inst = Instance.new(className)
	inst.Name = name
	init(inst)
	inst.Parent = parent
	return inst, true
end

-- Returns a one-line summary; throws only on unexpected engine errors.
function Environment.apply(): string
	local notes: { string } = {}
	Lighting.ClockTime = Config.lighting.clockTime
	Lighting.GeographicLatitude = Config.lighting.geographicLatitude

	local created = 0
	local _, c1 = ensure(Lighting, "Atmosphere", "Atmosphere", function(i: Instance)
		local a = i :: Atmosphere
		a.Density = 0.32
		a.Offset = 0.12
		a.Color = Color3.fromRGB(214, 190, 168)
		a.Decay = Color3.fromRGB(120, 104, 112)
		a.Glare = 0.45
		a.Haze = 1.6
	end)
	local _, c2 = ensure(Lighting, "Sky", "Sky", function(i: Instance)
		local s = i :: Sky
		s.CelestialBodiesShown = true
		s.SunAngularSize = 14
		s.StarCount = 1500
	end)
	local _, c3 = ensure(Lighting, "BloomEffect", "Bloom", function(i: Instance)
		local b = i :: BloomEffect
		b.Intensity = 0.6
		b.Size = 28
		b.Threshold = 1.4
	end)
	local _, c4 = ensure(Lighting, "SunRaysEffect", "SunRays", function(i: Instance)
		local s = i :: SunRaysEffect
		s.Intensity = 0.06
		s.Spread = 0.55
	end)
	local _, c5 = ensure(Lighting, "ColorCorrectionEffect", "ColorCorrection", function(i: Instance)
		local c = i :: ColorCorrectionEffect
		c.Brightness = 0.02
		c.Contrast = 0.12
		c.Saturation = 0.12
		c.TintColor = Color3.fromRGB(255, 244, 230)
	end)
	local _, c6 = ensure(Lighting, "DepthOfFieldEffect", "DepthOfField", function(i: Instance)
		local d = i :: DepthOfFieldEffect
		d.FarIntensity = 0.12
		d.FocusDistance = 40
		d.InFocusRadius = 60
		d.NearIntensity = 0
	end)
	for _, c in { c1, c2, c3, c4, c5, c6 } do
		if c then
			created += 1
		end
	end
	if created > 0 then
		table.insert(notes, string.format("%d effect(s) were missing and were recreated", created))
	end

	local terrain = Workspace.Terrain
	local t = Config.terrain
	terrain.WaterColor = rgb(t.waterColor)
	terrain.WaterTransparency = t.waterTransparency
	terrain.WaterReflectance = t.waterReflectance
	terrain.WaterWaveSize = t.waterWaveSize
	terrain.WaterWaveSpeed = t.waterWaveSpeed
	local colored = 0
	for name, color in (t.materialColors :: { [string]: { number } }) do
		local ok = pcall(function()
			terrain:SetMaterialColor((Enum.Material :: any)[name], rgb(color))
		end)
		if ok then
			colored += 1
		else
			table.insert(notes, "SetMaterialColor failed for " .. name)
		end
	end
	ensure(terrain, "Clouds", "Clouds", function(i: Instance)
		local c = i :: Clouds
		c.Cover = 0.58
		c.Density = 0.72
		c.Color = Color3.fromRGB(255, 238, 222)
	end)
	-- Terrain.Decoration and GrassLength are NotScriptable (API dump): they come from the
	-- project file and cannot even be read here.
	table.insert(notes, string.format("ClockTime %.2f, %d material colours", Lighting.ClockTime, colored))
	return table.concat(notes, "; ")
end

return Environment
