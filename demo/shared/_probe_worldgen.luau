local WorldGen = require("./WorldGen")
local w = WorldGen.new()
local t0 = os.clock()
local heights, targets = WorldGen.bandHeights(w, 0, w.columns)
local t1 = os.clock()
WorldGen.erode(w, heights, targets)
local t2 = os.clock()
local lo, hi = math.huge, -math.huge
for o = 0, buffer.len(heights) - 4, 4 do
  local h = buffer.readf32(heights, o)
  if h < lo then lo = h end
  if h > hi then hi = h end
end
local hist = WorldGen.histogram(w, heights)
local t3 = os.clock()
local sx, sy, sz = WorldGen.findSpawn(w, heights)
print(string.format("bands %.0f ms, erode %.0f ms, classify %.0f ms", (t1-t0)*1000, (t2-t1)*1000, (t3-t2)*1000))
print("min/max", lo, hi, "spawn", sx, sy, sz)
for i, c in hist do print(WorldGen.MATERIAL_NAMES[i], c) end
print("hash", WorldGen.hashBuffer(heights))
local t4 = os.clock()
local total = 0
local order = WorldGen.chunkOrder(w)
for _, id in order do
  local cx, cz = id % 16, id // 16
  local j0, ny = WorldGen.chunkRange(w, heights, cx, cz)
  total += ny * 256
end
print("voxels", total, "chunk0", order[1], order[2], order[3])
print("chunkHash 8,8", WorldGen.chunkHash(w, heights, 8, 8), string.format("%.0f ms", (os.clock()-t4)*1000))
-- ascii map
local n = w.columns
local chars = {[0]=" ", "\"", ";", ".", "~", ":", "^", "%", "L", "*", "G", "w"}
for k = 0, n-1, 8 do
  local row = {}
  for i = 0, n-1, 4 do
    local h = WorldGen.heightAt(w, heights, i, k)
    local m = WorldGen.classify(w, heights, i, k)
    if h < w.waterLevel then row[#row+1] = "w" else row[#row+1] = chars[m] end
  end
  print(table.concat(row))
end
