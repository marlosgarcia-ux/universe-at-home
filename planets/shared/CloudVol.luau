--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: CloudVol
--
-- Volumetric clouds, baked. A cloud layer is a spherical slab h0..h1 studs above the sea. For
-- every texel of a cube face, the bake marches straight up through the slab, sampling a 3D
-- density (a column-coverage field gives the cloud banks, a vertical profile rounds their
-- tops and flattens their bellies, 3D noise erodes the edges into billows) and, at every
-- step, marches towards the sun through the cloud above it for the light that arrives.
--
--   alpha   1 - exp(-tau) with tau the optical depth of the whole column: thin cloud is
--           translucent, thick cloud opaque, with soft edges
--   colour  the layer tint times the column's density-weighted lit fraction: tops and thin
--           edges bright, thick bellies grey (self-shadowing, with a powder term that darkens
--           the cores of thin clouds less than a plain Beer's law would)
--
-- The result is an RGBA8 tile that the engine draws on a shell with its own lighting on top
-- (sun against the shell's normal: day, night and terminator come for free). Only the
-- self-shadowing is baked, for the sun direction given to the bake, so the server is meant to
-- re-bake when the sun has moved (planets/server, not written yet: docs/HANDOFF.md). Several
-- layers stacked at different heights give
-- parallax: flying between them, the clouds move against each other and against the ground.
--
-- The same texel-centre rule as the surface atlas (Layout): texel k of an n-pixel tile is at
-- face parameter (k - 1) / (n - 3), so two faces meet along identical sphere points.
-- Cost, measured in the Luau CLI with native codegen: 0.45 to 0.6 s per 256 x 256 face and
-- layer, so about 2 s at 512. Six faces and three layers at 512 is about 40 s of one core.

local Noise3 = require("./Noise3")
local CubeSphere = require("./CubeSphere")
local MyMath = require("../Universe/MyMath")

local CloudVol = {}

export type Layer = {
	name: string,
	h0: number, -- studs above sea level
	h1: number,
	scale: number, -- bank frequency on the unit sphere
	erodeFreq: number,
	erode: number, -- 0..1 strength of the billow erosion
	cover: number, -- threshold of the coverage field (higher = fewer clouds)
	sigma: number, -- extinction per stud at full density
	tintR: number,
	tintG: number,
	tintB: number,
	spin: number, -- radians per second of the shell
	seed: number,
}

local smoothstep = MyMath.smoothstep
local sqrt, exp = math.sqrt, math.exp

-- Up to three layers: low cumulus, mid altocumulus, high wispy cirrus.
function CloudVol.layers(count: number): { Layer }
	local all: { Layer } = {
		{ name = "low", h0 = 12, h1 = 34, scale = 2.2, erodeFreq = 16, erode = 0.55, cover = 0.52, sigma = 0.34, tintR = 1, tintG = 1, tintB = 1, spin = 0.0035, seed = 9001 },
		{ name = "mid", h0 = 46, h1 = 62, scale = 3.1, erodeFreq = 24, erode = 0.5, cover = 0.62, sigma = 0.3, tintR = 0.98, tintG = 0.98, tintB = 1, spin = 0.0052, seed = 9101 },
		{ name = "high", h0 = 84, h1 = 90, scale = 4.6, erodeFreq = 34, erode = 0.42, cover = 0.68, sigma = 0.22, tintR = 0.97, tintG = 0.98, tintB = 1, spin = 0.0083, seed = 9201 },
	}
	local out: { Layer } = {}
	for i = 1, math.min(count, #all) do
		out[i] = all[i]
	end
	return out
end

local fields: { [number]: { Noise3.Field } } = {}
local function fieldsFor(seed: number): { Noise3.Field }
	local f = fields[seed]
	if not f then
		f = { Noise3.new(seed), Noise3.new(seed + 1), Noise3.new(seed + 2) }
		fields[seed] = f
	end
	return f
end

-- Column coverage 0..1 at a unit direction: the banks of this layer.
local function column(F: { Noise3.Field }, layer: Layer, x: number, y: number, z: number): number
	local w = Noise3.fbm(F[2], x, y, z, 1.3, 2, 0.5)
	local c = Noise3.fbm(F[1], x + 0.16 * w, y + 0.1 * w, z - 0.13 * w, layer.scale, 4, 0.5)
	local lat = math.abs(y)
	-- wet at the equator and in the mid latitudes, dry around 25 degrees
	local belt = 0.1 * (1 - smoothstep(0, 0.42, lat)) - 0.1 * smoothstep(0.2, 0.42, lat) * (1 - smoothstep(0.42, 0.7, lat)) + 0.07 * smoothstep(0.6, 0.87, lat)
	return smoothstep(layer.cover - 0.22, layer.cover + 0.22, c * 0.55 + 0.5 + belt)
end
CloudVol.column = column

-- Density 0..1 at height fraction hN in the slab above a column of coverage `base`.
local function density(F: { Noise3.Field }, layer: Layer, x: number, y: number, z: number, hN: number, base: number): number
	if base <= 0 or hN <= 0 or hN >= 1 then
		return 0
	end
	-- belly flat and soft, top rounded; thicker banks (high coverage) reach higher
	local profile = smoothstep(0, 0.16, hN) * smoothstep(1, 0.3 + 0.4 * base, hN)
	local e = Noise3.fbm(F[3], x, y, z, layer.erodeFreq, 3, 0.5) * 0.5 + 0.5 + hN * 0.35
	local d = base * profile - e * layer.erode * (1 - 0.5 * base)
	return smoothstep(0, 0.3, d)
end
CloudVol.density = density

-- Bakes face `face` (1..6) of `layer` into an n x n RGBA8 buffer (straight alpha). The sun
-- is a unit vector (sx, sy, sz) towards the sun; R is the planet radius. `steps` samples
-- through the slab (default 6), 2 towards the sun from each.
function CloudVol.bakeFace(R: number, layer: Layer, face: number, n: number, sx: number, sy: number, sz: number, steps: number?): buffer
	local K = steps or 6
	local out = buffer.create(n * n * 4)
	local F = fieldsFor(layer.seed)
	local thick = layer.h1 - layer.h0
	local ds = thick / K
	local span = n - 3
	local sigma = layer.sigma
	local lightStep = thick * 0.5
	for r = 0, n - 1 do
		local b = (r - 1) / span
		for k = 0, n - 1 do
			local a = (k - 1) / span
			local x, y, z = CubeSphere.facePoint(face, a, b)
			local base = column(F, layer, x, y, z)
			local tau, litSum, wSum = 0, 0, 0
			if base > 0.003 then
				for q = 0, K - 1 do
					local hN = (q + 0.5) / K
					local rho = density(F, layer, x, y, z, hN, base)
					if rho > 0.002 then
						-- light: towards the sun through the cloud above this sample
						local rad = R + layer.h0 + hN * thick
						local px, py, pz = x * rad, y * rad, z * rad
						local od = 0
						for m = 1, 2 do
							local qx, qy, qz = px + sx * lightStep * m, py + sy * lightStep * m, pz + sz * lightStep * m
							local ql = sqrt(qx * qx + qy * qy + qz * qz)
							local hm = (ql - R - layer.h0) / thick
							if hm >= 1 then
								break -- left the slab through its top: nothing more in the way
							end
							if hm > 0 then
								od += density(F, layer, qx / ql, qy / ql, qz / ql, hm, base) * lightStep * sigma * 0.3
							end
						end
						-- Beer's law with a powder term: dense cores do not darken to black
						local tl = exp(-od)
						local powder = 1 - 0.55 * exp(-2 * rho * sigma * ds * 3)
						local lit = tl * (0.6 + 0.4 * powder) + 0.4 * (1 - tl) -- multiple-scatter floor
						local w = rho * ds
						tau += rho * sigma * ds
						litSum += lit * w
						wSum += w
					end
				end
			end
			local o = (r * n + k) * 4
			if tau <= 0.0005 then
				buffer.writeu32(out, o, 0)
			else
				local alpha = 1 - exp(-tau)
				local shade = litSum / wSum
				if shade > 1 then
					shade = 1
				end
				local cr, cg, cb = layer.tintR * shade, layer.tintG * shade, layer.tintB * shade
				buffer.writeu32(out, o, ((cr * 255 + 0.5) // 1) + ((cg * 255 + 0.5) // 1) * 256 + ((cb * 255 + 0.5) // 1) * 65536 + ((alpha * 255 + 0.5) // 1) * 16777216)
			end
		end
	end
	return out
end

return CloudVol
