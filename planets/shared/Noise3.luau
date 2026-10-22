--!strict
--!native
--!optimize 2
-- Universe at Home: Planets :: Noise3
--
-- Deterministic 3D simplex noise (Gustavson's formulation, kernel radius^2 0.6, scale 32)
-- over a seeded permutation, and the sums built on it. Points on a planet are 3D unit
-- vectors, so 3D noise gives a surface with no seams and no pole pinching: every patch,
-- face and resolution samples the same field.
--
-- Determinism: only + - * floor, floor-mod and table reads, so a given (seed, x, y, z)
-- gives the same bits in the interpreter, under native code and on every device. The
-- permutation is shuffled with MyMath.hash32, never math.random.
--
-- Cost in the client interpreter is what bounds the planet: one octave is about 70
-- operations, so the generators budget octaves by resolution (see TileGen).

local MyMath = require("../Universe/MyMath")

local Noise3 = {}

export type Field = {
	perm: { number }, -- 512 entries 0..255 (the shuffle twice), index i + 1
	perm12: { number }, -- perm % 12, the gradient index
	seed: number,
}

-- the 12 edge gradients of a cube
local GX = { 1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0 }
local GY = { 1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1 }
local GZ = { 0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1 }

local F3 = 1 / 3
local G3 = 1 / 6
local G3x2 = 2 / 6
local G3x3m1 = 3 / 6 - 1

function Noise3.new(seed: number): Field
	local p = table.create(256, 0)
	for i = 0, 255 do
		p[i + 1] = i
	end
	local s = MyMath.u32(seed)
	for i = 255, 1, -1 do
		local h = MyMath.hash32(bit32.bxor(s, MyMath.u32(i * 2654435761)))
		local j = h % (i + 1)
		p[i + 1], p[j + 1] = p[j + 1], p[i + 1]
	end
	local perm = table.create(512, 0)
	local perm12 = table.create(512, 0)
	for i = 0, 511 do
		local v = p[(i % 256) + 1]
		perm[i + 1] = v
		perm12[i + 1] = v % 12
	end
	return { perm = perm, perm12 = perm12, seed = seed }
end

-- Simplex noise at (x, y, z), in about [-1, 1].
local function simplex(F: Field, x: number, y: number, z: number): number
	local perm, perm12 = F.perm, F.perm12
	local s = (x + y + z) * F3
	local i = (x + s) // 1
	local j = (y + s) // 1
	local k = (z + s) // 1
	local t = (i + j + k) * G3
	local x0 = x - (i - t)
	local y0 = y - (j - t)
	local z0 = z - (k - t)
	local i1, j1, k1, i2, j2, k2
	if x0 >= y0 then
		if y0 >= z0 then
			i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 1, 0
		elseif x0 >= z0 then
			i1, j1, k1, i2, j2, k2 = 1, 0, 0, 1, 0, 1
		else
			i1, j1, k1, i2, j2, k2 = 0, 0, 1, 1, 0, 1
		end
	else
		if y0 < z0 then
			i1, j1, k1, i2, j2, k2 = 0, 0, 1, 0, 1, 1
		elseif x0 < z0 then
			i1, j1, k1, i2, j2, k2 = 0, 1, 0, 0, 1, 1
		else
			i1, j1, k1, i2, j2, k2 = 0, 1, 0, 1, 1, 0
		end
	end
	local x1 = x0 - i1 + G3
	local y1 = y0 - j1 + G3
	local z1 = z0 - k1 + G3
	local x2 = x0 - i2 + G3x2
	local y2 = y0 - j2 + G3x2
	local z2 = z0 - k2 + G3x2
	local x3 = x0 + G3x3m1
	local y3 = y0 + G3x3m1
	local z3 = z0 + G3x3m1
	local ii = i % 256
	local jj = j % 256
	local kk = k % 256
	local n = 0
	local t0 = 0.6 - x0 * x0 - y0 * y0 - z0 * z0
	if t0 > 0 then
		local g = perm12[ii + perm[jj + perm[kk + 1] + 1] + 1] + 1
		t0 *= t0
		n += t0 * t0 * (GX[g] * x0 + GY[g] * y0 + GZ[g] * z0)
	end
	local t1 = 0.6 - x1 * x1 - y1 * y1 - z1 * z1
	if t1 > 0 then
		local g = perm12[ii + i1 + perm[jj + j1 + perm[kk + k1 + 1] + 1] + 1] + 1
		t1 *= t1
		n += t1 * t1 * (GX[g] * x1 + GY[g] * y1 + GZ[g] * z1)
	end
	local t2 = 0.6 - x2 * x2 - y2 * y2 - z2 * z2
	if t2 > 0 then
		local g = perm12[ii + i2 + perm[jj + j2 + perm[kk + k2 + 1] + 1] + 1] + 1
		t2 *= t2
		n += t2 * t2 * (GX[g] * x2 + GY[g] * y2 + GZ[g] * z2)
	end
	local t3 = 0.6 - x3 * x3 - y3 * y3 - z3 * z3
	if t3 > 0 then
		local g = perm12[ii + 1 + perm[jj + 1 + perm[kk + 2] + 1] + 1] + 1
		t3 *= t3
		n += t3 * t3 * (GX[g] * x3 + GY[g] * y3 + GZ[g] * z3)
	end
	return 32 * n
end
Noise3.simplex = simplex

-- Per-octave offsets: each octave samples a shifted copy of the field, so lattice
-- directions of successive octaves do not line up.
local OX: { number } = {}
local OY: { number } = {}
local OZ: { number } = {}
for o = 1, 32 do
	OX[o] = (o - 1) * 17.31
	OY[o] = (o - 1) * -9.77
	OZ[o] = (o - 1) * 23.03
end

-- Fractal sum of `octaves` octaves starting at frequency `freq`. `octaves` may be
-- fractional: the last octave is weighted by the fraction, so detail fades in smoothly as
-- a patch refines instead of popping. Amplitudes are not normalised.
function Noise3.fbm(F: Field, x: number, y: number, z: number, freq: number, octaves: number, gain: number): number
	local n = octaves // 1
	local frac = octaves - n
	local sum, amp, f = 0, 1, freq
	for o = 1, n do
		sum += amp * simplex(F, x * f + OX[o], y * f + OY[o], z * f + OZ[o])
		amp *= gain
		f *= 2
	end
	if frac > 0 and n < 32 then
		local o = n + 1
		sum += frac * amp * simplex(F, x * f + OX[o], y * f + OY[o], z * f + OZ[o])
	end
	return sum
end

-- Ridged multifractal (Musgrave): sharp crests from 1 - |n|, each octave weighted by the
-- previous one so detail gathers on the ridges. Result in [0, about 1.2].
function Noise3.ridged(F: Field, x: number, y: number, z: number, freq: number, octaves: number, gain: number): number
	local n = octaves // 1
	local frac = octaves - n
	local sum, amp, f, w = 0, 0.5, freq, 1
	local last = if frac > 0 and n < 32 then n + 1 else n
	for o = 1, last do
		local v = simplex(F, x * f + OX[o], y * f + OY[o], z * f + OZ[o])
		v = 1 - (if v < 0 then -v else v)
		v = v * v * w
		w = v * 2
		if w > 1 then
			w = 1
		end
		local a = if o > n then amp * frac else amp
		sum += v * a
		amp *= gain
		f *= 2
	end
	return sum
end

-- Number of octaves (fractional) whose lattice spacing stays above `minSpacing` (in the
-- same units as 1 / freq), capped at `maxOctaves`: the octaves a sampling grid of that
-- spacing can represent without aliasing.
function Noise3.octavesFor(freq: number, minSpacing: number, maxOctaves: number): number
	-- octave o (1-based) has spacing 1 / (freq * 2^(o-1)); keep spacing >= 2 * minSpacing
	local limit = 1 / (2 * minSpacing * freq)
	if limit <= 1 then
		return 1
	end
	-- log2 by repeated halving: deterministic and cheap for the small values used here
	local o = 1
	local v = limit
	while v >= 2 and o < maxOctaves do
		v *= 0.5
		o += 1
	end
	-- fractional part from the remaining factor v in [1, 2)
	local frac = v - 1
	local octaves = o + frac
	return if octaves > maxOctaves then maxOctaves else octaves
end

return Noise3
