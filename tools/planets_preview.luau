--!nonstrict
-- Renders planet tiles in the Luau CLI and prints them as hex panels for
-- tools/gallery_preview.py (PANEL name w h, then h lines of w little-endian RGBA words).
--
--   luau tools/planets_preview.luau -a mosaic terra 5 2 | python3 tools/gallery_preview.py OUT
--       a face of a body at a level: colour, normal map, and a lit render that decodes the
--       normal map the way an engine would (checks the encoding end to end)
--   luau tools/planets_preview.luau -a bench terra 6
--       tile generation time at a level

local Layout = require("../planets/shared/Layout")
local TileGen = require("../planets/shared/TileGen")
local CubeSphere = require("../planets/shared/CubeSphere")

local args = { ... }
local mode = args[1] or "mosaic"
local body = args[2] or "terra"
local face = tonumber(args[3]) or 5
local level = tonumber(args[4]) or 2
local ci = tonumber(args[5]) -- optional: one patch column and row at this level
local cj = tonumber(args[6])

local function dump(name: string, buf: buffer, w: number, h: number)
	print(string.format("PANEL %s %d %d", name, w, h))
	for y = 0, h - 1 do
		local parts = table.create(w, "")
		for x = 0, w - 1 do
			parts[x + 1] = string.format("%08x", buffer.readu32(buf, (y * w + x) * 4))
		end
		print(table.concat(parts))
	end
end

if mode == "bench" then
	local n = 0
	local t0 = os.clock()
	local worst = 0
	for i = 0, 3 do
		local r = TileGen.generate({ body = body, face = face, level = level, i = i, j = 1 })
		n += 1
		worst = math.max(worst, r.ms)
	end
	local dt = os.clock() - t0
	print(string.format("TIME %s level %d: %.1f ms per tile (worst %.1f), %.1f tiles/s", body, level, dt / n * 1000, worst, n / dt))
	return
end

-- mosaic of the interior pixels (gutters dropped) of a block of patches
local count = 2 ^ level
local i0, j0, n = 0, 0, count
if ci and cj then
	i0, j0, n = ci, cj, 1
elseif count > 4 then
	-- a 4 x 4 block around the face centre
	i0, j0, n = count // 2 - 2, count // 2 - 2, 4
end
local inner = Layout.TILE - 2 * Layout.GUTTER
local W = inner * n
local col = buffer.create(W * W * 4)
local nrm = buffer.create(W * W * 4)
local lit = buffer.create(W * W * 4)
-- light from the upper left, raised 35 degrees above the local horizon, in tangent space
local Lx, Ly, Lz = -0.58, 0.58, 0.57
local ll = math.sqrt(Lx * Lx + Ly * Ly + Lz * Lz)
Lx, Ly, Lz = Lx / ll, Ly / ll, Lz / ll
local total = 0
for pj = 0, n - 1 do
	for pi = 0, n - 1 do
		local r = TileGen.generate({ body = body, face = face, level = level, i = i0 + pi, j = j0 + pj })
		total += r.ms
		for y = 0, inner - 1 do
			for x = 0, inner - 1 do
				local src = ((y + Layout.GUTTER) * Layout.TILE + x + Layout.GUTTER) * 4
				local dst = ((pj * inner + y) * W + pi * inner + x) * 4
				local c = buffer.readu32(r.color, src)
				local nv = buffer.readu32(r.normal, src)
				buffer.writeu32(col, dst, c)
				buffer.writeu32(nrm, dst, nv)
				-- decode: red along +s (image right), green towards the image top
				local tx = (nv % 256) / 255 * 2 - 1
				local ty = ((nv // 256) % 256) / 255 * 2 - 1
				local tz = ((nv // 65536) % 256) / 255 * 2 - 1
				local d = tx * Lx + ty * Ly + tz * Lz
				local shade = 0.12 + 0.88 * math.max(0, d)
				local cr = (c % 256) * shade
				local cg = ((c // 256) % 256) * shade
				local cb = ((c // 65536) % 256) * shade
				buffer.writeu32(lit, dst, math.floor(cr) + math.floor(cg) * 256 + math.floor(cb) * 65536 + 4278190080)
			end
		end
	end
end
print(string.format("TIME %s face %d level %d: %d tiles, %.1f ms per tile", body, face, level, n * n, total / (n * n)))
dump(string.format("%s_f%d_L%d_color", body, face, level), col, W, W)
dump(string.format("%s_f%d_L%d_normal", body, face, level), nrm, W, W)
dump(string.format("%s_f%d_L%d_lit", body, face, level), lit, W, W)
