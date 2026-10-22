-- CLI shim: in Roblox, ReplicatedStorage.Planets modules reach ReplicatedStorage.Universe.MyMath
-- through the same relative path; this file forwards it to src/ for the Luau CLI tests.
-- Not part of the Rojo build (planets/default.project.json maps src/ directly).
return require("../../src/MyMath")
