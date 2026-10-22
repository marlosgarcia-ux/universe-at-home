--!native
--!optimize 2
-- universe-at-home :: compute/Distance
--
-- Distance transforms: turn a binary mask (buffer of u8, nonzero = feature) into a
-- field of squared Euclidean distances to the nearest feature pixel centre (buffer
-- of u32), and from there into signed distance fields, soft mattes, outlines and
-- glows. Three algorithms, measured against brute force in docs/COMPUTE.md 3.6:
--
--   edt     Felzenszwalb and Huttenlocher (2004) separable lower envelope of
--           parabolas. EXACT, O(pixels), two passes. The division that locates
--           parabola intersections is correctly rounded and can only misorder a
--           tie, where both parabolas give the same integer, so the output is the
--           exact integer squared distance (COMPUTE.md C8).
--   jfa     Jump flooding (Rong and Tan 2006): log2(n) passes of 9 probes. A GPU
--           algorithm; approximate and 5 to 10x slower than edt on a CPU.
--   ssedt8  8-point sequential signed EDT (Danielsson style, two raster sweeps
--           propagating offset vectors). Approximate, O(pixels).
--
-- Deterministic: integer arithmetic in doubles, comparisons, one correctly
-- rounded division per parabola test, sqrt only in the signed/matte helpers.

local Distance = {}

local INF = 2 ^ 40 -- larger than any squared distance on a 2^16 x 2^16 image

-- Squared distance from every pixel to the nearest feature pixel (exact).
function Distance.edt(mask: buffer, w: number, h: number, out: buffer?): buffer
	local res = out or buffer.create(w * h * 4)
	local g = buffer.create(w * h * 8) -- f64 squared vertical distances
	-- pass 1: columns, two sweeps, walked row by row (row-major memory order) with
	-- one "last feature row" per column
	local last = table.create(w, -1)
	for y = 0, h - 1 do
		local row = y * w
		for x = 0, w - 1 do
			local i = row + x
			if buffer.readu8(mask, i) ~= 0 then
				last[x + 1] = y
				buffer.writef64(g, i * 8, 0)
			else
				local l = last[x + 1]
				if l >= 0 then
					local d = y - l
					buffer.writef64(g, i * 8, d * d)
				else
					buffer.writef64(g, i * 8, INF)
				end
			end
		end
	end
	table.clear(last)
	for x = 1, w do
		last[x] = -1
	end
	for y = h - 1, 0, -1 do
		local row = y * w
		for x = 0, w - 1 do
			local i = row + x
			local cur = buffer.readf64(g, i * 8)
			if cur == 0 then
				last[x + 1] = y
			else
				local l = last[x + 1]
				if l >= 0 then
					local d = l - y
					local dd = d * d
					if dd < cur then
						buffer.writef64(g, i * 8, dd)
					end
				end
			end
		end
	end
	-- pass 2: rows, lower envelope of parabolas (x - q)^2 + f(q)
	local v = table.create(w + 1, 0) -- parabola apexes
	local z = table.create(w + 2, 0) -- envelope boundaries
	for y = 0, h - 1 do
		local row = y * w
		local k = 0 -- number of parabolas in the envelope
		for q = 0, w - 1 do
			local fq = buffer.readf64(g, (row + q) * 8)
			if fq >= INF then
				continue -- infinite parabola never reaches the envelope
			end
			local hq = fq + q * q
			if k == 0 then
				k = 1
				v[1] = q
				z[1] = -math.huge
				z[2] = math.huge
				continue
			end
			-- pop parabolas hidden by the new one; z[1] = -inf stops the loop
			local s
			while true do
				local p = v[k]
				local fp = buffer.readf64(g, (row + p) * 8)
				s = (hq - (fp + p * p)) / (2 * q - 2 * p)
				if s <= z[k] then
					k -= 1
				else
					break
				end
			end
			k += 1
			v[k] = q
			z[k] = s
			z[k + 1] = math.huge
		end
		if k == 0 then
			for x = 0, w - 1 do
				buffer.writeu32(res, (row + x) * 4, 0xFFFFFFFF)
			end
			continue
		end
		local j = 1
		for x = 0, w - 1 do
			while z[j + 1] < x do
				j += 1
			end
			local p = v[j]
			local dx = x - p
			buffer.writeu32(res, (row + x) * 4, dx * dx + buffer.readf64(g, (row + p) * 8))
		end
	end
	return res
end

-- Exact reference: every pixel against every feature pixel. O(pixels * features).
function Distance.brute(mask: buffer, w: number, h: number): buffer
	local res = buffer.create(w * h * 4)
	local fx, fy = {}, {}
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			if buffer.readu8(mask, y * w + x) ~= 0 then
				table.insert(fx, x)
				table.insert(fy, y)
			end
		end
	end
	local n = #fx
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local best = 0xFFFFFFFF
			for i = 1, n do
				local dx, dy = x - fx[i], y - fy[i]
				local d = dx * dx + dy * dy
				if d < best then
					best = d
				end
			end
			buffer.writeu32(res, (y * w + x) * 4, best)
		end
	end
	return res
end

-- Jump flooding. Stores the nearest seed as an index + 1 (0 = none) in a u32
-- buffer, then converts to squared distances.
function Distance.jfa(mask: buffer, w: number, h: number, out: buffer?): buffer
	local res = out or buffer.create(w * h * 4)
	local a = buffer.create(w * h * 4)
	local b = buffer.create(w * h * 4)
	for i = 0, w * h - 1 do
		if buffer.readu8(mask, i) ~= 0 then
			buffer.writeu32(a, i * 4, i + 1)
		end
	end
	local step = 1
	while step * 2 < math.max(w, h) do
		step *= 2
	end
	local src, dst = a, b
	while step >= 1 do
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local i = y * w + x
				local best = buffer.readu32(src, i * 4)
				local bd = INF
				if best > 0 then
					local s = best - 1
					local dx, dy = x - s % w, y - s // w
					bd = dx * dx + dy * dy
				end
				for oy = -step, step, step do
					local yy = y + oy
					if yy < 0 or yy >= h then
						continue
					end
					for ox = -step, step, step do
						local xx = x + ox
						if xx < 0 or xx >= w or (ox == 0 and oy == 0) then
							continue
						end
						local c = buffer.readu32(src, (yy * w + xx) * 4)
						if c > 0 then
							local s = c - 1
							local dx, dy = x - s % w, y - s // w
							local d = dx * dx + dy * dy
							if d < bd then
								bd = d
								best = c
							end
						end
					end
				end
				buffer.writeu32(dst, i * 4, best)
			end
		end
		src, dst = dst, src
		step //= 2
	end
	for i = 0, w * h - 1 do
		local c = buffer.readu32(src, i * 4)
		if c == 0 then
			buffer.writeu32(res, i * 4, 0xFFFFFFFF)
		else
			local s = c - 1
			local x, y = i % w, i // w
			local dx, dy = x - s % w, y - s // w
			buffer.writeu32(res, i * 4, dx * dx + dy * dy)
		end
	end
	return res
end

-- 8-point sequential EDT: offset vectors (dx, dy) to the nearest feature found so
-- far, propagated by a forward and a backward raster sweep. Offsets stored as i16.
function Distance.ssedt8(mask: buffer, w: number, h: number, out: buffer?): buffer
	local res = out or buffer.create(w * h * 4)
	local FAR = 16000
	local ox = buffer.create(w * h * 2)
	local oy = buffer.create(w * h * 2)
	for i = 0, w * h - 1 do
		if buffer.readu8(mask, i) == 0 then
			buffer.writei16(ox, i * 2, FAR)
			buffer.writei16(oy, i * 2, FAR)
		end
	end
	local function relax(i: number, j: number, ddx: number, ddy: number)
		-- candidate: neighbour j's offset plus the step from j to i
		local cx = buffer.readi16(ox, j * 2) + ddx
		local cy = buffer.readi16(oy, j * 2) + ddy
		local px = buffer.readi16(ox, i * 2)
		local py = buffer.readi16(oy, i * 2)
		if cx * cx + cy * cy < px * px + py * py then
			buffer.writei16(ox, i * 2, cx)
			buffer.writei16(oy, i * 2, cy)
		end
	end
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = y * w + x
			if x > 0 then
				relax(i, i - 1, 1, 0)
			end
			if y > 0 then
				relax(i, i - w, 0, 1)
				if x > 0 then
					relax(i, i - w - 1, 1, 1)
				end
				if x < w - 1 then
					relax(i, i - w + 1, -1, 1)
				end
			end
		end
		for x = w - 2, 0, -1 do
			local i = y * w + x
			relax(i, i + 1, -1, 0)
		end
	end
	for y = h - 1, 0, -1 do
		for x = w - 1, 0, -1 do
			local i = y * w + x
			if x < w - 1 then
				relax(i, i + 1, -1, 0)
			end
			if y < h - 1 then
				relax(i, i + w, 0, -1)
				if x < w - 1 then
					relax(i, i + w + 1, -1, -1)
				end
				if x > 0 then
					relax(i, i + w - 1, 1, -1)
				end
			end
		end
		for x = 1, w - 1 do
			local i = y * w + x
			relax(i, i - 1, 1, 0)
		end
	end
	for i = 0, w * h - 1 do
		local dx, dy = buffer.readi16(ox, i * 2), buffer.readi16(oy, i * 2)
		if dx >= FAR then
			buffer.writeu32(res, i * 4, 0xFFFFFFFF)
		else
			buffer.writeu32(res, i * 4, dx * dx + dy * dy)
		end
	end
	return res
end

-- Signed distance (f32, pixels, positive outside) to the boundary between the
-- mask's pixel centres: d = dOut - 1/2 outside and -(dIn - 1/2) inside, where dOut
-- is the distance to the nearest inside centre and dIn to the nearest outside
-- centre. Exact for boundaries along pixel edges.
function Distance.signed(mask: buffer, w: number, h: number): buffer
	local inv = buffer.create(w * h)
	for i = 0, w * h - 1 do
		if buffer.readu8(mask, i) == 0 then
			buffer.writeu8(inv, i, 1)
		end
	end
	local dOut = Distance.edt(mask, w, h)
	local dIn = Distance.edt(inv, w, h)
	local sd = buffer.create(w * h * 4)
	local sqrt = math.sqrt
	for i = 0, w * h - 1 do
		local a = buffer.readu32(dOut, i * 4)
		if a > 0 then
			buffer.writef32(sd, i * 4, if a == 0xFFFFFFFF then 1e9 else sqrt(a) - 0.5)
		else
			local b = buffer.readu32(dIn, i * 4)
			buffer.writef32(sd, i * 4, if b == 0xFFFFFFFF then -1e9 else 0.5 - sqrt(b))
		end
	end
	return sd
end

-- Writes alpha from a signed distance field into an RGBA8 image (RGB kept):
-- alpha = 255 * clamp(1/2 - d / feather). feather = 1 gives a one-pixel
-- anti-aliased edge; larger values feather a background-removal matte.
-- Spans whose alpha is 0 or 255 still cost one pixel write each here; a shell
-- (band) version only touches |d| < feather.
function Distance.applyMatte(img: buffer, sd: buffer, count: number, feather: number)
	local inv = 1 / feather
	for i = 0, count - 1 do
		local d = buffer.readf32(sd, i * 4)
		local a = 0.5 - d * inv
		a = if a < 0 then 0 elseif a > 1 then 1 else a
		buffer.writeu8(img, i * 4 + 3, (a * 255 + 0.5) // 1)
	end
end

-- Onion shell: alpha of an outline band |d - centre| <= half (soft by 1/2 pixel on
-- each side), for outlines (centre 0) and glows (a ramp outside the shape).
function Distance.shellAlpha(d: number, centre: number, half: number): number
	local a = half + 0.5 - math.abs(d - centre)
	return if a < 0 then 0 elseif a > 1 then 1 else a
end

-- Glow: alpha falls off linearly from 1 at the shape edge to 0 at `radius` px.
function Distance.glowAlpha(d: number, radius: number): number
	if d <= 0 then
		return 1
	end
	local a = 1 - d / radius
	return if a < 0 then 0 else a
end

return Distance
