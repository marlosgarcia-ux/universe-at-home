# Build and run locally

## 1. Get the code

```
git clone --branch claude/eloquent-clarke-a1n9la https://github.com/marlosgarcia-ux/universe-at-home.git
cd universe-at-home
```

No git? Download the ZIP: https://github.com/marlosgarcia-ux/universe-at-home/archive/refs/heads/claude/eloquent-clarke-a1n9la.zip

## 2. Install Rojo (it turns this repo into a Roblox place file)

Pick one:

| Tool | Command |
|---|---|
| Rokit | `rokit add rojo-rbx/rojo` |
| Aftman | `aftman add rojo-rbx/rojo` |
| Cargo | `cargo install rojo --locked` |
| Binary | https://github.com/rojo-rbx/rojo/releases |

Check with `rojo --version`. This repository was built with 7.7.1. You do not need the Rojo Studio plugin to build a file.

## 3. Build a place file

```
rojo build probe.project.json -o UniverseProbe.rbxlx
```

This puts the library (`src/`) in `ReplicatedStorage.Universe` and the in-engine probes from `studio/` in `StarterPlayerScripts` and `ServerScriptService`. A prebuilt copy is in `build/UniverseProbe.rbxlx`.

The Meadow demo (`docs/DEMO.md`) builds the same way from `demo/default.project.json`, or with `tools/build_demo.sh`, which also generates its assets and runs its checks. Those files appear on this branch when the demo build finishes.

## 4. Run the probes in Studio

1. Open `UniverseProbe.rbxlx` in Roblox Studio.
2. Home tab, Game Settings, Security: turn on **Allow Mesh / Image APIs**. Without it every EditableImage call fails.
3. Press **Play** (F5). Open the Output window.
4. The client probe prints a report starting with `# EditableImageProbe context=client`. Studio has no client memory budget, so the budget section only shows real limits on a device in a published place.
5. Copy the whole report from Output. It answers the questions in `docs/RUNTIME_AUDIT.md` section 7: size limits, API timings, the exact arithmetic of every combine type, whether stored alpha is straight or premultiplied, and how bilinear filtering behaves.
6. The `ParallelActor` script prints which EditableImage calls the engine allows in the parallel phase.
7. Optional: enable the disabled `RunOpsBench` scripts (server in `ServerScriptService`, client in `StarterPlayerScripts`) to measure Luau op costs in the real engine. They print `RESULT` lines that `tools/merge_bench.py` merges into a table.

## 5. Run the tests without Roblox

Get the Luau command line tools from https://github.com/luau-lang/luau/releases (or build them: `cmake` then `ninja Luau.Repl.CLI Luau.Analyze.CLI`). Then:

```
tests/run.sh /path/to/folder/containing/luau-and-luau-analyze
```

This runs every `tests/*.test.luau` in the interpreter and with native code generation, then checks strict types.

Ops benchmark: `tools/run_bench.sh /path/to/luau 3`.
