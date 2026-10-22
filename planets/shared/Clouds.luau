--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Clouds
--
-- Terra's cloud field: coverage 0..1 at a unit direction, as a pure function. The cloud
-- layer mesh (six faces in one 1024 x 512 atlas) and the planet's impostor both sample
-- this function, so the clouds seen from orbit are the clouds seen from below.
--
-- Shape: domain-warped fractal noise thresholded into cloud banks, modulated by latitude
-- belts (wet at the equator and around 60 degrees, dry around 25 degrees).

local Noise3 = require("./Noise3")
local CubeSphere = require("./CubeSphere")
local Layout = require("./Layout")
local MyMath = require("../Universe/MyMath")

local Clouds = {}

local F1 = Noise3.new(9001)
local F2 = Noise3.new(9002)
local smoothstep = MyMath.smoothstep

-- Coverage at (x, y, z). `spacing` (radians) is the sampling pitch of the caller: octaves
-- finer than it are left out, as for the terrain, so a coarse cache holds a smooth field
-- instead of aliased, blocky banks (default: the cloud layer's own texel pitch).
--
-- The warp is kept gentle on purpose: a domain warp multiplies the local frequency of the
-- warped field by (1 + warp amplitude x warp slope). At 0.55 x fbm(1.6, 3 octaves) that
-- factor reached about 35 and no octave budget could band-limit the result (measured:
-- coverage jumping from 0.78 to 0 across 0.004 rad, blocky in any cache). Here the warp's
-- slope is at most 12.8 x (1.3 + 2.6 x 0.5) = 33 per radian, times 0.16: a factor below 6,
-- and the octave budget is taken at 1.5x the pitch to leave room for it.
function Clouds.density(x: number, y: number, z: number, spacing: number?): number
	local pitch = spacing or (math.pi / 2) / Layout.CLOUD_SPAN
	local octaves = Noise3.octavesFor(2.4, pitch * 1.5, 6)
	local w = Noise3.fbm(F2, x, y, z, 1.3, 2, 0.5)
	local d = Noise3.fbm(F1, x + 0.16 * w, y + 0.10 * w, z - 0.13 * w, 2.4, octaves, 0.55)
	local lat = math.abs(y)
	-- belts: +0.12 at the equator, -0.12 around 0.42 (25 degrees), +0.08 around 0.87
	local belt = 0.12 * (1 - smoothstep(0.0, 0.42, lat)) - 0.12 * smoothstep(0.2, 0.42, lat) * (1 - smoothstep(0.42, 0.7, lat)) + 0.08 * smoothstep(0.6, 0.87, lat)
	return smoothstep(0.15, 0.55, d + belt)
end

-- One face of the cloud layer as a CLOUD_TILE x CLOUD_TILE RGBA tile (straight alpha), with
-- the same texel-centre rule as the surface atlas: pixel k sits at face parameter
-- (k - GUTTER) / CLOUD_SPAN under Nowell's map, so the layer's six faces meet seamlessly.
function Clouds.face(f: number): buffer
	local T = Layout.CLOUD_TILE
	local span = Layout.CLOUD_SPAN
	local out = buffer.create(T * T * 4)
	for r = 0, T - 1 do
		local b = (r - Layout.GUTTER) / span
		for k = 0, T - 1 do
			local a = (k - Layout.GUTTER) / span
			local x, y, z = CubeSphere.facePoint(f, a, b)
			local c = Clouds.density(x, y, z)
			-- thick cloud is slightly grey underneath
			local g = (255 - 40 * c * c) // 1
			local alpha = (c * 255 + 0.5) // 1
			buffer.writeu32(out, (r * T + k) * 4, g + g * 256 + g * 65536 + alpha * 16777216)
		end
	end
	return out
end

-- Cloud atlas placement of face f (1..6): tile column and row in the 4 x 2 atlas.
function Clouds.tileOf(f: number): (number, number)
	return (f - 1) % 4, (f - 1) // 4
end

return Clouds
