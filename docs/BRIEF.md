# Brief for anyone (human or agent) working in this repository

## The ask, in the owner's words

> research the most efficient, absurd and revolutionizing way of making Roblox EditableImages
> multi-use in Roblox Studio: flawless 1024p, things that should be "impossible". When LODs are
> introduced with EditableImages, transitioning gives artifacts; seeing them transition is ugly,
> but making multiple resolutions is costly on a CPU. SDF-like deterministic numbers for specific
> textures, memory and pixels (if they are even represented as pixels at all) or another form of
> representing RGB(A), and a form to remove background. Solve it all; solve what is going to be a
> problem in the future. Create your own axioms of math.

Three names the owner gave are used as the three pillars of the design:

| Name | Meaning in this project |
|---|---|
| **MyMath** | The axiom system and the deterministic numerics library (`src/MyMath.luau`) |
| **Saturn** | Rings: the level-of-detail and residency system. Concentric rings of resolution around a focus, transitions that are continuous by construction, a fixed pixel budget regardless of extent |
| **Unholy** | The things that should be impossible: beyond 1024, budget evasion, dehydration into Luau memory, server-side native generation with baking, GPU-side ops that cost zero Luau time |

## What is already established (do not re-derive; cite it)

- `docs/RUNTIME_AUDIT.md`: every EditableImage-related API with thread safety, security, limits, budgets and labels (PUBLIC CONTRACT / IMPLEMENTATION DETAIL / COMMUNITY REPORT / NOT PUBLICLY SPECIFIED), plus every Luau op with its measured cost. Section 6.7 lists the economic rules; section 6.5 lists which ops are bit-deterministic across platforms.
- `bench/results/x64-summary.md`: measured ns per op and ms per 1024x1024 kernel, interpreter O1 (Studio), interpreter O2 (live), native O2.
- `studio/`: probes the owner runs inside Roblox to measure what cannot be measured outside (combine-op truth tables, budget size, API timings, parallel safety). Their output is not available yet; design for both outcomes where a probe decides something.

Hard facts that shape every design decision:

1. Client Luau is interpreted; native codegen is server-only. A full 1024x1024 pass costs 10 ms minimum (constant write) and 40 to 120 ms for shader-like kernels on a 2.1 GHz x64 core; phones are slower.
2. `buffer.fill` and `buffer.copy` run at memcpy speed (4.5 to 7 Gpix/s): 50 to 70 times faster than Luau loops. Spans of equal pixels must go through them.
3. The display side refreshes one EditableImage per frame. `WritePixelsBuffer` cost is proportional to the bytes written (to be measured by the probe).
4. Max EditableImage size is 1024x1024; client memory budget is strict and dynamic (community reports: about 32 MB, five or six 1024x1024 images); Luau buffers do not count against it.
5. `AssetService:CreateDataModelContentAsync` bakes an EditableImage into static content that gets real mipmaps, is free of the editable budget, and replicates server to client. `PromptCreatePlatformContentAsync` publishes an EditableImage as an asset (server only, user prompt).
6. GPU-side per-pixel ops that cost zero Luau time: `ImageTransparency`, `ImageColor3`, `ImageRectOffset/Size`, `ScaleType`, `ResampleMode`, `ZIndex`, `CanvasGroup.GroupTransparency`, `Decal.Transparency/Color3/UVOffset/UVScale/Rotation/ZIndex`.
7. `DrawImageTransformed` resamples in native engine code (bilinear or nearest); combine types are `BlendSourceOver, Overwrite, Add, Multiply, AlphaBlend, NormalMapBlend, Subtract`. Exact arithmetic is not published.
8. Pixel format is straight-alpha RGBA8, little-endian, so `readu32` gives `r + g*256 + b*65536 + a*16777216`.
9. Deterministic across platforms and runtimes: `+ - * / sqrt floor abs min max`, integer `//` and `%`, all `bit32`, integer buffer ops. Not deterministic: `math.lerp`, `vector.lerp` (fused multiply-add natively), libm functions (`sin`, `exp`, `pow`, `^`, `log`), `math.noise`, `math.random`.
10. `require("./Sibling")` works in Roblox and in the Luau CLI, so modules in `src/` require each other by relative string.

## Toolchain

| Tool | Command |
|---|---|
| Run a Luau file (interpreter) | `/home/user/luau-lang/luau/build/luau path/to/file.luau` |
| Run with native codegen | `/home/user/luau-lang/luau/build/luau --codegen path/to/file.luau` |
| Type check and lint | `/home/user/luau-lang/luau/build/luau-analyze --mode=strict file.luau` |
| Bytecode or native IR dump | `/home/user/luau-lang/luau/build/luau-compile --text -O2 file.luau`, `--codegenir` |
| Run the test suite (both runtimes) | `tests/run.sh` |
| Ops benchmark | `tools/run_bench.sh /home/user/luau-lang/luau/build/luau 1` |
| Flawless pipeline benchmark (both runtimes, 3 rounds) | `tools/run_flawless_bench.sh` (writes `bench/results/flawless-x64.md`) |
| Roblox docs source | `/home/user/roblox/creator-docs/content/en-us/reference/engine/` (yaml per class) |
| Roblox API dump | `/home/user/maximumadhd/roblox-client-tracker/API-Dump.json` |
| Luau source | `/home/user/luau-lang/luau/` |

Network access to roblox.com and devforum is blocked in this environment; use the local clones.

## Rules for code in `src/`

- Pure Luau, no Roblox globals at module level. Engine objects are injected (see `Canvas.editableImageWriter`). Every module must load and run under the Luau CLI so tests can run here.
- `--!native` and `--!optimize 2` at the top of every pixel module. Strict-mode clean under `luau-analyze --mode=strict`.
- Deterministic ops only (fact 9) in anything that generates texture content.
- Follow the economics in `docs/RUNTIME_AUDIT.md` 6.7: spans through `buffer.copy`/`fill`, arithmetic packing, no non-builtin per pixel, cache upvalues in locals before hot loops.
- Tests live in `tests/*.test.luau`, run by `tests/run.sh` in both runtimes; they must assert, not print.

## Flawless rules (docs/COMPUTE.md sections 1 and 12)

- **F1: coverage is exact area.** Content edges use exact pixel areas: `Raster` `MODE_EXACT` (the default) or the exact functions in `compute/Coverage.luau` (`discBoxArea`, `discPolyArea`, `polygonBoxCoverage`, `MyMath.coverageHalfPlane` for straight edges). `MyMath.coverage` is the linear preview ramp (errs up to 57/255) and `MyMath.coverageCurved` an estimator (O(1/R) residual): neither may write content. Supersampling is never a reference.
- **F2: composite with exact visibility.** A scene is the exact box filter of its source-over composite. Never paint shapes that share pixels by chaining coverage as alpha (C11 seams of 48 to 84/255): use `Raster` `MODE_EXACT` or `Scanline.renderScene`; `Scanline.composite` is for one path only. Keep the composite in floating point and round each byte once.
- **F3: deterministic ops only.** `+ - * /`, `sqrt`, `floor`, comparisons, integer `//` and `%`, `bit32`, and angles through `Coverage.dasin` / `Coverage.datan2`; never `math.asin`, `atan`, `sin`, `cos`, `exp`, `pow`, `^` or `lerp` in content (references in tests may). Every new pixel path gets a hash constant asserted in both runtimes.
- **Reach.** Culling and bounding boxes use the coverage function's reach: `MyMath.COVERAGE_REACH * w` (sqrt(2)/2) for exact coverage, `w/2` only for the ramp.
- **Conditioning.** Exact formulas must stay well conditioned at their edge cases (vertical tangents, near-tangent chords, tiny or huge radii, shared vertices): prefer closed forms of differences (one arcsine of an angle difference, `(r - t)(r + t)` for `r^2 - t^2`), take differences before products in geometric predicates, and pin references to high-precision values where the double closed form is ill conditioned.
- **References and proofs.** Every exactness claim is either proved in COMPUTE.md or asserted against an independent exact reference (`refPixel` in `tests/flawless.test.luau`, 50-digit values), with the bound `|byte - 255 A| <= 0.51`.
- **LOD.** Render each level directly at its own resolution (`Raster.scaled`) or with the exact area resampler (`Filter.areaResample` for opaque, `Filter.areaResampleAlpha` for straight-alpha raster content). Switch levels only through `Saturn` (hysteresis selector, two-phase stacked fade applied to `ImageTransparency` / `Decal.Transparency`): never crossfade on the CPU and never fade both layers symmetrically.

## Repository map

```
docs/RUNTIME_AUDIT.md   what the engine and Luau actually do (measured and sourced)
docs/BRIEF.md           this file
docs/DESIGN.md          the axioms, theorems, algorithms and architecture (written by the design workflow)
bench/ops.luau          op and kernel micro-benchmark; bench/results/ holds runs
studio/                 scripts to run inside Roblox Studio or a published place
src/MyMath.luau         deterministic numerics, hashing, noise, SDF primitives, colour arithmetic, budget allocation,
                        the pixel axioms (F1 to F3, C3 to C5, reach) and exact half-plane coverage
src/Pixels.luau         buffer-level RGBA8 ops (span fill, blits, 2x box mip, source-over, alpha bleed, palette expand)
src/Canvas.luau         CPU image with dirty-tile tracking and a flush planner
src/Saturn.luau         LOD selection with hysteresis and two-phase stacked GPU crossfades (pure logic)
src/compute/            rasterizers and image operators of docs/COMPUTE.md; Raster (flawless by default),
                        Scanline (exact multi-path scenes), Visibility (exact compositing), Coverage, Filter, ...
tests/                  Luau tests runnable by the CLI
tools/                  benchmark runner and result merger
```
