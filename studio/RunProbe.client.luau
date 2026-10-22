-- universe-at-home :: studio/RunProbe.client.luau  (LocalScript)
-- Put this LocalScript and the EditableImageProbe ModuleScript in StarterPlayerScripts.
-- The client is where the editable memory budget applies, so this is the run that
-- matters. Run it in a published place on the devices you target for budget numbers.

local Probe = require(script.Parent:WaitForChild("EditableImageProbe"))

task.wait(3) -- let the client finish loading so timings are not skewed by startup work
Probe.run()
