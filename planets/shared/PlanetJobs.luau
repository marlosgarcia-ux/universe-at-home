--!strict
-- Universe at Home: Planets :: PlanetJobs
--
-- Job handlers for the client worker Actors (WorkerPool protocol, demo/shared/WorkerPool).
-- Every handler is pure Luau on numbers and buffers, so it runs desynchronized in an
-- Actor, inline in the serial fallback, and in the CLI. Results travel back as copies
-- (buffers included), so jobs return tiles and bands, never whole worlds.
--
--   tile        TileGen.generate(spec)                         -> TileGen.Result
--   cacheFace   SphereCache.buildFace(body, face, n)           -> buffer
--   setCache    store a body's assembled cache in this worker  -> true
--   impostor    Impostor rows [y0, y1) of a view as one band    -> { y0, y1, n, band }
--   skyFace     SkyGen.face(face, n, seed)                     -> buffer
--   cloudFace   Clouds.face(face)                              -> buffer
--   sun         SkyGen.sun(n, core)                            -> buffer

local TileGen = require("./TileGen")
local SphereCache = require("./SphereCache")
local Impostor = require("./Impostor")
local SkyGen = require("./SkyGen")
local Clouds = require("./Clouds")

type State = { [string]: any }

local Jobs = {}

Jobs.tile = {
	parallel = function(payload: any, state: State): any
		return TileGen.generate(payload)
	end,
}

Jobs.cacheFace = {
	parallel = function(payload: any, state: State): any
		return SphereCache.buildFace(payload.body, payload.face, payload.n)
	end,
}

Jobs.setCache = {
	parallel = function(payload: any, state: State): any
		local caches = state.caches
		if not caches then
			caches = {}
			state.caches = caches
		end
		caches[payload.body] = SphereCache.assemble(payload.body, payload.n, payload.faces)
		return true
	end,
}

Jobs.impostor = {
	parallel = function(payload: any, state: State): any
		local p = payload.params
		local caches = state.caches
		local cache = if caches then caches[p.body] else nil
		local rows = payload.y1 - payload.y0
		local band = buffer.create(rows * p.n * 4)
		Impostor.render(band, p, cache, payload.y0, payload.y1, payload.y0)
		return { y0 = payload.y0, y1 = payload.y1, n = p.n, band = band, cached = cache ~= nil }
	end,
}

Jobs.skyFace = {
	parallel = function(payload: any, state: State): any
		return SkyGen.face(payload.face, payload.n, payload.seed)
	end,
}

Jobs.cloudFace = {
	parallel = function(payload: any, state: State): any
		return Clouds.face(payload.face)
	end,
}

Jobs.sun = {
	parallel = function(payload: any, state: State): any
		return SkyGen.sun(payload.n, payload.core)
	end,
}

return Jobs
