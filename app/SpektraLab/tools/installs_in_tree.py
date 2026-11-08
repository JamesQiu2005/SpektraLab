#!/usr/bin/env python3
"""installs_in_tree.py -- before a push: is a tester's installation number in the repository's files?

    app/SpektraLab/tools/installs_in_tree.py [<logs folder>]     # <logs folder> defaults to ~/spektralab-logs

The privacy policy sends a log under a random number made on the host, and that number is the one
thing that ties a log to a person who quotes it. Counts and kinds of Mac may be written down in
this repository; **a number may not, not even its first eight characters** (README, "The log").

The numbers are the names of the folders `logs_pull.py` fills. Each, whole and by its first eight
characters, is looked for in every tracked file and in every untracked file git would add. Prints
how many were looked for, and the names of the files that hold one: never a number.

Exits 1 when a file holds one. To see that it can: point it at a folder of logs that has a
`pulled.log` and name that file — `installs_in_tree.py <logs folder> --in <logs folder> pulled.log`.

Standard library only. It reads; it changes nothing.
"""
import subprocess
import sys
from pathlib import Path


def main():
    args = sys.argv[1:]
    tree, paths = None, []
    if "--in" in args:
        i = args.index("--in")
        tree, paths = Path(args[i + 1]), args[i + 2:]
        args = args[:i]
    logs = Path(args[0]) if args else Path.home() / "spektralab-logs"
    if not logs.is_dir():
        sys.exit("no folder of logs at %s" % logs)
    if tree is None:
        here = Path(__file__).resolve().parent
        tree = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=here, capture_output=True, text=True).stdout.strip())
    if not paths:
        listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=tree, capture_output=True, text=True).stdout
        paths = [p for p in listed.splitlines() if p]
    numbers = [p.name.lower() for p in logs.iterdir() if p.is_dir() and any(p.glob("*.jsonl"))]
    needles = set(numbers) | {n[:8] for n in numbers}
    hits, searched = {}, 0
    for rel in paths:
        f = tree / rel
        if not f.is_file():
            continue
        try:
            text = f.read_text("utf-8", "replace").lower()
        except OSError:
            continue
        searched += 1
        found = sum(1 for needle in needles if needle in text)
        if found:
            hits[rel] = found
    print("%d installations' numbers, whole and by their first eight characters, looked for in %d files of %s" % (len(numbers), searched, tree))
    print("files that hold one: %d" % len(hits))
    for rel, found in sorted(hits.items()):
        print("   %s (%d of the strings)" % (rel, found))
    sys.exit(1 if hits else 0)


if __name__ == "__main__":
    main()
