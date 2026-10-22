#!/usr/bin/env python3
"""Procedural training targets for ALLAN (docs/LIQUID.md section 5, docs/LIQUID_TRAINING.md).

Every generator is deterministic: integer hashing (lowbias32, the same hash as
src/MyMath.luau), value noise with a quintic fade, and only + - * / sqrt floor
abs min max. No libm transcendental functions: sines come from the same odd
Taylor polynomial as MyMath.dsinTurns, powers from repeated multiplication and
square roots. The same seed and size give the same bytes on every machine.

Generators return uint8 arrays of shape (H, W, C):

    ui_flat      (C=3) flat UI art: panels, buttons, icons, pixel-font text lines
    sdf_logo     (C=3) SDF emblem and wordmark with a soft drop shadow on a gradient
    marble       (C=3) veined marble (turbulent sine of fbm)
    wood         (C=3) wood rings with grain
    caustics     (C=3) water caustics (iterated domain warp)
    pbr_stones   (C=8) PBR set: albedo RGB, normal X, normal Y, roughness,
                       metalness, ambient occlusion

Usage:  python3 tools/liquid_targets.py [--size 256] [--seed 1] [--out DIR]
writes one PNG per target (PBR as two PNGs) for inspection.
"""
from __future__ import annotations

import argparse
import os

import numpy as np

M32 = np.uint64(0xFFFFFFFF)


# ---------------------------------------------------------------------------
# deterministic numerics (mirrors src/MyMath.luau)
# ---------------------------------------------------------------------------

def hash32(x):
    """lowbias32 on uint64 arrays holding values below 2^32 (exact, wraps mod 2^32)."""
    x = np.asarray(x, dtype=np.uint64) & M32
    x = x ^ (x >> np.uint64(16))
    x = (x * np.uint64(0x7FEB352D)) & M32
    x = x ^ (x >> np.uint64(15))
    x = (x * np.uint64(0x846CA68B)) & M32
    x = x ^ (x >> np.uint64(16))
    return x


def _u32(v):
    return np.asarray(np.mod(np.asarray(v, dtype=np.int64), 1 << 32), dtype=np.uint64)


def hash2(ix, iy, seed):
    """MyMath.hash2: hash of an integer lattice point and a seed (inputs may be negative)."""
    h = hash32(_u32(seed) ^ ((_u32(ix) * np.uint64(0x9E3779B1)) & M32))
    return hash32(h ^ ((_u32(iy) * np.uint64(0x85EBCA77)) & M32))


def rand2(ix, iy, seed):
    return hash2(ix, iy, seed).astype(np.float64) / 4294967296.0


def fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def value_noise2(x, y, seed):
    ix = np.floor(x)
    iy = np.floor(y)
    ux = fade(x - ix)
    uy = fade(y - iy)
    ix = ix.astype(np.int64)
    iy = iy.astype(np.int64)
    a = rand2(ix, iy, seed)
    b = rand2(ix + 1, iy, seed)
    c = rand2(ix, iy + 1, seed)
    d = rand2(ix + 1, iy + 1, seed)
    ab = a + (b - a) * ux
    cd = c + (d - c) * ux
    return ab + (cd - ab) * uy


def fbm2(x, y, seed, octaves):
    s = np.zeros_like(x)
    amp, freq, norm = 1.0, 1.0, 0.0
    for o in range(1, octaves + 1):
        s = s + amp * value_noise2(x * freq, y * freq, seed + o * 1013)
        norm += amp
        amp *= 0.5
        freq *= 2.0
    return s / norm


TAU = 6.283185307179586


def dsin_turns(t):
    """sin(2 pi t), odd Taylor polynomial to x^15 on [-pi/2, pi/2] (MyMath.dsinTurns)."""
    t = t - np.floor(t)
    s = np.where(t < 0.25, t, np.where(t < 0.75, 0.5 - t, t - 1.0))
    x = s * TAU
    x2 = x * x
    return x * (1 + x2 * (-1 / 6 + x2 * (1 / 120 + x2 * (-1 / 5040 + x2 * (1 / 362880 + x2 * (
        -1 / 39916800 + x2 * (1 / 6227020800 + x2 * (-1 / 1307674368000))))))))


def dsin(x):
    return dsin_turns(x / TAU)


def dcos(x):
    return dsin_turns(x / TAU + 0.25)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def mix(a, b, t):
    return a + (b - a) * t


def to_u8(v):
    return np.clip(np.floor(np.asarray(v) * 255.0 + 0.5), 0, 255).astype(np.uint8)


def grid(size, ss=1):
    """Pixel-centre coordinates in [0, 1) with ss x ss supersampling (returns (H*ss, W*ss))."""
    n = size * ss
    c = (np.arange(n, dtype=np.float64) + 0.5) / n
    return np.meshgrid(c, c)


def box_down(a, ss):
    if ss == 1:
        return a
    h, w = a.shape[0] // ss, a.shape[1] // ss
    return a.reshape(h, ss, w, ss, *a.shape[2:]).mean(axis=(1, 3))


# ---------------------------------------------------------------------------
# SDF primitives (pixel-independent, unit-square coordinates)
# ---------------------------------------------------------------------------

def sd_circle(x, y, cx, cy, r):
    return np.sqrt((x - cx) ** 2 + (y - cy) ** 2) - r


def sd_round_box(x, y, cx, cy, hx, hy, rad):
    qx = np.abs(x - cx) - hx + rad
    qy = np.abs(y - cy) - hy + rad
    ox = np.maximum(qx, 0.0)
    oy = np.maximum(qy, 0.0)
    inside = np.minimum(np.maximum(qx, qy), 0.0)
    return np.sqrt(ox * ox + oy * oy) + inside - rad


def sd_segment(x, y, ax, ay, bx, by, r):
    pax, pay = x - ax, y - ay
    bax, bay = bx - ax, by - ay
    h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0.0, 1.0)
    dx, dy = pax - bax * h, pay - bay * h
    return np.sqrt(dx * dx + dy * dy) - r


def sd_polygon(x, y, pts):
    n = len(pts)
    d = np.full_like(x, np.inf)
    s = np.ones_like(x)
    jx, jy = pts[-1]
    for vx, vy in pts:
        ex, ey = jx - vx, jy - vy
        wx, wy = x - vx, y - vy
        ee = ex * ex + ey * ey
        h = np.clip((wx * ex + wy * ey) / ee, 0.0, 1.0)
        bx, by = wx - ex * h, wy - ey * h
        d = np.minimum(d, bx * bx + by * by)
        c1 = y >= vy
        c2 = y < jy
        c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
        jx, jy = vx, vy
    del n
    return s * np.sqrt(d)


def over(dst, color, alpha):
    """Straight-alpha source-over of a flat colour with coverage alpha onto an opaque dst."""
    a = alpha[..., None]
    return dst + (np.asarray(color, dtype=np.float64) - dst) * a


def hexc(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


# ---------------------------------------------------------------------------
# targets
# ---------------------------------------------------------------------------

def ui_flat(size=256, seed=1):
    """Flat UI art: window, title bar, pixel-font text lines, buttons, icons, progress bar.
    Flat colours, edges anti-aliased by 4x4 supersampling."""
    ss = 4
    x, y = grid(size, ss)
    img = np.empty(x.shape + (3,))
    img[...] = hexc("1E2230")

    def fill(mask_sd, col):
        nonlocal img
        cov = (mask_sd <= 0).astype(np.float64)
        img = over(img, hexc(col), cov)

    # window panel and title bar
    fill(sd_round_box(x, y, 0.5, 0.53, 0.43, 0.42, 0.03), "2B3245")
    fill(np.maximum(sd_round_box(x, y, 0.5, 0.53, 0.43, 0.42, 0.03), y - 0.17), "3A86FF")
    # window buttons
    for i, col in enumerate(("FF5F57", "FEBC2E", "28C840")):
        fill(sd_circle(x, y, 0.11 + 0.035 * i, 0.14, 0.011), col)
    # pixel-font text: glyphs are 3x5 cells drawn from hashed bit patterns
    def text_line(x0, y0, x1, cell, col, line_id):
        nonlocal img
        gx = 3 * cell
        pos = x0
        word = 0
        mask = np.zeros_like(x, dtype=bool)
        while pos < x1:
            nletters = 2 + int(hash2(line_id, word, seed) % np.uint64(6))
            for k in range(nletters):
                if pos + gx > x1:
                    break
                bits = int(hash2(line_id * 131 + word, k, seed + 7) & np.uint64(0x7FFF)) | 0x2492
                for cy in range(5):
                    for cx in range(3):
                        if bits >> (cy * 3 + cx) & 1:
                            ax = pos + cx * cell
                            ay = y0 + cy * cell
                            mask |= (x >= ax) & (x < ax + cell) & (y >= ay) & (y < ay + cell)
                pos += gx + cell
            pos += 3 * cell
            word += 1
        img = over(img, hexc(col), mask.astype(np.float64))

    text_line(0.10, 0.125, 0.40, 0.0062, "FFFFFF", 1)  # title
    for li in range(7):
        x1 = 0.86 - 0.12 * float(hash2(li, 99, seed) % np.uint64(4)) / 3.0
        text_line(0.11, 0.22 + li * 0.052, x1, 0.0048, "E6E9F0", 10 + li)
    # buttons with labels
    fill(sd_round_box(x, y, 0.27, 0.66, 0.13, 0.04, 0.02), "FF6B6B")
    text_line(0.19, 0.645, 0.36, 0.006, "FFFFFF", 50)
    fill(sd_round_box(x, y, 0.62, 0.66, 0.16, 0.04, 0.04), "4ECDC4")
    text_line(0.50, 0.645, 0.75, 0.006, "103030", 51)
    # icons: check mark (capsules), ring, filled circle
    fill(np.minimum(sd_segment(x, y, 0.13, 0.80, 0.16, 0.83, 0.008),
                    sd_segment(x, y, 0.16, 0.83, 0.21, 0.77, 0.008)), "28C840")
    fill(np.abs(sd_circle(x, y, 0.29, 0.80, 0.026)) - 0.006, "FEBC2E")
    fill(sd_circle(x, y, 0.37, 0.80, 0.02), "A78BFA")
    # progress bar
    fill(sd_round_box(x, y, 0.62, 0.80, 0.18, 0.012, 0.012), "1E2230")
    fill(sd_round_box(x, y, 0.53, 0.80, 0.09, 0.012, 0.012), "3A86FF")
    return to_u8(box_down(img, ss))


def sdf_logo(size=256, seed=1):
    """SDF emblem (ring, star, crossbar) and a capsule wordmark with a soft drop shadow
    over a vertical gradient. Anti-aliasing from the SDF (1 pixel ramp)."""
    x, y = grid(size)
    px = 1.0 / size
    top, bot = hexc("0F2027"), hexc("2C5364")
    img = top + (bot - top) * y[..., None]
    star = []
    for k in range(10):
        rr = 0.16 if k % 2 == 0 else 0.075
        t = 0.75 + k / 10.0
        star.append((0.5 + rr * dcos(TAU * t), 0.36 + rr * dsin(TAU * t)))
    ring = np.abs(sd_circle(x, y, 0.5, 0.36, 0.24)) - 0.022
    emblem = np.minimum(ring, sd_polygon(x, y, star))
    # wordmark: capsules forming letter-like strokes
    word = np.full_like(x, np.inf)
    cx = 0.2
    for i in range(6):
        hsel = int(hash2(i, 3, seed) % np.uint64(3))
        h = 0.045
        word = np.minimum(word, sd_segment(x, y, cx, 0.72, cx, 0.72 + h, 0.009))
        if hsel == 0:
            word = np.minimum(word, sd_segment(x, y, cx, 0.72, cx + 0.04, 0.72, 0.009))
        elif hsel == 1:
            word = np.minimum(word, sd_segment(x, y, cx, 0.72 + h, cx + 0.04, 0.72 + h / 2, 0.009))
        else:
            word = np.minimum(word, sd_segment(x, y, cx + 0.04, 0.72, cx + 0.04, 0.72 + h, 0.009))
        cx += 0.1
    logo = np.minimum(emblem, word)
    # soft shadow: offset SDF, wide smoothstep falloff
    sh = np.minimum(np.minimum(np.abs(sd_circle(x - 0.012, y - 0.02, 0.5, 0.36, 0.24)) - 0.022,
                               sd_polygon(x - 0.012, y - 0.02, star)), np.inf)
    shadow = 0.55 * (1.0 - smoothstep(-0.01, 0.06, sh))
    img = over(img, (0.0, 0.0, 0.0), shadow)
    cov = np.clip(0.5 - logo / px, 0.0, 1.0)
    gold = hexc("F7B733")[None, None, :] + (hexc("FC4A1A") - hexc("F7B733"))[None, None, :] * y[..., None]
    img = img + (gold - img) * cov[..., None]
    return to_u8(img)


def marble(size=256, seed=1):
    x, y = grid(size)
    n = fbm2(x * 4.0, y * 4.0, seed, 5)
    v = 0.5 + 0.5 * dsin_turns(x * 2.0 + y * 1.0 + 2.2 * n)
    v = v * v
    v = v * v  # sharpen veins (v^4)
    fine = fbm2(x * 24.0, y * 24.0, seed + 5, 3)
    base = np.array([0.93, 0.92, 0.89])
    vein = np.array([0.28, 0.33, 0.31])
    t = (1.0 - v)[..., None]
    img = vein + (base - vein) * t
    img = img * (0.94 + 0.06 * fine)[..., None]
    return to_u8(img)


def wood(size=256, seed=1):
    x, y = grid(size)
    n = fbm2(x * 3.0, y * 3.0, seed, 4)
    cx, cy = -0.35, 0.45
    r = np.sqrt(((x - cx) * 1.0) ** 2 + ((y - cy) * 2.6) ** 2)
    ring = r * 9.0 + 0.9 * n
    f = ring - np.floor(ring)
    prof = smoothstep(0.0, 0.75, f) * (1.0 - smoothstep(0.82, 1.0, f))
    grain = fbm2(x * 3.0, y * 90.0, seed + 11, 3)
    light = np.array([0.80, 0.60, 0.38])
    dark = np.array([0.47, 0.29, 0.15])
    t = (prof * (0.8 + 0.2 * grain))[..., None]
    img = dark + (light - dark) * t
    return to_u8(img)


def caustics(size=256, seed=1, time=0.0):
    """Water caustics: iterated domain warp (after the classic tileable-caustic shader),
    with deterministic polynomial sines and integer-power sharpening."""
    x, y = grid(size)
    off = float(hash2(seed, 0, 77) % np.uint64(1000)) / 100.0
    px = x * TAU * 1.5 - 250.0 + off
    py = y * TAU * 1.5 - 250.0 + off
    ix, iy = px.copy(), py.copy()
    c = np.ones_like(x)
    inten = 0.005
    iters = 5
    t0 = time * 0.5 + 23.0
    for n in range(iters):
        t = t0 * (1.0 - 3.5 / (n + 1))
        jx = px + dcos(t - ix) + dsin(t + iy)
        jy = py + dsin(t - iy) + dcos(t + ix)
        ix, iy = jx, jy
        ax = px / (dsin(ix + t) / inten)
        ay = py / (dcos(iy + t) / inten)
        c = c + 1.0 / np.maximum(np.sqrt(ax * ax + ay * ay), 1e-6)
    c = c / iters
    c = np.clip(c, 0.0, 4.0)
    r8 = np.sqrt(np.sqrt(np.sqrt(c)))
    c = 1.17 - c * r8 * r8 * r8  # c^1.375 in place of c^1.4
    a = np.abs(c)
    a2 = a * a
    a4 = a2 * a2
    col = np.clip(a4 * a4, 0.0, 1.0)  # |c|^8
    water = np.array([0.0, 0.35, 0.5])
    img = np.clip(water + col[..., None], 0.0, 1.0)
    return to_u8(img)


PBR_CHANNELS = ("albedo_r", "albedo_g", "albedo_b", "normal_x", "normal_y", "roughness", "metalness", "ao")


def pbr_stones(size=256, seed=1):
    """Stone tiles (jittered Voronoi), mortar grooves, some metal plates.
    Channels: albedo RGB, normal X/Y (from the height field by central differences),
    roughness, metalness, ambient occlusion."""
    x, y = grid(size)
    cells = 6.0
    gx, gy = x * cells, y * cells
    cx0, cy0 = np.floor(gx).astype(np.int64), np.floor(gy).astype(np.int64)
    f1 = np.full_like(x, 9.0)
    f2 = np.full_like(x, 9.0)
    id1 = np.zeros_like(cx0)
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            cx = cx0 + ox
            cy = cy0 + oy
            jx = cx + 0.15 + 0.7 * rand2(cx % 6, cy % 6, seed)
            jy = cy + 0.15 + 0.7 * rand2(cx % 6, cy % 6, seed + 1)
            d = np.sqrt((gx - jx) ** 2 + (gy - jy) ** 2)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            id1 = np.where(closer, (cx % 6) * 6 + (cy % 6), id1)
            f1 = np.where(closer, d, f1)
    edge = f2 - f1
    n = fbm2(x * 16.0, y * 16.0, seed + 3, 4)
    cell_r = rand2(id1, 5, seed + 9)
    groove = smoothstep(0.02, 0.12, edge)
    height = groove * (0.75 + 0.25 * n) * (0.85 + 0.15 * cell_r)
    metal = (hash2(id1, 17, seed) % np.uint64(6) == 0) & (groove > 0.5)
    # albedo
    stone_a = np.array([0.52, 0.49, 0.45])
    stone_b = np.array([0.36, 0.34, 0.33])
    mortar = np.array([0.20, 0.19, 0.18])
    metal_c = np.array([0.80, 0.62, 0.42])
    alb = stone_b + (stone_a - stone_b) * cell_r[..., None]
    alb = alb * (0.8 + 0.2 * n)[..., None]
    alb = np.where(metal[..., None], metal_c * (0.9 + 0.1 * n)[..., None], alb)
    alb = mortar + (alb - mortar) * groove[..., None]
    # normals from the height field (wrapping central differences)
    strength = 6.0
    dhx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * (size / 2.0) / size * strength
    dhy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * (size / 2.0) / size * strength
    inv = 1.0 / np.sqrt(dhx * dhx + dhy * dhy + 1.0)
    nx = -dhx * inv
    ny = -dhy * inv
    rough = np.where(metal, 0.25 + 0.1 * n, 0.7 + 0.25 * n)
    rough = mortar[0] * 0 + rough * groove + 0.95 * (1.0 - groove)
    metalness = metal.astype(np.float64)
    # AO: cavity from a box blur of the height (cumulative sums, sequential order)
    k = max(1, size // 64)
    pad = np.pad(height, k, mode="wrap")
    cs = pad.cumsum(axis=0).cumsum(axis=1)
    cs = np.pad(cs, ((1, 0), (1, 0)))
    w = 2 * k + 1
    blur = (cs[w:, w:] - cs[:-w, w:] - cs[w:, :-w] + cs[:-w, :-w]) / (w * w)
    ao = np.clip(1.0 - 2.5 * np.maximum(blur - height, 0.0), 0.0, 1.0)
    out = np.stack([alb[..., 0], alb[..., 1], alb[..., 2], nx * 0.5 + 0.5, ny * 0.5 + 0.5,
                    rough, metalness, ao], axis=-1)
    return to_u8(out)


TARGETS = {
    "ui_flat": ui_flat,
    "sdf_logo": sdf_logo,
    "marble": marble,
    "wood": wood,
    "caustics": caustics,
    "pbr_stones": pbr_stones,
}


def make(name, size=256, seed=1):
    return TARGETS[name](size=size, seed=seed)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="assets/liquid/targets")
    a = ap.parse_args()
    from PIL import Image
    os.makedirs(a.out, exist_ok=True)
    for name, fn in TARGETS.items():
        img = fn(size=a.size, seed=a.seed)
        if img.shape[2] == 3:
            Image.fromarray(img).save(os.path.join(a.out, f"{name}_{a.size}_s{a.seed}.png"))
        else:
            Image.fromarray(img[..., 0:3]).save(os.path.join(a.out, f"{name}_{a.size}_s{a.seed}_albedo.png"))
            Image.fromarray(np.dstack([img[..., 3], img[..., 4], np.full_like(img[..., 0], 255)])).save(
                os.path.join(a.out, f"{name}_{a.size}_s{a.seed}_normal.png"))
            Image.fromarray(img[..., 5:8]).save(os.path.join(a.out, f"{name}_{a.size}_s{a.seed}_rma.png"))
        print(name, img.shape, int(img.min()), int(img.max()))


if __name__ == "__main__":
    main()
