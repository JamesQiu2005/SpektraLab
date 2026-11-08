#!/usr/bin/env python3
"""Check a bundled `minilab/` catalog without the research tree or numpy.

    python3 engine/tests/minilab_catalog_check.py [RESOURCES_DIR]

Default is `engine/resources` beside this file. Point it at a built app's
`EngineResources` (or `Resources/engine`) to prove what shipped:

    python3 engine/tests/minilab_catalog_check.py \
        app/SpektraLab/build/engine-macosx/EngineResources

It re-derives, from the files themselves, exactly what
`engine/src/core/minilab.cpp` checks at run time: the catalog shape, the table
length and FNV-1a 64-bit payload hash, the named profile bytes, and for a
`derived_from` alias the inherited base profile's bytes. A missing or partial
catalog is what the app would otherwise discover only when a frame is opened,
because the engine refuses to start without one.

Stdlib only on purpose: this runs in a build or CI shell where the scientific
venv is not present. Exit status is 0 only when every entry passes.
"""
import json
import sys
from pathlib import Path

TABLE_BYTES = 28 + 65 ** 3 * 3 * 4
SIDE = 65


def fnv1a64(data):
    h = 14695981039346656037
    for byte in data:
        h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def profile_path(resources, stock):
    """The bundle merges the product overlay into `profiles/`; a checkout keeps
    it beside `resources/` in `resources_product/profiles/`. Both are valid
    inputs here: the point is to check the bytes the engine will read."""
    path = resources / "profiles" / (stock + ".json")
    if path.is_file():
        return path
    overlay = resources.parent / "resources_product" / "profiles" / (stock + ".json")
    if overlay.is_file():
        return overlay
    return None


def check(resources):
    problems = []
    index_path = resources / "minilab" / "index.json"
    if not index_path.is_file():
        return ["missing %s" % index_path], 0, 0
    try:
        index = json.loads(index_path.read_text())
    except Exception as exc:  # noqa: BLE001 - report, do not traceback in a build
        return ["%s: %s" % (index_path, exc)], 0, 0
    if index.get("version") != 1 or not isinstance(index.get("pairs"), dict):
        return ["%s: not a version-1 pair catalog" % index_path], 0, 0

    entries = 0
    files = set()
    for pair, spaces in sorted(index["pairs"].items()):
        if "|" not in pair:
            problems.append("%s: pair key is not film|paper" % pair)
            continue
        film, paper = pair.split("|", 1)
        for space, entry in sorted(spaces.items()):
            entries += 1
            name = entry.get("file", "")
            if not name or "/" in name or "\\" in name or ".." in name:
                problems.append("%s %s: bad file %r" % (pair, space, name))
                continue
            path = resources / "minilab" / name
            files.add(name)
            if not path.is_file():
                problems.append("%s %s: missing %s" % (pair, space, name))
                continue
            raw = path.read_bytes()
            if len(raw) != TABLE_BYTES:
                problems.append("%s %s: %s is %d bytes, expected %d"
                                % (pair, space, name, len(raw), TABLE_BYTES))
            if entry.get("side") != SIDE:
                problems.append("%s %s: side %r" % (pair, space, entry.get("side")))
            if fnv1a64(raw) != entry.get("hash"):
                problems.append("%s %s: payload hash" % (pair, space))
            for role, stock in (("film", film), ("paper", paper)):
                profile = profile_path(resources, stock)
                if profile is None:
                    problems.append("%s %s: no profile %s" % (pair, space, stock))
                    continue
                if fnv1a64(profile.read_bytes()) != entry.get(role + "_hash"):
                    problems.append("%s %s: %s identity" % (pair, space, role))
                data = json.loads(profile.read_text())
                base = data.get("derived_from")
                if base:
                    base_path = profile_path(resources, base)
                    if role + "_base_hash" not in entry:
                        problems.append("%s %s: %s alias without base hash"
                                        % (pair, space, role))
                    elif base_path is None or fnv1a64(base_path.read_bytes()) != entry[role + "_base_hash"]:
                        problems.append("%s %s: %s base identity" % (pair, space, role))
    return problems, entries, len(files)


def main(argv):
    resources = Path(argv[1]).resolve() if len(argv) > 1 else (
        Path(__file__).resolve().parents[1] / "resources")
    problems, entries, unique = check(resources)
    if problems:
        print("minilab catalog: %d problem(s) in %s" % (len(problems), resources))
        for problem in problems[:40]:
            print("  " + problem)
        if len(problems) > 40:
            print("  ... %d more" % (len(problems) - 40))
        return 1
    print("minilab catalog: %d entries, %d table files, %d bytes of payload - OK"
          % (entries, unique, unique * TABLE_BYTES))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
