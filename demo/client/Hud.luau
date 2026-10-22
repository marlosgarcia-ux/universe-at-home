--!strict
-- Universe at Home: Meadow :: Hud
--
-- The always-on heads-up display: metrics (left), world progress (top), capabilities
-- and self-check (right), stress bench buttons and results (bottom left). Plain
-- Instances built in code; nothing here is required for the world to work, and every
-- caller wraps HUD updates in pcall.

local Players = game:GetService("Players")

local Hud = {}

local MONO = Font.fromEnum(Enum.Font.RobotoMono)
local SANS = Font.fromEnum(Enum.Font.BuilderSansMedium)
local SANS_BOLD = Font.fromEnum(Enum.Font.BuilderSansBold)

local PANEL = Color3.fromRGB(14, 18, 24)
local INK = Color3.fromRGB(232, 236, 240)
local DIM = Color3.fromRGB(150, 160, 172)
local ACCENT = Color3.fromRGB(255, 196, 120)

Hud.STATE_COLORS = {
	ok = Color3.fromRGB(110, 214, 120),
	fallback = Color3.fromRGB(255, 190, 80),
	failed = Color3.fromRGB(255, 96, 96),
	pending = Color3.fromRGB(120, 170, 255),
	skipped = Color3.fromRGB(140, 140, 150),
	info = Color3.fromRGB(200, 205, 215),
}

export type Hud = {
	gui: ScreenGui,
	root: Frame,
	metrics: Frame,
	metricRows: { [string]: TextLabel },
	metricCount: number,
	progress: Frame,
	progressFill: Frame,
	progressText: TextLabel,
	caps: ScrollingFrame,
	capsTitle: TextLabel,
	bench: Frame,
	benchGrid: Frame,
	benchLog: TextLabel,
	benchLines: { string },
	benchButtons: { [string]: TextButton },
	toastLabel: TextLabel,
	visible: boolean,
}

local function make(className: string, props: { [string]: any }, parent: Instance?): Instance
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function panel(name: string, parent: Instance, position: UDim2, size: UDim2, anchor: Vector2?): Frame
	local f = make("Frame", {
		Name = name,
		Position = position,
		Size = size,
		AnchorPoint = anchor or Vector2.new(0, 0),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.22,
		BorderSizePixel = 0,
	}, parent) :: Frame
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, f)
	make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Transparency = 0.88, Thickness = 1 }, f)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
	}, f)
	return f
end

local function label(name: string, parent: Instance, text: string, font: Font, size: number, color: Color3, order: number?): TextLabel
	return make("TextLabel", {
		Name = name,
		Text = text,
		FontFace = font,
		TextSize = size,
		TextColor3 = color,
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, size + 2),
		LayoutOrder = order or 0,
		TextWrapped = true,
	}, parent) :: TextLabel
end

local function list(parent: Instance, padding: number)
	make("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding),
		FillDirection = Enum.FillDirection.Vertical,
	}, parent)
end

function Hud.new(): Hud
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = make("ScreenGui", {
		Name = "MeadowHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
	}) :: ScreenGui
	local root = make("Frame", { Name = "Root", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, gui) :: Frame

	-- metrics, top left (below the Roblox top bar)
	local metrics = panel("Metrics", root, UDim2.new(0, 12, 0, 64), UDim2.new(0, 330, 0, 0))
	metrics.AutomaticSize = Enum.AutomaticSize.Y
	list(metrics, 1)
	label("Title", metrics, "UNIVERSE AT HOME <font color=\"#FFC478\">MEADOW</font>", SANS_BOLD, 17, INK, -10)
	label("Subtitle", metrics, "procedural world, three-ring grass, Actors, stress bench", SANS, 13, DIM, -9)

	-- world progress, top centre
	local progress = panel("Progress", root, UDim2.new(0.5, 0, 0, 64), UDim2.new(0, 420, 0, 46), Vector2.new(0.5, 0))
	local progressText = label("Text", progress, "Waiting for the server...", SANS, 14, INK)
	progressText.Size = UDim2.new(1, 0, 0, 18)
	local bar = make("Frame", {
		Name = "Bar",
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 0, 8),
		BackgroundColor3 = Color3.fromRGB(40, 46, 56),
		BorderSizePixel = 0,
	}, progress) :: Frame
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
	}, bar) :: Frame
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)

	-- capabilities, right
	local capsPanel = panel("Capabilities", root, UDim2.new(1, -12, 0, 64), UDim2.new(0, 400, 0.62, 0), Vector2.new(1, 0))
	local capsTitle = label("Title", capsPanel, "SELF-CHECK AND CAPABILITIES", SANS_BOLD, 15, INK)
	capsTitle.Size = UDim2.new(1, 0, 0, 18)
	local caps = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.new(0, 0, 0, 24),
		Size = UDim2.new(1, 0, 1, -24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, capsPanel) :: ScrollingFrame
	list(caps, 2)

	-- stress bench, bottom left
	local bench = panel("Bench", root, UDim2.new(0, 12, 1, -12), UDim2.new(0, 560, 0, 236), Vector2.new(0, 1))
	local benchTitle = label("Title", bench, "STRESS BENCH", SANS_BOLD, 15, INK)
	benchTitle.Size = UDim2.new(1, 0, 0, 18)
	local grid = make("Frame", {
		Name = "Buttons",
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 0, 62),
		BackgroundTransparency = 1,
	}, bench) :: Frame
	make("UIGridLayout", {
		CellSize = UDim2.new(0, 84, 0, 28),
		CellPadding = UDim2.new(0, 6, 0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, grid)
	local benchLog = label("Log", bench, "Results appear here and as MEADOW|client|result lines in Output.", MONO, 12, DIM)
	benchLog.Position = UDim2.new(0, 0, 0, 90)
	benchLog.Size = UDim2.new(1, 0, 1, -90)
	benchLog.AutomaticSize = Enum.AutomaticSize.None
	benchLog.TextYAlignment = Enum.TextYAlignment.Bottom

	-- toast, bottom centre
	local toastLabel = make("TextLabel", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.new(0, 520, 0, 26),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.3,
		TextColor3 = INK,
		FontFace = SANS,
		TextSize = 14,
		Text = "H toggles the HUD",
		BorderSizePixel = 0,
	}, root) :: TextLabel
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, toastLabel)

	gui.Parent = playerGui
	return {
		gui = gui,
		root = root,
		metrics = metrics,
		metricRows = {},
		metricCount = 0,
		progress = progress,
		progressFill = fill,
		progressText = progressText,
		caps = caps,
		capsTitle = capsTitle,
		bench = bench,
		benchGrid = grid,
		benchLog = benchLog,
		benchLines = {},
		benchButtons = {},
		toastLabel = toastLabel,
		visible = true,
	}
end

function Hud.setMetric(h: Hud, key: string, value: string)
	local row = h.metricRows[key]
	if not row then
		h.metricCount += 1
		row = label("M_" .. key, h.metrics, "", MONO, 13, INK, h.metricCount)
		h.metricRows[key] = row
	end
	row.Text = string.format("<font color=\"#96A0AC\">%-13s</font> %s", key, value)
end

function Hud.setProgress(h: Hud, fraction: number, text: string)
	h.progress.Visible = true
	h.progressFill.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
	h.progressText.Text = text
end

function Hud.hideProgress(h: Hud)
	h.progress.Visible = false
end

local function hexOf(c: Color3): string
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

-- entries: { { side, feature, state, detail } }
function Hud.setCapabilities(h: Hud, entries: { { side: string, feature: string, state: string, detail: string } })
	local seen: { [string]: boolean } = {}
	for i, e in entries do
		local key = e.side .. ":" .. e.feature
		seen[key] = true
		local row = h.caps:FindFirstChild(key) :: TextLabel?
		if not row then
			row = label(key, h.caps, "", MONO, 12, INK, i)
		end
		assert(row)
		row.LayoutOrder = i
		local color = Hud.STATE_COLORS[e.state] or INK
		local text = string.format(
			"<font color=\"%s\">\u{25CF}</font> <font color=\"#96A0AC\">%s</font> <b>%s</b> <font color=\"%s\">%s</font> %s",
			hexOf(color),
			if e.side == "server" then "S" else "C",
			e.feature,
			hexOf(color),
			e.state,
			e.detail
		)
		if row.Text ~= text then
			row.Text = text
		end
	end
	for _, child in h.caps:GetChildren() do
		if child:IsA("TextLabel") and not seen[child.Name] then
			child:Destroy()
		end
	end
end

function Hud.addBenchButton(h: Hud, id: string, text: string, order: number, onClick: () -> ())
	local b = make("TextButton", {
		Name = id,
		Text = text,
		FontFace = SANS,
		TextSize = 13,
		TextColor3 = INK,
		BackgroundColor3 = Color3.fromRGB(44, 52, 64),
		AutoButtonColor = true,
		LayoutOrder = order,
		BorderSizePixel = 0,
	}, h.benchGrid) :: TextButton
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
	b.Activated:Connect(function()
		onClick()
	end)
	h.benchButtons[id] = b
end

function Hud.setBenchButtonState(h: Hud, id: string, state: string)
	local b = h.benchButtons[id]
	if not b then
		return
	end
	local c = Hud.STATE_COLORS[state]
	b.BackgroundColor3 = if c then c:Lerp(Color3.fromRGB(44, 52, 64), 0.55) else Color3.fromRGB(44, 52, 64)
end

function Hud.benchLog(h: Hud, line: string)
	table.insert(h.benchLines, line)
	while #h.benchLines > 9 do
		table.remove(h.benchLines, 1)
	end
	h.benchLog.Text = table.concat(h.benchLines, "\n")
end

function Hud.toast(h: Hud, text: string)
	h.toastLabel.Text = text
end

function Hud.toggle(h: Hud)
	h.visible = not h.visible
	h.root.Visible = h.visible
end

return Hud
