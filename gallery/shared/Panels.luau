--!strict
--!native
--!optimize 2
-- universe-at-home :: gallery/shared/Panels
--
-- Pixel generators for the EditableImage gallery. Pure Luau: no Roblox globals, buffers in and
-- out, so the same code runs in the Luau CLI (tests, PNG previews) and in a Roblox LocalScript.
-- MyMath is injected:  local Panels = require(path.to.Panels)(MyMath)
--
-- Buffers are row-major RGBA8, the EditableImage layout: a pixel read with readu32 is
-- r + g * 256 + b * 65536 + a * 16777216.
--
-- Every generator takes an optional progress(y0, y1) callback that fires after each batch of
-- finished rows [y0, y1). The gallery uses it to upload those rows to an EditableImage and to
-- yield to its frame-time scheduler, so heavy panels fill in over several frames.

return function(MyMath: any)
	local pack = MyMath.pack
	local hash32 = MyMath.hash32
	local dsinTurns = MyMath.dsinTurns
	local dcosTurns = MyMath.dcosTurns

	local sqrt, abs, floor, min, max = math.sqrt, math.abs, math.floor, math.min, math.max

	local M = {}
	M.noCull = false -- tests set this to render every pixel of every shape, without tile culling

	export type Progress = ((number, number) -> ())?
	type Shape = {
		sd: (number, number) -> number, -- signed distance in design units, negative inside, 1-Lipschitz
		r: number,
		g: number,
		b: number,
		a: number,
		blur: number, -- 0 = hard anti-aliased edge; > 0 = soft edge of that half-width (design units)
	}

	----------------------------------------------------------------------------------------
	-- Exact pixel coverage of a straight edge
	----------------------------------------------------------------------------------------

	-- Exact area of the unit pixel square inside the half-plane whose boundary passes at signed
	-- distance d from the pixel centre with unit normal (nx, ny) (docs/COMPUTE.md, C4). The
	-- pixel's projection onto the normal is a trapezoid; integrating it gives these four cases.
	-- Exactly 0 for d >= (|nx| + |ny|) / 2 and exactly 1 for d <= -(|nx| + |ny|) / 2.
	local function halfPlane(d: number, nx: number, ny: number): number
		local a, b = abs(nx), abs(ny)
		if a < b then
			a, b = b, a
		end
		local u = (a + b) * 0.5 - d
		if u <= 0 then
			return 0
		end
		if u >= a + b then
			return 1
		end
		if u < b then
			return u * u / (2 * a * b)
		end
		if u <= a then
			return (2 * u - b) / (2 * a)
		end
		local v = a + b - u
		return 1 - v * v / (2 * a * b)
	end
	M.halfPlane = halfPlane

	local REACH = 0.7071067811865476 -- largest |d| with 0 < coverage < 1 for any edge angle

	----------------------------------------------------------------------------------------
	-- Signed distance constructors (design units)
	----------------------------------------------------------------------------------------

	local function circle(cx: number, cy: number, r: number): (number, number) -> number
		return function(x, y)
			local dx, dy = x - cx, y - cy
			return sqrt(dx * dx + dy * dy) - r
		end
	end

	local function ring(cx: number, cy: number, r0: number, r1: number): (number, number) -> number
		local mid, half = (r0 + r1) * 0.5, (r1 - r0) * 0.5
		return function(x, y)
			local dx, dy = x - cx, y - cy
			return abs(sqrt(dx * dx + dy * dy) - mid) - half
		end
	end

	-- Rounded box with half extents (hx, hy), corner radius rad, rotated by rot turns.
	local function roundBox(cx: number, cy: number, hx: number, hy: number, rad: number, rot: number): (number, number) -> number
		local c, s = dcosTurns(rot), dsinTurns(rot)
		return function(x, y)
			local px, py = x - cx, y - cy
			local qx0 = c * px + s * py
			local qy0 = -s * px + c * py
			local qx = abs(qx0) - hx + rad
			local qy = abs(qy0) - hy + rad
			local ox = if qx > 0 then qx else 0
			local oy = if qy > 0 then qy else 0
			local inner = min(max(qx, qy), 0)
			return sqrt(ox * ox + oy * oy) + inner - rad
		end
	end

	local function capsule(ax: number, ay: number, bx: number, by: number, r: number): (number, number) -> number
		return function(x, y)
			return MyMath.sdSegment(x, y, ax, ay, bx, by, r)
		end
	end

	local function polygon(pts: { number }): (number, number) -> number
		return function(x, y)
			return MyMath.sdPolygon(x, y, pts)
		end
	end

	local function starPoints(cx: number, cy: number, outer: number, inner: number, points: number, rot: number): { number }
		local pts = {}
		for i = 0, points * 2 - 1 do
			local ang = i / (points * 2) + rot
			local rad = if i % 2 == 0 then outer else inner
			table.insert(pts, cx + rad * dcosTurns(ang))
			table.insert(pts, cy + rad * dsinTurns(ang))
		end
		return pts
	end

	local function shape(sd: (number, number) -> number, r: number, g: number, b: number, a: number?, blur: number?): Shape
		return { sd = sd, r = r, g = g, b = b, a = a or 1, blur = blur or 0 }
	end

	----------------------------------------------------------------------------------------
	-- Vector renderer: tile culling by the Lipschitz bound, per-pixel work only at edges
	----------------------------------------------------------------------------------------

	local function fillRect(buf: buffer, width: number, x0: number, y0: number, w: number, h: number, color: number)
		local row = width * 4
		local first = y0 * row + x0 * 4
		for i = 0, w - 1 do
			buffer.writeu32(buf, first + i * 4, color)
		end
		for r = 1, h - 1 do
			buffer.copy(buf, first + r * row, buf, first, w * 4)
		end
	end

	-- Renders opaque shapes (drawn in list order) over a flat background into an w x h buffer.
	-- Shapes live in a design space of `design` units; the image scales it to w pixels.
	-- A tile of T x T pixels whose centre is farther from a shape's boundary than the tile's
	-- half-diagonal plus the edge reach lies entirely inside or outside that shape (a 1-Lipschitz
	-- distance cannot change faster), so tiles no edge crosses are filled with buffer.copy and
	-- only edge tiles run per-pixel math.
	local function renderShapes(
		buf: buffer,
		w: number,
		h: number,
		shapes: { Shape },
		bgR: number,
		bgG: number,
		bgB: number,
		design: number,
		progress: Progress
	): (number, number)
		local s = w / design
		local T = if w >= 256 then 16 else 8
		local n = #shapes
		local state = table.create(n, 0) -- 0 outside, 1 inside, 2 edge (per tile)
		local active = table.create(n, 0)
		local rho = T * REACH
		local edgeTiles, tiles = 0, 0
		local GH = 0.25 -- gradient step in design units
		for ty = 0, (h + T - 1) // T - 1 do
			local y0 = ty * T
			local th = min(T, h - y0)
			for tx = 0, (w + T - 1) // T - 1 do
				local x0 = tx * T
				local tw = min(T, w - x0)
				tiles += 1
				local cxd, cyd = (x0 + tw * 0.5) / s, (y0 + th * 0.5) / s
				local nActive, anyEdge = 0, false
				for i = 1, n do
					local sh = shapes[i]
					local dc = sh.sd(cxd, cyd) * s
					local reach = if sh.blur > 0 then sh.blur * s else REACH
					local st
					if M.noCull then
						st = 2
						anyEdge = true
					elseif dc - rho >= reach + 1e-6 then
						st = 0
					elseif dc + rho <= -reach - 1e-6 then
						st = 1
					else
						st = 2
						anyEdge = true
					end
					state[i] = st
					if st ~= 0 then
						nActive += 1
						active[nActive] = i
					end
				end
				if not anyEdge then
					local r, g, b = bgR, bgG, bgB
					for k = 1, nActive do
						local sh = shapes[active[k]]
						r += (sh.r - r) * sh.a
						g += (sh.g - g) * sh.a
						b += (sh.b - b) * sh.a
					end
					fillRect(buf, w, x0, y0, tw, th, pack((r + 0.5) // 1, (g + 0.5) // 1, (b + 0.5) // 1, 255))
				else
					edgeTiles += 1
					for py = y0, y0 + th - 1 do
						local yd = (py + 0.5) / s
						for px = x0, x0 + tw - 1 do
							local xd = (px + 0.5) / s
							local r, g, b = bgR, bgG, bgB
							for k = 1, nActive do
								local i = active[k]
								local sh = shapes[i]
								local cov = 1
								if state[i] == 2 then
									local d = sh.sd(xd, yd) * s
									if sh.blur > 0 then
										local bl = sh.blur * s
										local t = 0.5 - d / (2 * bl)
										t = if t < 0 then 0 elseif t > 1 then 1 else t
										cov = t * t * (3 - 2 * t)
									elseif d >= REACH then
										cov = 0
									elseif d <= -REACH then
										cov = 1
									else
										local gx = sh.sd(xd + GH, yd) - sh.sd(xd - GH, yd)
										local gy = sh.sd(xd, yd + GH) - sh.sd(xd, yd - GH)
										local len = sqrt(gx * gx + gy * gy)
										if len > 0 then
											cov = halfPlane(d, gx / len, gy / len)
										else
											cov = if d < -0.5 then 1 elseif d > 0.5 then 0 else 0.5 - d
										end
									end
								end
								if cov > 0 then
									cov *= sh.a
									r += (sh.r - r) * cov
									g += (sh.g - g) * cov
									b += (sh.b - b) * cov
								end
							end
							buffer.writeu32(buf, (py * w + px) * 4, pack((r + 0.5) // 1, (g + 0.5) // 1, (b + 0.5) // 1, 255))
						end
					end
				end
			end
			if progress then
				progress(y0, y0 + th)
			end
		end
		return edgeTiles, tiles
	end

	----------------------------------------------------------------------------------------
	-- Panel 1: the badge scene (also the LOD source at any resolution)
	----------------------------------------------------------------------------------------

	local badge: { Shape }? = nil
	local function badgeShapes(): { Shape }
		if badge then
			return badge
		end
		local star = starPoints(256, 256, 70, 29, 5, -0.25)
		local list: { Shape } = {
			shape(circle(256, 256, 252), 26, 34, 74),
			shape(circle(256, 284, 172), 0, 0, 0, 0.5, 26),
			shape(circle(256, 256, 172), 255, 198, 72),
			shape(ring(256, 256, 126, 142), 34, 44, 100),
			shape(roundBox(256, 256, 86, 86, 30, 0.125), 236, 84, 96),
			shape(roundBox(256, 256, 60, 60, 20, 0.125), 255, 128, 118),
			shape(polygon(star), 255, 246, 220),
			shape(circle(256 + 205 * dcosTurns(0.06), 256 + 205 * dsinTurns(0.06), 20), 64, 214, 196),
			shape(circle(256 + 205 * dcosTurns(0.4), 256 + 205 * dsinTurns(0.4), 14), 255, 140, 200),
			shape(circle(256 + 205 * dcosTurns(0.72), 256 + 205 * dsinTurns(0.72), 24), 250, 250, 255),
			shape(capsule(196, 456, 316, 456, 9), 255, 255, 255, 0.75),
			shape(ring(256, 256, 238, 244), 255, 255, 255, 0.85),
		}
		badge = list
		return list
	end

	-- Renders the badge at any size; coordinates scale, so every resolution is its own exact
	-- sample of the vector source and levels agree. Returns (edge tiles, tiles).
	function M.renderScene(buf: buffer, w: number, h: number, progress: Progress): (number, number)
		return renderShapes(buf, w, h, badgeShapes(), 10, 12, 28, 512, progress)
	end

	----------------------------------------------------------------------------------------
	-- Panel 2: animated plasma (table-driven, a few ops per pixel)
	----------------------------------------------------------------------------------------

	local SIN = table.create(1024, 0)
	for i = 0, 1023 do
		SIN[i + 1] = dsinTurns(i / 1024)
	end
	-- indigo to magenta to amber to cream, interpolated linearly between four stops
	local PLASMA_STOPS = { { 18, 10, 64 }, { 200, 36, 140 }, { 255, 150, 48 }, { 255, 238, 205 } }
	local PALETTE = table.create(256, 0)
	for i = 0, 255 do
		local f = i / 255 * 3
		local k = min(floor(f), 2)
		local u = f - k
		local c0, c1 = PLASMA_STOPS[k + 1], PLASMA_STOPS[k + 2]
		PALETTE[i + 1] = pack(
			(c0[1] + (c1[1] - c0[1]) * u + 0.5) // 1,
			(c0[2] + (c1[2] - c0[2]) * u + 0.5) // 1,
			(c0[3] + (c1[3] - c0[3]) * u + 0.5) // 1,
			255
		)
	end

	export type PlasmaState = { w: number, h: number, rad: buffer, col: { number }, row: { number } }

	function M.plasmaInit(w: number, h: number): PlasmaState
		local rad = buffer.create(w * h * 4)
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local dx, dy = (x + 0.5) / w - 0.5, (y + 0.5) / h - 0.5
				buffer.writef32(rad, (y * w + x) * 4, sqrt(dx * dx + dy * dy))
			end
		end
		return { w = w, h = h, rad = rad, col = table.create(w, 0), row = table.create(h, 0) }
	end

	-- Fills buf with the plasma at time t (seconds).
	function M.plasmaFrame(st: PlasmaState, buf: buffer, t: number)
		local w, h = st.w, st.h
		local col, row, rad = st.col, st.row, st.rad
		local ta, tb, tc, td = t * 0.13, t * -0.17, t * 0.11, t * 0.23
		for x = 0, w - 1 do
			col[x + 1] = SIN[floor((x / w * 3.0 + ta) * 1024) % 1024 + 1]
		end
		for y = 0, h - 1 do
			row[y + 1] = SIN[floor((y / h * 4.0 + tb) * 1024) % 1024 + 1]
		end
		local o = 0
		for y = 0, h - 1 do
			local ry = row[y + 1]
			local dy = y / h * 2.0 + tc
			for x = 0, w - 1 do
				local diag = SIN[floor((x / w * 2.0 + dy) * 1024) % 1024 + 1]
				local rr = SIN[floor((buffer.readf32(rad, o) * 9.0 + td) * 1024) % 1024 + 1]
				local v = col[x + 1] + ry + diag + rr
				buffer.writeu32(buf, o, PALETTE[floor((v + 4) * 31.99) + 1])
				o += 4
			end
		end
	end

	----------------------------------------------------------------------------------------
	-- Panel 3: marble from deterministic fractal noise
	----------------------------------------------------------------------------------------

	function M.renderMarble(buf: buffer, w: number, h: number, seed: number, progress: Progress)
		local BATCH = 4
		for y0 = 0, h - 1, BATCH do
			local y1 = min(y0 + BATCH, h)
			for y = y0, y1 - 1 do
				for x = 0, w - 1 do
					local f = (MyMath.fbm2(x * 0.011, y * 0.011, seed, 5))
					-- two families of veins cut through the same warped noise field
					local t = 1 - abs(dsinTurns(x * 0.0045 + y * 0.0021 + 1.25 * f))
					local t2 = t * t
					local t4 = t2 * t2
					local t8 = t4 * t4
					local u = 1 - abs(dsinTurns(x * 0.0031 - y * 0.0038 + 2.1 * f + 0.37))
					local u2 = u * u
					local u8 = u2 * u2 * u2 * u2
					local wv = t8 + 0.22 * t2 * t + 0.55 * u8
					wv = if wv > 1 then 1 else wv
					-- ivory stone to blue-grey veins, with cloudy tone drift from the noise
					local warm = (f - 0.5) * 46
					local r = 238 + warm - (238 - 40) * wv
					local g = 232 + warm * 0.8 - (232 - 52) * wv
					local b = 220 + warm * 0.5 - (220 - 66) * wv
					buffer.writeu32(buf, (y * w + x) * 4, pack((r + 0.5) // 1, (g + 0.5) // 1, (b + 0.5) // 1, 255))
				end
			end
			if progress then
				progress(y0, y1)
			end
		end
	end

	----------------------------------------------------------------------------------------
	-- Panel 4: one tile of a canvas larger than the 1024 EditableImage limit
	----------------------------------------------------------------------------------------

	local MANDEL_PALETTE = table.create(512, 0)
	for i = 0, 511 do
		local t = i / 512
		local function ch(phase: number): number
			local v = 0.5 + 0.5 * dcosTurns(t * 2.0 + phase)
			return (v * v * 255 * 0.7 + v * 255 * 0.3 + 0.5) // 1
		end
		MANDEL_PALETTE[i + 1] = pack(ch(0.0), ch(0.1), ch(0.25), 255)
	end

	-- Tile (tx, ty) of a grid x grid canvas of size x size tiles: a Mandelbrot set zoomed to
	-- the seahorse valley. This one is for looking at, not for the determinism hash: it uses
	-- math.log for smooth colouring.
	function M.renderMandelbrotTile(buf: buffer, size: number, tx: number, ty: number, grid: number, progress: Progress)
		local cx, cy, span = -0.7436438870371587, 0.13182590420531197, 0.0036
		local total = size * grid
		local maxIter = 300
		local ln2 = math.log(2)
		for py = 0, size - 1 do
			local ci = cy + ((ty * size + py + 0.5) / total - 0.5) * span
			for px = 0, size - 1 do
				local cr = cx + ((tx * size + px + 0.5) / total - 0.5) * span
				local zr, zi, zr2, zi2 = 0, 0, 0, 0
				local n = 0
				while n < maxIter and zr2 + zi2 <= 256 do
					zi = 2 * zr * zi + ci
					zr = zr2 - zi2 + cr
					zr2 = zr * zr
					zi2 = zi * zi
					n += 1
				end
				local color
				if n >= maxIter then
					color = 0xFF000000
				else
					local mu = n + 1 - math.log(math.log(zr2 + zi2) * 0.5 / ln2) / ln2
					color = MANDEL_PALETTE[floor(mu * 6) % 512 + 1]
				end
				buffer.writeu32(buf, (py * size + px) * 4, color)
			end
			if progress and (py % 4 == 3 or py == size - 1) then
				progress(py - (py % 4), py + 1)
			end
		end
	end

	----------------------------------------------------------------------------------------
	-- Panels 5 to 7: green screen, matte, cut-out
	----------------------------------------------------------------------------------------

	local KEY_R, KEY_G, KEY_B = 0, 177, 64

	local function greenScreenShapes(): { Shape }
		local hair = {}
		for i = 0, 13 do
			local ang = -0.5 + 0.5 * (i + 0.5) / 14 -- fan over the top of the head
			local x0, y0 = 128 + 44 * dcosTurns(ang), 100 + 44 * dsinTurns(ang)
			local len = 12 + (i * 7 % 5) * 3
			local x1, y1 = 128 + (44 + len) * dcosTurns(ang), 100 + (44 + len) * dsinTurns(ang)
			table.insert(hair, shape(capsule(x0, y0, x1, y1, 0.9), 70, 44, 30))
		end
		local list: { Shape } = {
			shape(capsule(62, 196, 38, 238, 15), 58, 96, 196),
			shape(capsule(194, 196, 218, 238, 15), 58, 96, 196),
			shape(roundBox(128, 222, 66, 56, 30, 0), 58, 96, 196),
			shape(capsule(128, 138, 128, 160, 13), 214, 168, 140),
			shape(circle(128, 80, 47), 70, 44, 30),
			shape(circle(128, 104, 41), 232, 190, 160),
			shape(capsule(98, 164, 158, 164, 11), 204, 44, 56),
			shape(circle(114, 98, 4), 40, 30, 28),
			shape(circle(142, 98, 4), 40, 30, 28),
			shape(circle(198, 86, 26), 190, 225, 255, 0.45),
			shape(circle(189, 76, 7), 255, 255, 255, 0.7),
		}
		for _, hs in hair do
			table.insert(list, hs)
		end
		return list
	end

	-- A green-screen portrait with fine hair strands, a semi-transparent glass bubble and a
	-- little deterministic sensor noise.
	function M.renderGreenScreen(buf: buffer, w: number, h: number, progress: Progress)
		renderShapes(buf, w, h, greenScreenShapes(), KEY_R, KEY_G, KEY_B, 256, nil)
		for y0 = 0, h - 1, 16 do
			local y1 = min(y0 + 16, h)
			for y = y0, y1 - 1 do
				for x = 0, w - 1 do
					local o = (y * w + x) * 4
					local p = buffer.readu32(buf, o)
					local nz = hash32(x + y * w + 977) % 9 - 4
					local r = p % 256 + nz
					local g = (p // 256) % 256 + nz
					local b = (p // 65536) % 256 + nz
					r = if r < 0 then 0 elseif r > 255 then 255 else r
					g = if g < 0 then 0 elseif g > 255 then 255 else g
					b = if b < 0 then 0 elseif b > 255 then 255 else b
					buffer.writeu32(buf, o, pack(r, g, b, 255))
				end
			end
			if progress then
				progress(y0, y1)
			end
		end
	end

	-- Chroma key with soft alpha and colour decontamination. For a pixel C that is the key K
	-- mixed with foreground F at coverage alpha, C = alpha F + (1 - alpha) K, so
	-- F = (C - (1 - alpha) K) / alpha removes the green fringe at soft edges.
	-- matteOut gets alpha as grey; cutOut gets the foreground over a sunset backdrop.
	function M.keyMatte(src: buffer, w: number, h: number, matteOut: buffer, cutOut: buffer, progress: Progress)
		local LO, HI = 18, 100
		for y0 = 0, h - 1, 16 do
			local y1 = min(y0 + 16, h)
			for y = y0, y1 - 1 do
				-- backdrop: vertical sunset gradient with a sun disc
				local ty = y / h
				local br = 255 - 150 * ty
				local bg = 150 - 90 * ty
				local bb = 90 + 80 * ty
				for x = 0, w - 1 do
					local o = (y * w + x) * 4
					local p = buffer.readu32(src, o)
					local r, g, b = p % 256, (p // 256) % 256, (p // 65536) % 256
					local gd = g - (if r > b then r else b) -- how much greener than the other channels
					local a = 1 - (gd - LO) / (HI - LO)
					a = if a < 0 then 0 elseif a > 1 then 1 else a
					a = a * a * (3 - 2 * a)
					local fr, fg, fb = r, g, b
					if a > 0.02 then
						local ia = 1 - a
						fr = (r - ia * KEY_R) / a
						fg = (g - ia * KEY_G) / a
						fb = (b - ia * KEY_B) / a
						fr = if fr < 0 then 0 elseif fr > 255 then 255 else fr
						fg = if fg < 0 then 0 elseif fg > 255 then 255 else fg
						fb = if fb < 0 then 0 elseif fb > 255 then 255 else fb
					end
					local gray = (a * 255 + 0.5) // 1
					buffer.writeu32(matteOut, o, pack(gray, gray, gray, 255))
					-- sun disc, centred behind the glass bubble so its transparency is visible
					local dx, dy = x / w - 0.77, y / h - 0.34
					local sun = if dx * dx + dy * dy < 0.0144 then 1 else 0
					local bgr = br + (255 - br) * sun
					local bgg = bg + (236 - bg) * sun
					local bgb = bb + (180 - bb) * sun
					buffer.writeu32(
						cutOut,
						o,
						pack((fr * a + bgr * (1 - a) + 0.5) // 1, (fg * a + bgg * (1 - a) + 0.5) // 1, (fb * a + bgb * (1 - a) + 0.5) // 1, 255)
					)
				end
			end
			if progress then
				progress(y0, y1)
			end
		end
	end

	----------------------------------------------------------------------------------------
	-- LOD: continuous level blending without pops
	----------------------------------------------------------------------------------------

	local LOD_LO, LOD_HI = 80, 150 -- displayed size band (pixels) over which levels hand over

	-- Blend parameter f in [0, 1] for a displayed size in pixels: 0 = coarse level only,
	-- 1 = fine level only. Smoothstep over log size, so f is C1 in the size.
	function M.lodBlend(size: number): number
		local u = (math.log(size) - math.log(LOD_LO)) / (math.log(LOD_HI) - math.log(LOD_LO))
		u = if u < 0 then 0 elseif u > 1 then 1 else u
		return u * u * (3 - 2 * u)
	end

	-- Two-phase fade (docs/DESIGN.md, Saturn). Returns the transparencies (0 = opaque) of the
	-- coarse layer (below) and the fine layer (on top). Phase 1: the fine layer fades in over
	-- a fully opaque coarse layer. Phase 2: the fine layer is opaque and the coarse layer
	-- fades out beneath it. Never both layers half transparent at once, so a pixel that is
	-- covered in both levels never dips.
	function M.twoPhase(f: number): (number, number)
		if f < 0.5 then
			return 0, 1 - f * 2
		end
		return (f - 0.5) * 2, 0
	end

	-- The naive alternative for comparison: switch levels at the midpoint.
	function M.hardSwitch(f: number): (number, number)
		if f < 0.5 then
			return 0, 1
		end
		return 1, 0
	end

	-- Displayed size in pixels at time t: a slow zoom in and out between 36 and 288.
	function M.zoomSize(t: number): number
		local u = 0.5 - 0.5 * dcosTurns(t / 10)
		return 36 * (288 / 36) ^ u
	end

	----------------------------------------------------------------------------------------
	-- Helpers
	----------------------------------------------------------------------------------------

	-- Order-sensitive hash of a whole buffer (32-bit words), for determinism checks.
	function M.hashBuffer(buf: buffer): number
		local hsh = 0x9E3779B9
		for o = 0, buffer.len(buf) - 4, 4 do
			hsh = hash32(bit32.bxor(hsh, buffer.readu32(buf, o)))
		end
		return hsh
	end

	return M
end
