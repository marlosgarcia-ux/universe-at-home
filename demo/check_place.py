#!/usr/bin/env python3
"""Structural checks of the built Meadow place (build/UniverseMeadow.rbxlx).

Run by tools/build_demo.sh. Verifies what a Studio run would otherwise reveal first:
  * the expected instances exist with the right classes;
  * every require-by-string in every script resolves inside the built DataModel with
    the documented Roblox rules (reference/engine/globals/LuaGlobals.yaml, require:
    "./" starts at script.Parent, "../" at script.Parent.Parent, "@self/" at script,
    "@game/" at game, ".." components go to the parent), and lands on a ModuleScript;
  * worker templates are Actors whose scripts are saved Disabled (BaseScript.Enabled
    is CanLoad=false in the API dump, so the serialized property is Disabled) with the
    intended RunContext;
  * properties scripts cannot set (Lighting.Technology, Terrain.Decoration,
    Terrain.GrassLength) and start-up properties are in the file;
  * script sizes stay reasonable.
Exit status 1 on any failure.
"""
import re
import sys
import xml.etree.ElementTree as ET

SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}
RUN_CONTEXT = {0: "Legacy", 1: "Server", 2: "Client", 3: "Plugin"}


class Node:
    def __init__(self, cls, parent):
        self.cls = cls
        self.parent = parent
        self.props = {}
        self.children = []
        self.name = ""

    def child(self, name):
        for c in self.children:
            if c.name == name:
                return c
        return None

    def path(self):
        parts = []
        n = self
        while n is not None and n.parent is not None:
            parts.append(n.name)
            n = n.parent
        return ".".join(reversed(parts))


def load(path):
    tree = ET.parse(path)
    root = Node("DataModel", None)
    root.name = "game"

    def walk(elem, parent):
        for item in elem.findall("Item"):
            n = Node(item.get("class"), parent)
            props = item.find("Properties")
            if props is not None:
                for p in props:
                    name = p.get("name")
                    text = p.text or ""
                    if p.tag == "bool":
                        n.props[name] = text.strip() == "true"
                    elif p.tag in ("token", "int", "int64"):
                        n.props[name] = int(text.strip())
                    elif p.tag in ("float", "double"):
                        n.props[name] = float(text.strip())
                    else:
                        n.props[name] = text
            n.name = n.props.get("Name", "")
            parent.children.append(n)
            walk(item, n)

    walk(tree.getroot(), root)
    return root


def find(root, dotted):
    n = root
    for part in dotted.split("."):
        n = n.child(part) if n else None
        if n is None:
            return None
    return n


def resolve(script, path, root):
    """Roblox require-by-string resolution. Returns (node or None, reason)."""
    if path.startswith("./"):
        cur, rest = script.parent, path[2:]
    elif path.startswith("../"):
        cur = script.parent.parent if script.parent else None
        rest = path[3:]
    elif path.startswith("@self/"):
        cur, rest = script, path[6:]
    elif path.startswith("@game/"):
        cur, rest = root, path[6:]
    else:
        return None, "unsupported prefix"
    for comp in [c for c in rest.split("/") if c]:
        if cur is None:
            return None, "walked above game"
        if comp == "..":
            cur = cur.parent
        else:
            cur = cur.child(comp)
            if cur is None:
                return None, "no child " + comp
    if cur is None:
        return None, "resolved to nothing"
    if cur.cls != "ModuleScript":
        return None, "resolves to a " + cur.cls
    return cur, "ok"


REQUIRE_RE = re.compile(r"""require\(\s*"([^"]+)"\s*\)""")


def main(path):
    root = load(path)
    failures = []
    notes = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)

    def node(dotted, cls=None):
        n = find(root, dotted)
        expect(n is not None, "missing " + dotted)
        if n is not None and cls:
            expect(n.cls == cls, "%s is %s, expected %s" % (dotted, n.cls, cls))
        return n

    # services and entry points
    for dotted, cls in [
        ("ReplicatedStorage.Universe.MyMath", "ModuleScript"),
        ("ReplicatedStorage.Universe.Pixels", "ModuleScript"),
        ("ReplicatedStorage.Universe.Canvas", "ModuleScript"),
        ("ReplicatedStorage.Universe.compute.Raster", "ModuleScript"),
        ("ReplicatedStorage.Demo.Config", "ModuleScript"),
        ("ReplicatedStorage.Demo.WorldGen", "ModuleScript"),
        ("ReplicatedStorage.Demo.Net", "ModuleScript"),
        ("ReplicatedStorage.Demo.Status", "ModuleScript"),
        ("ReplicatedStorage.Demo.WorkerPool", "ModuleScript"),
        ("ReplicatedStorage.Demo.WorkerMain", "ModuleScript"),
        ("ServerScriptService.Server.Main", "Script"),
        ("StarterPlayer.StarterPlayerScripts.Client.Main", "LocalScript"),
        ("ServerScriptService.Workers.ServerWorker", "Actor"),
        ("Lighting.Atmosphere", "Atmosphere"),
        ("Lighting.Sky", "Sky"),
        ("Workspace.Terrain", "Terrain"),
        ("Workspace.Terrain.Clouds", "Clouds"),
    ]:
        node(dotted, cls)

    main_server = find(root, "ServerScriptService.Server.Main")
    if main_server is not None:
        rc = main_server.props.get("RunContext", 0)
        expect(rc in (0, 1), "server Main must run on the server (RunContext %s)" % RUN_CONTEXT.get(rc))
        expect(not main_server.props.get("Disabled", False), "server Main is disabled")
    main_client = find(root, "StarterPlayer.StarterPlayerScripts.Client.Main")
    if main_client is not None:
        expect(not main_client.props.get("Disabled", False), "client Main is disabled")

    # worker templates: Actors with one disabled script of the right run context
    def template(dotted, want_class, want_context):
        a = find(root, dotted)
        if a is None:
            return False
        expect(a.cls == "Actor", dotted + " must be an Actor")
        scripts = [c for c in a.children if c.cls in ("Script", "LocalScript")]
        expect(len(scripts) == 1, dotted + " must hold exactly one script")
        for s in scripts:
            expect(s.cls == want_class, "%s script is %s, expected %s" % (dotted, s.cls, want_class))
            expect(s.props.get("Disabled") is True, dotted + " script must be saved Disabled=true (templates must not run)")
            expect("Enabled" not in s.props, dotted + " uses Enabled, which Studio does not load (CanLoad=false)")
            if want_context is not None:
                rc = s.props.get("RunContext", 0)
                expect(rc == want_context, "%s RunContext %s, expected %s" % (dotted, RUN_CONTEXT.get(rc), RUN_CONTEXT[want_context]))
        return True

    template("ServerScriptService.Workers.ServerWorker", "Script", 1)
    if find(root, "ReplicatedStorage.DemoWorkers.ClientWorker") is not None:
        template("ReplicatedStorage.DemoWorkers.ClientWorker", "Script", 2)
    if find(root, "ReplicatedStorage.DemoWorkers.ClientWorkerLocal") is not None:
        template("ReplicatedStorage.DemoWorkers.ClientWorkerLocal", "LocalScript", None)

    # properties only the file can carry, and start-up properties
    lighting = find(root, "Lighting")
    if lighting is not None:
        expect(lighting.props.get("Technology") == 4, "Lighting.Technology must be Future (4)")
        expect(lighting.props.get("LightingStyle") == 0, "Lighting.LightingStyle must be Realistic (0)")
        expect(lighting.props.get("PrioritizeLightingQuality") is True, "Lighting.PrioritizeLightingQuality")
        expect("ClockTime" not in lighting.props, "ClockTime is CanSave=false; use TimeOfDay in the file")
    terrain = find(root, "Workspace.Terrain")
    if terrain is not None:
        expect(terrain.props.get("Decoration") is True, "Terrain.Decoration must be true (NotScriptable)")
        expect(0.1 <= terrain.props.get("GrassLength", 0) <= 1, "Terrain.GrassLength in [0.1, 1] (NotScriptable)")
    ws = find(root, "Workspace")
    if ws is not None:
        expect(ws.props.get("StreamingEnabled") is False, "Workspace.StreamingEnabled must be false")
    players = find(root, "Players")
    if players is not None:
        expect(players.props.get("CharacterAutoLoads") is False, "Players.CharacterAutoLoads must be false")

    # every require-by-string resolves to a ModuleScript in the built place
    scripts = []

    def collect(n):
        if n.cls in SCRIPT_CLASSES:
            scripts.append(n)
        for c in n.children:
            collect(c)

    collect(root)
    total_bytes = 0
    requires = 0
    biggest = (0, "")
    for s in scripts:
        src = s.props.get("Source", "")
        size = len(src.encode("utf-8"))
        total_bytes += size
        if size > biggest[0]:
            biggest = (size, s.path())
        expect(size < 1_000_000, "%s source is %d bytes (over 1 MB)" % (s.path(), size))
        # ignore commented-out lines
        for line in src.splitlines():
            code = line.split("--", 1)[0]
            for m in REQUIRE_RE.finditer(code):
                requires += 1
                target, why = resolve(s, m.group(1), root)
                expect(target is not None, '%s: require("%s") does not resolve: %s' % (s.path(), m.group(1), why))
        if s.path().startswith("ReplicatedStorage.Demo.Assets."):
            expect(size <= 64_000, "%s asset chunk is %d bytes (keep under 64 KB)" % (s.path(), size))

    notes.append("%d scripts, %d bytes of source, %d string requires checked, largest %s (%d bytes)"
                 % (len(scripts), total_bytes, requires, biggest[1], biggest[0]))
    for n in notes:
        print("note: " + n)
    if failures:
        for f in failures:
            print("FAIL " + f)
        return 1
    print("place structure OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/UniverseMeadow.rbxlx"))
