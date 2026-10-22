#!/usr/bin/env bash
# Runs bench/compute.luau in the interpreter and with native codegen, interleaved,
# ROUNDS times, so slow periods on the shared machine hit both runtimes equally.
# Then merges with the per-key minimum into bench/results/compute-x64.md.
#
# usage: tools/run_compute_bench.sh [/path/to/luau] [ROUNDS]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${1:-/home/user/luau-lang/luau/build/luau}"
ROUNDS="${2:-3}"
OUT="$HERE/bench/results"
mkdir -p "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  "$LUAU" "$HERE/bench/compute.luau" > "$OUT/compute-x64-interp.r$r.tsv"
  "$LUAU" --codegen "$HERE/bench/compute.luau" > "$OUT/compute-x64-native.r$r.tsv"
  echo "round $r done"
done
interp=$(ls "$OUT"/compute-x64-interp.r*.tsv | paste -sd, -)
native=$(ls "$OUT"/compute-x64-native.r*.tsv | paste -sd, -)
python3 "$HERE/tools/merge_compute.py" "$interp" "$native" > "$OUT/compute-x64.md"
echo "wrote $OUT/compute-x64.md"
