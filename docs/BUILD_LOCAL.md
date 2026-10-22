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

**The gallery: EditableImages you can see.** Start here.

```
rojo build gallery.project.json -o UniverseGallery.rbxlx
```

A prebuilt copy is in `build/UniverseGallery.rbxlx`. Open it in Studio, turn on **Allow Mesh / Image APIs** (Home, Game Settings, Security), and press **Play**. You get a panel of nine live EditableImages and a spinning cube in the world wearing the same images as Decals:

| Card | What it shows |
|---|---|
| Vector badge 512 x 512 | Exact-area anti-aliased shapes; tiles no edge touches are copy-filled |
| Live plasma 192 x 192 | Rewritten every frame; the compute and upload time per frame is measured and shown |
| Procedural marble 256 x 256 | Deterministic fractal noise, drawn progressively |
| Beyond 1024: 1152 x 1152 canvas | Nine 384 x 384 EditableImages as one canvas |
| LOD: hard switch, and two-phase fade | The same zoom twice: the sharpness jump versus the artifact-free fade |
| Green screen, matte, cut-out | Background removal with the green fringe removed and a glass bubble kept semi-transparent |

Press **G** to hide or show the panels. The heavy cards fill in over a few seconds because a frame-time scheduler spreads the work across frames. The HUD at top right shows FPS, how many EditableImages are alive and how much memory they take. If an image cannot be created, a red banner says what to enable.

How it was checked without Studio: the script type-checks with zero errors against Roblox's real API definitions (luau-lsp), `tools/gallery_mock_run.py` runs the real script against a mock of the API and compares every uploaded image with a direct render, and `tests/gallery.test.luau` covers the pixel code in both Luau runtimes. `tools/gallery_preview.luau` and `tools/gallery_preview.py` render the panels to PNG.

**The library and the probes** (for measuring the engine):

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
