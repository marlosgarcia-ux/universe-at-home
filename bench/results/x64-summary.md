| group | op | interp O1 (Studio) (ns/op) | interp O2 (live) (ns/op) | native O2 raw (ns/iter) |
|---|---|---|---|---|
| buffer | readu8 | 3.23 | 3.25 | 2.25 |
| buffer | readu16 | 3.00 | 4.62 | 2.24 |
| buffer | readu32 | 3.00 | 3.90 | 2.85 |
| buffer | readu32 (buffer cached in a local) | 2.38 | 2.51 | 2.15 |
| buffer | readi32 | 3.33 | 3.08 | 2.34 |
| buffer | readf32 | 2.87 | 3.84 | 2.36 |
| buffer | readf64 | 2.67 | 4.43 | 2.25 |
| buffer | readbits (8, byte aligned) | 22.04 | 25.30 | 23.40 |
| buffer | readbits (12, unaligned) | 24.32 | 24.75 | 25.09 |
| buffer | readstring (4 bytes) | 30.28 | 35.10 | 25.03 |
| buffer | writeu8 | 5.62 | 5.81 | 2.07 |
| buffer | writeu16 | 5.13 | 5.21 | 2.08 |
| buffer | writeu32 | 5.17 | 5.34 | 2.14 |
| buffer | writef32 | 5.17 | 5.20 | 2.54 |
| buffer | writef64 | 5.37 | 5.34 | 2.18 |
| buffer | writebits (8, byte aligned) | 23.39 | 23.67 | 18.55 |
| buffer | copy (4 bytes, C call) | 18.27 | 18.11 | 22.54 |
| buffer | len | 9.42 | 9.11 | 11.94 |
| table | array read t[i] | 3.58 | 2.52 | 3.26 |
| table | array write t[i]=v | 3.29 | 1.63 | 2.38 |
| bit32 | band(x, k) | 2.72 | 2.46 | 2.27 |
| bit32 | bor(x, k) | 2.35 | 3.49 | 2.48 |
| bit32 | bor(a, b, c, d) | 7.49 | 11.18 | 2.16 |
| bit32 | bxor(x, k) | 2.44 | 4.16 | 2.61 |
| bit32 | lshift(x, 8) | 2.16 | 2.17 | 2.63 |
| bit32 | rshift(x, 3) | 2.15 | 2.19 | 2.65 |
| bit32 | arshift(x, 3) | 2.17 | 2.27 | 2.55 |
| bit32 | extract(x, 4, 8) const field | 3.13 | 4.80 | 2.58 |
| bit32 | extract(x, f, w) dynamic | 3.53 | 4.45 | 3.07 |
| bit32 | replace(x, v, 8, 8) | 8.31 | 9.10 | 2.73 |
| bit32 | byteswap(x) | 1.59 | 2.64 | 2.11 |
| bit32 | countlz(x) | 2.06 | 2.88 | 2.07 |
| bit32 | lrotate(x, 7) | 2.94 | 4.41 | 2.10 |
| math | x * k | 1.46 | 1.35 | 2.18 |
| math | x / k | 0.80 | 1.48 | 2.34 |
| math | x // k | 1.02 | 2.11 | 2.37 |
| math | x % k | 1.14 | 2.07 | 2.55 |
| math | x ^ 2.2 (gamma via pow) | 12.34 | 12.30 | 11.41 |
| math | math.floor | 3.71 | 3.66 | 2.28 |
| math | math.floor via local alias | 4.35 | 4.15 | 2.51 |
| math | math.round | 4.27 | 4.46 | 2.55 |
| math | math.clamp | 6.75 | 7.73 | 2.07 |
| math | math.min(a, b) | 3.07 | 3.22 | 2.01 |
| math | math.max(a, b) | 3.35 | 1.95 | 2.04 |
| math | math.abs | 4.49 | 2.56 | 2.05 |
| math | math.sqrt | 1.47 | 1.59 | 1.95 |
| math | math.lerp | 5.38 | 4.57 | 2.10 |
| math | math.sign | 3.04 | 3.92 | 2.20 |
| math | math.sin (libm) | 6.95 | 10.16 | 7.21 |
| math | math.exp (libm) | 5.58 | 8.06 | 5.16 |
| math | if-expression select | 3.97 | 3.07 | 2.34 |
| vector | vector.create + .X | 8.09 | 7.95 | 2.06 |
| vector | v * s | 3.33 | 3.39 | 3.09 |
| vector | v + v | 1.31 | 1.08 | 2.51 |
| vector | vector.dot | 12.00 | 12.69 | 10.92 |
| vector | vector.magnitude | 13.90 | 13.52 | 13.87 |
| vector | vector.floor | 11.05 | 8.17 | 5.66 |
| vector | vector.lerp | 7.84 | 6.06 | 2.36 |
| vector | vector.clamp | 9.73 | 7.65 | 4.73 |
| pack | 4x writeu8 | 38.91 | 37.61 | 3.01 |
| pack | writeu32(r + g*256 + b*65536 + a*16777216) | 11.87 | 11.73 | 2.80 |
| pack | writeu32(bor(r, lshift(g,8), lshift(b,16), lshift(a,24))) | 18.38 | 23.06 | 2.91 |
| pack | writeu32(prepacked) | 6.09 | 7.22 | 2.23 |
| pack | writeu32(PAL[band(i,15)+1]) | 11.25 | 10.44 | 5.05 |
| pack | writeu32(packHelper(r,g,b,a)) local fn | 26.91 | 10.85 | 3.52 |
| unpack | 4x readu8 | 24.21 | 23.32 | 3.95 |
| unpack | readu32 + 4x extract | 27.36 | 23.02 | 3.89 |
| unpack | readu32 + band/rshift | 32.43 | 36.78 | 4.00 |
| unpack | readu32 + // and % | 25.56 | 23.59 | 7.38 |

| meta | interp O1 (Studio) | interp O2 (live) | native O2 raw |
|---|---|---|---|
| passes | 128.00 | 128.00 | 128.00 |
| baseline loop | 3.58 | 3.59 | 2.16 |

| kernel (1024x1024 RGBA8 source) | interp O1 (Studio) ms | interp O1 (Studio) Mpix/s | interp O2 (live) ms | interp O2 (live) Mpix/s | native O2 raw ms | native O2 raw Mpix/s |
|---|---|---|---|---|---|---|
| fill: buffer.fill (memset) | 0.18 | 5858.0 | 0.14 | 7231.6 | 0.18 | 5761.4 |
| fill: u32 seed + buffer.copy doubling | 0.23 | 4578.9 | 0.20 | 5115.0 | 0.24 | 4424.4 |
| fill: writeu32 per pixel | 10.87 | 96.4 | 10.30 | 101.8 | 2.86 | 366.4 |
| blit: 1024 row buffer.copy | 0.43 | 2410.5 | 0.36 | 2929.0 | 0.38 | 2796.2 |
| gradient: per pixel arithmetic pack | 14.23 | 73.7 | 14.63 | 71.7 | 3.56 | 294.5 |
| sdf circle: sqrt + clamp per pixel | 42.71 | 24.6 | 42.96 | 24.4 | 5.92 | 177.0 |
| sdf circle: vector.magnitude per pixel | 39.13 | 26.8 | 37.53 | 27.9 | 28.48 | 36.8 |
| sdf circle: span skip (only the AA ring) | 0.81 | 1294.5 | 0.62 | 1691.3 | 0.41 | 2526.7 |
| mip 2x2 box: per channel extract | 46.87 | 5.6 | 36.78 | 7.1 | 3.42 | 76.8 |
| mip 2x2 box: SWAR (2 channels per op) | 37.20 | 7.0 | 29.12 | 9.0 | 2.06 | 127.5 |
| blend over opaque dst: float per channel | 99.95 | 10.5 | 79.59 | 13.2 | 8.84 | 118.7 |
| blend over opaque dst: SWAR exact /255 | 101.01 | 10.4 | 114.06 | 9.2 | 18.02 | 58.2 |
| lod crossfade t=0.37: SWAR lerp (CPU path) | 118.17 | 8.9 | 122.20 | 8.6 | 18.51 | 56.6 |
| palette expand: u8 index -> u32 via readu32(PALB) | 25.47 | 41.2 | 20.91 | 50.1 | 4.07 | 257.6 |
| chroma key: squared distance + smooth alpha | 64.70 | 16.2 | 51.46 | 20.4 | 6.57 | 159.6 |
| bilinear resample 1024->512 at scale 0.73 | 55.96 | 4.7 | 58.26 | 4.5 | 7.49 | 35.0 |
| dirty tiles: 16 tiles of 64x64 rewritten | 0.79 | 82.7 | 0.81 | 80.6 | 0.18 | 358.1 |
