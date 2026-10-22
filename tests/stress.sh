#!/usr/bin/env bash
# Runs every tests/stress/*.stress.luau in the interpreter and with native code generation,
# and checks that both runtimes produce the same DIGEST (a rolling hash of every deterministic
# result the suite computed), which proves bit-identical results over the whole workload.
#
# usage: tests/stress.sh [quick|standard|heavy] [path/to/luau-build-dir]
#   quick     seconds, for a smoke test
#   standard  the default; about a minute
#   heavy     six times the iterations
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LEVEL="${1:-standard}"
BUILD="${2:-/home/user/luau-lang/luau/build}"
LUAU="$BUILD/luau"
fail=0
for f in "$HERE"/tests/stress/*.stress.luau; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .luau)"
  d_interp=""
  d_native=""
  for label in interp native; do
    flag=""
    [ "$label" = native ] && flag="--codegen"
    start=$(date +%s)
    out="$("$LUAU" $flag "$f" -a "$LEVEL" 2>&1)"
    status=$?
    secs=$(( $(date +%s) - start ))
    d="$(echo "$out" | grep '^DIGEST' | awk '{print $3}')"
    [ "$label" = interp ] && d_interp="$d" || d_native="$d"
    echo "$out" | grep -E '^(FAIL|      FINDING)' | sed "s/^/  [$label] /"
    if [ $status -ne 0 ]; then
      fail=$((fail + 1))
      printf 'FAIL %-20s %-7s %4ss\n' "$name" "$label" "$secs"
    else
      printf 'PASS %-20s %-7s %4ss  digest %s\n' "$name" "$label" "$secs" "$d"
    fi
  done
  if [ -n "$d_interp" ] && [ "$d_interp" != "$d_native" ]; then
    fail=$((fail + 1))
    printf 'FAIL %-20s digests differ: interpreter %s, native %s\n' "$name" "$d_interp" "$d_native"
  fi
done
[ "$fail" -eq 0 ] && echo "stress: all suites passed at level $LEVEL, interpreter and native digests identical" || echo "stress: $fail failure(s)"
exit "$fail"
