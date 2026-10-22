--!strict
--!native
--!optimize 2
-- Universe at Home: Meadow :: SkyGen
--
-- The six skybox faces, rendered on the server (native codegen) and baked with
-- AssetService:CreateDataModelContentAsync into Sky.Skybox*Content (docs/DEMO.md
-- section 2). Pure and deterministic.
--
-- Orientation. The mapping from a skybox face pixel to a view direction is NOT
-- PUBLICLY SPECIFIED. This sky is therefore a function of elevation only: side faces
-- depend only on the pixel row (row 0 is the top, the one safe assumption), the up
-- and down faces only on the distance to their centre. Whatever the engine's face
-- rotations are, the faces meet without seams. Azimuthal detail comes from the
-- engine: the Sun (Sky.CelestialBodiesShown), Atmosphere scattering toward the sun,
-- and dynamic Clouds.
--
-- Colour model: a golden-hour gradient (ground haze, warm horizon band, mid blue,
-- zenith) whose warmth follows the sun elevation, plus +-1/2 LSB hash dither so the
-- smooth gradient never bands after 8-bit quantisation.

local MyMath = require("../Universe/MyMath")

local SkyGen = {}

SkyGen.FACES = { "Bk", "Dn", "Ft", "Lf", "Rt", "Up" }
-- Sky property per face
SkyGen.PROPERTY = {
	Bk = "SkyboxBackContent",
	Dn = "SkyboxDownContent",
	Ft = "SkyboxFrontContent",
	Lf = "SkyboxLeftContent",
	Rt = "SkyboxRightContent",
	Up = "SkyboxUpContent",
}

local sqrt = math.sqrt
local floor = math.floor

export type Params = {
	zenith: { number },
	mid: { number },
	horizon: { number },
	ground: { number },
	sunGlow: { number },
}

-- Elevation (sine of the angle above the horizon, -1..1) of face pixel centre
-- (i, j) on a size x size face.
function SkyGen.elevation(face: string, i: number, j: number, size: number): number
	local u = (i + 0.5) / size * 2 - 1
	local v = (j + 0.5) / size * 2 - 1
	if face == "Up" or face == "Dn" then
		local y = if face == "Up" then 1 else -1
		return y / sqrt(u * u + v * v + 1)
	end
	-- side faces: row v from top (+1 up) to bottom; only the vertical component matters
	return -v / sqrt(u * u + v * v + 1)
end

local function mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- RGB (0..255, fractional) of the sky at elevation e for a sun at elevation sunE.
function SkyGen.colorAt(e: number, sunE: number, p: Params): (number, number, number)
	-- warmth: 1 when the sun touches the horizon, 0 when it is high
	local warm = 1 - MyMath.smoothstep(0.05, 0.6, sunE)
	local hz = p.horizon
	local md = p.mid
	local zn = p.zenith
	local gl = p.sunGlow
	local gr = p.ground
	local r, g, b
	if e >= 0 then
		-- horizon band -> mid sky -> zenith
		local t1 = MyMath.smoothstep(0, 0.32, e)
		local t2 = MyMath.smoothstep(0.18, 1, e)
		r = mix(mix(hz[1], md[1], t1), zn[1], t2)
		g = mix(mix(hz[2], md[2], t1), zn[2], t2)
		b = mix(mix(hz[3], md[3], t1), zn[3], t2)
		-- golden glow hugging the horizon, stronger when the sun is low
		local band = 1 - MyMath.smoothstep(0, 0.22, e)
		local glow = band * band * warm * 0.55
		r = mix(r, gl[1], glow)
		g = mix(g, gl[2], glow)
		b = mix(b, gl[3], glow)
	else
		-- below the horizon: haze fading to the ground colour
		local t = MyMath.smoothstep(0, 0.35, -e)
		r = mix(hz[1], gr[1], t)
		g = mix(hz[2], gr[2], t)
		b = mix(hz[3], gr[3], t)
	end
	return r, g, b
end

-- Renders one face into an RGBA8 buffer (opaque). Deterministic: dither from MyMath.hash2.
function SkyGen.renderFace(face: string, size: number, sunE: number, p: Params, out: buffer?): buffer
	local buf = out or buffer.create(size * size * 4)
	local hash2 = MyMath.hash2
	local seed = 0
	for c = 1, #face do
		seed = seed * 131 + string.byte(face, c)
	end
	for j = 0, size - 1 do
		local o = j * size * 4
		for i = 0, size - 1 do
			local e = SkyGen.elevation(face, i, j, size)
			local r, g, b = SkyGen.colorAt(e, sunE, p)
			local h = hash2(i, j, seed)
			local d1 = (h % 256) / 256 - 0.5
			local d2 = ((h // 256) % 256) / 256 - 0.5
			local d3 = ((h // 65536) % 256) / 256 - 0.5
			local R = floor(r + 0.5 + d1)
			local G = floor(g + 0.5 + d2)
			local B = floor(b + 0.5 + d3)
			R = if R < 0 then 0 elseif R > 255 then 255 else R
			G = if G < 0 then 0 elseif G > 255 then 255 else G
			B = if B < 0 then 0 elseif B > 255 then 255 else B
			buffer.writeu32(buf, o, R + G * 256 + B * 65536 + 0xFF000000)
			o += 4
		end
	end
	return buf
end

function SkyGen.selfTest(): (boolean, string?)
	local p: Params = {
		zenith = { 64, 108, 176 },
		mid = { 132, 168, 214 },
		horizon = { 246, 196, 140 },
		ground = { 120, 110, 100 },
		sunGlow = { 255, 190, 110 },
	}
	local a = SkyGen.renderFace("Rt", 32, 0.1, p)
	local b = SkyGen.renderFace("Rt", 32, 0.1, p)
	if buffer.tostring(a) ~= buffer.tostring(b) then
		return false, "sky face not deterministic"
	end
	-- seams: the bottom row of the up face's edge and the top row of a side face both
	-- sit at elevation sin(45 deg) at their midpoints (cube edge)
	local eUp = SkyGen.elevation("Up", 16, 0, 32)
	local eSide = SkyGen.elevation("Ft", 16, 0, 32)
	if math.abs(eUp - eSide) > 0.03 then
		return false, string.format("edge elevations differ: %.3f vs %.3f", eUp, eSide)
	end
	-- zenith bluer than the horizon, opaque everywhere
	local top = buffer.readu32(SkyGen.renderFace("Up", 8, 0.1, p), (4 * 8 + 4) * 4)
	local tr, tg, tb, ta = MyMath.unpack(top)
	if not (tb > tr and ta == 255) then
		return false, "zenith colour"
	end
	local _ = tg
	-- every face of every side is the same image up to dither: rotation invariance
	local f1 = SkyGen.renderFace("Lf", 16, 0.1, p)
	local f2 = SkyGen.renderFace("Bk", 16, 0.1, p)
	for o = 0, 16 * 16 * 4 - 4, 4 do
		local r1, g1, b1 = MyMath.unpack(buffer.readu32(f1, o))
		local r2, g2, b2 = MyMath.unpack(buffer.readu32(f2, o))
		if math.abs(r1 - r2) > 1 or math.abs(g1 - g2) > 1 or math.abs(b1 - b2) > 1 then
			return false, "side faces differ beyond dither"
		end
	end
	return true, nil
end

return SkyGen
