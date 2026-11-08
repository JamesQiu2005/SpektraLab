#!/usr/bin/env python3
"""logs_pull.py -- bring the testers' logs to this Mac, with the admin key taken from logs.local.

    app/SpektraLab/tools/logs_pull.py [<out>]          # <out> defaults to ~/spektralab-logs

Runs `server/logs/pull.py <out>` with `SPK_LOGS_ADMIN_KEY` (and `SPK_LOGS_URL`) read from
`app/SpektraLab/logs.local`, so the key is never on a command line, in a shell's history or in
what this prints: pull.py's own lines are searched for either key before anything is shown, and
only counts are printed -- how many files came, from how many installations, by build and by the
country the server noted.

pull.py says the country only on the line of a file as it is fetched. Those lines are kept in
`<out>/pulled.log`, one a file, so `logs_overview.py` can say where the logs arrived from; a
line stays only while its file does (pull.py removes a copy 90 days after it was fetched, and
the line about it goes with it here).

Exit code: pull.py's (1 when a request failed), 2 when there is no key to read.
Standard library only.
"""
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
PULL = APP.parent.parent / "server" / "logs" / "pull.py"
FETCHED = re.compile(r"fetched\s+([0-9a-f-]{36})/(\S+)\.jsonl\s.*?build (.*?)\s+country (\S+)\s+uploaded (\S+)")


def keys(path):
    """NAME=value lines of logs.local, comments and blanks aside."""
    found = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        found[name.replace("export ", "").strip()] = value.strip().strip('"').strip("'")
    return found


def struck(text, values):
    """`text` with neither key in it, whatever printed it."""
    for name in ("SPK_LOGS_ADMIN_KEY", "SPK_LOGS_KEY"):
        if values.get(name):
            text = text.replace(values[name], "<" + name + ">")
    return text


def remember(out, lines):
    """pulled.log: the newest line of each file that is still in <out>."""
    log = out / "pulled.log"
    kept = {}
    old = log.read_text().splitlines() if log.exists() else []
    for line in old + lines:
        m = FETCHED.match(line)
        if m and (out / m.group(1) / (m.group(2) + ".jsonl")).is_file():
            kept[(m.group(1), m.group(2))] = line
    if kept or log.exists():
        log.write_text("".join(line + "\n" for line in kept.values()))
    return len(kept)


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1].startswith("-")):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = Path(argv[1] if len(argv) == 2 else "~/spektralab-logs").expanduser()
    local = APP / "logs.local"
    if not local.is_file():
        print("no %s: the server's keys are kept there (server/logs/README.md)" % local, file=sys.stderr)
        return 2
    values = keys(local)
    if not values.get("SPK_LOGS_ADMIN_KEY"):
        print("no SPK_LOGS_ADMIN_KEY in %s" % local, file=sys.stderr)
        return 2
    env = dict(os.environ, SPK_LOGS_ADMIN_KEY=values["SPK_LOGS_ADMIN_KEY"])
    if values.get("SPK_LOGS_URL"):
        env["SPK_LOGS_URL"] = values["SPK_LOGS_URL"]
    done = subprocess.run([sys.executable, str(PULL), str(out)], env=env, capture_output=True, text=True)
    said = struck(done.stdout, values).splitlines()
    wrong = struck(done.stderr, values).splitlines()
    fetched = [line for line in said if FETCHED.match(line)]
    if out.is_dir():
        known = remember(out, fetched)
    else:
        known = 0
    installs = {FETCHED.match(line).group(1) for line in fetched}
    print("fetched %d files from %d installations" % (len(fetched), len(installs)))
    if fetched:
        print("   by build:   %s" % ", ".join("%s ×%d" % kv for kv in Counter(FETCHED.match(l).group(3) or "-" for l in fetched).most_common()))
        print("   by country: %s" % ", ".join("%s ×%d" % kv for kv in Counter(FETCHED.match(l).group(4) for l in fetched).most_common()))
    again = sum(1 for line in fetched if "pull again" in line)
    if again:
        print("   %d came shorter than listed (the store's read lags its listing): pull again in a minute" % again)
    for line in said:
        if line.startswith("removed"):
            print("   " + line)
    for line in wrong:
        print("   " + line[:300])
    if said:
        print(said[-1])
    print("%d files' arrival lines kept in %s" % (known, out / "pulled.log"))
    return done.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))
