#!/usr/bin/env python3
"""ALLAN offline training (docs/LIQUID.md section 5; results in docs/LIQUID_TRAINING.md).

Pipeline
  1. shell-byte quadtree: split while the max channel deviation from the node's
     integer mean exceeds theta and the node is above the minimum leaf size
  2. structured reservoir: Walsh projections of the leaf bytes (B, beta) at a
     multi-scale spread of kBase; k = clamp(kBase + log2(leafSide) + r, 0, K-1)
  3. exact replica of the Luau step order in float64 (elementwise numpy across
     rows, never a vectorised reduction where bits matter)
  4. ridge readout: a numpy float path, and an exact integer path (15-bit
     fixed-point statistics, scalar Cholesky) that is bit-identical to
     src/LiquidLearn.luau
  5. export in the ALN binary layout (src/Liquid.luau header is the source of truth)

Subcommands (python3 tools/liquid_train.py <cmd> --help):
  sweep     quality table over N, theta, epsilon for every target
  x4        learned detail above the source resolution
  golden    golden vectors and cross-check data for tests/liquid_learn.test.luau
  export    train and export one model
"""
from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
import time
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import liquid_targets as targets  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets", "liquid")

MAGIC = b"ALN"
VERSION = 1
QSCALE = 32767  # S3: states quantised to 15-bit fixed point, q = floor(h * 32767 + 0.5)


# ---------------------------------------------------------------------------
# model containers
# ---------------------------------------------------------------------------

class Reservoir:
    def __init__(self, N, I, K, beta, B, kbase):
        self.N, self.I, self.K = N, I, K
        self.beta = [float(v) for v in beta]
        self.B = [float(v) for v in B]  # neuron-major: B[i*I + t]
        self.kbase = [float(v) for v in kbase]

    def fingerprint(self):
        return zlib.crc32(encode_reservoir(self)) & 0xFFFFFFFF


class Readout:
    def __init__(self, M, N, Cf, Cb, d):
        self.M, self.N = M, N
        self.Cf = [float(v) for v in Cf]  # channel-major: Cf[m*N + i]
        self.Cb = [float(v) for v in Cb]
        self.d = [float(v) for v in d]

    def arrays(self):
        return (np.array(self.Cf).reshape(self.M, self.N), np.array(self.Cb).reshape(self.M, self.N),
                np.array(self.d))


class Tree:
    """Quadtree over a power-of-two root square; leaves in preorder."""

    def __init__(self, width, height, max_depth, root_log2, bits, lx, ly, lsl, lbytes):
        self.width, self.height = width, height
        self.max_depth, self.root_log2 = max_depth, root_log2
        self.bits = bits  # list of 0/1, one per visited node with depth < max_depth
        self.lx = np.asarray(lx, dtype=np.int64)
        self.ly = np.asarray(ly, dtype=np.int64)
        self.lsl = np.asarray(lsl, dtype=np.int64)  # log2 of the leaf side
        self.lbytes = np.asarray(lbytes, dtype=np.uint8).reshape(len(self.lx), -1)
        self._lid = None

    @property
    def leaves(self):
        return len(self.lx)

    def leaf_id_map(self):
        if self._lid is None:
            lid = np.full((self.height, self.width), -1, dtype=np.int64)
            for k in range(self.leaves):
                x0, y0, s = int(self.lx[k]), int(self.ly[k]), 1 << int(self.lsl[k])
                if x0 < self.width and y0 < self.height:
                    lid[y0:y0 + s, x0:x0 + s] = k
            assert (lid >= 0).all()
            self._lid = lid
        return self._lid


# ---------------------------------------------------------------------------
# binary layout (see src/Liquid.luau header; version 1)
# ---------------------------------------------------------------------------

def encode_reservoir(res):
    out = bytearray()
    out += struct.pack("<%dd" % res.N, *res.beta)
    out += struct.pack("<%dd" % (res.N * res.I), *res.B)
    out += struct.pack("<%dd" % res.N, *res.kbase)
    return bytes(out)


def pack_bits(bits):
    out = bytearray((len(bits) + 7) // 8)
    for i, b in enumerate(bits):
        if b:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


def encode_tree(tree):
    out = bytearray()
    out += struct.pack("<HHB", tree.width, tree.height, tree.max_depth)
    out += pack_bits(tree.bits)
    out += tree.lbytes.tobytes()
    return bytes(out)


def encode(res, ro, tree):
    assert ro.N == res.N
    out = bytearray(MAGIC)
    out += struct.pack("<BBBBB", VERSION, res.N, res.I, ro.M, res.K)
    out += encode_reservoir(res)
    out += struct.pack("<%dd" % (ro.M * ro.N), *ro.Cf)
    out += struct.pack("<%dd" % (ro.M * ro.N), *ro.Cb)
    out += struct.pack("<%dd" % ro.M, *ro.d)
    out += encode_tree(tree)
    return bytes(out)


def readout_bytes(ro):
    return struct.pack("<%dd" % (2 * ro.M * ro.N + ro.M), *(ro.Cf + ro.Cb + ro.d))


def root_log2_for(width, height):
    s, l = 1, 0
    while s < max(width, height):
        s, l = s * 2, l + 1
    return l


def decode(data):
    """Pure-Python decoder (no numpy needed for the scalar reference)."""
    assert data[0:3] == MAGIC, "bad magic"
    ver, N, I, M, K = struct.unpack_from("<BBBBB", data, 3)
    assert ver == VERSION, "unsupported version %d" % ver
    o = 8

    def f64s(n):
        nonlocal o
        v = list(struct.unpack_from("<%dd" % n, data, o))
        o += 8 * n
        return v

    beta, B, kbase = f64s(N), f64s(N * I), f64s(N)
    Cf, Cb, d = f64s(M * N), f64s(M * N), f64s(M)
    width, height, max_depth = struct.unpack_from("<HHB", data, o)
    o += 5
    root_log2 = root_log2_for(width, height)
    bit_start = o
    bits, leaves = [], []
    pos = [0]

    def read_bit():
        i = pos[0]
        pos[0] += 1
        return (data[bit_start + (i >> 3)] >> (i & 7)) & 1

    def walk(x0, y0, l, depth):
        if depth < max_depth:
            b = read_bit()
            bits.append(b)
            if b:
                h = 1 << (l - 1)
                walk(x0, y0, l - 1, depth + 1)
                walk(x0 + h, y0, l - 1, depth + 1)
                walk(x0, y0 + h, l - 1, depth + 1)
                walk(x0 + h, y0 + h, l - 1, depth + 1)
                return
        leaves.append((x0, y0, l))

    walk(0, 0, root_log2, 0)
    o = bit_start + (pos[0] + 7) // 8
    nl = len(leaves)
    lb = data[o:o + nl * I]
    assert len(lb) == nl * I, "truncated leaf bytes"
    res = Reservoir(N, I, K, beta, B, kbase)
    ro = Readout(M, N, Cf, Cb, d)
    tree = Tree(width, height, max_depth, root_log2, bits, [p[0] for p in leaves], [p[1] for p in leaves],
                [p[2] for p in leaves], np.frombuffer(bytes(lb), dtype=np.uint8) if nl else np.zeros(0, np.uint8))
    return res, ro, tree


# ---------------------------------------------------------------------------
# shell-byte quadtree (exact integer arithmetic; same rule in LiquidLearn.luau)
# ---------------------------------------------------------------------------

def build_tree(img, theta, min_leaf=1):
    """img: (H, W, C) uint8. A node splits iff depth < max_depth, it covers at least one
    pixel, and max over channels and pixels of |x - mean| > theta, where
    mean = (2*sum + count) // (2*count) (integer, round half up). Leaf bytes = means."""
    img = np.asarray(img)
    H, W, C = img.shape
    rl = root_log2_for(W, H)
    S = 1 << rl
    ml = int(round(math.log2(min_leaf)))
    assert (1 << ml) == min_leaf
    max_depth = rl - ml
    big = 1 << 20
    sm = np.zeros((S, S, C), dtype=np.int64)
    mn = np.full((S, S, C), big, dtype=np.int64)
    mx = np.full((S, S, C), -big, dtype=np.int64)
    ct = np.zeros((S, S), dtype=np.int64)
    sm[:H, :W] = img
    mn[:H, :W] = img
    mx[:H, :W] = img
    ct[:H, :W] = 1
    pyr = {0: (sm, mn, mx, ct)}
    for l in range(1, rl + 1):
        s, a, b, c = pyr[l - 1]
        n = s.shape[0] // 2
        s = s.reshape(n, 2, n, 2, C).sum(axis=(1, 3))
        a = a.reshape(n, 2, n, 2, C).min(axis=(1, 3))
        b = b.reshape(n, 2, n, 2, C).max(axis=(1, 3))
        c = c.reshape(n, 2, n, 2).sum(axis=(1, 3))
        pyr[l] = (s, a, b, c)
    bits, lx, ly, lsl, lbytes = [], [], [], [], []
    zero = [0] * C

    def walk(x0, y0, l, depth):
        s, a, b, c = pyr[l]
        nx, ny = x0 >> l, y0 >> l
        cnt = int(c[ny, nx])
        if cnt > 0:
            sums = s[ny, nx]
            means = [int((2 * int(sums[ch]) + cnt) // (2 * cnt)) for ch in range(C)]
            dev = 0
            for ch in range(C):
                dev = max(dev, int(b[ny, nx, ch]) - means[ch], means[ch] - int(a[ny, nx, ch]))
        else:
            means, dev = zero, 0
        if depth < max_depth:
            split = 1 if (cnt > 0 and dev > theta) else 0
            bits.append(split)
            if split:
                h = 1 << (l - 1)
                walk(x0, y0, l - 1, depth + 1)
                walk(x0 + h, y0, l - 1, depth + 1)
                walk(x0, y0 + h, l - 1, depth + 1)
                walk(x0 + h, y0 + h, l - 1, depth + 1)
                return
        lx.append(x0)
        ly.append(y0)
        lsl.append(l)
        lbytes.append(means)

    sys.setrecursionlimit(10000)
    walk(0, 0, rl, 0)
    return Tree(W, H, max_depth, rl, bits, lx, ly, lsl, np.array(lbytes, dtype=np.uint8).reshape(-1, C))


def piecewise_constant(tree):
    lid = tree.leaf_id_map()
    return tree.lbytes[lid]


# ---------------------------------------------------------------------------
# structured reservoir
# ---------------------------------------------------------------------------

def hadamard(n):
    h = [[1]]
    while len(h) < n:
        h = [r + r for r in h] + [r + [-v for v in r] for r in h]
    return h


INSTANT = -64  # kBase <= -K: k = 0 for every leaf, g = 1, h = b (the plain quadtree)
DEFAULT_SCALES = [INSTANT, 0, -2, 2, -4, 4, 1, -1]


def walsh_reservoir(N, I, K=16, kbase=None, scales=None, proj=None):
    """Neuron i reads Walsh projection p(i) of the leaf bytes:
    b = 1/2 + (1/I) * sum_t H[p][t] * (u_t - 1/2), in [0, 1] for u in [0, 1]^I,
    written as beta + sum_t B[t] u_t with B[t] = H[p][t] / I and beta = 1/2 - s / (2I),
    s = sum_t H[p][t]. Default projection p(i) = i mod I, kBase from `scales` by i div I."""
    hn = 1
    while hn < I:
        hn *= 2
    H = hadamard(hn)
    scales = scales or DEFAULT_SCALES
    beta, B, kb = [], [], []
    for i in range(N):
        p = proj[i] if proj is not None else i % I
        row = H[p][:I]
        s = sum(row)
        beta.append(0.5 - s / (2 * I))
        B.extend([v / I for v in row])
        kb.append(float(kbase[i]) if kbase is not None else float(scales[(i // I) % len(scales)]))
    return Reservoir(N, I, K, beta, B, kb)


def leaf_targets_gains(res, tree, r):
    """Per-leaf b (L, N) in the exact order, and per-leaf gains g (L, N)."""
    u = tree.lbytes.astype(np.float64) / 255.0
    L = tree.leaves
    b = np.empty((L, res.N))
    g = np.empty((L, res.N))
    for i in range(res.N):
        acc = np.full(L, res.beta[i])
        for t in range(res.I):
            acc = acc + res.B[i * res.I + t] * u[:, t]
        b[:, i] = acc
        k = np.clip(res.kbase[i] + tree.lsl + r, 0, res.K - 1).astype(np.int64)
        g[:, i] = np.ldexp(1.0, -k)
    return b, g


# ---------------------------------------------------------------------------
# exact simulation (Luau step order), vectorised across rows
# ---------------------------------------------------------------------------

def simulate_rows(res, tree, r=0, rows=None):
    """Bidirectional states for tree rows `rows` rendered at scale 2^r horizontally.
    Returns (lid_rows (R, Wr), hf (R, Wr, N), hb (R, Wr, N), b_pix (R, Wr, N)).
    Rows at scale 2^r repeat each tree row 2^r times vertically; callers expand."""
    lid = tree.leaf_id_map()
    if rows is None:
        rows = np.arange(tree.height)
    lr = lid[rows]
    if r:
        lr = np.repeat(lr, 1 << r, axis=1)
    bl, gl = leaf_targets_gains(res, tree, r)
    bp = bl[lr]
    gp = gl[lr]
    R, Wr = lr.shape
    hf = np.empty((R, Wr, res.N))
    hb = np.empty((R, Wr, res.N))
    h = bp[:, 0, :].copy()
    for x in range(Wr):
        h = h + (bp[:, x, :] - h) * gp[:, x, :]
        hf[:, x, :] = h
    h = bp[:, Wr - 1, :].copy()
    for x in range(Wr - 1, -1, -1):
        h = h + (bp[:, x, :] - h) * gp[:, x, :]
        hb[:, x, :] = h
    return lr, hf, hb, bp


def readout_z(ro, hf, hb):
    """z (..., M) summed in the exact order: d, then Cf terms, then Cb terms."""
    Cf, Cb, d = ro.arrays()
    out = np.empty(hf.shape[:-1] + (ro.M,))
    for m in range(ro.M):
        z = np.full(hf.shape[:-1], d[m])
        for i in range(ro.N):
            z = z + Cf[m, i] * hf[..., i]
        for i in range(ro.N):
            z = z + Cb[m, i] * hb[..., i]
        out[..., m] = z
    return out


def quantise(z):
    return np.clip(np.floor(z + 0.5), 0, 255).astype(np.uint8)


def row_blocks(tree, block=128):
    for y0 in range(0, tree.height, block):
        yield np.arange(y0, min(tree.height, y0 + block))


def expand_rows(a, r):
    return np.repeat(a, 1 << r, axis=0) if r else a


# ---------------------------------------------------------------------------
# training
# ---------------------------------------------------------------------------

def features_f(hf, hb):
    n = hf.shape[0] * hf.shape[1]
    return np.concatenate([hf.reshape(n, -1), hb.reshape(n, -1), np.ones((n, 1))], axis=1)


def features_q(hf, hb):
    n = hf.shape[0] * hf.shape[1]
    qf = np.floor(hf.reshape(n, -1) * float(QSCALE) + 0.5).astype(np.int64)
    qb = np.floor(hb.reshape(n, -1) * float(QSCALE) + 0.5).astype(np.int64)
    return np.concatenate([qf, qb, np.full((n, 1), QSCALE, dtype=np.int64)], axis=1)


def sample_mask(rows_r, Wr, stride):
    """Pixel (x, y) of the rendered grid is sampled iff (x + y) % stride == 0."""
    if stride == 1:
        return None
    y = rows_r[:, None]
    x = np.arange(Wr)[None, :]
    return ((x + y) % stride == 0).reshape(-1)


class Stats:
    """Exact integer sufficient statistics (S1, S3): G = sum s s^T, P = sum s y^T,
    YY = sum y^2, count. Python ints (unbounded) hold the same integers the Luau
    two-limb accumulator holds."""

    def __init__(self, D, M):
        self.D, self.M = D, M
        self.G = np.zeros((D, D), dtype=object)
        self.P = np.zeros((D, M), dtype=object)
        self.YY = np.zeros(M, dtype=object)
        self.count = 0

    def add_int64(self, Q, Y):
        G = Q.T @ Q
        P = Q.T @ Y
        self.G = self.G + G.astype(object)
        self.P = self.P + P.astype(object)
        self.YY = self.YY + (Y * Y).sum(axis=0).astype(object)
        self.count += Q.shape[0]

    def merge(self, other):
        out = Stats(self.D, self.M)
        out.G, out.P, out.YY = self.G + other.G, self.P + other.P, self.YY + other.YY
        out.count = self.count + other.count
        return out


def accumulate(res, tree, target, r=0, stride=1, want=("float", "exact")):
    """Simulate every tree row at scale 2^r and accumulate training statistics against
    `target` (shape (H << r, W << r, M) uint8). Returns dict with float Gram (numpy),
    exact Stats, or both."""
    M = target.shape[2]
    D = 2 * res.N + 1
    Gf = np.zeros((D, D))
    Pf = np.zeros((D, M))
    st = Stats(D, M) if "exact" in want else None
    for rows in row_blocks(tree, max(1, 256 >> r)):
        lr, hf, hb, _ = simulate_rows(res, tree, r, rows)
        hf = expand_rows(hf, r)
        hb = expand_rows(hb, r)
        rows_r = (rows[:, None] * (1 << r) + np.arange(1 << r)[None, :]).reshape(-1)
        Y = target[rows_r].reshape(-1, M).astype(np.int64)
        mask = sample_mask(rows_r, hf.shape[1], stride)
        if "float" in want:
            X = features_f(hf, hb)
            if mask is not None:
                X, Yf = X[mask], Y[mask]
            else:
                Yf = Y
            Gf += X.T @ X
            Pf += X.T @ Yf.astype(np.float64)
        if st is not None:
            Q = features_q(hf, hb)
            Yq = Y
            if mask is not None:
                Q, Yq = Q[mask], Y[mask]
            st.add_int64(Q, Yq)
    return {"Gf": Gf, "Pf": Pf, "stats": st}


def ridge_numpy(Gf, Pf, N, lam_rel):
    D = Gf.shape[0]
    lam = lam_rel * np.trace(Gf[:D - 1, :D - 1]) / (D - 1)
    A = Gf.copy()
    A[np.arange(D - 1), np.arange(D - 1)] += lam
    W = np.linalg.solve(A, Pf)
    M = Pf.shape[1]
    Cf = W[:N, :].T.reshape(-1)
    Cb = W[N:2 * N, :].T.reshape(-1)
    d = W[2 * N, :]
    return Readout(M, N, Cf, Cb, d)


def int_to_float(v):
    return float(int(v))


def cholesky_solve_exact(G, P, N, lam_rel):
    """Scalar replica of LiquidLearn.solve: same operations in the same order, so the
    readout bytes are bit-identical to the Luau result."""
    D = len(G)
    M = len(P[0])
    A = [[int_to_float(G[min(i, j)][max(i, j)]) for j in range(D)] for i in range(D)]
    tr = 0.0
    for i in range(D - 1):
        tr = tr + A[i][i]
    lam = lam_rel * (tr / (D - 1))
    for i in range(D - 1):
        A[i][i] = A[i][i] + lam
    L = [[0.0] * D for _ in range(D)]
    for j in range(D):
        s = A[j][j]
        for k in range(j):
            s = s - L[j][k] * L[j][k]
        if not s > 0.0:
            raise ValueError("matrix not positive definite at %d" % j)
        L[j][j] = math.sqrt(s)
        for i in range(j + 1, D):
            s = A[i][j]
            for k in range(j):
                s = s - L[i][k] * L[j][k]
            L[i][j] = s / L[j][j]
    W = [[0.0] * M for _ in range(D)]
    for m in range(M):
        yv = [0.0] * D
        for i in range(D):
            s = int_to_float(P[i][m])
            for k in range(i):
                s = s - L[i][k] * yv[k]
            yv[i] = s / L[i][i]
        for i in range(D - 1, -1, -1):
            s = yv[i]
            for k in range(i + 1, D):
                s = s - L[k][i] * W[k][m]
            W[i][m] = s / L[i][i]
    Cf, Cb, d = [0.0] * (M * N), [0.0] * (M * N), [0.0] * M
    for m in range(M):
        for i in range(N):
            Cf[m * N + i] = W[i][m] * float(QSCALE)
            Cb[m * N + i] = W[N + i][m] * float(QSCALE)
        d[m] = W[2 * N][m] * float(QSCALE)
    return Readout(M, N, Cf, Cb, d)


def ridge_exact(stats, N, lam_rel):
    return cholesky_solve_exact(stats.G.tolist(), stats.P.tolist(), N, lam_rel)


DEFAULT_LAMBDA = 1e-7
TWO32 = 1 << 32


def stats_entries(st):
    """Entries in the LiquidLearn order: G upper triangle (row-major), P (D x M), YY, count."""
    D, M = st.D, st.M
    out = []
    for i in range(D):
        for j in range(i, D):
            out.append(int(st.G[i][j]))
    for i in range(D):
        for m in range(M):
            out.append(int(st.P[i][m]))
    out.extend(int(v) for v in st.YY)
    out.append(int(st.count))
    return out


def limbs(v):
    """Canonical two-limb form (hi, lo) with 0 <= lo < 2^32."""
    return v >> 32, v & 0xFFFFFFFF


def fingerprint(res, M):
    """LiquidLearn.fingerprint: lowbias32 chain over (1, N, I, K, M, QSCALE) then the reservoir bytes."""
    def h32(x):
        return int(targets.hash32(np.uint64(x)))
    h = 0x414C4E31
    for v in (1, res.N, res.I, res.K, M, QSCALE):
        h = h32(h ^ v)
    for c in encode_reservoir(res):
        h = h32(h ^ c)
    return h


def train(res, tree, target, r=0, stride=1, lam_rel=DEFAULT_LAMBDA, exact=False):
    acc = accumulate(res, tree, target, r, stride, want=("float", "exact") if exact else ("float",))
    ro = ridge_numpy(acc["Gf"], acc["Pf"], res.N, lam_rel)
    rox = ridge_exact(acc["stats"], res.N, lam_rel) if exact else None
    return ro, rox, acc


# ---------------------------------------------------------------------------
# rendering, events and metrics
# ---------------------------------------------------------------------------

def render(res, ro, tree, r=0, eps=0.0, want_events=False):
    """Exact model (eps = 0: every pixel stepped and evaluated) or the event model:
    a pixel is filled with the quantised limit colour of its segment when the T2
    bound sum_i |Cf_mi||hf_i - b_i| + |Cb_mi||hb_i - b_i| <= eps for every channel m
    (the bound covers all later pixels because |h - b| is non-increasing inside a
    segment). Events = explicitly evaluated pixels + one per filled span; rows whose
    leaf sequence equals the previous row's are one copy event (band reuse)."""
    Wr, Hr = tree.width << r, tree.height << r
    out = np.empty((Hr, Wr, ro.M), dtype=np.uint8)
    Cf, Cb, d = ro.arrays()
    ev_rows = np.zeros(tree.height)
    lid = tree.leaf_id_map()
    for rows in row_blocks(tree, 128):
        lr, hf, hb, bp = simulate_rows(res, tree, r, rows)
        z = readout_z(ro, hf, hb)
        q = quantise(z)
        if eps > 0.0 or want_events:
            zinf = readout_z(ro, bp, bp)
            qinf = quantise(zinf)
            ef = np.abs(hf - bp)
            eb = np.abs(hb - bp)
            fill = np.ones(lr.shape, dtype=bool)
            for m in range(ro.M):
                bound = ef @ np.abs(Cf[m]) + eb @ np.abs(Cb[m])
                fill &= bound <= eps
            if eps > 0.0:
                q = np.where(fill[..., None], qinf, q)
            # spans: maximal runs of filled pixels inside one segment
            same_seg = np.concatenate([np.zeros((lr.shape[0], 1), bool), lr[:, 1:] == lr[:, :-1]], axis=1)
            span_start = fill & ~(same_seg & np.concatenate([np.zeros((lr.shape[0], 1), bool), fill[:, :-1]], axis=1))
            ev = (~fill).sum(axis=1) + span_start.sum(axis=1)
            ev_rows[rows] = ev
        out[(rows[:, None] * (1 << r) + np.arange(1 << r)[None, :]).reshape(-1)] = expand_rows(q, r)
    if not want_events:
        return out, None
    # band reuse: tree row y equal to row y-1 (same leaves) is one copy
    dup = np.zeros(tree.height, dtype=bool)
    dup[1:] = (lid[1:] == lid[:-1]).all(axis=1)
    distinct_ev = ev_rows[~dup].sum()
    amort = (distinct_ev + dup.sum() + tree.height * ((1 << r) - 1)) / Hr
    return out, {"events_per_row": float(ev_rows.mean()), "events_per_row_amortised": float(amort),
                 "distinct_rows": int((~dup).sum()), "rows": int(tree.height)}


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return float("inf") if mse == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)


def max_err(a, b):
    return int(np.max(np.abs(a.astype(np.int64) - b.astype(np.int64))))


def png_bytes(img):
    from PIL import Image
    import io
    tot = 0
    C = img.shape[2]
    for c0 in range(0, C, 4):
        part = img[..., c0:c0 + 4]
        if part.shape[2] == 2:
            part = np.dstack([part, np.zeros_like(part[..., :1])])
        mode = {1: "L", 3: "RGB", 4: "RGBA"}[part.shape[2]]
        buf = io.BytesIO()
        Image.fromarray(np.ascontiguousarray(part), mode=mode).save(buf, format="PNG", optimize=True)
        tot += buf.getbuffer().nbytes
    return tot


def raw_rgba8_bytes(H, W, M):
    return H * W * 4 * ((M + 3) // 4)


# ---------------------------------------------------------------------------
# pure-Python scalar reference renderer (no numpy): golden vectors
# ---------------------------------------------------------------------------

def scalar_reference_render(data, r=0):
    """Decodes ALN bytes and renders every pixel with the exact Luau order, using only
    Python floats. Returns bytes of M channels per pixel, row-major."""
    res, ro, tree = decode(data)
    N, I, M, K = res.N, res.I, ro.M, res.K
    W, H = tree.width, tree.height
    leaves = [(int(tree.lx[k]), int(tree.ly[k]), int(tree.lsl[k]), [int(v) for v in tree.lbytes[k]])
              for k in range(tree.leaves)]
    gtab = [1.0]
    for _ in range(1, max(K, 1)):
        gtab.append(gtab[-1] * 0.5)
    out = bytearray(W * H * M << (2 * r))
    Wr = W << r
    for yr in range(H << r):
        y = yr >> r
        segs = []  # (x0, x1, leaf) at render scale, increasing x
        for (lx, ly, sl, lb) in leaves:
            s = 1 << sl
            if ly <= y < ly + s and lx < W:
                segs.append(((lx << r), (min(lx + s, W) << r), sl, lb))
        segs.sort()
        bseg, gseg = [], []
        for (_, _, sl, lb) in segs:
            bs, gs = [], []
            for i in range(N):
                b = res.beta[i]
                for t in range(I):
                    b = b + res.B[i * I + t] * (lb[t] / 255.0)
                bs.append(b)
                k = res.kbase[i] + sl + r
                k = 0 if k < 0 else (K - 1 if k > K - 1 else k)
                gs.append(gtab[int(k)])
            bseg.append(bs)
            gseg.append(gs)
        hf = [[0.0] * N for _ in range(Wr)]
        hb = [[0.0] * N for _ in range(Wr)]
        h = list(bseg[0])
        for si, (x0, x1, _, _) in enumerate(segs):
            bs, gs = bseg[si], gseg[si]
            for x in range(x0, x1):
                for i in range(N):
                    h[i] = h[i] + (bs[i] - h[i]) * gs[i]
                hf[x] = list(h)
        h = list(bseg[-1])
        for si in range(len(segs) - 1, -1, -1):
            x0, x1 = segs[si][0], segs[si][1]
            bs, gs = bseg[si], gseg[si]
            for x in range(x1 - 1, x0 - 1, -1):
                for i in range(N):
                    h[i] = h[i] + (bs[i] - h[i]) * gs[i]
                hb[x] = list(h)
        for x in range(Wr):
            for m in range(M):
                z = ro.d[m]
                for i in range(N):
                    z = z + ro.Cf[m * N + i] * hf[x][i]
                for i in range(N):
                    z = z + ro.Cb[m * N + i] * hb[x][i]
                v = math.floor(z + 0.5)
                out[(yr * Wr + x) * M + m] = 0 if v < 0 else (255 if v > 255 else v)
    return bytes(out)


# ---------------------------------------------------------------------------
# helpers for experiments
# ---------------------------------------------------------------------------

def target_image(name, size, seed):
    return targets.make(name, size=size, seed=seed)


def evaluate(name, img, N, theta, eps_list, lam_rel=DEFAULT_LAMBDA, res=None, tree=None, stride=1):
    H, W, C = img.shape
    if tree is None:
        tree = build_tree(img, theta)
    if res is None:
        res = walsh_reservoir(N, C)
    ro, _, _ = train(res, tree, img, stride=stride, lam_rel=lam_rel)
    blob = encode(res, ro, tree)
    pc = piecewise_constant(tree)
    rows = []
    for eps in eps_list:
        out, ev = render(res, ro, tree, 0, eps, want_events=True)
        rows.append({
            "target": name, "N": N, "theta": theta, "eps": eps, "size": W,
            "psnr": psnr(out, img), "max_err": max_err(out, img),
            "psnr_pc": psnr(pc, img), "max_err_pc": max_err(pc, img),
            "events_per_row": ev["events_per_row"], "events_per_row_amortised": ev["events_per_row_amortised"],
            "leaves": tree.leaves, "bytes": len(blob), "bytes_zlib": len(zlib.compress(blob, 9)),
            "raw_rgba8": raw_rgba8_bytes(H, W, C),
        })
    return rows, res, ro, tree


# ---------------------------------------------------------------------------
# golden vectors and the Python <-> Luau cross-check data
# ---------------------------------------------------------------------------

def lua_num(v):
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    r = repr(float(v))
    return r if r not in ("inf", "-inf", "nan") else {"inf": "math.huge", "-inf": "-math.huge"}[r]


def lua_list(vals):
    return "{ " + ", ".join(lua_num(v) for v in vals) + " }"


def z_values(res, ro, tree, r=0):
    zs = []
    for rows in row_blocks(tree, 64):
        _, hf, hb, _ = simulate_rows(res, tree, r, rows)
        zs.append(expand_rows(readout_z(ro, hf, hb), r))
    return np.concatenate(zs, axis=0)


def golden_case(name, size, seed, theta, N, r=0, lam=DEFAULT_LAMBDA):
    """Builds one cross-check case. r = 1 trains on leaves of the 2x box-downsampled
    image against the full-resolution target (X4 learned detail)."""
    full = target_image(name, size, seed)
    M = full.shape[2]
    if r:
        src = full.reshape(size // 2, 2, size // 2, 2, M).astype(np.int64).sum(axis=(1, 3))
        src = ((src + 2) // 4).astype(np.uint8)
    else:
        src = full
    tree = build_tree(src, theta)
    res = walsh_reservoir(N, M)
    acc = accumulate(res, tree, full, r, 1, want=("float", "exact"))
    acc4 = accumulate(res, tree, full, r, 4, want=("exact",))
    ro_np = ridge_numpy(acc["Gf"], acc["Pf"], N, lam)
    ro_x = ridge_exact(acc["stats"], N, lam)
    ro_x4 = ridge_exact(acc4["stats"], N, lam)
    dz = float(np.max(np.abs(z_values(res, ro_x, tree, r) - z_values(res, ro_np, tree, r))))
    blob = encode(res, ro_x, tree)
    t0 = time.time()
    pix = scalar_reference_render(blob, r)
    t_ref = time.time() - t0
    vec = render(res, ro_x, tree, r)[0]
    assert pix == vec.tobytes(), "scalar reference and vectorised render disagree"
    e1 = stats_entries(acc["stats"])
    e4 = stats_entries(acc4["stats"])
    return {
        "name": name, "size": size, "seed": seed, "theta": theta, "N": N, "M": M, "K": res.K, "r": r,
        "lambda": lam, "scales": DEFAULT_SCALES, "src": src, "full": full, "tree": encode_tree(tree),
        "e1": e1, "e4": e4, "ro_x": readout_bytes(ro_x), "ro_x4": readout_bytes(ro_x4),
        "ro_np": readout_bytes(ro_np), "dz": dz, "blob": blob, "pix": pix, "fp": fingerprint(res, M),
        "psnr": psnr(np.frombuffer(pix, np.uint8).reshape(full.shape), full), "t_ref": t_ref,
        "leaves": tree.leaves,
    }


def write_golden_module(path, cases):
    lines = ["-- Generated by tools/liquid_train.py golden. Do not edit.",
             "-- Cross-check and golden vectors for tests/liquid_learn.test.luau: targets, the",
             "-- exact quadtree bytes, exact statistics (canonical limbs), readout bytes of the",
             "-- exact integer path (stride 1 and 4), the numpy float readout, and the exact",
             "-- quantised pixels of the exported model from a pure-Python scalar reference.",
             "return {"]
    for c in cases:
        h1 = [limbs(v) for v in c["e1"]]
        h4 = [limbs(v) for v in c["e4"]]
        lines += [
            "\t{",
            '\t\tname = "%s %dx%d seed %d theta %d N %d r %d",' % (c["name"], c["size"], c["size"], c["seed"],
                                                                   c["theta"], c["N"], c["r"]),
            "\t\tsize = %d, r = %d, theta = %d, N = %d, M = %d, K = %d," % (c["size"], c["r"], c["theta"], c["N"],
                                                                              c["M"], c["K"]),
            "\t\tlambda = %s," % lua_num(c["lambda"]),
            "\t\tscales = %s," % lua_list(c["scales"]),
            "\t\tleaves = %d," % c["leaves"],
            "\t\tfingerprint = %d," % c["fp"],
            '\t\tsource = "%s",' % c["src"].tobytes().hex(),
            '\t\ttarget = "%s",' % c["full"].tobytes().hex(),
            '\t\ttree = "%s",' % c["tree"].hex(),
            "\t\tstats1Hi = %s," % lua_list([h for h, _ in h1]),
            "\t\tstats1Lo = %s," % lua_list([l for _, l in h1]),
            "\t\tstats4Hi = %s," % lua_list([h for h, _ in h4]),
            "\t\tstats4Lo = %s," % lua_list([l for _, l in h4]),
            '\t\treadoutExact = "%s",' % c["ro_x"].hex(),
            '\t\treadoutExact4 = "%s",' % c["ro_x4"].hex(),
            '\t\treadoutNumpy = "%s",' % c["ro_np"].hex(),
            "\t\tnumpyMaxDz = %s," % lua_num(c["dz"]),
            '\t\tmodel = "%s",' % c["blob"].hex(),
            '\t\tpixels = "%s",' % c["pix"].hex(),
            "\t},",
        ]
    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def cmd_golden(a):
    os.makedirs(ASSETS, exist_ok=True)
    cases = [
        golden_case("sdf_logo", 64, 1, 8, 6, 0),
        golden_case("ui_flat", 64, 2, 4, 8, 0),
        golden_case("marble", 64, 3, 16, 6, 1),
    ]
    for c in cases:
        tag = "%s%d_r%d" % (c["name"], c["size"], c["r"])
        with open(os.path.join(ASSETS, "golden_%s.aln" % tag), "wb") as f:
            f.write(c["blob"])
        with open(os.path.join(ASSETS, "golden_%s.pixels" % tag), "wb") as f:
            f.write(c["pix"])
        print("%-22s leaves %5d  model %6d B  psnr %.2f dB  numpy-vs-exact max|dz| %.3g  scalar ref %.2fs" % (
            tag, c["leaves"], len(c["blob"]), c["psnr"], c["dz"], c["t_ref"]))
    write_golden_module(os.path.join(ASSETS, "golden.luau"), cases)
    print("wrote", os.path.join(ASSETS, "golden.luau"))


# ---------------------------------------------------------------------------
# quality sweeps
# ---------------------------------------------------------------------------

RGB_TARGETS = ["ui_flat", "sdf_logo", "marble", "wood", "caustics"]
ALL_TARGETS = RGB_TARGETS + ["pbr_stones"]


def n_levels(I):
    return [4, 8, 16] if I <= 4 else [8, 16, 24]


def segments_per_row(tree):
    lid = tree.leaf_id_map()
    return float((np.concatenate([np.ones((tree.height, 1), bool), lid[:, 1:] != lid[:, :-1]], axis=1)).sum(1).mean())


def sweep_target(name, size, seed, thetas, eps_list, lam=DEFAULT_LAMBDA, Ns=None, previews=None):
    img = target_image(name, size, seed)
    H, W, C = img.shape
    png = png_bytes(img)
    rows = []
    for theta in thetas:
        tree = build_tree(img, theta)
        pc = piecewise_constant(tree)
        segs = segments_per_row(tree)
        for N in (Ns or n_levels(C)):
            res = walsh_reservoir(N, C)
            ro, _, _ = train(res, tree, img, lam_rel=lam)
            blob = encode(res, ro, tree)
            zb = len(zlib.compress(blob, 9))
            for eps in eps_list:
                out, ev = render(res, ro, tree, 0, eps, want_events=True)
                rows.append({
                    "target": name, "size": W, "theta": theta, "N": N, "eps": eps,
                    "psnr": round(psnr(out, img), 3), "max_err": max_err(out, img),
                    "psnr_quadtree": round(psnr(pc, img), 3), "max_err_quadtree": max_err(pc, img),
                    "events_per_row": round(ev["events_per_row"], 2),
                    "events_per_row_amortised": round(ev["events_per_row_amortised"], 2),
                    "segments_per_row": round(segs, 2), "leaves": tree.leaves,
                    "bytes": len(blob), "bytes_zlib": zb, "png_bytes": png,
                    "raw_rgba8_bytes": raw_rgba8_bytes(H, W, C),
                })
                if previews is not None and theta == 8 and N == (8 if C <= 4 else 16) and eps == 0.5:
                    previews[name] = (img, out)
            print("%-10s theta %2d N %2d leaves %6d psnr(eps=0) %6.2f quadtree %6.2f ev/row %6.1f bytes %7d png %7d" % (
                name, theta, N, tree.leaves, rows[-len(eps_list)]["psnr"], rows[-1]["psnr_quadtree"],
                rows[-len(eps_list)]["events_per_row"], len(blob), png), flush=True)
    return rows


def save_preview(path, img, out):
    from PIL import Image
    C = img.shape[2]
    a = img[..., :3]
    b = out[..., :3]
    err = np.clip(np.abs(a.astype(np.int64) - b.astype(np.int64)) * 8, 0, 255).astype(np.uint8)
    sheet = np.concatenate([a, b, err], axis=1)
    if C > 3:
        a2 = np.dstack([img[..., 3], img[..., 4], img[..., 5]])
        b2 = np.dstack([out[..., 3], out[..., 4], out[..., 5]])
        e2 = np.clip(np.abs(a2.astype(np.int64) - b2.astype(np.int64)) * 8, 0, 255).astype(np.uint8)
        sheet = np.concatenate([sheet, np.concatenate([a2, b2, e2], axis=1)], axis=0)
    Image.fromarray(sheet).save(path, optimize=True)


def cmd_sweep(a):
    out_dir = os.path.join(ASSETS, "results")
    os.makedirs(out_dir, exist_ok=True)
    prev_dir = os.path.join(ASSETS, "previews")
    os.makedirs(prev_dir, exist_ok=True)
    thetas = [int(t) for t in a.thetas.split(",")]
    eps_list = [float(e) for e in a.eps.split(",")]
    names = a.targets.split(",") if a.targets else ALL_TARGETS
    rows = []
    previews = {}
    t0 = time.time()
    for name in names:
        rows += sweep_target(name, a.size, a.seed, thetas, eps_list, previews=previews)
    for name, (img, out) in previews.items():
        save_preview(os.path.join(prev_dir, "%s_%d.png" % (name, a.size)), img, out)
    path = os.path.join(out_dir, "sweep%d.json" % a.size)
    with open(path, "w") as f:
        json.dump({"size": a.size, "seed": a.seed, "lambda": DEFAULT_LAMBDA, "scales": DEFAULT_SCALES,
                   "rows": rows, "seconds": round(time.time() - t0, 1)}, f, indent=0)
    print("wrote", path)


def cmd_headline(a):
    """One configuration per target at a large size (default 1024): N = 8 (16 for PBR),
    theta = 8, eps in {0, 0.5}."""
    out_dir = os.path.join(ASSETS, "results")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for name in ALL_TARGETS:
        t0 = time.time()
        img = target_image(name, a.size, a.seed)
        C = img.shape[2]
        N = 8 if C <= 4 else 16
        r = sweep_target(name, a.size, a.seed, [a.theta], [0.0, 0.5, 1.0], Ns=[N])
        for row in r:
            row["seconds"] = round(time.time() - t0, 1)
        rows += r
    path = os.path.join(out_dir, "headline%d.json" % a.size)
    with open(path, "w") as f:
        json.dump({"size": a.size, "seed": a.seed, "theta": a.theta, "rows": rows}, f, indent=0)
    print("wrote", path)


# ---------------------------------------------------------------------------
# X4: learned detail above the source resolution
# ---------------------------------------------------------------------------

def box_down2(img):
    H, W, C = img.shape
    s = img.reshape(H // 2, 2, W // 2, 2, C).astype(np.int64).sum(axis=(1, 3))
    return ((s + 2) // 4).astype(np.uint8)


def bilinear_up2(img):
    """Bilinear 2x upsample with half-pixel centres and clamped edges (what an engine
    bilinear magnification shows)."""
    H, W, C = img.shape
    f = img.astype(np.float64)

    def axis_up(a, axis):
        n = a.shape[axis]
        idx = (np.arange(2 * n) + 0.5) / 2.0 - 0.5
        i0 = np.clip(np.floor(idx).astype(np.int64), 0, n - 1)
        i1 = np.clip(i0 + 1, 0, n - 1)
        t = np.clip(idx - np.floor(idx), 0.0, 1.0)
        t = np.where(idx < 0, 0.0, t)
        a0 = np.take(a, i0, axis=axis)
        a1 = np.take(a, i1, axis=axis)
        shape = [1] * a.ndim
        shape[axis] = -1
        return a0 + (a1 - a0) * t.reshape(shape)

    return np.clip(np.floor(axis_up(axis_up(f, 0), 1) + 0.5), 0, 255).astype(np.uint8)


def grad_energy(img):
    f = img.astype(np.float64)
    gx = np.abs(np.diff(f, axis=1)).mean()
    gy = np.abs(np.diff(f, axis=0)).mean()
    return gx, gy


def cmd_x4(a):
    out_dir = os.path.join(ASSETS, "results")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    names = a.targets.split(",") if a.targets else ALL_TARGETS
    for name in names:
        truth = {s: target_image(name, a.size, s) for s in (a.train_seed, a.test_seed)}
        src = {s: box_down2(truth[s]) for s in truth}
        trees = {s: build_tree(src[s], a.theta) for s in truth}
        C = truth[a.test_seed].shape[2]
        N = a.N if C <= 4 else max(a.N, 16)
        res = walsh_reservoir(N, C)
        T, S = a.test_seed, a.train_seed
        gt = truth[T]
        out = {}
        out["nearest"] = np.repeat(np.repeat(src[T], 2, axis=0), 2, axis=1)
        out["bilinear"] = bilinear_up2(src[T])
        pc = piecewise_constant(trees[T])
        out["quadtree_nearest"] = np.repeat(np.repeat(pc, 2, axis=0), 2, axis=1)
        # ALLAN trained at the source resolution (r = 0, targets = source), drawn at 2x
        ro_src, _, _ = train(res, trees[S], src[S], r=0)
        out["allan_source_trained"] = render(res, ro_src, trees[T], 1)[0]
        # X4: trained at 2x against the full-resolution truth of another seed
        ro_x4, _, _ = train(res, trees[S], truth[S], r=1)
        out["allan_x4_learned"] = render(res, ro_x4, trees[T], 1)[0]
        # oracle: the readout fitted on the test image itself (upper bound of a linear readout)
        ro_or, _, _ = train(res, trees[T], truth[T], r=1)
        out["allan_x4_oracle"] = render(res, ro_or, trees[T], 1)[0]
        gtx, gty = grad_energy(gt)
        for k, v in out.items():
            gx, gy = grad_energy(v)
            rows.append({"target": name, "size": a.size, "theta": a.theta, "N": N, "method": k,
                         "psnr": round(psnr(v, gt), 3), "max_err": max_err(v, gt),
                         "grad_x_ratio": round(gx / gtx, 3), "grad_y_ratio": round(gy / gty, 3)})
            print("%-10s %-22s psnr %6.2f  max %3d  grad x %.2f y %.2f" % (
                name, k, rows[-1]["psnr"], rows[-1]["max_err"], rows[-1]["grad_x_ratio"], rows[-1]["grad_y_ratio"]),
                flush=True)
    path = os.path.join(out_dir, "x4_%d.json" % a.size)
    with open(path, "w") as f:
        json.dump({"size": a.size, "theta": a.theta, "train_seed": a.train_seed, "test_seed": a.test_seed,
                   "note": "learned, not recovered: the 2x detail is predicted by a readout trained on another "
                           "seed of the same family", "rows": rows}, f, indent=0)
    print("wrote", path)


# ---------------------------------------------------------------------------
# Proposal (not in format v1): ALLAN-2D, separable liquid states
# ---------------------------------------------------------------------------
# The same liquid cells also run down every column (vertical forward and backward
# passes over the leaves a column crosses, same b, same gains), and the readout sees
# s = (hf, hb, vf, vb, 1), D = 4N + 1. Measured here to settle LIQUID.md open point 1.

def simulate_axis(res, tree, r, axis):
    """States along rows (axis 1) or columns (axis 0) at scale 2^r in both directions."""
    lid = tree.leaf_id_map()
    rep = 1 << r
    L = np.repeat(np.repeat(lid, rep, axis=0), rep, axis=1)
    if axis == 0:
        L = L.T
    bl, gl = leaf_targets_gains(res, tree, r)
    bp, gp = bl[L], gl[L]
    R, Wd, N = bp.shape
    hf = np.empty_like(bp)
    hb = np.empty_like(bp)
    h = bp[:, 0, :].copy()
    for x in range(Wd):
        h = h + (bp[:, x, :] - h) * gp[:, x, :]
        hf[:, x, :] = h
    h = bp[:, Wd - 1, :].copy()
    for x in range(Wd - 1, -1, -1):
        h = h + (bp[:, x, :] - h) * gp[:, x, :]
        hb[:, x, :] = h
    if axis == 0:
        hf = hf.transpose(1, 0, 2)
        hb = hb.transpose(1, 0, 2)
    return hf, hb


def fit_features(X, Y, lam):
    D = X.shape[1]
    G = X.T @ X
    P = X.T @ Y
    lamv = lam * np.trace(G[:D - 1, :D - 1]) / (D - 1)
    G[np.arange(D - 1), np.arange(D - 1)] += lamv
    return np.linalg.solve(G, P)


def features_2d(res, tree, r, two_d):
    hf, hb = simulate_axis(res, tree, r, 1)
    parts = [hf, hb]
    if two_d:
        vf, vb = simulate_axis(res, tree, r, 0)
        parts += [vf, vb]
    H, W = hf.shape[:2]
    X = np.concatenate([p.reshape(H * W, -1) for p in parts] + [np.ones((H * W, 1))], axis=1)
    return X, (H, W)


def predict(X, Wt, shape):
    return quantise(X @ Wt).reshape(shape + (Wt.shape[1],))


def cmd_twod(a):
    out_dir = os.path.join(ASSETS, "results")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    names = a.targets.split(",") if a.targets else ALL_TARGETS
    for name in names:
        img = target_image(name, a.size, a.seed)
        C = img.shape[2]
        N = a.N if C <= 4 else max(a.N, 16)
        res = walsh_reservoir(N, C)
        Y = img.reshape(-1, C).astype(np.float64)
        tree = build_tree(img, a.theta)
        pc = piecewise_constant(tree)
        rec = {"target": name, "size": a.size, "theta": a.theta, "N": N, "leaves": tree.leaves,
               "psnr_quadtree": round(psnr(pc, img), 3)}
        for two_d in (False, True):
            X, shp = features_2d(res, tree, 0, two_d)
            Wt = fit_features(X, Y, DEFAULT_LAMBDA)
            rec["psnr_2d" if two_d else "psnr_1d"] = round(psnr(predict(X, Wt, shp), img), 3)
        # X4 with 2D states: train on seed a.seed (truth 2x), test on seed a.seed + 1
        tr_t = target_image(name, a.size, a.seed)
        te_t = target_image(name, a.size, a.seed + 1)
        tr_tree = build_tree(box_down2(tr_t), a.theta_x4)
        te_tree = build_tree(box_down2(te_t), a.theta_x4)
        for two_d in (False, True):
            Xtr, _ = features_2d(res, tr_tree, 1, two_d)
            Wt = fit_features(Xtr, tr_t.reshape(-1, C).astype(np.float64), DEFAULT_LAMBDA)
            Xte, shp = features_2d(res, te_tree, 1, two_d)
            rec["x4_psnr_2d" if two_d else "x4_psnr_1d"] = round(psnr(predict(Xte, Wt, shp), te_t), 3)
        rec["x4_psnr_bilinear"] = round(psnr(bilinear_up2(box_down2(te_t)), te_t), 3)
        rows.append(rec)
        print(json.dumps(rec), flush=True)
    path = os.path.join(out_dir, "twod_%d.json" % a.size)
    with open(path, "w") as f:
        json.dump({"note": "proposal, not in ALN v1: separable 2D liquid states, D = 4N + 1", "rows": rows}, f,
                  indent=0)
    print("wrote", path)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_export(a):
    img = target_image(a.target, a.size, a.seed)
    rows, res, ro, tree = evaluate(a.target, img, a.N, a.theta, [0.0, a.eps])
    blob = encode(res, ro, tree)
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, "%s_%d_N%d_t%d.aln" % (a.target, a.size, a.N, a.theta))
    with open(path, "wb") as f:
        f.write(blob)
    print(json.dumps(rows, indent=1))
    print("wrote", path, len(blob), "bytes")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("--target", default="sdf_logo")
    e.add_argument("--size", type=int, default=256)
    e.add_argument("--seed", type=int, default=1)
    e.add_argument("--N", type=int, default=8)
    e.add_argument("--theta", type=int, default=8)
    e.add_argument("--eps", type=float, default=0.5)
    e.add_argument("--out", default=os.path.join(ASSETS, "models"))
    e.set_defaults(fn=cmd_export)
    g = sub.add_parser("golden")
    g.set_defaults(fn=cmd_golden)
    s = sub.add_parser("sweep")
    s.add_argument("--size", type=int, default=256)
    s.add_argument("--seed", type=int, default=1)
    s.add_argument("--thetas", default="2,4,8,16,32")
    s.add_argument("--eps", default="0,0.25,0.5,1,2")
    s.add_argument("--targets", default="")
    s.set_defaults(fn=cmd_sweep)
    h = sub.add_parser("headline")
    h.add_argument("--size", type=int, default=1024)
    h.add_argument("--seed", type=int, default=1)
    h.add_argument("--theta", type=int, default=8)
    h.set_defaults(fn=cmd_headline)
    x = sub.add_parser("x4")
    x.add_argument("--size", type=int, default=256, help="full (truth) resolution; the source is size/2")
    x.add_argument("--theta", type=int, default=4)
    x.add_argument("--N", type=int, default=8)
    x.add_argument("--train-seed", dest="train_seed", type=int, default=1)
    x.add_argument("--test-seed", dest="test_seed", type=int, default=2)
    x.add_argument("--targets", default="")
    x.set_defaults(fn=cmd_x4)
    t = sub.add_parser("twod")
    t.add_argument("--size", type=int, default=256)
    t.add_argument("--seed", type=int, default=1)
    t.add_argument("--theta", type=int, default=8)
    t.add_argument("--theta-x4", dest="theta_x4", type=int, default=4)
    t.add_argument("--N", type=int, default=8)
    t.add_argument("--targets", default="")
    t.set_defaults(fn=cmd_twod)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
