--!strict
-- Universe at Home: Planets :: Layout
--
-- Every size the planet system shares between the tile generator (workers), the mesh
-- pool and atlases (client) and the tests. Changing a number here changes all of them.
--
-- ATLAS TILES. A body's surface is drawn by patches of a cube-sphere quadtree. Each patch
-- owns one tile of a 1024 x 1024 atlas (16 x 16 tiles of 64 px). One atlas per map
-- (colour, normal; roughness at half resolution) because Roblox refreshes only one
-- displayed EditableImage per frame: one atlas carries any number of tile updates in that
-- single refresh, where one image per patch would take one frame per patch.
--
-- TEXEL CENTRES ON THE PATCH EDGE. Tile pixel k (0..63) has its centre at patch parameter
--     s(k) = (k - GUTTER) / SPAN = (k - 1) / 61
-- so pixel 1 sits exactly on the patch's first edge (s = 0) and pixel 62 on the last
-- (s = 1). Two patches that share an edge therefore sample the very same surface points
-- there, and bilinear filtering at the edge reads exactly that texel: no seams. Pixels 0
-- and 63 are the gutter: the surface function evaluated just beyond the edge, so the
-- filter never reads a neighbouring tile (EditableImages have no mips, so one texel of
-- gutter is all the filter footprint needs).
--
-- UV of patch parameter (s, t) in tile (tx, ty):
--     u = (tx * TILE + GUTTER + 0.5 + s * SPAN) / ATLAS,   v likewise with (ty, t)
-- v grows downward in the image (row 0 at the top), the UV origin Roblox meshes use.
-- Tests assert both rules (tests/planets.test.luau).

local Layout = {}

Layout.ATLAS = 1024 -- colour and normal atlas size (pixels)
Layout.TILE = 64 -- tile size including the gutter
Layout.GUTTER = 1
Layout.SPAN = 61 -- texel intervals across a patch (TILE - 2 * GUTTER - 1)
Layout.TILES_PER_ROW = 16 -- ATLAS / TILE
Layout.SLOTS = 256 -- TILES_PER_ROW ^ 2: patches a body can show at once

Layout.ROUGH_ATLAS = 512 -- roughness atlas (half resolution, same UVs)
Layout.ROUGH_TILE = 32

-- The generator samples one ring of texels beyond the tile to take central differences
-- for normals: sample index k = -1 .. 64, i.e. SAMPLES = 66 per row.
Layout.SAMPLES = 66

-- Patch mesh: GRID x GRID quads (GRID + 1)^2 vertices, a skirt along each edge, and two
-- zero-area triangles that pin the mesh's bounding box (see MeshPool).
Layout.GRID = 16
Layout.GRID_VERTS = (16 + 1) * (16 + 1) -- 289
Layout.SKIRT_VERTS = 4 * (16 + 1) -- 68
Layout.PIN_VERTS = 6
Layout.VERTS = 289 + 68 + 6 -- 363
Layout.GRID_TRIS = 16 * 16 * 2 -- 512
Layout.SKIRT_TRIS = 4 * 16 * 2 -- 128
Layout.PIN_TRIS = 2
Layout.TRIS = 512 + 128 + 2 -- 642

-- Every patch mesh shares one bounding box, centred on the body's centre: +-PIN_EXTENT
-- studs on every axis. It must exceed the largest body radius plus its highest mountain.
Layout.PIN_EXTENT = 1900

-- Clouds: six faces of 256 px in a 1024 x 512 atlas (4 x 2 tiles, two unused).
Layout.CLOUD_ATLAS_W = 1024
Layout.CLOUD_ATLAS_H = 512
Layout.CLOUD_TILE = 256
Layout.CLOUD_SPAN = 253 -- CLOUD_TILE - 2 * GUTTER - 1
Layout.CLOUD_GRID = 16

-- Tile (tx, ty) of slot index (0-based).
function Layout.tileOf(slot: number): (number, number)
	return slot % Layout.TILES_PER_ROW, slot // Layout.TILES_PER_ROW
end

-- Patch parameter of the centre of tile pixel k (0-based), and its inverse.
function Layout.paramOfPixel(k: number): number
	return (k - Layout.GUTTER) / Layout.SPAN
end

-- UV of patch parameter (s, t) in tile (tx, ty) of the 1024 atlas.
function Layout.uv(tx: number, ty: number, s: number, t: number): (number, number)
	local a = Layout.ATLAS
	local base = Layout.GUTTER + 0.5
	return (tx * Layout.TILE + base + s * Layout.SPAN) / a, (ty * Layout.TILE + base + t * Layout.SPAN) / a
end

-- Vertex index (0-based) of grid vertex (vi, vj), vi along s, vj along t.
function Layout.gridVertex(vi: number, vj: number): number
	return vj * (Layout.GRID + 1) + vi
end

return Layout
