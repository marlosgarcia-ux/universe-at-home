#!/usr/bin/env python3
"""Runs gallery/Gallery.client.luau against a mock of the Roblox API in the Luau CLI.

usage: python3 tools/gallery_mock_run.py [path/to/luau] [--codegen]

Glues tools/gallery_mock_prelude.luau + the script + tools/gallery_mock_check.luau into
tools/.gallery_mock_combined.luau (gitignored), runs it, and exits non-zero on failure.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel: str) -> str:
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def main(argv: list[str]) -> int:
    luau = "/home/user/luau-lang/luau/build/luau"
    extra: list[str] = []
    for a in argv:
        if a == "--codegen":
            extra.append(a)
        else:
            luau = a
    combined = read("tools/gallery_mock_prelude.luau") + "\n" + read("gallery/Gallery.client.luau") + "\n" + read("tools/gallery_mock_check.luau")
    path = os.path.join(ROOT, "tools", ".gallery_mock_combined.luau")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(combined)
    proc = subprocess.run([luau, *extra, path], cwd=ROOT)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
