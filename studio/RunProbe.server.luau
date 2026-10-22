-- universe-at-home :: studio/RunProbe.server.luau  (Script)
-- Put this Script and a copy of the EditableImageProbe ModuleScript in ServerScriptService.
-- Servers have no editable memory budget, so the budget section stops at its cap.
-- The budget section is skipped here to avoid allocating 1 GiB on the server.

local Probe = require(script.Parent:WaitForChild("EditableImageProbe"))

task.wait(1)
Probe.run({ budget = false })
