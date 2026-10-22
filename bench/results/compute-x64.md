Minimum of 3 interpreter runs and 3 native runs (`--codegen`), each value itself the minimum of 1 to 5 in-process repeats. Machine: Intel Xeon @ 2.10 GHz, 4 vCPU virtualised, shared with other agents, so absolute times swing by up to 4x between quiet and busy periods; the calibration row (a constant `writeu32` over 1024 x 1024; RUNTIME_AUDIT 6.6 measured 10.3 ms interpreted, 2.9 ms native) shows how fast the machine was. Times are ms per full 1024 x 1024 frame unless the row says otherwise.

| group | measurement | interp O2 | native O2 | unit |
|---|---|---|---|---|
| calibration | writeu32 constant, 1024^2 | 8.78 | 2.21 | ms |
| raster | bin 256 shapes into 64px tiles | 0.09 | 0.07 | ms |
| raster | quadtree render, 256 shapes, linear, leaf 4 | 106.21 | 31.98 | ms |
| raster | quadtree render, 256 shapes, linear, leaf 8 | 157.76 | 56.10 | ms |
| raster | brute force, 256 shapes, linear (16 rows x 64) | 60429.54 | 15906.52 | ms |
| raster | dirty update after moving 1 shape, linear | 1.69 | 0.49 | ms |
| raster | painter (bbox per shape, 8-bit RMW), linear | 653.21 | 144.20 | ms |
| raster | tiles of 64px finished in one 8 ms slice, linear | 9 | 46 | count |
| raster | quadtree render, 256 shapes, exact, leaf 4 | 131.00 | 43.89 | ms |
| raster | quadtree render, 256 shapes, exact, leaf 8 | 227.78 | 53.38 | ms |
| raster | brute force, 256 shapes, exact (16 rows x 64) | 80092.83 | 13851.93 | ms |
| raster | dirty update after moving 1 shape, exact | 2.18 | 0.60 | ms |
| raster | tiles of 64px finished in one 8 ms slice, exact | 6 | 26 | count |
| quality | circle R=2.5, linear | 15.26 | 15.26 | err255 |
| quality | circle R=2.5, exact | 0.32 | 0.32 | err255 |
| quality | circle R=20, linear | 10.63 | 10.63 | err255 |
| quality | circle R=20, exact | 0.50 | 0.50 | err255 |
| quality | star r=60, linear | 25.70 | 25.70 | err255 |
| quality | star r=60, exact | 0.50 | 0.50 | err255 |
| quality | star r=60, scanline exact area | 0.50 | 0.50 | err255 |
| quality | two triangles sharing an edge, separate layers (conflation) | 64.00 | 64.00 | err255 |
| quality | two triangles sharing an edge, one accumulator | 0.50 | 0.50 | err255 |
| quality | circle R=1.5, half-plane estimator, worst of 16 placements | 15.56 | 15.56 | err255 |
| quality | circle R=1.5, curvature-corrected estimator, worst of 16 placements | 3.83 | 3.83 | err255 |
| quality | circle R=2.5, half-plane estimator, worst of 16 placements | 10.04 | 10.04 | err255 |
| quality | circle R=2.5, curvature-corrected estimator, worst of 16 placements | 1.56 | 1.56 | err255 |
| quality | circle R=4, half-plane estimator, worst of 16 placements | 6.57 | 6.57 | err255 |
| quality | circle R=4, curvature-corrected estimator, worst of 16 placements | 0.80 | 0.80 | err255 |
| quality | circle R=8, half-plane estimator, worst of 16 placements | 3.62 | 3.62 | err255 |
| quality | circle R=8, curvature-corrected estimator, worst of 16 placements | 0.28 | 0.28 | err255 |
| quality | circle R=16, half-plane estimator, worst of 16 placements | 1.70 | 1.70 | err255 |
| quality | circle R=16, curvature-corrected estimator, worst of 16 placements | 0.18 | 0.18 | err255 |
| quality | SDF 64^2 magnified to 1024, circle R=300 | 27.16 | 27.16 | err255 |
| quality | SDF 128^2 magnified to 1024, circle R=300 | 6.72 | 6.72 | err255 |
| quality | SDF 256^2 magnified to 1024, circle R=300 | 1.60 | 1.60 | err255 |
| quality | SDF 512^2 magnified to 1024, circle R=300 | 0.32 | 0.32 | err255 |
| quality | SDF 256^2 magnified to 1024, sharp box corners | 77.98 | 77.98 | err255 |
| quality | SDF 512^2 magnified to 1024, sharp box corners | 33.47 | 33.47 | err255 |
| quality | circle R=80, 4x4 supersampling | 30.89 | 30.89 | err255 |
| quality | circle R=80, 16x16 supersampling | 4.43 | 4.43 | err255 |
| vector | 256 stars, scanline exact-area painter | 38.89 | 12.24 | ms |
| vector | 256 stars, SDF quadtree raster, linear, leaf 8 | 397.11 | 91.03 | ms |
| vector | 256 stars, SDF quadtree raster, exact, leaf 8 | 485.15 | 138.88 | ms |
| rows | disc R=300 exact coverage, direct per pixel | 70.30 | 25.37 | ms |
| rows | disc R=300, forward-differenced e = dx^2 + dy^2 | 67.27 | 25.19 | ms |
| rows | disc R=300, analytic spans (band only) | 1.97 | 1.12 | ms |
| distance | exact EDT (Felzenszwalb-Huttenlocher) | 172.94 | 43.66 | ms |
| distance | 8SSEDT (approximate) | 803.59 | 126.46 | ms |
| distance | jump flooding (approximate), 512^2 scaled x4 | 4127.09 | 731.53 | ms |
| distance | matte: signed EDT (2 transforms) + feathered alpha | 423.82 | 102.22 | ms |
| quality | jfa wrong pixels of 65536 (sparse seeds) | 7 | 7 | count |
| quality | jfa max distance error (sparse seeds) | 2.16 | 2.16 | px |
| quality | ssedt8 wrong pixels of 65536 (sparse seeds) | 0 | 0 | count |
| quality | ssedt8 max distance error (sparse seeds) | 0.00 | 0.00 | px |
| filter | box blur r=8 (running sums, SWAR) | 198.93 | 35.98 | ms |
| filter | box blur r=100 (same cost) | 203.74 | 35.47 | ms |
| filter | summed-area table build (4 x u32 planes) | 91.89 | 21.44 | ms |
| filter | SAT resample 1024 -> 737 (any footprint) | 784.42 | 227.69 | ms |
| filter | area resample 1024 -> 737 (exact, integer weights) | 192.30 | 40.02 | ms |
| filter | area resample 1024 -> 512 | 106.94 | 24.34 | ms |
| filter | SWAR 2x2 box mip 1024 -> 512 (Pixels.downsample2x) | 25.36 | 2.26 | ms |
| filter | height field -> normal map | 98.44 | 13.52 | ms |
| tiles | Morton encode, bit32 part1by1 (1M codes) | 188.30 | 19.35 | ms |
| tiles | Morton encode, byte lookup table (1M codes) | 65.36 | 22.15 | ms |
| tiles | intern a 1024^2 image as 16px tiles (string keys) | 3.74 | 2.91 | ms |
| tiles | unique 16px tiles, 64-shape scene (of 4096) | 962 | 962 | count |
| tiles | compose 16px tiles into a frame | 2.02 | 1.46 | ms |
| tiles | intern a 1024^2 image as 64px tiles (string keys) | 2.08 | 1.79 | ms |
| tiles | unique 64px tiles, 64-shape scene (of 256) | 172 | 172 | count |
| tiles | compose 64px tiles into a frame | 0.83 | 0.82 | ms |
| expr | closure tree, per pixel (128 rows x 8) | 1306.89 | 604.83 | ms |
| expr | op array interpreter, per pixel (128 rows x 8) | 2485.08 | 600.12 | ms |
| expr | op array interpreter, column at a time per row (128 rows x 8) | 904.49 | 282.22 | ms |
| expr | build-time generated module, row kernel (128 rows x 8) | 541.42 | 171.83 | ms |
| expr | loadstring per pixel (128 rows x 8) | 720.02 | 536.51 | ms |
| expr | loadstring row kernel (128 rows x 8) | 573.41 | 534.76 | ms |
| expr | loadstring row kernel, unsafe env (Roblox-like) (128 rows x 8) | 830.05 | 1022.34 | ms |
| expr | quadtree render, lipschitz classification, leaf 8 | 73.68 | 47.42 | ms |
| expr | pixels shaded, lipschitz classification | 57216 | 57216 | count |
| expr | quadtree render, interval classification, leaf 8 | 71.72 | 44.32 | ms |
| expr | pixels shaded, interval classification | 51072 | 51072 | count |
| trace | sphere-traced normal map 256^2, scaled x16 | 1579.72 | 592.87 | ms |
| trace | steps per ray (256^2) | 7 | 7 | count |

Calibration this session: interpreter 8.78 ms, native 2.21 ms.

All quality rows (err255, px, count) are identical in every run of both runtimes, except the time-slice tile counts, which depend on speed.
