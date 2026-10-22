--!strict
-- Universe at Home: Meadow :: Config
--
-- Every tunable of the demo in one pure table, shared by server, client, workers and
-- the CLI tests. Nothing here touches the engine. Changing a value that feeds a
-- generator (seed, world, grass, sky) changes the hashes asserted in
-- tests/demo.test.luau, on purpose.

local Config = {}

Config.VERSION = "M4"
Config.TAG = "MEADOW" -- prefix of every machine-readable Output line

Config.seed = 20261022

-- The landscape: 1024 x 1024 studs of 4-stud voxels, heights up to 256 studs.
Config.world = {
	size = 1024, -- studs per side
	voxel = 4, -- studs per voxel (WriteVoxels resolution must be 4)
	columns = 256, -- size / voxel
	origin = -512, -- world X and Z of the first column's lower edge
	maxHeight = 256, -- studs; 64 voxel layers
	minHeight = 6,
	waterLevel = 46, -- one water plane shared by lake and river
	chunkColumns = 16, -- a chunk is 16 x 16 columns (64 x 64 studs)
	shell = 12, -- studs of solid below the lowest neighbouring surface (hollow below)
	erosionIterations = 6,
	talus = 4.6, -- studs of height difference between 4-stud neighbours before material slides
	erosionRate = 0.3,
	-- meadow, hills and mountains
	meadowBase = 60,
	meadowAmplitude = 7,
	hillAmplitude = 34,
	mountainBase = 24,
	mountainAmplitude = 196,
	mountainInner = 270, -- radius where the mountain ring starts
	mountainOuter = 480, -- radius where it is at full height
	warpAmplitude = 70,
	-- the river: a polyline from the north-east mountains into the lake
	river = {
		points = { 520, -420, 330, -270, 210, -120, 120, -10, 10, 100, -95, 160, -185, 205 },
		width = 9, -- half width of the flat bed
		bank = 26, -- width of the bank slope at meadow height
		depth = 7, -- bed depth below the water level
		meander = 26, -- studs of meander warp
	},
	lake = { x = -205, z = 215, radius = 96, depth = 16, shore = 44 },
	spawn = { x = 0, z = 0 },
	snowLine = 178,
	alpineLine = 138,
	cliffSlope = 1.15, -- height difference per stud above which a column is a cliff
}

-- Terrain look. Colours are RGB 0..255 (converted with Color3.fromRGB by the server).
Config.terrain = {
	decoration = true, -- set in the project file (Terrain.Decoration is NotScriptable)
	grassLength = 0.85, -- likewise
	waterColor = { 38, 92, 96 },
	waterTransparency = 0.55,
	waterReflectance = 0.85,
	waterWaveSize = 0.12,
	waterWaveSpeed = 9,
	materialColors = {
		Grass = { 86, 128, 52 },
		LeafyGrass = { 92, 118, 50 },
		Ground = { 104, 86, 64 },
		Mud = { 86, 70, 56 },
		Sand = { 196, 182, 140 },
		Rock = { 112, 108, 102 },
		Slate = { 92, 94, 96 },
		Limestone = { 170, 162, 146 },
		Snow = { 238, 241, 246 },
		Glacier = { 168, 198, 220 },
	},
}

-- Golden hour.
Config.lighting = {
	clockTime = 17.55,
	geographicLatitude = 38,
}

-- Procedural sky: six faces rendered on the server and baked.
Config.sky = {
	faceSize = 512,
	-- the sky dome colours by elevation (RGB 0..255)
	zenith = { 64, 108, 176 },
	mid = { 132, 168, 214 },
	horizon = { 246, 196, 140 },
	ground = { 120, 110, 100 },
	sunGlow = { 255, 190, 110 },
	cloudColor = { 255, 236, 214 },
	cloudShadow = { 150, 140, 150 },
	cloudCover = 0.52,
	-- 0 places the horizon glow toward the sun direction under the assumed face
	-- orientation (docs/DEMO.md, Known limits); adjust if it looks rotated.
	azimuthOffsetTurns = 0,
}

-- Rocks: noise-displaced icospheres scattered on the slopes.
Config.rocks = {
	count = 36,
	subdivisions = 2,
	minRadius = 2.5,
	maxRadius = 9,
	roughness = 0.32,
}

-- Grass rings (docs/DEMO.md section 3).
Config.grass = {
	ring0 = 24, -- blade geometry inside this radius (studs)
	ring1 = 96, -- shell grass up to this radius
	patch = 4, -- studs per side of a blade patch (rigid wind tilt keeps edges in the ground)
	bladesPerPatch = 300, -- density x1 (T11 multiplies it): 18.75 blades per square stud
	bladeSegments = 2, -- quads per blade below the tip: 2 * 2 + 1 = 5 triangles
	bladeSegmentsFar = 1, -- 3 triangles for the sparse outer variant
	lodNear = 12, -- studs: full density inside, 60 percent beyond (Saturn selector)
	lodFar = 18, -- 30 percent beyond
	bladeHeight = 1.25, -- studs, average
	bladeHeightJitter = 0.55,
	bladeWidth = 0.075, -- studs at the root
	clumpCell = 1.4, -- studs; blades lean and share hue inside a clump cell
	shellCount = 12,
	shellHeight = 1.05, -- studs from shell 0 to the top shell
	shellTile = 16, -- studs per shell sheet side
	shellTexture = 256, -- alpha mask resolution of a shell layer (one 4 x 4 stud repeat)
	shellRepeat = 4, -- studs per mask repeat (= sheet grid spacing)
	shellBlades = 2600, -- blade cross-sections per mask
	shellBladeRadius = 0.011, -- base radius in tile units (2.8 px at 256)
	shellLeanPx = 22, -- lean of a blade tip in mask pixels
	fadeWidth = 6, -- studs of crossfade at each ring boundary
	hysteresis = 1.15, -- LOD hysteresis factor (Saturn eta)
	fadeSeconds = 0.6,
	windStrength = 0.22, -- radians of tilt at full gust
	windSpeed = 0.9, -- wave fronts per second
	windWavelength = 38, -- studs
	interactRadius = 3.2,
	maxPatches = 40, -- pool size of ring-0 patches
}

-- Actors.
Config.actors = {
	serverWorldGen = 8,
	serverRocks = 2,
	serverTraining = 1,
	clientRender = 8,
	clientGrass = 4,
	clientWind = 1,
	jobTimeout = 20, -- seconds before a worker job is declared lost and redone serially
}

-- Stress bench (docs/DEMO.md section 4).
Config.bench = {
	budgetImageSize = 256,
	budgetMaxImages = 512,
	rasterShapes = 256,
	rasterSize = 1024,
	rasterSeed = 7,
	actorCounts = { 1, 2, 4, 8 },
	uploadImages = 32,
	uploadSize = 128,
	atlasSprites = 1024,
	atlasSize = 512,
	giantSize = 4096,
	giantTiles = 4,
	giantGutter = 2,
	lodSurfaces = 64,
	trainingSlices = 12,
	densities = { 1, 2, 4 },
	refereeTimeout = 30,
}

-- HUD.
Config.hud = {
	refreshSeconds = 0.25,
}

return Config
