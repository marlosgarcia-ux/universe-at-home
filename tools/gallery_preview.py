#!/usr/bin/env python3
"""Turns the hex dump of tools/gallery_preview.luau into PNG files.

usage: luau tools/gallery_preview.luau | python3 tools/gallery_preview.py OUTDIR
"""
import os
import sys

from PIL import Image


def main(outdir: str) -> int:
    os.makedirs(outdir, exist_ok=True)
    name = None
    w = h = 0
    rows: list[bytes] = []

    def flush() -> None:
        nonlocal name, rows
        if name is None:
            return
        if len(rows) != h:
            print(f"{name}: expected {h} rows, got {len(rows)}", file=sys.stderr)
        data = b"".join(rows)
        img = Image.frombytes("RGBA", (w, h), data)
        path = os.path.join(outdir, f"{name}.png")
        img.save(path)
        print(f"wrote {path} ({w}x{h})")
        name, rows = None, []

    for line in sys.stdin:
        line = line.rstrip("\n")
        if line.startswith("PANEL "):
            flush()
            _, name, ws, hs = line.split()
            w, h = int(ws), int(hs)
        elif line.startswith("TIME ") or line.startswith("NOTE "):
            print(line)
        elif name is not None and line:
            # each word is a little-endian u32 printed big-endian: r + g*256 + b*65536 + a*16777216
            words = [int(line[i : i + 8], 16) for i in range(0, len(line), 8)]
            rows.append(b"".join(v.to_bytes(4, "little") for v in words))
    flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "gallery_preview"))
