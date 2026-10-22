-- universe-at-home :: studio/RunOpsBench.client.luau  (Script with RunContext Client, disabled by default)
-- Enable this script in Studio to run bench/ops.luau on the client, where Luau runs in the
-- interpreter. This is the number that matters for pixel code on players' devices.
-- It prints one RESULT line per measurement; paste the Output into
-- bench/results/ as a .tsv file and merge it with tools/merge_bench.py.

task.wait(3)
require(script.Parent:WaitForChild("OpsBench"))
