--!strict
-- Universe at Home: Planets :: Config
--
-- Every number you are likely to change. In Studio: ReplicatedStorage > Planets > Config.
-- Raise a value, press Play. Memory figures are RGBA8 EditableImage bytes unless noted;
-- the client budget is unknown (reports say about 32 MB), so press X in the place to
-- measure it. EditableImages are at most 1024 x 1024.

return {
	-- SURFACE (Terra and Selene meshes)
	splitPx = 1.6, -- split a patch while one texel covers more than this many screen pixels (lower = sharper)
	capacity = 200, -- most patches shown at once; cannot exceed 256 (the atlas has 256 tiles; 9 MB)
	stressSplitPx = 0.8, -- the B key
	stressCapacity = 240,
	maxLevelTerra = 11, -- deepest quadtree level (level 11 = 0.02 studs per texel on Terra)
	maxLevelOther = 10,
	meshOn = 2.0, -- distance / radius under which a rocky body switches from billboard to mesh
	meshOff = 2.3, -- and over which it switches back (keep above meshOn)

	-- FAR BODIES (billboards)
	sphereCacheN = 128, -- texels per cube-face edge of the lookup cache; 256 = twice as sharp from orbit,
	-- but each of the workers keeps ~10 MB (3 bodies); 128 = ~2.4 MB each
	impostorMax = 512, -- largest billboard image (power of two, 32 to 1024); 1024 = 4 MB per body instead of 1 MB

	-- SPACE
	skyFace = 512, -- star skybox face size (up to 1024; 1024 = 24 MB instead of 6 MB)
	sunSize = 256,

	-- WORKERS
	workers = 6, -- Actors generating tiles and billboards
}
