--!nonstrict
-- Renders the planet impostors, a skybox face, the sun sprite and a cloud face in the CLI
-- and prints them as hex panels for tools/gallery_preview.py.
--   luau --codegen tools/planets_impostor_preview.luau | python3 tools/gallery_preview.py OUT
--   luau --codegen tools/planets_impostor_preview.luau -a terra    (one item)

local Impostor = require("../planets/shared/Impostor")
local SphereCache = require("../planets/shared/SphereCache")
local Bodies = require("../planets/shared/Bodies")
local SkyGen = require("../planets/shared/SkyGen")
local Clouds = require("../planets/shared/Clouds")
local Atmos = require("../planets/shared/Atmos")

local only = ...

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

-- composite over a dark backdrop so transparency is visible in the PNG
local function onBackdrop(buf: buffer, n: number): buffer
	local out = buffer.create(n * n * 4)
	for i = 0, n * n - 1 do
		local c = buffer.readu32(buf, i * 4)
		local r, g, b, a = c % 256, (c // 256) % 256, (c // 65536) % 256, c // 16777216
		local t = a / 255
		local br, bg, bb = 8, 10, 22
		local o = math.floor(r * t + br * (1 - t)) + math.floor(g * t + bg * (1 - t)) * 256 + math.floor(b * t + bb * (1 - t)) * 65536 + 4278190080
		buffer.writeu32(out, i * 4, o)
	end
	return out
end

local function normalize(x, y, z)
	local l = math.sqrt(x * x + y * y + z * z)
	return x / l, y / l, z / l
end

local EXPOSURE = 0.55

local function view(id: string, distance: number, azimuth: number, elevation: number, sun: { number }, n: number, tag: string?)
	local B = Bodies.get(id)
	local D = B.radius * distance
	local ce = math.cos(math.rad(elevation))
	local cx = D * ce * math.sin(math.rad(azimuth))
	local cy = D * math.sin(math.rad(elevation))
	local cz = D * ce * math.cos(math.rad(azimuth))
	local fx, fy, fz = normalize(-cx, -cy, -cz)
	-- right = forward x worldUp, up = right x forward
	local rx, ry, rz = normalize(fy * 0 - fz * 1, fz * 0 - fx * 0, fx * 1 - fy * 0)
	local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
	local extra = if B.rings then 2.4 elseif B.atmosphere then 1 + B.atmosphere.thickness * 1.5 else 1.02
	local half = Impostor.halfSize(B.radius, extra, D)
	local sx, sy, sz = normalize(sun[1], sun[2], sun[3])
	local t0 = os.clock()
	Atmos.ensure(id)
	print(string.format("TIME %s: atmosphere tables %.0f ms", id, (os.clock() - t0) * 1000))
	t0 = os.clock()
	local cache = SphereCache.build(id, 96)
	local tc = os.clock() - t0
	local out = buffer.create(n * n * 4)
	t0 = os.clock()
	Impostor.render(out, {
		body = id,
		n = n,
		cx = cx,
		cy = cy,
		cz = cz,
		rx = rx,
		ry = ry,
		rz = rz,
		ux = ux,
		uy = uy,
		uz = uz,
		half = half,
		sx = sx,
		sy = sy,
		sz = sz,
		cloudAngle = 0.3,
		exposure = EXPOSURE,
	}, cache, 0, n)
	print(string.format("TIME %s: cache %.0f ms, impostor %dx%d %.0f ms", id, tc * 1000, n, n, (os.clock() - t0) * 1000))
	dump("impostor_" .. id .. (tag or ""), onBackdrop(out, n), n, n)
end

if only == nil or only == "terra" then
	view("terra", 3.2, 25, 12, { 1, 0.35, 0.55 }, 320)
end
if only == nil or only == "terra2" then
	view("terra", 3.2, 25, 12, { -0.9, 0.1, 0.45 }, 320, "_dusk")
	view("terra", 3.2, 25, 12, { -0.5, 0.2, -0.85 }, 320, "_night")
end
if only == nil or only == "selene" then
	view("selene", 3.5, 20, 5, { 1, 0.25, 0.35 }, 256)
end
if only == nil or only == "saturnia" then
	view("saturnia", 7, 30, 16, { -0.8, 0.45, 0.6 }, 384)
end
if only == nil or only == "sky" then
	local t0 = os.clock()
	local face = SkyGen.face(1, 256, 5)
	print(string.format("TIME sky face 256: %.0f ms", (os.clock() - t0) * 1000))
	dump("sky_face", face, 256, 256)
	dump("sun", onBackdrop(SkyGen.sun(128, 0.22), 128), 128, 128)
end
if only == nil or only == "clouds" then
	local t0 = os.clock()
	local c = Clouds.face(5)
	print(string.format("TIME cloud face 256: %.0f ms", (os.clock() - t0) * 1000))
	dump("cloud_face", onBackdrop(c, 256), 256, 256)
end
