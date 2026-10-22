--!strict
-- Universe at Home: Planets :: Hud
--
-- On-screen stats for the stress test, the key legend, and a status list where every
-- stage reports ok / fallback / failed instead of erroring (each line is also printed to
-- Output as PLANETS|<stage>|<state>|<detail>).

local Players = game:GetService("Players")

local Hud = {}

-- Live references to the client's subsystems, for the CLI mock harness
-- (tools/planets_mock_run.py) and for inspection from the command bar.
Hud.debug = {} :: { [string]: any }

export type Hud = {
	gui: ScreenGui,
	stats: TextLabel,
	status: TextLabel,
	help: TextLabel,
	lines: { string },
	order: { string },
	entries: { [string]: string },
	visible: boolean,
}

local function label(parent: Instance, name: string, pos: UDim2, size: UDim2, anchor: Vector2, align: Enum.TextXAlignment): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundColor3 = Color3.fromRGB(6, 8, 16)
	t.BackgroundTransparency = 0.35
	t.BorderSizePixel = 0
	t.Position = pos
	t.Size = size
	t.AnchorPoint = anchor
	t.AutomaticSize = Enum.AutomaticSize.XY
	t.Font = Enum.Font.Code
	t.TextSize = 14
	t.TextColor3 = Color3.fromRGB(225, 232, 255)
	t.TextXAlignment = align
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.RichText = false
	t.Text = ""
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = t
	t.Parent = parent
	return t
end

local HELP = table.concat({
	"FLY  hold right mouse: look   W A S D: move   E/Space up   Q/C down   Shift x5   wheel: speed",
	"VIEW 1 orbit  2 approach  3 coast  4 mountains  5 Selene  6 Saturnia",
	"TEST F fades on/off   T tint by level   L freeze LOD   B stress (finer LOD)   G impostors only",
	"     N flip normal-map green   V flip UV origin   K sun cycle   M clouds   X probe memory budget   H hide",
}, "\n")

function Hud.new(): Hud
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlanetsHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local player = Players.LocalPlayer
	gui.Parent = player:WaitForChild("PlayerGui")
	local h: Hud = {
		gui = gui,
		stats = label(gui, "Stats", UDim2.fromOffset(12, 12), UDim2.fromOffset(0, 0), Vector2.zero, Enum.TextXAlignment.Left),
		status = label(gui, "Status", UDim2.new(1, -12, 0, 12), UDim2.fromOffset(0, 0), Vector2.new(1, 0), Enum.TextXAlignment.Left),
		help = label(gui, "Help", UDim2.new(0, 12, 1, -12), UDim2.fromOffset(0, 0), Vector2.new(0, 1), Enum.TextXAlignment.Left),
		lines = {},
		order = {},
		entries = {},
		visible = true,
	}
	h.help.Text = HELP
	h.status.TextSize = 13
	return h
end

-- Records a stage result: state is "ok", "fallback", "failed" or "info".
function Hud.set(h: Hud, stage: string, state: string, detail: string)
	if not h.entries[stage] then
		table.insert(h.order, stage)
	end
	local mark = if state == "ok" then "[ok]  " elseif state == "fallback" then "[fall]" elseif state == "failed" then "[FAIL]" else "[..]  "
	h.entries[stage] = mark .. " " .. stage .. ": " .. detail
	local out = {}
	for _, s in h.order do
		table.insert(out, h.entries[s])
	end
	h.status.Text = table.concat(out, "\n")
	print(string.format("PLANETS|%s|%s|%s", stage, state, (string.gsub(detail, "[\r\n|]", " "))))
end

function Hud.stats(h: Hud, text: string)
	h.stats.Text = text
end

function Hud.toggle(h: Hud)
	h.visible = not h.visible
	h.gui.Enabled = h.visible
end

return Hud
