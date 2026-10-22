#!/usr/bin/env python3
"""Runs the planets client (planets/client) against a mock of the Roblox API in the Luau CLI.

usage: python3 tools/planets_mock_run.py [--codegen] [path/to/luau]

Glues tools/planets_mock/prelude.luau, every client module wrapped as a function of
(script, require), the WorkerPool modules, and tools/planets_mock/check.luau into
tools/.planets_mock_combined.luau (gitignored), runs it, and exits non-zero on failure.
Wrapping lets the client's instance requires (require(script.Parent:WaitForChild("X")))
resolve through the mock DataModel; `export type` becomes `type` because exports are only
legal at a module's top level.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def wrap(name, rel):
    src = read(rel)
    src = re.sub(r"(?m)^export type ", "type ", src)
    return '__defs["%s"] = function(script, require)\n%s\nend\n' % (name, src)


def main(argv):
    luau = "/home/user/luau-lang/luau/build/luau"
    extra = []
    for a in argv:
        if a == "--codegen":
            extra.append(a)
        else:
            luau = a
    parts = [read("tools/planets_mock/prelude.luau")]
    for fn in sorted(os.listdir(os.path.join(ROOT, "planets", "client"))):
        if fn.endswith(".luau"):
            name = fn[: -len(".luau")]
            if name == "Main.client":
                name = "Main"
            parts.append(wrap(name, "planets/client/" + fn))
    parts.append(wrap("WorkerPool", "demo/shared/WorkerPool.luau"))
    parts.append(wrap("WorkerMain", "demo/shared/WorkerMain.luau"))
    parts.append(read("tools/planets_mock/check.luau"))
    path = os.path.join(ROOT, "tools", ".planets_mock_combined.luau")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))
    proc = subprocess.run([luau, *extra, path], cwd=ROOT)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
