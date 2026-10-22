-- universe-at-home :: studio/RunOpsBench.server.luau  (Script, disabled by default)
-- Enable this script in Studio to run bench/ops.luau on the server, where --!native is honoured.
-- It prints one RESULT line per measurement; paste the Output into
-- bench/results/ as a .tsv file and merge it with tools/merge_bench.py.
-- It takes a few minutes and yields between measurements, so the server stays responsive.

task.wait(2)
require(script.Parent:WaitForChild("OpsBench"))
