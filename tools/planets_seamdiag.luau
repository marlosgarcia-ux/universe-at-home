--!nonstrict
-- Diagnostic: colour and normal differences along shared patch edges (same level, same face).
local Layout = require("../planets/shared/Layout")
local TileGen = require("../planets/shared/TileGen")
local MyMath = require("../src/MyMath")
local args = { ... }
local L = tonumber(args[1]) or 5
local face = tonumber(args[2]) or 5
local n = 2 ^ L
local hist = {}
local nh = {}
local cases = 0
for rep = 0, 3 do
	local i, j = (n // 2 - 2 + rep) % n, (n // 2 - 1 + rep * 3) % n
	if i + 1 < n then
		local A = TileGen.generate({ body = "terra", face = face, level = L, i = i, j = j })
		local R = TileGen.generate({ body = "terra", face = face, level = L, i = i + 1, j = j })
		for m = 1, Layout.TILE - 2 do
			local c1 = buffer.readu32(A.color, (m * Layout.TILE + 62) * 4)
			local c2 = buffer.readu32(R.color, (m * Layout.TILE + 1) * 4)
			local a1, a2, a3 = MyMath.unpack(c1)
			local b1, b2, b3 = MyMath.unpack(c2)
			local d = math.max(math.abs(a1 - b1), math.abs(a2 - b2), math.abs(a3 - b3))
			hist[d] = (hist[d] or 0) + 1
			local n1 = buffer.readu32(A.normal, (m * Layout.TILE + 62) * 4)
			local n2 = buffer.readu32(R.normal, (m * Layout.TILE + 1) * 4)
			local p1, p2, p3 = MyMath.unpack(n1)
			local q1, q2, q3 = MyMath.unpack(n2)
			local dn = math.max(math.abs(p1 - q1), math.abs(p2 - q2), math.abs(p3 - q3))
			nh[dn] = (nh[dn] or 0) + 1
			cases += 1
		end
	end
end
local keys = {}
for k in hist do table.insert(keys, k) end
table.sort(keys)
local out = {}
for _, k in keys do table.insert(out, k .. ":" .. hist[k]) end
print("level " .. L .. " colour diff histogram (max channel diff:count): " .. table.concat(out, " "))
keys = {}
for k in nh do table.insert(keys, k) end
table.sort(keys)
out = {}
for _, k in keys do table.insert(out, k .. ":" .. nh[k]) end
print("level " .. L .. " normal diff histogram: " .. table.concat(out, " "))
