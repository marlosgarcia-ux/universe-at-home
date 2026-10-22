#!/usr/bin/env bash
# Runs every tests/*.test.luau under the Luau CLI, in the interpreter and with native
# code generation, then type-checks src/ and tests/ in strict mode.
# usage: tests/run.sh [path/to/luau-build-dir]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-/home/user/luau-lang/luau/build}"
LUAU="$BUILD/luau"
ANALYZE="$BUILD/luau-analyze"
fail=0
pass=0
for f in "$HERE"/tests/*.test.luau; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  for mode in "" "--codegen"; do
    if out="$("$LUAU" $mode "$f" 2>&1)"; then
      pass=$((pass + 1))
      printf 'PASS %-40s %s\n' "$name" "${mode:-interp}"
    else
      fail=$((fail + 1))
      printf 'FAIL %-40s %s\n%s\n' "$name" "${mode:-interp}" "$out"
    fi
  done
done
if [ -x "$ANALYZE" ]; then
  if out="$("$ANALYZE" --mode=strict "$HERE"/src/*.luau "$HERE"/tests/*.luau 2>&1)"; then
    echo "PASS luau-analyze --mode=strict"
  else
    fail=$((fail + 1))
    echo "FAIL luau-analyze --mode=strict"
    echo "$out"
  fi
fi
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
