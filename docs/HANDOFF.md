# Handoff

Where the project stands on 2026-10-22, written so a new chat can pick it up. Read this first, then docs/PLANETS.md and the header comment of each module.

## Getting it

- GitHub: `marlosgarcia-ux/universe-at-home`, branch `claude/eloquent-clarke-a1n9la`. Everything below is pushed there.

  ```
  git clone -b claude/eloquent-clarke-a1n9la https://github.com/marlosgarcia-ux/universe-at-home.git
  ```

- The conversation that produced this branch can be pulled into a local Claude Code terminal with its full history. From a clean checkout of this repository, signed in to the same claude.ai account:

  ```
  claude --teleport session_01NU6oDLBc83ZQ5RaYstMAuS
  ```

- docs/BUILD_LOCAL.md covers installing Rojo and building the places.

## Checks

`tools/build_planets.sh` runs everything that can run without Studio. Each tool's path is an environment variable:

| Variable | Tool | Used for |
|---|---|---|
| ROJO | Rojo 7.7.1 | the place file and the sourcemap |
| LUAU_LSP | luau-lsp, built from source | type checking planets/ against the Roblox API |
| ROBLOX_DEFS | luau-lsp's `globalTypes.None.d.luau` | the Roblox API definitions |
| LUAU_BUILD | a build folder of luau-lang/luau holding `luau` and `luau-analyze` | CLI tests and the mock run |
| PYTHON | Python 3 | the mock runner and the place checker |

At handoff all of it passes, in about 80 seconds:

- the place builds, `build/UniversePlanets.rbxlx` and `.rbxl`
- luau-lsp: no errors, no warnings
- `tests/planets.test.luau` 151 checks, `planets_atmos` 228, `planets_lod` 22, `planets_render` 52, each in the interpreter and with `--codegen`
- the mock run of the real client: 101 checks
- the place structure check

The mock in `tools/planets_mock` is a fake Roblox written in Luau: instances, a task scheduler, EditableImages that keep their pixels, the EditableMesh batch API with a configurable vertex limit. It drives the real client through orbit, approach, the coastline, every key and the memory probe. It proves the code paths run and agree with each other. It cannot prove what the real engine does.

## The open request

The last request, in the user's words:

> lets make a more realistic planet atmosphere rendering, absolute fine details even upclose, an actual editablemesh (editablemesh batch for rendering it ofc) and lets make volumetric clouds, actual atmospheric calculations but efficient and pretty, true blacks on the colors. and a better camera. basically a 4K resolution beyond 1024. i'd say to make part of it on the server with multiple cores (two)

| Part | State |
|---|---|
| Atmosphere from real scattering | done: `planets/shared/Atmos.luau`, commit affe4c1 |
| True blacks in the billboards | done, tested pixel for pixel |
| One EditableMesh through the batch API | done: one mesh per atlas set, geomorph LOD, commit 736c9a4 |
| Beyond 1024 | done where the engine allows it: billboards up to 2048 as a 2 x 2 grid of images, more atlas sets for the ground |
| Volumetric clouds | half done: the bake is `planets/shared/CloudVol.luau`; nothing calls it yet |
| Two server cores | not started |
| Better camera | not started |
| True black engine lighting | not started |
| docs/PLANETS.md | stale: last edited in 14e05d6, before the atmosphere and single-mesh commits |

On "4K": an EditableImage is at most 1024 x 1024 and client Luau is interpreted, so a full-screen 4K raymarch every frame is out of reach. Detail beyond 1024 comes from many images at once: atlas sets for the ground, tiled billboards, baked cloud faces.

## Next steps, in order

### 1. Clouds baked on the server

Designed, not written:

- Files: `planets/server/Main.server.luau`, `CloudBaker.luau`, `Bake.luau`, and a worker at `planets/workers/server/PlanetServerWorker`: a Script with RunContext Server inside an Actor, disabled until cloned. Two Actors, `Config.serverWorkers = 2`. Add both folders to `planets/default.project.json`.
- One job is one cube face of one layer: `CloudVol.bakeFace(R, layer, face, n, sunX, sunY, sunZ)` returns an RGBA8 buffer. Add a `cloudBake` job kind to `PlanetJobs.luau`.
- The server writes each face into an EditableImage, turns it into replicating content with `AssetService:CreateDataModelContentAsync`, puts that on `Decal.TextureContent` under a replicated folder `PlanetsBaked/Clouds/V<n>`, then sets the attributes `Version` and `Sun` on the folder.
- It bakes again when the sun has moved more than `Config.cloudRebakeDegrees`.
- `Version` is a generation counter in the K-RDAP sense: a client shows a version only once all of its faces have arrived and never mixes faces from two versions on screen. It crossfades from the old complete version to the new complete one.
- Cost, measured with native codegen in the CLI: 0.45 to 0.6 s per 256 x 256 face and layer. Six faces and three layers at 512 is about 40 s on one core, about 20 s on two. Defaults should be 256 or 384 per face, two layers, and rare rebakes.
- New Config keys: `cloudLayers`, `cloudFace` at most 512, `serverWorkers`, `cloudRebakeDegrees`, optionally `dayMinutes`.

### 2. Client clouds, version 2

`planets/client/CloudLayer.luau` draws one shell. Replace it with stacked shells at CloudVol's layer heights, one EditableMesh per face per layer, each layer spinning at its own rate, textured from the baked Decal content, CastShadow off. When nothing has been baked, the client bakes one layer at 256 on its own workers.

The mock needs a server context for this: ServerScriptService, Decal, `CreateDataModelContentAsync` returning `Enum.CreateContentResult`, `Lighting:GetSunDirection`, plus checks that a Version bump bakes again and that the client uses the baked content.

### 3. Camera, version 2

`planets/client/Flight.luau` is version 1. Wanted: smoothed inertial look and motion, speed that scales with altitude, an orbit mode around the nearest body, terrain following near the ground, FOV zoom, a speed readout in the HUD.

### 4. True black engine lighting

In space: `Lighting.Ambient` and `OutdoorAmbient` at 0, `EnvironmentDiffuseScale` at 0, and no 0.004 dust floor in the sky. Near Terra: ambient and sun colour from `Atmos.ambient` and `Atmos.sunlight`, and the engine Atmosphere's tint and density from Atmos as well. The Lighting block of `planets/default.project.json` changes to match.

### 5. Finish

Add `planets/server` to the luau-lsp paths in `tools/build_planets.sh` and to `tools/check_planets_place.py`, keep the mock green, bring docs/PLANETS.md up to date with everything above, rebuild, commit, push.

## HAM and Atmos.luau

The HAM and K-RDAP papers the user shared, `01-AU-ARCHITECTURE`, `03-ARCHITECTURE-HAM`, `06-THE-FORMULA` and `12-PAPER-KRDAP-RUNTIME`, are not in this repository. Give them to the new chat again. Read against `planets/shared/Atmos.luau`:

Already the same idea:

- Phase factorization. The tables hold phase-free Rayleigh and Mie parts and the phase functions are applied at lookup. That is HAM's first step.
- Earth's shadow comes from geometry: `sunT` is 0 wherever the planet blocks the sun.
- Ozone is a layer, a tent profile, not an exponential.
- HAM's azimuth leak, the sun's local zenith changing along the ray, is kept exactly, because the tables are three-dimensional: rays that miss by `(d0, a, b)`, rays that hit the ground by `(mu_v, mu_s, tau)`. HAM's per-row polynomial in cos γ is the cheaper form for one observer's sky dome, which makes it the right tool for the sky seen from inside Terra's atmosphere. That sky is not built yet.

Where HAM says Atmos should change, most valuable first:

1. Multiple scattering. The `iso` term in `missParts`, `hitParts` and `skyRay` is a heuristic: `ms / 4π * (ρR + 0.4 ρM bM / bRb) * T_sun^0.45`, with 0.4 and 0.45 tuned by eye. HAM's own papers name this exact weak spot. The derived replacement is Hillaire's 2020 source table `Ψ_ms(h, μ_s)`: for each altitude and sun cosine, integrate second-order light over the sphere of directions, `Ψ = L2 / (1 - f_ms)`, with ground albedo where those directions hit the ground. Every ray then adds `σ_s(h) * T_view * Ψ_ms(h, μ_s)` as an additive source. That is HAM's additive S with its ambient derived instead of tuned, and it saturates correctly at high optical depth. Only table building gets slower; a pixel still costs the same lookups.
2. Rayleigh phase with depolarization: `3 / (16π (1 + 2γ)) * ((1 + 3γ) + (1 - γ) cos²θ)`, `γ = ρn / (2 - ρn)`, `ρn ≈ 0.0279`. Only `phaseR` changes.
3. Mie phase: Atmos uses Henyey-Greenstein, HAM uses Cornette-Shanks, `3/(8π) * (1 - g²)/(2 + g²) * (1 + cos²θ) / (1 + g² - 2g cosθ)^1.5`. Only `phaseM` changes.
4. Spectral tables: integrate 16 or more wavelengths against the CIE observer while building, instead of three RGB coefficients. That gives ozone's Chappuis band its real shape, which is what keeps a twilight zenith blue. Build time grows with the band count; pixel cost does not.
5. Validation against section 7 of `03-ARCHITECTURE-HAM`: horizon to zenith ratio 3 to 5 at clear noon, zenith chromaticity, the 400 to 700 nm ratios. The atmosphere tests today check structure, exact black and colour direction, not these numbers.

One limit those numbers expose is horizon airmass. A horizontal ray through an exponential atmosphere sees about `sqrt(π R / 2H)` times the vertical optical depth. Earth has R / H about 796 and airmass 35. Terra has R 1600 and hr 26, so R / H about 62 and airmass 9.8: its sunsets redden about 3.6 times less than Earth's under the same zenith sky. Earth's proportions on a 1600-stud planet would mean hr about 2 studs and hm about 0.3. That is right from orbit, where the atmosphere becomes a thin blue line, but Terra's mountains reach 90 studs, about 40 times Earth's proportion, and would stand in vacuum. Everything vertical on Terra is exaggerated together; hr 8 gives airmass 17.7 as a middle ground. This is a design decision, not a bug.

## Needs Studio to verify

- the UV origin of EditableMesh texture coordinates: the V key flips it
- the green channel convention of normal maps through CreateSurfaceAppearanceAsync: the N key flips it
- the real client EditableImage budget, reported at about 32 MB: the X key measures it
- frame rate, and how large one EditableMesh may be; the mesh pool halves its slots per mesh when refused
- the camera's far clip at planetary distances
- alpha of the cloud textures on MeshParts
- that content from CreateDataModelContentAsync replicates to clients, which the server cloud design assumes

## Older items never closed

Two entries from the earlier task list were still open: a design document with the axioms of the EditableImage research, and "tests, bench, doc section" for the ALLAN apps LiquidMatte, LiquidControl and LiquidTime. Some of the latter exists already in `tests/liquid_apps.test.luau`, `tests/liquid_time.test.luau` and docs/LIQUID.md, so check what is there before redoing it.
