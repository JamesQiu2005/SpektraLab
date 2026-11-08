#!/usr/bin/env python3
"""logs_summary.py -- what a set of the app's logs says, an installation at a time.

    logs_summary.py <folder or zip> [...]

Reads the app's session files (`Sources/Diagnostics`, one JSON record a line) wherever they are
under what it is given: a folder `server/logs/pull.py` filled (`<install>/<session>.jsonl`), the
`Logs` folder of a simulator's or a host's app, or the zip Settings hands on
(`SpektraLab-log-*.zip`, read without unpacking). For each installation -- a folder of sessions,
or a zip -- it prints the questions the log is there to answer (the README's table): which build
on which Mac; how its sessions ended; what the jobs took against what was planned for them;
what was exported and what was not; what the camera offered and shot; the library; what was used;
whether the log got out; and every error, once, with how often.

Standard library only. It reads; it changes nothing.
"""
import json
import statistics
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path


def sources(arguments):
    """(name, {session: [records]}) for each installation found."""
    for a in arguments:
        p = Path(a)
        if p.is_file() and p.suffix == ".zip":
            with zipfile.ZipFile(p) as z:
                found = {Path(n).stem: parse(z.read(n).decode("utf-8", "replace")) for n in z.namelist()
                         if n.startswith("logs/") and n.endswith(".jsonl")}
            yield p.name, found
        elif p.is_dir():
            by_folder = defaultdict(dict)
            for f in sorted(p.rglob("*.jsonl")):
                if f.name == "requests.jsonl":
                    continue
                by_folder[f.parent][f.stem] = parse(f.read_text("utf-8", "replace"))
            for folder, found in sorted(by_folder.items()):
                yield (folder.name if folder != p else p.name), found
        else:
            print(f"{a}: neither a folder nor a zip", file=sys.stderr)


def parse(text):
    rows = []
    for line in text.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and "cat" in r and "msg" in r:
            rows.append(r)
    return rows


def top(counter, n=6):
    return ", ".join(f"{k} ×{v}" for k, v in counter.most_common(n)) or "none"


def median(values):
    return statistics.median(values) if values else None


def seconds(v):
    return "?" if v is None else (f"{v:.2f} s" if v < 10 else f"{v:.0f} s")


def summarise(name, sessions):
    rows = [r for s in sorted(sessions) for r in sessions[s]]
    if not rows:
        return
    print(f"\n{name}: {len(sessions)} session{'s' if len(sessions) != 1 else ''}, {rows[0]['t'][:16]} to {rows[-1]['t'][:16]}")

    def of(cat, msg=None):
        return [r for r in rows if r["cat"] == cat and (msg is None or r["msg"] == msg)]

    launches = of("app", "launch")
    builds = Counter(f"{r.get('app')} ({r.get('build')}) {r.get('configuration', '')} {r.get('commit', '')}".strip() for r in launches)
    phones = Counter(f"{r.get('machine')}, {str(r.get('os', '')).replace('Version ', 'iOS ')}, {r.get('language')}/{r.get('region')}" for r in launches)
    engines = Counter(str(r.get("engine_sources") or r.get("engine")) for r in launches)
    print(f"  build    {top(builds, 3)}")
    print(f"  iPhone   {top(phones, 3)}; engine {top(engines, 2)}")
    failures = [r["engine_failure"] for r in launches if r.get("engine_failure")]
    if failures:
        print(f"  ENGINE   did not open: {top(Counter(failures), 3)}")
    last = launches[-1] if launches else {}
    if last:
        print(f"           allowance {last.get('allowance_mb', 0):,.0f} MB, develops to {last.get('develop_cap_mp')} MP, "
              f"sharing {last.get('sharing')}")

    previous = of("app", "previous")
    in_use = [r for r in previous if r.get("in_use")]
    open_jobs = Counter(j for r in in_use for j in r.get("open_jobs", []))
    print(f"  endings  {len(previous)} read at a launch: {len(in_use)} ended while the app was in use"
          + (f" (in the middle of: {top(open_jobs)})" if open_jobs else "")
          + f"; memory warnings {len(of('app', 'memory warning'))}")
    reports = Counter(r["msg"] for r in of("system"))
    if reports:
        print(f"  iOS      its own reports: {top(reports)}")

    ends = of("job", "end")
    outcome = Counter(str(r.get("outcome", "?")).split(":")[0] for r in ends)
    print(f"  jobs     {len(ends)}: {top(outcome)}")
    kinds = defaultdict(list)
    over = []
    for r in ends:
        j = r.get("job", {})
        if str(r.get("outcome")) == "done" and j.get("measuredSeconds") is not None:
            kinds[f"{r.get('kind')} {r.get('tier')}"].append(j["measuredSeconds"])
            if j.get("measuredPeakBytes") and j.get("predictedPeakBytes"):
                over.append((j["measuredPeakBytes"] / j["predictedPeakBytes"] - 1, f"{r.get('kind')} {r.get('tier')} {j.get('megapixels', 0):.1f} MP"))
    for kind, times in sorted(kinds.items(), key=lambda kv: -len(kv[1])):
        print(f"           {kind:28s} ×{len(times):<4d} median {seconds(median(times))}, slowest {seconds(max(times))}")
    if over:
        worst = max(over)
        print(f"           peak memory against the prediction: median {median([o[0] for o in over]) * 100:+.0f} %, worst {worst[0] * 100:+.0f} % ({worst[1]})")
    waits = Counter(w for r in ends for w in r.get("job", {}).get("waits", []))
    if waits:
        print(f"           waited for: {top(waits)}")
    failed = Counter(str(r.get("outcome")) for r in ends if str(r.get("outcome", "")).startswith("failed"))
    for why, n in failed.most_common(6):
        print(f"           FAILED ×{n}: {why}")

    exports = of("export")
    if exports:
        saved = [r for r in exports if r["msg"] == "saved"]
        print(f"  exports  {len(saved)} saved of {len(exports)}: {top(Counter(r.get('container') for r in saved))}; "
              f"{top(Counter(r.get('size') for r in saved))}; {top(Counter(r.get('colour') for r in saved))}; to {top(Counter(r.get('to') for r in saved))}")
        full = [r["s"] for r in saved if r.get("size") == "Full" and r.get("s") is not None]
        if full:
            print(f"           at Full: median {seconds(median(full))}, largest {max((r.get('mp') or 0) for r in saved if r.get('size') == 'Full'):.1f} MP")
        for why, n in Counter(f"{r['msg']}: {r.get('why')}" for r in exports if r["msg"] != "saved").most_common(6):
            print(f"           NOT SAVED ×{n}: {why}")

    ready, shots = of("camera", "ready"), of("camera", "shot")
    if ready or shots:
        offers = Counter(f"{r.get('lens')}: {', '.join(r.get('offers', []))}" for r in ready)
        through = Counter(str(r.get("lens")) + " " + str(r.get("format")) for r in shots)
        print(f"  camera   {len(shots)} shots: {top(through)}")
        took = [r["s"] for r in shots if r.get("s") is not None]
        if took:
            print(f"           shutter to file: median {seconds(median(took))}, slowest {seconds(max(took))}")
        for offer, _ in offers.most_common(8):
            print(f"           offers {offer}")
        trouble = Counter(f"{r['msg']}: {r.get('why') or r.get('error')}" for r in of("camera") if r["msg"] in ("refused", "stopped"))
        for why, n in trouble.most_common(6):
            print(f"           TROUBLE ×{n}: {why}")

    states = of("library", "state")
    if states:
        s = states[-1]
        print(f"  library  {s.get('frames')} frames and {s.get('pairs')} pairs ({top(Counter(s.get('from', {})))}); RAW {s.get('raw')}; "
              f"sizes {top(Counter(s.get('sizes', {})))}")
        print(f"           films {top(Counter(s.get('films', {})), 8)}")
        print(f"           papers {top(Counter(s.get('papers', {})), 6)}; film edge on {s.get('film_edge')}, date back on {s.get('date_back')}")
        print(f"           cameras {top(Counter(s.get('cameras', {})), 6)}")
        mb = s.get("storage_mb", {})
        print(f"           on disk: originals {mb.get('originals')} MB, working copies {mb.get('working_copies')} MB, previews {mb.get('previews')} MB")
        away = Counter(s.get("originals", {}))
        if away:
            print(f"           originals away: {top(away)}")
    imports = of("library", "import")
    if imports:
        print(f"  imports  {len(imports)}: {top(Counter(r.get('from') for r in imports))}; {sum(r.get('arrived', 0) for r in imports)} arrived of "
              f"{sum(r.get('asked', 0) for r in imports)} asked for")
    originals = of("library", "original")
    if originals:
        print(f"  Photos   originals brought: {top(Counter(r.get('outcome') for r in originals))}")

    visits = of("develop", "visit")
    if visits:
        touched = Counter(c for r in visits for c in (r.get("touched") or r.get("changed", [])))
        left = Counter(c for r in visits for c in r.get("changed", []))
        print(f"  develop  {len(visits)} visits, median {seconds(median([r.get('s', 0) for r in visits]))}, "
              f"{sum(1 for r in visits if not (r.get('touched') or r.get('changed')))} touched nothing")
        print(f"           touched most: {top(touched, 10)}")
        print(f"           left changed: {top(left, 10)}")
    uploads = Counter(r["msg"] for r in of("upload"))
    if uploads:
        why = Counter(r.get("why") for r in of("upload", "not sent"))
        print(f"  the log  {top(uploads)}" + (f"; not sent because: {top(why)}" if why else ""))
    errors = Counter(f"{r['cat']} {r['msg']}: {r.get('why') or r.get('outcome') or r.get('error') or ''}" for r in rows if r.get("lvl") == "error")
    if errors:
        print(f"  errors   {sum(errors.values())} lines, {len(errors)} kinds")
        for line, n in errors.most_common(8):
            print(f"           ×{n} {line}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    found = False
    for name, sessions in sources(sys.argv[1:]):
        if sessions:
            found = True
            summarise(name, sessions)
    if not found:
        raise SystemExit("no session files found")


if __name__ == "__main__":
    main()
