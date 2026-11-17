#!/usr/bin/env python3
"""gate.py -- the Mac app's test gates, by component (the owner's schema, 2026-11-14).

    tools/gate.py change   [--changed [REF]] [--plan]   a change's gate: its components' self-tests and checks
    tools/gate.py selftest [--changed [REF]] [--only ID,…] [--jobs N] [--plan]
    tools/gate.py full     [--plan]     every self-test and every check whole: before a merge to main, and a release's
    tools/gate.py release  [--plan]     full, then every check's broken rules (--self-test), then the timing rows
    tools/gate.py timing   [--only ID,…]   the cost rows alone, graded only on a quiet Mac
    tools/gate.py sweep                 the empty defaults suites past runs left (named <test>.<UUID>)
    tools/gate.py self-test             this file's own rules (below)

**The schema** (the owner, 2026-11-14): "separate the app into different abstracted components, and … for most cases
restrict the test to within-component only", cross-component "when shared dependency of components are changed / the
communication spec between components is changed", and the full suite "release plus nightly unattended run".
tools/gate_components.json is the table: its contracts, its shared code, its components (each its paths, its
in-app checks, the components it depends on).

- **change** (any change, before a commit). The self-tests a changed file reaches (below), and the in-app checks of:
  - *within a component*: the components that own the changed files, and every component that depends on one of them;
  - *cross-component*: every component, where a changed file is shared code or a contract.
  A changed file that nothing owns and no self-test reads **falls up to full**, and says so.
- **full** (before a merge to main, by hand on the Mac mini; the nightly that ran it is paused, 2026-11-15; and a
  release): every self-test, every check whole.
- **release**: full, every check's `--self-test` (each broken rule red), and the timing rows on a quiet Mac.

**What a self-test reaches.** A build step reaches the files on its command line. A step that compiles inside a script
reaches what the shim recorded it compiling the last time it ran (build/gate-cache/deps/<id>.deps): what was built,
never a second list kept by hand (trap 28). A step that never ran here is chosen, since what it reads is not known yet.
Builds go through tools/gate/swiftc: cached by the contents of what they read, `-Onone` except where kept, several at once.

**The self-test** holds that every source is owned, and reports each dependency a self-test's compile list shows that
the table does not declare (trap 16: a boundary that exists on paper only).

The summary prints the scope, what ran and why, and the time, which is what a commit records (AGENTS.md "Test gates";
trap 26: a short run where a long one was due is a skip, and is seen).
"""

import concurrent.futures as futures
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent          # app/SpektraLab
REPO = HERE.parent.parent
SRC = HERE / "Sources"
OUT = HERE / "build" / "tools"
CACHE = HERE / "build" / "gate-cache"
SHIM = HERE / "tools" / "gate"
PREFS = Path.home() / "Library" / "Preferences"
# The defaults suites the self-tests make, each named for its run: emptied by the test, the file left behind.
SUITE_FILE = re.compile(r"^(spk\.(selftest\.gpu|export-selftest|layer2-selftest)\.|language-selftest-)"
                        r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.plist$")


def load(name):
    return json.loads((HERE / "tools" / name).read_text())


def dataset():
    """The main checkout's RAWs (a worktree has none of its own: git's common directory is the main checkout's .git)."""
    common = subprocess.run(["git", "-C", str(HERE), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip()
    for root in [REPO, Path(common).parent if common else None]:
        if root and (root / "research" / "natural_shadow" / "dataset").is_dir():
            return sorted((root / "research" / "natural_shadow" / "dataset").glob("*.NEF"))
    return []


def expand(s):
    s = s.replace("$here", str(HERE)).replace("$src", str(SRC)).replace("$out", str(OUT))
    if "$raw" in s:
        raws = dataset()
        s = s.replace("$raw1", str(raws[0]) if raws else "/no-raw-dataset").replace("$raw2", str(raws[1]) if len(raws) > 1 else "/no-raw-dataset")
    return s


def rel(p):
    """A path as the app folder's (Sources/…, tools/…), or as the repository's for what lies outside it (../../engine/…)."""
    p = Path(p).resolve()
    try:
        return str(p.relative_to(HERE.resolve()))
    except ValueError:
        try:
            return "../../" + str(p.relative_to(REPO.resolve()))
        except ValueError:
            return str(p)


# ---------------------------------------------------------------------------------------------------------- reaching

def step_reads(step, static=False):
    """What a step is known to read, as app-relative paths (a trailing / is a folder), or None where not known yet.
    `static`: its command lines alone, whether or not it has run."""
    reads = set(step.get("reads", []))
    for token in re.findall(r'"?\$(?:here|src)[^"\s|)]*"?', step.get("run", "") + " " + " ".join(step.get("build", []))):
        path = expand(token.strip('"'))
        if path == str(SRC):
            reads.add("Sources/")
        elif Path(path).is_dir():
            reads.add(rel(path) + "/")
        else:
            reads.add(rel(path))
    if "build" in step or static:
        return reads
    deps = CACHE / "deps" / f"{step['id']}.deps"
    if not deps.exists():
        return None if not step.get("reads_only") else reads
    for line in deps.read_text().splitlines():
        if line.strip():
            reads.add(rel(line.strip()))
    return reads


def reaches(reads, path):
    return any(path == r or (r.endswith("/") and path.startswith(r)) for r in reads)


def matches(pats, path):
    return any(fnmatch.fnmatch(path, pat) or (pat.endswith("/") and path.startswith(pat)) for pat in pats)


def owner(table, path):
    """'contract', 'shared', a component's id, or None."""
    if matches(table["contracts"]["paths"], path):
        return "contract"
    if matches(table["shared"]["paths"], path):
        return "shared"
    for c in table["components"]:
        if matches(c["paths"], path):
            return c["id"]
    return None


def dependents(table, ids):
    """`ids` and every component that depends on one of them, however far."""
    out, grew = set(ids), True
    while grew:
        grew = False
        for c in table["components"]:
            if c["id"] not in out and out & set(c.get("depends", [])):
                out.add(c["id"]); grew = True
    return out


def closure(table, cid):
    """What `cid` may build on: its depends, theirs, and so on."""
    by = {c["id"]: c for c in table["components"]}
    out, todo = set(), list(by[cid].get("depends", []))
    while todo:
        d = todo.pop()
        if d not in out:
            out.add(d); todo += by[d].get("depends", [])
    return out


def changed_files(ref):
    """The app's files a change touches: committed since `ref`, in the working tree, and new. App-relative."""
    def git(*a):
        return subprocess.run(["git", "-C", str(REPO), *a], capture_output=True, text=True).stdout.split("\n")
    names = set(git("diff", "--name-only", f"{ref}...HEAD")) | set(git("diff", "--name-only", "HEAD")) \
        | set(git("ls-files", "--others", "--exclude-standard"))
    out = set()
    for n in names:
        n = n.strip()
        if not n:
            continue
        p = REPO / n
        out.add(rel(p))
    return sorted(out)


# Changes no gate reads: the project file regenerated from the tree, documents, the screenshots.
IGNORED = ["SpektraLab.xcodeproj/", "*.md", "../../*.md", "../../docs/", "../../screenshots/", "../../PRD/",
           "../../design/", "../../license/", "../../.github/", "docs/", "design/"]


def ignored(path):
    return any(fnmatch.fnmatch(path, pat) or (pat.endswith("/") and path.startswith(pat)) for pat in IGNORED + UNTESTED)


UNTESTED = []    # gate_components.json's `untested`, read in main()


# The gate's own files: a change to one runs every self-test.
GATE_FILES = ["tools/selftest.sh", "tools/gate.py", "tools/selftests.json", "tools/gate_components.json", "tools/gate/"]


def choose(changed, steps, table, widen=False):
    """(steps chosen, checks chosen, why, falls_up, scope): scope is 'component' or 'cross'."""
    why, chosen, chosen_checks, unknown, up = {}, set(), set(), [], []
    touched, cross = set(), []
    known = {s["id"]: step_reads(s) for s in steps}
    for sid, reads in known.items():
        if reads is None:
            chosen.add(sid)
            why.setdefault(sid, []).append("never run here: what it reads is not known yet")
    for path in changed:
        if ignored(path):
            continue
        if any(path == g or (g.endswith("/") and path.startswith(g)) for g in GATE_FILES):
            for s in steps:
                chosen.add(s["id"]); why.setdefault(s["id"], []).append(path + " (the gate's own)")
            continue
        hit = False
        for s in steps:
            reads = known[s["id"]]
            if reaches(reads if reads is not None else step_reads(s, static=True), path):
                chosen.add(s["id"]); hit = True
                why.setdefault(s["id"], []).append(path)
        own = owner(table, path)
        if own in ("contract", "shared"):
            cross.append(f"{path} ({own})"); hit = True
        elif own:
            touched.add(own); hit = True
            why.setdefault("component:" + own, []).append(path)
        if not hit:
            up.append(path)
    if cross:
        comps = {c["id"] for c in table["components"]}
        why["scope"] = cross
    else:
        # Within the components a change touches (the owner's schema). `widen`: and every component that depends on one.
        comps = dependents(table, touched) if widen else set(touched)
    for c in table["components"]:
        if c["id"] in comps:
            for k in c.get("checks", []):
                chosen_checks.add(k)
                why.setdefault(k, []).append(c["id"])
    return chosen, chosen_checks, why, up, ("cross" if cross else "component")


# ---------------------------------------------------------------------------------------------------------- running

class Result:
    def __init__(self, sid):
        self.id, self.rc, self.out, self.seconds, self.built = sid, 0, "", 0.0, ""


def env_for(step_id):
    e = dict(os.environ)
    e.update({"here": str(HERE), "src": str(SRC), "out": str(OUT),
              "PATH": f"{SHIM}:{e.get('PATH', '')}",
              "SPK_GATE_CACHE": str(CACHE / "bin"), "SPK_GATE_DEPS": str(CACHE / "deps"),
              "SPK_GATE_STEP": step_id, "SPK_GATE_LOG": str(CACHE / "builds.log")})
    return e


def run_steps(steps, jobs):
    OUT.mkdir(parents=True, exist_ok=True)
    (CACHE / "deps").mkdir(parents=True, exist_ok=True)
    log = CACHE / "builds.log"
    log.write_text("")
    results = {s["id"]: Result(s["id"]) for s in steps}
    for s in steps:
        (CACHE / "deps" / f"{s['id']}.deps").unlink(missing_ok=True)

    def build(s):
        r = results[s["id"]]
        t0 = time.time()
        p = subprocess.run([str(SHIM / "swiftc"), *[expand(a) for a in s["build"]]], cwd=HERE, env=env_for(s["id"]),
                           capture_output=True, text=True)
        r.seconds += time.time() - t0
        if p.returncode != 0:
            r.rc = p.returncode
            errors = [l for l in (p.stderr + p.stdout).splitlines() if "error" in l][:30]
            r.out = f"{s['id']}: the build failed\n" + "\n".join(errors) + "\n"

    with futures.ThreadPoolExecutor(jobs) as pool:
        list(pool.map(build, [s for s in steps if "build" in s]))

    locks = {}
    for s in steps:
        if "group" in s:
            locks.setdefault(s["group"], threading.Lock())

    def run(s):
        r = results[s["id"]]
        if r.rc != 0 or "run" not in s:
            return
        lock = locks.get(s.get("group"))
        if lock:
            lock.acquire()
        try:
            t0 = time.time()
            p = subprocess.run(["bash", "-o", "pipefail", "-c", expand(s["run"])], cwd=HERE, env=env_for(s["id"]),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            r.seconds += time.time() - t0
            r.rc, r.out = p.returncode, p.stdout
        finally:
            if lock:
                lock.release()

    # The longest first, so the pool is not left waiting on one at the end.
    order = sorted(steps, key=lambda s: -s.get("weight", 1))
    with futures.ThreadPoolExecutor(jobs) as pool:
        list(pool.map(run, order))
    built = [l for l in log.read_text().splitlines() if l.startswith("built")]
    hits = [l for l in log.read_text().splitlines() if l.startswith("hit")]
    return results, built, hits


def sweep(since=None):
    """Delete the empty defaults suites past self-tests left (`removePersistentDomain` empties a suite and keeps its
    file). Only a file named <test prefix>.<UUID>.plist holding nothing; with `since`, only those made after it."""
    gone = 0
    if not PREFS.is_dir():
        return 0
    for f in PREFS.iterdir():
        if not SUITE_FILE.match(f.name):
            continue
        if since is not None and f.stat().st_mtime < since:
            continue
        try:
            held = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(f)], capture_output=True, text=True).stdout.strip()
        except OSError:
            continue
        if held not in ("{}", ""):
            continue
        subprocess.run(["defaults", "delete", f.name[:-6]], capture_output=True)
        f.unlink(missing_ok=True)
        gone += 1
    return gone


def selftest(args, steps, table):
    t0 = time.time()
    chosen = [s for s in steps]
    reason = "every self-test"
    if args.only:
        ids = set(args.only.split(","))
        unknown = ids - {s["id"] for s in steps}
        if unknown:
            print("gate: no such step: " + ", ".join(sorted(unknown)))
            return 2
        chosen = [s for s in steps if s["id"] in ids]
        reason = "--only"
    elif args.changed is not None:
        changed = changed_files(args.changed)
        ids, _, why, up, _ = choose(changed, steps, table)
        if up:
            reason = f"{len(up)} changed file(s) no step or check reads, so every self-test: " + ", ".join(up[:8])
        else:
            chosen = [s for s in steps if s["id"] in ids]
            reason = f"{len(changed)} changed file(s) since {args.changed} reach {len(chosen)} of {len(steps)} steps"
        if args.plan:
            for s in chosen:
                print(f"  {s['id']:34} {', '.join(why.get(s['id'], ['(falls up)']))[:110]}")
    print(f"gate selftest: {reason}")
    if args.plan:
        return 0
    started = time.time()
    results, built, hits = run_steps(chosen, args.jobs)
    failed = [s["id"] for s in chosen if results[s["id"]].rc != 0]
    for s in chosen:
        r = results[s["id"]]
        print(f"── {s['id']} ({r.seconds:.1f} s){'  FAILED rc=' + str(r.rc) if r.rc else ''}")
        sys.stdout.write(r.out if r.out.endswith("\n") or not r.out else r.out + "\n")
    gone = sweep(since=started - 1)
    print(f"gate selftest: {len(chosen) - len(failed)} of {len(chosen)} steps passed in {time.time() - t0:.0f} s "
          f"({len(built)} built, {len(hits)} from the cache, {args.jobs} at once; {gone} empty defaults suites swept)")
    if failed:
        print("gate selftest: FAILED " + ", ".join(failed))
    return 1 if failed else 0


def watched(cmd, quiet):
    """A check run in a process group of its own, its lines passed on as they come. Silent for `quiet` seconds, or this
    process interrupted, and the whole group is killed: the app, its watcher and the watcher's `tail -F` with it (a
    check killed alone used to leave them running: eleven for 17 h, and every wait on them never ended)."""
    import signal
    p = subprocess.Popen(cmd, cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                         start_new_session=True)
    last = [time.time()]

    def pump():
        for line in p.stdout:
            last[0] = time.time()
            sys.stdout.write(line); sys.stdout.flush()
    t = threading.Thread(target=pump, daemon=True)
    t.start()
    try:
        while p.poll() is None:
            if time.time() - last[0] > quiet:
                print(f"gate: silent for {quiet} s: killed")
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
                return 124
            time.sleep(1)
    except KeyboardInterrupt:
        os.killpg(p.pid, signal.SIGKILL)
        raise
    t.join(timeout=5)
    return p.returncode


def run_checks(entries, field, plan):
    status, t0 = 0, time.time()
    for a in entries:
        cmd = a.get(field)
        if not cmd:
            continue
        print(f"gate: {a['id']} ({field}): {cmd}")
        if plan:
            continue
        s = time.time()
        rc = watched(["bash", "-o", "pipefail", "-c", expand(cmd)], quiet=a.get("quiet", 600))
        print(f"gate: {a['id']} rc={rc} in {time.time() - s:.0f} s (load {os.getloadavg()[0]:.1f})")
        if rc == 3:
            print(f"gate: {a['id']} NOT RUN (it says why above): the tier is incomplete")
            status = max(status, 3) if status != 1 else 1
        elif rc != 0:
            status = 1
    if not plan:
        print(f"gate: {len(entries)} check(s) in {time.time() - t0:.0f} s, {'passed' if status == 0 else 'FAILED' if status == 1 else 'incomplete'}")
    return status


def checks_of(table, ids):
    return [dict(id=k, **table["checks"][k]) for k in table["checks"] if k in ids]


def parts_skipped(check, changed, scope):
    """The parts of a check (gate_components.json's `parts`: a name and the paths that bring it back) a change reaches
    none of, for `--skip`. A cross-component change, or one to the gate itself, skips nothing."""
    parts = {k: v for k, v in check.get("parts", {}).items() if k != "about"}
    if not parts or scope == "cross" or any(any(p == g or (g.endswith("/") and p.startswith(g)) for g in GATE_FILES) for p in changed):
        return []
    return sorted(name for name, pats in parts.items() if not any(matches(pats, p) for p in changed))


def change(args, steps, table):
    t0 = time.time()
    ref = args.changed or "main"
    changed = changed_files(ref)
    _, ids, why, up, scope = choose(changed, steps, table, widen=args.dependents)
    if up:
        print(f"gate change: {len(up)} changed file(s) nothing owns and no self-test reads, so the whole suite: " + ", ".join(up[:8]))
        args.changed = None
        s1 = selftest(args, steps, table)
        return max(s1, run_checks(checks_of(table, table["checks"]), "full", args.plan))
    if scope == "cross":
        print(f"gate change: cross-component: {', '.join(why['scope'][:6])}")
    else:
        comps = sorted(k[len("component:"):] for k in why if k.startswith("component:"))
        others = sorted(set(w for k in ids for w in why[k]) - set(comps))
        print(f"gate change: within {', '.join(comps) or 'no component'}" + (f" and what depends on it: {', '.join(others)}" if others else ""))
    args.changed = ref
    s1 = selftest(args, steps, table)
    chosen = checks_of(table, ids)
    for c in chosen:
        skip = parts_skipped(c, changed, scope)
        if skip:
            c["run"] = f"{c['run']} --skip {','.join(skip)}"
        print(f"  check {c['id']:16} for {', '.join(sorted(set(why[c['id']])))}"
              + (f"; its parts {', '.join(skip)} left out: the change reaches none of their paths" if skip else ""))
    s2 = run_checks(chosen, "run", args.plan)
    worst = 1 if 1 in (s1, s2) else max(s1, s2)
    if not args.plan:
        print(f"gate change ({scope}): {'passed' if worst == 0 else 'FAILED' if worst == 1 else 'incomplete'} in {time.time() - t0:.0f} s")
    return worst


def timing(args, table):
    chosen = [c for c in checks_of(table, table["checks"]) if c.get("timing") and (not args.only or c["id"] in args.only.split(","))]
    load = os.getloadavg()[0]
    quiet = (os.cpu_count() or 8) / 4
    print(f"gate timing: load {load:.1f} (graded only at or under {quiet:.1f})")
    if load > quiet and not args.plan:
        print("gate timing: NOT GRADED: the Mac is busy, and a cost row read now measures that (2.4.0's round: load 6-430)")
        return 3
    return run_checks(chosen, "timing", args.plan)


# ---------------------------------------------------------------------------------------------------------- self-test

def self_test(steps, table):
    failures = []

    def expect(ok, what):
        print(("ok    " if ok else "FAIL  ") + what)
        if not ok:
            failures.append(what)

    ids = [s["id"] for s in steps]
    expect(len(ids) == len(set(ids)), "the steps' ids are unique")
    missing = []
    for s in steps:
        b = s.get("build", [])
        for i, a in enumerate(b):
            if a.startswith("$") and not (i > 0 and b[i - 1] == "-o") and not Path(expand(a)).exists():
                missing.append(f"{s['id']}: {a}")
    expect(not missing, f"every source the {sum('build' in s for s in steps)} builds name is there" + (": not " + ", ".join(missing) if missing else ""))
    comp_ids = {c["id"] for c in table["components"]}
    bad = [f"{c['id']} → {d}" for c in table["components"] for d in c.get("depends", []) if d not in comp_ids]
    bad += [f"{c['id']}: check {k}" for c in table["components"] for k in c.get("checks", []) if k not in table["checks"]]
    expect(not bad, "every depends and check the components name exists" + (": not " + ", ".join(bad) if bad else ""))

    # Every source of the app is owned: a contract, shared, or one component.
    sources = sorted(rel(p) for p in SRC.rglob("*.swift"))
    unowned = [f for f in sources if owner(table, f) is None]
    expect(not unowned, f"every one of {len(sources)} sources is owned" + (": not " + ", ".join(unowned[:10]) if unowned else ""))
    counts = {}
    for f in sources:
        counts[owner(table, f)] = counts.get(owner(table, f), 0) + 1
    print("note  owners: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda x: -x[1])))

    # The dependencies the self-tests' compile lists show, against the table's.
    undeclared = {}
    for s in steps:
        if "build" not in s:
            continue
        owned = [owner(table, rel(expand(a))) for a in s["build"] if a.startswith("$src/")]
        comps = [o for o in owned if o in comp_ids]
        if not comps:
            continue
        home = s.get("component") or max(set(comps), key=lambda c: (comps.count(c), -[x["id"] for x in table["components"]].index(c)))
        if home == "contract":
            continue
        allowed = closure(table, home) | {home}
        for o, a in zip(owned, [a for a in s["build"] if a.startswith("$src/")]):
            if o in comp_ids and o not in allowed:
                undeclared.setdefault(f"{home} → {o}", []).append(f"{s['id']}: {a[5:]}")
    for k, v in sorted(undeclared.items()):
        print(f"      {k}: {', '.join(v[:3])}{' …' if len(v) > 3 else ''}")
    expect(not undeclared, "what each self-test compiles crosses only the components' declared depends"
           + (f": {len(undeclared)} undeclared" if undeclared else ""))

    # Every tool is reached by a step, owned, or named untested.
    known = {s["id"]: step_reads(s) for s in steps}
    never = [sid for sid, r in known.items() if r is None]
    known = {sid: (r if r is not None else step_reads(next(x for x in steps if x["id"] == sid), static=True)) for sid, r in known.items()}
    tools = [rel(p) for p in (HERE / "tools").rglob("*") if p.is_file() and "__pycache__" not in str(p) and not str(p).endswith(".pyc")]
    unreached = [f for f in tools if not ignored(f) and owner(table, f) is None
                 and not any(f == g or (g.endswith("/") and f.startswith(g)) for g in GATE_FILES)
                 and not any(reaches(r, f) for r in known.values())]
    if never:
        print(f"note  {len(never)} script steps have not run here yet: what they compile is known after one `gate.py selftest`")
    expect(not unreached or bool(never), f"every one of {len(tools)} tools is reached by a step, owned, or named untested"
           + (": not " + ", ".join(unreached[:12]) if unreached else ""))

    def picks(path):
        return choose([path], steps, table)
    c, k, _, up, scope = picks("Sources/Engine/HostCut.swift")
    expect(scope == "cross" and {"crop_selftest", "host_cut_selftest", "export_selftest"} <= c, "HostCut.swift (shared) is cross-component and reaches its self-tests")
    readers = {s["id"] for s in steps if "$src/Model/Format.swift" in s.get("build", [])}
    c, k, _, up, scope = picks("Sources/Model/Format.swift")
    expect(not up and readers <= c and scope == "cross" and k == set(table["checks"]) - {"engine"} | ({"engine"} & k),
           f"Format.swift (shared): all {len(readers)} builds that read it, and every component's checks")
    c, k, _, up, scope = picks("Sources/Features/Layers/MaskRules.swift")
    expect(scope == "component" and "masks_selftest" in c and k == {"masks"}, f"MaskRules.swift: within masks, its check alone ({sorted(k)})")
    masks = table["checks"]["masks"]
    expect(parts_skipped(masks, ["Sources/Features/Layers/MaskRules.swift"], "component") == ["find", "flat"],
           "MaskRules.swift: the masks check leaves out its finding and flat-frame parts")
    expect(parts_skipped(masks, ["Sources/Engine/SubjectFinder.swift"], "component") == ["flat"]
           and parts_skipped(masks, ["Sources/Engine/MaskOverlay.swift"], "component") == ["find"],
           "SubjectFinder.swift brings the finding back, MaskOverlay.swift the flat frame")
    expect(parts_skipped(masks, ["Sources/Features/Layers/MaskRules.swift"], "cross") == []
           and parts_skipped(masks, ["Sources/Features/Layers/MaskRules.swift", "tools/gate.py"], "component") == [],
           "a cross-component change, or the gate's own, leaves out no part")
    c, k, _, up, scope = choose(["Sources/Features/Layers/MaskRules.swift"], steps, table, widen=True)
    expect({"masks", "layers"} <= k, f"--dependents: and the components that depend on masks ({sorted(k)})")
    c, k, _, up, scope = picks("Sources/Engine/Layer2Kernel.swift")
    kernel = {s["id"] for s in steps if "$src/Engine/Layer2Kernel.swift" in s.get("build", [])}
    expect(scope == "component" and k == {"edit_refresh", "hdr_choice", "finished_layers"} and kernel <= c and len(kernel) > 3,
           f"Layer2Kernel.swift (develop): develop's checks, and all {len(kernel)} self-tests that compile it, wherever they are")
    c, k, _, up, scope = picks("Sources/Engine/EngineWire.swift")
    expect(scope == "cross", "EngineWire.swift (the wire) is cross-component")
    c, k, _, up, scope = picks("tools/no_such_new_tool.swift")
    expect(up == ["tools/no_such_new_tool.swift"], "a new file nothing owns or reads falls up to full")
    c, k, _, up, scope = picks("tools/gate.py")
    expect(not up and len(c) == len(steps), "a change to the gate itself runs every self-test")
    c, k, _, up, scope = picks("README.md")
    # A step that never ran here is chosen for any change (what it reads is not known yet), so a document's own reach is
    # what it adds to an empty change: on a fresh Mac this case was red for steps no document touches.
    expect(not up and not k and not (c - choose([], steps, table)[0]), "a document reaches nothing")
    c, k, _, up, scope = picks("../../engine/src/pipeline/print.cpp")
    expect(not up and "engine" in k, "an engine source reaches the engine's check, and what depends on the engine")
    print(f"gate self-test: {len(failures)} failure(s)")
    return 1 if failures else 0


def main():
    import argparse
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("tier", choices=["change", "selftest", "full", "release", "timing", "sweep", "self-test"])
    p.add_argument("--changed", nargs="?", const="main", default=None, metavar="REF")
    p.add_argument("--only")
    p.add_argument("--jobs", type=int, default=max(2, min(8, (os.cpu_count() or 4) - 2)))
    p.add_argument("--plan", action="store_true", help="say what would run, and why; run nothing")
    p.add_argument("--dependents", action="store_true", help="change: also the checks of every component that depends on one touched")
    args = p.parse_args()
    steps = load("selftests.json")["steps"]
    table = load("gate_components.json")
    UNTESTED.extend(p if p.endswith("/") or "*" in p or p.endswith((".py", ".sh", ".swift")) else p + "*"
                    for p in table.get("untested", {}).get("paths", []))
    if args.tier == "self-test":
        sys.exit(self_test(steps, table))
    if args.tier == "sweep":
        print(f"gate sweep: {sweep()} empty defaults suites deleted")
        return
    if args.tier == "selftest":
        sys.exit(selftest(args, steps, table))
    if args.tier == "change":
        sys.exit(change(args, steps, table))
    if args.tier == "timing":
        sys.exit(timing(args, table))
    # full, release
    t0 = time.time()
    args.changed, args.only = None, None
    every = checks_of(table, table["checks"])
    s1 = selftest(args, steps, table)
    s2 = run_checks(every, "full", args.plan)
    s3 = run_checks(every, "selftest", args.plan) if args.tier == "release" else 0
    s4 = timing(args, table) if args.tier == "release" else 0
    worst = 1 if 1 in (s1, s2, s3, s4) else max(s1, s2, s3, s4)
    if not args.plan:
        print(f"gate {args.tier}: {'passed' if worst == 0 else 'FAILED' if worst == 1 else 'incomplete'} in {time.time() - t0:.0f} s")
    sys.exit(worst)


if __name__ == "__main__":
    main()
