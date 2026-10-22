# ALLAN training: offline (numpy) and on the server (Luau)

This document reports the learning half of ALLAN (docs/LIQUID.md sections 5 and 6, claims L6, L9, X4, S1 to S6). Every number below was produced by code in this repository and can be regenerated with the commands in section 1. Every claim is labelled **[proved]**, **[tested]**, **[measured]** or **[conjecture]**.

The binary layout and the exact arithmetic are defined once, in the header of `src/Liquid.luau` (the renderer). `src/LiquidLearn.luau` and `tools/liquid_train.py` implement the same layout and the same operation order, and the tests check that all three agree bit for bit.

## 0. Verdict first

| Question | Answer | Status |
|---|---|---|
| Can the server train ALLAN in Luau, exactly? | Yes. Integer sufficient statistics in two limbs, a fixed-order Cholesky solve, readout bytes identical in the interpreter, in native code and in the Python replica | [proved] [tested] |
| Do servers that learn separately agree? | Yes. Every merge order, grouping, duplication and delivery order gives the same readout bytes (a G-Counter CRDT over integer statistics) | [proved] [tested] |
| Is it fast enough for a live server? | 1024 x 1024, every pixel, N = 8: 0.26 to 0.42 s native, 1.09 to 1.50 s interpreted; every fourth pixel 0.14 to 0.21 s native. Sliced on Heartbeat with a 1.5 ms budget: 99 % of slices under 1.66 ms native and 1.98 ms interpreted (best of three runs); the rare excursions above 2 ms match the VM's measured preemption jitter | [measured] |
| What does the liquid readout buy over its own quadtree? | +0.2 to +1.2 dB at N = 8, up to +1.7 dB at N = 16; at most 0.09 dB worse wherever the quadtree is below 70 dB (instant neurons, section 2.3); in the near-lossless regime (UI art at theta 2, 93 dB) ridge regularisation costs up to 5.4 dB, a handful of 1-byte errors | [measured] |
| Is ALLAN a good codec? | On flat UI art and logos, yes: at equal PSNR zlib(ALN) is 2 to 5.3x smaller than JPEG (4:4:4), with a lower maximum error on the logo, and 12 % smaller than lossless PNG on UI art at 53 to 66 dB at 256 x 256 (at 1024 x 1024 PNG is 10 % smaller). On natural textures, no: JPEG at the same PSNR is 3.4 to 5.5x smaller | [measured] |
| Is decoding event-sparse? | On flat UI art yes: events per row equal segments per row (85 of 256). On textures no with the plain ridge: 245 to 256 of 256. The event-aware ridge (3.3) is a dial down to the segment count (marble: 247 to 149 events per row for 0.43 dB, or to 124 for the full 0.59 dB) | [measured] |
| Does X4 (learned detail above the source resolution) work? | It is learned and transfers across seeds (within 0.04 dB of an oracle fitted to the test image), but it beats the engine's free bilinear magnification only on the PBR set; it loses 1.3 to 5.5 dB on smooth textures, because ALLAN is nearest-neighbour in y | [measured] |
| What would fix the vertical weakness? | Separable 2D liquid states (vertical passes, D = 4N + 1): +2.1 dB on the SDF logo, +1.3 dB on wood; X4 then beats bilinear on PBR by 1.6 dB, still loses on smooth textures | [measured], proposal outside format v1 |

## 1. What was built and how to run it

| File | What it is |
|---|---|
| `tools/liquid_targets.py` | Deterministic procedural targets: flat UI art with pixel-font text, SDF logo with soft shadow, marble, wood rings, water caustics, an 8-channel PBR set (albedo RGB, normal XY from a height field, roughness, metalness, AO). lowbias32 hashing (as `MyMath.hash2`), value noise, polynomial sines (as `MyMath.dsinTurns`); no libm |
| `tools/liquid_train.py` | Offline builder: shell-byte quadtree, Walsh reservoir, exact float64 replica of the Luau step order, numpy ridge and the exact integer path, ALN export, a pure-Python scalar reference renderer, sweeps, X4, the 2D proposal, golden vectors |
| `src/LiquidLearn.luau` | Server learning: quadtree builder, ALN codec, exact states, S1/S3 exact statistics (plain, band, event and naive modes), Cholesky ridge, S4 messages and ledger, S5 gain search, S6 online updates, a time-sliced trainer, `renderExact` |
| `tests/liquid_learn.test.luau` | Golden vectors and cross-checks (section 8), merge-order proofs by test, second-limb test |
| `bench/liquid_learn.luau` | S2 at 1024 x 1024 in both runtimes, slicing, S5 cost, jitter floor |
| `assets/liquid/golden.luau`, `golden_*.aln`, `golden_*.pixels` | Three exported models with their exact pixels |
| `assets/liquid/results/*.json` | Raw results of every table here; `assets/liquid/previews/*.png` target, render and 8x error |

```
python3 tools/liquid_train.py golden            # golden vectors and cross-check data
python3 tools/liquid_train.py sweep --size 256   # quality table (about 70 s)
python3 tools/liquid_train.py headline --size 1024
python3 tools/liquid_train.py x4 --size 256
python3 tools/liquid_train.py twod --size 256
luau tests/liquid_learn.test.luau ; luau --codegen tests/liquid_learn.test.luau
luau --codegen bench/liquid_learn.luau [-a quick]
```

## 2. The training contract

### 2.1 Model arithmetic

Exactly the header of `src/Liquid.luau`: `u_t = byte_t / 255`; `b_i = beta_i` then `b_i = b_i + B[i*I+t] * u_t` in index order; `k_i = clamp(kBase_i + log2(leafSide) + r, 0, K - 1)`, `g_i = 2^-k_i` from an exact table; both passes start at rest (`h = b` of the first pixel) and step `h = h + (b - h) * g`; `z_m = d_m`, then the forward terms, then the backward terms, in index order; `byte = clamp(floor(z + 0.5), 0, 255)`. The Python replica vectorises only across rows and pixels (elementwise IEEE operations, never a reduction), so its states and pixels are the Luau bits [tested: the scalar reference, the vectorised renderer, `LiquidLearn.renderExact`, a minimal loader inside the test and `Liquid.reference` produce identical bytes on all golden models].

### 2.2 Quadtree builder

Root side `S` = smallest power of two at least `max(width, height)`. A node splits iff its depth is below `maxDepth`, it covers at least one pixel, and `max_c max(max_c - mean_c, mean_c - min_c) > theta`, with the integer mean `(2 sum + count) // (2 count)`. Leaf bytes are the means (I = number of target channels). Python and Luau produce identical bytes [tested].

### 2.3 Reservoir: Walsh projections and instant neurons

Neuron `i` reads Walsh projection `p(i)` of the leaf bytes: `b = 1/2 + (1/I) sum_t H[p][t] (u_t - 1/2)`, so `b` is in [0, 1] and `B` rows are signed `1/I` (exact for I = 4 and 8). Default `p(i) = i mod I`, `kBase` from the scale list `[INSTANT, 0, -2, 2, -4, 4, 1, -1]` by `i div I`, `INSTANT = -64`.

**Finding: spec v1 needs instant neurons.** With `k = kBase + log2(leafSide)` the time constant follows the leaf size, not the edge. A sharp edge that falls on a quadtree node boundary between two large flat leaves (the common case for pixel-aligned UI art) becomes a long exponential smear into the large leaf. The first reservoir built here (no instant neurons) lost 4.4 dB to its own plain quadtree on UI art (62.0 against 66.4 dB) [measured]. A neuron with `kBase <= -K - r` has `k = 0`, `g = 1`, so `h = b` (exactly from the second pixel of a segment on, within one ulp at its first pixel): the plain quadtree becomes representable by the readout, and slow neurons only add smoothing where it pays. With one instant neuron per projection the readout is at most 0.09 dB worse than the plain quadtree on the 87 of the 90 configurations of section 3 whose quadtree PSNR is below 70 dB, and up to 1.67 dB better; only near-lossless UI art (theta 2, 93 dB) loses more (5.4 dB, maximum error 2 instead of 1), because the ridge term keeps the readout from reproducing the quadtree exactly [measured]. Smoothing across leaf boundaries can raise the maximum error while lowering the mean (wood, theta 4, N = 16: maximum 10 against the quadtree's 4). This needs no format change (kBase is a stored f64).

A true liquid gain (time constant gated by the size of the input step at a segment boundary, the recursive-bilateral cell of LIQUID.md section 8) was also measured. A gated reservoir of 9 neurons matched, but did not beat, the ungated default reservoir of 16 neurons (wood 47.78 against 47.80 dB at theta 4 and 36.31 against 36.32 at theta 16; marble 35.42 against 35.47 at theta 16), kept every pixel active, and would need a format extension. Not adopted [measured].

### 2.4 Training statistics and solve (S1, S3)

Per sampled pixel the features are `s = (qf_1..qf_N, qb_1..qb_N, 32767)`, `q = floor(h * 32767 + 0.5)`, `D = 2N + 1`, and the targets `y_m` are bytes. The statistics are the exact integers `G = sum s s^T` (upper triangle), `P = sum s y^T`, `YY_m = sum y_m^2` and the sample count, each held as `hi * 2^32 + lo`. The readout solves `(G + lambda I') w = P` by Cholesky in a fixed order, `lambda = 1e-7 * mean(diag G)` over the non-constant features, then `C = 32767 w`. Python (`cholesky_solve_exact`) and Luau (`LiquidLearn.solve`) perform the same IEEE operations in the same order; there is no fused multiply-add because no source expression asks for one and Luau codegen never fuses separate MUL and ADD (docs/RUNTIME_AUDIT.md 6.5).

## 3. Offline quality, 256 x 256, seed 1 [measured]

### 3.1 Quality, events and bytes

`theta` in byte units; N = 8 (16 for the 8-channel PBR set); PSNR over all channels; max err in bytes; events per row from the T2 skip rule at epsilon 0.5 (a pixel is filled with its segment's quantised limit colour when `sum_i |Cf_mi||hf_i - b_i| + |Cb_mi||hb_i - b_i| <= epsilon` for every channel; events = evaluated pixels + one per filled span), amortised over quadtree bands; bytes of the ALN file, of zlib(ALN), of a lossless optimised PNG of the target, and of raw RGBA8.

| target | theta | leaves | PSNR exact | PSNR eps 0.5 | max err | quadtree PSNR | gain | events/row (amortised) | segments/row | ALN | zlib(ALN) | PNG | RGBA8 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ui_flat | 4 | 14704 | 66.41 | 66.41 | 4 | 66.44 | -0.02 | 85 (73) | 85 | 45863 | 8583 | 9740 | 262144 |
| ui_flat | 8 | 14341 | 53.63 | 53.63 | 8 | 53.63 | 0.00 | 89 (77) | 84 | 44773 | 8590 | 9740 | 262144 |
| ui_flat | 16 | 13285 | 35.91 | 35.91 | 52 | 35.63 | +0.28 | 139 (102) | 75 | 41456 | 8289 | 9740 | 262144 |
| sdf_logo | 4 | 6175 | 45.64 | 45.64 | 6 | 45.37 | +0.27 | 168 (144) | 48 | 19913 | 11272 | 16477 | 262144 |
| sdf_logo | 8 | 4900 | 43.02 | 43.01 | 12 | 42.44 | +0.58 | 185 (139) | 40 | 15880 | 9194 | 16477 | 262144 |
| sdf_logo | 16 | 4447 | 40.77 | 40.77 | 23 | 40.31 | +0.46 | 186 (137) | 36 | 14462 | 8431 | 16477 | 262144 |
| marble | 4 | 32413 | 47.24 | 47.24 | 6 | 46.87 | +0.37 | 245 (245) | 154 | 99903 | 56726 | 72375 | 262144 |
| marble | 8 | 22645 | 41.26 | 41.25 | 10 | 40.67 | +0.59 | 247 (247) | 124 | 70408 | 42039 | 72375 | 262144 |
| marble | 16 | 11719 | 35.20 | 35.20 | 21 | 34.60 | +0.59 | 250 (250) | 89 | 37312 | 23249 | 72375 | 262144 |
| wood | 4 | 42865 | 47.33 | 47.31 | 9 | 46.13 | +1.20 | 254 (254) | 196 | 132019 | 57482 | 53287 | 262144 |
| wood | 8 | 23110 | 39.20 | 39.19 | 10 | 38.70 | +0.49 | 252 (252) | 142 | 72562 | 35761 | 53287 | 262144 |
| wood | 16 | 15562 | 35.43 | 35.43 | 18 | 34.81 | +0.63 | 253 (247) | 111 | 49209 | 25977 | 53287 | 262144 |
| caustics | 4 | 31162 | 45.67 | 45.66 | 7 | 45.06 | +0.61 | 255 (255) | 158 | 96456 | 55163 | 71161 | 262144 |
| caustics | 8 | 17839 | 39.60 | 39.60 | 12 | 38.99 | +0.61 | 255 (255) | 114 | 55980 | 34100 | 71161 | 262144 |
| caustics | 16 | 8020 | 34.53 | 34.53 | 20 | 34.01 | +0.52 | 255 (225) | 75 | 25925 | 16669 | 71161 | 262144 |
| pbr_stones | 4 | 36721 | 49.82 | 49.82 | 8 | 49.66 | +0.16 | 256 (256) | 179 | 299779 | 191429 | 207661 | 524288 |
| pbr_stones | 8 | 28372 | 45.55 | 45.55 | 11 | 45.37 | +0.18 | 256 (256) | 143 | 232133 | 152764 | 207661 | 524288 |
| pbr_stones | 16 | 25168 | 42.19 | 42.19 | 17 | 41.90 | +0.30 | 256 (256) | 123 | 206139 | 136710 | 207661 | 524288 |

The full grid (theta 2, 4, 8, 16, 32; N 4, 8, 16 or 8, 16, 24; epsilon 0, 0.25, 0.5, 1, 2) is in `assets/liquid/results/sweep256.json`.

**N and events.** At theta 8: sdf_logo N = 4 gives 42.42 dB at 45 events per row, N = 8 43.02 dB at 185, N = 16 43.50 dB at 230. ui_flat stays at 84 to 92 events for every N (the readout puts no weight on slow neurons). On textures every N keeps 227 to 256 events per row. More neurons buy 0.0 to 0.8 dB; the events are bought by the weight the readout places on slow neurons, so N is a quality-for-cost knob only on logos [measured].

**Epsilon.** From epsilon 0 to 2 the PSNR changes by at most 0.51 dB (wood, theta 4, N = 4), and on near-lossless UI art it improves by up to 1.2 dB (the quantised limit colour of a converged span is closer to the target than the regularised transient). Events fall from 210 to 85 per row on ui_flat (any epsilon > 0 removes the converged spans), from 222 to 84 on sdf_logo theta 4, and on textures only from 256 to between 184 and 243 [measured].

### 3.2 Against JPEG at matched quality

The smallest JPEG (PIL, 4:4:4, optimised) whose PSNR reaches ALLAN's (N = 8, epsilon 0.5), from `assets/liquid/results/jpeg_vs_allan256.json` [measured]:

| target, theta | ALLAN PSNR / max err | zlib(ALN) | JPEG quality, bytes, max err | ratio |
|---|---|---|---|---|
| ui_flat, 4 | 66.41 dB / 4 | 8583 | no JPEG quality reaches 66.4 dB | ALLAN only |
| ui_flat, 8 | 53.63 dB / 8 | 8590 | q100, 45950, 4 | ALLAN 5.3x smaller |
| ui_flat, 16 | 35.91 dB / 52 | 8289 | q84, 16747, 57 | ALLAN 2.0x smaller |
| sdf_logo, 4 | 45.64 dB / 6 | 11272 | q97, 25864, 13 | ALLAN 2.3x smaller |
| sdf_logo, 8 | 43.01 dB / 12 | 9194 | q95, 21025, 26 | ALLAN 2.3x smaller |
| sdf_logo, 16 | 40.77 dB / 23 | 8431 | q92, 16450, 34 | ALLAN 2.0x smaller |
| marble, 8 | 41.25 dB / 10 | 42039 | q64, 7884, 14 | JPEG 5.3x smaller |
| wood, 8 | 39.19 dB / 10 | 35761 | q68, 10501, 20 | JPEG 3.4x smaller |
| caustics, 8 | 39.60 dB / 12 | 34100 | q52, 6196, 36 | JPEG 5.5x smaller |

(Same trend at theta 4 and 16 for the textures: JPEG 1.8 to 5.2x smaller.) ALLAN's maximum error is lower than JPEG's in 12 of the 14 rows where both exist.

### 3.3 Events are a training choice: the event-aware ridge [measured]

The T2 skip rule keeps a pixel active while `sum_i |C_i||h_i - b_i| > epsilon`, so the cost of decoding is set by how much weight the readout puts on slow neurons. A larger ridge on the slow neurons' features (`LiquidLearn.slowRidge(res, mult)`, `slow_ridge` in Python; instant neurons keep the plain ridge) is a continuous dial between ALLAN's smoothing and the plain quadtree (events = segments). 256 x 256, theta 8, N = 8 (16 for PBR), epsilon 0.5, `assets/liquid/results/event_aware256.json`:

| target | slow ridge x1 | x100 | x1e4 | x1e6 (= quadtree) |
|---|---|---|---|---|
| sdf_logo | 43.01 dB, 185 events | 42.89 dB, 163 | 42.47 dB, **55** | 42.44 dB, 40 |
| marble | 41.25 dB, 247 | 41.25 dB, 226 | 40.82 dB, 149 | 40.67 dB, 124 |
| wood | 39.19 dB, 252 | 39.19 dB, 249 | 38.82 dB, 200 | 38.70 dB, 142 |
| caustics | 39.60 dB, 255 | 39.59 dB, 251 | 39.40 dB, 222 | 38.99 dB, 114 |
| ui_flat (theta 16) | 35.91 dB, 139 | 35.91 dB, 125 | 35.72 dB, 94 | 35.63 dB, 74 |
| pbr_stones | 45.55 dB, 256 | 45.47 dB, 245 | 45.37 dB, 143 | 45.37 dB, 143 |

x100 is nearly free (at most 0.12 dB) and removes 1 to 12 % of the events; x1e4 removes 13 to 70 % for 0.18 to 0.54 dB. The dB that the liquid readout adds over its quadtree are paid for in events, at a roughly constant exchange rate; the server can choose the point per texture and per device class, and the Luau and Python solves give identical bytes for it [tested].

### 3.4 Verdict per target

- **ui_flat**: ALLAN's home ground. Events = segments, decode cost follows the edges, zlib(ALN) 8.6 kB against PNG 9.7 kB at 53 to 66 dB with max error 4 to 8. The liquid part adds nothing at small theta (the readout correctly ignores slow neurons) and +0.2 to +0.3 dB at large theta.
- **sdf_logo**: +0.3 to +0.6 dB over the quadtree at N = 8; zlib(ALN) 9.2 kB at 43 dB against 21 kB for JPEG at the same PSNR (with twice JPEG's accuracy in maximum error) and 16.5 kB for lossless PNG. The vertical gradient background is a staircase in y (section 6 removes most of it).
- **marble, wood, caustics**: +0.4 to +1.2 dB over the quadtree, but every pixel is an event, and JPEG at the same PSNR is 3.4 to 5.5x smaller. As a texture codec ALLAN loses; its value on textures is determinism (every client renders the same bits), multi-resolution rendering and server-side learning, not size.
- **pbr_stones**: +0.2 to +0.3 dB; normals are high-frequency, so the quadtree is dense and zlib(ALN) is within 10 % of PNG only at 42 dB. ALLAN loses.

## 4. 1024 x 1024 headline [measured]

theta 8, N = 8 (16 for PBR), seed 1, `python3 tools/liquid_train.py headline --size 1024` (2 min 22 s for all six targets); raw rows in `assets/liquid/results/headline1024.json`:

| target | N | leaves | PSNR exact | PSNR eps 0.5 | max err | quadtree PSNR | events/row eps 0.5 (amortised) | segments/row | ALN | zlib(ALN) | PNG | RGBA8 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ui_flat | 8 | 72058 | 58.09 | 58.09 | 8 | 58.10 | 159 (132) | 137 | 222877 | 27658 | 24857 | 4194304 |
| sdf_logo | 8 | 19324 | 43.29 | 43.28 | 51 | 42.61 | 679 (489) | 55 | 60452 | 28409 | 95920 | 4194304 |
| marble | 8 | 66910 | 41.33 | 41.33 | 12 | 40.49 | 971 (581) | 196 | 212506 | 117424 | 543574 | 4194304 |
| wood | 8 | 72658 | 40.97 | 40.96 | 9 | 40.06 | 931 (553) | 235 | 230683 | 99426 | 420068 | 4194304 |
| caustics | 8 | 47956 | 41.14 | 41.14 | 13 | 40.08 | 1022 (581) | 172 | 152492 | 85793 | 511184 | 4194304 |
| pbr_stones | 16 | 229462 | 47.36 | 47.36 | 10 | 46.86 | 1020 (1020) | 309 | 1853259 | 1087305 | 1330823 | 8388608 |

At 1024 the readout gains more over its quadtree than at 256 (+0.7 to +1.1 dB on the logo and the textures, +0.5 dB on PBR), because the content is smoother per pixel. UI art stays event-sparse (159 events per row of 1024, close to its 137 segments), but lossless PNG is now 10 % smaller than zlib(ALN): large flat areas compress better as runs than as leaves. Textures evaluate 91 to 100 % of their pixels per rendered row; band reuse (rows of one band are copies) brings the amortised cost to 54 to 57 %. The logo's maximum error of 51 was located: it sits inside a 32-pixel leaf that touches a sharp gold-to-dark edge with no shell on its side, where the backward pass enters the leaf from the dark side and slow neurons carry the dark colour into it (the effect of 2.3, reduced but not removed by instant neurons). 49 of 1,048,576 pixels have an error above 20.

## 5. X4: learned detail above the source resolution [measured]

The source is the 2x box-downsampled image (128 x 128); leaves come from the source (theta 4); ALLAN renders at render scale 2 (r = 1: every leaf twice as wide, k + 1). The readout is trained on seed 1 against the full-resolution truth and tested on seed 2. The detail is **learned, not recovered**: it is the readout's prediction of what a 2x image of this family looks like.

| target | nearest | bilinear | quadtree nearest | ALLAN trained at source res | **ALLAN X4 (learned)** | oracle (fitted on the test image) |
|---|---|---|---|---|---|---|
| ui_flat | 22.41 | 22.52 | 22.41 | 22.41 | 22.43 | 22.43 |
| sdf_logo | 29.08 | 30.44 | 28.97 | 28.93 | 29.08 | 29.08 |
| marble | 33.45 | 39.41 | 33.31 | 33.67 | 33.91 | 33.91 |
| wood | 32.76 | 36.04 | 32.70 | 32.78 | 32.95 | 32.95 |
| caustics | 35.09 | 39.36 | 34.80 | 35.19 | 35.40 | 35.41 |
| pbr_stones | 25.05 | 25.94 | 25.04 | 25.13 | 26.08 | 26.12 |

What it buys: +0.15 to +0.95 dB over the same model trained at the source resolution, and the learned readout transfers across seeds (within 0.04 dB of the oracle), so a family-level readout can be trained once on the server and reused. Where it loses: bilinear magnification, which the engine does for free on the GPU, is 1.3 to 5.5 dB better on the logo and on smooth textures, because ALLAN is nearest-neighbour in y (rows of one leaf band are identical). On PBR ALLAN X4 beats bilinear by 0.14 dB. ui_flat is lost at the source resolution (pixel-font glyphs are 1 to 2 source pixels) for every method.

## 6. Proposal measured: ALLAN-2D (separable liquid states) [measured; outside format v1]

LIQUID.md open point 1 (vertical smoothness). The same cells also run down every column over the leaves the column crosses (same b, same gains), and the readout sees `(hf, hb, vf, vb, 1)`, D = 4N + 1. At 256 x 256, theta 8, N = 8 (16 for PBR):

| target | quadtree | ALLAN (rows) | ALLAN-2D | X4 rows | X4 2D | X4 bilinear |
|---|---|---|---|---|---|---|
| ui_flat | 53.63 | 53.63 | 53.64 | 22.43 | 22.47 | 22.52 |
| sdf_logo | 42.44 | 43.02 | **45.12** | 29.08 | 29.25 | 30.44 |
| marble | 40.67 | 41.26 | 41.62 | 33.91 | 34.34 | 39.41 |
| wood | 38.70 | 39.20 | **40.46** | 32.95 | 33.63 | 36.04 |
| caustics | 38.99 | 39.60 | 39.98 | 35.40 | 35.70 | 39.36 |
| pbr_stones | 45.37 | 45.55 | 45.77 | 26.08 | **27.57** | 25.94 |

It doubles the state cost and quadruples the Gram cost, and needs a format version 2 plus a vertical pass in the renderer. Recommended only for content with vertical gradients (logos, wood) and for PBR upscaling.

## 7. Training on the server (S1 to S6)

### 7.1 S3: exactness, proved

**Bounds.** For a Walsh reservoir `b` is in [0, 1]. The float step is monotone toward `b` and never overshoots it for `g <= 1/2` (`h + fl(b - h) * g` lies between `h` and `b` because rounding is monotone and `b` is representable); for `g = 1` the first step lands within one ulp of `b` and the next is exact (Sterbenz). So `h` stays in [0, 1] up to one ulp and `q = floor(h * 32767 + 0.5)` is in [0, 32767] **[proved]**. Every feature product is below 2^30, every `q * y` below 2^23, every `y^2` below 2^16.

**Accumulation.** After a normalisation every `lo` is in [0, 2^32). Before each block of work the accumulator normalises if the pending sample weight plus the block's weight would exceed 2^22, and no block carries more than 2^22 of weight. So between normalisations `lo < 2^32 + 2^22 * 2^30 < 2^53`, and every partial sum inside a block (`sum_k w_k f_i f_j <= 2^22 * 2^30`) is below 2^53. All additions are exact integer additions in a double. Normalisation `c = floor(lo / 2^32)`, `lo = lo - c * 2^32`, `hi = hi + c` is exact (division by a power of two). A single double holds `2^53 / 2^30 = 2^23` worst-case samples (LIQUID.md S3); the two limbs hold values up to 2^85, i.e. 2^55 worst-case samples **[proved]**. The test drives 2^24 samples of the largest feature, so that `G[1][1] = 2^24 * 32767^2 > 2^53`, and checks the exact limbs **[tested]**.

**Order freedom.** Exact integer addition is associative and commutative and the canonical form `(hi, lo)` with `0 <= lo < 2^32` is a function of the integer alone, so statistics do not depend on the order of pixels, rows, bands, slices or servers **[proved]**. The plain, band, event, naive and sliced paths give identical integers **[tested in every run and asserted in the benchmark]**.

### 7.2 S1, S2: how the Gram is computed, and what it costs

Rows of one quadtree band share their state vectors, so with `w(x)` the number of sampled pixels in column `x` of the band and `Y_m(x)` their target sum, the band contributes `G += sum_x w(x) s(x) s(x)^T`, `P += sum_x s(x) Y(x)^T`: one row of products per band instead of one per pixel, the same integers **[proved: same multiset of samples, exact arithmetic]**. On top of that:

- **inner-product form with 2 x 4 register blocking**: each `G[i][j]` is one accumulator in a register over the band's terms, two rows against four columns share each load (2x faster than one outer product per pixel in both runtimes);
- **exact column dedupe**: an instant neuron's forward and backward features are bit-identical almost everywhere; identical columns are detected exactly per call and multiplied once (1.4x native, 1.1 to 1.3x interpreted, A/B in one process);
- **identity terms**: with every column sampled the band itself is the term list (no copy);
- **event mode**: consecutive columns with identical feature vectors merge into one weighted term. On textures runs are rare and event mode is slower than plain mode; use it for flat art.

Measured with `bench/liquid_learn.luau` at 1024 x 1024, N = 8 (D = 17), M = 3, theta 8, on this repository's x64 VM (2.1 GHz Xeon, 4 shared cores), three runs per runtime, minimum per key; raw values in `assets/liquid/results/bench_learn_x64.json` **[measured]**:

| Path | flat UI art, native | interpreted | marble, native | interpreted |
|---|---|---|---|---|
| Quadtree build | 81 ms | 295 ms | 100 ms | 264 ms |
| States of every pixel (the floor under every mode) | 75 ms | 330 ms | 108 ms | 448 ms |
| **Naive S2** (LIQUID.md cost model: one outer product per pixel), every pixel | 1482 ms (1413 ns/sample) | 4553 ms | 1459 ms (1391 ns/sample) | 4560 ms |
| Naive S2, every fourth pixel | 387 ms | 1035 ms | 461 ms | 1144 ms |
| **Band path**, every pixel | **259 ms** (247 ns/sample) | **1091 ms** | **422 ms** (402 ns/sample) | **1495 ms** |
| Band path, every fourth pixel | 142 ms | 577 ms | 207 ms | 895 ms |
| Event mode, every pixel | 256 ms | 1068 ms | 477 ms | 1824 ms |
| Ridge solve, D = 17 | 21 us | 54 us | 19 us | 54 us |
| Reference render (every pixel stepped) | 182 ms | 649 ms | 254 ms | 827 ms |

(1024 x 1024: flat UI art has 51,844 leaves and 118 segments per row, marble 69,610 leaves and 200 segments per row.) Every path produced the same integers as the naive path; the benchmark asserts it.

**S2 verdict.** LIQUID.md estimated 0.7 s interpreted and 0.2 s native per million pixels for one outer product per pixel. Measured, that method costs 4.55 to 4.56 s and 1.46 to 1.48 s: the estimate is 6.5x (interpreted) and 7.4x (native) optimistic, because a native table read-modify-write costs about 3 ns, not one cycle. The band path brings it to 1.09 to 1.50 s and 0.26 to 0.42 s, 1.3 to 2.1x the estimate. Sampling every fourth pixel does not divide the cost by four (0.58 to 0.90 s and 0.14 to 0.21 s), because every pixel must still be stepped to know the states (the floor row); interleaving four neurons per pass already halved that floor natively (from 132 to 142 ms to 75 to 108 ms, bits unchanged).

### 7.3 Time slicing on Heartbeat

`LiquidLearn.newTrainer` / `LiquidLearn.step(trainer, budget)` run bounded units (a band's segments; the states of two neurons; clearing the band; four rows of targets; 256 columns of terms; 32 terms of Gram products) until the budget is spent, so a slice overshoots by at most one unit. The final statistics equal one `accumulate` call bit for bit **[tested with a fake clock forcing one unit per slice]**.

Real clock, 1.5 ms budget, 1024 x 1024, three runs per runtime; value of the best run, worst run in brackets **[measured]**:

| Mode | native p99 | native max | native slices over 2 ms | interpreted p99 | interpreted max | interpreted over 2 ms |
|---|---|---|---|---|---|---|
| flat, every pixel | 1.60 [1.61] ms | 1.77 [2.52] ms | 0 [2] of about 180 | 1.87 [2.00] ms | 1.99 [2.25] ms | 0 [5] of about 580 |
| flat, every fourth pixel | 1.56 [1.70] ms | 1.59 [3.24] ms | 0 [1] of about 115 | 1.65 [1.70] ms | 1.95 [2.27] ms | 0 [1] of about 380 |
| flat, event mode | 1.59 [1.65] ms | 1.61 [1.99] ms | 0 [0] of about 230 | 1.98 [2.13] ms | 2.08 [5.47] ms | 4 [18] of about 650 |
| marble, every pixel | 1.56 [3.03] ms | 1.60 [6.51] ms | 0 [5] of about 360 | 1.69 [1.84] ms | 1.71 [3.04] ms | 0 [6] of about 970 |
| marble, every fourth pixel | 1.66 [2.24] ms | 1.92 [3.40] ms | 0 [4] of about 225 | 1.61 [2.01] ms | 1.80 [6.17] ms | 0 [10] of about 675 |
| marble, event mode | 1.58 [1.91] ms | 2.38 [3.37] ms | 1 [3] of about 410 | 1.75 [1.78] ms | 2.77 [3.88] ms | 2 [4] of about 1270 |

Per-unit profiling explains the tail. The largest units by mean are four rows of targets (0.06 ms native, 0.20 to 0.28 ms interpreted) and the states of two neurons (0.04 and 0.11 ms); a Gram unit averages 0.01 to 0.05 ms. The multi-millisecond maxima are sporadic outliers of those same units (a Gram unit with mean 0.012 ms peaked at 2.3 ms), and the benchmark's jitter probe, a fixed 20 us workload, peaked at up to 3.9 ms natively and 1.8 ms interpreted in the same runs: preemption on a shared 4-core VM, not work. **Verdict:** with a 1.5 ms budget, the best of three runs keeps 99 % of slices under 1.66 ms natively and 1.98 ms interpreted, with at most 1 (native) and 4 (interpreted) slices above 2 ms; noisy runs (the brackets) show the same unit work stretched by preemption. A 1.0 ms budget (marble, three runs, `assets/liquid/results/slice_budget1024.json`) gives a native p99 of 1.05 to 1.64 ms; interpreted, the p99 was 1.28 to 1.36 ms in four of six run-modes and 2.39 to 2.89 ms in two noisy ones, so on this VM the interpreted tail is set by preemption rather than by the budget [measured]. With one 1.5 ms slice per Heartbeat at 60 Hz (9 % of a frame), a 1024 x 1024 texture trains in 93 to 428 frames natively (1.6 to 7.1 s of wall time, depending on mode and content) and 303 to 1336 frames interpreted (5 to 22 s).

### 7.4 S4: federated learning across servers

**Messages.** Cumulative statistics are packed as base64 strings of at most 1000 characters (750 raw bytes; MessagingService allows 1 kB per message, PUBLIC CONTRACT, creator-docs `MessagingService.yaml`): magic `ALS`, version, a fingerprint of everything that must agree (reservoir bytes, N, I, K, M, quantisation scale), sender id, sequence number, chunk index and count, first entry and entry count, then `varint(hi) varint(lo)` per entry. N = 8, M = 3 (E = 208 entries) fits in 3 messages of at most 1000 characters for a 1024 x 1024 texture (measured on both benchmark textures); the 8-channel PBR set with N = 16 (D = 33, E = 834 entries) needs 9 messages (6,339 raw bytes) [measured, `assets/liquid/results/messages1024.json`]. The DataStore value (4,194,304 characters per key) is the same strings joined by newlines.

**Ledger: a CRDT.** Each sender owns one slot holding its latest cumulative statistics; merging keeps the higher sequence per sender. Max per slot is idempotent, commutative and associative, so the ledger is a state-based CRDT (a G-Counter whose slots are vectors), and its total is the exact integer sum of the slots. Delivery is best effort and not guaranteed (creator-docs): duplicates are ignored (same chunk), stale sequences are ignored, chunks are buffered per sender until the newest sequence is complete, foreign fingerprints are rejected, finished senders can be folded into a base keeping only their final sequence number. Every server that has seen the same latest sequences computes the same integers, hence the same readout bytes **[proved]**. Tests: 24 shuffled deliveries with duplicates, stale snapshots and a foreign reservoir; 12 different groupings of `addStats`; a union of two partial ledgers; a fold; a DataStore round trip; all give the readout bytes of a single server that saw every row **[tested]**.

Throughput check: one publish of 3 messages per server per minute stays far below the documented limits (600 + 240 * players sent per server per minute; 40 + 80 * servers received per topic per minute).

### 7.5 S5: gain search on exact sub-Grams

Neurons are uncoupled: a neuron's state depends only on its own (projection, kBase) and the tree. So one accumulation of a **superset** reservoir holding every (projection, candidate kBase) pair contains, as exact integer sub-matrices, the statistics of every configuration; a trial is a sub-matrix copy, a D x D Cholesky solve on training rows and a validation score computed from statistics alone (`YY - 2 w.P + w^T G w`), with no rendering **[proved; tested: the sub-Gram solve gives the readout bytes of a direct accumulation]**. Measured on a 256 x 256 marble (3 projections x 10 candidates, superset D = 61): one superset accumulation takes 223 ms native (947 ms interpreted); the 179 coordinate-descent trials take 6 ms (16 ms) together, against 67 ms (205 ms) for **one** trial done the naive way (re-simulate, accumulate, solve), so the search is 52x (38x) cheaper than 179 naive trials. Validation error fell from 4.28 to 4.02 (6 %) **[measured]**.

### 7.6 S6: online updates

`addStats`, `subStats` (exact sliding windows) and `halveStats` (exact `floor(v / 2)` of every entry, deterministic forgetting) followed by a re-solve. The D = 17 solve takes 19 to 21 us native and 54 us interpreted, so re-solving after every new texture or player drawing costs less than a frame; recursive least squares is unnecessary (and would not be order-free) **[measured; tested: 2S halved is S, (A + B) - A is B]**.

## 8. Cross-checks and golden vectors

`python3 tools/liquid_train.py golden` builds three cases (sdf_logo 64 x 64 N = 6; ui_flat 64 x 64 N = 8; marble 64 x 64 at render scale 2 from 32 x 32 leaves, the X4 path) and writes `assets/liquid/golden.luau`. `tests/liquid_learn.test.luau` checks, in both runtimes:

| Check | Result |
|---|---|
| Luau quadtree bytes = Python quadtree bytes | identical [tested] |
| Luau statistics (stride 1 and stride 4) = Python integers | identical [tested] |
| Luau readout bytes = Python `cholesky_solve_exact` bytes, plain ridge and event-aware ridge (x1e4) | identical, so interpreter = native = Python [tested] |
| Plain, band, event, naive and time-sliced accumulation, and accumulation forced into sub-bands of three rows | identical integers [tested] |
| Statistics extracted from a superset reservoir (S5) against a direct accumulation of the same configuration | identical integers and readout bytes [tested] |
| Luau readout against the numpy float readout (LAPACK, unquantised states) | max \|z difference\| 0.0146, 0.0196 and 0.046 byte units, stated tolerance 0.1; the difference itself is bit-identical between Luau and Python [tested] |
| Luau-built model bytes = Python export | identical [tested] |
| Golden pixels (pure-Python scalar reference) through `LiquidLearn.renderExact`, through a minimal loader written inside the test, and through `src/Liquid.luau` (`Liquid.reference`) | identical [tested] |
| `Liquid.render` (the event renderer) at epsilon 0 and 0.5 on the golden models | max byte difference 0 and 1, within its T2 bound floor(epsilon + 1) [measured, reported by the test] |

## 9. Claims ledger

| Claim (docs/LIQUID.md) | Status after this build |
|---|---|
| L6 reservoir training by ridge regression | Built and working; needs instant neurons (2.3) [measured] |
| L9 federated exact learning | [proved] and [tested] (7.1, 7.4) |
| S1 sufficient statistics | Built; band and inner-product form (7.2) [proved, tested] |
| S2 cost: 0.7 s interpreted, 0.2 s native per million pixels | 6.5 to 7.4x optimistic for one outer product per pixel (4.56 s, 1.48 s); the band path reaches 1.09 to 1.50 s and 0.26 to 0.42 s; every fourth pixel 0.58 to 0.90 s and 0.14 to 0.21 s, not a quarter (7.2) [measured] |
| S3 exact accumulation, 2^23 samples, second limb | [proved] and [tested] at 2^24 samples (7.1) |
| S4 federated merge in 1 kB messages | Designed as a CRDT, [proved], [tested]; 3 messages for N = 8, M = 3 at 1024 x 1024 [measured] |
| S5 gain search by coordinate descent | Built on exact sub-Grams of one superset accumulation (7.5): 52x (native) and 38x (interpreted) cheaper than naive trials [proved, tested, measured] |
| S6 online adaptation | Add, subtract, halve, re-solve (7.6) [tested, measured] |
| X4 learned detail | Learned and transferable, but loses to bilinear on smooth content (5) [measured] |
| T6 "64 events per row" | Holds for flat UI art (85 of 256 at 256 x 256, 159 of 1024 at 1024); false for textures with the plain ridge (events about W), adjustable down to the segment count with the event-aware ridge (3.3) [measured] |
| Open point 1, vertical smoothness | ALLAN-2D measured (6); not in format v1 |
| Open point 4, quality ceiling | Section 3 and `results/sweep256.json` [measured] |
| Open point 5, server training time | 7.2 and 7.3 [measured] |
| (new) Event cost is a training choice | Event-aware ridge, 3.3 [measured, tested] |

## 10. Open issues

1. The quality of ALLAN is set mostly by the quadtree (theta); the liquid readout adds at most 1.7 dB. Learning the leaf bytes as well (the output is affine in the leaf bytes for a fixed tree, so they can be solved by sparse least squares) is the next lever [conjecture].
2. Event cost on textures is set by the weight on slow neurons; the event-aware ridge (3.3) is the dial. Folding predicted events into the S5 score (so the gain search chooses kBase for quality per event, not quality alone) is the next step [conjecture].
3. ALLAN-2D and the contrast-gated gain need a format version 2 and renderer support; both were measured here, neither is in format v1.
4. Roblox server timings will differ from this x64 VM. The benchmark uses only Luau and `os.clock`, so it can run in a server Script once its requires point at the modules; it has not been run inside Roblox here.
5. The golden check through `src/Liquid.luau` uses the renderer's current API (`decode`, `prepare`, `reference`, `render`); the test skips that part, and says so in its output, if the API changes.
6. LIQUID.md S4 counted 153 + 68 numbers per message set. The statistics here also carry `YY` and the sample count, which validation from statistics and exact merging need: 208 entries for N = 8, M = 3.
