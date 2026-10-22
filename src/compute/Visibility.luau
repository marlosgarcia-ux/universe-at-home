--!native
--!optimize 2
-- universe-at-home :: compute/Visibility
--
-- Exact visibility for "conflict pixels": pixels where the edges of two or more
-- shapes enter (docs/COMPUTE.md F2 and C11). Elsewhere coverage-as-alpha is exact
-- (proof in the "Flawless pipeline" section of docs/COMPUTE.md); here it is not,
-- because the shapes' coverage regions inside the pixel are correlated (abutting
-- shapes are perfectly anti-correlated: two exact halves composite to 3/4, a
-- 64/255 seam). This module computes the exact box filter of the source-over
-- composite of a pixel's shape stack instead.
--
-- Method (signed convex terms). In pixel-local coordinates (pixel = the square
-- [-1/2, 1/2]^2), every shape's indicator inside the pixel is written as a signed
-- sum of CONVEX PIECES, sum_j sigma_j 1[K_j], each piece = (convex polygon inside
-- the square) intersected with at most one disc. Disc complements and non-convex
-- polygons are expressed through the signs (ring = outer disc - inner disc,
-- polygon = signed fan of triangles of its clip to the pixel). The stack is
-- processed top-down while maintaining the transmittance
--     nu(q) = prod over shapes t above (1 - alpha_t I_t(q))
-- as a signed weighted sum of terms, sum_k w_k 1[R_k], with every region R_k an
-- intersection of pieces (convex polygon and a set of discs). Shape s contributes
--     alpha_s c_s * integral(I_s nu) = alpha_s c_s * sum_k sum_j w_k sigma_j |R_k ^ K_j|
-- and updates nu <- nu - alpha_s I_s nu, which appends the terms (R_k ^ K_j,
-- -alpha_s sigma_j w_k). A shape that covers the whole pixel (I_s = 1) contributes
-- alpha_s c_s integral(nu) and scales every weight by (1 - alpha_s). The base below
-- the stack contributes alpha_0 c_0 integral(nu). The result is the premultiplied
-- integral of the exact composite over the pixel; dividing by the alpha integral
-- gives straight alpha.
--
-- Exact areas: |R| for R = (convex polygon) ^ D_1 ^ ... ^ D_k. The polygon part is
-- a Sutherland-Hodgman clip (exact up to rounding). With k = 1 the area is
-- Coverage.discPolyArea; with k >= 2 the POWER-CELL LEMMA reduces it to k single
-- disc areas: with power functions p_i(q) = |q - c_i|^2 - r_i^2, on the cell where
-- p_i is the largest the intersection of all discs is {p_i <= 0} = D_i, and every
-- cell {p_i >= p_j for all j} is convex (p_i - p_j is affine), so
--     |P ^ D_1 ^ ... ^ D_k| = sum_i |P ^ cell_i ^ D_i|.
-- Identical discs (zero normal, zero offset) are tie-broken by index.
--
-- Abutting shapes: complementary pieces (a shared edge with opposite inner sides)
-- intersect in a zero-area sliver, so they never double count; no tolerance or
-- snapping is involved. Terms with zero area are pruned, so k mutually disjoint
-- shapes cost O(k^2) clips, while k mutually overlapping fractional shapes can
-- need up to 2^k terms: the term list is capped at MAX_TERMS (stats.capped counts
-- pixels where the cap bound; none in any measured scene).
--
-- Usage per pixel (allocation-free after warm-up; module-level scratch):
--   Visibility.reset()
--   for each shape from the TOP of the stack down to just above the base:
--     Visibility.full(r, g, b, a)                  -- covers the whole pixel
--     or Visibility.begin(r, g, b, a)               -- partly covers it, then pieces:
--          Visibility.square(sign) / rect(sign, x0, y0, x1, y1) / poly(sign, xs, ys, n)
--          Visibility.clip(nx, ny, c)               -- keep {nx x + ny y <= c}
--          Visibility.disc(cx, cy, r)               -- intersect with a disc
--          Visibility.piece()                       -- store the piece
--        Visibility.commit()
--   r, g, b, a = Visibility.finish(baseR, baseG, baseB, baseA)   -- straight alpha
-- Colours are 0..255 floats, alphas 0..1. Deterministic ops only (+ - * / sqrt,
-- comparisons, and Coverage.dasin through the disc areas).

local Coverage = require("./Coverage")

local Visibility = {}

local clipInto = Coverage.clipInto
local polyArea = Coverage.polyArea
local discPolyArea = Coverage.discPolyArea

local MAX_TERMS = 1024
Visibility.MAX_TERMS = MAX_TERMS

export type Stats = { pixels: number, terms: number, areas: number, capped: number }
local stats: Stats = { pixels = 0, terms = 0, areas = 0, capped = 0 }
Visibility.stats = stats

function Visibility.resetStats()
	stats.pixels, stats.terms, stats.areas, stats.capped = 0, 0, 0, 0
end

-- pieces of the current entry
local PS: { number } = table.create(32, 0) -- sign
local PV0: { number } = table.create(32, 0) -- first vertex in PX, PY
local PN: { number } = table.create(32, 0) -- vertex count
local PD: { number } = table.create(32, 0) -- 1: has a disc
local PDX: { number } = table.create(32, 0)
local PDY: { number } = table.create(32, 0)
local PDR: { number } = table.create(32, 0)
local PX: { number } = table.create(512, 0)
local PY: { number } = table.create(512, 0)
local nP, nPV = 0, 0

-- terms of nu
local TW: { number } = table.create(256, 0) -- weight
local TA: { number } = table.create(256, 0) -- area
local TV0: { number } = table.create(256, 0)
local TN: { number } = table.create(256, 0)
local TD0: { number } = table.create(256, 0)
local TND: { number } = table.create(256, 0)
local TX: { number } = table.create(2048, 0)
local TY: { number } = table.create(2048, 0)
local TDX: { number } = table.create(512, 0)
local TDY: { number } = table.create(512, 0)
local TDR: { number } = table.create(512, 0)
local nT, nTV, nTD = 0, 0, 0

local accR, accG, accB, accA = 0, 0, 0, 0
local eR, eG, eB, eA = 0, 0, 0, 0

-- piece under construction (ping-pong clip buffers)
local AX: { number } = table.create(64, 0)
local AY: { number } = table.create(64, 0)
local BX: { number } = table.create(64, 0)
local BY: { number } = table.create(64, 0)
local cur = 0 -- 0: current polygon in A, 1: in B
local wn = 0
local wSign, wDisc, wDX, wDY, wDR = 0, 0, 0, 0, 0

-- region measurement scratch
local VX: { number } = table.create(64, 0)
local VY: { number } = table.create(64, 0)
local UX: { number } = table.create(64, 0)
local UY: { number } = table.create(64, 0)
local CX: { number } = table.create(64, 0)
local CY: { number } = table.create(64, 0)
local DX2: { number } = table.create(64, 0)
local DY2: { number } = table.create(64, 0)
local KX: { number } = table.create(16, 0)
local KY: { number } = table.create(16, 0)
local KR: { number } = table.create(16, 0)

function Visibility.reset()
	stats.pixels += 1
	-- one term: the whole pixel, weight 1, area 1, no discs
	TX[1], TY[1] = -0.5, -0.5
	TX[2], TY[2] = 0.5, -0.5
	TX[3], TY[3] = 0.5, 0.5
	TX[4], TY[4] = -0.5, 0.5
	TW[1], TA[1], TV0[1], TN[1], TD0[1], TND[1] = 1, 1, 1, 4, 1, 0
	nT, nTV, nTD = 1, 4, 0
	accR, accG, accB, accA = 0, 0, 0, 0
end

-- A shape that covers the whole pixel with straight colour (r, g, b), alpha a < 1.
function Visibility.full(r: number, g: number, b: number, a: number)
	local W = 0
	for t = 1, nT do
		W += TW[t] * TA[t]
	end
	local k = a * W
	accR += r * k
	accG += g * k
	accB += b * k
	accA += k
	local f = 1 - a
	for t = 1, nT do
		TW[t] *= f
	end
end

-- Starts a shape that covers the pixel partly; its pieces follow.
function Visibility.begin(r: number, g: number, b: number, a: number)
	eR, eG, eB, eA = r, g, b, a
	nP, nPV = 0, 0
end

-- Piece construction ---------------------------------------------------------------

-- Starts a piece equal to the whole pixel square.
function Visibility.square(sign: number)
	AX[1], AY[1] = -0.5, -0.5
	AX[2], AY[2] = 0.5, -0.5
	AX[3], AY[3] = 0.5, 0.5
	AX[4], AY[4] = -0.5, 0.5
	cur, wn = 0, 4
	wSign, wDisc = sign, 0
end

-- Starts a piece equal to the rectangle [x0, x1] x [y0, y1] clipped to the pixel.
function Visibility.rect(sign: number, x0: number, y0: number, x1: number, y1: number)
	if x0 < -0.5 then
		x0 = -0.5
	end
	if y0 < -0.5 then
		y0 = -0.5
	end
	if x1 > 0.5 then
		x1 = 0.5
	end
	if y1 > 0.5 then
		y1 = 0.5
	end
	wSign, wDisc, cur = sign, 0, 0
	if x1 <= x0 or y1 <= y0 then
		wn = 0
		return
	end
	AX[1], AY[1] = x0, y0
	AX[2], AY[2] = x1, y0
	AX[3], AY[3] = x1, y1
	AX[4], AY[4] = x0, y1
	wn = 4
end

-- Starts a piece equal to the convex polygon xs, ys [1..n] (positive orientation:
-- every edge has the interior on its left), which must lie inside the pixel.
function Visibility.poly(sign: number, xs: { number }, ys: { number }, n: number)
	for i = 1, n do
		AX[i], AY[i] = xs[i], ys[i]
	end
	cur, wn = 0, n
	wSign, wDisc = sign, 0
end

-- Clips the piece under construction to {nx x + ny y <= c}.
function Visibility.clip(nx: number, ny: number, c: number)
	if wn < 3 then
		wn = 0
		return
	end
	if cur == 0 then
		wn = clipInto(AX, AY, wn, BX, BY, nx, ny, c)
		cur = 1
	else
		wn = clipInto(BX, BY, wn, AX, AY, nx, ny, c)
		cur = 0
	end
end

-- Intersects the piece under construction with the disc (cx, cy, r).
function Visibility.disc(cx: number, cy: number, r: number)
	wDisc, wDX, wDY, wDR = 1, cx, cy, r
end

-- Stores the piece under construction (dropped when its polygon is empty).
function Visibility.piece()
	if wn < 3 then
		return
	end
	local X, Y = AX, AY
	if cur == 1 then
		X, Y = BX, BY
	end
	if polyArea(X, Y, wn) <= 0 then
		return
	end
	nP += 1
	PS[nP] = wSign
	PV0[nP] = nPV + 1
	PN[nP] = wn
	for i = 1, wn do
		PX[nPV + i], PY[nPV + i] = X[i], Y[i]
	end
	nPV += wn
	PD[nP] = wDisc
	PDX[nP], PDY[nP], PDR[nP] = wDX, wDY, wDR
end

-- Pieces of one closed polygon contour (pixel-local coordinates, any size; it is
-- clipped to the pixel here) whose signed winding number, times sigma, is its
-- contribution to the shape's indicator (sigma = the shape's orientation, so a
-- simple polygon of either orientation, or a path whose holes wind the other way,
-- contributes exactly 1 inside). A convex clip becomes one piece; otherwise the
-- winding number of the clip is the sum of its fan triangles' signed indicators.
local GX: { number } = table.create(64, 0)
local GY: { number } = table.create(64, 0)
local HX: { number } = table.create(64, 0)
local HY: { number } = table.create(64, 0)
local TRX: { number } = table.create(3, 0)
local TRY: { number } = table.create(3, 0)

function Visibility.polygon(xs: { number }, ys: { number }, n: number, sigma: number)
	local m = clipInto(xs, ys, n, HX, HY, 1, 0, 0.5)
	m = clipInto(HX, HY, m, GX, GY, -1, 0, 0.5)
	m = clipInto(GX, GY, m, HX, HY, 0, 1, 0.5)
	m = clipInto(HX, HY, m, GX, GY, 0, -1, 0.5)
	if m < 3 then
		return
	end
	local A = polyArea(GX, GY, m)
	if A == 0 then
		return
	end
	local sg = sigma
	if A < 0 then
		-- reverse to positive orientation; the winding inside the clip is then +1
		sg = -sigma
		local i, j = 1, m
		while i < j do
			GX[i], GX[j] = GX[j], GX[i]
			GY[i], GY[j] = GY[j], GY[i]
			i += 1
			j -= 1
		end
	end
	local convex = true
	local ax, ay = GX[m - 1], GY[m - 1]
	local bx, by = GX[m], GY[m]
	for i = 1, m do
		local cx, cy = GX[i], GY[i]
		if (bx - ax) * (cy - by) - (by - ay) * (cx - bx) < -1e-12 then
			convex = false
			break
		end
		ax, ay, bx, by = bx, by, cx, cy
	end
	if convex then
		Visibility.poly(sg, GX, GY, m)
		Visibility.piece()
		return
	end
	-- winding number of the closed clip = sum of signed fan triangles
	local x0, y0 = GX[1], GY[1]
	for i = 2, m - 1 do
		local x1, y1, x2, y2 = GX[i], GY[i], GX[i + 1], GY[i + 1]
		local t = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0)
		if t > 0 then
			TRX[1], TRY[1], TRX[2], TRY[2], TRX[3], TRY[3] = x0, y0, x1, y1, x2, y2
			Visibility.poly(sg, TRX, TRY, 3)
			Visibility.piece()
		elseif t < 0 then
			TRX[1], TRY[1], TRX[2], TRY[2], TRX[3], TRY[3] = x0, y0, x2, y2, x1, y1
			Visibility.poly(-sg, TRX, TRY, 3)
			Visibility.piece()
		end
	end
end

-- Region areas ---------------------------------------------------------------------

-- Area of polygon (px, py)[1..m] intersected with discs K[1..k] (power cells).
local function regionArea(px: { number }, py: { number }, m: number, k: number): number
	stats.areas += 1
	if k == 0 then
		return polyArea(px, py, m)
	elseif k == 1 then
		return discPolyArea(px, py, m, KX[1], KY[1], KR[1])
	end
	local total = 0
	for i = 1, k do
		local xi, yi, ri = KX[i], KY[i], KR[i]
		local powi = xi * xi + yi * yi - ri * ri
		for v = 1, m do
			CX[v], CY[v] = px[v], py[v]
		end
		local n = m
		local inC = true -- current cell polygon is in CX/CY (else DX2/DY2)
		local empty = false
		for j = 1, k do
			if j ~= i then
				local xj, yj, rj = KX[j], KY[j], KR[j]
				-- p_i >= p_j  <=>  2 (c_i - c_j) . q <= (|c_i|^2 - r_i^2) - (|c_j|^2 - r_j^2)
				local nx, ny = 2 * (xi - xj), 2 * (yi - yj)
				local c = powi - (xj * xj + yj * yj - rj * rj)
				if nx == 0 and ny == 0 then
					if not (c > 0 or (c == 0 and j > i)) then
						empty = true
						break
					end
				else
					if inC then
						n = clipInto(CX, CY, n, DX2, DY2, nx, ny, c)
					else
						n = clipInto(DX2, DY2, n, CX, CY, nx, ny, c)
					end
					inC = not inC
					if n < 3 then
						empty = true
						break
					end
				end
			end
		end
		if not empty then
			if inC then
				total += discPolyArea(CX, CY, n, xi, yi, ri)
			else
				total += discPolyArea(DX2, DY2, n, xi, yi, ri)
			end
		end
	end
	return total
end

-- Processes the shape begun with Visibility.begin against every current term.
function Visibility.commit()
	local nOld = nT
	local contrib = 0
	for t = 1, nOld do
		local wt = TW[t]
		if wt == 0 then
			continue
		end
		for p = 1, nP do
			-- polygon of term t intersected with piece p (both convex)
			local X, Y = VX, VY
			local m
			local p0, pn = PV0[p], PN[p]
			if t == 1 then
				-- term 1 is the whole pixel; pieces already lie inside it
				for v = 1, pn do
					VX[v], VY[v] = PX[p0 + v - 1], PY[p0 + v - 1]
				end
				m = pn
			else
				local t0 = TV0[t]
				m = TN[t]
				for v = 1, m do
					VX[v], VY[v] = TX[t0 + v - 1], TY[t0 + v - 1]
				end
				local qx, qy = PX[p0 + pn - 1], PY[p0 + pn - 1]
				for v = 0, pn - 1 do
					local rx, ry = PX[p0 + v], PY[p0 + v]
					local ex, ey = rx - qx, ry - qy
					-- interior on the left: cross(e, q - P) >= 0  <=>  ey x - ex y <= ey Px - ex Py
					local c = ey * qx - ex * qy
					if X == VX then
						m = clipInto(VX, VY, m, UX, UY, ey, -ex, c)
						X, Y = UX, UY
					else
						m = clipInto(UX, UY, m, VX, VY, ey, -ex, c)
						X, Y = VX, VY
					end
					if m < 3 then
						break
					end
					qx, qy = rx, ry
				end
			end
			if m < 3 then
				continue
			end
			-- discs of the region: the term's and the piece's
			local k = 0
			local d0 = TD0[t]
			for i = d0, d0 + TND[t] - 1 do
				k += 1
				KX[k], KY[k], KR[k] = TDX[i], TDY[i], TDR[i]
			end
			if PD[p] == 1 then
				k += 1
				KX[k], KY[k], KR[k] = PDX[p], PDY[p], PDR[p]
			end
			local a = regionArea(X, Y, m, k)
			if a <= 0 then
				continue
			end
			local sw = PS[p] * wt
			contrib += sw * a
			if nT >= MAX_TERMS then
				stats.capped += 1
				continue
			end
			nT += 1
			stats.terms += 1
			TW[nT] = -eA * sw
			TA[nT] = a
			TV0[nT] = nTV + 1
			TN[nT] = m
			for v = 1, m do
				TX[nTV + v], TY[nTV + v] = X[v], Y[v]
			end
			nTV += m
			TD0[nT] = nTD + 1
			TND[nT] = k
			for i = 1, k do
				TDX[nTD + i], TDY[nTD + i], TDR[nTD + i] = KX[i], KY[i], KR[i]
			end
			nTD += k
		end
	end
	local f = eA * contrib
	accR += eR * f
	accG += eG * f
	accB += eB * f
	accA += f
end

-- Adds the base below the stack (straight colour, alpha) and returns the exact
-- composite in straight alpha: r, g, b in 0..255, a in 0..1.
function Visibility.finish(r: number, g: number, b: number, a: number): (number, number, number, number)
	local W = 0
	for t = 1, nT do
		W += TW[t] * TA[t]
	end
	local k = a * W
	local R, G, B, A = accR + r * k, accG + g * k, accB + b * k, accA + k
	if A <= 0 then
		return r, g, b, 0
	end
	return R / A, G / A, B / A, if A > 1 then 1 else A
end

-- The premultiplied integrals accumulated so far (for tests): r, g, b, a.
function Visibility.accumulated(): (number, number, number, number)
	return accR, accG, accB, accA
end

return Visibility
