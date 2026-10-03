#!/usr/bin/env python3
"""RFC-032 §27 checks for overscan and the date back. Needs only `build.sh dylib`.

    python3 engine/tests/overscan_checks.py [--dylib path]

Grain and print glare draw fresh seeds per render, so every comparison here
turns them off; what is compared is the overscan's own randomness, which is
seeded. Against an engine from before RFC-032 the first check fails
(`unknown parameter 'overscan_active'`) -- that is the red this was shown.
"""
import argparse, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "grain_active": False,
        "glare_active": False, "auto_exposure": False}


def frame(w, h, seed=1):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.05 + 0.4 * (x / w)[..., None] * np.array([1.0, 0.9, 0.7]) + 0.3 * (y / h)[..., None]
    return (img + 0.02 * rng.standard_normal((h, w, 3))).astype(np.float32)


def render(e, img, extra, tier="live"):
    p = dict(BASE); p.update(extra)
    s = e.open(img, p)
    try:
        rgba, _ = s.render(tier)
    finally:
        s.close()
    return rgba


def decode_dx(rgba, px):
    """Read the DX code back off the render's bottom band, as a reader would:
    find the clock track (5-bar, 23 alternating singles, 3-bar) on one row,
    sample the data track at the clock's module centres. Returns
    (dx_extract, frame, half, parity_ok) for the first complete code, or None."""
    lum = rgba[..., :3].astype(float).mean(-1)
    H = lum.shape[0]
    # rows by distance from the canvas's bottom edge, which is the carrier
    # 0.40 mm past the film's: the clock track below the perforations, the
    # data track at the edge (1.59 and 0.49 mm into the film)
    clock = lum[H - 1 - int(round(1.99 / px))]
    data = lum[H - 1 - int(round(0.89 / px))]

    def threshold(row):
        ink = row[row < 0.9 * 65535]          # the scan's light through a hole is not ink
        return 0.5 * (np.percentile(ink, 98) + np.percentile(ink, 5))
    thr = threshold(clock)
    b = clock > thr
    edges = np.flatnonzero(np.diff(b.astype(int))) + 1
    runs = np.split(np.arange(len(b)), edges)
    for i in range(len(runs) - 25):
        if not b[runs[i][0]]:
            continue
        seg = runs[i:i + 25]
        lens = np.array([len(r) for r in seg], float)
        mod = lens.sum() / 31.0
        if abs(lens[0] - 5 * mod) > 1.3 * mod or abs(lens[-1] - 3 * mod) > 1.1 * mod:
            continue
        if np.any(lens[1:-1] < 0.45 * mod) or np.any(lens[1:-1] > 1.7 * mod):
            continue
        x0 = seg[0][0]
        centres = x0 + (np.arange(31) + 0.5) * mod
        dthr = threshold(data)
        bits = [int(data[int(c)] > dthr) for c in centres]
        if bits[:5] != [1, 0, 1, 0, 1] or bits[28:] != [1, 0, 1]:
            continue
        d = bits[5:28]
        val = lambda a, n: int("".join(map(str, d[a:a + n])), 2)
        parity_ok = sum(d[:21]) % 2 == d[21] and d[0] == d[8] == d[20] == d[22] == 0
        return val(1, 7) * 16 + val(9, 4), val(13, 6), bool(d[19]), parity_ok
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path)
    a = ap.parse_args()
    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'} {name}{(' -- ' + detail) if detail else ''}")

    with spk.Engine(dylib=a.dylib) as e:
        img = frame(1200, 800)
        off = render(e, img, {"overscan_active": False})
        check("off keeps the frame's size", off.shape[:2] == (800, 1200), str(off.shape))

        on = render(e, img, {"overscan_active": True, "overscan_format": "135", "overscan_edge_text": "KODAK PORTRA 400"})
        H, W = on.shape[:2]
        px = 36.25 / 1200                                   # the 135 gate's long edge over the frame (a camera's, measured)
        # the scan shows 0.40 mm of carrier past each long edge (answer sheet C2)
        check("135 canvas spans the film's width and its carrier", 35.6 < H * px <= 36.0, f"{H * px:.3f} mm")
        check("135 canvas is the frame plus two part-gaps", 36.25 + 1.4 < W * px < 36.25 + 2.0, f"{W * px:.3f} mm")
        # The gate is a camera's (reference_film/135: 0.47-0.67 mm from the
        # perforations, whose inner edge is 4.8 mm in; the canvas starts 0.40 mm
        # before the film). A 24.0 mm gate leaves 5.9 mm from the canvas's edge.
        edge_to_gate = (H - 800) / 2 * px
        check("135 gate sits ~0.6 mm inside the perforations", 5.7 < edge_to_gate < 5.85, f"{edge_to_gate:.3f} mm")

        again = render(e, img, {"overscan_active": True, "overscan_format": "135", "overscan_edge_text": "KODAK PORTRA 400"})
        check("same seeds, same film", np.array_equal(on, again))

        other = render(e, img, {"overscan_active": True, "overscan_format": "135", "overscan_edge_text": "KODAK PORTRA 400",
                                "overscan_frame_seed": 2})
        same_shape = other.shape == on.shape
        check("another frame seed moves the film", not same_shape or not np.array_equal(on, other))

        sq = frame(1000, 1000)
        m = render(e, sq, {"overscan_active": True, "overscan_format": "120_6x6", "overscan_edge_text": "KODAK 200"})
        px = 56.0 / 1000
        check("120 canvas spans the film's width and its carrier", 61.6 < m.shape[0] * px < 62.0, f"{m.shape[0] * px:.2f} mm")

        date = render(e, img, {"date_imprint_active": True, "date_imprint_text": "'26 9 28", "film_format_mm": 36.0})
        check("date alone keeps the frame's size", date.shape[:2] == (800, 1200))
        diff = np.abs(date.astype(int) - off.astype(int))[..., :3].sum(-1)
        ys, xs = np.nonzero(diff > 2000)
        check("the date lands lower right", len(xs) > 50 and xs.mean() > 0.6 * 1200 and ys.mean() > 0.7 * 800,
              f"{len(xs)} px at ({xs.mean() if len(xs) else 0:.0f}, {ys.mean() if len(ys) else 0:.0f})")

        try:
            render(e, img, {"overscan_active": True, "striped": True})
            check("striped executor refuses overscan", False, "it rendered")
        except spk.EngineError as err:
            check("striped executor refuses overscan", "striped" in str(err), str(err)[:80])

        try:
            render(e, img, {"overscan_active": True, "overscan_format": "110"})
            check("an unknown format is refused", False, "it rendered")
        except spk.EngineError as err:
            check("an unknown format is refused", "format" in str(err), str(err)[:80])

        # --- RFC-032 §29 -------------------------------------------------------
        S135 = {"overscan_active": True, "overscan_format": "135", "overscan_edge_text": "KODAK PORTRA 400"}
        px = 36.25 / 1200
        dx = decode_dx(on, px)
        check("the DX code reads back as Portra 400 (1277) with good parity",
              dx is not None and dx[0] == 1277 and dx[3], str(dx))
        gold = render(e, img, dict(S135, film_stock="kodak_gold_200"))
        dxg = decode_dx(gold, px)
        # 1548, read back off the real Gold 200 strip in reference_film/135 (the database said 1250)
        check("another stock, another DX number (Gold 200 = 1548)", dxg is not None and dxg[0] == 1548, str(dxg))
        # the DX code is 12.7 mm on Kodak-made film, 14.1 on Fujifilm's X-Tra 400
        xt = render(e, img, dict(S135, film_stock="fujifilm_xtra_400", overscan_edge_text="S-400"))
        dxx = decode_dx(xt, px)
        check("X-Tra 400's own, longer DX code reads back (628)", dxx is not None and dxx[0] == 628, str(dxx))
        # Fujifilm's slides print no bars, and their edge is not Kodak's
        for stock in ("fujifilm_provia_100f", "fujifilm_velvia_100"):
            sl = render(e, img, dict(S135, film_stock=stock, scan_film=True, overscan_edge_text="RVP100"))
            check(f"{stock} prints no DX bars", decode_dx(sl, px) is None)
        # the film edge is the stock's own: the same text on a Fujifilm and a Kodak stock differs
        sq2 = frame(1000, 1000)
        fk = render(e, sq2, dict(S135, overscan_format="120_6x6", overscan_edge_text="PRO400H"))
        ff = render(e, sq2, dict(S135, film_stock="fujifilm_pro_400h", overscan_format="120_6x6", overscan_edge_text="PRO400H"))
        band = lambda r: r[: int(1.9 / (56.0 / 1000)), :, :3].astype(float).mean(-1)
        check("a Fujifilm 120 edge is not Kodak's layout", fk.shape == ff.shape and
              np.abs(band(fk) - band(ff)).mean() > 500, f"{np.abs(band(fk) - band(ff)).mean():.0f}")
        # the reader must be able to say no: a stock with no DX code prints none
        vis = render(e, img, dict(S135, film_stock="kodak_vision3_250d"))
        check("a stock without a DX code prints none (the reader finds nothing)", decode_dx(vis, px) is None)

        # The perforations: the scan's light by default, the print's black on request.
        def perf_values(rgba):
            # the top perforation row's band, between the film edge and the gate
            band = rgba[int(round(2.3 / px)):int(round(4.5 / px)), :, :3].astype(float).mean(-1)
            return np.percentile(band, 99), np.percentile(band, 50)
        hi_light, _ = perf_values(on)
        printed = render(e, img, dict(S135, overscan_holes="black"))
        hi_print, _ = perf_values(printed)
        check("holes = white shows the light through the perforations", hi_light > 0.9 * 65535, f"{hi_light:.0f}")
        check("holes = black leaves them dark", hi_print < 0.25 * 65535, f"{hi_print:.0f}")
        # black holes are still holes: darker than the rebate around them
        bb = printed[int(round(2.3 / px)):int(round(4.5 / px)), :, :3].astype(float)
        bl = bb.mean(-1)
        hole_dark, rebate = np.percentile(bl, 1), np.median(bl)
        check("black holes read: darker than the rebate", hole_dark < 0.5 * rebate,
              f"hole {hole_dark:.0f} vs rebate {rebate:.0f}")

        # A hole is white inside (RFC-032 §30.5); its edges carry the
        # randomness, and no two holes' edges are alike.
        band = on[int(round(2.3 / px)):int(round(4.5 / px)), :, :3].astype(float)
        inner = band[band.min(-1) > 0.98 * 65535]
        check("hole interiors are white", len(inner) > 1000 and np.abs(inner.mean(0) - inner.mean()).max() < 150,
              f"{len(inner)} px, mean {inner.mean(0).round(0) if len(inner) else None}")
        # the cut's shoulder (RFC-032 §31.5) is not the same on every hole: the
        # lift of the black just outside each hole must vary between holes.
        # Measured at 0.015 mm/px and beyond each hole's anti-aliased pixel,
        # since the edge's sub-pixel phase repeats every three holes and would
        # otherwise dominate; without edge fog, which also lifts the rebate.
        def shoulder(rgba, p):
            b = rgba[int(round(2.3 / p)):int(round(4.5 / p)), :, :3].astype(float)
            lum = b.mean(-1)
            reb = np.median(lum)
            hole = lum > 0.5 * 65535
            grown = hole.copy()
            for _ in range(2):                        # the hole and its anti-aliased pixel
                g = grown.copy()
                g[1:] |= grown[:-1]; g[:-1] |= grown[1:]; g[:, 1:] |= grown[:, :-1]; g[:, :-1] |= grown[:, 1:]
                grown = g
            ring = grown.copy()
            for _ in range(5):                        # the next five pixels out
                g = ring.copy()
                g[1:] |= ring[:-1]; g[:-1] |= ring[1:]; g[:, 1:] |= ring[:, :-1]; g[:, :-1] |= ring[:, 1:]
                ring = g
            ring &= ~grown
            cols = np.flatnonzero(hole.any(0))
            if not len(cols):
                return np.array([])
            groups = np.split(cols, np.flatnonzero(np.diff(cols) > 5) + 1)
            out = []
            for g in groups[1:-1]:                    # whole holes only
                sl = slice(max(0, g[0] - 12), g[-1] + 13)
                out.append(np.clip(lum[:, sl][ring[:, sl]] - reb, 0, None).mean())
            return np.array(out)
        big = frame(2400, 1600)
        sh = shoulder(render(e, big, dict(S135, overscan_fog=0.0), tier="preview"), 36.0 / 2400)
        check("hole edges differ from hole to hole (the cut's shoulder)",
              len(sh) >= 4 and sh.std() / max(sh.mean(), 1e-9) > 0.25, f"{len(sh)} holes, mean lift {np.round(sh, 0)}")

        # Gate families: each renders, and each changes the gate. On a frame
        # of the 645 gate's shape (56 x 41.5), since the frame is the gate.
        img645 = frame(1200, 889)
        sq = render(e, img645, dict(S135, overscan_format="120_645", overscan_gate="square"))
        for fam in ("rounded", "eared", "kicked", "shouldered"):
            r = render(e, img645, dict(S135, overscan_format="120_645", overscan_gate=fam))
            check(f"gate {fam} differs from square", r.shape == sq.shape and not np.array_equal(r, sq))
        for bad, field in (("hexagon", "overscan_gate"), ("light", "overscan_holes")):
            try:
                render(e, img, dict(S135, **{field: bad}))
                check(f"an unknown {field} is refused", False, "it rendered")
            except spk.EngineError as err:
                check(f"an unknown {field} is refused", bad in str(err), str(err)[:80])
        m68 = render(e, sq_img := frame(1520, 1120), dict(S135, overscan_format="120_6x8", overscan_edge_text="KODAK EKTAR 100"))
        check("120_6x8 renders the film's width", 61.6 < m68.shape[0] * (76.0 / 1520) < 62.0 or 61.6 < m68.shape[1] * (76.0 / 1520) < 62.0,
              str(m68.shape))

        # The date back's faces, corners and size, on the frame alone.
        DATE = {"date_imprint_active": True, "date_imprint_text": "'26 10 1", "film_format_mm": 36.0}
        def lit(rgba):
            dd = np.abs(rgba.astype(int) - off.astype(int))[..., :3].sum(-1)
            ys, xs = np.nonzero(dd > 2000)
            return len(xs), (xs.mean() if len(xs) else 0), (ys.mean() if len(ys) else 0)
        n_lcd, _, _ = lit(date)
        n_dots, xd, yd = lit(render(e, img, dict(DATE, date_imprint_style="dots")))
        check("dots style draws in the lower right", n_dots > 50 and xd > 0.6 * 1200 and yd > 0.7 * 800, f"{n_dots} px")
        n_tl, xt, yt = lit(render(e, img, dict(DATE, date_imprint_corner="tl")))
        check("corner tl moves the date to the upper left", n_tl > 50 and xt < 0.4 * 1200 and yt < 0.3 * 800,
              f"({xt:.0f}, {yt:.0f})")
        n_big, _, _ = lit(render(e, img, dict(DATE, date_imprint_size=2.0)))
        check("size 2 roughly quadruples the date's area", 2.5 * n_lcd < n_big < 6.0 * n_lcd, f"{n_lcd} -> {n_big}")
        # The date back is part of the camera (RFC-032 §32): placed and turned in
        # the film's frame. A full frame shot turned (portrait) carries the date
        # along the film -- a tall, narrow mark at the picture's lower left,
        # never upright. A half frame held level is portrait with the film
        # running across it, so its date is upright at the lower right.
        def date_box(rgba, base_rgba):
            dd = np.abs(rgba.astype(int) - base_rgba.astype(int))[..., :3].sum(-1)
            ys, xs = np.nonzero(dd > 2000)
            return (xs.min(), xs.max(), ys.min(), ys.max()) if len(xs) else None
        pimg = frame(800, 1200)                     # 24 x 36, turned
        pb = date_box(render(e, pimg, dict(DATE)), render(e, pimg, {"film_format_mm": 36.0}))
        check("a turned full frame carries the date along the film (tall, lower left)",
              pb is not None and (pb[3] - pb[2]) > 2.5 * (pb[1] - pb[0]) and pb[1] < 0.4 * 800 and pb[2] > 0.5 * 1200,
              f"box x {pb[0]}-{pb[1]}, y {pb[2]}-{pb[3]}" if pb else "no date")
        himg = frame(900, 1200)                     # 18 x 24, a half frame held level
        HALF = {"film_format_mm": 24.0, "overscan_format": "135_half"}
        hb = date_box(render(e, himg, dict(DATE, **HALF)), render(e, himg, HALF))
        check("a half frame held level carries the date upright (wide, lower right)",
              hb is not None and (hb[1] - hb[0]) > 2.5 * (hb[3] - hb[2]) and hb[0] > 0.4 * 900 and hb[2] > 0.7 * 1200,
              f"box x {hb[0]}-{hb[1]}, y {hb[2]}-{hb[3]}" if hb else "no date")
        half = render(e, himg, dict(S135, overscan_format="135_half"))
        hpx = 24.0 / 1200
        check("135_half canvas: the film's width across, the frame plus ~1 mm along",
              35.6 < half.shape[0] * hpx <= 36.0 and 18.7 < half.shape[1] * hpx < 19.1,
              f"{half.shape[1] * hpx:.2f} x {half.shape[0] * hpx:.2f} mm")
        # with overscan on, a turned full frame's date also runs along the film
        pov = render(e, pimg, dict(S135))
        pod = date_box(render(e, pimg, dict(S135, **DATE)), pov)
        check("with overscan, a turned full frame's date runs along the film too",
              pod is not None and (pod[3] - pod[2]) > 2.5 * (pod[1] - pod[0]),
              f"box x {pod[0]}-{pod[1]}, y {pod[2]}-{pod[3]}" if pod else "no date")
        dat = render(e, img, dict(S135, date_imprint_active=True, date_imprint_style="data",
                                  date_imprint_text="Av 1/125 F2.8 ISO 200"))
        base = render(e, img, S135)
        dd = np.abs(dat.astype(int) - base.astype(int))[..., :3].sum(-1)
        ys, xs = np.nonzero(dd > 2000)
        gate_x0 = (dat.shape[1] - 1200) / 2
        check("data style prints between frames, outside the picture", len(xs) > 50 and xs.max() < gate_x0 + 2,
              f"{len(xs)} px, x <= {xs.max() if len(xs) else -1}")
        # The owner's frame number (2026-10-03): 0 is the seed's draw, byte for
        # byte; a number set changes the marks on every layout that numbers
        # frames, and two numbers differ from each other.
        for fmt, img_, stock in (("135", img, "kodak_portra_400"), ("120_6x7", frame(725, 900), "kodak_gold_200"),
                                 ("120_6x7", frame(725, 900), "fujifilm_pro_400h")):
            base_ = dict(S135, overscan_format=fmt, film_stock=stock)
            n0 = render(e, img_, base_)
            n0b = render(e, img_, dict(base_, overscan_frame_number=0))
            n7 = render(e, img_, dict(base_, overscan_frame_number=7))
            n8 = render(e, img_, dict(base_, overscan_frame_number=8))
            check(f"frame number 0 is the seeded draw ({stock}, {fmt})", np.array_equal(n0, n0b))
            check(f"frame number 7 changes the edge ({stock}, {fmt})", not np.array_equal(n0, n7))
            check(f"frame numbers 7 and 8 differ ({stock}, {fmt})", not np.array_equal(n7, n8))
        try:
            render(e, frame(1800, 600), S135)
            check("a frame that is not the gate's shape is refused", False, "it rendered")
        except spk.EngineError as err:
            check("a frame that is not the gate's shape is refused", "gate's shape" in str(err), str(err)[:90])
        for fmt, (w, h) in (("135_half", (900, 1200)), ("120_645", (900, 667)), ("120_6x6", (700, 700)), ("120_6x7", (725, 900))):
            try:
                render(e, frame(w, h), {"overscan_active": True, "overscan_format": fmt})
                check(f"a {w} x {h} frame is the {fmt} gate's shape", True)
            except spk.EngineError as err:
                check(f"a {w} x {h} frame is the {fmt} gate's shape", False, str(err)[:90])
        try:
            render(e, img, dict(DATE, date_imprint_style="neon"))
            check("an unknown date style is refused", False, "it rendered")
        except spk.EngineError as err:
            check("an unknown date style is refused", "neon" in str(err), str(err)[:80])

        # A reprint of a film canvas. The print side masks the holes with the
        # layout of the frame it is printing, and one session reprints several:
        # the live tier after the full one has rendered, and any tier after a
        # print-layer edit has rebuilt the pipeline. Every case is compared
        # with a fresh session rendering the same parameters, pixel for pixel.
        # A frame larger than the live tier, so the two tiers' canvases differ.
        big = frame(3000, 2000)

        def reprint_case(name, steps, final):
            s = e.open(big, dict(BASE, **S135))
            try:
                try:
                    out = steps(s)
                except spk.EngineError as err:
                    check(name, False, str(err)[:90])
                    return
            finally:
                s.close()
            want = render(e, big, dict(S135, **final), tier="live")
            check(name, out.shape == want.shape and np.array_equal(out, want), f"{out.shape[:2]}")

        def live_after_full(s):
            s.render("live"); s.render("full")
            return s.render("live", reprint=True)[0]
        reprint_case("the live tier reprints after the full tier has rendered", live_after_full, {})

        def live_edit_after_full(s):
            s.render("live"); s.render("full")
            s.set_params({"print_exposure": 0.7})
            return s.render("live", reprint=True)[0]
        reprint_case("a live print edit reprints after the full tier has rendered", live_edit_after_full,
                     {"print_exposure": 0.7})

        for field, value in (("print_stock", "kodak_portra_endura"), ("scan_film", True),
                             ("digital_intermediate", True), ("extended_dynamic_range", True)):
            def rebuilt(s, field=field, value=value):
                s.render("live")
                s.set_params({field: value})
                return s.render("live", reprint=True)[0]
            reprint_case(f"a reprint after {field} rebuilt the pipeline", rebuilt, {field: value})

        s = e.open(big, dict(BASE, **S135))
        try:
            s.render("live")
            di, _ = s.render_digital_intermediate()
            want = render(e, big, dict(S135, digital_intermediate=True), tier="full")
            check("the Digital Intermediate export of a film canvas", di.shape == want.shape, f"{di.shape[:2]}")
        except spk.EngineError as err:
            check("the Digital Intermediate export of a film canvas", False, str(err)[:90])
        finally:
            s.close()

        # Marks stay where they belong: a long edge text ends before the next
        # frame number, and a date too large or too far inset for the frame
        # stays inside it instead of running off its edge.
        # The 135 slot is 30.1 mm at 1.15 mm caps (~1.16 mm a character with
        # tracking): 26 characters, cut back to the last whole word.
        long_ = render(e, img, dict(S135, overscan_edge_text="KODAK " * 50))
        cut = render(e, img, dict(S135, overscan_edge_text="KODAK KODAK KODAK KODAK"))
        other = render(e, img, dict(S135, overscan_edge_text="KODAK KODAK KODAK KODA"))
        check("a long edge text is cut to the words that fit its slot",
              np.array_equal(long_, cut) and not np.array_equal(long_, other))
        big = render(e, img, dict(DATE, date_imprint_size=3.0, date_imprint_inset_x=0.0, date_imprint_inset_y=0.0))
        far = render(e, img, dict(DATE, date_imprint_inset_x=30.0, date_imprint_inset_y=30.0))
        bare = render(e, img, {"film_format_mm": 36.0})
        for name, r in (("size 3 at inset 0", big), ("inset 30 mm", far)):
            dd = np.abs(r.astype(int) - bare.astype(int))[..., :3].sum(-1)
            ys, xs = np.nonzero(dd > 2000)
            # the lcd face at size 3 is ~3.9 mm tall and ~26 mm wide: all of it in the 36 x 24 frame
            check(f"the date at {name} stays inside the frame", len(xs) > 500 and xs.max() < 1200 - 2 and ys.max() < 800 - 2
                  and (xs.max() - xs.min()) * px > 6.0, f"{len(xs)} px, x {xs.min() if len(xs) else -1}-{xs.max() if len(xs) else -1}")
        # --- the panoramic long formats and the carrier (answer sheet C1-C7) ---
        for fmt, (gl, gs), film_w in (("135_xpan", (65.0, 24.0), 35.0), ("120_6x12", (112.0, 56.0), 61.0),
                                      ("120_6x17", (168.0, 56.0), 61.0)):
            fw = 1200
            fh = int(round(fw * gs / gl))
            pimg_ = frame(fw, fh)
            P = {"overscan_active": True, "overscan_format": fmt, "overscan_edge_text": "KODAK PORTRA 400"}
            r = render(e, pimg_, P)
            ppx = gl / fw
            across, along = r.shape[0] * ppx, r.shape[1] * ppx
            check(f"{fmt} renders the film's width, its carrier, and the frame along",
                  film_w + 0.5 < across < film_w + 1.0 and gl + 1.0 < along < gl + 5.0, f"{along:.2f} x {across:.2f} mm")
            lum = r[..., :3].astype(float).mean(-1)
            # the outermost rows are the carrier: black on every column, however the scan sits
            check(f"{fmt} shows a black carrier past both long edges",
                  lum[0].max() < 0.02 * 65535 and lum[-1].max() < 0.02 * 65535, f"{lum[0].max():.0f}, {lum[-1].max():.0f}")
            op = render(e, pimg_, dict(P, overscan_carrier="open"))
            lo = op[..., :3].astype(float).mean(-1)
            check(f"{fmt} with an open carrier shows the scan's light there",
                  lo[0].min() > 0.9 * 65535 and lo[-1].min() > 0.9 * 65535, f"{lo[0].min():.0f}, {lo[-1].min():.0f}")
            inner = slice(int(1.5 / ppx), -int(1.5 / ppx))
            check(f"{fmt}: the carrier changes nothing on the film", np.array_equal(r[inner], op[inner]))
            dated = render(e, pimg_, dict(P, date_imprint_active=True, date_imprint_text="'26 10 1"))
            check(f"{fmt} carries no date", np.array_equal(r, dated))
        try:
            render(e, img, dict(S135, overscan_carrier="grey"))
            check("an unknown carrier is refused", False, "it rendered")
        except spk.EngineError as err:
            check("an unknown carrier is refused", "carrier" in str(err), str(err)[:80])
        # The tilt is capped by end travel (0.27 mm of the 0.40 mm carrier): over
        # many frames a 6x17 strip reaches the canvas's edge at a corner at most,
        # never along a length of it. At the old 0.35 degrees it travelled 0.52.
        worst = 0.0
        p617 = frame(1200, 400)
        for seed in range(1, 25):
            rr = render(e, p617, {"overscan_active": True, "overscan_format": "120_6x17", "overscan_frame_seed": seed})
            ll = rr[..., :3].astype(float).mean(-1)
            worst = max(worst, (ll[0] > 0.02 * 65535).mean(), (ll[-1] > 0.02 * 65535).mean())
        check("6x17 never tilts its film out of the carrier (24 frames)", worst < 0.15, f"{worst:.3f} of an edge row")
        # --- the half-frame pair: two exposures of one gate on one strip, and
        # where the gates are (spk_overscan_geometry) ---------------------------
        def geometry(img_, extra):
            p = dict(BASE); p.update(extra)
            s = e.open(img_, p)
            try:
                r_, _ = s.render("live")
                return r_, s.overscan_geometry()
            finally:
                s.close()
        hw, hh = 450, 600                                   # one half frame, 18 x 24
        adv = int(round(19.0 / (18.0 / hw)))                # the advance, in picture pixels
        both = np.zeros((hh, adv + hw, 3), np.float32)
        both[:, :hw] = frame(hw, hh, 1); both[:, adv:] = 0.6 * frame(hw, hh, 2)
        PAIR = {"overscan_active": True, "overscan_format": "135_half", "overscan_pair": True,
                "overscan_edge_text": "KODAK PORTRA 400"}
        pr, pg = geometry(both, PAIR)
        check("a pair renders one strip with two gates", pg.get("valid") and len(pg["gates"]) == 2, str(pg)[:120])
        ch_, cw_ = pr.shape[:2]
        widths = [(g[2] - g[0]) * cw_ for g in pg["gates"]]
        heights = [(g[7] - g[1]) * ch_ for g in pg["gates"]]
        check("each gate is one half frame on the canvas", all(abs(w_ - hw) < 3 for w_ in widths) and all(abs(h_ - hh) < 3 for h_ in heights),
              f"{widths} x {heights}")
        step = (pg["gates"][1][0] - pg["gates"][0][0]) * cw_
        check("the gates are one advance apart", abs(step - adv) < 2, f"{step:.1f} px for {adv}")
        # the gap between them is unexposed film: as dark as the rebate, and the pictures are not
        lum = pr[..., :3].astype(float).mean(-1)
        gx = int((pg["gates"][0][2] + pg["gates"][1][0]) * 0.5 * cw_)
        gy0, gy1 = int(pg["gates"][0][1] * ch_) + 20, int(pg["gates"][0][7] * ch_) - 20
        inside = lum[gy0:gy1, int(pg["gates"][0][0] * cw_) + 20:int(pg["gates"][0][2] * cw_) - 20].mean()
        check("the gap between the frames is unexposed film", lum[gy0:gy1, gx].mean() < 0.35 * inside,
              f"gap {lum[gy0:gy1, gx].mean():.0f}, picture {inside:.0f}")
        _, sg = geometry(frame(hw, hh), {"overscan_active": True, "overscan_format": "135_half"})
        check("a single frame has one gate", sg.get("valid") and len(sg["gates"]) == 1)
        _, og = geometry(img, {})
        check("no geometry with overscan off", og == {"valid": False}, str(og))
        d0 = render(e, both, dict(PAIR, date_imprint_active=True, date_imprint_text="'26 10 1"))
        d1 = render(e, both, dict(PAIR, date_imprint_active=True, date_imprint_text="'26 10 1", date_imprint_text_b="'26 10 3"))
        dd = np.abs(d1.astype(int) - d0.astype(int))[..., :3].sum(-1)
        ys, xs = np.nonzero(dd > 2000)
        check("the second frame carries its own date, in its own gate",
              len(xs) > 30 and xs.min() > pg["gates"][1][0] * cw_ and xs.max() < pg["gates"][1][2] * cw_,
              f"{len(xs)} px, x {xs.min() if len(xs) else -1}-{xs.max() if len(xs) else -1}")
        for bad, why in ((dict(PAIR, overscan_format="135"), "135_half"), ):
            try:
                render(e, both, bad)
                check("a pair on another format is refused", False, "it rendered")
            except spk.EngineError as err:
                check("a pair on another format is refused", why in str(err), str(err)[:80])
        # The camera turned: the film runs down the picture and the two frames
        # sit one above the other, the first at the top.
        tr, tg = geometry(np.ascontiguousarray(both.transpose(1, 0, 2)), PAIR)
        th_, tw_ = tr.shape[:2]
        tops = sorted(g[1] * th_ for g in tg.get("gates", []))
        check("a turned pair renders two gates, one above the other",
              tg.get("valid") and tg.get("vertical") and len(tops) == 2 and abs((tops[1] - tops[0]) - adv) < 2,
              f"tops {tops} for an advance of {adv}")
        tl = tr[..., :3].astype(float).mean(-1)
        gyt = int((tg["gates"][0][5] + tg["gates"][1][1]) * 0.5 * th_) if len(tops) == 2 else 0
        g0 = tg["gates"][0]
        xs_ = sorted(g0[0::2]); x0_, x1_ = int(xs_[0] * tw_) + 20, int(xs_[-1] * tw_) - 20
        ys_ = sorted(g0[1::2])
        check("the gap of a turned pair is unexposed film",
              tl[gyt, x0_:x1_].mean() < 0.35 * tl[int(ys_[0] * th_) + 20:int(ys_[-1] * th_) - 20, x0_:x1_].mean(),
              f"gap {tl[gyt, x0_:x1_].mean():.0f}")

    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
