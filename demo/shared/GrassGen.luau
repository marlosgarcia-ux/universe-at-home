--!strict
--!native
--!optimize 2
-- Universe at Home: Meadow :: GrassGen
--
-- Pure, deterministic grass generators (docs/DEMO.md section 3), shared by the client
-- grass Actors, the server baker and the CLI tests.
--
--   patch       ring 0 blade geometry: curved, tapered blades (quadratic Bezier spine,
--               width narrowing to a tip), 2 * segments + 1 triangles each, vertex
--               colours from a palette (root to tip gradient x clump hue), upward-bent
--               normals from a small palette; clumping cells share lean, hue and height
--   bend        interaction: blades near a point pushed away (per-vertex, rest copy)
--   maskBlades  ring 1 blade cross-sections in one tileable 4 x 4 stud cell
--   renderMask  the alpha mask of shell layer k, rendered by the flawless rasterizer
--               (src/compute/Raster, exact-area coverage) with a built-in fallback
--   sheet       the terrain-following sheet topology for the shells (annulus of quads,
--               each quad one mask repeat, per-vertex alpha for the ring crossfades)
--
-- Deterministic ops only (RUNTIME_AUDIT 6.5): MyMath hashing, + - * / sqrt floor and
-- MyMath.dsinTurns / dcosTurns (no libm).

local MyMath = require("../Universe/MyMath")
local Rings = require("./Rings")

local GrassGen = {}

local hash32 = MyMath.hash32
local hash2 = MyMath.hash2
local dsin, dcos = MyMath.dsinTurns, MyMath.dcosTurns
local sqrt = math.sqrt
local floor = math.floor
local TWO32 = 4294967296

GrassGen.LEVELS = 8 -- colour steps from root to tip
GrassGen.HUES = 6 -- clump hue variants
GrassGen.NORMAL_DIRS = 8

-- Palette (r, g, b in 0..1): index = hue * LEVELS + level + 1. Golden-hour meadow:
-- dark olive roots, saturated mid blades, warm sunlit tips.
local PALETTE: { { number } } = {}
do
	local root = { 0.09, 0.17, 0.04 }
	local mid = { 0.26, 0.42, 0.10 }
	local tip = { 0.62, 0.66, 0.28 }
	local hueShift = {
		{ 1.00, 1.00, 1.00 },
		{ 1.10, 1.02, 0.80 },
		{ 0.92, 1.04, 1.06 },
		{ 1.18, 1.05, 0.70 },
		{ 0.86, 0.96, 0.92 },
		{ 1.04, 0.94, 0.86 },
	}
	for h = 1, GrassGen.HUES do
		for l = 0, GrassGen.LEVELS - 1 do
			local t = l / (GrassGen.LEVELS - 1)
			local c = table.create(3, 0)
			for ch = 1, 3 do
				local v
				if t < 0.5 then
					v = root[ch] + (mid[ch] - root[ch]) * (t * 2)
				else
					v = mid[ch] + (tip[ch] - mid[ch]) * ((t - 0.5) * 2)
				end
				v *= hueShift[h][ch]
				c[ch] = if v > 1 then 1 else v
			end
			table.insert(PALETTE, c)
		end
	end
end
GrassGen.PALETTE = PALETTE

-- Normals: up, bent toward one of 8 facing directions (soft, ground-like lighting).
local NORMALS: { { number } } = {}
for d = 0, GrassGen.NORMAL_DIRS - 1 do
	local a = d / GrassGen.NORMAL_DIRS
	local x, z, y = dcos(a) * 0.45, dsin(a) * 0.45, 0.8
	local l = sqrt(x * x + y * y + z * z)
	table.insert(NORMALS, { x / l, y / l, z / l })
end
GrassGen.NORMALS = NORMALS

local function rng(seed: number): () -> number
	local h = hash32(seed % TWO32)
	return function(): number
		h = hash32((h + 0x9E3779B9) % TWO32)
		return h / TWO32
	end
end
GrassGen.rng = rng

export type PatchOptions = {
	seed: number,
	blades: number,
	segments: number, -- quads per blade below the tip triangle
	size: number, -- studs per side
	height: number,
	heightJitter: number,
	width: number,
	clump: number, -- clump cell size (studs)
	sink: number?, -- studs of blade below the patch plane
}

export type Patch = {
	positions: { number },
	tris: { number },
	colorIndex: { number },
	normalIndex: { number },
	bladeFirst: { number },
	bladeRootX: { number },
	bladeRootZ: { number },
	bladeHeight: { number },
	bladeVerts: number,
	vertexCount: number,
	triangleCount: number,
	bladeCount: number,
}

function GrassGen.patch(o: PatchOptions): Patch
	local rnd = rng(o.seed)
	local S = o.segments
	local half = o.size * 0.5
	local sink = o.sink or 0.25
	local positions: { number } = {}
	local tris: { number } = {}
	local colorIndex: { number } = {}
	local normalIndex: { number } = {}
	local bladeFirst: { number } = {}
	local rootX: { number } = {}
	local rootZ: { number } = {}
	local heights: { number } = {}
	local bladeVerts = 2 * (S + 1) + 1
	local v = 0
	for b = 1, o.blades do
		local x = (rnd() - 0.5) * o.size
		local z = (rnd() - 0.5) * o.size
		-- clump cell: shared lean, hue and height factor
		local cx = floor((x + half + 1000) / o.clump)
		local cz = floor((z + half + 1000) / o.clump)
		local ch = hash2(cx, cz, o.seed + 77)
		local clumpLean = (ch % 1000) / 1000
		local hue = (floor(ch / 1000) % GrassGen.HUES)
		local clumpHeight = 0.8 + ((floor(ch / 6000) % 1000) / 1000) * 0.45
		local facing = rnd()
		local lean = clumpLean + (rnd() - 0.5) * 0.18
		local bend = 0.25 + rnd() * 0.45
		local H = o.height * (1 - o.heightJitter * 0.5 + o.heightJitter * rnd()) * clumpHeight
		local W = o.width * (0.75 + rnd() * 0.5)
		local fx, fz = dcos(facing), dsin(facing)
		local lx, lz = dcos(lean), dsin(lean)
		local bendH = bend * H * 0.6
		-- Bezier control points (P0 root, P1 straight up, P2 tip)
		local p0x, p0y, p0z = x, -sink, z
		local p1x, p1y, p1z = x, -sink + 0.55 * H, z
		local p2x, p2y, p2z = x + lx * bendH, -sink + H * (1 - 0.3 * bend * bend), z + lz * bendH
		local nIdx = (floor(facing * GrassGen.NORMAL_DIRS + 0.5) % GrassGen.NORMAL_DIRS) + 1
		table.insert(bladeFirst, v + 1)
		table.insert(rootX, x)
		table.insert(rootZ, z)
		table.insert(heights, H)
		for l = 0, S do
			local t = l / (S + 1)
			local a, bb, c = (1 - t) * (1 - t), 2 * t * (1 - t), t * t
			local px = a * p0x + bb * p1x + c * p2x
			local py = a * p0y + bb * p1y + c * p2y
			local pz = a * p0z + bb * p1z + c * p2z
			local w = W * 0.5 * (1 - 0.85 * t)
			-- side vector perpendicular to the facing direction
			local sx, sz = -fz * w, fx * w
			table.insert(positions, px - sx)
			table.insert(positions, py)
			table.insert(positions, pz - sz)
			table.insert(positions, px + sx)
			table.insert(positions, py)
			table.insert(positions, pz + sz)
			local level = floor(t * (GrassGen.LEVELS - 1) + 0.5)
			local ci = hue * GrassGen.LEVELS + level + 1
			table.insert(colorIndex, ci)
			table.insert(colorIndex, ci)
			table.insert(normalIndex, nIdx)
			table.insert(normalIndex, nIdx)
		end
		table.insert(positions, p2x)
		table.insert(positions, p2y)
		table.insert(positions, p2z)
		table.insert(colorIndex, hue * GrassGen.LEVELS + GrassGen.LEVELS)
		table.insert(normalIndex, nIdx)
		-- triangles: quads between pair levels, then the tip
		for l = 0, S - 1 do
			local L0, R0 = v + 2 * l + 1, v + 2 * l + 2
			local L1, R1 = v + 2 * l + 3, v + 2 * l + 4
			table.insert(tris, L0)
			table.insert(tris, R0)
			table.insert(tris, R1)
			table.insert(tris, L0)
			table.insert(tris, R1)
			table.insert(tris, L1)
		end
		local Lt, Rt, T = v + 2 * S + 1, v + 2 * S + 2, v + 2 * S + 3
		table.insert(tris, Lt)
		table.insert(tris, Rt)
		table.insert(tris, T)
		v += bladeVerts
	end
	return {
		positions = positions,
		tris = tris,
		colorIndex = colorIndex,
		normalIndex = normalIndex,
		bladeFirst = bladeFirst,
		bladeRootX = rootX,
		bladeRootZ = rootZ,
		bladeHeight = heights,
		bladeVerts = bladeVerts,
		vertexCount = v,
		triangleCount = #tris // 3,
		bladeCount = o.blades,
	}
end

-- Interaction: blades whose root lies within `radius` of (px, pz) (patch-local studs)
-- lean away from it. Writes every vertex into `out` (rest positions for the others).
-- Returns the number of bent blades.
function GrassGen.bend(p: Patch, px: number, pz: number, radius: number, strength: number, out: { number }): number
	local pos = p.positions
	local n = #pos
	for i = 1, n do
		out[i] = pos[i]
	end
	local bent = 0
	local r2 = radius * radius
	local nv = p.bladeVerts
	for b = 1, p.bladeCount do
		local dx, dz = p.bladeRootX[b] - px, p.bladeRootZ[b] - pz
		local d2 = dx * dx + dz * dz
		if d2 < r2 then
			bent += 1
			local d = sqrt(d2)
			local f = 1 - d / radius
			local push = strength * f * f
			local ux, uz = 0, 1
			if d > 1e-6 then
				ux, uz = dx / d, dz / d
			end
			local H = p.bladeHeight[b]
			local first = p.bladeFirst[b]
			local baseY = pos[(first - 1) * 3 + 2]
			for k = 0, nv - 1 do
				local o = (first - 1 + k) * 3
				local y = pos[o + 2] - baseY
				local t = y / H
				if t < 0 then
					t = 0
				end
				local s = push * H * t * t
				out[o + 1] = pos[o + 1] + ux * s
				out[o + 3] = pos[o + 3] + uz * s
				out[o + 2] = baseY + y * (1 - 0.45 * push * t)
			end
		end
	end
	return bent
end

----------------------------------------------------------------------------------
-- Ring 0 variants: the same four patches on every client and on the server baker
----------------------------------------------------------------------------------

GrassGen.VARIANTS = {
	{ name = "A", seed = 101, density = 1.0, far = false, level = 0 },
	{ name = "A2", seed = 202, density = 1.0, far = false, level = 0 },
	{ name = "B", seed = 303, density = 0.6, far = false, level = 1 },
	{ name = "C", seed = 404, density = 0.3, far = true, level = 2 },
}

-- Patch options of variant index v (1-based) for a grass config table (Config.grass)
-- and a density multiplier (T11).
function GrassGen.variantOptions(g: any, v: number, densityMul: number?): PatchOptions
	local spec = GrassGen.VARIANTS[v]
	local blades = math.max(1, floor(g.bladesPerPatch * spec.density * (densityMul or 1) + 0.5))
	return {
		seed = spec.seed,
		blades = blades,
		segments = if spec.far then g.bladeSegmentsFar else g.bladeSegments,
		size = g.patch,
		height = g.bladeHeight,
		heightJitter = g.bladeHeightJitter,
		width = g.bladeWidth,
		clump = g.clumpCell,
		sink = 0.25,
	}
end

----------------------------------------------------------------------------------
-- Shell masks (ring 1)
----------------------------------------------------------------------------------

export type MaskBlade = { u: number, v: number, r: number, hf: number, lx: number, ly: number, hue: number }

-- Blade cross-sections in one tile (u, v in [0, 1)). r is the base radius in tile
-- units, hf the blade height as a fraction of the shell stack, (lx, ly) the lean
-- direction, hue the palette hue.
function GrassGen.maskBlades(seed: number, count: number, baseRadius: number): { MaskBlade }
	local rnd = rng(seed + 5151)
	local out: { MaskBlade } = {}
	for i = 1, count do
		local u, v = rnd(), rnd()
		local cell = hash2(floor(u * 6), floor(v * 6), seed + 9)
		local lean = (cell % 1000) / 1000 + (rnd() - 0.5) * 0.2
		out[i] = {
			u = u,
			v = v,
			r = baseRadius * (0.7 + rnd() * 0.6),
			hf = 0.5 + rnd() * 0.5,
			lx = dcos(lean),
			ly = dsin(lean),
			hue = floor(cell / 1000) % GrassGen.HUES,
		}
	end
	return out
end

-- Colour of a blade at height fraction t of its own height, as packed RGBA8.
local function bladeColor(hue: number, t: number, alpha: number): number
	local level = floor(t * (GrassGen.LEVELS - 1) + 0.5)
	if level < 0 then
		level = 0
	elseif level > GrassGen.LEVELS - 1 then
		level = GrassGen.LEVELS - 1
	end
	local c = PALETTE[hue * GrassGen.LEVELS + level + 1]
	return MyMath.pack(floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5), alpha)
end
GrassGen.bladeColor = bladeColor

export type MaskShape = { x: number, y: number, r: number, color: number }

-- Circles (pixel units, wrapped copies included) of shell layer k of `layers` on a
-- size x size tile, plus the background colour.
function GrassGen.maskShapes(k: number, layers: number, size: number, blades: { MaskBlade }, leanPx: number): ({ MaskShape }, number)
	local t = if layers > 1 then k / (layers - 1) else 0
	local shapes: { MaskShape } = {}
	for _, b in blades do
		if t <= b.hf then
			local f = t / b.hf
			local r = b.r * size * (1 - 0.85 * f)
			if r < 0.45 then
				r = 0.45
			end
			local s = leanPx * f * f
			local x = b.u * size + b.lx * s
			local y = b.v * size + b.ly * s
			x = x - floor(x / size) * size
			y = y - floor(y / size) * size
			local color = bladeColor(b.hue, f, 255)
			-- wrapped copies so the tile repeats without seams
			for oy = -1, 1 do
				for ox = -1, 1 do
					local cx, cy = x + ox * size, y + oy * size
					if cx + r > -1 and cx - r < size + 1 and cy + r > -1 and cy - r < size + 1 then
						table.insert(shapes, { x = cx, y = cy, r = r, color = color })
					end
				end
			end
		end
	end
	-- shell 0 carries the ground: nearly opaque dark green under the blades
	local background = if k == 0 then MyMath.pack(30, 46, 14, 236) else 0
	return shapes, background
end

-- Built-in fallback rasterizer: discs with the linear coverage ramp (the preview
-- quality of Raster MODE_LINEAR), painter's order, straight alpha.
local function renderDiscs(shapes: { MaskShape }, background: number, size: number): buffer
	local out = buffer.create(size * size * 4)
	if background ~= 0 then
		for o = 0, size * size * 4 - 4, 4 do
			buffer.writeu32(out, o, background)
		end
	end
	for _, s in shapes do
		local x0 = math.max(0, floor(s.x - s.r - 1))
		local x1 = math.min(size - 1, floor(s.x + s.r + 1))
		local y0 = math.max(0, floor(s.y - s.r - 1))
		local y1 = math.min(size - 1, floor(s.y + s.r + 1))
		local sr, sg, sb = MyMath.unpack(s.color)
		for y = y0, y1 do
			for x = x0, x1 do
				local dx, dy = x + 0.5 - s.x, y + 0.5 - s.y
				local cov = MyMath.coverage(sqrt(dx * dx + dy * dy) - s.r, 1)
				if cov > 0 then
					local o = (y * size + x) * 4
					local p = buffer.readu32(out, o)
					local pr, pg, pb, pa = MyMath.unpack(p)
					local ia = 1 - cov
					local a = cov * 255 + pa * ia
					local r = sr * cov + pr * ia
					local g = sg * cov + pg * ia
					local b = sb * cov + pb * ia
					buffer.writeu32(out, o, MyMath.pack(floor(r + 0.5), floor(g + 0.5), floor(b + 0.5), floor(a + 0.5)))
				end
			end
		end
	end
	return out
end
GrassGen.renderDiscs = renderDiscs

-- Renders shell layer k with the flawless rasterizer (Raster, MODE_EXACT) when it
-- loads and accepts the scene, else with the fallback above. Returns the RGBA8
-- buffer and which renderer ran.
function GrassGen.renderMask(k: number, layers: number, size: number, seed: number, count: number, baseRadius: number, leanPx: number): (buffer, string)
	local blades = GrassGen.maskBlades(seed, count, baseRadius)
	local shapes, background = GrassGen.maskShapes(k, layers, size, blades, leanPx)
	local ok, result = pcall(function(): buffer
		local Raster = require("../Universe/compute/Raster") :: any
		local sc = Raster.newScene(background, 1, Raster.MODE_EXACT)
		for _, s in shapes do
			Raster.circle(sc, s.color, s.x, s.y, s.r)
		end
		local bins = Raster.bin(sc, size, size, 64)
		local out = buffer.create(size * size * 4)
		Raster.render(sc, bins, out, size, size, 4)
		return out
	end)
	if ok then
		return result, "Raster exact"
	end
	return renderDiscs(shapes, background, size), "fallback discs (" .. tostring(result) .. ")"
end

----------------------------------------------------------------------------------
-- Shell sheet topology (ring 1)
----------------------------------------------------------------------------------

export type Sheet = {
	n: number, -- vertices per side = 2 * half + 1
	half: number,
	spacing: number,
	vx: { number }, -- vertex local x (studs), 1-based vertex index
	vz: { number },
	alpha: { number }, -- per-vertex opacity (ring crossfades)
	quads: { number }, -- flat a, b, c, d vertex indices (a = (i, j), b = (i+1, j), c = (i, j+1), d = (i+1, j+1))
	quadCount: number,
}

-- Square grid of (2 half + 1)^2 vertices `spacing` studs apart, centred on the
-- origin, keeping the quads whose centre lies in [inner - fadeIn, outer]. Vertex
-- opacity follows the two-phase crossfade at both boundaries: shells are fully in
-- before ring 0 blades leave (inner) and fade out into the engine grass (outer).
function GrassGen.sheet(inner: number, outer: number, spacing: number, fadeIn: number, fadeOut: number): Sheet
	local half = math.ceil(outer / spacing)
	local n = 2 * half + 1
	local vx: { number } = table.create(n * n, 0)
	local vz: { number } = table.create(n * n, 0)
	local alpha: { number } = table.create(n * n, 0)
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local idx = j * n + i + 1
			local x, z = (i - half) * spacing, (j - half) * spacing
			vx[idx], vz[idx] = x, z
			local d = sqrt(x * x + z * z)
			local _, inOpacity = Rings.boundary(d, inner, fadeIn)
			local outOpacity = Rings.boundary(d, outer, fadeOut)
			alpha[idx] = inOpacity * outOpacity
		end
	end
	local quads: { number } = {}
	local lo = inner - fadeIn - spacing * 0.75
	for j = 0, n - 2 do
		for i = 0, n - 2 do
			local cx, cz = (i - half + 0.5) * spacing, (j - half + 0.5) * spacing
			local d = sqrt(cx * cx + cz * cz)
			if d >= lo and d <= outer + spacing * 0.5 then
				local a = j * n + i + 1
				table.insert(quads, a)
				table.insert(quads, a + 1)
				table.insert(quads, a + n)
				table.insert(quads, a + n + 1)
			end
		end
	end
	return { n = n, half = half, spacing = spacing, vx = vx, vz = vz, alpha = alpha, quads = quads, quadCount = #quads // 4 }
end

----------------------------------------------------------------------------------
-- Self test (run by tests/demo.test.luau in both runtimes)
----------------------------------------------------------------------------------

local function hashNumbers(t: { number }): number
	local b = buffer.create(#t * 8)
	for i, v in t do
		buffer.writef64(b, (i - 1) * 8, v)
	end
	local h = hash32(0x2545F491)
	for w = 0, buffer.len(b) // 4 - 1 do
		h = hash32(bit32.bxor(h, buffer.readu32(b, w * 4)))
	end
	return h
end
GrassGen.hashNumbers = hashNumbers

function GrassGen.selfTest(): (boolean, string?)
	local o: PatchOptions = { seed = 11, blades = 50, segments = 2, size = 4, height = 1.25, heightJitter = 0.55, width = 0.075, clump = 1.4 }
	local p = GrassGen.patch(o)
	if p.vertexCount ~= 50 * 7 or p.triangleCount ~= 50 * 5 then
		return false, string.format("patch counts %d %d", p.vertexCount, p.triangleCount)
	end
	if #p.positions ~= p.vertexCount * 3 or #p.colorIndex ~= p.vertexCount or #p.normalIndex ~= p.vertexCount then
		return false, "patch array sizes"
	end
	for i = 1, #p.tris do
		local v = p.tris[i]
		if v < 1 or v > p.vertexCount then
			return false, "triangle index out of range"
		end
	end
	for i = 1, #p.colorIndex do
		if p.colorIndex[i] < 1 or p.colorIndex[i] > #PALETTE then
			return false, "colour index out of range"
		end
	end
	for i = 1, p.vertexCount do
		local x, z = p.positions[3 * i - 2], p.positions[3 * i]
		if math.abs(x) > 3 or math.abs(z) > 3 then
			return false, "blade leaves its patch"
		end
	end
	local p2 = GrassGen.patch(o)
	if hashNumbers(p.positions) ~= hashNumbers(p2.positions) then
		return false, "patch not deterministic"
	end
	-- bending moves only blades near the point and keeps roots in place
	local out = {}
	local bent = GrassGen.bend(p, 0, 0, 1.5, 0.8, out)
	if bent == 0 or bent == p.bladeCount then
		return false, "bend count " .. bent
	end
	for b = 1, p.bladeCount do
		local o3 = (p.bladeFirst[b] - 1) * 3
		if out[o3 + 1] ~= p.positions[o3 + 1] or out[o3 + 3] ~= p.positions[o3 + 3] then
			return false, "bend moved a root"
		end
	end
	-- masks: deterministic, tileable, mostly transparent above shell 0
	local m1 = GrassGen.renderMask(3, 12, 64, 5, 120, 0.02, 8)
	local m2 = GrassGen.renderMask(3, 12, 64, 5, 120, 0.02, 8)
	if buffer.tostring(m1) ~= buffer.tostring(m2) then
		return false, "mask not deterministic"
	end
	local opaque = 0
	for o2 = 3, 64 * 64 * 4 - 1, 4 do
		if buffer.readu8(m1, o2) > 0 then
			opaque += 1
		end
	end
	if opaque == 0 or opaque > 64 * 64 * 0.9 then
		return false, "mask coverage " .. opaque
	end
	local s = GrassGen.sheet(24, 96, 4, 6, 10)
	if s.quadCount < 1000 or s.quadCount * 2 > 20000 then
		return false, "sheet quads " .. s.quadCount
	end
	for i = 1, #s.alpha do
		if s.alpha[i] < 0 or s.alpha[i] > 1 then
			return false, "sheet alpha out of range"
		end
	end
	return true, nil
end

return GrassGen
