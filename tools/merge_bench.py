#!/usr/bin/env python3
"""Merge bench/ops.luau result files into markdown tables.

Usage:
    python3 tools/merge_bench.py [--unit ns/op|ns/iter] LABEL=path.tsv[,path2.tsv...] [...]
    python3 tools/merge_bench.py --mixed LABEL=path.tsv[,path2.tsv...]:unit [...]

Several comma-separated files under one label are reduced to the per-key minimum.

Each input holds lines of the form
    RESULT <TAB> group <TAB> name <TAB> value <TAB> unit
The first file sets row order. Kernels get ms and Mpix/s columns per run.
With --mixed, each run names the op unit to show, for example
    interp=x64-interp-O2.tsv:ns/op native=x64-native-O2.tsv:ns/iter
"""
import sys

PIXELS_PER_KERNEL = {
    # kernels that do not produce a full 1024x1024 frame
    "mip 2x2 box: per channel extract": 512 * 512,
    "mip 2x2 box: SWAR (2 channels per op)": 512 * 512,
    "bilinear resample 1024->512 at scale 0.73": 512 * 512,
    "dirty tiles: 16 tiles of 64x64 rewritten": 16 * 64 * 64,
}
FULL_FRAME = 1024 * 1024


def load(path):
    rows = {}
    order = []
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 5 or parts[0] != "RESULT":
                continue
            _, group, name, value, unit = parts
            key = (group, name, unit)
            rows[key] = float(value)
            if (group, name) not in order:
                order.append((group, name))
    return rows, order


def main(argv):
    default_unit = "ns/op"
    mixed = False
    specs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--unit":
            default_unit = argv[i + 1]
            i += 2
            continue
        if a == "--mixed":
            mixed = True
            i += 1
            continue
        specs.append(a)
        i += 1
    if not specs:
        print(__doc__)
        return 1

    runs = []
    for spec in specs:
        label, rest = spec.split("=", 1)
        unit = default_unit
        if mixed and ":" in rest:
            rest, unit = rest.rsplit(":", 1)
        # several comma-separated files per label: keep the per-key minimum, which is
        # the run least disturbed by other work on the machine
        rows, order = {}, []
        for path in rest.split(","):
            r, o = load(path)
            for key, value in r.items():
                rows[key] = value if key not in rows else min(rows[key], value)
            for key in o:
                if key not in order:
                    order.append(key)
        runs.append((label, unit, rows, order))
    order = runs[0][3]

    labels = [f"{label} ({unit})" for label, unit, _, _ in runs]
    print("| group | op | " + " | ".join(labels) + " |")
    print("|---|---|" + "---|" * len(labels))
    for group, name in order:
        if group in ("kernel", "meta"):
            continue
        cells = []
        for _, unit, rows, _ in runs:
            v = rows.get((group, name, unit))
            cells.append("n/a" if v is None else f"{v:.2f}")
        print(f"| {group} | {name} | " + " | ".join(cells) + " |")

    print()
    print("| meta | " + " | ".join(r[0] for r in runs) + " |")
    print("|---|" + "---|" * len(runs))
    for group, name in order:
        if group != "meta":
            continue
        cells = []
        for _, _, rows, _ in runs:
            v = [val for (g, n, u), val in rows.items() if g == group and n == name]
            cells.append("n/a" if not v else f"{v[0]:.2f}")
        print(f"| {name} | " + " | ".join(cells) + " |")

    print()
    header = []
    for label, _, _, _ in runs:
        header += [f"{label} ms", f"{label} Mpix/s"]
    print("| kernel (1024x1024 RGBA8 source) | " + " | ".join(header) + " |")
    print("|---|" + "---|" * len(header))
    for group, name in order:
        if group != "kernel":
            continue
        pixels = PIXELS_PER_KERNEL.get(name, FULL_FRAME)
        cells = []
        for _, _, rows, _ in runs:
            ms = rows.get((group, name, "ms/frame"))
            if ms is None:
                cells += ["n/a", "n/a"]
            else:
                cells += [f"{ms:.2f}", f"{pixels / (ms / 1000) / 1e6:.1f}" if ms > 0 else "inf"]
        print(f"| {name} | " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
