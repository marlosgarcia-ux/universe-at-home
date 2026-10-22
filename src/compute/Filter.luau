--!native
--!optimize 2
-- universe-at-home :: compute/Filter
--
-- Filters whose cost does not depend on their size, all exact in integer
-- arithmetic (docs/COMPUTE.md 3.5):
--
--   boxBlur        separable box blur of radius r by running sums: per pixel and
--                  pass, add the pixel entering the window and subtract the one
--                  leaving it. Sums of 8-bit channels are kept two to a number in
--                  16-bit lanes (SWAR, 0x00FF00FF masks), r <= 127. The result is
--                  round(sum / (2r + 1)) by integer floor division: identical to
--                  the brute-force average (tests/compute.test.luau).
--   satBuild       summed-area table, one u32 plane per channel (exact: totals stay
--                  below 2^32 for 1024 x 1024 x 255).
--   satResample    area-average resampling to ANY size through the table: the
--                  integral of a piecewise-constant image over a rectangle with
--                  fractional corners is the bilinear interpolation of the
--                  summed-area table. Any footprint in O(1) (variable blur, LOD).
--   areaResample   the reference resampler: exact area average at any ratio with
--                  integer weights and exact rational rounding, separable, about
--                  4x faster than satResample. Artifact-free downscaling for LOD.
--   normalMap      height field to tangent-space normal map by central differences.
--
-- Edges clamp to the border pixel. Deterministic ops only.

local Filter = {}

local band, rshift = bit32.band, bit32.rshift

-- One horizontal running-sum pass of radius r from src (w x h) into dst.
local function boxPassH(src: buffer, dst: buffer, w: number, h: number, r: number)
	local n = 2 * r + 1
	local half = r -- (sum + r) // n rounds half down; n is odd so ties never occur
	for y = 0, h - 1 do
		local row = y * w * 4
		local first = buffer.readu32(src, row)
		local lastPx = buffer.readu32(src, row + (w - 1) * 4)
		-- window for x = 0 covers [-r, r], clamped: (r + 1) copies of pixel 0 ...
		local rb = band(first, 0x00FF00FF) * (r + 1)
		local ga = band(rshift(first, 8), 0x00FF00FF) * (r + 1)
		for k = 1, r do
			local p = buffer.readu32(src, row + (if k < w then k else w - 1) * 4)
			rb += band(p, 0x00FF00FF)
			ga += band(rshift(p, 8), 0x00FF00FF)
		end
		for x = 0, w - 1 do
			local rr = rb % 65536
			local bb = rb // 65536
			local gg = ga % 65536
			local aa = ga // 65536
			buffer.writeu32(
				dst,
				row + x * 4,
				(rr + half) // n + ((gg + half) // n) * 256 + ((bb + half) // n) * 65536 + ((aa + half) // n) * 16777216
			)
			-- slide: add pixel x + r + 1, remove pixel x - r (both clamped)
			local inX = x + r + 1
			local outX = x - r
			local pin = if inX < w then buffer.readu32(src, row + inX * 4) else lastPx
			local pout = if outX > 0 then buffer.readu32(src, row + outX * 4) else first
			rb += band(pin, 0x00FF00FF) - band(pout, 0x00FF00FF)
			ga += band(rshift(pin, 8), 0x00FF00FF) - band(rshift(pout, 8), 0x00FF00FF)
		end
	end
end

-- Vertical pass, walked row by row with per-column lane sums (row-major access).
local function boxPassV(src: buffer, dst: buffer, w: number, h: number, r: number)
	local n = 2 * r + 1
	local half = r
	local RB = table.create(w, 0)
	local GA = table.create(w, 0)
	local stride = w * 4
	for x = 0, w - 1 do
		local p = buffer.readu32(src, x * 4)
		RB[x + 1] = band(p, 0x00FF00FF) * (r + 1)
		GA[x + 1] = band(rshift(p, 8), 0x00FF00FF) * (r + 1)
	end
	for k = 1, r do
		local yy = if k < h then k else h - 1
		for x = 0, w - 1 do
			local p = buffer.readu32(src, yy * stride + x * 4)
			RB[x + 1] += band(p, 0x00FF00FF)
			GA[x + 1] += band(rshift(p, 8), 0x00FF00FF)
		end
	end
	for y = 0, h - 1 do
		local inY = y + r + 1
		local outY = y - r
		local inRow = (if inY < h then inY else h - 1) * stride
		local outRow = (if outY > 0 then outY else 0) * stride
		local row = y * stride
		for x = 0, w - 1 do
			local rb, ga = RB[x + 1], GA[x + 1]
			local rr = rb % 65536
			local bb = rb // 65536
			local gg = ga % 65536
			local aa = ga // 65536
			buffer.writeu32(
				dst,
				row + x * 4,
				(rr + half) // n + ((gg + half) // n) * 256 + ((bb + half) // n) * 65536 + ((aa + half) // n) * 16777216
			)
			local pin = buffer.readu32(src, inRow + x * 4)
			local pout = buffer.readu32(src, outRow + x * 4)
			RB[x + 1] = rb + band(pin, 0x00FF00FF) - band(pout, 0x00FF00FF)
			GA[x + 1] = ga + band(rshift(pin, 8), 0x00FF00FF) - band(rshift(pout, 8), 0x00FF00FF)
		end
	end
end

-- Box blur of radius r (1 <= r <= 127), horizontal then vertical, rounding after
-- each pass (so it equals two rounded 1D box filters, not one 2D mean).
function Filter.boxBlur(src: buffer, w: number, h: number, r: number, dst: buffer?): buffer
	assert(r >= 1 and r <= 127, "radius must be 1..127 (16-bit lanes)")
	local tmp = buffer.create(w * h * 4)
	local out = dst or buffer.create(w * h * 4)
	boxPassH(src, tmp, w, h, r)
	boxPassV(tmp, out, w, h, r)
	return out
end

-- Brute-force reference with the same per-pass rounding (tests only).
function Filter.boxBlurBrute(src: buffer, w: number, h: number, r: number): buffer
	local n = 2 * r + 1
	local tmp = buffer.create(w * h * 4)
	local out = buffer.create(w * h * 4)
	for pass = 1, 2 do
		local a = if pass == 1 then src else tmp
		local b = if pass == 1 then tmp else out
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local s0, s1, s2, s3 = 0, 0, 0, 0
				for k = -r, r do
					local xx, yy = x, y
					if pass == 1 then
						xx = math.clamp(x + k, 0, w - 1)
					else
						yy = math.clamp(y + k, 0, h - 1)
					end
					local p = buffer.readu32(a, (yy * w + xx) * 4)
					s0 += p % 256
					s1 += (p // 256) % 256
					s2 += (p // 65536) % 256
					s3 += p // 16777216
				end
				buffer.writeu32(
					b,
					(y * w + x) * 4,
					(s0 + r) // n + ((s1 + r) // n) * 256 + ((s2 + r) // n) * 65536 + ((s3 + r) // n) * 16777216
				)
			end
		end
	end
	return out
end

export type SAT = { w: number, h: number, planes: { buffer } }

-- Summed-area table with a zero row and column: S(x, y) = sum of pixels [0, x) x [0, y).
-- One u32 plane per channel, (w + 1) x (h + 1).
function Filter.satBuild(src: buffer, w: number, h: number): SAT
	local W1 = w + 1
	local planes = {}
	for c = 1, 4 do
		planes[c] = buffer.create(W1 * (h + 1) * 4)
	end
	local P0, P1, P2, P3 = planes[1], planes[2], planes[3], planes[4]
	for y = 1, h do
		local s0, s1, s2, s3 = 0, 0, 0, 0
		local srow = (y - 1) * w * 4
		local o = y * W1 * 4 + 4
		local up = o - W1 * 4
		for x = 1, w do
			local p = buffer.readu32(src, srow + (x - 1) * 4)
			s0 += p % 256
			s1 += (p // 256) % 256
			s2 += (p // 65536) % 256
			s3 += p // 16777216
			buffer.writeu32(P0, o, s0 + buffer.readu32(P0, up))
			buffer.writeu32(P1, o, s1 + buffer.readu32(P1, up))
			buffer.writeu32(P2, o, s2 + buffer.readu32(P2, up))
			buffer.writeu32(P3, o, s3 + buffer.readu32(P3, up))
			o += 4
			up += 4
		end
	end
	return { w = w, h = h, planes = planes }
end

-- Integral of one channel over [0, x] x [0, y] for real x, y (bilinear in S).
local function integral(P: buffer, W1: number, x: number, y: number): number
	local ix, iy = x // 1, y // 1
	local fx, fy = x - ix, y - iy
	local o = (iy * W1 + ix) * 4
	local s00 = buffer.readu32(P, o)
	if fx == 0 and fy == 0 then
		return s00
	end
	local s10 = if fx > 0 then buffer.readu32(P, o + 4) else s00
	local s01 = if fy > 0 then buffer.readu32(P, o + W1 * 4) else s00
	local s11 = if fx > 0 and fy > 0 then buffer.readu32(P, o + W1 * 4 + 4) else (if fx > 0 then s10 else s01)
	local top = s00 + (s10 - s00) * fx
	local bot = s01 + (s11 - s01) * fx
	return top + (bot - top) * fy
end
Filter.integral = integral

-- Exact area-average resample of the SAT's image to dw x dh: output pixel (i, j)
-- is the mean over the source rectangle [i * sx, (i + 1) * sx) x [j * sy, (j + 1) * sy).
function Filter.satResample(sat: SAT, dw: number, dh: number, dst: buffer?): buffer
	local w, h = sat.w, sat.h
	local W1 = w + 1
	local out = dst or buffer.create(dw * dh * 4)
	local sx, sy = w / dw, h / dh
	local inv = 1 / (sx * sy)
	local P = sat.planes
	local o = 0
	for j = 0, dh - 1 do
		local y0, y1 = j * sy, (j + 1) * sy
		if y1 > h then
			y1 = h
		end
		for i = 0, dw - 1 do
			local x0, x1 = i * sx, (i + 1) * sx
			if x1 > w then
				x1 = w
			end
			local px = 0
			local mul = 1
			for c = 1, 4 do
				local pl = P[c]
				local s = integral(pl, W1, x1, y1) - integral(pl, W1, x0, y1) - integral(pl, W1, x1, y0) + integral(pl, W1, x0, y0)
				local v = (s * inv + 0.5) // 1
				v = if v < 0 then 0 elseif v > 255 then 255 else v
				px += v * mul
				mul *= 256
			end
			buffer.writeu32(out, o, px)
			o += 4
		end
	end
	return out
end

-- Overlap weights of output cells with source pixels, in units of 1/dn pixel so
-- they are integers: output cell i covers [i n, (i + 1) n) and source pixel k
-- covers [k dn, (k + 1) dn). Flat lists: first[i] = first source index, count[i],
-- weights in wts (each cell's weights sum to n).
local function areaWeights(n: number, dn: number): ({ number }, { number }, { number })
	local first, count, wts = table.create(dn, 0), table.create(dn, 0), {}
	for i = 0, dn - 1 do
		local a, b = i * n, (i + 1) * n
		local k0 = a // dn
		local k1 = (b - 1) // dn
		first[i + 1] = k0
		count[i + 1] = k1 - k0 + 1
		for k = k0, k1 do
			local lo = if a > k * dn then a else k * dn
			local hi = if b < (k + 1) * dn then b else (k + 1) * dn
			table.insert(wts, hi - lo)
		end
	end
	return first, count, wts
end

-- Exact area-average resample to dw x dh by two separable passes (the box
-- footprint is a product of an x and a y interval). Weights are integers (see
-- areaWeights), so every sum is an exact integer below 255 w h and the output is
-- round-half-up of the exact rational mean, (2 S + w h) // (2 w h): one fixed
-- answer on every platform and in every implementation (docs/COMPUTE.md C9).
-- Each pass only touches the ceil(scale) + 1 source pixels a footprint overlaps.
function Filter.areaResample(src: buffer, w: number, h: number, dw: number, dh: number, dst: buffer?): buffer
	local out = dst or buffer.create(dw * dh * 4)
	local fx, cx, wx = areaWeights(w, dw)
	local fy, cy, wy = areaWeights(h, dh)
	local mid = buffer.create(dw * h * 16) -- u32 x 4 channels, sums below 255 w
	for y = 0, h - 1 do
		local srow = y * w * 4
		local o = y * dw * 16
		local wi = 1
		for i = 1, dw do
			local s0, s1, s2, s3 = 0, 0, 0, 0
			local k = fx[i]
			for _ = 1, cx[i] do
				local p = buffer.readu32(src, srow + k * 4)
				local wt = wx[wi]
				s0 += (p % 256) * wt
				s1 += ((p // 256) % 256) * wt
				s2 += ((p // 65536) % 256) * wt
				s3 += (p // 16777216) * wt
				k += 1
				wi += 1
			end
			buffer.writeu32(mid, o, s0)
			buffer.writeu32(mid, o + 4, s1)
			buffer.writeu32(mid, o + 8, s2)
			buffer.writeu32(mid, o + 12, s3)
			o += 16
		end
	end
	local T = w * h
	local T2 = 2 * T
	local wj = 1
	for j = 1, dh do
		local orow = (j - 1) * dw * 4
		for i = 0, dw - 1 do
			local s0, s1, s2, s3 = 0, 0, 0, 0
			local k = fy[j]
			local wk = wj
			for _ = 1, cy[j] do
				local o = (k * dw + i) * 16
				local wt = wy[wk]
				s0 += buffer.readu32(mid, o) * wt
				s1 += buffer.readu32(mid, o + 4) * wt
				s2 += buffer.readu32(mid, o + 8) * wt
				s3 += buffer.readu32(mid, o + 12) * wt
				k += 1
				wk += 1
			end
			buffer.writeu32(
				out,
				orow + i * 4,
				(2 * s0 + T) // T2 + ((2 * s1 + T) // T2) * 256 + ((2 * s2 + T) // T2) * 65536 + ((2 * s3 + T) // T2) * 16777216
			)
		end
		wj += cy[j]
	end
	return out
end

-- Tangent-space normal map from a height field (u8 heights in a w x h buffer):
-- n = normalize(-s dh/dx, -s dh/dy, 1) by central differences (clamped at the
-- border), packed as RGB = round(127.5 + 127.5 n), alpha 255.
function Filter.normalMap(height: buffer, w: number, h: number, strength: number, dst: buffer?): buffer
	local out = dst or buffer.create(w * h * 4)
	local sqrt = math.sqrt
	local s = strength * 0.5 / 255
	for y = 0, h - 1 do
		local ym = if y > 0 then y - 1 else 0
		local yp = if y < h - 1 then y + 1 else h - 1
		for x = 0, w - 1 do
			local xm = if x > 0 then x - 1 else 0
			local xp = if x < w - 1 then x + 1 else w - 1
			local dx = (buffer.readu8(height, y * w + xp) - buffer.readu8(height, y * w + xm)) * s
			local dy = (buffer.readu8(height, yp * w + x) - buffer.readu8(height, ym * w + x)) * s
			local inv = 1 / sqrt(dx * dx + dy * dy + 1)
			local nx, ny, nz = -dx * inv, -dy * inv, inv
			buffer.writeu32(
				out,
				(y * w + x) * 4,
				((nx + 1) * 127.5 + 0.5) // 1 + (((ny + 1) * 127.5 + 0.5) // 1) * 256 + (((nz + 1) * 127.5 + 0.5) // 1) * 65536 + 0xFF000000
			)
		end
	end
	return out
end

return Filter
