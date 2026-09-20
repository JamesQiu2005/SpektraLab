"""RFC-020 §9 step 6, the F half: FIR halos and the bookkeeping they need.

Step 5's bands were contiguous slices of the same array -- a pointwise node
cannot tell a band from a plane. **F is where that stops**: a neighbourhood
stage reads rows outside the band it writes, so a crossing now has to carry
*context*, and the two ways to get that wrong are both new:

1. **A halo that is too small.** Invisible in the plan, invisible in the pass
   count, and a seam at every band boundary -- which is exactly the failure the
   user asked about when they asked whether stripes show.
2. **A halo that is not composed along a run.** For `A(FIR, R_a) -> B(P) ->
   C(FIR, R_c)` the context needed is `R_a + R_c`: C's output needs A's output
   right on `[y0-R_c, y0+rows+R_c)`, and A's output there needs A's *input* on
   `[y0-R_c-R_a, ...)`. Taking the widest instead of the sum is wrong by
   `min(R_a, R_c)` rows.

   **Measured, because the obvious version of this paragraph is wrong.** The
   failure was expected at `n >= 3` -- "the first and last bands get the
   context a max-halo dropped from the plane's own edge, so an interior band is
   needed". It is not so: every band boundary has an interior *side*, and a
   band's buffer has two edges, so a two-strip plan is already wrong. In the
   max-halo build the axis failed at `n = 2, 8, 17, H` and passed at `n = 1`
   (one strip, no boundary). What the plane's edges protect is the outward side
   of the first and last buffers, not the boundary between two strips.

**The parameters are chosen to be engaged, which is step 5's lesson.** At the
shipped settings on a small frame the film-side sigmas fall to a fraction of a
pixel and the blurs are near-passthroughs, so an axis run there tests the
plumbing and none of the arithmetic -- the mistake that let `boost` be striped
for a whole step. Here `lens_blur_um` and the coupler diffusion are set so that
every blur is a real kernel with a radius of several rows, and the film side's
`film_blurs` and `film_couplers` are **both** band-able, which puts two
neighbourhood stages in one run with a pointwise stage between them.

The halo is checked against an **independent derivation** in Python: the same
sigmas from the same parameters, converted to a radius by the same
`truncate * sigma + 0.5` rule the kernel builder uses. That is not a second
source of truth -- it is a second *route*, and it is the only way to see a
demand that forgot one of a stage's blurs, which is the shape that produces a
halo one kernel short.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402
from pool_invariants import frame  # noqa: E402


def ripple_frame(h: int, w: int) -> np.ndarray:
    """The shared fixture plus a fine vertical ripple.

    **The smooth ramp is the worst possible input for this probe.** A missing
    row of context changes a smooth value by a fraction of a 16-bit quantum, so
    an under-contexted build renders "the same" picture down to a rounding tie:
    measured on the ramp alone, the max-halo build differed in *one pixel by one
    quantum* and at `n = 3` in none at all -- a red case that a different
    fixture could turn green, which is not a red case. Five-row ripple puts real
    contrast between neighbouring rows, so an under-contexted row is wrong by
    something the quantiser cannot hide.
    """
    base = frame(h, w).astype(np.float64)
    y = np.arange(h, dtype=np.float64)[:, None]
    base += 0.15 * np.cos(2.0 * np.pi * y / 5.0)[:, :, None]
    return np.clip(base, 0.01, 0.99).astype(np.float32)

TRUNCATE = 3.0
FILM_FORMAT_MM = 35.0
# `exponential_gaussian_fit(3)`: an isotropic 2-D exponential PSF as three
# Gaussians, as (amplitude, sigma-ratio). Copied from `core/numeric.cpp` -- if
# that fit moves, these expectations move with it and this probe says so.
SURROGATE = (0.5360, 1.5236, 2.7684)

# **The frame is 180 px and that is forced, not chosen for speed.** The wire
# reaches `lens_blur_um` and the on/off flags, but not the halation sigmas nor
# the coupler diffusion lengths -- those are `product_defaults`. The coupler
# tail is 200 µm and its widest surrogate sigma is 2.7684 x lambda, so for that
# blur to be FIR at all the pitch has to exceed 200 * 2.7684 / 3 = 185 µm/px,
# which on a 35 mm format means a long edge under 189 px. Below that the run
# this probe exists for does not form: `film_couplers` resolves `carried` and
# the film segment has one F stage in it instead of two.
#
#   pitch  = 35 * 1000 / 180 = 194.4 µm/px
#   lens   = 100 µm / 194.4 = 0.514 px    -> R = int(3 * 0.514 + 0.5) = 2
#   bounce = 65 µm / 194.4 * sqrt(3)      -> R = 2   (halation's defaults)
#   tail   = 200 µm / 194.4 = 1.029 px    -> widest surrogate sigma 2.848 px -> R = 9
#   run halo = 2 + 0 + 9 = 11;  a max-halo build would use 9 and be wrong in
#   the first two rows of every interior band.
# `striped` is on so the run is reported at all -- `strip_segments` is what the
# striped executor did, and a session that never entered it reports nothing.
# The two stochastic stages have to be off, or the axis compares noise:
# `fresh_seed()` draws a realisation per render, so with grain or glare on, two
# renders of the *same* parameters in the same session differ -- which is why
# `parity_render`'s BASE pins exactly these three. Neither is in the F path:
# both are `Whole`.
NEUTRAL = {"grain_active": False, "glare_active": False, "auto_exposure": False}

CASES = [
    # 1. Two F stages in one band run, so the *run's* halo has to be the sum.
    ("film: two F stages in one run",
     {**NEUTRAL, "product_defaults": True, "lens_blur_um": 100.0, "striped": True}),
    # 2. One F stage whose *own* node blurs twice in a row (`scanner_blur` then
    #    `unsharp`'s mask), so the stage's halo has to be the sum too -- and it
    #    is the case that can see it, because nothing else in that run has a
    #    radius to mask a shortfall with. On the print side both sigmas are in
    #    pixels and reachable from the wire, which the film side's halation
    #    scatter is not.
    ("print: two blurs in sequence in one node",
     {**NEUTRAL, "product_defaults": True, "scanner_lens_blur": 2.0, "striped": True}),
]

# What the wire cannot reach, so the probe reads them from `params.cpp` the way
# it reads the surrogate fit from `numeric.cpp`: defaults of the structs.
HALATION = {"scatter_core_um": [2.2, 2.0, 1.6], "scatter_tail_um": [9.3, 9.7, 9.1],
            "halation_first_sigma_um": [65.0, 65.0, 65.0], "halation_n_bounces": 3}
DIR_COUPLERS = {"diffusion_size_um": 20.0, "diffusion_tail_um": 200.0}
# `ScannerParams::unsharp_mask[0]`, in pixels at the full tier; the ratio is 1
# for an uncropped frame, which is every frame this probe renders.
UNSHARP_SIGMA_PX = 0.7


def fir_radius(sigma: float) -> int:
    """`gaussian_kernel_1d`'s radius, or 0 for a sigma that is not FIR."""
    if not 0.0 < sigma < 3.0:
        return 0
    return int(TRUNCATE * sigma + 0.5)


def expect_halos(long_edge: int, case: dict) -> dict[str, int]:
    """What each stage's demand must come out to, by hand, from the parameters.

    Derived the way the node bodies do it -- the pitch from the pre-crop long
    edge, each micrometre value through it, a surrogate sigma-ratio for anything
    that is an exponential tail -- and with the two composition rules that
    matter:

      * **inside a mixture, the max**: `G1 + G2 + ...` of the same input, so the
        widest component's radius covers them all;
      * **between blurs in sequence, the sum**: `G_b(G_a(x))` reaches `R_a + R_b`
        rows, and `node_halation` chains two mixtures while `node_unsharp`
        chains a blur onto `node_scanner_blur`'s.

    Nothing here reads the engine -- that is the point of it.
    """
    pitch = FILM_FORMAT_MM * 1000.0 / long_edge

    def tail_radius(um: float) -> int:
        lam = max(um / pitch, 1e-6)
        return max(fir_radius(max(lam * ratio, 1e-6)) for ratio in SURROGATE)

    lens = fir_radius(case.get("lens_blur_um", 0.0) / pitch)
    scatter = max([fir_radius(max(c / pitch, 1e-6)) for c in HALATION["scatter_core_um"]]
                  + [tail_radius(t) for t in HALATION["scatter_tail_um"]])
    bounces = max(fir_radius(max(HALATION["halation_first_sigma_um"][0] / pitch * k ** 0.5, 1e-6))
                  for k in range(1, HALATION["halation_n_bounces"] + 1))
    couplers = max(fir_radius(max(DIR_COUPLERS["diffusion_size_um"] / pitch, 1e-6)),
                   tail_radius(DIR_COUPLERS["diffusion_tail_um"]))
    # The print side's two are in pixels already.
    scanner = fir_radius(case.get("scanner_lens_blur", 0.0))
    unsharp = fir_radius(UNSHARP_SIGMA_PX)
    blurs = lens + scatter + bounces          # in sequence: sum
    scan_finish = scanner + unsharp           # in sequence: sum
    print(f"  pitch {pitch:.1f} um/px: lens R={lens}, scatter R={scatter}, "
          f"bounces R={bounces} -> film_blurs R={blurs}; dir_couplers R={couplers}; "
          f"scanner R={scanner} + unsharp R={unsharp} -> print_scan_finish R={scan_finish}")
    return {"film_blurs": blurs, "film_couplers": couplers, "print_scan_finish": scan_finish}


def segments(engine, session) -> list[dict]:
    out = ctypes.c_char_p()
    if engine._lib.spk_progress(session._handle, None, ctypes.byref(out)) != spk_ctypes.SPK_OK:
        raise spk_ctypes.EngineError(engine._last_error())
    return engine._take_json(out).get("strip_segments", [])


def digest(rgba) -> str:
    return hashlib.sha1(rgba.tobytes()).hexdigest()[:16]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dylib", type=Path, default=None)
    parser.add_argument("--height", type=int, default=180)
    parser.add_argument("--counts", type=str, default="1,2,3,8,17",
                        help="strip counts for the axis, before H")
    parser.add_argument("--case", type=int, default=None, help="run only this case (1-based)")
    args = parser.parse_args()

    h = w = args.height   # square: the pitch depends on the long edge
    img = ripple_frame(h, w)
    counts = [int(c) for c in args.counts.split(",")] + [h]
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")
    print(f"frame {w}x{h}, {len(counts)} strip counts {counts}")

    failures = 0

    def check(ok: bool, what: str, detail: str = "") -> None:
        nonlocal failures
        print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
        if not ok:
            failures += 1

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        print(f"build:  {engine.build_info}")
        for index, (label, case) in enumerate(CASES, start=1):
            if args.case and args.case != index:
                continue
            print(f"\n{index}. {label}")
            expect = expect_halos(w, case)

            with engine.open(img, dict(case)) as session:
                session.render("full")
                segs = segments(engine, session)
            by = {g["stage"]: {st["name"]: st for st in g["stages"]} for g in segs}

            want_bands = {
                "film": {"film_scale_and_expose", "film_blurs", "film_log_and_curves",
                         "film_couplers"},
                "print": {"print_spectral", "print_linear", "print_scan_finish", "print_output"},
            }
            got_bands = {g["stage"]: {st["name"] for st in g["stages"] if st["band_able"]}
                         for g in segs}
            check(got_bands == want_bands, "the band-able stages are where they should be",
                  f"{got_bands}" if got_bands != want_bands else
                  ", ".join(sorted(got_bands["film"])) + " | " + ", ".join(sorted(got_bands["print"])))

            # The halos, against the same arithmetic a different way round. The
            # film run is `film_blurs -> film_log_and_curves -> film_couplers`
            # (halos `R + 0 + R`), the print run is
            # `print_linear -> print_scan_finish -> print_output`.
            film_run = expect["film_blurs"] + expect["film_couplers"]
            checks = [("film_blurs", film_run), ("film_couplers", film_run),
                      ("print_scan_finish", expect["print_scan_finish"])]
            for name, want in checks:
                got = by["film" if name.startswith("film") else "print"][name]["halo"]
                check(got == want, f"{name}'s halo is {want}",
                      f"reported {got}" + ("" if got == want else
                      f", and a max-within-a-node build would report less"))

            # The arithmetic has to be reachable, or every hash below is decoration.
            key = "lens_blur_um" if index == 1 else "scanner_lens_blur"
            with engine.open(img, {**case, key: 0.0}) as plain:
                off = digest(plain.render("full")[0])
            with engine.open(img, dict(case)) as engaged:
                on = digest(engaged.render("full")[0])
            check(off != on, "the blur this case relies on changes the picture",
                  f"{key} 0 -> {off}, {case[key]} -> {on}")

            # §6's gate, at parameters that engage the F path.
            for kind in ("render", "reprint"):
                with engine.open(img, dict(case)) as session:
                    digests = []
                    for n in [None, *counts]:
                        if n is not None:
                            rows = max(1, (h + n - 1) // n)
                            session.set_params({"striped": True, "strip_rows": rows})
                        session.render("full")
                        rgba, _ = session.render("full", reprint=(kind == "reprint"))
                        digests.append(digest(rgba))
                want = digests[0]
                bad = [(n, d) for n, d in zip(counts, digests[1:]) if d != want]
                boundaries = (f"{len(counts) - 1} band boundaries, all interior"
                              if len(counts) > 1 else "one strip, no boundary")
                check(not bad, f"strips {kind}: {len(counts)} heights, all {want}  [{boundaries}]",
                      "; ".join(f"n={n} -> {d}" for n, d in bad))

    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
