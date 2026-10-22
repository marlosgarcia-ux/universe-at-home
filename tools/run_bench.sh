#!/usr/bin/env bash
# Runs bench/ops.luau in three configurations, interleaved ROUNDS times, so slow
# periods on a shared machine hit every configuration equally. Merge with the
# per-key minimum: python3 tools/merge_bench.py --mixed --min ...
#
# usage: tools/run_bench.sh /path/to/luau [ROUNDS] [OUTDIR] [TAG]
set -euo pipefail
LUAU="${1:?path to luau CLI}"
ROUNDS="${2:-3}"
OUT="${3:-bench/results}"
TAG="${4:-x64}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed 's/^--!optimize 2$/--!optimize 1/' "$HERE/bench/ops.luau" > "$TMP/ops_o1.luau"
mkdir -p "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  "$LUAU" "$TMP/ops_o1.luau"           > "$OUT/$TAG-interp-O1.r$r.tsv"
  "$LUAU" "$HERE/bench/ops.luau"       > "$OUT/$TAG-interp-O2.r$r.tsv"
  "$LUAU" --codegen "$HERE/bench/ops.luau" > "$OUT/$TAG-native-O2.r$r.tsv"
  echo "round $r done"
done
