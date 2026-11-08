"""keys_in_range.py <app dir> <range> -- before a push: are the log server's keys in what would leave?

Reads the two keys from <app dir>/logs.local. Looks in the tracked files of the checked-out commit, and
in every commit of <range> (its message and its whole diff; a merge's diff against each parent). Prints
counts only: never a key, never a matching line. Also says whether a file named logs.local was ever
added in the range.
"""
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
span = sys.argv[2]
top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=app, capture_output=True, text=True).stdout.strip()


def git(*args):
    return subprocess.run(["git", *args], cwd=top, capture_output=True, text=True, errors="replace").stdout


kept = {}
for line in (app / "logs.local").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        kept[k.strip()] = v.strip()

commits = [c for c in git("rev-list", span).splitlines() if c]
print(f"{len(commits)} commits in {span}")
found = 0
for name in ("SPK_LOGS_KEY", "SPK_LOGS_ADMIN_KEY"):
    key = kept.get(name, "")
    if len(key) < 32:
        raise SystemExit(f"{name} is missing from logs.local")
    files = [f for f in git("grep", "-l", "-F", "-e", key).splitlines() if f]
    print(f"{name}: in {len(files)} tracked files of the checked-out commit")
    found += len(files)
    hits = 0
    for commit in commits:
        # -m: a merge is shown against each of its parents, so nothing a merge brought is skipped.
        shown = git("show", "-m", "--format=%B", commit)
        if key in shown:
            hits += 1
    print(f"{name}: in {hits} of the {len(commits)} commits (message and diff)")
    found += hits

# A file of that name, or anything under a build folder, ever added in the range?
names = git("log", "--format=", "--name-only", "--diff-filter=A", span).splitlines()
local = [n for n in names if n.endswith("logs.local")]
built = [n for n in names if "/build/" in n or n.startswith("build/")]
print(f"files named logs.local added in the range: {len(local)}")
print(f"files under a build folder added in the range: {len(built)}")
found += len(local)

# The check itself, seen to find something: a string that is in the tip's tracked files.
probe = "SPK_LOGS_URL"
seen = [f for f in git("grep", "-l", "-F", "-e", probe).splitlines() if f]
in_commits = sum(1 for c in commits if probe in git("show", "-m", "--format=%B", c))
print(f"(the search works: '{probe}' is in {len(seen)} tracked files and {in_commits} commits)")
sys.exit(1 if found else 0)
