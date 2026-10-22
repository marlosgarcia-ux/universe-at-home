#!/usr/bin/env bash
# Builds the "Universe at Home: Meadow" demo place and runs every check that can run
# without Studio. Fails loudly (non-zero exit, FAIL lines) on any error.
#
#   1. assets     assets/liquid/*.aln (+ trees) -> demo/shared/Assets/*.luau ModuleScripts
#   2. place      rojo build -> build/UniverseMeadow.rbxlx and build/UniverseMeadow.rbxl
#   3. luau-lsp   type check of every demo/ script against the Roblox API definitions
#                 (globalTypes.None.d.luau = the security level game scripts run at) with a
#                 Rojo sourcemap and strict DataModel types
#   4. CLI tests  tests/demo.test.luau in the interpreter and with --codegen, plus
#                 luau-analyze --mode=strict of the pure generators
#   5. place      structural checks of the built .rbxlx (demo/check_place.py)
#
# usage: tools/build_demo.sh            full build and checks
#        SKIP_LSP=1 tools/build_demo.sh skip step 3 (only if luau-lsp is unavailable)
# environment overrides: ROJO, LUAU_LSP, ROBLOX_DEFS, LUAU_BUILD, PYTHON
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROJO="${ROJO:-/root/.cargo/bin/rojo}"
LUAU_LSP="${LUAU_LSP:-/home/user/tools-src/luau-lsp/build/luau-lsp}"
ROBLOX_DEFS="${ROBLOX_DEFS:-/home/user/tools-src/luau-lsp/scripts/globalTypes.None.d.luau}"
LUAU_BUILD="${LUAU_BUILD:-/home/user/luau-lang/luau/build}"
PYTHON="${PYTHON:-python3}"
OUT="$HERE/build"
fail=0

step() { printf '\n== %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=$((fail + 1)); }
good() { printf 'PASS %s\n' "$*"; }

mkdir -p "$OUT"

step "1. assets"
if [ -f "$HERE/tools/demo_assets.py" ]; then
  if "$PYTHON" -I "$HERE/tools/demo_assets.py" "$HERE"; then
    good "assets converted"
  else
    bad "asset conversion (tools/demo_assets.py)"
  fi
else
  echo "skip: tools/demo_assets.py not present"
fi

step "2. place"
if [ ! -x "$ROJO" ]; then
  bad "rojo not found at $ROJO"
else
  if "$ROJO" build "$HERE/demo/default.project.json" -o "$OUT/UniverseMeadow.rbxlx"; then
    good "build/UniverseMeadow.rbxlx ($(wc -c < "$OUT/UniverseMeadow.rbxlx") bytes)"
  else
    bad "rojo build (rbxlx)"
  fi
  if "$ROJO" build "$HERE/demo/default.project.json" -o "$OUT/UniverseMeadow.rbxl"; then
    good "build/UniverseMeadow.rbxl ($(wc -c < "$OUT/UniverseMeadow.rbxl") bytes)"
  else
    bad "rojo build (rbxl)"
  fi
fi

step "3. luau-lsp (Roblox API types)"
if [ "${SKIP_LSP:-0}" = "1" ]; then
  echo "skip: SKIP_LSP=1 (API usage NOT type-checked in this run)"
elif [ ! -x "$LUAU_LSP" ] || [ ! -f "$ROBLOX_DEFS" ]; then
  bad "luau-lsp ($LUAU_LSP) or Roblox definitions ($ROBLOX_DEFS) missing; set SKIP_LSP=1 to build anyway"
else
  # The sourcemap's file paths are relative to demo/, so luau-lsp runs from there.
  # strictDatamodelTypes keeps game/workspace/services typed by their classes while the
  # sourcemap resolves requires; without it luau-lsp 1.70 types DataModel access as any.
  printf '{"luau-lsp.diagnostics.strictDatamodelTypes": true}\n' > "$OUT/luau-lsp.settings.json"
  if (cd "$HERE/demo" && "$ROJO" sourcemap default.project.json --output "$OUT/sourcemap.json" --include-non-scripts >/dev/null); then
    report="$OUT/luau-lsp.txt"
    (cd "$HERE/demo" && "$LUAU_LSP" analyze \
        --platform=roblox \
        --settings="$OUT/luau-lsp.settings.json" \
        --sourcemap="$OUT/sourcemap.json" \
        --definitions=@roblox="$ROBLOX_DEFS" \
        shared server client workers) 2>&1 | grep -v '^\[INFO\]\|^\[WARN\] client does not allow' > "$report"
    errors=$(grep -c 'Error' "$report" || true)
    warnings=$(grep -vc 'Error' "$report" || true)
    if [ "$errors" -gt 0 ]; then
      cat "$report"
      bad "luau-lsp: $errors error(s) in demo/ scripts (report: build/luau-lsp.txt)"
    else
      [ -s "$report" ] && cat "$report"
      good "luau-lsp: 0 errors, $warnings lint line(s) in demo/shared, server, client, workers"
    fi
  else
    bad "rojo sourcemap"
  fi
fi

step "4. CLI tests"
for mode in "" "--codegen"; do
  if out="$("$LUAU_BUILD/luau" $mode "$HERE/tests/demo.test.luau" 2>&1)"; then
    good "tests/demo.test.luau ${mode:-interp}"
  else
    echo "$out"
    bad "tests/demo.test.luau ${mode:-interp}"
  fi
done
pure=()
for m in Config WorldGen RockGen Metrics Net GrassGen SkyGen Rings AssetCodec; do
  [ -f "$HERE/demo/shared/$m.luau" ] && pure+=("$HERE/demo/shared/$m.luau")
done
if out="$("$LUAU_BUILD/luau-analyze" --mode=strict "${pure[@]}" "$HERE/tests/demo.test.luau" 2>&1)"; then
  good "luau-analyze --mode=strict (pure generators)"
else
  echo "$out"
  bad "luau-analyze --mode=strict (pure generators)"
fi

step "5. place structure"
if [ -f "$OUT/UniverseMeadow.rbxlx" ]; then
  if "$PYTHON" -I "$HERE/demo/check_place.py" "$OUT/UniverseMeadow.rbxlx"; then
    good "place structure"
  else
    bad "place structure (demo/check_place.py)"
  fi
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "BUILD FAILED: $fail step(s) failed"
  exit 1
fi
echo "BUILD OK: build/UniverseMeadow.rbxlx"
