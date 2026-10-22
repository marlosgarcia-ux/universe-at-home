#!/usr/bin/env python3
"""Merge bench/compute.luau runs into one markdown table.

usage: merge_compute.py INTERP_FILES NATIVE_FILES
Each argument is a comma-separated list of result files (RESULT lines). Times
(unit ms) keep the per-key minimum over runs; every other unit is deterministic
and must be identical in every run of both runtimes (the script says so if not).
"""
import sys


def load(paths):
    rows, order, seen = {}, [], {}
    for path in paths.split(","):
        with open(path) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 5 or parts[0] != "RESULT":
                    continue
                _, group, name, value, unit = parts
                key = (group, name, unit)
                v = float(value)
                seen.setdefault(key, set()).add(v)
                if key not in rows:
                    rows[key] = v
                    order.append(key)
                elif unit == "ms":
                    rows[key] = min(rows[key], v)
    return rows, order, seen


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 1
    ri, order, si = load(argv[1])
    rn, _, sn = load(argv[2])
    nI = len(argv[1].split(","))
    nN = len(argv[2].split(","))
    cal_i = ri.get(("calibration", "writeu32 constant, 1024^2", "ms"))
    cal_n = rn.get(("calibration", "writeu32 constant, 1024^2", "ms"))
    print(f"Minimum of {nI} interpreter runs and {nN} native runs (`--codegen`), each value itself the minimum of 1 to 5 in-process repeats. "
          "Machine: Intel Xeon @ 2.10 GHz, 4 vCPU virtualised, shared with other agents, so absolute times swing by up to 4x between quiet and busy periods; "
          "the calibration row (a constant `writeu32` over 1024 x 1024; RUNTIME_AUDIT 6.6 measured 10.3 ms interpreted, 2.9 ms native) shows how fast the machine was. "
          "Times are ms per full 1024 x 1024 frame unless the row says otherwise.\n")
    print("| group | measurement | interp O2 | native O2 | unit |")
    print("|---|---|---|---|---|")
    mismatches = []
    for key in order:
        group, name, unit = key
        a = ri.get(key)
        b = rn.get(key)
        fa = "n/a" if a is None else (f"{a:.2f}" if unit != "count" else f"{a:.0f}")
        fb = "n/a" if b is None else (f"{b:.2f}" if unit != "count" else f"{b:.0f}")
        if unit != "ms":
            vals = si.get(key, set()) | sn.get(key, set())
            if len(vals) > 1 and unit in ("err255", "px") or (unit == "count" and group != "raster" and len(vals) > 1):
                mismatches.append(f"{group} / {name}: {sorted(vals)}")
        print(f"| {group} | {name} | {fa} | {fb} | {unit} |")
    print()
    if cal_i and cal_n:
        print(f"Calibration this session: interpreter {cal_i:.2f} ms, native {cal_n:.2f} ms.\n")
    if mismatches:
        print("**Deterministic rows that differ between runs or runtimes:**\n")
        for m in mismatches:
            print(f"- {m}")
    else:
        print("All quality rows (err255, px, count) are identical in every run of both runtimes, except the time-slice tile counts, which depend on speed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
