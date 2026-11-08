#!/usr/bin/env python3
"""logs_overview.py -- what the testers' logs say, every installation together.

    app/SpektraLab/tools/logs_overview.py [<folder>]     # <folder> defaults to ~/spektralab-logs

Reads the folder `logs_pull.py` (or `server/logs/pull.py`) filled: `<install>/<session>.jsonl`,
and `pulled.log` beside them when it is there (the country each log arrived from). Where
`logs_summary.py` goes through one installation at a time, this counts across all of them:
who is testing, how much of each host's use the server has, how far each got, what went wrong,
what the jobs took, and what was used.

It prints counts. An installation's number appears only by its first eight characters, and only
where one host is the whole of a finding (a tester who writes in quotes that number).

Two things it knows about the log that the counts depend on:
- A session is sent whole when the app is left, but not twice within five minutes
  (`Diagnostics.currentEvery`), and the first sending is the moment Share is answered. In the
  beta's first build, 0.1 (202610101439), that sending started the five minutes: a host that
  was used for under five minutes and not opened again has sent its first seconds only. Such
  installations are counted apart, and "how far each got" is of the others. A build made after
  2026-10-12 sends at the first leaving whatever the time since the answer, and should leave
  few of them: one that still does was ended without being left.
- An ending in mid-use is known at the next launch (`app` `previous`). A host that never came
  back says nothing of how its session ended.

Standard library only. It reads; it changes nothing.
"""
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

NAMES = {}
FETCHED = re.compile(r"fetched\s+([0-9a-f-]{36})/\S+\s.*?country (\S+)")
# A develop for the page or the library runs at the preview's size: 2,400 px on the long edge of
# anything larger, 3.8 MP at 3:2. A RAW file whose first develop ran under this was taken for a
# smaller picture than any camera makes.
SMALL_MP = 3.5


def when(r):
    try:
        return datetime.fromisoformat(r["t"])
    except (KeyError, ValueError, TypeError):
        return None


def med(values):
    return statistics.median(values) if values else None


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p * (len(s) - 1))))]


def n(value, pattern="%.2f"):
    return "?" if value is None else pattern % value


def top(counter, most=8):
    return ", ".join("%s ×%d" % (k, v) for k, v in counter.most_common(most)) or "none"


def mb(value):
    return "?" if not value else "%.0f" % (value / 1e6)


def read(folder):
    installs = {}
    for path in sorted(folder.glob("*/*.jsonl")):
        rows = []
        for line in path.read_text("utf-8", "replace").splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and "cat" in r and "msg" in r:
                rows.append(r)
        if rows:
            installs.setdefault(path.parent.name, {})[path.stem] = rows
    country = defaultdict(Counter)
    log = folder / "pulled.log"
    if log.exists():
        for line in log.read_text().splitlines():
            m = FETCHED.match(line)
            if m:
                country[m.group(1)][m.group(2)] += 1
    return installs, country


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1].startswith("-")):
        raise SystemExit(__doc__)
    folder = Path(argv[1] if len(argv) == 2 else "~/spektralab-logs").expanduser()
    installs, country = read(folder)
    if not installs:
        raise SystemExit("no session files under %s" % folder)
    rows_of = {i: [r for s in sorted(ss) for r in ss[s]] for i, ss in installs.items()}
    everything = [(i, r) for i, rows in rows_of.items() for r in rows]

    def of(cat, msg=None):
        return [(i, r) for i, r in everything if r["cat"] == cat and (msg is None or r["msg"] == msg)]

    launch = {}
    for i, r in of("app", "launch"):
        launch[i] = r
    for i in installs:
        launch.setdefault(i, {})

    # A host's own name, from the camera of the shots made in the app on it.
    names = dict(NAMES)
    shooters = {i for i, _ in of("camera", "shot")}
    learned = defaultdict(Counter)
    for i, r in of("library", "state"):
        if i in shooters:
            for name, count in r.get("cameras", {}).items():
                if name.startswith("Apple Mac"):
                    learned[launch[i].get("machine")][name.replace("Apple ", "")] = max(learned[launch[i].get("machine")][name.replace("Apple ", "")], count)
    for machine, c in learned.items():
        names.setdefault(machine, c.most_common(1)[0][0])

    def model(i):
        machine = launch[i].get("machine", "?")
        return names.get(machine, machine)

    times = [t for t in (when(r) for _, r in everything) if t]
    print("== WHO")
    print("%d installations, %d sessions, %d records; %s to %s (this Mac's time)"
          % (len(installs), sum(len(s) for s in installs.values()), len(everything),
             min(times).astimezone().strftime("%m-%d %H:%M"), max(times).astimezone().strftime("%m-%d %H:%M")))
    first = Counter((when(rows_of[i][0]) or min(times)).astimezone().strftime("%m-%d") for i in installs)
    print("first seen, by day: %s" % ", ".join("%s: %d" % (d, first[d]) for d in sorted(first)))
    models = Counter(model(i) for i in installs)
    print("iPhones: %s" % top(models, 24))
    print("iOS: %s" % top(Counter(str(launch[i].get("os", "?")).replace("Version ", "").split(" (")[0] for i in installs), 12))
    print("language: %s" % top(Counter(launch[i].get("language") for i in installs), 12))
    print("region setting: %s" % top(Counter(launch[i].get("region") for i in installs), 12))
    if country:
        arrived = Counter(c for i in installs for c in (country.get(i) or {"?": 1}))
        print("arrived from, by installation (the server's note): %s" % top(arrived, 14))
    print("builds: %s" % top(Counter("%s (%s) %s %s" % (launch[i].get("app"), launch[i].get("build"), launch[i].get("configuration"), launch[i].get("commit"))
                                      for i in installs), 4))
    print("RAM %s GB; develops to %s MP; Pro control %s"
          % (top(Counter(round(launch[i].get("ram_gb", 0)) for i in installs)), top(Counter(launch[i].get("develop_cap_mp") for i in installs)),
             top(Counter(launch[i].get("settings", {}).get("pro_control") for i in installs))))
    unopened = Counter(r.get("engine_failure") for _, r in of("app", "launch") if r.get("engine_failure"))
    print("the engine did not open: %d %s" % (sum(unopened.values()), top(unopened, 3) if unopened else ""))

    print("\n== HOW MUCH OF EACH PHONE'S USE THE SERVER HAS")
    only_first = set()
    for i, rows in rows_of.items():
        if len(installs[i]) == 1 and rows[-1]["cat"] == "upload" and rows[-1]["msg"] == "consent":
            only_first.add(i)
    told = [i for i in installs if i not in only_first]
    print("the first sending only (nothing after the Share answer; the rest comes when the app is opened again): %d" % len(only_first))
    print("more than that: %d -- the rest of this page is of these, where it says 'installations'" % len(told))
    ends = Counter()
    for i in told:
        last = installs[i][sorted(installs[i])[-1]]
        states = [r["msg"] for r in last if r["cat"] == "app" and r["msg"] in ("active", "inactive", "background", "terminate")]
        ends[states[-1] if states else "no state"] += 1
    print("   their last session, as the server has it, ends: %s" % top(ends))
    per = Counter(len(installs[i]) for i in told)
    print("   sessions each: %s" % ", ".join("%d: %d" % (k, per[k]) for k in sorted(per)))
    front = []
    for i in told:
        total = 0.0
        for rows in installs[i].values():
            since = None
            for r in rows:
                if r["cat"] != "app":
                    continue
                t = when(r)
                if r["msg"] == "active":
                    since = t
                elif r["msg"] in ("inactive", "background", "terminate") and since and t:
                    total += (t - since).total_seconds()
                    since = None
        front.append(total)
    print("   time in front, each: median %s min, a quarter under %s, a quarter over %s, longest %s; together %s hours"
          % (n(med(front) and med(front) / 60, "%.1f"), n(pct(front, 0.25) / 60 if front else None, "%.1f"), n(pct(front, 0.75) / 60 if front else None, "%.1f"),
             n(max(front) / 60 if front else None, "%.0f"), n(sum(front) / 3600, "%.1f")))
    sent_files = sum(r.get("files", 0) for _, r in of("upload", "sent"))
    print("sendings the hosts record: %d files; with each host's last, which is not in its own file, at least %d writes at the server" % (sent_files, sent_files + len(installs)))
    not_sent = of("upload", "not sent")
    print("a sending that failed: %d in %d installations: %s; refused by the server: %d"
          % (len(not_sent), len({i for i, _ in not_sent}), top(Counter(r.get("why") for _, r in not_sent)), len(of("upload", "refused"))))
    print("zips made: %d; iOS's own reports: %s" % (len(of("upload", "zip")), top(Counter(r["msg"] for _, r in of("system")))))

    print("\n== HOW FAR EACH GOT (installations)")
    opened_camera = {i for i, _ in of("camera", "ready")}
    imported = {i for i, r in of("library", "import") if r.get("arrived", 0) > 0}
    has_frame = shooters | imported | {i for i, r in of("library", "state") if r.get("frames", 0) > 0}
    visited = {i for i, _ in of("develop", "visit")}
    changed = {i for i, r in of("develop", "visit") if r.get("touched") or r.get("changed")}
    tried = {i for i, _ in of("export")}
    saved_by = {i for i, _ in of("export", "saved")}
    print("opened the camera %d, shot with it %d; brought photos in %d; has a frame %d of %d"
          % (len(opened_camera - only_first), len(shooters), len(imported), len(has_frame - only_first), len(told)))
    print("opened a develop page %d, changed something there %d; tried an export %d, saved one %d" % (len(visited), len(changed), len(tried), len(saved_by)))

    print("\n== WHAT WENT WRONG")
    previous = of("app", "previous")
    in_use = [(i, r) for i, r in previous if r.get("in_use")]
    print("sessions read back at a later launch: %d; ended while in use: %d, in %d installations" % (len(previous), len(in_use), len({i for i, _ in in_use})))
    for (i, jobs), count in Counter((i, ", ".join(r.get("open_jobs", [])) or "no job open") for i, r in in_use).most_common(12):
        print("   %s %s ×%d, in the middle of: %s" % (i[:8], model(i), count, jobs))
    final = {}
    for i, r in of("job", "end"):
        final[(i, r.get("id"))] = r
    print("jobs, each by its last word: %d: %s" % (len(final), top(Counter(str(r.get("outcome")).split(":")[0] for r in final.values()))))
    failed = [(i, r) for i, r in of("job", "end") if str(r.get("outcome", "")).startswith("failed")]
    for (why, kind), count in Counter((str(r.get("outcome")), "%s %s" % (r.get("kind"), r.get("tier"))) for _, r in failed).most_common(8):
        print("   FAILED ×%d %s (%s), in %d installations" % (count, why, kind, len({i for i, r in failed if str(r.get("outcome")) == why})))
    starts = {(i, r.get("id")): r for i, r in of("job", "start")}
    open_end = Counter("%s %s %.1f MP" % (r.get("kind"), r.get("tier"), r.get("mp", 0)) for k, r in starts.items() if k not in final)
    print("jobs begun with no end in the log: %d: %s" % (sum(open_end.values()), top(open_end)))
    exports = of("export")
    print("exports: %s" % top(Counter(r["msg"] for _, r in exports)))
    for why, count in Counter("%s: %s" % (r["msg"], r.get("why")) for _, r in exports if r["msg"] != "saved").most_common(8):
        print("   ×%d %s" % (count, why))
    trouble = Counter("%s: %s" % (r["msg"], r.get("why") or r.get("error")) for _, r in of("camera") if r["msg"] in ("refused", "stopped"))
    print("the camera refused or stopped: %d %s" % (sum(trouble.values()), top(trouble) if trouble else ""))
    last_state = {}
    for i, r in of("library", "state"):
        last_state[i] = r
    print("frames not developed at the last look: %d in %d installations; originals away: %s"
          % (sum(r.get("not_developed", 0) for r in last_state.values()), sum(1 for r in last_state.values() if r.get("not_developed", 0)),
             top(Counter(k for r in last_state.values() for k in r.get("originals", {})))))
    originals = of("library", "original")
    print("originals brought from Photos again: %d %s" % (len(originals), top(Counter(r.get("outcome") for _, r in originals)) if originals else ""))
    errors = Counter("%s %s: %s" % (r["cat"], r["msg"], r.get("why") or r.get("outcome") or r.get("error") or "") for _, r in everything if r.get("lvl") == "error")
    print("error lines: %d: %s" % (sum(errors.values()), top(errors)))
    print("memory warnings: %d; heat noted: %s; launched in Low Power Mode: %d"
          % (len(of("app", "memory warning")), top(Counter(r.get("state") for _, r in of("app", "thermal"))), sum(1 for _, r in of("app", "launch") if r.get("low_power"))))

    print("\n== A PICTURE TAKEN FOR SMALLER THAN IT IS")
    # An import of one photo, and the megapixels of the develop that followed it.
    table = Counter()
    small_by = defaultdict(Counter)
    for i, rows in rows_of.items():
        for k, r in enumerate(rows):
            if r["cat"] == "library" and r["msg"] == "import" and r.get("arrived") == 1:
                nxt = next((x for x in rows[k + 1:k + 4] if x["cat"] == "job" and x["msg"] == "start" and x.get("kind") == "importDevelop"), None)
                if nxt is None:
                    continue
                camera = next(iter(r.get("cameras", {})), "no camera named")
                kind = "RAW" if r.get("raw") else "not RAW"
                small = nxt.get("mp", 99) < SMALL_MP
                table[(kind, small)] += 1
                if small and kind == "RAW":
                    small_by[camera]["%.2f MP" % nxt.get("mp", 0)] += 1
    print("RAW photos brought in one at a time: %d; first developed under %.1f MP: %d" % (table[("RAW", True)] + table[("RAW", False)], SMALL_MP, table[("RAW", True)]))
    for camera, sizes in sorted(small_by.items()):
        print("   %s: %s" % (camera, top(sizes)))
    print("   (not RAW, for comparison: %d of %d under it -- screenshots and saved pictures are that small)" % (table[("not RAW", True)], table[("not RAW", True)] + table[("not RAW", False)]))
    shrunk = []
    for i, rows in rows_of.items():
        for k, r in enumerate(rows):
            if r["cat"] == "job" and r["msg"] == "end" and r.get("kind") == "export" and str(r.get("outcome")) == "done":
                opened = r.get("job", {}).get("measurement", {}).get("opened") or {}
                record = next((x for x in rows[k:k + 6] if x["cat"] == "export"), None)
                if not opened or record is None or "x" not in str(record.get("out")):
                    continue
                w, h = (int(v) for v in record["out"].split("x")[:2])
                ratio = (w * h) / max(1, opened.get("width", 0) * opened.get("height", 0))
                asked = str(record.get("size"))
                if ratio < 0.25 and asked in ("Full", "12 MP") and opened.get("width", 0) * opened.get("height", 0) / 1e6 > 6:
                    shrunk.append((i, r, record, opened, ratio))
    print("exports asked at Full or 12 MP that came out under a quarter of the pixels decoded for them: %d in %d installations"
          % (len(shrunk), len({i for i, *_ in shrunk})))
    for i, r, record, opened, ratio in shrunk[:12]:
        j = r["job"]
        print("   %s %s: decoded %dx%d, wrote %s (%s); peak %s MB, planned %s, budget %s"
              % (i[:8], model(i), opened.get("width", 0), opened.get("height", 0), record.get("out"), record.get("size"),
                 mb(j.get("measuredPeakBytes")), mb(j.get("predictedPeakBytes")), mb(j.get("budgetBytes"))))

    print("\n== WHAT THE JOBS TOOK (those that ended done)")
    done = [(i, r) for (i, _), r in final.items() if str(r.get("outcome")) == "done" and r.get("job", {}).get("measuredSeconds") is not None]
    by_kind = defaultdict(list)
    for i, r in done:
        by_kind["%s %s" % (r.get("kind"), r.get("tier"))].append(r["job"])
    for kind, jobs in sorted(by_kind.items(), key=lambda kv: -len(kv[1])):
        t = [j["measuredSeconds"] for j in jobs]
        print("%-24s ×%-5d median %s s, 95%% under %s s, slowest %s s; up to %.1f MP"
              % (kind, len(jobs), n(med(t)), n(pct(t, 0.95)), n(max(t)), max(j.get("megapixels", 0) for j in jobs)))
    measured = [(i, r) for i, r in done if r["job"].get("measuredPeakBytes") and r["job"].get("budgetBytes")]
    over = [(i, r) for i, r in measured if r["job"]["measuredPeakBytes"] > r["job"]["budgetBytes"]]
    print("measured peak over the job's budget: %d of %d measured" % (len(over), len(measured)))
    for i, r in over[:10]:
        j = r["job"]
        print("   %s %s %s %.1f MP: peak %s MB, budget %s, planned %s%s" % (model(i), r.get("kind"), r.get("tier"), j.get("megapixels", 0), mb(j["measuredPeakBytes"]),
              mb(j["budgetBytes"]), mb(j.get("predictedPeakBytes")), "; opened from rest" if j.get("measurement", {}).get("fromRest") else ""))
    ratios = [r["job"]["measuredPeakBytes"] / r["job"]["predictedPeakBytes"] - 1 for _, r in measured if r["job"].get("predictedPeakBytes")]
    print("measured peak against the planned one: median %s %%, 95%% under %s %%, worst %s %%"
          % (n(med(ratios) and med(ratios) * 100, "%+.0f") if ratios else "?", n(pct(ratios, 0.95) * 100 if ratios else None, "%+.0f"),
             n(max(ratios) * 100 if ratios else None, "%+.0f")))
    print("jobs that waited: %s" % top(Counter(w for r in final.values() for w in r.get("job", {}).get("waits", []))))
    print("\nby Mac -- the develop page's develop; an export's engine run, by megapixels:")
    by_model = defaultdict(lambda: defaultdict(list))
    for i, r in done:
        j = r["job"]
        if r.get("kind") == "canvasDevelop":
            by_model[model(i)]["live"].append(j["measuredSeconds"])
        if r.get("kind") == "export":
            mp = j.get("megapixels", 0)
            bucket = "to 13 MP" if mp <= 13 else ("to 26 MP" if mp <= 26 else ("to 40 MP" if mp <= 40 else "over 40 MP"))
            by_model[model(i)][bucket].append(j)
    for m in sorted(by_model, key=lambda k: -models[k]):
        d = by_model[m]
        line = "   %-18s (%d) develop ×%-4d median %s s, 95%% %s s" % (m, models[m], len(d["live"]), n(med(d["live"])), n(pct(d["live"], 0.95)))
        for bucket in ("to 13 MP", "to 26 MP", "to 40 MP", "over 40 MP"):
            jobs = d.get(bucket)
            if jobs:
                peaks = [j["measuredPeakBytes"] for j in jobs if j.get("measuredPeakBytes")]
                line += " | export %s ×%d: %s s%s" % (bucket, len(jobs), n(med([j["measuredSeconds"] for j in jobs])), (", peak to %s MB" % mb(max(peaks))) if peaks else "")
        print(line)
    big = sorted(((r["job"].get("megapixels", 0), i, r["job"]) for i, r in done if r.get("kind") == "export" and r["job"].get("megapixels", 0) > 26), key=lambda v: -v[0])
    for mp, i, j in big[:12]:
        print("   %.1f MP on an %s: %s s (planned %s), peak %s MB of a budget of %s (planned %s), %s"
              % (mp, model(i), n(j["measuredSeconds"]), n(j.get("predictedSeconds")), mb(j.get("measuredPeakBytes")), mb(j.get("budgetBytes")),
                 mb(j.get("predictedPeakBytes")), j.get("ran") or j.get("mode")))

    print("\n== WHAT THEY DID")
    shots = [r for _, r in of("camera", "shot")]
    took = [r["s"] for r in shots if r.get("s") is not None]
    print("shots: %d in %d installations: %s; lenses %s; shutter to file median %s s, slowest %s s"
          % (len(shots), len(shooters), top(Counter(r.get("format") for r in shots)), top(Counter(r.get("lens") for r in shots), 10), n(med(took)), n(max(took) if took else None)))
    imports = [r for _, r in of("library", "import")]
    print("photos brought in: %d in %d imports, %d installations: read in place %d, copied in %d; RAW %d"
          % (sum(r.get("arrived", 0) for r in imports), len(imports), len(imported), sum(r.get("read_in_place", 0) for r in imports),
             sum(r.get("copied_in", 0) for r in imports), sum(r.get("raw", 0) for r in imports)))
    print("   their cameras: %s" % top(Counter(k for r in imports for k, v in r.get("cameras", {}).items() for _ in range(v)), 30))
    print("   Photos access at the last look: %s" % top(Counter(r.get("photos_access") for r in last_state.values())))
    with_frames = [r for r in last_state.values() if r.get("frames")]
    count = [r.get("frames", 0) for r in with_frames]
    print("libraries at the last look: %d frames in %d installations (median %s, most %s); RAW %d; pairs %d in %d installations"
          % (sum(count), len(with_frames), n(med(count), "%d"), n(max(count) if count else None, "%d"), sum(r.get("raw", 0) for r in with_frames),
             sum(r.get("pairs", 0) for r in with_frames), sum(1 for r in with_frames if r.get("pairs"))))
    films = Counter()
    film_phones = Counter()
    for r in last_state.values():
        for k, v in r.get("films", {}).items():
            films[k] += v
            film_phones[k] += 1
    print("   films: %s" % ", ".join("%s ×%d (%d)" % (k, v, film_phones[k]) for k, v in films.most_common(30)))
    print("   papers: %s" % top(Counter(k for r in last_state.values() for k, v in r.get("papers", {}).items() for _ in range(v)), 12))
    print("   frames with a film edge: %d in %d installations; with a date back: %d in %d"
          % (sum(r.get("film_edge", 0) for r in with_frames), sum(1 for r in with_frames if r.get("film_edge")),
             sum(r.get("date_back", 0) for r in with_frames), sum(1 for r in with_frames if r.get("date_back"))))
    visits = of("develop", "visit")
    lasted = [r.get("s", 0) for _, r in visits]
    print("develop visits: %d in %d installations; median %s s, a quarter over %s s; touched nothing %d; of a pair %d"
          % (len(visits), len(visited), n(med(lasted), "%.0f"), n(pct(lasted, 0.75), "%.0f"), sum(1 for _, r in visits if not (r.get("touched") or r.get("changed"))),
             sum(1 for _, r in visits if r.get("pair"))))
    touched, kept, hosts = Counter(), Counter(), defaultdict(set)
    for i, r in visits:
        for c in r.get("touched") or []:
            touched[c] += 1
            hosts[c].add(i)
        for c in r.get("changed") or []:
            kept[c] += 1
    print("   touched (visits / hosts / left changed):")
    for c, v in touched.most_common(28):
        print("      %-42s %3d / %2d / %d" % (c, v, len(hosts[c]), kept.get(c, 0)))
    saved = [r for _, r in of("export", "saved")]
    whole = [r.get("s", 0) for r in saved]
    print("exports saved: %d in %d installations: %s; %s; %s; to %s"
          % (len(saved), len(saved_by), top(Counter(r.get("container") for r in saved)), top(Counter(r.get("size") for r in saved)),
             top(Counter(r.get("colour") for r in saved)), top(Counter(r.get("to") for r in saved))))
    print("   with a film edge %d (%s); with a date back %d; of a pair %d; tap to saved median %s s, slowest %s s"
          % (sum(1 for r in saved if r.get("film_edge")), top(Counter(r.get("film_edge") for r in saved if r.get("film_edge"))),
             sum(1 for r in saved if r.get("date_back")), sum(1 for r in saved if r.get("pair")), n(med(whole)), n(max(whole) if whole else None)))
    print("   films exported: %s" % top(Counter(r.get("film") for r in saved), 16))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
