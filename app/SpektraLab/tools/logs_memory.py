#!/usr/bin/env python3
"""logs_memory.py -- what the testers' hosts say about memory: what a host allows the app, what
opening a picture and rendering it took, how near the limit any job came, and which jobs never ended.

    app/SpektraLab/tools/logs_memory.py [<folder>]     # <folder> defaults to ~/spektralab-logs

Reads the folder `logs_pull.py` filled (`<install>/<session>.jsonl`). Where `logs_overview.py` says
what the jobs took in time and how often a peak passed its plan, this goes into the one question a
host answers and a simulator cannot: **where the memory went** (RFC-036). Everything is from each
job's own record (`RenderQueue.record`, `JobDiagnostics`):

- `reading.appAvailable` + `reading.footprint` as the job begins: the app's allowance on that host;
- `measurement.openPeakFootprint` - `footprintBefore`: what opening the picture added (the decode);
- `measuredPeakBytes` against `predictedPeakBytes` and `budgetBytes`: the job's peak over rest, what
  the cost model said, what the budget allowed;
- `measurement.lowestAppAvailable`: the least the app had left under its allowance while the job ran,
  which is how far it was from being ended for its own footprint;
- `measurement.opened` against `megapixels`: the frame the engine was handed against the canvas the
  job was planned for;
- a `job start` with no `job end` in its session: the app did not live to write one;
- `measurement.decodedBy` (a build after 0.1 (202610101439)): what made the pixels the engine was
  handed -- "ImageIO", "Core Image", "RAW 9 dng" -- so an open is priced by its decoder.

And, from the build after 0.1 (202610101439), the app's own memory as it ran (`MemoryLog`): `memory`
`mark` (the footprint at each page, around the camera and each shot), `rise`, `fall` and `low` (four
readings a second, written where the footprint moved by a step or the allowance went under a floor),
and `session` (the most a session held, and during what). A session with no `background` after its
last record ended while in use: its last `memory` record is within a quarter of a second of the end.

It prints figures. An installation is a letter here, never its number, and the letters are not kept
from one run to the next. MB is 2^20 bytes, as in every figure of RFC-035 and RFC-036.

Standard library only. It reads; it changes nothing.
"""
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

MB = 1048576.0

NAMES = {}


def host(machine):
    return NAMES.get(machine, machine)


def read(folder):
    """{installation: [(session, [records])]}, sessions in order."""
    out = defaultdict(list)
    for path in sorted(folder.glob("*/*.jsonl")):
        rows = []
        for line in path.read_text("utf-8", "replace").splitlines():
            if line.strip().startswith("{"):
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
        out[path.parent.name].append((path.stem, rows))
    return out


def size(d):
    return "%sx%s" % (d.get("width"), d.get("height")) if d else "?"


def pixels(d):
    return (d.get("width") or 0) * (d.get("height") or 0) if d else 0


def quantile(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(p * len(v)))]


def seconds_between(a, b):
    try:
        return (datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds()
    except (TypeError, ValueError):
        return None


def main():
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "spektralab-logs"
    installs = read(folder)
    if not installs:
        sys.exit("no logs under %s" % folder)
    letters = {}

    def letter(i):
        if i not in letters:
            n = len(letters)
            letters[i] = chr(ord("A") + n % 26) + (str(n // 26) if n >= 26 else "")
        return letters[i]

    jobs, unfinished, shots, imports = [], [], [], []
    marks, peaks, lasts, lows = defaultdict(list), [], [], []
    allowance = defaultdict(list)
    ram = {}
    outcomes = Counter()
    for inst, sessions in installs.items():
        machine = next((r.get("machine") for _, rows in sessions for r in rows if r.get("msg") == "launch"), "?")
        first_job = True
        cams = Counter()
        for session, rows in sessions:
            for r in rows:
                if r.get("msg") == "launch" and r.get("ram_gb"):
                    ram[machine] = round(r["ram_gb"], 1)
            starts = {}
            ends = {r["id"]: r for r in rows if r.get("cat") == "job" and r.get("msg") == "end" and "id" in r}
            mem = [r for r in rows if r.get("cat") == "memory"]
            if mem:
                # How the file ends: with the app left, or in the middle of use (`LogStore.Ending.inUse`).
                course = [r.get("msg") for r in rows if r.get("cat") == "app" and r.get("msg") in
                          ("launch", "continued", "active", "inactive", "background", "terminate")]
                if course and course[-1] in ("launch", "continued", "active"):
                    lasts.append(dict(inst=letter(inst), machine=machine, session=session, r=mem[-1],
                                      after=sum(1 for x in rows[rows.index(mem[-1]) + 1:] if x.get("cat") != "memory")))
            for n, r in enumerate(rows):
                cat, msg = r.get("cat"), r.get("msg")
                if cat == "memory":
                    if msg == "mark":
                        where = r.get("at")
                        if where == "page":
                            where = "page: " + str(r.get("page"))
                        elif where == "camera":
                            where = "camera: " + ("off" if r.get("camera", "").startswith("camera off") else "on")
                        marks[where].append(r)
                    elif msg == "session":
                        peaks.append(dict(machine=machine, r=r))
                    elif msg == "low":
                        lows.append(dict(inst=letter(inst), machine=machine, r=r))
                if cat == "library" and msg == "state":
                    for c, k in (r.get("cameras") or {}).items():
                        cams[c] = max(cams[c], k)
                if cat == "job" and msg == "start":
                    starts[r.get("id")] = r
                    if r.get("id") not in ends:
                        unfinished.append(dict(inst=letter(inst), machine=machine, session=session, start=r,
                                               after=len(rows) - n - 1, cams=dict(cams)))
                if cat == "job" and msg == "end":
                    outcomes[(r.get("outcome") or "")[:44]] += 1
                    j = r.get("job") or {}
                    m = j.get("measurement") or {}
                    reading = j.get("reading") or {}
                    if first_job and reading.get("appAvailable"):
                        allowance[machine].append((reading["appAvailable"] + reading.get("footprint", 0)) / MB)
                        first_job = False
                    if not m:
                        continue
                    jobs.append(dict(
                        inst=letter(inst), machine=machine, kind=r.get("kind"), tier=r.get("tier"), outcome=r.get("outcome"),
                        mp=j.get("megapixels") or 0, opened=m.get("opened") or {}, ran=str(j.get("ran") or j.get("mode")),
                        predicted=j.get("predictedPeakBytes", 0) / MB, peak=j.get("measuredPeakBytes", 0) / MB,
                        budget=j.get("budgetBytes", 0) / MB, binding=j.get("binding"),
                        before=m.get("footprintBefore", 0) / MB, open_rise=(m.get("openPeakFootprint", 0) - m.get("footprintBefore", 0)) / MB,
                        decode=m.get("decodeSeconds"), render=m.get("renderSeconds"), from_rest=m.get("fromRest"),
                        by=m.get("decodedBy"),
                        least=m.get("lowestAppAvailable", 0) / MB, at_start=reading.get("appAvailable", 0) / MB, cams=dict(cams)))
                # A shot made in the app, and an import of one photo, each with the first job after it that decoded a picture.
                if (cat == "camera" and msg == "shot") or (cat == "library" and msg == "import" and r.get("arrived") == 1):
                    for x in rows[n + 1:n + 12]:
                        if x.get("cat") == cat and x.get("msg") == msg:
                            break
                        if x.get("cat") == "job" and x.get("msg") == "end":
                            j = x.get("job") or {}
                            m = j.get("measurement") or {}
                            if not m.get("decodeSeconds"):
                                continue
                            row = dict(machine=machine, job=x.get("kind"), before=m.get("footprintBefore", 0) / MB,
                                       rise=(m.get("openPeakFootprint", 0) - m.get("footprintBefore", 0)) / MB,
                                       decode=m.get("decodeSeconds"), opened=m.get("opened") or {},
                                       peak=j.get("measuredPeakBytes", 0) / MB, predicted=j.get("predictedPeakBytes", 0) / MB,
                                       budget=j.get("budgetBytes", 0) / MB, gap=seconds_between(r.get("t"), x.get("t")))
                            if cat == "camera":
                                shots.append(dict(row, format=r.get("format") or r.get("kind") or "?", file_mb=r.get("mb") or 0))
                            else:
                                imports.append(dict(row, camera=next(iter(r.get("cameras") or {}), "unknown"), raw=bool(r.get("raw")),
                                                    listed=next(iter(r.get("sizes") or {}), "?"), in_place=bool(r.get("read_in_place"))))
                            break

    print("%d installations, %d jobs with a measurement on %d of them" % (len(installs), len(jobs), len({j["inst"] for j in jobs})))

    print("\n== What each kind of Mac allows the app (what was left under the allowance plus the footprint, at an installation's first job)")
    for machine in sorted(allowance):
        v = sorted(allowance[machine])
        same = "%.0f MB on each of %d" % (v[0], len(v)) if v[-1] - v[0] < 2 else ", ".join("%.0f" % x for x in v) + " MB"
        print("   %-18s %5s GB of memory   %s" % (host(machine), ram.get(machine, "?"), same))

    print("\n== How the jobs ended")
    for k, n in outcomes.most_common():
        print("   %5d  %s" % (n, k))
    print("   (no outcome here is 'cancelled: pressure, runs again smaller' unless a memory warning or the scheduler's own watch stopped a job)")

    print("\n== Jobs that began and wrote no end in their session: %d (with no record after it, the app was ended there; with records after it, the file was sent while the job ran)" % len(unfinished))
    for u in unfinished:
        s = u["start"]
        print("   %s %-18s %s %s, %.2f MP planned, mode %s, at %s; %d records after it in that session"
              % (u["inst"], host(u["machine"]), s.get("kind"), s.get("tier"), s.get("mp") or 0, s.get("mode"), (s.get("t") or "")[:19], u["after"]))
        print("      the library's cameras then: %s" % (", ".join("%s x%d" % kv for kv in sorted(u["cams"].items())) or "none listed"))

    print("\n== Jobs handed a frame larger than the canvas they were planned for (the frame opened has over 1.5 times the canvas's pixels)")
    over = [j for j in jobs if j["tier"] == "full" and pixels(j["opened"]) > 1.5 * j["mp"] * 1e6 > 0]
    for j in sorted(over, key=lambda j: -j["peak"]):
        px = pixels(j["opened"])
        print("   %s %-18s %s: planned %.1f MP, opened %s (%.1f MP), ran %s; predicted %.0f MB, peak %.0f MB over rest = %.0f B a pixel opened; "
              "open +%.0f MB in %.2f s, render %.2f s; least left under the allowance %.0f MB of %.0f; %s"
              % (j["inst"], host(j["machine"]), j["kind"], j["mp"], size(j["opened"]), px / 1e6, j["ran"], j["predicted"], j["peak"],
                 j["peak"] * MB / px if px else 0, j["open_rise"], j["decode"] or 0, j["render"] or 0, j["least"], j["at_start"], j["outcome"]))
        print("      the library's cameras then: %s" % (", ".join("%s x%d" % kv for kv in sorted(j["cams"].items())) or "none listed"))
    if not over:
        print("   none")

    print("\n== How near the allowance any finished job came: the least the app had left while it ran")
    for j in sorted((j for j in jobs if j["least"] > 0), key=lambda j: j["least"])[:8]:
        print("   %s %-18s %-13s %-7s %5.1f MP ran %-22s least left %5.0f MB of %5.0f; peak %5.0f over rest (predicted %5.0f, budget %5.0f, the %s side binding)"
              % (j["inst"], host(j["machine"]), j["kind"], j["tier"], j["mp"], j["ran"][:22], j["least"], j["at_start"], j["peak"], j["predicted"], j["budget"], j["binding"]))

    past = [j for j in jobs if j["peak"] > j["budget"] > 0]
    print("\n== Jobs whose peak passed their budget: %d of %d" % (len(past), len(jobs)))
    for j in sorted(past, key=lambda j: -(j["peak"] - j["budget"])):
        print("   %s %-18s %-13s %-7s %5.1f MP, opened %s, ran %s: peak %5.0f MB over a budget of %5.0f (predicted %5.0f); open +%5.0f MB in %.2f s"
              % (j["inst"], host(j["machine"]), j["kind"], j["tier"], j["mp"], size(j["opened"]), j["ran"], j["peak"], j["budget"], j["predicted"],
                 j["open_rise"], j["decode"] or 0))

    print("\n== Opening a shot made in the app, by the format it was shot in (its first develop: a 2,400 px picture)")
    by = defaultdict(list)
    for s in shots:
        by[s["format"]].append(s)
    for fmt in sorted(by):
        g = by[fmt]
        rises = [s["rise"] for s in g]
        tops = [s["before"] + s["rise"] for s in g]
        decs = [s["decode"] for s in g]
        print("   %-14s n=%2d  file %4.0f-%-4.0f MB  open rise MB: least %4.0f, median %4.0f, most %4.0f;  footprint at the open's peak, most %4.0f MB;  decode s: median %.2f, most %.2f;  past the job's budget: %d"
              % (fmt, len(g), min(s["file_mb"] for s in g), max(s["file_mb"] for s in g), min(rises), quantile(rises, 0.5), max(rises), max(tops),
                 quantile(decs, 0.5), max(decs), sum(1 for s in g if s["peak"] > s["budget"] > 0)))
    heavy = sorted((s for s in shots if s["rise"] > 900 or s["before"] + s["rise"] > 2000), key=lambda s: -(s["before"] + s["rise"]))
    for s in heavy:
        print("      %-18s %-14s file %4.1f MB, %-13s footprint %5.0f MB before, +%5.0f MB to open in %.2f s; the job ended %s s after the shot (predicted %4.0f, budget %5.0f)"
              % (host(s["machine"]), s["format"], s["file_mb"], s["job"], s["before"], s["rise"], s["decode"],
                 "%.1f" % s["gap"] if s["gap"] is not None else "?", s["predicted"], s["budget"]))

    print("\n== Opening an imported photo for its first develop")
    raws = sorted((p for p in imports if p["raw"]), key=lambda p: -p["rise"])
    for p in raws:
        print("   RAW  %-18s %-36s listed %-10s opened %-10s open +%4.0f MB in %.2f s (job peak %4.0f, predicted %4.0f)"
              % (host(p["machine"]), p["camera"][:36], p["listed"], size(p["opened"]), p["rise"], p["decode"], p["peak"], p["predicted"]))
    rest = defaultdict(list)
    for p in imports:
        if not p["raw"]:
            rest[p["listed"]].append(p)
    for listed in sorted(rest):
        g = rest[listed]
        print("   not RAW, listed %-10s n=%2d  open rise MB: median %4.0f, most %4.0f;  decode s: median %.2f, most %.2f"
              % (listed, len(g), quantile([p["rise"] for p in g], 0.5), max(p["rise"] for p in g), quantile([p["decode"] for p in g], 0.5), max(p["decode"] for p in g)))

    print("\n== Opening a picture, by what decoded it and the size opened (`decodedBy`; a build after 0.1 (202610101439))")
    opens = defaultdict(list)
    for j in jobs:
        if j["by"] and j["decode"]:
            mp = pixels(j["opened"]) / 1e6
            opens[(j["by"], "to 3 MP" if mp <= 3 else "to 13 MP" if mp <= 13 else "to 26 MP" if mp <= 26 else "to 50 MP" if mp <= 50 else "over 50 MP")].append(j)
    if not opens:
        print("   none: no job here says what decoded its picture")
    for key in sorted(opens):
        g = opens[key]
        rises = [j["open_rise"] for j in g]
        print("   %-22s %-10s n=%4d  open rise MB: least %5.0f, median %5.0f, most %5.0f;  decode s: median %.2f, most %.2f"
              % (key[0], key[1], len(g), min(rises), quantile(rises, 0.5), max(rises),
                 quantile([j["decode"] for j in g], 0.5), max(j["decode"] for j in g)))

    print("\n== The app's memory as it ran (`memory` records; a build after 0.1 (202610101439))")
    if not marks and not peaks and not lasts:
        print("   none: no log here is from a build that writes them")
        return
    print("   the footprint at each mark, MB: least / median / most (and what was left of the allowance, least)")
    for where in sorted(marks):
        g = marks[where]
        f = [r.get("footprint_mb", 0) for r in g]
        print("   %-24s n=%4d  %5d / %5d / %5d   (left, least %5d)"
              % (where, len(g), min(f), quantile(f, 0.5), max(f), min(r.get("allowance_mb", 0) for r in g)))
    after = [r for r in marks.get("landed", []) if r.get("footprint_mb") is not None]
    if after:
        print("   a shot landed with the app at %d to %d MB (median %d)" % (min(r["footprint_mb"] for r in after),
              max(r["footprint_mb"] for r in after), quantile([r["footprint_mb"] for r in after], 0.5)))
    print("\n   the most a session held, by Mac, and what the app was doing then")
    by = defaultdict(list)
    for p in peaks:
        by[p["machine"]].append(p["r"])
    for machine in sorted(by):
        g = sorted(by[machine], key=lambda r: -r.get("peak_mb", 0))
        print("   %-18s n=%3d  median %5d MB, most %5d MB during \"%s\"; least left of the allowance %5d MB during \"%s\""
              % (host(machine), len(g), quantile([r.get("peak_mb", 0) for r in g], 0.5), g[0].get("peak_mb", 0), g[0].get("peak_during", ""),
                 min(r.get("least_allowance_mb", 0) for r in g), min(g, key=lambda r: r.get("least_allowance_mb", 0)).get("least_during", "")))
    print("\n   the allowance went under a floor: %d times" % len(lows))
    for l in sorted(lows, key=lambda l: l["r"].get("allowance_mb", 0))[:20]:
        r = l["r"]
        print("      %-3s %-18s under %4d MB: footprint %5d, left %5d, the host %5d; %s; %s%s"
              % (l["inst"], host(l["machine"]), r.get("under_mb", 0), r.get("footprint_mb", 0), r.get("allowance_mb", 0), r.get("phone_mb", 0),
                 r.get("page"), r.get("camera"), "; " + r["job"] if r.get("job") else ""))
    print("\n   sessions that ended while in use, and the app's memory at its last reading: %d" % len(lasts))
    for l in lasts:
        r = l["r"]
        print("      %-3s %-18s %s  %s: footprint %5d MB, left %5d, the host %5d; %s; %s%s%s; %d records after it"
              % (l["inst"], host(l["machine"]), (r.get("t") or "")[:19], r.get("msg"), r.get("footprint_mb", 0), r.get("allowance_mb", 0),
                 r.get("phone_mb", 0), r.get("page"), r.get("camera"), "; " + r["job"] if r.get("job") else "",
                 "; %.1f s after a shot" % r["since_shot_s"] if r.get("since_shot_s") is not None else "", l["after"]))


if __name__ == "__main__":
    main()
