--!strict
-- universe-at-home :: gallery/Gallery.client.luau  (LocalScript, StarterPlayerScripts)
--
-- A visual gallery of EditableImages, every one drawn in Luau on this machine:
--   * a vector badge rendered with exact-area edges and copy-filled tiles
--   * a live plasma rewritten every frame (compute and upload time shown)
--   * procedural marble from deterministic fractal noise
--   * a 1152 x 1152 canvas made of nine 384 x 384 tiles (larger than any one image may be)
--   * level-of-detail switching: a hard switch next to the two-phase fade
--   * a green-screen portrait, its matte, and the cut-out over a new backdrop
-- plus a spinning cube in the world that wears the same EditableImages as Decals.
--
-- Heavy panels are drawn by a frame-time scheduler (coroutines that yield when the frame's
-- budget is spent), so the gallery fills in over a few seconds without freezing the game.
-- Every stage runs under pcall: if one fails, the others still come up and the error is shown.
-- Press G to hide or show the panels.
--
-- Requires: Game Settings, Security, "Allow Mesh / Image APIs" turned ON.

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

-- wait for replication, then require by static path
ReplicatedStorage:WaitForChild("Universe"):WaitForChild("MyMath")
ReplicatedStorage:WaitForChild("Gallery"):WaitForChild("Panels")
local MyMath: any = require(ReplicatedStorage.Universe.MyMath)
local Panels: any = (require(ReplicatedStorage.Gallery.Panels) :: any)(MyMath)

-- ALLAN (the liquid network renderer) and its embedded models are optional for the gallery:
-- if they fail to load, only the two ALLAN cards say so.
local allanOk, allanErr = (pcall :: any)(function()
	ReplicatedStorage:WaitForChild("Universe"):WaitForChild("Liquid")
	ReplicatedStorage:WaitForChild("Gallery"):WaitForChild("AlnModels")
	return {
		Liquid = require(ReplicatedStorage.Universe.Liquid),
		Models = require(ReplicatedStorage.Gallery.AlnModels),
	}
end)
local Liquid: any = if allanOk then allanErr.Liquid else nil
local AlnModels: any = if allanOk then allanErr.Models else nil

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

----------------------------------------------------------------------------------------
-- Error reporting and EditableImage helpers
----------------------------------------------------------------------------------------

-- pcall for functions that return nothing: typed as (boolean, any) so the error can be read
local function try(fn: () -> ()): (boolean, any)
	local ok, err = (pcall :: any)(fn)
	return ok, err
end

local errors: { string } = {}
local banner: TextLabel? = nil

local function reportError(where: string, message: string)
	local line = where .. ": " .. message
	table.insert(errors, line)
	warn("[Gallery] " .. line)
	if banner then
		banner.Visible = true
		banner.Text = "Something did not come up. " .. line
			.. "\nIf this says EditableImage is not enabled: Home > Game Settings > Security > Allow Mesh / Image APIs, then press Play again."
	end
end

local liveImages = 0
local livePixels = 0

local function createImage(w: number, h: number, where: string): EditableImage?
	local ok, result = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	end)
	if ok and result then
		liveImages += 1
		livePixels += w * h
		return result :: EditableImage
	end
	reportError(where, if ok then "CreateEditableImage returned nil (out of editable memory budget)" else tostring(result))
	return nil
end

local scratch: { [number]: buffer } = {}

-- Uploads rows [y0, y1) of a row-major RGBA8 buffer.
local function uploadRows(img: EditableImage, buf: buffer, width: number, y0: number, y1: number)
	local rows = y1 - y0
	if rows <= 0 then
		return
	end
	local bytes = rows * width * 4
	if y0 == 0 and bytes == buffer.len(buf) then
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(width, rows), buf)
		return
	end
	local tmp = scratch[bytes]
	if not tmp then
		tmp = buffer.create(bytes)
		scratch[bytes] = tmp
	end
	buffer.copy(tmp, 0, buf, y0 * width * 4, bytes)
	img:WritePixelsBuffer(Vector2.new(0, y0), Vector2.new(width, rows), tmp)
end

----------------------------------------------------------------------------------------
-- Frame-time scheduler: jobs are coroutines that yield when the frame's budget is spent
----------------------------------------------------------------------------------------

type Job = { co: thread, cpu: number, sliceStart: number, name: string }

local jobs: { Job } = {}
local deadline = 0

local function checkpoint()
	if os.clock() >= deadline then
		coroutine.yield()
	end
end

local function spawnJob(name: string, fn: (job: Job) -> ()): Job
	local job: Job = { co = coroutine.create(function() end), cpu = 0, sliceStart = 0, name = name }
	job.co = coroutine.create(function()
		fn(job)
	end)
	table.insert(jobs, job)
	return job
end

local function cpuMs(job: Job): number
	return (job.cpu + (os.clock() - job.sliceStart)) * 1000
end

local function runJobs(budget: number)
	if #jobs == 0 then
		return
	end
	deadline = os.clock() + budget
	local i = 1
	while i <= #jobs and os.clock() < deadline do
		local job = jobs[i]
		job.sliceStart = os.clock()
		local ok, err = coroutine.resume(job.co)
		job.cpu += os.clock() - job.sliceStart
		if not ok then
			reportError(job.name, tostring(err))
			table.remove(jobs, i)
		elseif coroutine.status(job.co) == "dead" then
			table.remove(jobs, i)
		else
			i += 1
		end
	end
end

----------------------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------------------

local FONT = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)

local function text(parent: Instance, content: string, size: number, pos: UDim2, dim: UDim2, bold: boolean?, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.FontFace = if bold then FONT_BOLD else FONT
	l.TextSize = size
	l.TextColor3 = color or Color3.fromRGB(226, 230, 245)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Text = content
	l.Position = pos
	l.Size = dim
	l.Parent = parent
	return l
end

local function round(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EditableImageGallery"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "Panels"
root.BackgroundColor3 = Color3.fromRGB(10, 12, 22)
root.BackgroundTransparency = 0.12
root.BorderSizePixel = 0
root.Position = UDim2.fromOffset(8, 8)
root.Size = UDim2.new(0, 650, 1, -16)
root.Parent = screenGui
round(root, 10)

text(root, "EditableImage Gallery", 24, UDim2.fromOffset(14, 8), UDim2.new(1, -28, 0, 30), true)
text(
	root,
	"Every picture here is an EditableImage drawn by Luau on this machine, no uploaded assets. Press G to hide.",
	13,
	UDim2.fromOffset(14, 38),
	UDim2.new(1, -28, 0, 30),
	false,
	Color3.fromRGB(150, 158, 190)
)

local scroller = Instance.new("ScrollingFrame")
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.Position = UDim2.fromOffset(0, 72)
scroller.Size = UDim2.new(1, 0, 1, -72)
scroller.CanvasSize = UDim2.new()
scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroller.ScrollBarThickness = 8
scroller.Parent = root

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingTop = UDim.new(0, 4)
pad.PaddingBottom = UDim.new(0, 12)
pad.Parent = scroller

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.fromOffset(300, 366)
grid.CellPadding = UDim2.fromOffset(10, 10)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = scroller

local bannerLabel = text(
	screenGui,
	"",
	15,
	UDim2.new(0.5, -300, 0, 8),
	UDim2.fromOffset(600, 70),
	true,
	Color3.fromRGB(255, 200, 200)
)
bannerLabel.BackgroundTransparency = 0.1
bannerLabel.BackgroundColor3 = Color3.fromRGB(110, 20, 28)
bannerLabel.Visible = false
bannerLabel.ZIndex = 10
round(bannerLabel, 8)
banner = bannerLabel

local hud = text(screenGui, "", 13, UDim2.new(1, -348, 0, 8), UDim2.fromOffset(340, 112), false)
hud.BackgroundTransparency = 0.25
hud.BackgroundColor3 = Color3.fromRGB(8, 10, 18)
round(hud, 8)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.KeyCode == Enum.KeyCode.G then
		root.Visible = not root.Visible
	end
end)

type Card = { frame: Frame, body: Frame, info: TextLabel }

local function makeCard(order: number, title: string, subtitle: string): Card
	local frame = Instance.new("Frame")
	frame.Name = title
	frame.LayoutOrder = order
	frame.BackgroundColor3 = Color3.fromRGB(24, 28, 46)
	frame.BorderSizePixel = 0
	frame.Parent = scroller
	round(frame, 8)
	text(frame, title, 14, UDim2.fromOffset(8, 6), UDim2.new(1, -16, 0, 20), true)
	local body = Instance.new("Frame")
	body.BackgroundColor3 = Color3.fromRGB(12, 14, 24)
	body.BorderSizePixel = 0
	body.ClipsDescendants = true
	body.Position = UDim2.fromOffset(6, 28)
	body.Size = UDim2.fromOffset(288, 288)
	body.Parent = frame
	local sub = text(frame, subtitle, 11, UDim2.fromOffset(8, 319), UDim2.new(1, -16, 0, 24), false, Color3.fromRGB(150, 158, 190))
	sub.TextYAlignment = Enum.TextYAlignment.Top
	local info = text(frame, "queued...", 12, UDim2.fromOffset(8, 346), UDim2.new(1, -16, 0, 16), true, Color3.fromRGB(130, 220, 170))
	return { frame = frame, body = body, info = info }
end

local function imageLabel(parent: Instance, img: EditableImage?, size: UDim2, pos: UDim2?): ImageLabel
	local l = Instance.new("ImageLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Size = size
	l.Position = pos or UDim2.new()
	if img then
		l.ImageContent = Content.fromObject(img)
	end
	l.Parent = parent
	return l
end

----------------------------------------------------------------------------------------
-- 3D: a cube that wears the same EditableImages as Decals
----------------------------------------------------------------------------------------

local cube = Instance.new("Part")
cube.Name = "GalleryCube"
cube.Size = Vector3.new(9, 9, 9)
cube.Anchored = true
cube.CanCollide = false
cube.Material = Enum.Material.SmoothPlastic
cube.Color = Color3.fromRGB(245, 245, 250)
cube.CFrame = CFrame.new(0, 9, -24)
cube.Parent = workspace

local function wear(face: Enum.NormalId, img: EditableImage?)
	if not img then
		return
	end
	local ok, err = try(function()
		local d = Instance.new("Decal")
		d.Face = face
		d.TextureContent = Content.fromObject(img)
		d.Parent = cube
	end)
	if not ok then
		reportError("cube decal " .. face.Name, tostring(err))
	end
end

----------------------------------------------------------------------------------------
-- Cards
----------------------------------------------------------------------------------------

local allanCard = makeCard(1, "ALLAN: a liquid network draws this", "A 15.9 KB model, not pixels: 16.5x smaller than raw RGBA. Against the original: 43.0 dB, worst error 12 of 255 (measured by the trainer). Decoded here, in Luau.")
local levelsCard = makeCard(2, "ALLAN: one model, any level", "Top: one 44.8 KB model at levels 0, 1, 2, no downsampling pass. Bottom right: a 3 KB model stored at 32 x 32, rendered at 64 x 64.")
local sceneCard = makeCard(3, "Vector badge  512 x 512", "Exact-area anti-aliased shapes. Tiles that no edge touches are copy-filled; only edge tiles run per-pixel math.")
local plasmaCard = makeCard(4, "Live plasma  192 x 192", "Rewritten every frame with WritePixelsBuffer: the compute and upload time below is measured here, live.")
local marbleCard = makeCard(5, "Procedural marble  256 x 256", "Deterministic fractal noise: every client computes the same bytes. Fills in as the scheduler allows.")
local mandelCard = makeCard(6, "Beyond 1024:  1152 x 1152 canvas", "Nine 384 x 384 tiles, each its own EditableImage. No single image may exceed 1024, the canvas does.")
local hardCard = makeCard(7, "LOD: hard switch", "Zooms in and out. At the midpoint it swaps the 64 px level for the 512 px level: watch the sharpness jump.")
local fadeCard = makeCard(8, "LOD: two-phase fade", "Same two images, same zoom. The fine level fades in over the coarse one, then the coarse one fades out beneath it.")
local greenCard = makeCard(9, "Green screen  256 x 256", "A portrait with 1 px hair strands and a glass bubble, plus sensor noise.")
local matteCard = makeCard(10, "Matte (alpha)  256 x 256", "Soft chroma key. The glass bubble comes out grey: partly transparent, not cut out.")
local cutCard = makeCard(11, "Cut-out on a new backdrop", "Foreground colour recovered by removing the green fringe, then composited over the sunset.")

----------------------------------------------------------------------------------------
-- Panel jobs
----------------------------------------------------------------------------------------

local sceneImg: EditableImage? = nil
local lowImg: EditableImage? = nil
local plasmaImg: EditableImage? = nil
local mandelImgs: { EditableImage } = {}

-- 1. badge, plus its 64 px level for the LOD cards
spawnJob("badge", function(job)
	local img = createImage(512, 512, "badge")
	if not img then
		sceneCard.info.Text = "could not create the image"
		return
	end
	sceneImg = img
	imageLabel(sceneCard.body, img, UDim2.fromOffset(288, 288))
	local buf = buffer.create(512 * 512 * 4)
	local edge, tiles = Panels.renderScene(buf, 512, 512, function(y0: number, y1: number)
		uploadRows(img, buf, 512, y0, y1)
		checkpoint()
	end)
	sceneCard.info.Text = string.format("rendered in %.0f ms CPU  |  %d of %d tiles needed math", cpuMs(job), edge, tiles)
	wear(Enum.NormalId.Front, img)

	local low = createImage(64, 64, "badge level 64")
	if low then
		lowImg = low
		local lbuf = buffer.create(64 * 64 * 4)
		Panels.renderScene(lbuf, 64, 64, nil)
		uploadRows(low, lbuf, 64, 0, 64)
		wear(Enum.NormalId.Bottom, low)
	end
end)

-- 2. plasma image (frames are drawn in the main loop)
do
	local img = createImage(192, 192, "plasma")
	if img then
		plasmaImg = img
		imageLabel(plasmaCard.body, img, UDim2.fromOffset(288, 288))
		wear(Enum.NormalId.Back, img)
	else
		plasmaCard.info.Text = "could not create the image"
	end
end

-- 3. marble
spawnJob("marble", function(job)
	local img = createImage(256, 256, "marble")
	if not img then
		marbleCard.info.Text = "could not create the image"
		return
	end
	imageLabel(marbleCard.body, img, UDim2.fromOffset(288, 288))
	local buf = buffer.create(256 * 256 * 4)
	Panels.renderMarble(buf, 256, 256, 1234, function(y0: number, y1: number)
		uploadRows(img, buf, 256, y0, y1)
		marbleCard.info.Text = string.format("%d%% drawn  |  %.0f ms CPU so far", y1 / 256 * 100, cpuMs(job))
		checkpoint()
	end)
	marbleCard.info.Text = string.format("rendered in %.0f ms CPU", cpuMs(job))
	wear(Enum.NormalId.Left, img)
end)

-- 7 to 9. green screen, matte, cut-out
spawnJob("green screen", function(job)
	local src = createImage(256, 256, "green screen")
	local matte = createImage(256, 256, "matte")
	local cut = createImage(256, 256, "cut-out")
	if not (src and matte and cut) then
		greenCard.info.Text = "could not create the images"
		return
	end
	imageLabel(greenCard.body, src, UDim2.fromOffset(288, 288))
	imageLabel(matteCard.body, matte, UDim2.fromOffset(288, 288))
	imageLabel(cutCard.body, cut, UDim2.fromOffset(288, 288))
	local gbuf = buffer.create(256 * 256 * 4)
	Panels.renderGreenScreen(gbuf, 256, 256, function(y0: number, y1: number)
		uploadRows(src, gbuf, 256, y0, y1)
		checkpoint()
	end)
	greenCard.info.Text = string.format("rendered in %.0f ms CPU", cpuMs(job))
	local mbuf = buffer.create(256 * 256 * 4)
	local cbuf = buffer.create(256 * 256 * 4)
	local before = cpuMs(job)
	Panels.keyMatte(gbuf, 256, 256, mbuf, cbuf, function(y0: number, y1: number)
		uploadRows(matte, mbuf, 256, y0, y1)
		uploadRows(cut, cbuf, 256, y0, y1)
		checkpoint()
	end)
	local took = string.format("matte + cut-out in %.0f ms CPU", cpuMs(job) - before)
	matteCard.info.Text = took
	cutCard.info.Text = took
	wear(Enum.NormalId.Top, cut)
end)

-- ALLAN: decode a model, render it in bands so the scheduler can spread the work over frames
local function allanFail(message: string)
	allanCard.info.Text = message
	levelsCard.info.Text = message
	reportError("ALLAN", message)
end

spawnJob("ALLAN", function(job)
	if not Liquid or not AlnModels then
		allanFail("ALLAN module did not load: " .. tostring(allanErr))
		return
	end
	-- renders one level of a model into an EditableImage, 32 output rows at a time
	local function render(plan: any, tree: any, level: number, img: EditableImage, w: number, h: number): any
		local out = buffer.create(w * h * 4)
		local stats = Liquid.newStats()
		for y0 = 0, h - 1, 32 do
			local rows = math.min(32, h - y0)
			Liquid.render(plan, tree, out, w, { level = level, x = 0, y = y0, w = w, h = rows, dy = y0, stats = stats })
			uploadRows(img, out, w, y0, y0 + rows)
			checkpoint()
		end
		return stats
	end
	local function load(name: string): (any, any, any)
		local model, tree = Liquid.decode(AlnModels.load(name))
		return model, tree, Liquid.prepare(model, tree, AlnModels.scale(name))
	end

	-- the logo, large
	local logoImg = createImage(256, 256, "ALLAN logo")
	if not logoImg then
		allanFail("could not create the image")
		return
	end
	imageLabel(allanCard.body, logoImg, UDim2.fromOffset(288, 288))
	local _, logoTree, logoPlan = load("sdf_logo_256")
	local before = cpuMs(job)
	local stats = render(logoPlan, logoTree, 0, logoImg, 256, 256)
	allanCard.info.Text = string.format(
		"%d B model vs %d B raw  |  %.0f ms CPU  |  %d events, %d rows",
		AlnModels.bytes("sdf_logo_256"),
		262144,
		cpuMs(job) - before,
		stats.segments,
		stats.rows
	)

	-- one UI model at levels 0, 1, 2, and the marble, in a 2 x 2 grid
	local cells = {
		{ name = "ui_flat_256", level = 0, size = 256, x = 0, y = 0, caption = "level 0  256 px" },
		{ name = "ui_flat_256", level = 1, size = 128, x = 144, y = 0, caption = "level 1  128 px" },
		{ name = "ui_flat_256", level = 2, size = 64, x = 0, y = 144, caption = "level 2  64 px" },
		{ name = "marble_64", level = 0, size = 64, x = 144, y = 144, caption = "marble  64 px" },
	}
	local total, done = 0, 0
	for _, cell in cells do
		local img = createImage(cell.size, cell.size, "ALLAN " .. cell.caption)
		if not img then
			levelsCard.info.Text = "out of editable memory at " .. cell.caption
			return
		end
		local l = imageLabel(levelsCard.body, img, UDim2.fromOffset(144, 144), UDim2.fromOffset(cell.x, cell.y))
		l.ZIndex = 1
		local cap = text(levelsCard.body, cell.caption, 11, UDim2.fromOffset(cell.x + 4, cell.y + 4), UDim2.fromOffset(136, 14), true, Color3.fromRGB(255, 255, 255))
		cap.BackgroundTransparency = 0.45
		cap.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		cap.AutomaticSize = Enum.AutomaticSize.X
		cap.Size = UDim2.fromOffset(0, 14)
		cap.ZIndex = 2
		local _, tree, plan = load(cell.name)
		local t0 = cpuMs(job)
		render(plan, tree, cell.level, img, cell.size, cell.size)
		total += cpuMs(job) - t0
		done += 1
		levelsCard.info.Text = string.format("%d of 4 images  |  %.0f ms CPU so far", done, total)
	end
	levelsCard.info.Text = string.format("4 images from 2 models (%d B + %d B)  |  %.0f ms CPU", AlnModels.bytes("ui_flat_256"), AlnModels.bytes("marble_64"), total)
end)

-- 4. nine tiles
local TILE, GRID = 384, 3
spawnJob("mandelbrot", function(job)
	local buf = buffer.create(TILE * TILE * 4)
	local labels: { ImageLabel } = {}
	for i = 0, GRID * GRID - 1 do
		local tx, ty = i % GRID, i // GRID
		local img = createImage(TILE, TILE, "mandelbrot tile " .. (i + 1))
		if not img then
			mandelCard.info.Text = string.format("tile %d: out of editable memory", i + 1)
			return
		end
		table.insert(mandelImgs, img)
		local shown = 288 // GRID
		labels[i + 1] = imageLabel(mandelCard.body, img, UDim2.fromOffset(shown, shown), UDim2.fromOffset(tx * shown, ty * shown))
		Panels.renderMandelbrotTile(buf, TILE, tx, ty, GRID, function(y0: number, y1: number)
			uploadRows(img, buf, TILE, y0, y1)
			mandelCard.info.Text = string.format("tile %d of %d  |  %.0f ms CPU so far", i + 1, GRID * GRID, cpuMs(job))
			checkpoint()
		end)
		if i == 4 then
			wear(Enum.NormalId.Right, img)
		end
	end
	mandelCard.info.Text = string.format("%d x %d px from %d images  |  %.0f ms CPU", TILE * GRID, TILE * GRID, GRID * GRID, cpuMs(job))
end)

----------------------------------------------------------------------------------------
-- LOD cards: two stacked labels per card, driven by the zoom size
----------------------------------------------------------------------------------------

local function lodStage(card: Card): (ImageLabel, ImageLabel)
	local coarse = imageLabel(card.body, nil, UDim2.fromOffset(36, 36))
	local fine = imageLabel(card.body, nil, UDim2.fromOffset(36, 36))
	for _, l in { coarse, fine } do
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Position = UDim2.fromScale(0.5, 0.5)
	end
	coarse.ZIndex = 1
	fine.ZIndex = 2
	return coarse, fine
end

local hardCoarse, hardFine = lodStage(hardCard)
local fadeCoarse, fadeFine = lodStage(fadeCard)
local lodBound = false

local function bindLod()
	if lodBound or not (sceneImg and lowImg) then
		return
	end
	lodBound = true
	for _, l in { hardCoarse, fadeCoarse } do
		l.ImageContent = Content.fromObject(lowImg :: EditableImage)
	end
	for _, l in { hardFine, fadeFine } do
		l.ImageContent = Content.fromObject(sceneImg :: EditableImage)
	end
end

local function updateLod(t: number)
	bindLod()
	local size = Panels.zoomSize(t)
	local f = Panels.lodBlend(size)
	local dim = UDim2.fromOffset(size, size)
	local hc, hf = Panels.hardSwitch(f)
	local fc, ff = Panels.twoPhase(f)
	hardCoarse.Size, hardFine.Size = dim, dim
	fadeCoarse.Size, fadeFine.Size = dim, dim
	hardCoarse.ImageTransparency, hardFine.ImageTransparency = hc, hf
	fadeCoarse.ImageTransparency, fadeFine.ImageTransparency = fc, ff
	hardCard.info.Text = string.format("shown at %3.0f px  |  %s level", size, if f < 0.5 then "64 px" else "512 px")
	fadeCard.info.Text = string.format("shown at %3.0f px  |  fine %2.0f%%  coarse %2.0f%%", size, (1 - ff) * 100, (1 - fc) * 100)
end

----------------------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------------------

local plasmaState = if plasmaImg then Panels.plasmaInit(192, 192) else nil
local plasmaBuf = buffer.create(192 * 192 * 4)
local plasmaFailed = false
local plasmaComputeMs, plasmaUploadMs = 0, 0
local fps, hudClock = 60, 0
local started = os.clock()

RunService.RenderStepped:Connect(function(dt: number)
	local now = os.clock()
	local t = now - started
	if dt > 0 then
		fps += (1 / dt - fps) * 0.08
	end

	-- live plasma: compute, then upload, each timed separately
	local pImg = plasmaImg
	if pImg and plasmaState and not plasmaFailed then
		local ok, err = try(function()
			local t0 = os.clock()
			Panels.plasmaFrame(plasmaState, plasmaBuf, t)
			local t1 = os.clock()
			pImg:WritePixelsBuffer(Vector2.zero, Vector2.new(192, 192), plasmaBuf)
			local t2 = os.clock()
			plasmaComputeMs += ((t1 - t0) * 1000 - plasmaComputeMs) * 0.1
			plasmaUploadMs += ((t2 - t1) * 1000 - plasmaUploadMs) * 0.1
		end)
		if not ok then
			plasmaFailed = true
			reportError("plasma frame", tostring(err))
		end
		plasmaCard.info.Text = string.format("compute %.2f ms  |  upload %.2f ms  per frame", plasmaComputeMs, plasmaUploadMs)
	end

	local okLod, errLod = try(function()
		updateLod(t)
	end)
	if not okLod then
		reportError("LOD", tostring(errLod))
	end

	cube.CFrame = CFrame.new(0, 9, -24) * CFrame.Angles(0.35, t * 0.6, 0.12)

	runJobs(0.008)

	hudClock += dt
	if hudClock > 0.25 then
		hudClock = 0
		local total, tex = 0, 0
		pcall(function()
			total = Stats:GetTotalMemoryUsageMb()
			tex = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsTexture)
		end)
		hud.Text = string.format(
			"FPS %.0f   frame %.1f ms\nEditableImages alive: %d  (%.2f Mpx, %.1f MB as RGBA)\nClient memory %.0f MB   GraphicsTexture %.0f MB\nPanels still drawing: %d   Errors: %d\nG: hide or show panels",
			fps,
			1000 / math.max(fps, 1),
			liveImages,
			livePixels / 1e6,
			livePixels * 4 / 1048576,
			total,
			tex,
			#jobs,
			#errors
		)
	end
end)
