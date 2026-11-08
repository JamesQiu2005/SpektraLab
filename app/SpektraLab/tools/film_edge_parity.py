#!/usr/bin/env python3
"""film_edge_parity.py -- hold the app's film layout against the engine's own render.

    tools/film_edge_parity.py --engine <engine dir> [--out DIR] [--only ID[,ID]] [--keep]

The Film Edge pages draw a film before it is developed -- the Frame step's GUIDE, the format
cards -- from `Sources/FilmEdge/FilmLayout.swift`, a port of the engine's layout. The owner's
rule for those pages is that what they show is what the develop shows: the same silhouette, the
same view, the same words, the same DX code where the film has one. This is the check of that
rule, against the engine itself and not against a second copy of the port.

For each case below it

  1. renders a flat grey frame with the real engine (`<engine dir>/build/libspektralab_engine.dylib`,
     through that engine's own `tests/spk_ctypes.py`), grain, glare, halation, fog and leaks off,
     told about the film edge by the app's own wire fields (`FilmEdgeSettings.wire`,
     `DateBackSettings.wire`), and asks it where the gate is (`spk_overscan_geometry`);
  2. lays the same case out with the app's code (`build/tools/film_geometry_dump`, compiled here
     from the app's sources) and draws its marks as a mask at the canvas's size;
  3. compares: the canvas's size, the gate's corners, and on the pixels the gate's opening, the
     perforations, the edge print, the date, and the DX code read back off the render.

It needs an engine that has the formats asked for. The panoramic ones and the carrier are in the
desktop engine since `unpublished-revision`; this repository's has them once that is synced. `engine/build.sh
dylib` builds what this loads.

The black-and-white films are the product's own profiles (`<engine dir>/resources_product`), which
nothing installs: they are laid over the engine's resources in a scratch folder, by the engine's
own `tests/bw_checks.py` (`overlay`), and the engine is pointed there. Their cases are laid out in
the words the app itself sends (`Stock.edgeText`, read from `Resources/StockCatalog.json`), and
those words are held to the films' own (`SILVER`).

Exit status is the number of failed checks.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent.parent
SRC = HERE / "Sources"
TOOL = HERE / "build" / "tools" / "film_geometry_dump"
PORT_SOURCES = [
    "Model/Format.swift", "Model/Localization.swift", "Model/FilmParams.swift", "Model/Geometry.swift", "Model/FeatureFlags.swift",
    "Model/FilmEdge.swift", "Model/FrameEdit.swift", "Model/Adjustments.swift", "Model/CurveMath.swift", "Model/Stock.swift",
    # Theme.swift imports UIKit, which a plain macOS swiftc has not: the swatch parse is the shim's
    "../tools/selftest_theme_shim.swift",
    "FilmEdge/FilmEdgeStock.swift", "FilmEdge/FilmGeometry.swift", "FilmEdge/FilmLayout.swift",
]

# name: (film width, gate across, gate along) -- only to size the test frames
GATES = {
    "135": (36.25, 24.3), "135_half": (18.0, 24.0), "120_645": (41.5, 56.0), "120_6x6": (56.0, 56.0),
    "120_6x7": (69.5, 56.0), "120_6x8": (76.0, 56.0), "120_6x9": (84.0, 56.0),
    "135_xpan": (65.0, 24.0), "120_6x12": (112.0, 56.0), "120_6x17": (168.0, 56.0),
}
POSITIVE = {"fujifilm_provia_100f", "fujifilm_velvia_100", "kodak_ektachrome_100", "kodak_kodachrome_64"}
# The black-and-white films, and the words each one's edge prints (the film's own, the same in
# 135 and 120: `EdgeWords`). The app's own words are held to these.
SILVER = {"kodak_tri_x_400": "KODAK 400TX", "kodak_tmax_100": "KODAK 100TMX",
          "fujifilm_neopan_acros_100_ii": "FUJI 100 ACROS II", "ilford_hp5_plus_400": "ILFORD HP5 PLUS"}
# A silver film is printed on the silver paper, through its filter 2 (`resources_product/paper_grades.json`).
SILVER_PRINT = {"print_stock": "ilford_multigrade_iv_rc", "c_filter_neutral": 0.0, "m_filter_neutral": 0.0,
                "y_filter_neutral": 68.0}


def frame_size(fmt: str, along_is_width: bool) -> tuple[int, int]:
    """A frame of the gate's shape, fine enough that a 0.2 mm stroke is several pixels."""
    along, across = GATES[fmt]
    w_mm, h_mm = (along, across) if along_is_width else (across, along)
    long_px = max(1400, int(round(max(w_mm, h_mm) / 0.04)))
    k = long_px / max(w_mm, h_mm)
    return int(round(w_mm * k)), int(round(h_mm * k))


def cases() -> list[dict]:
    out: list[dict] = []

    def add(cid, fmt, wide=True, stock="kodak_gold_200", text="KODAK GB 200-7", **kw):
        w, h = frame_size(fmt, wide)
        c = dict(id=cid, format=fmt, frame_w=w, frame_h=h, stock=stock, edge_text=text,
                 camera_seed=19, frame_seed=5)
        c.update(kw)
        out.append(c)

    # every format, the film across and the film down, the drawings' body and frame
    for fmt in GATES:
        add(f"{fmt}_across", fmt, True)
        if fmt != "120_6x6":
            add(f"{fmt}_down", fmt, False)
    # other bodies and other frames: the camera's and the advance's draws
    for cam, frm in ((1, 1), (7, 263), (123, 217), (640, 44)):
        add(f"135_c{cam}_f{frm}", "135", True, camera_seed=cam, frame_seed=frm)
        add(f"120_6x7_c{cam}_f{frm}", "120_6x7", False, camera_seed=cam, frame_seed=frm)
        add(f"120_645_c{cam}_f{frm}", "120_645", True, camera_seed=cam, frame_seed=frm)
        add(f"135_xpan_c{cam}_f{frm}", "135_xpan", True, camera_seed=cam, frame_seed=frm)
    # the filed view
    for fmt in ("135", "135_half", "120_645", "120_6x6", "120_6x9", "135_xpan", "120_6x17"):
        add(f"{fmt}_filed", fmt, True, mode="filed")
    # every gate family, asked for by name
    for fam in ("square", "rounded", "eared", "shouldered", "kicked"):
        add(f"120_6x7_gate_{fam}", "120_6x7", True, gate=fam)
        add(f"135_gate_{fam}", "135", True, gate=fam)
    add("120_6x8_auto_c3", "120_6x8", True, camera_seed=3)
    add("120_6x6_auto_c4", "120_6x6", True, camera_seed=4)
    # every stock's own edge: 135 and 120
    stocks = [("kodak_portra_400", "KODAK PORTRA 400"), ("kodak_portra_800_push1", "KODAK PORTRA 800-3"),
              ("fujifilm_c200", "FUJI 200"), ("fujifilm_xtra_400", "FUJI S-400"),
              ("fujifilm_pro_400h", "FUJI PRO400H"), ("fujifilm_provia_100f", "FUJI RDPIII"),
              ("fujifilm_velvia_100", "FUJI RVP100"), ("kodak_ektachrome_100", "KODAK E100"),
              ("kodak_vision3_250d", "EASTMAN 5207"), ("kodak_kodachrome_64", "KODAK KODACHROME 64"),
              ("kodak_ultramax_400", "KODAK GC 400")]
    for stock, text in stocks:
        add(f"135_{stock}", "135", True, stock=stock, text=text)
        add(f"120_6x7_{stock}", "120_6x7", True, stock=stock, text=text)
    add("135_xpan_fujifilm_xtra_400", "135_xpan", True, stock="fujifilm_xtra_400", text="FUJI S-400")
    add("135_half_fujifilm_provia_100f", "135_half", True, stock="fujifilm_provia_100f", text="FUJI RDPIII")
    # the frame's own number
    add("135_no12", "135", True, frame_number=12)
    add("120_6x7_no7", "120_6x7", True, frame_number=7)
    add("120_6x7_fuji_no3", "120_6x7", True, stock="fujifilm_pro_400h", text="FUJI PRO400H", frame_number=3)
    # black holes
    add("135_black_holes", "135", True, holes="black")
    # the date back: every face, every placement it has
    add("135_date_lcd_br", "135", True, date=dict(text="'26 10 1", style="lcd", corner="br"))
    add("135_date_lcd_tl_down", "135", False, date=dict(text="'26 10 1", style="lcd", corner="tl"))
    add("135_date_dots_bl", "135", True, date=dict(text="'26 10 1", style="dots", corner="bl", size=1.6))
    add("135_date_lcd_between", "135", True, date=dict(text="'26 10 1", style="lcd", placement="rebate"))
    add("135_date_data", "135", True, date=dict(text="1/250 F5.6", style="data"))
    # a date face and the data line together (2026-10-20): the data between frames, the date in the
    # frame -- or, between frames too, in the gap after the frame
    add("135_date_lcd_and_data", "135", True, date=dict(text="'26 10 1", style="lcd", data_text="1/250 F5.6"))
    add("135_date_dots_between_and_data", "135", True,
        date=dict(text="'26 10 1", style="dots", placement="rebate", data_text="1/250 F5.6"))
    add("135_half_date_lcd", "135_half", True, date=dict(text="10 1 '26", style="lcd", corner="tr", inset_x=2.0))
    add("120_645_date_data", "120_645", True, date=dict(text="1/250 F5.6", style="data"))
    add("120_6x7_date_none", "120_6x7", True, date=dict(text="'26 10 1", style="lcd"))
    add("135_xpan_date_none", "135_xpan", True, date=dict(text="'26 10 1", style="lcd"))
    # the black-and-white films, in the app's own words (`text=None`): every format the Film step
    # offers, the film down, the filed view, a number of the frame's own, another body and frame
    for stock in SILVER:
        for fmt in GATES:
            add(f"{fmt}_{stock}", fmt, True, stock=stock, text=None)
        add(f"135_down_{stock}", "135", False, stock=stock, text=None)
        add(f"120_6x7_down_{stock}", "120_6x7", False, stock=stock, text=None)
        add(f"135_filed_{stock}", "135", True, stock=stock, text=None, mode="filed")
        add(f"135_no12_{stock}", "135", True, stock=stock, text=None, frame_number=12)
        add(f"120_6x7_no3_{stock}", "120_6x7", True, stock=stock, text=None, frame_number=3)
        add(f"135_c7_f263_{stock}", "135", True, stock=stock, text=None, camera_seed=7, frame_seed=263)
        add(f"120_645_c7_f263_{stock}", "120_645", True, stock=stock, text=None, camera_seed=7, frame_seed=263)
    return out


def engine_params(c: dict, wire: dict) -> dict:
    """What the engine is told: a flat, quiet render, and the film edge in the app's own words --
    `wire` is what `FilmEdgeSettings.wire` and `DateBackSettings.wire` send for this case, so a
    field the engine does not know, or a value it refuses, fails here."""
    # A slide is looked at as it is, not printed onto paper.
    p = {"film_stock": c["stock"], "print_stock": "kodak_supra_endura", "auto_exposure": False,
         "scan_film": c["stock"] in POSITIVE,
         "grain_active": False, "glare_active": False, "halation_active": False}
    if c["stock"] in SILVER:
        p.update(SILVER_PRINT)
    p.update(wire)
    return p


def build_tool() -> None:
    newest = max((SRC / s).stat().st_mtime for s in PORT_SOURCES)
    newest = max(newest, (HERE / "tools" / "film_geometry_dump.swift").stat().st_mtime)
    if TOOL.exists() and TOOL.stat().st_mtime >= newest:
        return
    TOOL.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["swiftc", "-O", "-parse-as-library", "-o", str(TOOL)] + [str(SRC / s) for s in PORT_SOURCES] \
        + [str(HERE / "tools" / "film_geometry_dump.swift")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("could not compile the app's layout:\n" + "\n".join(l for l in r.stderr.splitlines() if "error" in l)[:4000])


def resources(engine: Path, tmp: str) -> Path | None:
    """The engine's resources with the product's profiles laid over them, where the engine has
    any (`tests/bw_checks.py`, `overlay`); None, the engine's own, where it has none."""
    if not (engine / "resources_product" / "profiles").is_dir():
        return None
    import bw_checks  # noqa: E402
    return bw_checks.overlay(tmp)


def write_png(path: Path, rgb: np.ndarray) -> None:
    """An 8-bit RGB PNG, with nothing but zlib."""
    import struct, zlib
    h, w = rgb.shape[:2]
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def dilate(mask: np.ndarray, r: int) -> np.ndarray:
    out = mask.copy()
    for _ in range(r):
        m = out.copy()
        m[1:] |= out[:-1]; m[:-1] |= out[1:]; m[:, 1:] |= out[:, :-1]; m[:, :-1] |= out[:, 1:]
        out = m
    return out


def iou(a: np.ndarray, b: np.ndarray) -> float:
    u = (a | b).sum()
    return 1.0 if u == 0 else float((a & b).sum()) / float(u)


def stretches(e_ink: np.ndarray, p_ink: np.ndarray, p_near: np.ndarray, vertical: bool, px: float) -> tuple[float, float]:
    """The edge print a millimetre of film at a time, each band by itself: the least share of the
    app's ink the engine exposed, and the least share of the engine's ink that is the app's. One
    glyph is a millimetre of the film and a hundredth of its ink, so the whole print's shares
    cannot tell a wrong glyph from none. Only a millimetre with a tenth of a square millimetre of
    ink in it is counted (a dotted letter is 0.13): less is the fringe of a glyph the stretch only
    touches. The engine's ink is counted on the rows the app's print lies on."""
    if vertical:                                              # turned, so the film runs along x
        e_ink, p_ink, p_near = e_ink.T, p_ink.T, p_near.T
    w = max(4, int(round(1.0 / px)))
    need = 0.10 / (px * px)
    recall = precision = 1.0
    half = e_ink.shape[0] // 2
    for band in (slice(0, half), slice(half, None)):
        rows = dilate(p_ink[band].any(1)[:, None], max(2, int(round(0.3 / px))))

        def run(a: np.ndarray) -> np.ndarray:
            cs = np.concatenate([[0.0], np.cumsum((a[band] & rows).sum(0, dtype=np.float64))])
            return cs[w:] - cs[:-w]
        app, hit, eng, inside = run(p_ink), run(e_ink & p_ink), run(e_ink), run(e_ink & p_near)
        if (app >= need).any():
            recall = min(recall, float((hit[app >= need] / app[app >= need]).min()))
        if (eng >= need).any():
            precision = min(precision, float((inside[eng >= need] / eng[eng >= need]).min()))
    return recall, precision


def compare(c: dict, port: dict, mask: np.ndarray | None, rgba: np.ndarray, geo: dict, oc) -> list[tuple[str, bool, str]]:
    """One case: the engine's render and geometry against the app's layout and mask."""
    out: list[tuple[str, bool, str]] = []
    H, W = rgba.shape[:2]

    # 0. the words: what the app sends for this film is what the owner decided for it
    if c["stock"] in SILVER and c.get("edge_text") is None:
        sent = port.get("wire", {}).get("overscan_edge_text")
        out.append(("edge words", sent == SILVER[c["stock"]] and port.get("app_edge_text") == sent,
                    f"app sends {sent!r}  decided {SILVER[c['stock']]!r}"))

    # 1. the canvas
    same = bool(port.get("valid")) and (port["canvas_w"], port["canvas_h"]) == (W, H)
    out.append(("canvas", same, f"engine {W}x{H}  app {port.get('canvas_w')}x{port.get('canvas_h')}"))
    if not same or mask is None:
        return out
    # 2. the gate's corners, in pixels
    eg = np.array(geo["gates"][0]).reshape(4, 2) * [W, H]
    pg = np.array(port["gate"]).reshape(4, 2) * [W, H]
    d = float(np.abs(eg - pg).max())
    out.append(("gate corners", d < 0.02, f"max {d:.4f} px"))
    out.append(("direction", bool(geo["vertical"]) == bool(port["vertical"]), f"vertical {geo['vertical']}"))

    # --- the pixels
    rgb = rgba[..., :3].astype(np.float64) / 65535.0
    lum = rgb.mean(-1)
    p_gate, p_ink, p_date, p_hole = mask == 64, mask == 128, mask == 192, mask == 255
    white_holes = c.get("holes", "white") == "white"

    # the picture is the flat grey: its level is the gate's middle
    gy0, gy1 = int(pg[:, 1].min()), int(pg[:, 1].max())
    gx0, gx1 = int(pg[:, 0].min()), int(pg[:, 0].max())
    core = lum[gy0 + (gy1 - gy0) // 3: gy1 - (gy1 - gy0) // 3, gx0 + (gx1 - gx0) // 3: gx1 - (gx1 - gx0) // 3]
    grey = float(np.median(core))
    outside = ~dilate(p_gate | p_hole | p_ink | p_date, 3)
    rebate = float(np.median(lum[outside])) if outside.any() else 0.0
    positive_print = rebate > grey          # the rebate lighter than the picture: holes cannot be told from it

    # 3. the gate's opening: the picture's grey against the rebate
    thr = 0.5 * (grey + rebate)
    e_gate = (lum > thr) if grey > rebate else (lum < thr)
    box = np.zeros_like(e_gate)
    box[max(gy0 - 12, 0): gy1 + 12, max(gx0 - 12, 0): gx1 + 12] = True
    e_open = e_gate & box & ~dilate(p_hole | p_ink, 2)        # holes and marks are not the opening
    p_open = (p_gate | p_date) & box
    v = iou(e_open, p_open)
    out.append(("gate opening", v > 0.995, f"IoU {v:.4f}"))

    # 4. the perforations
    if p_hole.any() and white_holes and not positive_print:
        low = rgb.min(-1)                                     # the scan's light is white in every channel; ink never is
        e_hole = low > 0.5 * (float(low.max()) + max(grey, rebate))
        e_hole &= ~dilate(p_gate, 1)
        e_hole &= ~dilate(p_ink, 2) | p_hole                  # a white edge print (E100) is not a hole
        v = iou(e_hole, p_hole)
        # The engine punches each hole a little differently (tolerances, burrs). The filed view
        # shows only a half-millimetre sliver of each, where that is a larger share.
        floor = 0.90 if c.get("mode") == "filed" else 0.93
        out.append(("perforations", v > floor, f"IoU {v:.4f}  holes {port['holes']}"))
    elif port["holes"] == 0:
        out.append(("perforations", True, "none on this film"))

    # 5. the edge print: ink against the rebate
    zone = ~dilate(p_gate, 6) & ~dilate(p_hole, 2)            # off the gate's penumbra and the holes' cut
    if (p_ink & zone).any():
        diff = np.abs(lum - rebate)
        level = float(np.percentile(diff[p_ink & zone], 60))
        e_ink = (diff > 0.35 * level) & zone if level > 0 else np.zeros_like(p_ink)
        recall = float((e_ink & p_ink & zone).sum()) / max(1.0, float((p_ink & zone).sum()))
        precision = float((e_ink & dilate(p_ink, 2)).sum()) / max(1.0, float(e_ink.sum()))
        out.append(("edge print", recall > 0.90 and precision > 0.92,
                    f"app's ink exposed {recall:.3f}  engine's ink in app's {precision:.3f}"))
        # 5b. and no one glyph of it wrong. The bars are under what was measured over every case
        # here (2026-10-09): the least exposed millimetre 0.484 (X-Pan, Kodak's thin strokes at
        # 0.04 mm a pixel), the least of the engine's ink in the app's 0.971. A glyph the engine
        # did not print is a millimetre at 0; one the app has not is the same the other way.
        lr, lp = stretches(e_ink & zone, p_ink & zone, dilate(p_ink, 2), bool(port["vertical"]), port["mm_per_px"])
        out.append(("edge glyphs", lr > 0.40 and lp > 0.90,
                    f"worst millimetre: app's ink exposed {lr:.3f}  engine's ink in app's {lp:.3f}"))
    else:
        # nothing of the edge print is on this canvas: nothing may be exposed there
        clear = zone & ~dilate(p_date, 3)
        stray = float((np.abs(lum[clear] - rebate) > 0.08).mean()) if clear.any() else 0.0
        out.append(("edge print", stray < 0.002, f"none on this canvas; stray {stray:.4f}"))

    # 6. the date: light added to the picture, red
    if p_date.any():
        # red over what is there without it: the picture's grey in the gate, the rebate outside
        red = rgb[..., 0] - rgb[..., 2]
        inside = dilate(p_gate | p_date, 1) & box
        base_in = float(np.median(red[p_gate])) if p_gate.any() else 0.0
        base_out = float(np.median(red[outside])) if outside.any() else 0.0
        excess = red - np.where(inside, base_in, base_out)
        clear = ~dilate(p_ink | p_hole, 3)                    # the edge print is red too
        # the back's light is strong (+3.5 EV) and spreads in the film: 0.15 mm about each mark
        where = dilate(p_date, max(3, int(np.ceil(0.15 / port["mm_per_px"]))))
        e_date = (excess > 0.5 * float(np.percentile(excess[p_date], 50))) & clear
        recall = float((e_date & p_date).sum()) / float(p_date.sum())
        precision = float((e_date & where).sum()) / max(1.0, float(e_date.sum()))
        out.append(("date", recall > 0.75 and precision > 0.90,
                    f"app's marks lit {recall:.3f}  engine's light in app's {precision:.3f}"))
    elif c.get("date"):
        red = rgb[..., 0] - rgb[..., 2]
        lit = float((np.abs(red[p_open] - np.median(red[p_open])) > 0.1).mean()) if p_open.any() else 0.0
        out.append(("date", port["date_marks"] == 0 and lit < 0.001, f"not drawn; lit {lit:.4f}"))

    # 7. the DX code, read back off the render as a reader would
    if c.get("mode", "strip") == "strip" and port["holes"] > 0 and white_holes and not positive_print:
        flat = np.rot90(rgba, 1) if port["vertical"] else rgba
        # Ilford's code is Kodak's turned half a turn: a reader meets it with the film turned
        if port.get("dx_turned"):
            flat = flat[::-1, ::-1]
        got = oc.decode_dx(flat, port["mm_per_px"])
        if port["dx"] >= 0:
            # a reader needs a whole code: one that lies inside this piece of film
            whole = [k for k in port["dx_codes"]
                     if k["s"] >= port["s_lo"] + 0.3 and k["s"] + port["dx_length"] <= port["s_hi"] - 0.3]
            want = {(port["dx"], int(k["frame"]), bool(k["half"])) for k in port["dx_codes"]}
            if whole:
                ok = got is not None and (got[0], got[1], got[2]) in want and got[3]
                out.append(("DX code", ok, f"read {got}  app {port['dx']} ({(port['dx'] >> 4) & 0x7F}-{port['dx'] & 0xF})"))
            else:
                ok = got is None or ((got[0], got[1], got[2]) in want and got[3])
                out.append(("DX code", ok, f"no whole code on this piece; read {got}"))
        else:
            # none either way up: a code may lie as Kodak's does or turned half a turn, as Ilford's
            turned = oc.decode_dx(flat[::-1, ::-1], port["mm_per_px"])
            out.append(("DX code", got is None and turned is None,
                        f"none on this film; read {got}" + ("" if turned is None else f", turned {turned}")))
    return out


def self_test(c: dict, port: dict, mask: np.ndarray, rgba: np.ndarray, geo: dict, oc) -> int:
    """A check that cannot fire is not a check: break the app's answer in each way a wrong layout
    would, and count the breaks the comparison catches."""
    def failed(name: str, port_: dict, mask_: np.ndarray) -> bool:
        return any(n == name and not ok for n, ok, _ in compare(c, port_, mask_, rgba, geo, oc))

    px = port["mm_per_px"]
    shift = max(2, int(round(0.25 / px)))                     # a quarter of a millimetre
    moved = np.roll(mask, shift, axis=1)
    only = lambda level: np.where(mask == level, np.roll(mask, shift, axis=1), np.where(np.roll(mask, shift, axis=1) == level, level, mask))
    trials = [
        ("the canvas one pixel wider", "canvas", dict(port, canvas_w=port["canvas_w"] + 1), mask),
        ("the gate a quarter millimetre along", "gate corners",
         dict(port, gate=[v + (shift / port["canvas_w"] if i % 2 == 0 else 0) for i, v in enumerate(port["gate"])]), mask),
        ("the film turned", "direction", dict(port, vertical=not port["vertical"]), mask),
        ("the opening a quarter millimetre along", "gate opening", port, np.where(moved == 64, 64, np.where(mask == 64, 0, mask)).astype(np.uint8)),
        ("the holes a quarter millimetre along", "perforations", port, np.where(moved == 255, 255, np.where(mask == 255, 0, mask)).astype(np.uint8)),
        ("the edge print a quarter millimetre along", "edge print", port, np.where(moved == 128, 128, np.where(mask == 128, 0, mask)).astype(np.uint8)),
        ("another stock's DX number", "DX code", dict(port, dx=port["dx"] + 1), mask),
        ("the frame number one on", "DX code", dict(port, dx_codes=[dict(k, frame=k["frame"] + 40) for k in port["dx_codes"]]), mask),
    ]
    if (mask == 192).any():
        trials.append(("the date a quarter millimetre along", "date", port,
                       np.where(moved == 192, 192, np.where(mask == 192, 64, mask)).astype(np.uint8)))
    # one glyph's worth of the print, where it is densest: a hundredth of the ink
    mm = max(4, int(round(1.0 / px)))
    x0 = int(np.argmax(np.convolve((mask == 128).sum(0), np.ones(mm), "valid")))
    gone = mask.copy()
    gone[:, x0:x0 + mm][gone[:, x0:x0 + mm] == 128] = 0
    trials.append(("a millimetre of the edge print left out", "edge glyphs", port, gone))
    if port.get("dx_turned"):
        trials += [
            ("a turned code said to lie as Kodak's", "DX code", dict(port, dx_turned=False), mask),
            ("a film with a code said to have none", "DX code", dict(port, dx=-1, dx_codes=[]), mask),
        ]
    if c["stock"] in SILVER and c.get("edge_text") is None:
        name = port["app_edge_text"] + " 400"                 # as another name in capitals would be
        trials.append(("another name sent, not the film's own words", "edge words",
                       dict(port, app_edge_text=name, wire=dict(port["wire"], overscan_edge_text=name)), mask))
    print(f"{c['id']}:")
    caught = 0
    for what, name, port_, mask_ in trials:
        ok = failed(name, port_, mask_)
        caught += 1 if ok else 0
        print(f"{'caught' if ok else 'MISSED'}  {what}  ({name})")
    print(f"{caught} of {len(trials)} broken layouts caught\n")
    return len(trials) - caught


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engine", required=True, type=Path, help="an engine folder: build/libspektralab_engine.dylib, tests/spk_ctypes.py")
    ap.add_argument("--out", type=Path, default=HERE / "build" / "film_parity")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true", help="also write each case's render as a PNG")
    ap.add_argument("--self-test", action="store_true", help="break the app's answer on purpose and count what is caught")
    a = ap.parse_args()

    sys.path.insert(0, str(a.engine / "tests"))
    import spk_ctypes as spk  # noqa: E402
    import overscan_checks as oc  # noqa: E402  (its DX reader)

    todo = cases()
    if a.self_test:
        # a date on Kodak's layout, and Ilford's: the one layout whose code lies turned
        todo = [c for c in todo if c["id"] in ("135_date_lcd_br", "135_ilford_hp5_plus_400")]
    elif a.only:
        want = set(a.only.split(","))
        todo = [c for c in todo if c["id"] in want]
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "cases.json").write_text(json.dumps(todo, indent=1))
    build_tool()
    r = subprocess.run([str(TOOL), str(a.out / "cases.json"), str(a.out / "port"), str(HERE / "Resources" / "StockCatalog.json")],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("the app's layout failed:\n" + r.stderr)

    failures = 0
    missed = 0
    rows: list[str] = []
    dylib = a.engine / "build" / "libspektralab_engine.dylib"
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=dylib, resources=resources(a.engine, tmp)) as e:
        for c in todo:
            cid = c["id"]
            port = json.loads((a.out / "port" / f"{cid}.json").read_text())
            img = np.full((c["frame_h"], c["frame_w"], 3), 0.184, np.float32)
            s = e.open(img, engine_params(c, port.get("wire", {})))
            try:
                rgba, _ = s.render("full")           # the frame as given: the live tier would scale it
                geo = s.overscan_geometry()
            finally:
                s.close()
            H, W = rgba.shape[:2]
            raw = a.out / "port" / f"{cid}.gray"
            mask = None
            if port.get("valid") and (port["canvas_w"], port["canvas_h"]) == (W, H):
                mask = np.fromfile(raw, dtype=np.uint8).reshape(H, W)
            if a.self_test:
                if mask is None:
                    sys.exit("the self-test's own case does not line up; run without --self-test first")
                missed += self_test(c, port, mask, rgba, geo, oc)
                continue
            for name, ok, detail in compare(c, port, mask, rgba, geo, oc):
                failures += 0 if ok else 1
                rows.append(f"{'PASS' if ok else 'FAIL'}  {cid:34s} {name:14s} {detail}")
            if a.keep:
                (a.out / "engine").mkdir(exist_ok=True)
                write_png(a.out / "engine" / f"{cid}.png", (np.clip(rgba[..., :3] / 65535.0, 0, 1) * 255).astype(np.uint8))

    if a.self_test:
        print(f"{missed} broken layouts missed, {len(todo)} cases")
        return missed
    print("\n".join(rows))
    print(f"\n{len(rows) - failures} passed, {failures} failed, {len(todo)} cases, engine {a.engine}")
    return failures


if __name__ == "__main__":
    sys.exit(min(main(), 255))
