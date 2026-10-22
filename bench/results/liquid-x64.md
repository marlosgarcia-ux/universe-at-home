# ALLAN renderer benchmark, x64

Produced by `bench/liquid.luau` (see its header) on a 2.1 GHz x64 VM with 4 cores shared with other agents, one core used. Every timing is the minimum of 3 runs (`-a 3`). Commands:

    /home/user/luau-lang/luau/build/luau --codegen bench/liquid.luau -a 3 "" "native O2"
    /home/user/luau-lang/luau/build/luau bench/liquid.luau -a 3 "" "interpreter O2"

Columns: "vs reference" divides the time of `Liquid.reference` (every pixel stepped) by the render time; "vs band-copied reference" divides the time of the reference that steps one row per band and copies the rest, which isolates what event rendering adds to row copying. "rows evaluated" counts row renders (a footprint crossing band boundaries at level > 0 evaluates one row per band); "rows deduplicated" are rows copied from an earlier row with an equal segment sequence. "events" are segments per evaluated row, "evals" closed-form footprint evaluations per evaluated row, "fill %" the share of evaluated pixels written by fill spans. "max diff vs reference" is the largest byte difference to the per-pixel reference (T2 allows 1 for epsilon < 1; epsilon = 0 is lossless).

Noise on this shared machine is visible: in one case (noise, fast reservoir, interpreter) the band-copied reference measured slower than the plain one, which it cannot be in CPU work. Read single cells as plus or minus 15 %.

Summary (default reservoir, epsilon 0.5, level 0):

| scene | leaves | rows evaluated (+ deduplicated) | events / row | native ms | interpreter ms | vs reference (native / interp) | lossless (epsilon 0) native / interp ms |
|---|---|---|---|---|---|---|---|
| flat UI | 32593 | 476 (+193) | 57.3 | 25.4 | 60.9 | 25.6x / 31.4x | 23.8 / 77.0 |
| SDF logo | 24952 | 778 (+48) | 52.7 | 26.6 | 87.6 | 25.1x / 21.8x | 26.3 / 90.1 |
| noise | 198949 | 880 (+0) | 428.4 | 189 | 563 | 4.2x / 3.8x | 190 / 630 |

## Native code generation (--codegen)

# ALLAN renderer benchmark (native O2), 1024x1024, minimum of 3 runs per timing

## flat UI: image 3.7 s, tree 0.3 s, 32593 leaves, 43457 nodes, 67 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 0.2 s; model vs source PSNR 53.77 dB (max err 9)
reference (every pixel stepped) 650.7 ms; reference with band copies 429.8 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 25.41 | 25.6x | 16.9x | 476 | 193 | 57.3 | 82.5 | 91.9 | 1 |
| 0 | 0 | box | 23.78 | 27.4x | 18.1x | 476 | 193 | 57.3 | 82.8 | 91.9 | 0 |
| 0.25 | 0 | box | 23.52 | 27.7x | 18.3x | 476 | 193 | 57.3 | 82.8 | 91.9 | 1 |
| 1 | 0 | box | 23.60 | 27.6x | 18.2x | 476 | 193 | 57.3 | 68.8 | 93.3 | 1 |
| 0.5 | 1 | box | 34.60 | 18.8x | - | 523 | 146 | 57.6 | 14.8 | 96.0 | - |
| 0.5 | 2 | box | 30.46 | 21.4x | - | 660 | 9 | 54.4 | 8.7 | 93.4 | - |
| 0.5 | 2 | point | 7.06 | 92.2x | - | 165 | 62 | 51.9 | 7.7 | 94.0 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.57 mean 0.027; point max 71.01 mean 2.159 (output units)
X2 (level 0 predicted from levels 1 and 2): 89.56 ms in all, of which 83.46 ms render the two coarse levels (prediction pass 6.10 ms); 97.6% of pixels exact, mean abs err 0.224, max err 68. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 40% (uniform 25%)
X3 endless tile at (1024, 0): 438.07 ms, rows evaluated 1017 (deduplicated 0), largest certificate 4.62e-08 output units
X3 endless tile at (512, 512): 481.96 ms, rows evaluated 2025 (deduplicated 3), largest certificate 5.9e-08 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 0.2 s; model vs source PSNR 53.73 dB (max err 12)
reference (every pixel stepped) 565.6 ms; reference with band copies 397.3 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 20.05 | 28.2x | 19.8x | 476 | 193 | 57.3 | 13.3 | 98.7 | 1 |
| 0 | 0 | box | 20.14 | 28.1x | 19.7x | 476 | 193 | 57.3 | 13.3 | 98.7 | 0 |
| 0.25 | 0 | box | 19.94 | 28.4x | 19.9x | 476 | 193 | 57.3 | 13.3 | 98.7 | 1 |
| 1 | 0 | box | 19.91 | 28.4x | 20.0x | 476 | 193 | 57.3 | 6.5 | 99.4 | 1 |
| 0.5 | 1 | box | 29.98 | 18.9x | - | 523 | 146 | 57.6 | 7.1 | 97.5 | - |
| 0.5 | 2 | box | 25.78 | 21.9x | - | 660 | 9 | 54.4 | 4.9 | 94.8 | - |
| 0.5 | 2 | point | 6.03 | 93.8x | - | 165 | 62 | 51.9 | 4.5 | 95.2 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.51 mean 0.020; point max 71.01 mean 2.152 (output units)
X2 (level 0 predicted from levels 1 and 2): 87.54 ms in all, of which 59.06 ms render the two coarse levels (prediction pass 28.48 ms); 97.6% of pixels exact, mean abs err 0.223, max err 68. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 43% (uniform 25%)
X3 endless tile at (1024, 0): 203.10 ms, rows evaluated 1007 (deduplicated 0), largest certificate 3.2e-10 output units
X3 endless tile at (512, 512): 364.52 ms, rows evaluated 1978 (deduplicated 7), largest certificate 5.1e-10 output units

## SDF logo: image 0.6 s, tree 0.2 s, 24952 leaves, 33269 nodes, 627 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 0.2 s; model vs source PSNR 52.50 dB (max err 16)
reference (every pixel stepped) 666.6 ms; reference with band copies 530.3 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 26.59 | 25.1x | 19.9x | 778 | 48 | 52.7 | 100.2 | 90.2 | 1 |
| 0 | 0 | box | 26.32 | 25.3x | 20.1x | 778 | 48 | 52.7 | 103.5 | 89.9 | 0 |
| 0.25 | 0 | box | 24.65 | 27.0x | 21.5x | 778 | 48 | 52.7 | 103.5 | 89.9 | 1 |
| 1 | 0 | box | 22.18 | 30.0x | 23.9x | 778 | 48 | 52.7 | 57.0 | 94.4 | 1 |
| 0.5 | 1 | box | 47.83 | 13.9x | - | 822 | 4 | 51.4 | 33.3 | 92.2 | - |
| 0.5 | 2 | box | 32.31 | 20.6x | - | 823 | 3 | 51.4 | 16.2 | 90.9 | - |
| 0.5 | 2 | point | 7.70 | 86.6x | - | 209 | 3 | 50.7 | 15.7 | 91.1 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.64 mean 0.052; point max 102.24 mean 0.624 (output units)
X2 (level 0 predicted from levels 1 and 2): 90.00 ms in all, of which 68.77 ms render the two coarse levels (prediction pass 21.23 ms); 97.9% of pixels exact, mean abs err 0.329, max err 76. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 41% (uniform 25%)
X3 endless tile at (1024, 0): 355.28 ms, rows evaluated 1024 (deduplicated 0), largest certificate 1.83e-08 output units
X3 endless tile at (512, 512): 523.07 ms, rows evaluated 2047 (deduplicated 0), largest certificate 4.62e-08 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 0.2 s; model vs source PSNR 52.90 dB (max err 22)
reference (every pixel stepped) 540.7 ms; reference with band copies 464.9 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 27.56 | 19.6x | 16.9x | 778 | 48 | 52.7 | 27.0 | 97.4 | 1 |
| 0 | 0 | box | 20.12 | 26.9x | 23.1x | 778 | 48 | 52.7 | 27.7 | 97.3 | 0 |
| 0.25 | 0 | box | 19.16 | 28.2x | 24.3x | 778 | 48 | 52.7 | 27.7 | 97.3 | 1 |
| 1 | 0 | box | 18.67 | 29.0x | 24.9x | 778 | 48 | 52.7 | 11.1 | 98.9 | 1 |
| 0.5 | 1 | box | 30.52 | 17.7x | - | 822 | 4 | 51.4 | 13.1 | 96.2 | - |
| 0.5 | 2 | box | 19.94 | 27.1x | - | 823 | 3 | 51.4 | 6.4 | 94.7 | - |
| 0.5 | 2 | point | 4.63 | 116.8x | - | 209 | 3 | 50.7 | 6.3 | 94.8 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.58 mean 0.028; point max 102.24 mean 0.600 (output units)
X2 (level 0 predicted from levels 1 and 2): 72.14 ms in all, of which 58.61 ms render the two coarse levels (prediction pass 13.53 ms); 97.9% of pixels exact, mean abs err 0.329, max err 76. Refining 10% of rows in discrepancy order removes 20% of the error (uniform rows: 10%); 25%: 41% (uniform 25%)
X3 endless tile at (1024, 0): 199.09 ms, rows evaluated 1024 (deduplicated 0), largest certificate 3.46e-08 output units
X3 endless tile at (512, 512): 254.76 ms, rows evaluated 2038 (deduplicated 0), largest certificate 5.79e-08 output units

## noise: image 2.4 s, tree 0.3 s, 198949 leaves, 265265 nodes, 15760 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 0.3 s; model vs source PSNR 39.99 dB (max err 11)
reference (every pixel stepped) 792.4 ms; reference with band copies 690.0 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 189.25 | 4.2x | 3.6x | 880 | 0 | 428.4 | 1020.7 | 0.3 | 1 |
| 0 | 0 | box | 189.78 | 4.2x | 3.6x | 880 | 0 | 428.4 | 1020.8 | 0.3 | 0 |
| 0.25 | 0 | box | 181.48 | 4.4x | 3.8x | 880 | 0 | 428.4 | 1020.8 | 0.3 | 1 |
| 1 | 0 | box | 133.26 | 5.9x | 5.2x | 880 | 0 | 428.4 | 1020.3 | 0.4 | 1 |
| 0.5 | 1 | box | 228.40 | 3.5x | - | 880 | 0 | 428.4 | 492.8 | 3.4 | - |
| 0.5 | 2 | box | 175.17 | 4.5x | - | 880 | 0 | 428.4 | 82.2 | 0.8 | - |
| 0.5 | 2 | point | 71.48 | 11.1x | - | 256 | 0 | 426.9 | 83.3 | 0.8 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.88 mean 0.253; point max 12.14 mean 1.471 (output units)
X2 (level 0 predicted from levels 1 and 2): 589.80 ms in all, of which 549.87 ms render the two coarse levels (prediction pass 39.93 ms); 29.6% of pixels exact, mean abs err 0.642, max err 7. Refining 10% of rows in discrepancy order removes 10% of the error (uniform rows: 10%); 25%: 25% (uniform 25%)
X3 endless tile at (1024, 0): 533.51 ms, rows evaluated 910 (deduplicated 0), largest certificate 1.32e-09 output units
X3 endless tile at (512, 512): 858.57 ms, rows evaluated 1839 (deduplicated 0), largest certificate 1.32e-09 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 0.3 s; model vs source PSNR 40.23 dB (max err 8)
reference (every pixel stepped) 724.1 ms; reference with band copies 708.7 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 196.83 | 3.7x | 3.6x | 880 | 0 | 428.4 | 0.9 | 99.9 | 1 |
| 0 | 0 | box | 159.33 | 4.5x | 4.4x | 880 | 0 | 428.4 | 1.1 | 99.9 | 0 |
| 0.25 | 0 | box | 162.88 | 4.4x | 4.4x | 880 | 0 | 428.4 | 1.1 | 99.9 | 1 |
| 1 | 0 | box | 147.41 | 4.9x | 4.8x | 880 | 0 | 428.4 | 0.4 | 100.0 | 1 |
| 0.5 | 1 | box | 181.68 | 4.0x | - | 880 | 0 | 428.4 | 0.5 | 99.6 | - |
| 0.5 | 2 | box | 162.46 | 4.5x | - | 880 | 0 | 428.4 | 0.3 | 32.7 | - |
| 0.5 | 2 | point | 50.51 | 14.3x | - | 256 | 0 | 426.9 | 0.3 | 33.2 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.68 mean 0.200; point max 12.25 mean 1.404 (output units)
X2 (level 0 predicted from levels 1 and 2): 447.42 ms in all, of which 376.91 ms render the two coarse levels (prediction pass 70.51 ms); 35.8% of pixels exact, mean abs err 0.754, max err 7. Refining 10% of rows in discrepancy order removes 10% of the error (uniform rows: 10%); 25%: 25% (uniform 25%)
X3 endless tile at (1024, 0): 534.23 ms, rows evaluated 910 (deduplicated 0), largest certificate 0 output units
X3 endless tile at (512, 512): 868.39 ms, rows evaluated 1839 (deduplicated 0), largest certificate 0 output units

## Interpreter

# ALLAN renderer benchmark (interpreter O2), 1024x1024, minimum of 3 runs per timing

## flat UI: image 8.8 s, tree 0.5 s, 32593 leaves, 43457 nodes, 67 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 0.9 s; model vs source PSNR 53.77 dB (max err 9)
reference (every pixel stepped) 1910.6 ms; reference with band copies 1116.7 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 60.88 | 31.4x | 18.3x | 476 | 193 | 57.3 | 82.5 | 91.9 | 1 |
| 0 | 0 | box | 77.04 | 24.8x | 14.5x | 476 | 193 | 57.3 | 82.8 | 91.9 | 0 |
| 0.25 | 0 | box | 75.93 | 25.2x | 14.7x | 476 | 193 | 57.3 | 82.8 | 91.9 | 1 |
| 1 | 0 | box | 70.74 | 27.0x | 15.8x | 476 | 193 | 57.3 | 68.8 | 93.3 | 1 |
| 0.5 | 1 | box | 114.58 | 16.7x | - | 523 | 146 | 57.6 | 14.8 | 96.0 | - |
| 0.5 | 2 | box | 107.90 | 17.7x | - | 660 | 9 | 54.4 | 8.7 | 93.4 | - |
| 0.5 | 2 | point | 24.45 | 78.1x | - | 165 | 62 | 51.9 | 7.7 | 94.0 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.57 mean 0.027; point max 71.01 mean 2.159 (output units)
X2 (level 0 predicted from levels 1 and 2): 315.16 ms in all, of which 284.50 ms render the two coarse levels (prediction pass 30.66 ms); 97.6% of pixels exact, mean abs err 0.224, max err 68. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 40% (uniform 25%)
X3 endless tile at (1024, 0): 1278.12 ms, rows evaluated 1017 (deduplicated 0), largest certificate 4.62e-08 output units
X3 endless tile at (512, 512): 1580.48 ms, rows evaluated 2025 (deduplicated 3), largest certificate 5.9e-08 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 1.1 s; model vs source PSNR 53.73 dB (max err 12)
reference (every pixel stepped) 2049.9 ms; reference with band copies 1146.1 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 62.21 | 33.0x | 18.4x | 476 | 193 | 57.3 | 13.3 | 98.7 | 1 |
| 0 | 0 | box | 62.54 | 32.8x | 18.3x | 476 | 193 | 57.3 | 13.3 | 98.7 | 0 |
| 0.25 | 0 | box | 62.14 | 33.0x | 18.4x | 476 | 193 | 57.3 | 13.3 | 98.7 | 1 |
| 1 | 0 | box | 64.45 | 31.8x | 17.8x | 476 | 193 | 57.3 | 6.5 | 99.4 | 1 |
| 0.5 | 1 | box | 100.72 | 20.4x | - | 523 | 146 | 57.6 | 7.1 | 97.5 | - |
| 0.5 | 2 | box | 84.56 | 24.2x | - | 660 | 9 | 54.4 | 4.9 | 94.8 | - |
| 0.5 | 2 | point | 16.36 | 125.3x | - | 165 | 62 | 51.9 | 4.5 | 95.2 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.51 mean 0.020; point max 71.01 mean 2.152 (output units)
X2 (level 0 predicted from levels 1 and 2): 248.64 ms in all, of which 194.75 ms render the two coarse levels (prediction pass 53.89 ms); 97.6% of pixels exact, mean abs err 0.223, max err 68. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 43% (uniform 25%)
X3 endless tile at (1024, 0): 702.29 ms, rows evaluated 1007 (deduplicated 0), largest certificate 3.2e-10 output units
X3 endless tile at (512, 512): 1061.44 ms, rows evaluated 1978 (deduplicated 7), largest certificate 5.1e-10 output units

## SDF logo: image 2.0 s, tree 0.4 s, 24952 leaves, 33269 nodes, 627 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 0.9 s; model vs source PSNR 52.50 dB (max err 16)
reference (every pixel stepped) 1911.9 ms; reference with band copies 1529.4 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 87.59 | 21.8x | 17.5x | 778 | 48 | 52.7 | 100.2 | 90.2 | 1 |
| 0 | 0 | box | 90.08 | 21.2x | 17.0x | 778 | 48 | 52.7 | 103.5 | 89.9 | 0 |
| 0.25 | 0 | box | 91.70 | 20.8x | 16.7x | 778 | 48 | 52.7 | 103.5 | 89.9 | 1 |
| 1 | 0 | box | 98.19 | 19.5x | 15.6x | 778 | 48 | 52.7 | 57.0 | 94.4 | 1 |
| 0.5 | 1 | box | 152.00 | 12.6x | - | 822 | 4 | 51.4 | 33.3 | 92.2 | - |
| 0.5 | 2 | box | 120.30 | 15.9x | - | 823 | 3 | 51.4 | 16.2 | 90.9 | - |
| 0.5 | 2 | point | 26.94 | 71.0x | - | 209 | 3 | 50.7 | 15.7 | 91.1 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.64 mean 0.052; point max 102.24 mean 0.624 (output units)
X2 (level 0 predicted from levels 1 and 2): 305.52 ms in all, of which 254.49 ms render the two coarse levels (prediction pass 51.03 ms); 97.9% of pixels exact, mean abs err 0.329, max err 76. Refining 10% of rows in discrepancy order removes 19% of the error (uniform rows: 10%); 25%: 41% (uniform 25%)
X3 endless tile at (1024, 0): 1022.66 ms, rows evaluated 1024 (deduplicated 0), largest certificate 1.83e-08 output units
X3 endless tile at (512, 512): 1429.36 ms, rows evaluated 2047 (deduplicated 0), largest certificate 4.62e-08 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 0.9 s; model vs source PSNR 52.90 dB (max err 22)
reference (every pixel stepped) 1894.1 ms; reference with band copies 1447.5 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 85.24 | 22.2x | 17.0x | 778 | 48 | 52.7 | 27.0 | 97.4 | 1 |
| 0 | 0 | box | 87.35 | 21.7x | 16.6x | 778 | 48 | 52.7 | 27.7 | 97.3 | 0 |
| 0.25 | 0 | box | 88.65 | 21.4x | 16.3x | 778 | 48 | 52.7 | 27.7 | 97.3 | 1 |
| 1 | 0 | box | 84.62 | 22.4x | 17.1x | 778 | 48 | 52.7 | 11.1 | 98.9 | 1 |
| 0.5 | 1 | box | 144.12 | 13.1x | - | 822 | 4 | 51.4 | 13.1 | 96.2 | - |
| 0.5 | 2 | box | 98.77 | 19.2x | - | 823 | 3 | 51.4 | 6.4 | 94.7 | - |
| 0.5 | 2 | point | 21.43 | 88.4x | - | 209 | 3 | 50.7 | 6.3 | 94.8 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.58 mean 0.028; point max 102.24 mean 0.600 (output units)
X2 (level 0 predicted from levels 1 and 2): 292.26 ms in all, of which 232.56 ms render the two coarse levels (prediction pass 59.70 ms); 97.9% of pixels exact, mean abs err 0.329, max err 76. Refining 10% of rows in discrepancy order removes 20% of the error (uniform rows: 10%); 25%: 41% (uniform 25%)
X3 endless tile at (1024, 0): 782.52 ms, rows evaluated 1024 (deduplicated 0), largest certificate 3.46e-08 output units
X3 endless tile at (512, 512): 1004.43 ms, rows evaluated 2038 (deduplicated 0), largest certificate 5.79e-08 output units

## noise: image 12.0 s, tree 0.7 s, 198949 leaves, 265265 nodes, 15760 distinct leaf contents

### reservoir walsh[inst,0,-2] (N 8, K 16, 2 tracked groups): fit 1.0 s; model vs source PSNR 39.99 dB (max err 11)
reference (every pixel stepped) 2160.0 ms; reference with band copies 2005.4 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 563.06 | 3.8x | 3.6x | 880 | 0 | 428.4 | 1020.7 | 0.3 | 1 |
| 0 | 0 | box | 629.94 | 3.4x | 3.2x | 880 | 0 | 428.4 | 1020.8 | 0.3 | 0 |
| 0.25 | 0 | box | 576.07 | 3.7x | 3.5x | 880 | 0 | 428.4 | 1020.8 | 0.3 | 1 |
| 1 | 0 | box | 588.55 | 3.7x | 3.4x | 880 | 0 | 428.4 | 1020.3 | 0.4 | 1 |
| 0.5 | 1 | box | 1049.21 | 2.1x | - | 880 | 0 | 428.4 | 492.8 | 3.4 | - |
| 0.5 | 2 | box | 646.45 | 3.3x | - | 880 | 0 | 428.4 | 82.2 | 0.8 | - |
| 0.5 | 2 | point | 205.60 | 10.5x | - | 256 | 0 | 426.9 | 83.3 | 0.8 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.88 mean 0.253; point max 12.14 mean 1.471 (output units)
X2 (level 0 predicted from levels 1 and 2): 1974.57 ms in all, of which 1729.09 ms render the two coarse levels (prediction pass 245.47 ms); 29.6% of pixels exact, mean abs err 0.642, max err 7. Refining 10% of rows in discrepancy order removes 10% of the error (uniform rows: 10%); 25%: 25% (uniform 25%)
X3 endless tile at (1024, 0): 1425.97 ms, rows evaluated 910 (deduplicated 0), largest certificate 1.32e-09 output units
X3 endless tile at (512, 512): 1941.67 ms, rows evaluated 1839 (deduplicated 0), largest certificate 1.32e-09 output units

### reservoir walsh[inst,-2,-4] (N 8, K 16, 2 tracked groups): fit 0.9 s; model vs source PSNR 40.23 dB (max err 8)
reference (every pixel stepped) 2009.9 ms; reference with band copies 2258.0 ms

| epsilon | level | vertical | ms | vs reference | vs band-copied reference | rows evaluated | rows deduplicated | events (segments)/evaluated row | closed-form evals/evaluated row | fill % of evaluated px | max diff vs reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.5 | 0 | box | 421.22 | 4.8x | 5.4x | 880 | 0 | 428.4 | 0.9 | 99.9 | 1 |
| 0 | 0 | box | 402.25 | 5.0x | 5.6x | 880 | 0 | 428.4 | 1.1 | 99.9 | 0 |
| 0.25 | 0 | box | 372.45 | 5.4x | 6.1x | 880 | 0 | 428.4 | 1.1 | 99.9 | 1 |
| 1 | 0 | box | 430.85 | 4.7x | 5.2x | 880 | 0 | 428.4 | 0.4 | 100.0 | 1 |
| 0.5 | 1 | box | 510.47 | 3.9x | - | 880 | 0 | 428.4 | 0.5 | 99.6 | - |
| 0.5 | 2 | box | 475.97 | 4.2x | - | 880 | 0 | 428.4 | 0.3 | 32.7 | - |
| 0.5 | 2 | point | 127.76 | 15.7x | - | 256 | 0 | 426.9 | 0.3 | 33.2 | - |

vertical strategy at level 2 against the exact 2D box average of the reference: box max 0.68 mean 0.200; point max 12.25 mean 1.404 (output units)
X2 (level 0 predicted from levels 1 and 2): 1158.41 ms in all, of which 1135.20 ms render the two coarse levels (prediction pass 23.22 ms); 35.8% of pixels exact, mean abs err 0.754, max err 7. Refining 10% of rows in discrepancy order removes 10% of the error (uniform rows: 10%); 25%: 25% (uniform 25%)
X3 endless tile at (1024, 0): 1285.67 ms, rows evaluated 910 (deduplicated 0), largest certificate 0 output units
X3 endless tile at (512, 512): 2048.17 ms, rows evaluated 1839 (deduplicated 0), largest certificate 0 output units
