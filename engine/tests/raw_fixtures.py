#!/usr/bin/env python3
"""Every RAW fixture through the pinned LibRaw, with its outcome written down.

The camera files are not in the repository; SPEKTRALAB_RAW_FIXTURES names the
folder that holds them (the 2026-11-17 set: A7m3, A7V, "DNG RAW", "EOS R6iii",
GFX100RF, "Leica Q3", "Lumix S1", "Nikon Z6iii", "Nikon Z7ii", "Olympus
E300"). FIXTURES below is the expected outcome of every RAW file in it, one row
per file. Nothing is skipped: the variable unset, a listed file missing, or a
RAW file in the folder that has no row is a failure, as is a file expected to
decode that does not (or one expected to be refused that decodes).

Two checks share the table:

  host     T-A1. Each file through a native spektralab-host
           (desktop/HOST-PROTOCOL.md): probe (make, model, displayed size,
           EXIF orientation), thumbnail, open in compatible16 and in headroom,
           and one render_view of each, whose picture must be not constant, not
           black and plausibly exposed. A refused file must be refused by both
           modes with the listed error code and message, after a working probe
           and thumbnail.

  compare  T-A2. The decoded linear frame (raw_pin_compare/raw_decode_dump)
           from the previous pin and from this one, both modes, for every file
           the previous pin decoded: the same size and orientation, and no
           difference beyond the row's `pin` expectation. Every frame of the
           current pin must be finite. engine/tests/raw_pin_compare.sh builds
           the two dump tools and calls this.

    SPEKTRALAB_RAW_FIXTURES=<folder> engine/tests/raw_fixtures.py host \\
        --host build/mac-new/engine/host/spektralab-host --resources build/mac-new/engine/resources
    SPEKTRALAB_RAW_FIXTURES=<folder> engine/tests/raw_fixtures.py compare \\
        --old <dir with raw_decode_dump> --new <dir with raw_decode_dump, raw_frame_compare> --scratch <dir>

Standard library only. No timing is measured or asserted.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from host_smoke import Host  # noqa: E402  (the framed protocol client)

RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".crw", ".dng", ".nef", ".nrw", ".orf", ".raf", ".rw2", ".pef",
                  ".srw", ".3fr", ".iiq", ".rwl", ".x3f", ".erf", ".kdc", ".dcr", ".mos", ".mef", ".srf", ".sr2"}
# Sidecars, prints and LUTs that live beside the fixtures; never decoded.
IGNORED_EXTENSIONS = {".json", ".xmp", ".tif", ".tiff", ".cube", ".ds_store", ""}

# The previous pin was LibRaw 0.22.2 + the libraw-arw6 overlay + raw_camera.hpp's
# GFX100RF/X-E5 matrices (base 1aa6f4d8). `pin` is what moving to master
# 42f89c16 is allowed to change in the decoded frame:
#   "identical"        every sample bit-identical, same size and orientation;
#   {"crop": ...}      the new frame contains the old one at offset (x, y) and is
#                      larger by (w, h); the overlap, less an 8 px band, identical;
#   {"colour": ...}    same size and orientation, samples changed by upstream
#                      colour data: mean |difference| and max |difference| bounded
#                      (linear [0,1] units) -- the measured values, not a wider bar;
#   "new"              the old pin refused the file; nothing to compare.
FIXTURES = [
    # path, make, model, displayed width x height, EXIF orientation, decoder, outcome, pin
    {"path": "A7m3/DSC03710.ARW", "make": "Sony", "model": "ILCE-7M3", "size": (6024, 4024), "orientation": 1,
     "decoder": "sony_arw2_load_raw()", "decode": True, "pin": "identical"},
    {"path": "A7m3/DSC03733.ARW", "make": "Sony", "model": "ILCE-7M3", "size": (6024, 4024), "orientation": 1,
     "decoder": "sony_arw2_load_raw()", "decode": True, "pin": "identical"},
    # Sony A7 V: one lossless-compressed file, one ARW 6 "Compressed" (lossy) file.
    {"path": "A7V/5676846937.arw", "make": "Sony", "model": "ILCE-7M5", "size": (4688, 7028), "orientation": 8,
     "decoder": "sony_ljpeg_load_raw()", "decode": True, "pin": "identical"},
    {"path": "A7V/9218571104.arw", "make": "Sony", "model": "ILCE-7M5", "size": (4688, 7028), "orientation": 8,
     "decoder": "sony_arw6_load_raw()", "decode": True, "pin": "identical"},
    # iPhone 17 Pro ProRAW: DNG 1.7 with JPEG XL compression (52546). LibRaw
    # decodes that only when built with the Adobe DNG SDK, which this build is
    # not; probe and the embedded preview work, the decode is refused.
    {"path": "DNG RAW/IMG_9826.DNG", "make": "Apple", "model": "iPhone18,1 back telephoto camera",
     "size": (6048, 8064), "orientation": 6, "decode": False, "error_code": "decode_failed",
     "error": "RAW unpack: Unsupported file format or not RAW file (-2)", "pin": "refused by both"},
    {"path": "DNG RAW/R0030139.DNG", "make": "Ricoh", "model": "GR II", "size": (4944, 3280), "orientation": 1,
     "decoder": "lossless_dng_load_raw()", "decode": True, "pin": "identical"},
    # Canon EOS R6 Mark III: master's crop keeps 25 x 27 more of the sensor than
    # the 0.22.2 overlay did (visible 6986x4664 at margins 158,96 against
    # 6959x4639 at 172,108); the old frame sits inside the new one unchanged.
    {"path": "EOS R6iii/8153398483.cr3", "make": "Canon", "model": "EOS R6 Mark III", "size": (4664, 6986),
     "orientation": 8, "decoder": "crxLoadRaw()", "decode": True,
     "pin": {"crop": {"x": 12, "y": 13, "w": 25, "h": 27}}},
    # Fujifilm GFX100RF: 102 MP. Bit-identical with raw_camera.hpp's override
    # gone -- master's own "GFX 100RF" entry has the GFX 100 II matrix it lent.
    {"path": "GFX100RF/DSCF1220.RAF", "make": "Fujifilm", "model": "GFX100RF", "size": (11662, 8746),
     "orientation": 1, "decoder": "unpacked_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Leica Q3/L1026319.DNG", "make": "Leica", "model": "Q3", "size": (9536, 6344), "orientation": 1,
     "decoder": "lossless_dng_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Leica Q3/L1026321.DNG", "make": "Leica", "model": "Q3", "size": (9536, 6344), "orientation": 1,
     "decoder": "lossless_dng_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Leica Q3/L1026367.DNG", "make": "Leica", "model": "Q3", "size": (6344, 9536), "orientation": 6,
     "decoder": "lossless_dng_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Leica Q3/L1026368.DNG", "make": "Leica", "model": "Q3", "size": (6344, 9536), "orientation": 6,
     "decoder": "lossless_dng_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Lumix S1/2186891362.rw2", "make": "Panasonic", "model": "DC-S1", "size": (6024, 4016),
     "orientation": 1, "decoder": "panasonicC6_load_raw()", "decode": True, "pin": "identical"},
    # Panasonic DC-S1 II: 0.22.2 had no entry and matched "DC-S1" by prefix
    # (camera_from_xyz 0.9744, -0.3905, ...); master has the S1 II's own matrix
    # (1.073, -0.4442, ...). The sensor data, levels and WB are unchanged.
    {"path": "Lumix S1/P2319446.RW2", "make": "Panasonic", "model": "DC-S1M2", "size": (6008, 4008),
     "orientation": 1, "decoder": "panasonicC8_load_raw()", "decode": True,
     "pin": {"colour": {"compatible16": {"mean_abs": 1.2e-4, "max_abs": 0.21},
                        "headroom": {"mean_abs": 1.5e-4, "max_abs": 0.14}}}},
    # Nikon Z6III, HE* compression: refused by name under 0.22.2, decoded by
    # master's new nikon_he_load_raw().
    {"path": "Nikon Z6iii/9143972759.nef", "make": "Nikon", "model": "Z6_3", "size": (6064, 4040),
     "orientation": 1, "decoder": "nikon_he_load_raw()", "decode": True, "pin": "new"},
    {"path": "Nikon Z7ii/_DSC0897.NEF", "make": "Nikon", "model": "Z 7_2", "size": (8288, 5520), "orientation": 1,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC2439.NEF", "make": "Nikon", "model": "Z 7_2", "size": (5520, 8288), "orientation": 8,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC2663.NEF", "make": "Nikon", "model": "Z 7_2", "size": (5520, 8288), "orientation": 8,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC2704.NEF", "make": "Nikon", "model": "Z 7_2", "size": (8288, 5520), "orientation": 1,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC2715.NEF", "make": "Nikon", "model": "Z 7_2", "size": (8288, 5520), "orientation": 1,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC8127.NEF", "make": "Nikon", "model": "Z 7_2", "size": (5520, 8288), "orientation": 8,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Nikon Z7ii/_DSC8683.NEF", "make": "Nikon", "model": "Z 7_2", "size": (5520, 8288), "orientation": 8,
     "decoder": "nikon_load_raw()", "decode": True, "pin": "identical"},
    {"path": "Olympus E300/sample1.orf", "make": "Olympus", "model": "E-300", "size": (3340, 2504),
     "orientation": 1, "decoder": "packed_load_raw()", "decode": True, "pin": "identical"},
]

FAILURES: list[str] = []


def check(cond, label, detail=""):
    print(("ok   " if cond else "FAIL ") + label + (f"  ({detail})" if detail else ""), flush=True)
    if not cond:
        FAILURES.append(label)
    return bool(cond)


def fixture_root() -> Path:
    root = os.environ.get("SPEKTRALAB_RAW_FIXTURES")
    if not root:
        print("FAIL SPEKTRALAB_RAW_FIXTURES is not set; the RAW fixtures are required, not optional", flush=True)
        sys.exit(1)
    path = Path(root)
    if not path.is_dir():
        print(f"FAIL SPEKTRALAB_RAW_FIXTURES={root} is not a folder", flush=True)
        sys.exit(1)
    return path


def inventory(root: Path) -> list[dict]:
    """The table, with every listed file present and every RAW file listed."""
    listed = {row["path"] for row in FIXTURES}
    for row in FIXTURES:
        check((root / row["path"]).is_file(), f"fixture present: {row['path']}")
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        ext = path.suffix.lower()
        if ext in RAW_EXTENSIONS:
            check(rel in listed, f"RAW file has an expected-outcome row: {rel}")
        elif ext not in IGNORED_EXTENSIONS and path.name.lower() != ".ds_store":
            check(False, f"unrecognised fixture file (add it to the table or the ignored list): {rel}")
    return [row for row in FIXTURES if (root / row["path"]).is_file()]


# --- T-A1 ---------------------------------------------------------------------------------------

def picture_stats(px: bytes, width: int, height: int) -> dict:
    n = width * height
    step = max(1, n // 200_000)
    lum, clipped, dark = [], 0, 0
    for i in range(0, n, step):
        r, g, b = px[4 * i], px[4 * i + 1], px[4 * i + 2]
        y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lum.append(y)
        clipped += max(r, g, b) >= 254
        dark += max(r, g, b) <= 4
    mean = sum(lum) / len(lum)
    sd = math.sqrt(sum((v - mean) ** 2 for v in lum) / len(lum))
    return {"mean": mean, "sd": sd, "clipped": clipped / len(lum), "dark": dark / len(lum)}


def plausible(stats: dict) -> bool:
    # Not constant, not black, not blown: generous bounds a broken decode
    # (all-black, all-white, a flat field, NaNs turned to 0) cannot meet.
    return 12 <= stats["mean"] <= 240 and stats["sd"] >= 6 and stats["clipped"] < 0.5 and stats["dark"] < 0.5


def view(host: Host, sid: str, label: str, opened: dict) -> None:
    h, _ = host.call("get_params", {"session": sid})
    if not check(h["ok"], f"{label}: get_params", h.get("error")):
        return
    req = {"session": sid, "tier": "preview", "display": "srgb", "format": "rgba8", "generation": 1,
           "params": h["result"]["params"], "long_edge": 512, "adjustments": {}, "geometry": {}}
    h, px = host.call("render_view", req)
    if not check(h["ok"], f"{label}: render_view", h.get("error")):
        return
    im = h["result"]["image"]
    w, hh = im["width"], im["height"]
    check(len(px) == w * hh * 4 and max(w, hh) <= 512 and (w >= hh) == (opened["width"] >= opened["height"]),
          f"{label}: render_view size and orientation", f"{w}x{hh}")
    s = picture_stats(px, w, hh)
    check(plausible(s), f"{label}: picture is not constant, not black, plausibly exposed",
          "mean {mean:.1f} sd {sd:.1f} clipped {clipped:.3f} dark {dark:.3f}".format(**s))


def host_check(args) -> None:
    root = fixture_root()
    rows = inventory(root)
    host = Host([args.host, "--resources", args.resources])
    h, _ = host.call("hello")
    check(h["ok"] and h["result"]["backend"].get("available"), "host: hello, Vulkan backend available",
          h.get("error") or h["result"].get("build_info"))
    for row in rows:
        path, label = str(root / row["path"]), row["path"]
        h, _ = host.call("probe", {"path": path})
        if not check(h["ok"], f"{label}: probe", h.get("error")):
            continue
        r = h["result"]
        md = r.get("metadata", {})
        check(r["kind"] == "raw", f"{label}: probe kind raw", r["kind"])
        check((r["width"], r["height"]) == tuple(row["size"]), f"{label}: probe displayed size",
              f'{r["width"]}x{r["height"]}, want {row["size"][0]}x{row["size"][1]}')
        check(md.get("make") == row["make"] and md.get("model") == row["model"], f"{label}: make and model",
              f'{md.get("make")} / {md.get("model")}')
        check(md.get("orientation") == row["orientation"], f"{label}: EXIF orientation",
              f'{md.get("orientation")}, want {row["orientation"]}')
        h, px = host.call("thumbnail", {"path": path, "long_edge": 320})
        if check(h["ok"], f"{label}: thumbnail", h.get("error")):
            im = h["result"]["image"]
            ok = len(px) == im["width"] * im["height"] * 4 and max(im["width"], im["height"]) <= 320
            check(ok and (im["width"] >= im["height"]) == (r["width"] >= r["height"]),
                  f"{label}: thumbnail payload and orientation",
                  f'{im["width"]}x{im["height"]} {h["result"].get("source")}')
            s = picture_stats(px, im["width"], im["height"])
            # The camera's own preview keeps the scene's exposure: the two Leica
            # Q3 night frames preview at a mean of 4-6 of 255. Not constant and
            # not all black is what can be asked of it.
            check(s["sd"] >= 6 and s["mean"] >= 2 and s["dark"] < 0.99, f"{label}: thumbnail is a picture",
                  "mean {mean:.1f} sd {sd:.1f}".format(**s))
        for mode in ("compatible16", "headroom"):
            h, _ = host.call("open", {"path": path, "decode": {"raw_mode": mode}})
            if not row["decode"]:
                err = h.get("error") or {}
                check(not h["ok"] and err.get("code") == row["error_code"] and row["error"] in err.get("message", ""),
                      f"{label}: {mode} refused as expected", err or "it decoded")
                if h["ok"]:
                    host.call("close", {"session": h["result"]["session"]})
                continue
            if not check(h["ok"], f"{label}: open {mode}", h.get("error")):
                continue
            o = h["result"]
            check((o["width"], o["height"]) == tuple(row["size"]) and o["kind"] == "raw",
                  f"{label}: {mode} size matches the table", f'{o["width"]}x{o["height"]}')
            check(o["metadata"].get("model") == row["model"], f"{label}: {mode} model", o["metadata"].get("model"))
            view(host, o["session"], f"{label}: {mode}", o)
            host.call("close", {"session": o["session"]})
    h, _ = host.call("shutdown")
    host.p.wait(timeout=60)
    check(host.p.returncode == 0, "host: clean shutdown", host.p.returncode)


# --- T-A2 ---------------------------------------------------------------------------------------

def dump(tool: Path, raw: Path, mode: str, out: Path):
    p = subprocess.run([str(tool), str(raw), mode, str(out)], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def header(path: Path) -> dict:
    out = {}
    with open(path, "rb") as f:
        assert f.readline() == b"SPKF32 1\n"
        while True:
            line = f.readline().decode("utf-8").rstrip("\n")
            if not line:
                return out
            k, _, v = line.partition(" ")
            out[k] = v


def compare_check(args) -> None:
    root = fixture_root()
    rows = inventory(root)
    old_dump, new_dump = Path(args.old) / "raw_decode_dump", Path(args.new) / "raw_decode_dump"
    compare = Path(args.new) / "raw_frame_compare"
    scratch = Path(args.scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    a, b = scratch / "old.spkf32", scratch / "new.spkf32"
    report = []
    for row in rows:
        raw, label, pin = root / row["path"], row["path"], row["pin"]
        for mode in ("compatible16", "headroom"):
            try:
                oc, otext = dump(old_dump, raw, mode, a)
                nc, ntext = dump(new_dump, raw, mode, b)
                tag = f"{label}: {mode}"
                if not row["decode"]:
                    check(oc == 3 and nc == 3 and row["error"] in ntext and row["error"] in otext,
                          f"{tag}: refused by both pins", f"old {oc} {otext} | new {nc} {ntext}")
                    report.append({"file": label, "mode": mode, "old": otext, "new": ntext})
                    continue
                if not check(nc == 0, f"{tag}: the current pin decodes", ntext):
                    continue
                hb = header(b)
                check(hb["nonfinite"] == "0", f"{tag}: every sample finite", hb["nonfinite"])
                check(hb["decoder"] == row["decoder"], f"{tag}: decoder", hb["decoder"])
                if pin == "new":
                    check(oc == 3, f"{tag}: the previous pin refused it", otext)
                    report.append({"file": label, "mode": mode, "old": otext, "new": ntext})
                    continue
                if not check(oc == 0, f"{tag}: the previous pin decodes", otext):
                    continue
                p = subprocess.run([str(compare), str(a), str(b)], capture_output=True, text=True)
                if not check(p.returncode == 0, f"{tag}: compare", p.stderr.strip()):
                    continue
                d = json.loads(p.stdout)
                entry = {"file": label, "mode": mode, "result": d}
                report.append(entry)
                check(d["same_flip"], f"{tag}: same orientation", f'{d["a"]["flip"]} / {d["b"]["flip"]}')
                if pin == "identical":
                    ok = d["same_size"] and d["max_abs"] == 0 and d["nonfinite"] == 0
                    check(ok, f"{tag}: bit-identical to the previous pin",
                          "size {}x{} -> {}x{}, max {}, mean {}".format(d["a"]["width"], d["a"]["height"], d["b"]["width"],
                                                                        d["b"]["height"], d.get("max_abs"), d.get("mean_abs")))
                elif "crop" in pin:
                    c = pin["crop"]
                    al = d.get("aligned") or {}
                    grew = (int(d["b"]["width"]) - int(d["a"]["width"]), int(d["b"]["height"]) - int(d["a"]["height"]))
                    check(grew == (c["w"], c["h"]) and al.get("offset_x") == c["x"] and al.get("offset_y") == c["y"],
                          f"{tag}: the new crop contains the old frame where recorded",
                          f"grew {grew}, offset {al.get('offset_x')},{al.get('offset_y')}")
                    check(al.get("max_abs") == 0 and al.get("samples", 0) > 0, f"{tag}: the overlap is bit-identical",
                          f"max {al.get('max_abs')} over {al.get('samples')} samples")
                elif "colour" in pin:
                    bound = pin["colour"][mode]
                    check(d["same_size"] and d["mean_abs"] <= bound["mean_abs"] and d["max_abs"] <= bound["max_abs"],
                          f"{tag}: changed only by upstream colour data, within the recorded bound",
                          f"mean {d.get('mean_abs'):.3g} <= {bound['mean_abs']}, max {d.get('max_abs'):.3g} <= {bound['max_abs']}")
                    check(d["mean_abs"] > 0, f"{tag}: the recorded change is still there (else make the row identical)")
                else:
                    check(False, f"{tag}: unknown pin expectation {pin!r}")
            finally:
                for f in (a, b):
                    f.unlink(missing_ok=True)
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("host")
    h.add_argument("--host", required=True)
    h.add_argument("--resources", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--old", required=True, help="build dir of raw_pin_compare against the previous pin")
    c.add_argument("--new", required=True, help="build dir of raw_pin_compare against the current pin")
    c.add_argument("--scratch", required=True, help="where the frames are written (and deleted)")
    c.add_argument("--report", help="write every comparison as JSON here")
    args = ap.parse_args()
    (host_check if args.cmd == "host" else compare_check)(args)
    print(f"\n{len(FAILURES)} failure(s)" + ("" if not FAILURES else ": " + "; ".join(FAILURES[:20])), flush=True)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
