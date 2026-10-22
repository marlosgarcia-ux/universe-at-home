#!/usr/bin/env python3
"""Structural checks of the built Planets place (build/UniversePlanets.rbxlx).

Reuses the parser and the Roblox require-by-string resolver of demo/check_place.py and
checks: every module the client and the workers load exists with the right class; the
worker templates are Actors whose scripts are saved Disabled with the intended RunContext;
the client entry point is enabled; properties only the file can carry are present
(Lighting.Technology, TimeOfDay instead of the unsaved ClockTime); every string require in
every script resolves to a ModuleScript in the built DataModel.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("check_place", os.path.join(HERE, "demo", "check_place.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)


def main(path):
    root = cp.load(path)
    failures = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    shared = ["Layout", "Noise3", "CubeSphere", "Bodies", "TileGen", "Quadtree", "SphereCache",
              "Impostor", "SkyGen", "Clouds", "PlanetJobs", "WorkerPool", "WorkerMain"]
    client = ["Uploader", "MeshPool", "PlanetLod", "Impostors", "Sky", "CloudLayer", "Flight", "Hud", "Workers"]
    wanted = [("ReplicatedStorage.Universe.MyMath", "ModuleScript")]
    wanted += [("ReplicatedStorage.Planets." + m, "ModuleScript") for m in shared]
    wanted += [("StarterPlayer.StarterPlayerScripts.Client." + m, "ModuleScript") for m in client]
    wanted += [("StarterPlayer.StarterPlayerScripts.Client.Main", "LocalScript"),
               ("ReplicatedStorage.PlanetWorkers.PlanetWorker", "Actor"),
               ("ReplicatedStorage.PlanetWorkers.PlanetWorkerLocal", "Actor"),
               ("Lighting.Sky", "Sky"), ("Lighting.Bloom", "BloomEffect")]
    for dotted, cls in wanted:
        n = cp.find(root, dotted)
        expect(n is not None, "missing " + dotted)
        if n is not None:
            expect(n.cls == cls, "%s is %s, expected %s" % (dotted, n.cls, cls))

    main_client = cp.find(root, "StarterPlayer.StarterPlayerScripts.Client.Main")
    if main_client is not None:
        expect(not main_client.props.get("Disabled", False), "client Main is disabled")

    def template(dotted, want_class, want_context):
        a = cp.find(root, dotted)
        if a is None:
            return
        scripts = [c for c in a.children if c.cls in ("Script", "LocalScript")]
        expect(len(scripts) == 1, dotted + " must hold exactly one script")
        for s in scripts:
            expect(s.cls == want_class, "%s script is %s, expected %s" % (dotted, s.cls, want_class))
            expect(s.props.get("Disabled") is True, dotted + " script must be saved Disabled=true")
            if want_context is not None:
                rc = s.props.get("RunContext", 0)
                expect(rc == want_context, "%s RunContext %s, expected %s" % (dotted, cp.RUN_CONTEXT.get(rc), cp.RUN_CONTEXT[want_context]))

    template("ReplicatedStorage.PlanetWorkers.PlanetWorker", "Script", 2)
    template("ReplicatedStorage.PlanetWorkers.PlanetWorkerLocal", "LocalScript", None)

    lighting = cp.find(root, "Lighting")
    if lighting is not None:
        expect(lighting.props.get("Technology") == 4, "Lighting.Technology must be Future (4)")
        expect("ClockTime" not in lighting.props, "ClockTime is CanSave=false; use TimeOfDay in the file")
        expect(lighting.props.get("TimeOfDay", "").startswith("14:12"), "Lighting.TimeOfDay is set")
    players = cp.find(root, "Players")
    if players is not None:
        expect(players.props.get("CharacterAutoLoads") is False, "Players.CharacterAutoLoads must be false")
    ws = cp.find(root, "Workspace")
    if ws is not None:
        expect(ws.props.get("StreamingEnabled") is False, "Workspace.StreamingEnabled must be false")

    scripts = []

    def collect(n):
        if n.cls in cp.SCRIPT_CLASSES:
            scripts.append(n)
        for c in n.children:
            collect(c)

    collect(root)
    requires = 0
    for s in scripts:
        src = s.props.get("Source", "")
        for line in src.splitlines():
            code = line.split("--", 1)[0]
            for m in cp.REQUIRE_RE.finditer(code):
                requires += 1
                target, why = cp.resolve(s, m.group(1), root)
                expect(target is not None, '%s: require("%s") does not resolve: %s' % (s.path(), m.group(1), why))
    print("note: %d scripts, %d string requires checked" % (len(scripts), requires))
    if failures:
        for f in failures:
            print("FAIL " + f)
        return 1
    print("place structure OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "build", "UniversePlanets.rbxlx")))
