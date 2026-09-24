"""Every wire field, applied to a live session, rendered.

The render-parity suite opens a *fresh* session per case, so it never exercises
the path a user actually takes: open once, then move sliders. That gap hid a
bug that broke twelve of the print-layer fields -- most of the right-hand panel
-- with a hard error.

The bug: anything outside `LIVE_MUTABLE` replaces the pipeline, but only a
*shoot*-layer change drops the cached negative. So a print-layer rebuild left a
fresh pipeline reprinting a negative it had never rendered, with no pixel pitch
and no way to get one. `parity_render.py` could not see it and neither could
the Swift tests.

So this walks the schema itself: for every field, set it on an already-open
session and render. It asserts three things, all of which the bug broke:

  * the render succeeds;
  * `invalidated` matches the field's declared layer, because that is what
    decides whether the negative is reused -- getting it wrong lets a
    shoot-side edit silently reprint a stale negative;
  * a shoot-layer edit actually re-renders the negative, and a print-layer one
    actually reuses it.

Usage: engine/tests/parity_session.py [--verbose]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE.parent / "src"))
sys.path.insert(0, str(ENGINE / "tests"))

# A value that differs from the default for every declared field, so each one
# actually changes something. Stock fields get a real alternative stock.
OVERRIDES: dict[str, object] = {
    "film_stock": "kodak_gold_200",
    "print_stock": "kodak_endura_premier",
    "input_color_space": "sRGB",
    "output_color_space": "sRGB",
    "enlarger_illuminant": "D65",
    # Not the default, and one of RFC-015 §2.3's four intents. A str field with
    # no strategy used to stop the walk before the exposure comparison below.
    "auto_exposure_method": "balanced",
    # RFC-023: the other enumerated string, and two knees chosen by hand -- a
    # third of the way into [-24, 24] puts both at -8, and the engine refuses
    # a crossed pair (the walk applies the fields cumulatively, so both rooms
    # are on by the time the second knee lands).
    "scene_latitude_norm": "y",
    # RFC-024's scheme has one product value; the walk sends it back as is.
    "contrast_mask_scheme": "gaussian",
    "scene_latitude_highlight_knee": 4.0,
    "scene_latitude_shadow_knee": -12.0,
}

# Print-layer fields that nevertheless invalidate cached work. The walk below
# asserts the usual rule -- a print-layer edit reprints the negative it already
# has -- and `preview_long_edge` is the exception that proves the rule is about
# the *film* side: the negative is fine, but the live tier's copy of it was
# made at the old size, so `spk_set_params` drops that tier (the reference's
# `apply_delta` drops it too) and the next live render makes a new one.
PRINT_LAYER_DROPS_NEGATIVE = {"preview_long_edge"}


def value_for(field: dict):
    name, kind = field["name"], field["type"]
    if name in OVERRIDES:
        return OVERRIDES[name]
    if kind == "bool":
        return not field["default"]
    if kind == "int":
        lo, hi = field.get("range", [0, 3])
        return int(lo) if field["default"] != lo else int(hi)
    if kind == "float":
        lo, hi = field.get("range", [0.0, 1.0])
        # A third of the way in, which is different from every default in the
        # schema and inside every range.
        candidate = lo + (hi - lo) / 3.0
        return candidate if abs(candidate - field["default"]) > 1e-9 else lo + (hi - lo) * 0.6
    raise AssertionError(f"no value strategy for {name} ({kind})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    from spk_ctypes import Engine

    rng = np.random.default_rng(11)
    frame = (rng.random((300, 400, 3)) * 0.4).astype(np.float32)

    failures = 0
    with Engine() as engine:
        schema = engine.params_schema()
        fields = schema["fields"]
        print(f"{len(fields)} declared fields, applied one at a time to one open session\n")
        session = engine.open(frame, {"grain_active": False, "glare_active": False,
                                      "auto_exposure": False})
        session.render("live", reprint=True)

        for field in fields:
            name = field["name"]
            value = value_for(field)
            try:
                reply = session.set_params({name: value})
                _, result = session.render("live", reprint=True)
            except Exception as exc:
                print(f"FAIL {name:26s} = {value!r:24} -> {exc}")
                failures += 1
                continue

            want_layer = field["layer"]
            got_layer = reply["invalidated"]
            cached = bool(result.negative_was_cached)
            problems = []
            if got_layer != want_layer:
                problems.append(f"invalidated {got_layer!r}, schema says {want_layer!r}")
            # A shoot edit must re-render the negative; a print edit must not.
            if want_layer == "shoot" and cached:
                problems.append("reused the cached negative after a shoot-layer edit")
            if (want_layer == "print" and not cached
                    and name not in PRINT_LAYER_DROPS_NEGATIVE):
                problems.append("re-rendered the negative after a print-layer edit")

            if problems:
                print(f"FAIL {name:26s} = {value!r:24} -> {'; '.join(problems)}")
                failures += 1
            elif args.verbose:
                print(f"ok   {name:26s} = {value!r:24} {got_layer:5s} "
                      f"{'reused' if cached else 're-rendered'} in {result.elapsed_ms:6.1f} ms")

        # --- the settable preview resolution (the `live` tier's size) --------
        # The walk above applies the field and checks its layer, but `frame` is
        # 400 px, so at every legal edge the live tier is the frame itself and
        # nothing there would notice a session that accepted the field and went
        # on ignoring it. This runs on a frame *larger* than both edges, where
        # the two are different renders, and pairs it with the reference
        # resolving the same field through its own params and resolver.
        rng = np.random.default_rng(12)
        big = (rng.random((1200, 1600, 3)) * 0.4).astype(np.float32)
        sized = engine.open(big, {"grain_active": False, "glare_active": False,
                                  "auto_exposure": False})
        for edge in (800, 1600):
            sized.set_params({"preview_long_edge": edge})
            _, result = sized.render("live", reprint=True)
            rendered = max(result.width, result.height)
            if rendered != edge:
                print(f"FAIL preview_long_edge = {edge}: live rendered a "
                      f"{rendered} px long edge")
                failures += 1
            elif args.verbose:
                print(f"ok   preview_long_edge = {edge:5d} -> live renders "
                      f"{result.width}x{result.height}")
        sized.close()

        from spektrafilm.runtime.params_builder import init_params as ref_init_params
        from spektrafilm.service import schema as pyschema
        from spektrafilm.service.session import tier_long_edge

        ref = ref_init_params()
        pyschema.apply_delta(ref, {"preview_long_edge": 2560})
        got = tier_long_edge("live", ref)
        if got != 2560:
            print(f"FAIL the reference resolves preview_long_edge = 2560 to {got!r}")
            failures += 1
        elif args.verbose:
            print("ok   the reference resolves the same field to the same live edge")

        # --- the two methods the field walk does not reach ------------------
        from spektrafilm.utils.autoexposure import measure_autoexposure_ev
        from spektrafilm.utils.preview import resize_for_preview

        session.set_params({f["name"]: f["default"] for f in fields
                            if f["name"] not in ("film_stock", "print_stock")})

        # `solve(exposure)` meters the whole live tier, unlike the
        # auto-exposure *node*, which meters a 256 px stride sample. The two
        # differ by ~3e-3 EV, so which one `solve` reproduces is a real choice
        # and this is what pins it.
        got_ev = session.solve("exposure")["solved_params"]["exposure_compensation_ev"]
        want_ev = float(measure_autoexposure_ev(
            resize_for_preview(frame, 1600)[..., :3], "ProPhoto RGB", False,
            method="center_weighted"))
        if abs(got_ev - want_ev) > 1e-6:
            print(f"FAIL solve(exposure): {got_ev:+.8f} EV, reference {want_ev:+.8f} EV")
            failures += 1
        elif args.verbose:
            print(f"ok   solve(exposure)          {got_ev:+.6f} EV, matches the reference")

        # `preview_render` exists to force the film side; without that it is
        # `reprint` in everything but the flag it reports.
        session.render("live", reprint=True)
        _, cached = session.render("live", reprint=True)
        _, forced = session.render("live", reprint=False)
        if not cached.negative_was_cached:
            print("FAIL reprint re-rendered the negative instead of reusing it")
            failures += 1
        if forced.negative_was_cached:
            print("FAIL preview_render reused the cached negative instead of forcing the film side")
            failures += 1
        if args.verbose:
            print("ok   reprint reuses the negative, preview_render forces the film side")

        session.close()

    if not failures:
        print(f"ok   all {len(fields)} fields applied, rendered, and invalidated the right layer")
        print("ok   solve and preview_render match the reference")
    print(f"\n{len(fields)} fields, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
