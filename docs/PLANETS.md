# Universe at Home: Planets

A stress test of EditableImages at planetary scale. Every surface pixel on screen is generated at run time on worker Actors and streamed through EditableImages: a 1600-stud planet you can fly from orbit down to 1.5 studs above a coastline, a cratered moon, a ringed gas giant, clouds, stars and the sun.

The place is `build/UniversePlanets.rbxlx` (and `.rbxl`). Open it in Studio, turn on **Game Settings > Security > Allow Mesh / Image APIs**, and press Play. Nothing else is needed: there is no server script, no character, and no asset upload.

## Changing the resolution

Every tunable is in one module: `ReplicatedStorage > Planets > Config` in Studio, or `planets/shared/Config.luau` in the repository. Each value has a comment with its limit and memory cost. More surface tiles than 256 need new code (extra atlas sets); everything else is a number.

## Controls

| Keys | Action |
|---|---|
| hold right mouse | look around |
| W A S D, E / Space, Q / C | move; up and down follow the view |
| Shift, mouse wheel | x5 boost; change the base speed (speed also scales with altitude) |
| 1 to 6 | orbit, approach, coastline at 25 studs, mountain range, Selene, Saturnia |
| F | level-of-detail fades on or off (two-phase fade versus a hard switch) |
| T | tint every patch by its quadtree level |
| L | freeze the level of detail |
| B | stress: finer detail (texel threshold 0.8 px, 240 patches) |
| G | impostors only (every body as its raytraced billboard, even up close) |
| N | flip the normal map's green channel and rebuild the surface |
| V | flip the UV origin (bottom-left instead of top-left) |
| K | animate the sun |
| M | clouds on or off |
| X | probe the EditableImage memory budget |
| H | hide the HUD |

The HUD shows frame time, our main-thread Luau time, patches shown, cached and generating, the deepest level, tiles per second, worker state, uploads, impostor renders, and the EditableImage memory in use. The status list on the right reports every stage as ok, fallback or failed, and the same lines go to Output as `PLANETS|stage|state|detail`.

## What is in it

| Part | What it draws | EditableImages |
|---|---|---|
| Terra, Selene | cube-sphere quadtree of up to 256 pooled patch meshes; each patch owns one 64 px tile of a colour, a normal and a roughness atlas, shown through a SurfaceAppearance | 1024², 1024², 512² (shared by both, one body at a time) |
| every body | a raytraced billboard (impostor): exact anti-aliased limb, atmosphere, clouds, ocean glint, rings with exact box-filtered gaps, ring and planet shadows | 3 × 512² |
| Terra's clouds | a rotating shell, six 256 px faces in one atlas | 1024 × 512 |
| space | six star faces for the Sky, the sun sprite | 6 × 512², 256² |

In total 14 EditableImages, 5.31 Mpx, about 21 MB as RGBA8.

## How the engine's rules shaped it

**One displayed EditableImage refreshes per frame** (EditableImage reference, docs/RUNTIME_AUDIT.md). So patches never get images of their own: they share three atlases, and every pixel write goes through one queue (`planets/client/Uploader.luau`) that flushes exactly one image per frame, with all of that image's pending rectangles. One atlas refresh can carry dozens of tiles. A patch counts as ready only after all three of its atlases have flushed.

**Normal and roughness maps are plugin-only properties.** A game script gets them through `AssetService:CreateSurfaceAppearanceAsync`, whose maps cannot be swapped afterwards. The EditableImages behind them can be rewritten, though, and that is all the pool ever does. If the engine refuses the call, the pool falls back to `MeshPart.TextureContent` (colour only) and says so in the status list.

**The client memory budget is strict and unknown.** Community reports put it near 32 MB, and Studio has no budget. Everything is allocated once at start and recycled. The X key measures the real budget on the device by allocating 256 × 256 images until the engine refuses, then frees them.

**Meshes are created once and only rewritten.** Each slot's EditableMesh has fixed topology, UVs into its own tile and per-vertex normals. Assigning a patch rewrites its 363 positions and normals with one batch call each. Every vertex is body-local, and two tiny triangles pin the bounding box to ±1900 studs. The box is therefore centred on the body whichever origin rule the engine uses, and it never changes size, so the engine never rescales a part.

**Distances are compressed for billboards.** Bodies lie up to 37,000 studs apart. A billboard is drawn at a compressed distance along its true direction, scaled by the same factor, so its angular size and position are exact while it stays well inside the depth range.

## The mathematics

- **Surfaces are pure functions of a direction** (`planets/shared/Bodies.luau`). Every patch, level, face, impostor and test samples the same planet. Low-frequency fields are defined on one global lattice of 128 × 128 cells per cube face, so shared patch edges are bit-identical at every level. Per-patch interpolation grids had shown seams of up to 100 colour levels.
- **Texel centres sit on patch edges** (`Layout.luau`), with a one-texel gutter. Two patches sample the same points along their shared edge, and the bilinear filter never reads a neighbouring tile.
- **Coastlines are anti-aliased by exact area.** Near sea level the height divided by its gradient is a signed distance in texels, and `MyMath.coverageHalfPlane` gives the land share of each texel. Coasts stay crisp at every level of detail.
- **Normal maps are tangent-space against the sphere's own frame.** The mesh's vertex normals are the sphere normals, so the map carries all the relief. Tests decode the map and recover the surface normal to within 1.5 degrees on average.
- **Craters are distance-field profiles** on gnomonic cells, scaled so that each crater stays inside its own cell everywhere on a face.
- **Ring gaps are exact box filters** of the radial profile through prefix integrals. A gap narrower than a pixel dims that pixel by its share instead of flickering.
- **Level of detail is chosen in screen space** (`Quadtree.luau`). The patch whose texels look largest splits first, within the atlas's capacity, with hysteresis, and patches behind the horizon never split. The plan only swaps patches that are fully generated, so the displayed patches always partition the sphere, and it coarsens first when atlas tiles run short.

## Verification (all without Studio)

`tools/build_planets.sh` runs every step below and stops on failure:

1. Rojo builds the place.
2. luau-lsp type-checks every planets script against the Roblox API definitions: no errors, no warnings.
3. CLI tests run in the interpreter and under native code. The core test (151 checks) covers bit-identical seams, normal-map decoding, mesh orientation, crater and ring maths, and a golden tile digest. The level-of-detail test (22 checks) flies a whole flight with the partition invariant held on every frame. The render test (45 checks) checks the limb's alpha against 16 × 16 supersampling, billboard bounds, and cloud-cache reconstruction.
4. A mock-API run of the real client (`tools/planets_mock_run.py`, 69 checks) flies orbit, approach, coastline, the N and V toggles, a focus switch to Selene, then Saturnia and the budget probe. It checks for no errors, at most one image written per frame for the whole run, and that a shown patch's atlas tiles and vertices equal its generation byte for byte. It also checks that the displayed patches partition the sphere in every phase.
5. A structural check of the built place: classes, disabled worker templates and their RunContext, and every string require resolved.

The mock run found a real bug before any Studio run. A child patch that finished before its siblings looked unneeded and was evicted and regenerated forever: 2,785 tiles for 4 swaps, and detail stuck at level 2. The plan now lists every patch a pending step needs, and the pool grows before it evicts.

## Measured on this machine (CLI, x64 VM)

| Work | Interpreter | Native |
|---|---|---|
| one patch tile (64² colour, normal, roughness, and the mesh), deep levels | 90 to 120 ms | 40 to 70 ms |
| one patch tile, levels 0 to 3 | 40 to 70 ms | 20 to 30 ms |
| Terra's impostor, 320², from its cache | 195 ms | 43 ms |
| Terra's sphere cache, six faces of 96² | 2.0 s | 0.75 s |
| mock run: 1,389 frames, 674 tiles | 62 s | 26 s |

Roblox clients run Luau interpreted, so the first column is the one that matters. Six worker Actors give tens of tiles per second.

## Not verified until it runs in Studio

These are engine behaviours this repository cannot observe. Each one has a fallback or a key:

- **UV origin.** The atlas assumes Roblox mesh UVs start at the top-left of the image. If patches look scrambled or seams appear at every patch edge, press V.
- **Normal-map green channel.** The tiles follow the OpenGL convention Roblox documents, read with top-left UVs. If relief looks lit from the wrong side, press N.
- **Live edits of SurfaceAppearance maps.** Rewriting an EditableImage behind a SurfaceAppearance should show on screen, per the in-experience SurfaceAppearance announcement. If patches stay grey, the status list says which path is active.
- **Cloning a SurfaceAppearance keeps its maps.** The pool tests the first clone and falls back to one CreateSurfaceAppearanceAsync call per slot.
- **Texture alpha on the cloud shell.** The shell relies on MeshPart texture transparency. M toggles the clouds.
- **Depth range.** The mesh is shown within 2.3 radii, about 3,700 studs, and billboards stay within 3,500 studs. Neither has been checked against the engine's far plane.
- **The real client memory budget.** Press X to measure it.
- **Frame time with 256 patch parts, 164,000 triangles, on real devices.**

## Files

| Path | Role |
|---|---|
| `planets/shared/` | pure Luau: Layout, Noise3, CubeSphere, Bodies, TileGen, Quadtree, SphereCache, Impostor, SkyGen, Clouds, PlanetJobs |
| `planets/client/` | Roblox client: Main, Uploader, MeshPool, PlanetLod, Impostors, Sky, CloudLayer, Flight, Hud, Workers |
| `planets/workers/client/` | Actor templates (Script with RunContext Client, LocalScript fallback) |
| `planets/default.project.json` | Rojo project (reuses demo/shared/WorkerPool and WorkerMain) |
| `tests/planets*.test.luau` | CLI tests |
| `tools/build_planets.sh`, `tools/planets_mock*`, `tools/check_planets_place.py` | build and verification |
| `tools/planets_preview.luau`, `tools/planets_impostor_preview.luau` | PNG previews of tiles and impostors |
