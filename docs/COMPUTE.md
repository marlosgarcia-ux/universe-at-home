# COMPUTE: how pixels get computed (fast, flawless, deterministic)

What is the fastest, highest-quality, deterministic way to compute an image's pixels in Roblox Luau, what axioms govern it, and how does each technique combine with ALLAN (`docs/LIQUID.md`)? This document answers technique by technique. Each entry says what the technique is, which owner problem it serves (1024 and beyond, artifact-free LOD, deterministic textures, memory and representation, background removal, future-proofing), the axioms and theorems that govern it, its measured or predicted cost, how it combines with ALLAN, and a verdict: **adopt**, **adopt later**, **reject** or **needs probe**.

Labels: **[proved]** (proof given here), **[measured]** (number from `bench/compute.luau`, merged in `bench/results/compute-x64.md`, or asserted in `tests/compute.test.luau`), **[predicted]** (derived from measured op costs, not run), **[conjecture]** (believed, not proved), **[needs probe]** (only `studio/EditableImageProbe.luau` or a Roblox run can settle it).

Times are milliseconds per full 1024 x 1024 frame, interpreter at `--!optimize 2` (what clients run) / native `--codegen` (what servers can run), minimum of 3 runs of each on a 2.1 GHz Xeon shared with other agents (`bench/results/compute-x64.md`). The calibration kernel (constant `writeu32` over 1024 x 1024) ran at 8.78 / 2.21 ms in the reported session against 10.3 / 2.9 in `docs/RUNTIME_AUDIT.md` 6.6. Other agents were running (load average about 2), so individual kernels varied by up to 20 percent between sessions, and at busy moments the same code ran up to 4x slower; ratios between rows are more reliable than absolute values.

## 0. Headline findings

1. **The project's coverage axiom is wrong in a measurable way.** `MyMath.coverage(d, w) = clamp(0.5 - d/w, 0, 1)` errs by up to 10.94/255 on a straight 45 degree edge (closed form, C3), 11/255 on circles of any radius, 38/255 at sharp box corners and 26 to 57/255 at polygon corners, against the exact pixel area. Section 9 gives the correction; `src/MyMath.luau` is left unchanged for its owner to decide.
2. **Flawless anti-aliasing is cheap and deterministic.** `Raster` mode `MODE_EXACT` (half-plane area, a first-order curvature term, exact disc areas from a deterministic arcsine, exact wedge clipping at polygon corners) writes every tested primitive within 0.50/255 of the exact area, which is the 8-bit rounding floor itself (capsule caps 0.74/255), at about 1.2x the cost of the linear ramp interpreted, and stays pixel-identical between the quadtree renderer and brute force.
3. **For polygons and paths, exact is also fastest.** The scanline signed-area painter renders 256 stars exactly (0.50/255) in 39 ms interpreted, 10 to 12x faster than the SDF quadtree raster (397 ms linear, 485 ms exact).
4. **Supersampling is not a reference.** 4 x 4 supersampling errs up to 31/255 and 16 x 16 up to 4.4 to 6/255 against exact area. Exact area, computed analytically, defines "flawless" (section 1).
5. **The interpreter numbers in the previous notes were native numbers.** The "34 to 67 ms" quoted for 256 shapes at 1024 x 1024 came from the `--codegen` half of a two-run command. The interpreter takes 106 ms (linear) and 131 ms (exact), native 32 and 44 ms.
6. **Exactness through integers wins wherever it is available.** The exact Euclidean distance transform, running-sum blurs and an area-average resampler with integer weights reproduce their brute-force definitions bit for bit, and are as fast as or faster than the approximate alternatives (jump flooding is 24x slower than exact EDT on a CPU and still wrong on some pixels; 8SSEDT is 4.6x slower).
7. **Evaluation strategy matters 4.6x; culling matters 570x.** For a 45-node SDF expression, a per-pixel op-array interpreter costs 4.6x a build-time generated module, closures 2.4x, a column-at-a-time op array 1.7x. A quadtree with Lipschitz or interval classification cuts the same frame from 1 307 ms (closures at every pixel) to 72 to 74 ms, and the shape rasterizer from 60 s brute force to 106 ms.
8. **Every prototype is bit-identical between the interpreter and native code**: eight output hashes are asserted as constants in `tests/compute.test.luau` and pass in both runtimes.

## 1. What "flawless" means, operationally

A rendered pixel is a box-filtered sample: the mean of the continuous image over the pixel square. For one shape of colour `c` over a background `b`, that mean is `b + (c - b) * A`, where `A` is the **exact area** of the pixel square covered by the shape. Everything is measured against `A`, never against supersampling, because n x n point sampling has its own error of up to about `1/(2n)` per edge crossing (measured: 31/255 for 4 x 4, 4.4 to 6/255 for 16 x 16 on circles).

**Definition (F1, per shape).** A coverage method is *flawless* when, for every pixel, `|byte - 255 A| <= 0.5 + epsilon` with `epsilon = 0.01`: the byte it writes is the correctly rounded exact area (a tie may round either way). It is *visually flawless* when the bound is 1.0 (one least significant bit).

**Definition (F2, per scene).** For a scene composited with source-over, F1 applies to each shape's coverage. Compositing coverage as alpha is itself exact only when at most one edge crosses a pixel; where edges of different shapes cross the same pixel (shared or abutting edges) the composite differs from the exact box filter of the scene ("conflation", C11, measured at 64/255 in 3.2). Shapes that must abut without seams are merged into one exact-area path instead.

**Definition (F3, determinism).** The same inputs give the same bytes in the interpreter and in native code, on every device: only the operations of `docs/RUNTIME_AUDIT.md` 6.5 touch content. `tests/compute.test.luau` checks this by hashing every prototype's output and comparing against constants that both runtimes must reproduce.

**Exact references used** (all in `src/compute/Coverage.luau`): `circleArea` (closed form by splitting the x range where the clipping switches; uses `math.asin`, reference only), `discRectArea` (the same with a deterministic arcsine, usable for content), `polygonArea` (Sutherland-Hodgman clip to the pixel, then the shoelace formula), and compositions of these for rings (difference of discs), rounded boxes and capsules (polygons flattened to 400 to 600 vertices per arc). For images, `Filter.areaResample` is the exact box-filter reference at any scale (C9).

## 2. Spatial structures

### 2.1 Quadtree with Lipschitz or interval classification

**What.** Each 64 x 64 tile is split recursively. At each node every candidate shape is classified as *outside* (coverage exactly 0 at every pixel centre of the node), *inside* (exactly 1) or *crossing*. Outside shapes are dropped for the subtree; the topmost opaque inside shape becomes the node's base and hides everything below it; a node whose remaining shapes are all inside is one `buffer.copy` span fill; only leaves that an edge crosses are shaded per pixel. Classification uses either a **Lipschitz bound** (evaluate `d` at the node centre; `|grad d| <= L` bounds `d` at every pixel centre within `L * rho`, `rho = (size - 1) * sqrt(2)/2`) or **interval arithmetic** (evaluate the field over the node's box, 3.1). Code: `Raster.render` (shapes, Lipschitz), `Expr.renderQuad` (expressions, either).

**Owner problems.** 1024 and beyond (cost follows edges, not area), deterministic textures, background removal (the same classification finds the uniform regions of a mask).

**Theorems.**
- **C2 (identity) [proved, measured].** If classification is conservative (a dropped shape has coverage exactly 0 at every pixel centre of the node, an inside opaque shape exactly 1) and the per-pixel routine is the same function with the same operand order as brute force, the quadtree output equals brute force bit for bit. Proof: dropping a shape removes a compositing step whose result is the identity (coverage 0 changes nothing); an inside opaque shape sets the colour to exactly its own with alpha 1, which is what compositing coverage 1 at alpha 255 produces, and erases the dependence on everything below; uniform nodes copy a pixel computed by the same routine. Asserted in `tests/compute.test.luau` for both coverage modes and three scene sizes, including after `renderDirty`.
- The culling threshold is the coverage function's **reach** `R_cov`: the largest `|d|` at which coverage is strictly between 0 and 1. `R_cov = w/2` for the linear ramp but `w sqrt(2)/2` for half-plane and exact coverage (C4). Bounding boxes for binning must grow by the same `R_cov` (`Raster.updateBounds`).

**Measured.** 256 shapes (circles, rounded boxes, capsules, rings, stars; a quarter translucent), 1024 x 1024:

| Renderer | interp | native |
|---|---|---|
| brute force, linear (every shape at every pixel) | 60 430 | 15 907 |
| painter (bbox per shape, 8-bit read-modify-write, not identical) | 653 | 144 |
| quadtree, linear, leaf 4 / leaf 8 | **106** / 158 | **32** / 56 |
| quadtree, exact, leaf 4 / leaf 8 | **131** / 228 | **44** / 53 |

The quadtree is 570x faster than brute force interpreted (500x native) and 6x faster than the painter's algorithm, and unlike the painter it is exact. Leaf 4 beats leaf 8 interpreted: per-node classification is cheaper than per-pixel shading of multi-shape leaves. For the 45-node expression of 4.1, Lipschitz classification shades 57 216 pixels and interval classification 51 072 (11 percent fewer); both cost about the same (74 vs 72 ms interpreted, 47 vs 44 ms native; an earlier session measured 95 vs 72 and 37 vs 43).

**ALLAN.** The quadtree's leaf decomposition is ALLAN's input tree: uniform nodes are flat segments, edge leaves are its shells (LIQUID L7). For vector sources the classifier is an exact, sampling-free split rule, replacing "maximum channel deviation above theta" (LIQUID 5.1), and it hands ALLAN only the nodes that are not already constant. For raster sources, a summed-area table of values and of squares (3.5) gives each node's mean and variance in O(1), so the split test costs O(nodes) instead of O(pixels x depth) **[predicted]**.

**Verdict: adopt.** Lipschitz for exact SDF primitives (tighter per cost); interval classification for fields that are not distance functions (noise, height fields, scaled shapes) and wherever its 11 percent tighter culling pays.

### 2.2 Morton traversal

**What.** Z-order codes interleave the bits of x and y, so a depth-first quadtree walk visits tiles in Morton order and a sorted list of Morton codes plus depths is a pointerless ("linear") quadtree. `Tiles.morton` (bit32 part1by1), `Tiles.mortonLUT` (256-entry byte table), `Tiles.mortonOrder`, `Tiles.ringOrder` (Chebyshev rings around a focus tile, Morton order inside a ring).

**Owner problems.** Beyond 1024 (tile order and addressing of virtual canvases), memory (pointerless trees), artifact-free LOD (ring order is Saturn's refinement order).

**Axioms.** Morton order of the tile grid equals the depth-first order of the quadtree over it, so a tree serialised depth-first needs 1 bit per node (split or leaf) plus the leaf payloads. Pixel storage stays row-major: `WritePixelsBuffer` takes row-major RGBA8 and every span fill is a contiguous row run, so a Morton pixel layout would cost a full conversion pass per upload.

**Measured.** One million codes: bit32 version 188 / 19 ms, lookup table **65** / 22 ms. In the interpreter the table is 2.9x faster (four table reads replace about 18 bit32 calls); natively the bit32 version is slightly faster because its calls become inline instructions.

**ALLAN.** ALLAN's shell-byte tree (LIQUID L7) is stored depth-first, which is Morton order: split bits plus leaf bytes, versioned, in one buffer. Row segments are recovered per row band by walking the tree; rows of the same band cross the same leaves (LIQUID 3, "2D").

**Verdict: adopt** for tile order, tree serialisation and progressive refinement order (use the lookup table on clients). **Reject** Morton pixel layouts.

### 2.3 Per-tile shape binning

**What.** `Raster.bin` appends each shape to the list of every 64 x 64 tile its conservative bounding box touches; each tile's quadtree starts from its own list. **Measured:** 0.09 / 0.07 ms for 256 shapes, negligible.

**Owner problems.** 1024 and beyond (cost per tile follows local complexity), temporal coherence (bins tell which tiles a moved shape dirties).

**Axiom.** Binning is conservative exactly when the bounding box includes the coverage reach `R_cov` (2.1). With the exact coverage mode the box must grow by `0.7071 w`, not `0.5 w`; this was a latent bug for any exact-coverage use and is fixed in `Raster.updateBounds`.

**ALLAN.** Bins bound which ALLAN leaves and row bands an edit touches: re-train or re-render only those tiles (3.9).

**Verdict: adopt.**

### 2.4 Octrees where they fit

- **Colour quantisation to a palette (octree quantiser).** Insert each pixel into an 8-level RGB octree, merge the least populated nodes until K colours remain, store u8 indices and a palette. Integer-only, so deterministic. Cost **[predicted]** about 150 ns per pixel interpreted (8 levels of bit extraction and table walks), 150 to 200 ms per 1024 x 1024 frame, 30 to 50 ms native. EditableImages are RGBA8 only, so the saving applies to Luau-side storage (tile caches, virtual canvases, dehydrated images: 4x smaller), expanded at upload by `Pixels.expandIndexed` (21 ms interpreted per frame). **Adopt later**, server-side, for cold storage; content-addressed tiles (2.6) already remove exact duplicates for free.
- **Space-time (x, y, t) octree for animation.** A cell constant over a time interval is stored once. Content addressing (2.6) gives the same saving for exact repeats with no tree: a tile identical across frames interns to the same id. **Reject** as a separate structure; ALLAN's closed-form time extrapolation (LIQUID X1) is the better model for smooth change.
- **(x, y, level) for the mip pyramid.** A quadtree node is a mip texel; a node uniform at level k is uniform at every finer level, so a sparse pyramid stores it once. The 2.1 classifier already produces exactly this. For non-power-of-two levels use `Filter.areaResample` (3.5). **Adopt** as "the quadtree is the pyramid"; no extra structure.
- **Sparse voxel octrees for 3D textures or impostors.** Ray traversal per pixel costs about as much as sphere tracing (3.10: about 2 s interpreted per 1024 x 1024 frame). Roblox has no 3D texture sink. **Reject** at runtime on clients; **adopt later** on the server for baked impostors, where `Trace.luau` already covers the SDF case.

**ALLAN.** The (x, y, level) view is the one ALLAN shares: T5 makes every level an exact horizontal box filter, so ALLAN plus the quadtree is a sparse pyramid with no stored levels.

### 2.5 Shells

- **Narrow bands around edges.** The quadtree's edge leaves are a band of leaf width around every edge; the analytic span kernel (`Rows.circleSpans`) shades a band of `2 R_cov` (1.41 px) per crossing. **Measured:** disc R = 300, full frame 70.3 ms direct versus **1.97 ms** with spans (36x), bit-identical. **C12 [proved]:** with spans, work per row is O(edge crossings x band width) plus O(spans) memory fills, independent of the shape's area. **Adopt.**
- **Onion shells for outlines and glow.** `|d| - t` is an outline (`Expr.shell`, `Raster.ring`); a glow is `f(d)` on `0 < d < radius` (`Distance.glowAlpha`). Cost is perimeter x shell width. For raster art, the signed EDT (3.6) gives `d`. **Adopt.**
- **Shell texturing with stacked GPU layers** (fur, grass, depth, parallax). Layer k shows pixels whose height exceeds k/N; N `ImageLabel`s or `Decal`s stacked with offsets. Per-frame cost zero Luau; memory N layers (an atlas with `ImageRectOffset` keeps one image). **Adopt later / needs probe**: draw-order and overdraw cost of many stacked transparent layers on phones.
- **Distance shells as LOD rings (Saturn).** Resolution halves per Chebyshev ring around the focus; `Tiles.ringOrder` renders nearest first; the GPU crossfades rings for free (`ImageTransparency`). **Adopt.**

**ALLAN.** Shells are where ALLAN's leaves are small (fast gains) and the exact rasterizer works; outside the shells ALLAN converges and copy-fills (LIQUID T2). The liquid matte runs only in the shell around the matte edge (3.6).

### 2.6 Tile deduplication by content, copy-on-write tiles

**What.** `Tiles.Store` keys every tile by its own pixel bytes as a Luau string (`buffer.tostring`). `Tiles.Grid` is an array of tile ids with copy-on-write editing (`edit` clones a shared tile; `commit` re-interns edited tiles so equal content merges again).

**Owner problems.** Memory and representation, beyond 1024 (a virtual canvas costs memory per *unique* tile, held in Luau buffers outside the editable budget), deterministic textures (identical inputs give shareable tiles).

**Axiom C10 [proved from source].** Luau interns every string: `luaS_hash` hashes all bytes (12-byte ARX blocks, then a byte loop) and the intern table compares length and full content with `memcmp` on a hash match (`VM/src/lstring.cpp`). So two tiles get the same key if and only if their bytes are equal: dedup is exact, with no false positives, and the hashing and comparison run in C.

**Measured.** Interning a whole 1024 x 1024 image costs 3.7 / 2.9 ms (16 px tiles) or 2.1 / 1.8 ms (64 px tiles), nearly the same interpreted and native because the work is in C. The 64-shape exact scene dedups to 962 unique of 4096 16 px tiles (23.5 percent, 4.3x less memory) and 172 of 256 64 px tiles. Composing the frame back costs 1 to 2 ms. Copy-on-write round trips are asserted in the tests.

**ALLAN.** Cache ALLAN output tiles keyed by their *inputs* (model version, leaf bytes, start state, level), not their pixels: the key is tiny and a hit skips rendering entirely. LIQUID 3's "rows with identical segments and start states render once" is the same idea per row.

**Verdict: adopt.** Store only the key string for cold tiles (the string is the pixels; `buffer.fromstring` rehydrates) to halve memory.

## 3. Evaluation

### 3.1 Interval and affine arithmetic

**What.** `Expr.interval` evaluates an SDF expression (circles, boxes, min, max, polynomial smooth min, negation, rounding, onion shells) over a box. Each node's range is exact for that node: squares and absolute values have exact interval forms, the box SDF and `smin` are non-decreasing in each argument (`smin`'s partial derivatives are `h` and `1 - h`), and min/max/negation are monotone. The root range can still overestimate through the dependency problem (min of two ranges whose extremes occur at different points). **Affine arithmetic** tracks first-order correlations (`x - x = 0`), tightening polynomials with repeated variables at 3 to 5x the cost of intervals **[predicted]**.

**Measured.** Sound on 200 random boxes x 25 points (asserted). Quadtree culling: interval 51 072 shaded pixels versus Lipschitz 57 216; 72 / 44 ms versus 74 / 47 ms (2.1).

**Theorem.** For a 1-Lipschitz field, Lipschitz classification at a node centre is within a factor of the interval width of the true range; interval arithmetic is exact for single monotone primitives. `MyMath.fbm2` returns its own Lipschitz bound, so noise fields can use either method.

**ALLAN.** A liquid neuron's state stays inside `[min(h0, b), max(h0, b)]` over a segment (it relaxes monotonically toward `b`), so interval bounds on leaf inputs bound the state, and LIQUID T2's skip bound is a Lipschitz-type bound in time. Interval culling can prove whole tiles of ALLAN output constant before running the network **[conjecture]**.

**Verdict: adopt** intervals for non-distance fields and expression culling; **reject** affine arithmetic for now (no measured need).

### 3.2 Scanline analytic spans (exact-area accumulation)

**What.** `Scanline` deposits, for each polygon edge, the signed area between the edge and the right side of every cell it crosses; a running sum along each row then gives the exact box-filtered coverage (Levien's font-rs method). Between touched cells the sum is constant, so those spans are filled with `buffer.copy`. `Scanline.composite` blends a straight-alpha colour onto an RGBA8 destination: zero spans are skipped, full spans of an opaque colour are one span fill, and spans with a constant fractional sum (rows a horizontal edge or a vertex crosses) are blended with that constant coverage. Curves are flattened (`flattenEllipse`).

**Owner problems.** Flawless 1024 for vector art (fonts, icons, UI, decals), memory (vectors instead of pixels), beyond 1024 (cost follows perimeter).

**Theorems.**
- **Exactness [proved].** By Green's theorem the area of polygon-intersect-pixel is a sum over edges of signed trapezoid areas; the accumulator adds each edge's trapezoid area to the cells it crosses and the row prefix sum completes it. With the non-zero rule, coverage = `min(1, |sum|)`. Error: floating rounding only. **Measured** 0.50/255 for stars, squares, clipped triangles.
- **C11 (conflation) [proved, measured].** Two shapes that share an edge, each with exact coverage 1/2 on the edge pixels, composite to `1/2 + 1/2 (1 - 1/2) = 3/4` instead of 1: a 64/255 seam. The same happens in `Raster` (any per-shape coverage composited with source-over). Accumulating both into **one** accumulator gives winding sums that cancel on the shared edge: measured 0.50/255.
- Flattening tolerance `tau` bounds the area error per pixel by about `1.5 tau` (chord length in a pixel at most `sqrt(2)`); a circle of radius 90 needs 945 vertices at `tau = 0.0005` for 0.59/255 (previous notes). For circles the exact disc of 3.3 is cheaper.

**Measured.** 256 stars, 1024 x 1024: scanline painter **39 / 12 ms**, SDF quadtree raster 397 / 91 ms (linear) and 485 / 139 ms (exact). The scanline path is 10 to 12x faster interpreted *and* exact.

**ALLAN.** Both are event-driven row walkers. Scanline events are edge cells (exact); ALLAN events are leaf boundaries and convergence points (LIQUID T2). A combined row walker merges the two sorted event lists: between events, ALLAN's state jumps in closed form (T1) and coverage is constant, so a converged ALLAN output with coverage 0 or 1 is one span fill; at edge cells the pixel is ALLAN's paint composited with exact coverage. That is the classic vector split into *coverage x paint*, with ALLAN as the paint **[predicted]**: cost per row = ALLAN events + edge cells.

**Verdict: adopt** as the primary path for polygons, glyphs and paths. Merge shapes that abut into one accumulator (C11).

### 3.3 Exact area coverage versus distance approximations

**What.** Ways to turn a signed distance `d` (pixel units, negative inside) into pixel coverage, implemented in `Coverage.luau` and `Raster.luau`:

| Method | Formula | Deterministic | Cost |
|---|---|---|---|
| linear (`MyMath.coverage`) | `clamp(0.5 - d, 0, 1)` | yes | 1x |
| half-plane (`Coverage.halfPlane`) | exact area of the pixel inside the tangent line, from `d` and the gradient `n`: a trapezoid density of width `|nx| + |ny|` | yes | about 1.1x |
| curvature-corrected half-plane (`Raster.covCurved`) | half-plane minus `k (t1^3 - t0^3) / 6` over the chord `[t0, t1]` the tangent line cuts from the pixel, `k` the boundary curvature | yes | about 1.2x |
| exact pieces | `discRectArea` (circles under 8 px radius, rounded box corners), product of 1D overlaps (sharp boxes), wedge clipping at polygon vertices (`Coverage.corner`), two-edge clipping where non-adjacent edges share a pixel (`Coverage.edgePair`) | yes (deterministic arcsine `Coverage.dasin`, within 6.5e-14 of libm) | only on the few pixels that need it |
| supersampling n x n | fraction of inside sample points | yes | n^2 evaluations |

`Raster` `MODE_EXACT` combines the curvature-corrected half-plane with the exact pieces.

**Measured error against exact area** (max over all pixels the edge touches, 1/255 units; single white shape on transparent black, so the alpha byte is the coverage):

| Shape | linear | half-plane | curvature-corrected | `MODE_EXACT` (final bytes) | 4x4 SS | 16x16 SS |
|---|---|---|---|---|---|---|
| circle R = 2.5 | 13.7 to 15.3 | 10.3 | 1.45 to 1.56 | **0.32** | 24.4 | 2.5 |
| circle R = 8 | 12.2 | 2.8 to 3.6 | 0.18 to 0.29 | **0.49** | 27.7 | 2.4 |
| circle R = 20 to 40 | 10.6 to 11.1 | 0.72 | 0.008 | **0.50** | 30.0 | 4.9 |
| circle R = 300 | 11.0 | 0.10 | 0.000 | **0.50** | 31.4 | 6.0 |
| ring r = 30, t = 3 | 11.4 | - | - | **0.50** | - | - |
| sharp box | 37.8 (corners) | - | - | **0.50** | - | - |
| rounded box, corner radius 0.5 / 2 / 8 | 19.1 / 15.7 / 10.4 | - | 14.4 / 3.2 / 1.2 | **0.50 / 0.50 / 0.50** | - | - |
| capsule r = 5 | 12.7 | - | 0.74 | **0.74** | - | - |
| star r = 6 / 20 / 60 (sharp corners) | 56.4 / 45.0 / 25.7 | 57 / 45 / 27 | - | **0.49 / 0.50 / 0.50** | - | - |
| straight edge at 45 degrees | 10.94 (closed form, C3) | 0 | 0 | 0 | - | - |

"`MODE_EXACT` (final bytes)" includes the 8-bit rounding, so 0.50 is the floor: those bytes are the correctly rounded exact areas. The other columns are the estimator's own error. Ranges are over sub-pixel placements.

**Theorems.**

- **C3 (linear ramp error on a straight edge) [proved].** For a straight edge with unit normal `(a, b)`, `a >= b >= 0`, the exact coverage is the trapezoid integral `H(d)`; the linear ramp is `clamp(1/2 - d)`. At 45 degrees (`a = b = sqrt(2)/2`) and `d = 1/2` the ramp gives 0 while `H = (sqrt(2)/2 - 1/2)^2 = 0.04289`, i.e. 10.94/255. On `u = sqrt(2)/2 - d` in `[sqrt(2)/2 - 1/2, sqrt(2)/2]`, `H = u^2` and the ramp is `u - (sqrt(2)/2 - 1/2)`, so the error `u^2 - u + 0.2071` reaches the same magnitude 0.0429 again at `u = 1/2`; by symmetry the maximum over `d` is 0.04289. The ramp is exact only for axis-aligned edges. Asserted in the tests.
- **C4 (half-plane coverage is exact for straight edges) [proved].** The pixel's projection on `n` has a trapezoid density with ramps of width `b` and a plateau of width `a - b`; integrating it gives the four-piece formula in `Coverage.halfPlane` (asserted equal to clipped polygon area to 1e-9). It is exactly 0 for `d >= (a + b)/2` and exactly 1 for `d <= -(a + b)/2`, and `(a + b)/2 <= sqrt(2)/2`, so culling and bounding boxes must use the reach `sqrt(2)/2` instead of `1/2`.
- **C5 (curvature bound) [proved to first order, measured beyond].** A boundary of curvature `k` tangent to the half-plane line lies `k t^2 / 2 + O(k^3 t^4)` inside it at tangential offset `t`. Every point of the pixel is within `sqrt(1/2 - d^2) <= sqrt(2)/2` of the foot point, so the half-plane overestimates the area by at most `integral over |t| <= sqrt(2)/2 of k t^2 / 2 dt = k (sqrt(2)/2)^3 / 3 = 0.1179 k`, i.e. **30/R in 1/255 units** for a circle of radius R (measured 29 to 30/R for R from 40 to 300). Subtracting the exact first-order term over the actual chord leaves an `O(k^2)` error: measured worst case over sub-pixel offsets 3.8/255 at R = 1.5, 1.56 at R = 2.5, 0.80 at R = 4, 0.29 at R = 8, 0.18 at R = 16. Hence curvature-corrected coverage is visually flawless for curvature radius >= 4 px and flawless for >= 8 px; below 8 px `MODE_EXACT` uses the exact disc area instead.
- **C6 (corners need two lines) [proved].** At a polygon vertex the boundary inside the pixel is two segments, not a line, so no single `(d, n)` coverage function can be exact there (the linear ramp errs by 26 to 57/255 at star tips, the half-plane just as much). The exact area is the square clipped by both edges' half-planes (convex vertex: intersection; reflex: union by inclusion-exclusion), `Coverage.corner`, allocation-free. Where two non-adjacent edges share a pixel, the polygon is locally their intersection (inner sides facing each other: a sliver) or their union (facing away: a gap), `Coverage.edgePair`. The renderer tracks the two nearest edges per pixel to choose. Exact whenever at most two edges enter the pixel.

**Owner problems.** Flawless 1024 (no edge error above rounding), deterministic textures (every op is in the deterministic set, including the arcsine), artifact-free LOD (`Raster.scaled` renders any mip level directly with exact area at that level, so levels agree with the exact box filter of the vector source).

**Cost [measured].** 256-shape scene: exact 131 / 44 ms against linear 106 / 32 ms (1.2x interpreted, 1.4x native); 256 stars: 485 versus 397 ms (1.2x).

**ALLAN.** Exact coverage is ALLAN's quality reference: training targets for vector-sourced content are `MODE_EXACT` or scanline renders, never supersampled ones, and ALLAN's reported maximum error (LIQUID 5.4) is measured against them. ALLAN's own edges are its weak point (an exponential relaxation cannot represent an arbitrary sub-pixel step per row), so edges go to this path and ALLAN paints interiors (section 5).

**Verdict: adopt `MODE_EXACT`** as the default for SDF shapes; keep the linear ramp only for previews; use the scanline path (3.2) for polygons.

### 3.4 Forward differencing

**What.** Replace polynomial evaluation along a row by repeated addition: `e(x + 1) = e(x) + (2 dx + 1)` for `e = dx^2 + dy^2`. `Rows.circleFD`.

**Theorem C7 (dyadic exactness) [proved, measured].** If the centre lies on a `2^-k` grid and every value stays below `2^(53 - 2k)` in magnitude, `dx` is a multiple of `2^-k`, `e` a multiple of `2^-2k`, and every addition is exact, so forward-differenced values are bit-identical to direct evaluation. Asserted for four circles including off-canvas centres.

**Measured.** Disc R = 300: direct 70.3 / 25.4 ms, forward-differenced 67.3 / 25.2 ms, analytic spans **1.97 / 1.12 ms**. In Luau the multiplications forward differencing removes cost about as much as the additions that replace them; the loop, the square root, the coverage function and the write dominate.

**ALLAN.** ALLAN's dyadic step `h += (b - h) g` is forward differencing of a geometric sequence; C7's lesson carries over: incremental evaluation is only bit-stable when every operand is dyadic and bounded, which is why LIQUID T1 fixes one evaluation schedule.

**Verdict: reject** as a speed technique in Luau; **keep C7** as the rule that makes incremental evaluation deterministic. Spans (2.5) are the optimisation that matters.

### 3.5 Separable and running-sum filters, summed-area tables

**What.** `Filter.boxBlur`: separable box blur by running sums, two channels per number in 16-bit lanes (SWAR), any radius up to 127, rounding by integer floor division. `Filter.satBuild`/`satResample`: summed-area table (one u32 plane per channel) and resampling to any size through it. `Filter.areaResample`: exact area-average resampling with integer weights, separable. `Filter.normalMap`: height field to normal map.

**Owner problems.** Artifact-free LOD (exact prefiltered levels at any ratio, not just halves), glow and blur effects, deterministic textures.

**Theorems.**
- **Running sums are exact [proved, measured].** Sums of bytes stay below 2^16 per lane for radius up to 127 and below 2^53 overall, so the result equals the brute-force mean with the same rounding, independent of radius. `(sum + r) // (2r + 1)` is round-to-nearest because `2r + 1` is odd and ties cannot occur.
- **SAT bilinear = exact area integral [proved].** For a piecewise-constant image, the integral over `[0, X] x [0, Y]` with fractional corners is the bilinear interpolation of the summed-area table: the four interpolation terms are the full block, the partial column, the partial row and the partial pixel.
- **C9 (integer-weight area resampling) [proved, measured].** Output cell `i` covers `[i w, (i + 1) w)` in units of `1/dw` source pixels, so every overlap weight is an integer; sums stay below `255 w h < 2^53`; the output `(2 S + w h) // (2 w h)` is the exact rational mean rounded half up. It is one fixed answer on every platform and in any correct implementation, it equals `Pixels.downsample2x` at 2x bit for bit, and it matches a brute-force rational computation at 47 x 35, 61 x 13 and 9 x 7 (asserted). The float SAT path differs on a few pixels only where the exact mean is a tie, which floating summation order breaks either way.

**Measured.**

| Filter | interp | native |
|---|---|---|
| box blur r = 8 / r = 100 | 199 / 204 | 36 / 35 |
| summed-area table build | 92 | 21 |
| SAT resample 1024 -> 737 | 784 | 228 |
| area resample 1024 -> 737 / -> 512 | **192** / 107 | **40** / 24 |
| SWAR 2 x 2 mip 1024 -> 512 (reference point) | 25 | 2.3 |
| height field -> normal map | 98 | 13.5 |

A Gaussian is three box passes (about 600 ms interpreted, 110 ms native per frame).

**ALLAN.** C9 gives ALLAN its LOD training targets: level `L` of a texture is `areaResample` of the source, exact and deterministic, so LIQUID T5's claim "each level is an exact horizontal box filter" can be checked against an exact reference. The SAT is the image-side counterpart of T5's closed-form integral: any footprint in O(1).

**Verdict: adopt** `areaResample` as the reference LOD generator (server native, then bake; on clients only for small images or time-sliced), running-sum blurs for glow and soft shadows (server, or client on regions), normal maps from heights. SAT for variable footprints only.

### 3.6 Distance transforms

**What.** `Distance.edt`: Felzenszwalb-Huttenlocher squared Euclidean distance transform (columns by two sweeps, rows by the lower envelope of parabolas). `Distance.jfa`: jump flooding. `Distance.ssedt8`: 8-point sequential signed EDT. `Distance.signed`: signed distance to the boundary between mask pixel centres. `Distance.applyMatte`, `shellAlpha`, `glowAlpha`: soft mattes, outlines, glows.

**Owner problems.** Background removal (a hard chroma-key or flood-fill mask becomes a soft, distance-feathered matte), outlines and glows for any raster art, SDF generation from bitmaps (logos to resolution-independent shapes), memory.

**Theorem C8 (EDT exactness) [proved, measured].** All inputs are integers below 2^53. The only non-integer quantity is the parabola intersection `s = num / den` with integer `num`, `den`, `|den| <= 2W`. Two distinct such rationals differ by at least `1/(4 W^2)`, far above the rounding error of `s` (relative 2^-53 on values below `W^2`) for `W <= 8192`, so every comparison of intersections and of integer query points is decided correctly; exact ties pick either parabola, which give the same integer value there. Hence the output is the exact integer squared distance. Asserted equal to brute force on three masks.

**Measured.**

| Transform | interp | native | Error |
|---|---|---|---|
| exact EDT | **173** | **44** | 0 (exact) |
| 8SSEDT | 804 | 126 | 0 wrong pixels on these masks (known to fail on rare configurations) |
| jump flooding (512^2 x 4) | 4 127 | 732 | 7 of 65 536 pixels wrong, up to 2.16 px |
| matte: signed EDT (2 transforms) + 2 px feather | 424 | 102 | - |

Jump flooding is a GPU algorithm (log2 n passes of 9 probes, massively parallel); on one CPU core it is 24x slower than the exact transform. 8SSEDT pays a non-builtin call per neighbour test in this prototype; even inlined it would remain approximate.

**ALLAN.** The distance transform feeds the liquid matte (LIQUID 8): (1) the band `|d| < feather + support` is the only place the four-direction recursive bilateral pass must run, so its cost becomes perimeter x band instead of all pixels; (2) the signed distance quantised to a byte is a leaf input that lets the readout produce edge-aware alpha; (3) the distance sets the liquid gain (fast near the edge, slow far from it). The quadtree classification of the mask (2.1) finds the band without a full-frame EDT when only a narrow band is needed **[predicted]**.

**Verdict: adopt** the exact EDT (server native for full frames: 44 ms; clients for regions or time-sliced). **Reject** jump flooding and 8SSEDT on the CPU.

### 3.7 Low-resolution SDF magnification and multi-channel SDF

**What.** Store a distance field at low resolution and magnify it bilinearly at display time, then convert distance to coverage (Green 2007). Multi-channel SDFs (Chlumsky 2015) keep sharp corners with three edge-coloured channels and a median.

**Theorem C14 (magnification bound) [proved, measured].** Bilinear interpolation of a C^2 function with texel size `h` errs by at most `h^2 / 8 * max |f''|`. A circle's distance has `|f''| <= 1/R` near the edge, so the distance error is `h^2 / (8 R)` px, and coverage error is that times 255 per px of distance. **Measured** (bench quality rows, 1024 output): R = 300 with 16 / 8 / 4 / 2 px texels: 0.1065 / 0.0264 / 0.0063 / 0.0013 px (27 / 6.7 / 1.6 / 0.3 out of 255; the bound predicts 0.107 / 0.027 / 0.0067 / 0.0017). R = 40 with 16 px texels (development run): 200/255. Sharp corners are worse because the distance is not C^1 there: 78/255 at 4 px texels and 33/255 at 2 px.

**Owner problems.** Memory (a 64 x 64 field instead of a 1024 x 1024 mask), resolution independence. Not flawless: F1 at 0.5/255 needs `h <= sqrt(8 R 0.002)`, about 2 px for R = 300 and under 1 px for R = 40, which removes the memory advantage.

**Roblox mapping.** `DrawImageTransformed` resamples bilinearly in native code, so the engine could magnify the field and Luau would only apply a 256-entry distance-to-alpha table per pixel (about 15 to 20 ms per 1024 x 1024 frame interpreted **[predicted]** from the calibration kernel plus one read and one table lookup) **[needs probe]**: bilinear exactness, edge handling, and channel independence when the field sits in RGB with alpha 255.

**ALLAN.** A distance byte per leaf is a better ALLAN input than a magnified field: ALLAN can learn the curvature correction the bilinear field lacks **[conjecture]**.

**Verdict: adopt later** for UI and text at "visually good" quality with MSDF (corners), once the probe confirms `DrawImageTransformed` behaviour; **reject** as a flawless technique. Store vector shapes, not distance textures, when flawless matters.

### 3.8 Progressive any-time refinement

**What.** Render the tiles nearest the focus first (`Tiles.ringOrder`), finish a tile completely before the next (exact on finished tiles), optionally show a quarter-resolution render (`Raster.scaled(sc, 0.25)`, 16x fewer pixels) stretched by the GPU while the full one completes. `Raster.renderUntil` renders tiles in a given order until a deadline.

**Measured.** The first 8 ms slice (the central tiles, which hold the most shapes) finishes 9 (linear) or 6 (exact) of the 256 tiles of 64 x 64 interpreted, 26 to 46 natively. At the average tile cost (106 to 131 ms per frame) a full frame needs 13 to 16 slices of 8 ms; centre-heavy scenes need more.

**Axiom.** Any-time means the error is non-increasing in work done; with exact per-tile rendering, a partial frame is exact on its finished tiles and the previous frame elsewhere.

**ALLAN.** LIQUID X2 (Richardson LOD) is ALLAN's progressive mode: coarse levels are instant, the refinement is ordered by the discrepancy estimate. Ring order decides *where* to refine, X2's error estimate *which level*.

**Verdict: adopt.**

### 3.9 Temporal coherence and dirty propagation

**What.** When shapes move, re-render only the tiles touched by their old and new bounds (`Raster.renderDirty`); upload only changed rectangles (`Canvas.planFlush`).

**Measured.** Moving one shape: 1.7 / 0.49 ms (linear), 2.2 / 0.60 ms (exact), against 106 / 32 ms for the full frame (63x less work interpreted). The result is asserted identical to a full re-render: tiles are independent and bins are rebuilt (C2).

**ALLAN.** Re-render only rows that cross leaves whose inputs or state changed by more than epsilon (LIQUID 8, water); dirty tiles bound which ALLAN row bands rerun.

**Verdict: adopt.** Edits fit a 16 ms client frame; full re-renders do not.

### 3.10 Sphere tracing 3D SDFs, height field to normal map

**What.** `Trace.render`: orthographic sphere tracing of a 3D SDF (sphere, torus and rounded slab with smooth unions) into a tangent-space normal map (tetrahedral 4-tap gradient) and a height map, skipping pixels outside the projected bounding sphere with span fills. `Filter.normalMap`: height to normals by central differences.

**Measured.** 256 x 256: 7.3 steps per ray; 1 580 / 593 ms per 1024 x 1024 frame (measured at 256 x 256 and scaled by 16; a direct 1024 run took 2.0 s / 0.64 s in a development session). Height to normal map: 98 / 13.5 ms. Output hashes are identical in both runtimes.

**Owner problems.** Deterministic textures (bevels, embossed UI, relief, impostors from a few numbers), memory (the SDF is bytes), PBR maps.

**ALLAN.** Sphere-traced renders are training data for ALLAN impostors and PBR outputs (normal X/Y channels, LIQUID 8); deriving normals from an ALLAN height output keeps normals consistent with the height.

**Verdict: adopt** for server-side generation and baking (`CreateDataModelContentAsync`); on clients only at 128 x 128 or below, or time-sliced. Height-to-normal: adopt on clients up to 512 x 512 (about 25 ms).

## 4. Coding techniques in Luau

### 4.1 Closures, a flat op-buffer interpreter, or generated source

**What.** One 45-node SDF expression (`Expr.demo(16, 1024, 11)`) evaluated by: a closure tree (`Expr.closure`); a flat op array run by a register machine per pixel (`Expr.run`); the same op array run column-at-a-time over a row, one dispatch per node per row (`Expr.runRow`); generated Luau source loaded with `loadstring` (`Expr.source`, `Expr.sourceRow`); and the same row kernel generated at build time and shipped as a module (`tools/gen_expr.luau` writes `bench/generated/ExprDemoRow.luau`). All return bit-identical values (asserted).

**`loadstring` facts (sourced).** `loadstring` is disabled by default; `ServerScriptService.LoadStringEnabled` (default false, NotScriptable) enables it for server scripts only (`scripting/capabilities.md`: "it is still only available on the server"); the reference warns it "disables certain Luau optimizations on the returned function" (`LuaGlobals.yaml`). In the Luau VM those optimisations are the `safeenv` fast paths: `GETIMPORT` resolution and every `FASTCALL` builtin check `cl->env->safeenv` (`VM/src/lvmexecute.cpp`). The Luau CLI's own `loadstring` clears `safeenv` only on the original globals, so its chunks keep the fast paths; the benchmark emulates Roblox by giving the chunk its own environment through `setfenv`, which clears `safeenv` on that environment only. The CLI native-compiles the main script and required modules but never `loadstring` chunks (`CLI/src/Repl.cpp`, `ReplRequirer.cpp`); whether Roblox can native-compile them is NOT PUBLICLY SPECIFIED.

**Measured** (ms per full 1024 x 1024 evaluation, no culling; sampled on 128 rows and scaled):

| Strategy | interp | native | interp vs generated |
|---|---|---|---|
| op array, per pixel | 2 485 | 600 | 4.6x |
| closure tree, per pixel | 1 307 | 605 | 2.4x |
| op array, column at a time per row | 904 | 282 | 1.7x |
| build-time generated module, row kernel | **541** | **172** | 1x |
| `loadstring` row kernel / per pixel (safe environment) | 573 / 720 | 535 / 537 (not native-compiled) | 1.1 to 1.3x |
| `loadstring` row kernel, unsafe environment (Roblox-like) | 830 | 1 022 | 1.5x |

**Axiom C12b (dispatch amortisation) [measured].** Interpretive overhead must be paid per node per *row*, not per node per pixel: the column-at-a-time interpreter recovers 2.7x of the per-pixel interpreter's 4.6x penalty while staying fully dynamic.

**ALLAN.** ALLAN's runtime is an interpreter with a fixed program (the model) and data (weights, tree). Two consequences: run it column-at-a-time (neurons as registers across a row's events), and generate a specialised kernel per `(N, M)` shape at build time (unrolled neuron loops, constants inline) for about 1.3 to 2x **[predicted]**. Model weights stay data, so federated updates (LIQUID S4) never require new code.

**Verdict.** **Adopt** build-time generated modules for fixed generators (works on clients, native on servers, no `loadstring`); **adopt** column-at-a-time op arrays for content defined at runtime (player-made shapes); **reject** per-pixel interpreters and closure trees in pixel loops; **reject** `loadstring` (clients cannot use it; on servers it is a security switch and measured 1.5x slower than generated code under the documented de-optimisation).

### 4.2 Batch row kernels

**What.** Hoist everything that is constant along a row (the row's `dy^2`, shape parameters, dispatch decisions) out of the pixel loop; solve span boundaries analytically; fill constant spans with `buffer.copy`.

**Measured.** Analytic spans 36x (disc), column-at-a-time dispatch 2.7x (expression), forward differencing about 1x (3.4). In `Raster`, shading is pixel-major with a per-shape kind dispatch inside each pixel; a shape-major leaf kernel (per leaf, per shape, loop over pixels, accumulate in a small float buffer) would hoist the dispatch and parameter reads, **[predicted]** 1.5 to 2x on edge leaves.

**ALLAN.** ALLAN is a batch row kernel by design (one row = one time series).

**Verdict: adopt** (the rule: dispatch per row, arithmetic per pixel, memory ops per span).

### 4.3 Data layouts

- **AoS versus SoA.** Scenes are SoA (`p1..p6`, `cr..ca` arrays) so a kernel hoists `local P1 = sc.p1` once; table reads cost 2.5 ns each interpreted (RUNTIME_AUDIT 6.6). **Adopt SoA.**
- **Row-major versus Morton.** Row-major for pixels (2.2). **Adopt row-major.**
- **Fixed point versus float.** Every Luau number is a double, so "fixed point" means integers in doubles. Integers below 2^53 are exact and their sums associative, so results do not depend on evaluation order: required for Actor partial sums (4.6) and ALLAN's federated statistics (LIQUID S3). The integer area resampler is both exact and faster than its float version (191 versus 257 ms interpreted, same development session). f32 buffers halve memory for fields (signed distances) but round. **Adopt integers for anything accumulated; f32 only for stored fields.**
- **Lookup tables.** Morton bytes (2.9x faster interpreted), gamma (`MyMath.SRGB_TO_LINEAR16`), distance-to-alpha. **Adopt** on clients.
- **SWAR.** Two 8-bit channels per number in 16-bit lanes: running-sum blur, `Pixels.downsample2x`. **Adopt** where it removes builtin calls (RUNTIME_AUDIT 6.7.6).

**C15 (integer division and fast-math) [proved under the stated model].** RUNTIME_AUDIT 6.5 flags `//` and `%` on fractional values as non-deterministic on MSVC builds because `luai_numidiv` and `luai_nummod` sit in a fast-math region. If fast-math is modelled as reciprocal multiplication and contraction: division by a power of two (`x // 1`, `x // 256`, `x % 65536`) has an exact reciprocal, and integer floor division `a // b` with `0 <= a < 2^51`, `b >= 1` cannot cross an integer boundary under two roundings (the quotient's distance to the next integer is at least `1/b`, the error is below `2^-51 a / b`). So the project's rounding idiom `(x + 0.5) // 1` and every integer division used here are deterministic even in fast-math builds. **[needs probe]** to confirm on a Windows client by comparing test hashes. Note that `src/Liquid.luau` adopts the stricter convention "floor of fractional values uses `math.floor`, never `//`", while `MyMath`, `Pixels` and these prototypes use `(x + 0.5) // 1`; the project should pick one. If the Windows hash check passes, C15 makes both safe; if not, switching to `math.floor` costs about 1.6 ns more per rounding interpreted (3.7 versus 2.1 ns, RUNTIME_AUDIT 6.6), roughly 5 percent of a shading kernel.

### 4.4 EditableImage combine ops as a C++ image-algebra coprocessor

**What.** `DrawImage`, `DrawImageTransformed`, `DrawRectangle`, `DrawCircle` with `BlendSourceOver`, `Overwrite`, `Add`, `Multiply`, `AlphaBlend`, `NormalMapBlend`, `Subtract` run in native engine code: an image-algebra coprocessor at memory speed. Their exact arithmetic is not published (RUNTIME_AUDIT 5).

**Design for both outcomes.**
- *If the probe shows exact, documented-looking formulas* (for example `Multiply = round(dst * src / 255)` per channel, `Add` clamped, source-over on straight alpha with round-to-nearest): composite layers in the engine. Luau renders each layer once (a mask from `Scanline`, a paint from ALLAN), the engine multiplies mask by paint and composites, Luau never touches the composite. Deterministic content may then use these ops, provided the probe also shows client and server agree bit for bit.
- *If they are inexact, inconsistent across devices or carry the reported bugs* (`Add` ignoring source alpha, source blend not blending colour): use them for display only (things that are re-created every frame and never hashed or shared), keep deterministic compositing in Luau (`Scanline.composite`, `Pixels.blendOver`).
- `DrawImageTransformed` as the bilinear magnifier for distance fields (3.7) and as a fast resampler, once its filter is known.

**ALLAN.** Paint x mask through `Multiply` is the zero-Luau composite of section 5's split, if exact.

**Verdict: needs probe.** See section 10 for the list.

### 4.5 GPU display-time computation

**What.** Per-pixel work the GPU does for free (BRIEF fact 6): `ImageTransparency` and `GroupTransparency` crossfades, `ImageColor3` tints, `ImageRectOffset/Size` atlas windows (flipbooks), `ScaleType` Tile and Slice, `Decal` `UVOffset/UVScale/Rotation` (scrolling water and clouds), `ZIndex` stacking (shell layers).

**Rule.** Anything per frame that is a linear blend, a uniform tint or an affine UV map goes to the GPU; Luau computes only new content. A CPU crossfade costs 120 ms per frame (RUNTIME_AUDIT 6.7.7); the GPU's costs nothing.

**ALLAN.** ALLAN renders keyframes (or LOD levels) and the GPU blends between them: ALLAN at a few frames per second, display at 60 (temporal interpolation for free); Saturn's ring transitions likewise.

**Verdict: adopt.**

### 4.6 Actors in the parallel phase

**Facts (sourced).** Buffers passed through Roblox APIs, including messages, arrive as copies, and "the same buffer object cannot be used from multiple Actor scripts" (`libraries/buffer.yaml`); `Actor:SendMessage` arguments are "passed by copy across Luau VM boundaries" (`Actor.yaml`); `SharedTable` values are booleans, numbers, vectors, strings, SharedTables or serialisable types (`SharedTable.yaml`). `ReadPixelsBuffer` is Safe (callable desynchronised); `WritePixelsBuffer` is Unsafe (serial phase only) (RUNTIME_AUDIT 2).

**Design.** Split the frame into row bands of tiles, one per Actor; each renders into its own buffer while desynchronised, then the bands come back by message (a copy at memory speed, about 1 ms per 4 MB **[predicted]**) and are written in the serial phase. Tiles are independent (C2), so the output is identical for any number of Actors; any reduction (statistics, histograms) uses integer sums (4.3) so its result does not depend on merge order.

**Cost [predicted].** Up to 3 to 4x on a 4-core client for compute-bound passes, minus copies and scheduling overhead, which `studio/ParallelProbe.client.luau` measures.

**ALLAN.** Rows are independent given their start states: row bands per Actor; LIQUID S3's integer statistics merge exactly across Actors as across servers.

**Verdict: adopt later / needs probe** (message copy cost and real speedup on phones).

### 4.7 Time slicing

**What.** Render tiles in ring order until a per-frame budget expires (`Raster.renderUntil`), resume next frame. **Measured:** 6 to 9 of the heaviest (central) 64 x 64 tiles per 8 ms slice interpreted for the 256-shape scene; a full 1024 x 1024 render spans roughly 15 to 40 frames depending on where the shapes are, while a one-shape edit fits one frame (3.9).

**ALLAN.** Rows are ALLAN's natural slice unit; LIQUID X5's predictive controller sets epsilon and level per slice.

**Verdict: adopt** (budget about 4 to 8 ms of Luau per client frame).

### 4.8 Server native codegen plus baking

**What.** Generate heavy content on the server with `--!native` (measured speedups over the interpreter here: rasterizer 3.0 to 3.3x, EDT 4.0x, blur 5.5x, area resample 4.8x, normal map 7.3x, generated kernels 3.1x, sphere tracing 2.7x), then bake with `AssetService:CreateDataModelContentAsync`: replicated, real mips, outside the editable budget (RUNTIME_AUDIT 3).

**Caveat [needs probe].** Baked content is "transcoded into mips for client delivery". If transcoding uses lossy GPU compression, baked pixels are not the bytes the server computed, so F1 and F3 hold for the server's buffer but not necessarily for what the client samples. The probe must compare a baked image read back against its source.

**ALLAN.** Training (LIQUID S2) and heavy pre-renders run here; clients receive model bytes or baked content.

**Verdict: adopt** for full-frame generation of static content; clients keep incremental and dynamic work.

## 5. Combining with ALLAN

ALLAN is a learned, event-driven row renderer: strong on smooth and organic interiors, compact as data, extrapolating in time and LOD; weak where content needs exact sub-pixel edges (an exponential relaxation per row cannot reproduce an arbitrary sub-pixel step, and each row of a slanted edge is a different step) **[conjecture until ALLAN's quality numbers exist]**. The techniques above complement it as follows:

| Technique | Role in an ALLAN pipeline |
|---|---|
| Quadtree classification (2.1) | Builds ALLAN's input tree: exact split rule for vector sources, O(1) variance per node via SAT for raster sources; only non-constant nodes reach the network |
| Morton order (2.2) | Serialisation of the shell-byte tree (depth-first = Morton), tile order for progressive ALLAN renders |
| Binning, dirty tiles (2.3, 3.9) | Which ALLAN row bands rerun after an edit |
| Scanline spans (3.2) | Coverage events merged with ALLAN events in one row walker: coverage x paint |
| Exact coverage (3.3) | ALLAN's quality reference and training target; the crisp-edge path |
| Interval bounds (3.1) | Prove tiles of ALLAN output constant; T2-style skips |
| Area resample, SAT (3.5) | Exact targets for T5 integral LOD at every level |
| Distance transforms (3.6) | Band, gain and input feature for the liquid matte |
| Content-addressed tiles (2.6) | Cache ALLAN outputs keyed by inputs |
| Generated kernels, column-at-a-time (4.1) | How the ALLAN kernel itself should be compiled and run |
| GPU crossfades (4.5) | ALLAN keyframes blended at display rate |
| Actors, time slicing, server bake (4.6 to 4.8) | Where ALLAN rows run |

**Entry points in the ALLAN code that landed during this study** (`src/Liquid.luau`, `src/LiquidLearn.luau`; not modified here): the tree is stored in preorder with one split bit per node and leaf bytes in the same order (the Morton serialisation of 2.2); `LiquidLearn.buildTree(pixels, width, height, stride, C, theta, minLeaf)` is where the exact classifier (vector sources) or SAT-based O(1) node statistics (raster sources) would supply the split decision; `Liquid.rowSegments(plan, tree, y)` returns a row's segments, the list to merge with `Scanline`'s touched cell ranges in the combined row walker; `Liquid.renderRowValues` produces a row of paint values for the coverage x paint composite; `Liquid.reference` is the step-by-step model against which exact-area targets apply.

**The split.** A texture is `paint x coverage`. Coverage comes from exact geometry (scanline accumulator for paths, `MODE_EXACT` for curved primitives, the signed EDT for raster mattes); paint comes from ALLAN (organic texture, gradients, PBR channels) or from flat colours (span fills). Where coverage is 0 or 1 and ALLAN has converged, a whole span is one `buffer.copy`. ALLAN never has to learn an edge, and the rasterizer never has to learn a texture.

## 6. Measured summary

Full table: `bench/results/compute-x64.md`. Selected rows (ms per 1024 x 1024 frame; error against exact area in 1/255 units, identical in both runtimes):

| Technique | interp | native | error vs exact | Verdict |
|---|---|---|---|---|
| calibration: constant `writeu32` | 8.8 | 2.2 | - | - |
| SDF shapes, brute force, linear (256 shapes) | 60 430 | 15 907 | 11 to 57 | reference only |
| SDF shapes, painter's algorithm, linear | 653 | 144 | 11 to 57 (+ 8-bit rounding per layer) | reject |
| SDF shapes, quadtree, linear, leaf 4 | 106 | 32 | 11 to 57 | previews |
| **SDF shapes, quadtree, exact, leaf 4** | **131** | **44** | **0.50 (capsule caps 0.74)** | adopt |
| SDF shapes, dirty update (1 shape moved), exact | 2.2 | 0.6 | same as full | adopt |
| **256 stars, scanline exact-area painter** | **39** | **12** | **0.50** | adopt |
| 256 stars, SDF quadtree, exact | 485 | 139 | 0.50 | (use scanline) |
| disc R = 300, per pixel / analytic spans | 70.3 / **2.0** | 25.4 / **1.1** | 0.50 | spans: adopt |
| disc R = 300, forward differencing | 67.3 | 25.2 | 0.50 | reject |
| exact EDT | 173 | 44 | 0 (exact) | adopt |
| 8SSEDT / jump flooding | 804 / 4 127 | 126 / 732 | 0 / up to 2.16 px | reject |
| matte from mask (signed EDT + feather) | 424 | 102 | - | adopt |
| box blur, any radius | 199 to 204 | 35 to 36 | 0 vs brute force | adopt |
| area resample 1024 -> 737 (exact) | 192 | 40 | correctly rounded (C9) | adopt |
| SAT resample 1024 -> 737 | 784 | 228 | ties only | variable footprints |
| height to normal map | 98 | 13.5 | - | adopt |
| intern 1024^2 as 16 px tiles | 3.7 | 2.9 | exact dedup (4.3x less memory) | adopt |
| Morton codes (1M), lookup table / bit32 | 65 / 188 | 22 / 19 | - | table on clients |
| expression: generated module / op array per row / closure / op array per pixel | 541 / 904 / 1 307 / 2 485 | 172 / 282 / 605 / 600 | bit-identical | generated, column-at-a-time |
| expression, `loadstring` with Roblox-like unsafe environment | 830 | 1 022 | bit-identical | reject |
| expression, quadtree, Lipschitz / interval | 74 / 72 | 47 / 44 | bit-identical to brute force | adopt |
| sphere-traced normal map | 1 580 | 593 | - | server + bake |
| supersampling 4x4 / 16x16 (as a "reference") | - | - | 30.9 / 4.4 | reject as reference |
| low-res SDF magnified, 4 px texels, R = 300 / corners | - | - | 1.6 / 78 | adopt later (MSDF), not flawless |

## 7. Ranked pipeline recommendation

Ranked by how much each stage contributes to "fastest, highest-quality, deterministic", with its ALLAN role:

1. **Classify and bin before computing anything** (per-tile shape bins, quadtree with Lipschitz or interval classification, ring/Morton tile order, span fills for uniform nodes). 570x over brute force; exact by C2. *ALLAN: produces its input tree and its segments; only non-constant nodes reach the network.*
2. **Exact-area edges.** Polygons, glyphs and paths through the scanline accumulator (exact and the fastest path measured, 39 ms for 256 stars interpreted; merge abutting shapes, C11). Curved SDF primitives through `MODE_EXACT` (flawless, 1.2x the linear ramp). *ALLAN: the crisp-edge path and its quality reference.*
3. **Reuse before recompute.** Dirty-tile re-rendering (63x less work per edit), content-addressed copy-on-write tiles (exact dedup at C speed), GPU crossfades and UV animation instead of CPU passes. *ALLAN: cache keyed by inputs; keyframes blended by the GPU.*
4. **Interiors.** Flat: span fills. Organic texture, gradients, PBR: ALLAN, run column-at-a-time in a build-time generated kernel. Procedural fields: build-time generated row kernels or column-at-a-time op arrays. *ALLAN: the paint in paint x coverage.*
5. **Integer-exact image operators.** Area resampling for every LOD level (C9), running-sum blur and glow, exact EDT for mattes, outlines and glows, height to normals. Full frames on the server, regions on clients. *ALLAN: exact LOD targets; matte band and features.*
6. **Scheduling.** Client: time-sliced tiles in ring order (4 to 8 ms per frame), Actors once the probe confirms the speedup. Server: native generation then `CreateDataModelContentAsync` for static content, after the probe confirms baking keeps the bytes. *ALLAN: rows per slice and per Actor; training on the server.*
7. **Heavy generators, server only.** Sphere tracing, impostors, palette quantisation, ALLAN training.

Rejected: brute force and painter's algorithm, forward differencing as an optimisation, jump flooding and 8SSEDT on the CPU, per-pixel interpreters and closure trees, Morton pixel layouts, `loadstring`, supersampling as a reference, low-resolution distance fields where flawless edges matter, separate space-time octrees.

## 8. Axioms added by this study

- **C1 (exact-area reference).** Flawless means each byte is the correctly rounded exact area (F1 at 0.5 + 0.01) per shape, deterministic across runtimes (F3); supersampling is not a reference.
- **C2 (conservative classification identity).** Quadtree culling with conservative 0/1 classification and a shared per-pixel routine reproduces brute force bit for bit.
- **C3 (linear ramp error).** `clamp(0.5 - d)` errs by up to `(sqrt(2)/2 - 1/2)^2 = 10.94/255` on a straight 45 degree edge; exact only on axis-aligned edges.
- **C4 (half-plane exactness and reach).** Half-plane coverage is exact for straight edges and is exactly 0 or 1 beyond `|d| = sqrt(2)/2`; culling and bounds must use that reach.
- **C5 (curvature).** The half-plane overestimates a convex boundary of curvature `k` by at most `0.1179 k` (30/R in 1/255 units); the first-order chord correction leaves `O(k^2)`: flawless for radius >= 8 px, visually flawless for >= 4 px.
- **C6 (corners).** No function of `(d, n)` is exact at a corner; exact coverage there clips the pixel by the two edges (intersection, union, or the two-edge sliver/gap rule).
- **C7 (dyadic incremental evaluation).** Forward differencing is bit-identical to direct evaluation when all operands are dyadic and bounded.
- **C8 (EDT exactness).** The Felzenszwalb-Huttenlocher transform on integers in doubles is exact for widths up to 8192.
- **C9 (integer-weight resampling).** Area-average resampling with integer weights and `(2S + T) // (2T)` is the exact rational mean rounded half up, at any ratio, identical everywhere; it equals the 2 x 2 box mip at 2x.
- **C10 (interned identity).** Equal Luau strings have equal bytes; content-addressed tiles dedup exactly at C speed.
- **C11 (conflation).** Per-shape exact coverage composited with source-over leaves a seam of up to 64/255 on shared edges; abutting shapes must share one winding accumulator.
- **C12 (work follows events).** With span fills, cost per row is O(edge crossings x band width + spans), independent of area (36x on a disc); interpretive dispatch must be paid per node per row (C12b, 2.7x).
- **C13 (runtime identity).** Every prototype here produces the same bytes in the interpreter and native code (eight asserted hashes); deterministic ops plus a fixed operation order suffice.
- **C14 (magnification bound).** Bilinear magnification of a distance field errs by `h^2 / (8R)` px on a curve of radius R and by O(h) at corners.
- **C15 (integer division under fast-math).** Division by powers of two and integer floor division below 2^51 stay deterministic even if `//` and `%` are compiled with reciprocal multiplication or contraction.

## 9. Corrections to the project axioms

1. **`MyMath.coverage` (the linear ramp) is not a flawless coverage function.** Its comments and the project's use treat `clamp(0.5 - d/w, 0, 1)` as the anti-aliasing rule. Its exact-0 and exact-1 claims beyond `|d| >= w/2` are right, but as an estimate of pixel area it errs by up to 10.94/255 on straight 45 degree edges (C3, closed form), 11/255 on circles of any radius, 38/255 at sharp box corners and up to 57/255 at polygon corners (measured, 3.3). Proposed correction, for the owner of `src/MyMath.luau` to decide:
   - add `MyMath.coverageHalfPlane(d, nx, ny)` and `MyMath.coverageCurved(d, nx, ny, k)` (the functions in `Coverage.luau` and `Raster.covCurved`), and state C4 and C5 as axioms;
   - keep `MyMath.coverage` but document it as "linear ramp, exact only for axis-aligned edges; up to 11/255 error elsewhere";
   - use the reach `w sqrt(2)/2` instead of `w/2` wherever exact coverage is culled or bounded (C4). Code that culls at `w/2` and then switches to half-plane coverage silently cuts real coverage on diagonal edges.
2. **The Lipschitz culling rule needs the coverage function's reach.** "Drop a shape when `d - reach > w/2`" is correct for the linear ramp only. The general rule is "drop when `d - L rho >= R_cov`", where `R_cov` is the largest `|d|` at which the coverage function is strictly between 0 and 1, and bounding boxes for binning must grow by the same `R_cov` (fixed in `Raster.updateBounds`).
3. **Supersampling is not ground truth.** Any test that compares against an n x n supersampled render inherits up to about `1/(2n)` error per edge (measured 31/255 at 4 x 4, 4.4 to 6/255 at 16 x 16). The project's references are the exact areas of section 1.
4. **Coverage-as-alpha is not exact for shared edges** (C11). Vector content whose shapes abut must be accumulated as one path.
5. **The rasterizer's interpreter cost was understated about 3x** in the previous notes (native numbers reported as interpreter numbers): 256 shapes at 1024 x 1024 take 106 ms interpreted, not 34 ms. Full-frame vector renders do not fit a client frame; edits do.
6. **RUNTIME_AUDIT 6.5's fast-math caveat is narrower than stated** for the integer and power-of-two cases the project uses (C15), pending a Windows client hash check.

## 10. What the Studio probe must confirm

`studio/EditableImageProbe.luau` and `studio/ParallelProbe.client.luau` already measure most of these; this study depends on:

1. **Combine-op arithmetic** for each `ImageCombineType`: exact formula, rounding, clamping, straight versus premultiplied storage, and whether client and server agree bit for bit (decides 4.4).
2. **`DrawImageTransformed` filtering**: bilinear weights and rounding, edge handling, channel independence with alpha 255, minification behaviour (decides 3.7 and engine resampling).
3. **Baking fidelity**: read back content baked by `CreateDataModelContentAsync` and compare with the source buffer; mip filter used (decides whether F1/F3 survive 4.8).
4. **`WritePixelsBuffer` cost per byte and per call**, to size dirty-rectangle flushes (3.9).
5. **Actors**: `SendMessage` copy cost for a 4 MB buffer, desynchronised compute throughput, real speedup on 4-core and 8-core phones (4.6).
6. **Client interpreter speed per device class**: run the calibration kernel; scale every interpreter number in section 6 by its ratio to 8.8 ms.
7. **Determinism on devices**: run `tests/compute.test.luau` (its hash constants) on an x64 Windows client, an ARM phone and a server; all must pass (F3, C15).
8. **`loadstring` on servers**: whether chunks are native-compiled and how slow they are with `LoadStringEnabled` (expected about 1.5x a generated module, 4.1).
9. **Stacked transparent layers** (shell texturing): overdraw cost of 8 to 16 stacked `ImageLabel`s or `Decal`s on phones (2.5).

## 11. Files and how to reproduce

| File | What |
|---|---|
| `src/compute/Coverage.luau` | Coverage estimators and exact references: half-plane, curvature-corrected, deterministic arcsine, disc-rectangle area, wedge and edge-pair clipping, rounded corners, polygon area, supersampling, error statistics |
| `src/compute/Raster.luau` | Scene rasterizer: linear and exact coverage modes, brute force, painter, per-tile binning, Lipschitz quadtree, dirty re-render, time slicing |
| `src/compute/Scanline.luau` | Exact-area signed accumulation: layer resolve and composite painter, curve flattening |
| `src/compute/Rows.luau` | Batch row kernels: direct, forward-differenced, analytic spans |
| `src/compute/Distance.luau` | Exact EDT, jump flooding, 8SSEDT, brute force, signed distance, matte, shells, glow |
| `src/compute/Filter.luau` | Running-sum box blur, summed-area table, exact area resampling, normal maps |
| `src/compute/Tiles.luau` | Morton codes and orders, content-addressed store, copy-on-write grid |
| `src/compute/Expr.luau` | SDF expressions: closures, op array (per pixel and per row), generated source, interval arithmetic, quadtree render |
| `src/compute/Trace.luau` | Sphere tracing to normal and height maps |
| `tools/gen_expr.luau` | Build-time code generation demo; writes `bench/generated/ExprDemoRow.luau` |
| `tests/compute.test.luau` | Correctness and cross-runtime hashes for every prototype |
| `bench/compute.luau` | Timings and quality numbers |
| `tools/run_compute_bench.sh`, `tools/merge_compute.py` | Three interleaved rounds per runtime, per-key minimum, determinism check of quality rows |
| `bench/results/compute-x64.md` | Merged results |

Reproduce: `tools/run_compute_bench.sh` (about 2 minutes), `luau tests/compute.test.luau` and `luau --codegen tests/compute.test.luau` (about 11 s interpreted), `luau-analyze --mode=strict src/compute/*.luau tests/compute.test.luau bench/compute.luau`.
