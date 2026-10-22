Minimum of 4 interpreter runs and 4 native runs (`--codegen`), each value itself the minimum of 1 to 5 in-process repeats. Machine: Intel Xeon @ 2.10 GHz, 4 vCPU virtualised, shared with other agents, so absolute times swing by up to 4x between quiet and busy periods; the calibration row (a constant `writeu32` over 1024 x 1024; RUNTIME_AUDIT 6.6 measured 10.3 ms interpreted, 2.9 ms native) shows how fast the machine was. Times are ms per full 1024 x 1024 frame unless the row says otherwise.

| group | measurement | interp O2 | native O2 | unit |
|---|---|---|---|---|
| calibration | writeu32 constant, 1024^2 | 11.24 | 3.05 | ms |
| demo | 256 shapes, leaf 4, linear (preview) | 126.90 | 42.79 | ms |
| demo | 256 shapes, leaf 4, exact coverage, alpha compositing (F1) | 140.38 | 44.89 | ms |
| demo | 256 shapes, leaf 4, flawless (F1 + F2) | 192.03 | 52.09 | ms |
| demo | 256 shapes, leaf 4, conflict pixels | 2090 | 2090 | count |
| demo | 256 shapes, leaf 4, conflict pixels per million | 1993.18 | 1993.18 | ppm |
| demo | 256 shapes, leaf 4, exact region areas | 4379 | 4379 | count |
| demo | 256 shapes, leaf 4, visibility term cap reached | 0 | 0 | count |
| seams | triangle mesh, 4608 triangles, linear (preview) | 670.77 | 209.71 | ms |
| seams | triangle mesh, 4608 triangles, exact coverage, alpha compositing (F1) | 934.33 | 288.97 | ms |
| seams | triangle mesh, 4608 triangles, flawless (F1 + F2) | 1238.89 | 295.89 | ms |
| seams | triangle mesh, 4608 triangles, conflict pixels | 194120 | 194120 | count |
| seams | triangle mesh, 4608 triangles, conflict pixels per million | 185127.26 | 185127.26 | ppm |
| seams | triangle mesh, 4608 triangles, exact region areas | 0 | 0 | count |
| seams | triangle mesh, 4608 triangles, visibility term cap reached | 0 | 0 | count |
| seams | 64 pie charts of 6 slices, linear (preview) | 58.16 | 19.65 | ms |
| seams | 64 pie charts of 6 slices, exact coverage, alpha compositing (F1) | 102.16 | 32.05 | ms |
| seams | 64 pie charts of 6 slices, flawless (F1 + F2) | 133.81 | 40.41 | ms |
| seams | 64 pie charts of 6 slices, conflict pixels | 24077 | 24077 | count |
| seams | 64 pie charts of 6 slices, conflict pixels per million | 22961.62 | 22961.62 | ppm |
| seams | 64 pie charts of 6 slices, exact region areas | 995 | 995 | count |
| seams | 64 pie charts of 6 slices, visibility term cap reached | 0 | 0 | count |
| seams | triangle mesh, Scanline.composite per path (conflates, C11) | 213.91 | 74.32 | ms |
| seams | triangle mesh, Scanline.renderScene (exact, F2) | 679.62 | 271.29 | ms |
| seams | triangle mesh, Scanline.renderScene conflict pixels | 194115 | 194115 | count |
| seams | triangle mesh, Scanline.renderScene pixels composited in floating point | 194115 | 194115 | count |

Calibration this session: interpreter 11.24 ms, native 3.05 ms.

All quality rows (err255, px, count) are identical in every run of both runtimes, except the time-slice tile counts, which depend on speed.
