#!/usr/bin/env bash
# Runs bench/flawless.luau in the interpreter and with native codegen, interleaved,
# ROUNDS times, so slow periods on the shared machine hit both runtimes equally.
# Then merges with the per-key minimum into bench/results/flawless-x64.md.
#
# usage: tools/run_flawless_bench.sh [/path/to/luau] [ROUNDS]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LUAU="${1:-/home/user/luau-lang/luau/build/luau}"
ROUNDS="${2:-3}"
OUT="$HERE/bench/results"
mkdir -p "$OUT"
rm -f "$OUT"/flawless-x64-interp.r*.tsv "$OUT"/flawless-x64-native.r*.tsv
for r in $(seq 1 "$ROUNDS"); do
  "$LUAU" "$HERE/bench/flawless.luau" > "$OUT/flawless-x64-interp.r$r.tsv"
  "$LUAU" --codegen "$HERE/bench/flawless.luau" > "$OUT/flawless-x64-native.r$r.tsv"
  echo "round $r done ($(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?') load)"
done
interp=$(ls "$OUT"/flawless-x64-interp.r*.tsv | paste -sd, -)
native=$(ls "$OUT"/flawless-x64-native.r*.tsv | paste -sd, -)
python3 "$HERE/tools/merge_compute.py" "$interp" "$native" > "$OUT/flawless-x64.md"
echo "wrote $OUT/flawless-x64.md"
