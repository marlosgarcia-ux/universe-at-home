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
