--!optimize 2
-- universe-at-home :: studio/EditableImageProbe.luau  (ModuleScript)
--
-- Measures what cannot be measured outside the Roblox engine:
--   1. limits      size bounds, default size, buffer-length rules, client memory budget
--   2. timings     run time of every public EditableImage method and the AssetService
--                  calls around it, as median and best of several runs
--   3. ops         an empirical truth table for every Enum.ImageCombineType, plus
--                  write/read round-trips that reveal the stored alpha convention,
--                  how DrawImageTransformed actually filters, and whether baking
--                  with CreateDataModelContentAsync keeps the bytes (probeBakeFidelity)
--
-- Usage: require this module from studio/RunProbe.client.luau (client budget, the
-- interesting case) or studio/RunProbe.server.luau. Everything is wrapped in pcall, so a
-- missing API or a changed contract shows up as a reported error instead of a crash.
-- Paste the printed report back into docs/RUNTIME_AUDIT.md section "Measured in engine".
--
-- Run it in a published place on a real device for budget numbers. Roblox documents
-- that Studio, servers and plugins have no editable memory budget.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local Probe = {}

local lines: { string } = {}
local function out(fmt: string, ...: any)
	local s = string.format(fmt, ...)
	table.insert(lines, s)
	print(s)
end

local function context(): string
	local where = if RunService:IsServer() then "server" else "client"
	if RunService:IsStudio() then
		where ..= " (Studio)"
	end
	return where
end

local function newImage(w: number, h: number): EditableImage?
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	if ok then
		return img
	end
	out("  CreateEditableImage(%dx%d) error: %s", w, h, tostring(img))
	return nil
end

local function median(samples: { number }): (number, number)
	table.sort(samples)
	return samples[(#samples + 1) // 2], samples[1]
end

-- Times fn n times. Yields between runs so long probes never trip the script timeout.
local function timeit(n: number, fn: () -> ()): (number, number)
	local samples = table.create(n, 0)
	for i = 1, n do
		local t0 = os.clock()
		fn()
		samples[i] = os.clock() - t0
		if i % 4 == 0 then
			task.wait()
		end
	end
	return median(samples)
end

local function report(name: string, n: number, pixels: number?, fn: () -> ())
	local ok, err = pcall(function()
		local med, best = timeit(n, fn)
		if pixels then
			out("  %-58s median %9.3f ms  best %9.3f ms  %8.2f Mpix/s", name, med * 1e3, best * 1e3, pixels / med / 1e6)
		else
			out("  %-58s median %9.3f ms  best %9.3f ms", name, med * 1e3, best * 1e3)
		end
	end)
	if not ok then
		out("  %-58s ERROR %s", name, tostring(err))
	end
end

local function fillPattern(img: EditableImage, w: number, h: number, seed: number)
	local b = buffer.create(w * h * 4)
	for i = 0, w * h - 1 do
		local v = (i * 2654435761 + seed) % 4294967296
		buffer.writeu32(b, i * 4, v)
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), b)
end

----------------------------------------------------------------------------------
-- 1. Limits
----------------------------------------------------------------------------------

local function probeLimits()
	out("## limits [%s]", context())

	local ok, img = pcall(function()
		return AssetService:CreateEditableImage()
	end)
	if ok and img then
		out("  default size: %s", tostring(img.Size))
		img:Destroy()
	else
		out("  default CreateEditableImage(): %s", tostring(img))
	end

	for _, s in { { 1, 1 }, { 1024, 1024 }, { 1025, 1 }, { 1, 1025 }, { 2048, 2048 }, { 4096, 4096 }, { 0, 0 }, { 100.5, 100.5 } } do
		local ok2, res = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(s[1], s[2]) })
		end)
		if ok2 and res then
			out("  create %gx%g -> ok, Size=%s", s[1], s[2], tostring(res.Size))
			-- can we write the whole thing in one call?
			local w, h = res.Size.X, res.Size.Y
			local okW, errW = pcall(function()
				res:WritePixelsBuffer(Vector2.zero, res.Size, buffer.create(w * h * 4))
			end)
			out("    full-size WritePixelsBuffer: %s", if okW then "ok" else tostring(errW))
			res:Destroy()
		elseif ok2 then
			out("  create %gx%g -> nil (budget)", s[1], s[2])
		else
			out("  create %gx%g -> error: %s", s[1], s[2], tostring(res))
		end
	end

	local img2 = newImage(16, 16)
	if img2 then
		local cases = {
			{ "buffer 1 byte short", function()
				img2:WritePixelsBuffer(Vector2.zero, Vector2.new(16, 16), buffer.create(16 * 16 * 4 - 1))
			end },
			{ "buffer 1 byte long", function()
				img2:WritePixelsBuffer(Vector2.zero, Vector2.new(16, 16), buffer.create(16 * 16 * 4 + 1))
			end },
			{ "write rect past right edge", function()
				img2:WritePixelsBuffer(Vector2.new(8, 0), Vector2.new(16, 1), buffer.create(16 * 4))
			end },
			{ "write at negative position", function()
				img2:WritePixelsBuffer(Vector2.new(-1, 0), Vector2.new(1, 1), buffer.create(4))
			end },
			{ "write at fractional position 0.5", function()
				img2:WritePixelsBuffer(Vector2.new(0.5, 0), Vector2.new(1, 1), buffer.create(4))
			end },
			{ "read rect past bottom edge", function()
				img2:ReadPixelsBuffer(Vector2.new(0, 8), Vector2.new(1, 16))
			end },
			{ "DrawRectangle partly outside", function()
				img2:DrawRectangle(Vector2.new(10, 10), Vector2.new(10, 10), Color3.new(1, 0, 0), 0, Enum.ImageCombineType.Overwrite)
			end },
			{ "DrawImage partly outside", function()
				local s = newImage(8, 8)
				if s then
					img2:DrawImage(Vector2.new(12, 12), s, Enum.ImageCombineType.Overwrite)
					s:Destroy()
				end
			end },
			{ "use after Destroy (ReadPixelsBuffer)", function()
				local s = newImage(4, 4)
				if s then
					s:Destroy()
					s:ReadPixelsBuffer(Vector2.zero, Vector2.new(4, 4))
				end
			end },
		}
		for _, c in cases do
			local okc, errc = pcall(c[2])
			out("  %-40s %s", c[1], if okc then "accepted" else "error: " .. tostring(errc))
		end
		img2:Destroy()
	end
end

local function probeBudget()
	out("## budget [%s]", context())
	-- Allocate 256x256 images (256 KiB of RGBA each) until creation returns nil.
	-- Capped at 4096 images (1 GiB) because servers and Studio have no budget.
	local made: { EditableImage } = {}
	local cap = 4096
	local t0 = os.clock()
	while #made < cap do
		local ok, img = pcall(function()
			return AssetService:CreateEditableImage({ Size = Vector2.new(256, 256) })
		end)
		if not ok or img == nil then
			break
		end
		table.insert(made, img)
		if #made % 64 == 0 then
			task.wait()
		end
	end
	local count = #made
	out("  256x256 images before nil: %d%s  (%.1f MiB of RGBA8, %.2f s)", count, if count == cap then " (cap hit, no budget here)" else "", count * 0.25, os.clock() - t0)

	-- Accounting check: does one 512x512 cost the same as four 256x256?
	if count < cap and count >= 8 then
		for _ = 1, 4 do
			local img = table.remove(made)
			if img then
				img:Destroy()
			end
		end
		local big = newImage(512, 512)
		out("  after freeing 4x 256x256, a 512x512 create: %s", if big then "ok (pixel-count accounting)" else "nil")
		if big then
			big:Destroy()
		end
		local again = newImage(256, 256)
		out("  Destroy() returns budget immediately: %s", if again then "yes" else "no")
		if again then
			again:Destroy()
		end
	end
	for _, img in made do
		img:Destroy()
	end
end

----------------------------------------------------------------------------------
-- 2. Timings
----------------------------------------------------------------------------------

local function probeTimings()
	out("## timings [%s]  (median of runs; Mpix/s counts destination pixels)", context())

	report("CreateEditableImage 256x256 + Destroy", 16, nil, function()
		local i = AssetService:CreateEditableImage({ Size = Vector2.new(256, 256) })
		i:Destroy()
	end)
	report("CreateEditableImage 1024x1024 + Destroy", 8, nil, function()
		local i = AssetService:CreateEditableImage({ Size = Vector2.new(1024, 1024) })
		i:Destroy()
	end)

	local img = newImage(1024, 1024)
	local src = newImage(1024, 1024)
	local half = newImage(512, 512)
	local quarter = newImage(256, 256)
	if not (img and src and half and quarter) then
		out("  could not allocate probe images; skipping timings")
		return
	end
	fillPattern(src, 1024, 1024, 17)
	fillPattern(img, 1024, 1024, 99)

	local full = buffer.create(1024 * 1024 * 4)
	local tile = buffer.create(64 * 64 * 4)
	local one = buffer.create(4)
	local SZ = Vector2.new(1024, 1024)

	report("WritePixelsBuffer 1024x1024", 12, 1024 * 1024, function()
		img:WritePixelsBuffer(Vector2.zero, SZ, full)
	end)
	report("WritePixelsBuffer 64x64 tile", 32, 64 * 64, function()
		img:WritePixelsBuffer(Vector2.new(128, 128), Vector2.new(64, 64), tile)
	end)
	report("WritePixelsBuffer 1x1 (call overhead)", 64, 1, function()
		img:WritePixelsBuffer(Vector2.new(3, 3), Vector2.one, one)
	end)
	report("ReadPixelsBuffer 1024x1024", 12, 1024 * 1024, function()
		img:ReadPixelsBuffer(Vector2.zero, SZ)
	end)
	report("ReadPixelsBuffer 64x64 tile", 32, 64 * 64, function()
		img:ReadPixelsBuffer(Vector2.new(128, 128), Vector2.new(64, 64))
	end)
	report("ReadPixelsBuffer 1x1 (call overhead)", 64, 1, function()
		img:ReadPixelsBuffer(Vector2.new(3, 3), Vector2.one)
	end)

	for _, ct in { Enum.ImageCombineType.Overwrite, Enum.ImageCombineType.AlphaBlend, Enum.ImageCombineType.BlendSourceOver } do
		report("DrawRectangle full canvas " .. ct.Name, 12, 1024 * 1024, function()
			img:DrawRectangle(Vector2.zero, SZ, Color3.new(0.2, 0.4, 0.6), 0.25, ct)
		end)
	end
	for _, ct in Enum.ImageCombineType:GetEnumItems() do
		report("DrawImage 1024->1024 " .. ct.Name, 12, 1024 * 1024, function()
			img:DrawImage(Vector2.zero, src, ct)
		end)
	end
	for _, mode in { Enum.ResamplerMode.Default, Enum.ResamplerMode.Pixelated } do
		report("DrawImageTransformed 1024->512 scale 0.5 " .. mode.Name, 12, 512 * 512, function()
			half:DrawImageTransformed(Vector2.zero, Vector2.new(0.5, 0.5), 0, src, {
				CombineType = Enum.ImageCombineType.Overwrite,
				SamplingMode = mode,
				PivotPoint = Vector2.zero,
			})
		end)
	end
	report("DrawImageTransformed 1024->1024 rotate 30deg Default", 8, 1024 * 1024, function()
		img:DrawImageTransformed(Vector2.new(512, 512), Vector2.one, 30, src, {
			CombineType = Enum.ImageCombineType.Overwrite,
			SamplingMode = Enum.ResamplerMode.Default,
		})
	end)
	report("DrawImageTransformed 512->256 scale 0.5 (mip step)", 16, 256 * 256, function()
		quarter:DrawImageTransformed(Vector2.zero, Vector2.new(0.5, 0.5), 0, half, {
			CombineType = Enum.ImageCombineType.Overwrite,
			PivotPoint = Vector2.zero,
		})
	end)
	report("DrawCircle r=300 AA on", 16, nil, function()
		img:DrawCircle(Vector2.new(512, 512), 300, Color3.new(1, 0.6, 0.2), 0, Enum.ImageCombineType.BlendSourceOver)
	end)
	report("DrawCircle r=300 AA off", 16, nil, function()
		img:DrawCircle(Vector2.new(512, 512), 300, Color3.new(1, 0.6, 0.2), 0, Enum.ImageCombineType.BlendSourceOver, Enum.AntiAliasing.Disabled)
	end)
	report("DrawLine 1024 px diagonal AA on", 32, nil, function()
		img:DrawLine(Vector2.zero, Vector2.new(1023, 1023), Color3.new(1, 1, 1), 0, Enum.ImageCombineType.BlendSourceOver)
	end)
	report("Content.fromObject", 64, nil, function()
		Content.fromObject(img)
	end)

	local label = Instance.new("ImageLabel")
	report("ImageLabel.ImageContent = Content.fromObject(img)", 32, nil, function()
		label.ImageContent = Content.fromObject(img)
		label.ImageContent = Content.none
	end)
	label:Destroy()

	-- Baking: yields, so this is latency including frame waits, not CPU time.
	local okB, errB = pcall(function()
		local samples = {}
		for _ = 1, 3 do
			local t0 = os.clock()
			local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(src))
			table.insert(samples, os.clock() - t0)
			if result ~= Enum.CreateContentResult.Success then
				out("  CreateDataModelContentAsync result: %s", tostring(result))
			end
			local _ = content
		end
		local med, best = median(samples)
		out("  %-58s median %9.3f ms  best %9.3f ms  (latency, yields)", "CreateDataModelContentAsync 1024x1024", med * 1e3, best * 1e3)
	end)
	if not okB then
		out("  CreateDataModelContentAsync error: %s", tostring(errB))
	end

	img:Destroy()
	src:Destroy()
	half:Destroy()
	quarter:Destroy()
end

----------------------------------------------------------------------------------
-- 3. Ops: truth tables
----------------------------------------------------------------------------------

type RGBA = { number }

local DST_CASES: { RGBA } = {
	{ 200, 100, 50, 255 },
	{ 200, 100, 50, 128 },
	{ 200, 100, 50, 0 },
	{ 0, 0, 0, 0 },
	{ 255, 255, 255, 255 },
}
local SRC_CASES: { RGBA } = {
	{ 10, 220, 90, 255 },
	{ 10, 220, 90, 128 },
	{ 10, 220, 90, 1 },
	{ 10, 220, 90, 0 },
	{ 255, 0, 0, 64 },
}

local function writeRow(img: EditableImage, row: { RGBA })
	local b = buffer.create(#row * 4)
	for i, p in row do
		local o = (i - 1) * 4
		buffer.writeu8(b, o, p[1])
		buffer.writeu8(b, o + 1, p[2])
		buffer.writeu8(b, o + 2, p[3])
		buffer.writeu8(b, o + 3, p[4])
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(#row, 1), b)
end

local function readRow(img: EditableImage, n: number): { RGBA }
	local b = img:ReadPixelsBuffer(Vector2.zero, Vector2.new(n, 1))
	local res = table.create(n)
	for i = 1, n do
		local o = (i - 1) * 4
		res[i] = { buffer.readu8(b, o), buffer.readu8(b, o + 1), buffer.readu8(b, o + 2), buffer.readu8(b, o + 3) }
	end
	return res
end

-- Candidate formulas in straight alpha, 0..1 floats. Each returns r, g, b, a.
type Model = (s: RGBA, d: RGBA) -> (number, number, number, number)
local function f(v: number): number
	return v / 255
end
local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

local MODELS: { [string]: Model } = {
	["overwrite"] = function(s, d)
		return f(s[1]), f(s[2]), f(s[3]), f(s[4])
	end,
	["srcover straight"] = function(s, d)
		local sa, da = f(s[4]), f(d[4])
		local oa = sa + da * (1 - sa)
		if oa <= 0 then
			return 0, 0, 0, 0
		end
		local function c(i)
			return (f(s[i]) * sa + f(d[i]) * da * (1 - sa)) / oa
		end
		return c(1), c(2), c(3), oa
	end,
	["lerp by src alpha, a = srcover"] = function(s, d)
		local sa, da = f(s[4]), f(d[4])
		local function c(i)
			return f(s[i]) * sa + f(d[i]) * (1 - sa)
		end
		return c(1), c(2), c(3), sa + da * (1 - sa)
	end,
	["lerp by src alpha, a = lerp"] = function(s, d)
		local sa, da = f(s[4]), f(d[4])
		local function c(i)
			return f(s[i]) * sa + f(d[i]) * (1 - sa)
		end
		return c(1), c(2), c(3), sa * sa + da * (1 - sa)
	end,
	["lerp by src alpha, a = max"] = function(s, d)
		local sa, da = f(s[4]), f(d[4])
		local function c(i)
			return f(s[i]) * sa + f(d[i]) * (1 - sa)
		end
		return c(1), c(2), c(3), math.max(sa, da)
	end,
	["add (rgb*sa), a+a"] = function(s, d)
		local sa = f(s[4])
		local function c(i)
			return clamp01(f(d[i]) + f(s[i]) * sa)
		end
		return c(1), c(2), c(3), clamp01(f(d[4]) + sa)
	end,
	["subtract (rgb*sa), a-a"] = function(s, d)
		local sa = f(s[4])
		local function c(i)
			return clamp01(f(d[i]) - f(s[i]) * sa)
		end
		return c(1), c(2), c(3), clamp01(f(d[4]) - sa)
	end,
	["multiply all channels"] = function(s, d)
		return f(s[1]) * f(d[1]), f(s[2]) * f(d[2]), f(s[3]) * f(d[3]), f(s[4]) * f(d[4])
	end,
	["srcover premultiplied storage"] = function(s, d)
		local sa = f(s[4])
		local function c(i)
			return f(s[i]) + f(d[i]) * (1 - sa)
		end
		return c(1), c(2), c(3), sa + f(d[4]) * (1 - sa)
	end,
}

local function scoreModel(model: Model, srcs: { RGBA }, dsts: { RGBA }, got: { RGBA }): (number, number)
	local maxColor, maxAlpha = 0, 0
	for i = 1, #got do
		local r, g, b, a = model(srcs[i], dsts[i])
		local o = got[i]
		local da = math.abs(a * 255 - o[4])
		maxAlpha = math.max(maxAlpha, da)
		-- colour only matters where the result is visible
		if o[4] > 0 then
			maxColor = math.max(maxColor, math.abs(r * 255 - o[1]), math.abs(g * 255 - o[2]), math.abs(b * 255 - o[3]))
		end
	end
	return maxColor, maxAlpha
end

local function fmt(p: RGBA): string
	return string.format("(%3d,%3d,%3d,%3d)", p[1], p[2], p[3], p[4])
end

local function probeCombineOps()
	out("## ops: ImageCombineType truth tables via DrawImage [%s]", context())
	-- Every (src, dst) pair becomes one pixel of a 1-row image, so one DrawImage call
	-- evaluates all 25 cases of an op at once.
	local srcs, dsts = {}, {}
	for _, d in DST_CASES do
		for _, s in SRC_CASES do
			table.insert(srcs, s)
			table.insert(dsts, d)
		end
	end
	local n = #srcs
	local srcImg = newImage(n, 1)
	local dstImg = newImage(n, 1)
	if not (srcImg and dstImg) then
		return
	end
	writeRow(srcImg, srcs)
	-- 1. Round-trip: does the stored image keep straight alpha and colour under alpha 0?
	local rt = readRow(srcImg, n)
	local changed = 0
	for i = 1, n do
		for c = 1, 4 do
			if rt[i][c] ~= srcs[i][c] then
				changed += 1
			end
		end
	end
	out("  WritePixelsBuffer->ReadPixelsBuffer round-trip: %s", if changed == 0 then "exact (straight alpha stored, rgb kept under alpha 0)" else ("%d channel values changed"):format(changed))
	for i = 1, #SRC_CASES do
		out("    wrote %s read %s", fmt(srcs[i]), fmt(rt[i]))
	end

	for _, ct in Enum.ImageCombineType:GetEnumItems() do
		writeRow(dstImg, dsts)
		local okD, errD = pcall(function()
			dstImg:DrawImage(Vector2.zero, srcImg, ct)
		end)
		if not okD then
			out("### %s: DrawImage error %s", ct.Name, tostring(errD))
			continue
		end
		local got = readRow(dstImg, n)
		out("### %s", ct.Name)
		for i = 1, n do
			out("    src %s over dst %s -> %s", fmt(srcs[i]), fmt(dsts[i]), fmt(got[i]))
		end
		-- rank candidate formulas by worst-case error
		local ranked = {}
		for name, model in MODELS do
			local mc, ma = scoreModel(model, srcs, dsts, got)
			table.insert(ranked, { name = name, mc = mc, ma = ma })
		end
		table.sort(ranked, function(a, b)
			return math.max(a.mc, a.ma) < math.max(b.mc, b.ma)
		end)
		for k = 1, math.min(3, #ranked) do
			local r = ranked[k]
			out("    fit #%d %-34s max colour err %6.2f  max alpha err %6.2f", k, r.name, r.mc, r.ma)
		end
	end
	srcImg:Destroy()
	dstImg:Destroy()
end

local function probePrimitiveOps()
	out("## ops: DrawRectangle colour + transparency per combine type [%s]", context())
	local dst = newImage(#DST_CASES, 1)
	if not dst then
		return
	end
	for _, ct in Enum.ImageCombineType:GetEnumItems() do
		for _, transparency in { 0, 0.5, 1 } do
			writeRow(dst, DST_CASES)
			local ok, err = pcall(function()
				for i = 1, #DST_CASES do
					dst:DrawRectangle(Vector2.new(i - 1, 0), Vector2.one, Color3.fromRGB(10, 220, 90), transparency, ct)
				end
			end)
			if not ok then
				out("  %-16s t=%.1f error %s", ct.Name, transparency, tostring(err))
				continue
			end
			local got = readRow(dst, #DST_CASES)
			local parts = {}
			for i = 1, #got do
				table.insert(parts, fmt(DST_CASES[i]) .. "->" .. fmt(got[i]))
			end
			out("  %-16s t=%.1f  %s", ct.Name, transparency, table.concat(parts, "  "))
		end
	end
	dst:Destroy()
end

local function probeSampling()
	out("## ops: DrawImageTransformed filtering [%s]", context())
	-- (a) magnify a black|white pair 4x: the read-back ramp shows the filter kernel
	local pair = newImage(2, 1)
	local wide = newImage(8, 1)
	if pair and wide then
		writeRow(pair, { { 0, 0, 0, 255 }, { 255, 255, 255, 255 } })
		for _, mode in { Enum.ResamplerMode.Default, Enum.ResamplerMode.Pixelated } do
			writeRow(wide, table.create(8, { 0, 0, 0, 0 }))
			local ok, err = pcall(function()
				wide:DrawImageTransformed(Vector2.zero, Vector2.new(4, 1), 0, pair, {
					CombineType = Enum.ImageCombineType.Overwrite,
					SamplingMode = mode,
					PivotPoint = Vector2.zero,
				})
			end)
			if ok then
				local got = readRow(wide, 8)
				local ramp = {}
				for i = 1, 8 do
					table.insert(ramp, tostring(got[i][1]))
				end
				out("  magnify 2px->8px %-10s red ramp: %s", mode.Name, table.concat(ramp, " "))
			else
				out("  magnify %s error %s", mode.Name, tostring(err))
			end
		end
	end
	-- (b) colour bleed: a transparent red pixel next to an opaque green one. With straight
	-- alpha a naive bilinear filter drags red into the green edge (the "fringe").
	local bleed = newImage(2, 1)
	local bleedOut = newImage(8, 1)
	if bleed and bleedOut then
		writeRow(bleed, { { 255, 0, 0, 0 }, { 0, 255, 0, 255 } })
		writeRow(bleedOut, table.create(8, { 0, 0, 0, 0 }))
		local ok, err = pcall(function()
			bleedOut:DrawImageTransformed(Vector2.zero, Vector2.new(4, 1), 0, bleed, {
				CombineType = Enum.ImageCombineType.Overwrite,
				SamplingMode = Enum.ResamplerMode.Default,
				PivotPoint = Vector2.zero,
			})
		end)
		if ok then
			local got = readRow(bleedOut, 8)
			local parts = {}
			for i = 1, 8 do
				table.insert(parts, fmt(got[i]))
			end
			out("  premultiplied-aware filter test (red under alpha 0 | green): %s", table.concat(parts, " "))
			out("    red > 0 in a visible pixel means the filter is NOT premultiplied-aware")
		else
			out("  bleed test error %s", tostring(err))
		end
	end
	-- (c) minification quality: 1px checkerboard 256x256 to 64x64 in one 0.25 step vs two
	-- 0.5 steps. A true area filter gives mid grey (127.5) everywhere. Bilinear sampling at
	-- 0.25 only touches 4 of 16 source pixels, so its error reveals aliasing.
	local checker = newImage(256, 256)
	local mid = newImage(128, 128)
	local small1 = newImage(64, 64)
	local small2 = newImage(64, 64)
	if checker and mid and small1 and small2 then
		local b = buffer.create(256 * 256 * 4)
		for y = 0, 255 do
			for x = 0, 255 do
				local v = if (x + y) % 2 == 0 then 0xFFFFFFFF else 0xFF000000
				buffer.writeu32(b, (y * 256 + x) * 4, v)
			end
		end
		checker:WritePixelsBuffer(Vector2.zero, Vector2.new(256, 256), b)
		local opts = { CombineType = Enum.ImageCombineType.Overwrite, SamplingMode = Enum.ResamplerMode.Default, PivotPoint = Vector2.zero }
		local ok, err = pcall(function()
			small1:DrawImageTransformed(Vector2.zero, Vector2.new(0.25, 0.25), 0, checker, opts)
			mid:DrawImageTransformed(Vector2.zero, Vector2.new(0.5, 0.5), 0, checker, opts)
			small2:DrawImageTransformed(Vector2.zero, Vector2.new(0.5, 0.5), 0, mid, opts)
		end)
		if ok then
			local function err255(img: EditableImage): (number, number)
				local rb = img:ReadPixelsBuffer(Vector2.zero, Vector2.new(64, 64))
				local sum, worst = 0, 0
				for i = 0, 64 * 64 - 1 do
					local e = math.abs(buffer.readu8(rb, i * 4) - 127.5)
					sum += e
					worst = math.max(worst, e)
				end
				return sum / (64 * 64), worst
			end
			local m1, w1 = err255(small1)
			local m2, w2 = err255(small2)
			out("  checkerboard 256->64 one step x0.25 : mean |err| %.1f  worst %.1f", m1, w1)
			out("  checkerboard 256->64 two steps x0.5: mean |err| %.1f  worst %.1f", m2, w2)
		else
			out("  minification test error %s", tostring(err))
		end
	end
	for _, i in { pair, wide, bleed, bleedOut, checker, mid, small1, small2 } do
		if i then
			i:Destroy()
		end
	end
end

-- Bake fidelity: does content baked by CreateDataModelContentAsync keep the bytes the
-- flawless pipeline computed (docs/COMPUTE.md "Flawless pipeline", engine-dependent
-- guarantees)? Bakes a 64 x 64 pattern holding every byte value, alpha ramps, hard
-- alpha edges and colour under alpha 0, then reads it back through a new
-- EditableImage if the engine allows that. 0 differing visible pixels means F1, F2
-- and F3 survive baking at mip level 0; mips themselves cannot be read back here.
local function probeBakeFidelity()
	out("## ops: bake fidelity, CreateDataModelContentAsync [%s]", context())
	local W = 64
	local src = newImage(W, W)
	if not src then
		return
	end
	local b = buffer.create(W * W * 4)
	for y = 0, W - 1 do
		for x = 0, W - 1 do
			local r = (x * 4 + y) % 256
			local g = (y * 4 + x * 3) % 256
			local bl = ((x + y) * 2) % 256
			local a = if y < 16 then 255 elseif y < 32 then (x * 4) % 256 elseif y < 48 then (if x % 2 == 0 then 0 else 255) else (x * 4 + 3) % 256
			buffer.writeu32(b, (y * W + x) * 4, r + g * 256 + bl * 65536 + a * 16777216)
		end
	end
	src:WritePixelsBuffer(Vector2.zero, Vector2.new(W, W), b)
	local ok, err = pcall(function()
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(src))
		out("  bake result: %s", tostring(result))
		if result ~= Enum.CreateContentResult.Success then
			return
		end
		local okR, back = pcall(function()
			return AssetService:CreateEditableImageAsync(content)
		end)
		if not okR or not back then
			out("  baked content cannot be read back as an EditableImage (%s); compare visually", tostring(back))
			return
		end
		local size = back.Size
		out("  read back %dx%d", size.X, size.Y)
		if size.X == W and size.Y == W then
			local rb = back:ReadPixelsBuffer(Vector2.zero, Vector2.new(W, W))
			local visibleDiff, hiddenDiff, maxD, maxA = 0, 0, 0, 0
			for i = 0, W * W - 1 do
				if buffer.readu32(b, i * 4) ~= buffer.readu32(rb, i * 4) then
					local a = buffer.readu8(b, i * 4 + 3)
					if a > 0 then
						visibleDiff += 1
						for c = 0, 2 do
							maxD = math.max(maxD, math.abs(buffer.readu8(b, i * 4 + c) - buffer.readu8(rb, i * 4 + c)))
						end
					else
						hiddenDiff += 1
					end
					maxA = math.max(maxA, math.abs(a - buffer.readu8(rb, i * 4 + 3)))
				end
			end
			out("  baked vs source: %d visible pixels differ (max colour diff %d), %d pixels differ only under alpha 0, max alpha diff %d", visibleDiff, maxD, hiddenDiff, maxA)
			out("    0 visible differences and alpha diff 0: baking keeps the computed bytes")
		end
		back:Destroy()
	end)
	if not ok then
		out("  bake fidelity error: %s", tostring(err))
	end
	src:Destroy()
end

----------------------------------------------------------------------------------

function Probe.run(options: { budget: boolean?, timings: boolean?, ops: boolean?, limits: boolean? }?)
	local o = options or {}
	table.clear(lines)
	out("# EditableImageProbe  context=%s  version=%s", context(), version())
	if o.limits ~= false then
		probeLimits()
	end
	if o.ops ~= false then
		probeCombineOps()
		probePrimitiveOps()
		probeSampling()
		probeBakeFidelity()
	end
	if o.timings ~= false then
		probeTimings()
	end
	if o.budget ~= false then
		probeBudget()
	end
	out("# done")
	return table.concat(lines, "\n")
end

return Probe
