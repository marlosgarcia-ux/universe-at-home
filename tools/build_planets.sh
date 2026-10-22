#!/usr/bin/env bash
# Builds the "Universe at Home: Planets" place and runs every check that can run without
# Studio. Fails loudly (non-zero exit, FAIL lines) on any error.
#   1. place      rojo build -> build/UniversePlanets.rbxlx and .rbxl
#   2. luau-lsp   every planets/ script against the Roblox API definitions (strict
#                 DataModel types, Rojo sourcemap)
#   3. CLI tests  tests/planets*.test.luau in the interpreter and with --codegen
#   4. structure  tools/check_planets_place.py on the built place
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

step "1. place"
for ext in rbxlx rbxl; do
  if "$ROJO" build "$HERE/planets/default.project.json" -o "$OUT/UniversePlanets.$ext" >/dev/null; then
    good "build/UniversePlanets.$ext ($(wc -c < "$OUT/UniversePlanets.$ext") bytes)"
  else
    bad "rojo build ($ext)"
  fi
done

step "2. luau-lsp (Roblox API types)"
printf '{"luau-lsp.diagnostics.strictDatamodelTypes": true}\n' > "$OUT/planets-lsp.settings.json"
if (cd "$HERE/planets" && "$ROJO" sourcemap default.project.json --output "$OUT/planets-sourcemap.json" --include-non-scripts >/dev/null); then
  report="$OUT/planets-lsp.txt"
  (cd "$HERE/planets" && "$LUAU_LSP" analyze --platform=roblox --settings="$OUT/planets-lsp.settings.json" \
      --sourcemap="$OUT/planets-sourcemap.json" --definitions=@roblox="$ROBLOX_DEFS" client shared workers) 2>&1 \
      | grep -v '^\[INFO\]\|client does not allow' > "$report"
  errors=$(grep -c 'Error' "$report" || true)
  lines=$(wc -l < "$report")
  if [ "$errors" -eq 0 ] && [ "$lines" -eq 0 ]; then
    good "luau-lsp: no errors or warnings in planets/"
  else
    cat "$report"
    bad "luau-lsp: $errors errors, $lines lines (build/planets-lsp.txt)"
  fi
else
  bad "rojo sourcemap"
fi

step "3. CLI tests"
for t in "$HERE"/tests/planets*.test.luau; do
  for mode in "" "--codegen"; do
    if out="$("$LUAU_BUILD/luau" $mode "$t" 2>&1)"; then
      good "$(basename "$t") ${mode:-interp}: $(echo "$out" | tail -1)"
    else
      echo "$out" | tail -5
      bad "$(basename "$t") ${mode:-interp}"
    fi
  done
done

step "4. mock run of the client (tools/planets_mock_run.py)"
if out="$("$PYTHON" "$HERE/tools/planets_mock_run.py" --codegen "$LUAU_BUILD/luau" 2>&1)"; then
  good "client mock run: $(echo "$out" | grep -c '^ok ') checks, $(echo "$out" | tail -2 | head -1)"
else
  echo "$out" | grep -v '^ok \|^PLANETS' | tail -20
  bad "client mock run"
fi

step "5. place structure"
if "$PYTHON" -I "$HERE/tools/check_planets_place.py" "$OUT/UniversePlanets.rbxlx"; then
  good "place structure"
else
  bad "place structure"
fi

echo
if [ "$fail" -eq 0 ]; then echo "BUILD OK"; else echo "BUILD FAILED: $fail"; fi
exit "$fail"
