# ALLAN: the Alpha Liquid network that draws the image

ALLAN (ALPHA LNN) is this project's own liquid neural network, designed for Luau and for Roblox's constraints, and used as the renderer itself. Status: specification v1. Every numbered claim is marked **[proved]**, **[to prove]** or **[to measure]**. The build must turn each **[to ...]** into a proof, a test or a measured number, or correct the claim.

## 1. The idea

MIT's liquid networks (Hasani, Rus et al.: Liquid Time-constant Networks, then the closed-form CfC) are tiny continuous-time networks. Each neuron relaxes toward a target with a time constant that depends on the input, so the network reshapes its dynamics while it runs. They were built for time series and are known for extrapolating well outside their training data.

**ALLAN's move: a scanline is a time series.** Walk a row of pixels as if x were time, let a handful of liquid neurons relax across it, and read the colour out of their state. Where the image is flat the neurons converge, so the renderer stops computing and copy-fills. Where it has detail, time constants are short and neurons react fast. The time constant is the local level of detail, so cost scales with the number of **events** in a row (places where something changes), not with pixels.

## 2. How ALLAN differs from the liquid networks it descends from

| # | Liquid / CfC networks | ALLAN | Why |
|---|---|---|---|
| L1 | Time constant is any positive real; update uses `exp` and `sigmoid` | **Dyadic gains**: per neuron `g = 2^-k`, integer `k` in `[0, K)`; update `h += (b - h) * g` | No libm, three ops per neuron, bit-identical on every device. `k = 0` is an instant edge, large `k` a soft gradient |
| L2 | Evaluated step by step | **Closed-form jumps**: constant input over a segment gives `h(n) = b + (h(0) - b) * a^n`, `a = 1 - g` | Skip any number of pixels in O(N) |
| L3 | Computes every step | **Event-driven rendering** with a proved skip bound (T2) | Flat spans become one `buffer.copy` |
| L4 | Point outputs | **Integral outputs**: the exact box-filtered average over a footprint of `L = 2^level` pixels is a geometric series | One model renders every mip level already prefiltered |
| L5 | Causal in time | **Bidirectional** passes, `z = d + Cf hf + Cb hb` | Images have no arrow of time |
| L6 | All weights trained by backpropagation through time | **Reservoir training** (the original "liquid state machine" idea): gains and input maps structured, only the readout trained, by ridge regression | Training is one small linear solve; it runs **on the Roblox server in Luau** (section 6) |
| L7 | Inputs are sensor signals | **Shell-byte quadtree** inputs: split only where detail lives (shells around edges), a few bytes per leaf; **leaf size sets the time constant** | The quadtree is the detail map |
| L8 | Floating point, platform libm | Deterministic op set only (docs/RUNTIME_AUDIT.md 6.5) | Every client renders the same bits, so instances exchange inputs, never pixels |
| L9 | Learns once, offline | **Federated exact learning**: training statistics are integers that add; servers merge them in any order and get the same model | Every server in the experience learns from every other, bit for bit |
| L10 | Extrapolation is an emergent property | **Extrapolation as a first-class operation** in time, level of detail, space, resolution and budget (section 7) | Work happens before it is needed, or not at all |

## 3. The model

Notation: row length `W` base pixels, pixel `j` covers `[j, j+1)`. `N` neurons (4 to 16), `I` input bytes per leaf, `M` output channels (3 for RGB, up to 8 for PBR: albedo RGB, normal XY, roughness, metalness, AO).

**Inputs.** Along a row, the quadtree leaves crossed cut it into **segments**; the input `u` (bytes mapped to `byte / 255`) is constant on each segment.

**Targets and gains.** Neuron `i`: target `b_i = beta_i + sum_t B[i][t] * u_t`; gain exponent `k_i = clamp(kBase_i + depthShift(leafSize), 0, K - 1)`, where `depthShift` makes small leaves fast; `g_i = 2^-k_i`, `a_i = 1 - g_i`.

**Step (one base pixel).** `h_i <- h_i + (b_i - h_i) * g_i`, in exactly this operation order in Luau and in any reference implementation, so all produce identical bits.

**Output.** `z_m = d_m + sum_i Cf[m][i] * hf_i + sum_i Cb[m][i] * hb_i`, summed in index order; `byte = clamp(floor(z_m + 0.5), 0, 255)`.

**2D.** Rows in the same quadtree band that cross identical segments with identical inputs and start states render once and are copied. Vertical variation enters through the leaves a row crosses. Vertical smoothness across leaf boundaries is an open point (section 10).

## 4. Rendering theorems

**T1 Closed form [proved].** With constant `b, a`, the step maps `h - b` to `(h - b)(1 - g) = (h - b) a`, so `h(n) - b = (h(0) - b) a^n` in exact arithmetic. In floating point a jump differs from stepping in the last bits, so every client must use one fixed evaluation schedule, which is a deterministic function of the inputs and `epsilon`.

**T2 Event skip bound [to prove, including rounding].** With `e_i = h_i(0) - b_i` and `z_m(inf) = d_m + sum_i C[m][i] b_i`: `|z_m(n) - z_m(inf)| <= R_m(n) = sum_i |C[m][i] e_i| a_i^n`, non-increasing in `n`. Once `R_m(n0) <= epsilon` for all `m`, the rest of the segment is one span of the quantised limit colour, within `epsilon + 0.5` of the exact model per channel. Bidirectional passes add both bounds.

**T3 Logarithm-free n0 search [to prove].** Precompute integer half-lives `H_k` with `(1 - 2^-k)^H_k <= 1/2`; halve the residual bound in steps of `H_kmax` until it is below `epsilon`. Bound the iterations.

**T4 Decaying active set [to prove].** Drop neuron `i` from the per-pixel sum once `sum_m |C[m][i] e_i| a_i^n <= epsilon / N`; total error stays within `epsilon`, and per-pixel cost falls as the segment converges.

**T5 Integral LOD [to prove].** The exact average of `z_m` over base pixels `n_s .. n_s + L - 1` is `z_m(inf) + sum_i C[m][i] e_i a_i^n_s (1 - a_i^L) / (L g_i)`. For `L = 2^level`, `a_i^L` is `level` exact squarings, so a per-`(k, level)` table makes each level an exact horizontal box filter at one evaluation per output pixel.

**T6 Cost model [to measure].** Per event about `3N` ops plus `2MN` multiply-adds, doubled for two passes. With `N = 8, M = 4`, about 130 ns per event in the interpreter. Predicted 1024 x 1024 cost: about 17 ms at 64 events per row, 3 ms at 10 (flat art), 270 ms for noise-like content, where server generation plus baking takes over.

**T7 Lockstep determinism [to prove and test].** Same model bytes, tree bytes, `epsilon`, level and schedule give bit-identical pixels in the interpreter and in native code on every device.

## 5. Training offline (numpy)

1. Build the shell-byte quadtree: split while the maximum channel deviation from the node mean exceeds `theta` and the node is above the minimum leaf size.
2. Fix the reservoir: `N` neurons with a multi-scale spread of `kBase`, structured `B, beta`, the `depthShift` rule.
3. Simulate both passes with the exact Luau step order; collect states.
4. Ridge-regress the readout to all target channels at once. Report PSNR, max error, events per row and bytes against raw RGBA8.
5. Export model and tree as a versioned binary (version byte first) loadable through `buffer`.

## 6. Training on the server in Luau, and learning together

**S1 Sufficient statistics.** Ridge regression needs only the Gram matrix `G = sum_x s(x) s(x)^T` and the cross term `P = sum_x s(x) y(x)^T`, where `s(x)` is the state vector (forward states, backward states, a constant 1; `D = 2N + 1`, so 17 for `N = 8`) and `y(x)` the target channels. The readout solves `(G + lambda I) C = P` by Cholesky on a 17 x 17 matrix.

**S2 Cost [to measure].** Per sampled pixel: `D(D+1)/2 = 153` products for `G` and `D * M` for `P`, about 440 ops with the states. One million pixels: roughly 0.7 s interpreted and 0.2 s with native codegen, which the server has. Sampling every fourth pixel divides that by four. Time-sliced on `Heartbeat`, training never stalls the server.

**S3 Exact integer accumulation [to prove].** Quantise states and targets to 15-bit fixed point. Every product is below `2^30`, so up to `2^23` (about 8 million) samples sum exactly in a double's 53-bit integer range; a second limb extends it. Integer sums are associative, so **the result does not depend on the order samples or servers are merged**: exact, order-free federated learning.

**S4 Federated learning across servers [to design and measure].** Each server accumulates `(G, P, count)` from its own textures or player edits. The upper triangle of `G` plus `P` is 153 + 68 numbers. Servers exchange them through MessagingService (1 kB per message, so two or three messages, or quantised to fit one), and persist the sum in a DataStore. Every server solves the same system and gets the same readout bytes; clients receive only the model bytes.

**S5 Gain search on the server [to measure].** The discrete `kBase` choices are tuned by coordinate descent: change one neuron's `k`, re-simulate a sample, re-solve, keep it if validation error drops. Each trial costs one sampled accumulation and one 17 x 17 solve.

**S6 Online adaptation.** A recursive least-squares update (or simply adding new statistics and re-solving) lets the server keep learning while the game runs, from new textures, player drawings or new devices' needs.

## 7. Extrapolation, first class

**X1 In time (texture dead reckoning) [to design].** For animated textures (water, fire, caustics), leaf features evolve with their own liquid cells. Their state can be advanced in closed form (T1) to any future time, so a client renders frame `t + Delta` during idle time and between server updates keeps evolving the texture deterministically. Corrections from the server are inputs, not pixels.

**X2 Across level of detail (Richardson LOD) [to prove].** Render two coarse levels cheaply and extrapolate the next finer one, for example `z_0 ~ z_1 + c (z_1 - z_2)` with `c` derived from the geometric-series structure of T5. The discrepancy `|z_1 - z_2|` is an error estimate, so refinement is spent only where the extrapolation is wrong. This gives an instant fine level and an exact one later, refined in error order. Derive when the extrapolation is exact (single-exponential segments) and bound the error otherwise.

**X3 In space (endless textures) [to design].** Leaves outside the stored tree are generated from a hash of their coordinates and the seed (MyMath.hash2), so rows continue past the texture's edge: virtual canvases larger than 1024, generated on demand and identical on every client.

**X4 In resolution (learned detail) [to measure].** Train the readout to predict fine-scale structure from coarse leaves, so rendering above the source resolution shows plausible detail rather than blur. This is learned and deterministic, not recovered information, and is labelled as such.

**X5 In budget (predictive control) [to design].** A small liquid controller extrapolates frame time and memory trends and lowers `epsilon`, level or residency before a stutter happens, instead of reacting after it.

## 8. Applications

- **PBR from bytes**: one shared reservoir per material family, per-texture tree and readout, decoded at whatever resolution the client can afford.
- **Liquid matte (background removal)**: a liquid neuron whose gain depends on the colour step between neighbours is a recursive bilateral filter. Run it left, right, up and down over a raw chroma or flood-fill matte: edges stay sharp, noise and holes smooth out, O(pixels) at a few ops per pixel per direction, deterministic.
- **Water and animated textures**: X1, plus re-rendering only rows that cross leaves whose state moved more than `epsilon`.
- **Client adaptation**: knobs are `epsilon`, level, active neurons and leaf depth, driven by the controller of X5.
- **Instances talking**: inputs, seeds, edits, time stamps and training statistics travel; pixels never do.

## 9. Built for the future

ALLAN is data: a versioned model and a tree. Execution is a backend. Today's backends are the Luau interpreter (clients), Luau native code (servers), and baking through `CreateDataModelContentAsync`. Each likely change lands on one seam:

| Future change | Where it lands |
|---|---|
| Native codegen on clients | Same Luau backend gets 4 to 10x faster; `epsilon` and level defaults rise |
| EditableImage limit above 1024 | Tile size is a runtime capability; X3 tiles grow |
| GPU compute or shaders exposed to scripts | A new backend evaluates the same model bytes; T7 still defines the reference |
| 64-bit integer type in Luau | S3 accumulation moves to native integers; same results |
| New combine types or baking rules | Only the integration layer (Canvas flush, baking) changes |
| Larger cross-server message limits | S4 sends statistics in one message |

## 10. Open points to settle with measurements

1. Vertical smoothness across leaf boundaries: a vertical liquid pass at leaf-feature level, a vertical pass on output limited to rows that differ, or bilinear leaf features in y.
2. Vertical prefiltering for T5.
3. Predicting runs of equal quantised value inside a transient.
4. Quality ceiling (PSNR, max error) on flat UI art, SDF logos, marble, wood, water caustics and a PBR set, as functions of `N`, `K`, `theta`, `epsilon`.
5. Server training time in Luau, interpreted and native, against S2.

## 11. Renderer results

Built: `src/Liquid.luau` (renderer, codec, step-by-step reference, X2, X3), `tests/liquid.test.luau` (assertions, run by `tests/run.sh` in the interpreter and with native code generation), `bench/liquid.luau` (scenes and timings), `bench/results/liquid-x64.md` (full benchmark output, both runtimes). Labels in this section: **[proved]** proof given here; **[tested]** asserted by `tests/liquid.test.luau` in both runtimes; **[measured]** a number from `bench/liquid.luau` on this machine (2.1 GHz x64 VM shared with other agents; every timing is the minimum of 3 runs); **[conjecture]**.

### 11.1 Format, interfaces, interoperability

The binary layout and the exact arithmetic are written once, as the header comment of `src/Liquid.luau`, and stay version 1. Two points the specification left open were settled with the learning builder (`src/LiquidLearn.luau`, `tools/liquid_train.py`), which implements the same layout:

- every split node has all four children, including nodes with no pixel inside the image (builders store them as zero-byte leaves; the renderer never shows them except in the endless mode, which replaces them by virtual leaves);
- `depthShift`: `k = clamp(kBase + log2(leafSide) + r, 0, K - 1)` with `r` the log2 render scale (`Liquid.prepare(model, tree, r)` renders `2^r` times larger, the X4 setting); `kBase <= -K - r` is an instant neuron.

Interoperability **[tested]** by `tests/liquid_learn.test.luau`: the learning builder's three golden models (64 x 64, r = 0 and r = 1) decode with `Liquid.decode`; `Liquid.reference` reproduces the pure-Python scalar reference's pixels exactly; `Liquid.render` reproduces them exactly at `epsilon = 0` and within 1 at `epsilon = 0.5`.

Interfaces: `decode`, `encode`, `newModel`, `newTree`, `buildTree`, `prepare`; `render(plan, tree, out, outWidth, opts)` with `epsilon`, `level`, a region `x y w h` and destination `dx dy`, `vertical = "box" | "point" | "rows"`, `out2` for channels 4..7, `endless = {seed, horizon, tolerance}`, `dedup`, `stats`; `renderCanvas` (marks exactly the written rows dirty **[tested]**); `renderRows`; `renderRowValues` (real values); `reference`, `referenceRow`, `referenceSpan`, `referenceEndless` (pure stepping); `richardsonRow`, `predictFiner` (X2); `virtualLeafAt`, `windowCertificate`, `seamBound` (X3); `hashBuffer` (T7 checksum).

### 11.2 The algorithm as built

Per row, the leaves the row crosses are its segments; neighbours with equal content and depth are merged. A backward and a forward sweep of closed-form jumps (T1) give every segment its entering residuals. Per segment:

1. **Gain groups.** Neurons with equal `kBase` have equal `k` at every depth, so by linearity the readout-projected state of a group, `sum_{i in g} Cf[m][i] h_i` (and the same with `Cb`), obeys exactly the jump of a single neuron. The fast path (M <= 4) tracks `4G` projected values, `G` the number of groups of non-instant neurons (2 for the learning builder's default reservoir), instead of `N` states plus a per-segment projection (N2 below).
2. **Classes.** Groups with equal `k` at the segment's depth collapse into one decay term per channel; `k = 0` terms vanish after one step (`a = 0`). A segment with no non-instant term is exactly a span of its limit colour.
3. **Footprints.** At level `L` an output pixel covers `F = 2^L` rendered pixels: the closed form of T5 for footprints inside the segment, exact geometric sums for the partial footprints at its ends (accumulated across segments).
4. **Fill.** The first footprint where the forward residual bound is below its budget and the last where the backward one is (T2, T3) bound one span, written with one `writeu32` and `buffer.copy` doubling.
5. **Transients.** The footprints outside the span are evaluated in closed form, walking from each end inward and skipping terms below their share of `epsilon` (T4).

Per frame: rows of a band (rows that cross the same leaves) are evaluated once and copied; a row whose segment sequence equals an earlier row's is copied (N3); in endless mode each block column is evaluated over its own canonical window (X3).

### 11.3 T1 closed form: [proved, tested]

In exact arithmetic the step maps `e = h - b` to `e (1 - g) = e a`, so `e_n = e_0 a^n`. In floating point (`u = 2^-53`, `Hm = max(|b|, |h0|)`): stepping commits at most `u |e_t| g + u |h_{t+1}|` per step and the map contracts earlier errors by `a`, so it ends within `u (|e0| + Hm min(n, 2^k))` of the exact value (first order). The power table is filled as `pw[n] = pw[floor(n/2)] pw[ceil(n/2)]`; by induction its relative error is at most `(n - 1) u`, so the jump `b + (h0 - b) pw[n]` is within `u (|e0| (n + 1) + Hm)`. Hence the stated tolerance

    |jump - step| <= 4 u (|e0| (n + 2) + Hm (min(n, 2^k) + 2))

(the factor 4 absorbs second-order terms). Tested on random `(k, n, b, h0)`; measured on 3000 cases with `k` in 0..30, `n <= 1024`, `|b|, |h0| <= 3`: max `|jump - step| = 1.1e-13`, at most 0.18 of the tolerance. The table is non-increasing in `n` and non-decreasing in `k` (checked exhaustively; T2 and T3 rely on it).

The evaluation schedule (which jumps, closed forms, fills and skips happen where) is a function of the model, the tree, `epsilon`, the level, the vertical strategy and the endless parameters only, never of the requested region (N4), so it is the same on every client.

### 11.4 T2 event skip, strengthened to a lossless mode: [proved, tested]

Inside a segment the exact value of footprint `X` is `z_m(X) = zinf_m + sum_c Qf'[c][m] a_c^nf(X) + sum_c Qb'[c][m] a_c^nb(X)` (T1, T5 and linearity), `nf` increasing and `nb` decreasing in `X`. The bounds `Rf_m(X) = sum_c |Qf'[c][m]| a_c^nf(X)` (non-increasing in `X`) and `Rb_m(X)` (non-decreasing) give `|z_m(X) - zinf_m| <= Rf_m(X) + Rb_m(X)`.

The renderer's per-channel budget is `tau_m = max(epsilon, delta_m - eta)`, where `delta_m` is the distance from `zinf_m` to the nearest point at which `clamp(floor(z + 0.5), 0, 255)` changes and `eta = 2^-24`. With normalised weights `w_c = max_m |Q'[c][m]| / tau_m`, a footprint is filled with the quantised `zinf` when `sum_c wf_c a_c^nf <= hF` and `sum_c wb_c a_c^nb <= hB`, `hF + hB <= 1` (one half each, or 1 for a side when the other has no residual). Then `Rf_m + Rb_m <= tau_m` for every channel, and:

- if `tau_m = epsilon`: `|q(zinf_m) - z_m| <= 0.5 + epsilon`;
- if `tau_m = delta_m - eta > epsilon`: `|z_m - zinf_m| < delta_m`, so `z_m` lies in the quantisation cell of `zinf_m` and the filled byte **is** the exact model's byte.

By monotonicity the filled footprints of a segment form one interval. Transient footprints are evaluated in closed form with the terms skipped by T4 contributing at most `epsilon`; partial footprints are exact sums; `clamp` is 1-Lipschitz. So every byte is within `epsilon + 0.5` of the exact value, and with `epsilon = 0` nothing is approximated at all. Floating point: the bounds use the same power table (relative error below `2^-36` for `n <= 65536`), comparisons are shrunk by `2^-40` and the margin by `eta`; what is left (of the order of `1e-9` output units at most for the value ranges used here, including the reference's own stepping error) is covered by the stated slack `FP = 1e-7` of the tests.

Tested for random models and trees, levels 0 to 3, all three vertical strategies, regions, M from 1 to 7 and r = 1: every byte within `epsilon + 0.5 + FP` of the reference value and within 1 LSB of the reference byte; with `epsilon = 0` the event renderer equals the step-by-step reference byte for byte (lossless), also on the learning builder's golden models. Measured: on the benchmark scenes `epsilon = 0` costs the same as `epsilon = 0.5` (11.9), because the quantisation margin does the skipping.

### 11.5 T3 logarithm-free n0 search: [proved]

`NT[k][j]` = smallest `n <= T` with `a_k^n <= 2^-j` (read off the power table, `j <= 62`; `T + 1` when none). It generalises the half-lives: `NT[k][1] = H_k` and `NT[k][j] <= j H_k` because `a^H_k <= 1/2`. Measured `H_1..H_10 = 1, 3, 6, 11, 22, 45, 89, 178, 355, 710`.

**Claim.** With `W = sum_c w_c`, `kmax` the largest gain with a nonzero weight and `j = ceilLog2(W / h)`, every `n >= NT[kmax][j]` satisfies `sum_c w_c a_c^n <= h`. *Proof.* The table is non-increasing in `n` and non-decreasing in `k`, so `sum_c w_c pw[k_c][n] <= W pw[kmax][n] <= W 2^-j <= h`.

`ceilLog2` uses no logarithm: multiply by `2^-512, 2^-256, ..., 2^-2` whenever the ratio exceeds that power (exact, powers of two), leaving `r` in `(1, 2]`; the answer is the accumulated exponent plus 1. Ten comparisons, no rounding. (The specification's "halve in steps of `H_kmax`" is the same bound with `NT[kmax][j]` replaced by `j H_kmax`.)

The renderer probes the segment's first footprint (a converged entry costs one probe), otherwise takes the T3 point as the upper end and gallops and bisects below it: `O(log(transient length))` probes, each `O(classes)`. Measured on a logo-like scene: 0.38 to 0.71 probes per segment for `epsilon` 2 to 0.

### 11.6 T4 decaying active set: [proved, tested, measured]

A term (one class in one direction) with `om = max_m |Q'[c][m]|` is skipped at footprint `X` when its power `p = a^n` satisfies `p <= share / om`, `share = epsilon_dir / (terms in that direction)`, `epsilon_dir = epsilon / 2` (or `epsilon` when the other direction has no term). Each skipped term moves each channel by at most `om p <= share`, so all skipped terms together stay within `epsilon`. The rule is stateless (it depends on `X` only), which keeps region renders identical to crops of full renders (N4); because powers shrink along each walk, trailing skipped terms are trimmed for good, so the per-pixel cost falls as the segment converges. Tested: the real-valued output (`renderRowValues`, levels 0 to 3) is within `epsilon` of the reference everywhere. Measured on the logo-like scene: closed-form term evaluations 49k at `epsilon = 0`, 27k at 0.25, 18k at 0.5, 10k at 1, 5k at 2 (fills and skips together). An earlier variant that computed every term's drop point up front with `ceilLog2` cost more than it saved on noise (single native runs: 72 ms at `epsilon = 0.25`, where drop points were computed, against 42 ms at `epsilon = 0`, where they were not), which is why the stateless form was kept.

### 11.7 T5 integral LOD and the vertical strategy: [proved, tested, measured]

Over a footprint of `F` steps starting at step `nf`, `(1/F) sum_{n=nf}^{nf+F-1} a^n = a^nf S1[k][F] / F` with `S1[k][F] = sum_{t<F} a^t = (1 - a^F) / g`, so `G[L][k] = S1[k][2^L] / 2^L` is the footprint factor of T5. The table accumulates `S1` term by term instead of computing `1 - a^F`, which avoids the cancellation of that difference for slow gains. The backward side uses the footprint's smallest backward step. Partial footprints at segment ends are summed exactly as `cnt zinf + sum_c Q a^n1 S1[k][cnt]`. Tested: level-L output equals the horizontal box average of the level-0 reference within `epsilon + 0.5` (levels 1 to 3; lossless at `epsilon = 0`).

**Vertical strategy (chosen: exact band-weighted box filter, `vertical = "box"`, the default).** Rows of a band are identical, so the 2D box average over the `F` rows of a footprint is `sum_bands (rows of the band in the footprint / F) x (the band row's horizontal average)`. When one band covers the footprint (the common case) the output row is that band's level-L row, with fills; otherwise the band rows are accumulated as real values (budget `epsilon`, no margin) and quantised once. It is exact: tested within `epsilon + 0.5` of the exact 2D box average of the reference. The alternatives are `"point"` (the footprint's centre row; cheapest) and `"rows"` (horizontal only, one output row per rendered row). Measured at level 2 against the exact 2D box average of the reference:

| scene | box: max / mean error | point: max / mean error | box ms | point ms (native) |
|---|---|---|---|---|
| flat UI | 0.57 / 0.027 | 71.0 / 2.16 | 30.5 | 7.1 |
| SDF logo | 0.64 / 0.052 | 102.2 / 0.62 | 32.3 | 7.7 |
| noise | 0.88 / 0.253 | 12.1 / 1.47 | 175 | 71 |

Point sampling aliases (errors up to 102 at edges), so the exact box filter is the default; point sampling stays available as the cheap preview. This settles section 10, point 2.

### 11.8 T7 lockstep determinism: [tested on x64 in both runtimes, argued for other devices]

The schedule is deterministic (11.3) and every operation is in the deterministic set of `docs/RUNTIME_AUDIT.md` 6.5: `+ - * /`, `sqrt` (X2 only), `math.floor`, comparisons, integer `//` and `%`, `bit32`, integer buffer ops; no `math.lerp` (codegen never fuses a separate multiply and add), no libm. Tested: seven renders (levels 0 and 2, lossless, endless, the generic M = 7 path with its second target, an X2 prediction) and the raw f64 bits of event and reference row values hash (`Liquid.hashBuffer`, `MyMath.hash32` over u32 words) to the same recorded constants in the interpreter and with native code generation. Other CPUs (ARM): argued from IEEE 754 and the op set, not tested here. `hashBuffer` doubles as a 4-byte lockstep checksum instances can exchange.

### 11.9 Measurements (T6 and the speedups): [measured]

1024 x 1024, three scenes built in `bench/liquid.luau` with exact-coverage anti-aliasing (a flat UI, an SDF logo, high-frequency fbm noise), shell-byte quadtrees with the learning builder's rule (`theta = 8`), readouts fitted by ridge regression on the learning builder's Walsh reservoir (`N = 8`, `K = 16`, scales `[instant, 0, -2]`; a faster `[instant, -2, -4]` in the full results). "Reference" steps every pixel; "band-copied" steps one row per band and copies the rest, isolating what the events contribute. Events are segments per evaluated row; evals are closed-form footprint evaluations per evaluated row.

Default reservoir, `epsilon = 0.5`, level 0 (native = `--codegen`, interp = interpreter, as on clients):

| scene | leaves | rows evaluated (+ deduplicated) of 1024 | events / row | evals / row | fill % | reference ms native / interp | ALLAN ms native / interp | speedup native / interp | vs band-copied reference | lossless `epsilon = 0` ms native / interp |
|---|---|---|---|---|---|---|---|---|---|---|
| flat UI (53.8 dB) | 32593 | 476 (+193) | 57.3 | 82.5 | 91.9 | 651 / 1911 | 25.4 / 60.9 | 25.6x / 31.4x | 16.9x / 18.3x | 23.8 / 77.0 |
| SDF logo (52.5 dB) | 24952 | 778 (+48) | 52.7 | 100.2 | 90.2 | 667 / 1912 | 26.6 / 87.6 | 25.1x / 21.8x | 19.9x / 17.5x | 26.3 / 90.1 |
| noise (40.0 dB) | 198949 | 880 (+0) | 428.4 | 1020.7 | 0.3 | 792 / 2160 | 189 / 563 | 4.2x / 3.8x | 3.6x / 3.6x | 190 / 630 |

(dB: PSNR of the model against its source image.) Other levels, `epsilon = 0.5`, ms native / interp:

| scene | level 1 box | level 2 box | level 2 point |
|---|---|---|---|
| flat UI | 34.6 / 115 | 30.5 / 108 | 7.1 / 24.5 |
| SDF logo | 47.8 / 152 | 32.3 / 120 | 7.7 / 26.9 |
| noise | 228 / 1049 | 175 / 646 | 71 / 206 |

On noise every footprint above level 0 spans several one-row bands, so the exact box filter accumulates every pixel and costs more than level 0; point sampling is the cheap path there. With the faster reservoir (`[instant, -2, -4]`, same PSNR within 0.4 dB) level 0 costs 20.1 / 62.2 ms (UI), 27.6 / 85.2 (logo) and 197 / 421 (noise); its noise pixels are 99.9 % fills, so what remains is per-segment overhead (428 segments per row). Full tables, `epsilon` 0 to 1 and both reservoirs: `bench/results/liquid-x64.md`.

Correction to **T6**. Per event the interpreter spends about 2.2 µs (flat UI: 61 ms for 476 evaluated rows of 57 segments, transients included), not 130 ns: the class bookkeeping per segment outweighs the predicted `3N + 2MN` operations by about 17 times. The flat UI frame (61 ms) is 3.6 times the predicted 17 ms rather than 17 times, because only 476 of 1024 rows are evaluated (bands and N3) and 90 to 99 % of evaluated pixels are fills. Noise-like content costs 563 ms interpreted (T6 predicted about 270 ms) and 150 to 190 ms native (4 to 6 times faster than the reference): every row is its own band, and there server generation plus baking remains the right tool, as predicted.

### 11.10 X2 Richardson LOD: [proved, tested, measured]

On a single exponential with ratio `rho` per level-(L-1) pixel, footprint averages are geometric too (T5), so a level-(L+1) pixel's four grandchildren `Z + r rho^p`, `p = 0..3`, relate to the coarse values by

    z_{L-1} = z_L + c (z_L - z_{L+1}),   c = +mu_a, -mu_a, -mu_b, +mu_b   (p = 0, 1, 2, 3)

with `mu_a = 2 / (1 + rho)^2` and `mu_b = 2 rho^2 / (1 + rho)^2` for a forward decay (swapped for a backward one). *Proof:* `z_L = Z + r (1 + rho) / 2` and `Z + r rho^2 (1 + rho) / 2` for the two children, `z_{L+1} = Z + r (1 + rho)(1 + rho^2) / 4`; substituting gives each `c`. `rho = 1` gives the affine coefficients `+-1/2`. `rho^2` is Aitken's ratio of consecutive level-L differences; the renderer accepts it only when two consecutive ratios agree to `1e-6` (always true on a single exponential) and otherwise keeps `+-1/2`.

- **Exact case [proved, tested]:** wherever the four level-L pixels `X-1 .. X+2` and the sibling of `X` see one exponential (one decay rate, one direction, inside one segment), the prediction is exact (measured error `5.7e-14` against the exact level).
- **Bound otherwise [proved, tested]:** with the affine coefficients the error of child `p` is `(3 d2a + d2b) / 8` (`p = 0, 1`, up to sign) or `(d2a + 3 d2b) / 8` (`p = 2, 3`), with `d2a, d2b` the two second differences of the fine values under the parent; so `|error| <= max |d2| / 2` for any signal. On single exponentials of any rate the true `|c|` lies in `[0, 2]`, so the affine prediction errs by at most `1.5 |z_L - z_{L+1}|`: the discrepancy is an error bound there. The geometric prediction is never worse than the affine one in the tests.
- **Mean preservation [proved, tested]:** each child pair averages back to `z_L` (`c` sums to 0 over a pair), so replacing the prediction by the exact level never shifts the mean: refinement cannot flicker.
- **Refinement [tested]:** `predictFiner` returns the rows in decreasing discrepancy; refining them all (`renderRows`) gives the exact level bit for bit.

Measured (level 0 from levels 1 and 2): 97.6 % (UI) and 97.9 % (logo) of pixels exact, mean error 0.22 and 0.33, maximum 68 and 76 at edges (segment boundaries, where no extrapolation can know the new leaf); noise 30 to 36 % exact, mean 0.64 to 0.75, maximum 7. The event-aware prediction pass (zero-discrepancy runs become fills) takes 6 to 28 ms native; producing the two coarse levels as real values takes 59 to 83 ms, more than rendering level 0 exactly (20 to 27 ms). So X2 is a progressive-quality tool, not a speed-up, on this content: an almost exact fine level from cached coarse rows, exact later. Refining 10 % of rows in discrepancy order removes 19 to 20 % of the error (uniform: 10 %); on noise the ordering gives nothing, and because almost every UI row crosses an edge, useful refinement needs spans, not rows (open issue 3).

### 11.11 X3 endless textures: [designed, proved, tested, measured]

**Virtual leaves.** The plane is tiled by blocks of the root side. Block (0, 0) is the stored tree; every other block, and every stored node with no pixel inside the image, is virtual: a node of depth `t` at stored origin `(x, y)` splits iff `t < maxDepth` and `hash2(x, y, hash2(t, 0x5B1, seed)) mod nodesAt[t] < splitsAt[t]` (the stored tree's split ratio at that depth), and a virtual leaf carries the content of the stored leaf `leavesAt[t][hash2(x, y, seedL) mod #leavesAt[t]]` (any stored leaf when none has that depth). Integers and `bit32` only, so every client generates the same canvas; only stored contents appear, so the readout sees inputs from its training distribution **[tested]**.

**Canonical windows.** An infinite row has no first pixel to start a pass at rest, so each block column is evaluated over a window: the block plus a warm-up `w` on each side, both passes starting at rest at the window ends. `w` is the first of `Sr/16, Sr/4, Sr, 4 Sr, ...` (capped at `horizon` blocks, default 2) whose certificate (below) is at most `tolerance` (default `2^-24` output units). The choice depends only on the virtual content of that row and block, so a pixel never depends on the requested region: renders tiled at any size and offset are bit-identical **[tested: tiles of 64, 37 and 23 pixels, levels 0 and 1, negative coordinates]**.

**Certificate [proved, tested].** Every state of either pass is a convex combination of targets, so for each neuron any two histories differ by at most `E_i` (the range of its targets over the stored contents). Starting at rest instead of from the true history changes neuron `i`'s state at `x` by at most `E_i` times the product of `a_i^len` over the segment pieces between the window end and `x`. Hence for every pixel of `[xl, xr)`

    |z_window - z_infinite| <= max_m sum_i (|Cf[m][i]| cf_i + |Cb[m][i]| cb_i) E_i

with `cf_i` the product from the window's left end to `xl` and `cb_i` from its right end to `xr` (`windowCertificate`; `render` reports the largest one in `stats.seam`). Two blocks therefore meet with a seam of at most twice the tolerance. Tested: windows overlapping at a pixel disagree there by at most the sum of their certificates (non-trivially: the measured disagreement reaches a positive fraction of the bound). The a-priori `seamBound` (worst-case contraction `(1 - 2^-kmax)^(h Sr)`) is also proved and tested but is pessimistic (50 output units at `h = 1` on a slow test model against 4.3 measured), which is why the window is chosen by certificate.

Measured: largest certificates `3e-10` to `6e-8` output units on the benchmark models (at most the tolerance); a fully virtual 1024 x 1024 tile 199 to 534 ms native and 0.7 to 1.4 s interpreted. The adaptive warm-up halved the cost against fixed 2-block windows (fast reservoir, UI: 498 to 232 ms in a single-run comparison). The rest of the cost is the virtual content itself: resampling split decisions per node reproduces each depth's split ratio but not the spatial coherence of edges, so a UI or logo tree continues as noise-like patchwork with a band per row. Endless mode suits texture-like content; spatially coherent virtual generation is open issue 4.

### 11.12 New results found while building

- **N1 Lossless event rendering.** The quantisation-margin budget of T2 makes `epsilon = 0` render exactly the reference's bytes while still filling spans, at the cost of `epsilon = 0.25 to 0.5` (11.4, 11.9). It also answers section 10, point 3, for the tail of every transient: once the residual bound is inside the quantisation cell of the limit, the rest of the run is one span of exactly the right byte.
- **N2 Gain groups.** Projected group states (11.2): an exact linear reduction of the tracked state; 11 % faster in an interleaved A/B in both runtimes, identical pixels.
- **N3 Exact row deduplication by content.** A rolling hash over (length, content key, depth) per segment finds rows that equal an earlier row, verified by comparing the sequences, so a collision can only cost a render. In a UI-like test tree 337 of 537 band rows repeat earlier ones; in the benchmark scenes 193 of 669 (UI) and 48 of 826 (logo).
- **N4 Region invariance.** Fill and transient regions are computed on the unclipped footprint range and T4 is stateless, so any region equals the same crop of a full render bit for bit **[tested]**: partial re-renders, tiles and lockstep clients all agree.
- **N5 Pure-fill segments.** A segment whose depth makes every tracked neuron instant is an exact span of its limit colour, at any length.
- **N6 Certified seams.** X3's a-posteriori certificate and canonical adaptive warm-up (11.11).
- **N7 Mean-preserving Richardson LOD** (11.10).

### 11.13 Open issues

1. The fill rule splits the error budget between the two directions. `Rf + Rb` is convex in `X`, so the exact fill interval of the combined bound can be found too; not done.
2. Interpreter cost per segment (about 2.2 µs) dominates on detailed content. Next candidates: sweeping only the groups that are non-instant at the segment's depth, a lighter traversal, and caching a band's segment list across frames.
3. X2 refinement by spans inside rows, and X2 from quantised coarse levels (today it needs real-valued coarse rows).
4. Spatially coherent virtual trees for X3 (for example split decisions hashed at the parent's coordinates so edges continue).
5. Vertical smoothness across leaf boundaries (section 10, point 1) is not addressed by the renderer: rows stay independent.
6. M > 4 runs on the generic path: measured 2.4 times (M = 5) and 3.6 times (M = 8) the time of M = 4 on a logo-like scene (native). Extending the fast path to 8 channels is mechanical.
7. Memory: the per-content cache holds `8G + 10` numbers per distinct leaf content (up to 32768 contents, about 6.5 MB as Luau tables for the noise scene's 15760). A client should cap it lower or store it in buffers.
8. T7 on ARM is argued, not tested.
