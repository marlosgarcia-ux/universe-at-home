--!nonstrict
-- Diagnostic: how well the sphere cache's cloud channel reconstructs the cloud field.
local SphereCache = require("../planets/shared/SphereCache")
local Clouds = require("../planets/shared/Clouds")
local MyMath = require("../src/MyMath")
local n = tonumber((...)) or 128
local cache = SphereCache.build("terra", n)
local errs = {}
for k = 1, 4000 do
	local x, y, z = MyMath.rand2(k, 1, 7) * 2 - 1, MyMath.rand2(k, 2, 7) * 2 - 1, MyMath.rand2(k, 3, 7) * 2 - 1
	local l = math.sqrt(x * x + y * y + z * z)
	x, y, z = x / l, y / l, z / l
	local e = math.abs(SphereCache.cloud(cache, x, y, z) - Clouds.density(x, y, z))
	table.insert(errs, e)
end
table.sort(errs)
local sum = 0
for _, e in errs do sum += e end
print(string.format("n %d: mean %.4f  p50 %.4f  p90 %.4f  p99 %.4f  max %.4f", n, sum / #errs, errs[2000], errs[3600], errs[3960], errs[4000]))
