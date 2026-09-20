"""RFC-020 §9 step 6, the R half: the recurrence, bit for bit, against the build it replaces.

**This step's gate is not the gate of the steps before it.** Steps 4, 5 and 6-F
left the un-striped path exactly as it was, so "bit-identical" there meant
striped == un-striped and a new/old comparison was a formality. **R changes the
shipping blur**: the IIR stopped transposing, so every render on every machine
goes through the new code with the mode off and nothing opted into. The
comparison that can fail is therefore **new engine against old engine, on the
un-striped path**, and that is this file.

What is compared, per case, per tier, for the negative and for a reprint:

    the sha1 of the whole rgba16 output, and every byte of it

Not a tolerance. `parity_render` holds the engine to the *Python* reference at
about 1e-5 because that reference is a different implementation in a different
language, and that is the right bar for it; here the two engines are supposed to
produce the same bits, so the bar is equality.

The cases are chosen to put the recurrence through its two axes and both entry
points, because that is what changed:

  * the coupler diffusion, whose 200 µm tail is IIR at every frame size the
    suite uses -- its widest surrogate sigma is `2.7684 * 200 / pitch`, so it is
    the one that is *always* over the crossover;
  * `scanner_lens_blur`, in pixels, so a sigma can be set past 3 px directly and
    the print side's horizontal pass is exercised on its own;
  * `lens_blur_um`, which reaches the film side's first blur the same way;
  * a **mixture** (`halation`), which is where the accumulate form rides: the
    fused multiply-add must land in the same pass it landed in before, and on
    the vertical/horizontal split that is an argument until it is a hash.

Usage: `python3 iir_bitexact.py --old <a dylib built from the commit being
replaced>` -- `git worktree add /tmp/x HEAD && (cd /tmp/x/engine && ./build.sh dylib)`
produces one, and the resources beside it are picked up automatically.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402
from parity_render import load_frame  # noqa: E402

NEUTRAL = {"grain_active": False, "glare_active": False, "auto_exposure": False}

CASES = [
    # The couplers' tail is IIR at any pitch this frame has: the control.
    ("defaults", {}),
    # A sigma past the crossover, set directly in pixels, on each side.
    ("scanner_blur_iir", {"scanner_lens_blur": 6.0}),
    ("lens_blur_iir", {"lens_blur_um": 200.0}),   # the wire's ceiling, ~6.9 px here
    # A mixture with IIR components and the fused accumulate.
    ("halation_mixture", {"halation_amount": 2.0}),
    # And one that straddles: the FIR channels take the whole-plane FIR path
    # inside the same call the IIR channels sweep.
    ("straddle", {"lens_blur_um": 20.0, "scanner_lens_blur": 5.0}),
    ("scan_film", {"scan_film": True}),
]


def digest(rgba) -> str:
    return hashlib.sha1(rgba.tobytes()).hexdigest()


def renders(engine, img, delta: dict):
    """(negative, reprint) at both tiers, as bytes."""
    out = {}
    with engine.open(img, {**NEUTRAL, **delta}) as session:
        for tier in ("live", "full"):
            session.render(tier)
            out[f"{tier}/render"] = session.render(tier)[0].tobytes()
            out[f"{tier}/reprint"] = session.render(tier, reprint=True)[0].tobytes()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", type=Path, required=True,
                    help="the dylib built from the commit this change replaces")
    ap.add_argument("--new", type=Path, default=None, help="defaults to build/")
    ap.add_argument("--size", type=int, default=None)
    ap.add_argument("--case", action="append")
    args = ap.parse_args()

    img = load_frame(args.size)
    print(f"frame {img.shape[1]}x{img.shape[0]} ({img.shape[0] * img.shape[1] / 1e6:.2f} MP)")
    print(f"old: {args.old}")
    print(f"new: {args.new or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}\n")

    # **A dylib and a metallib are a pair.** The kernels live in
    # `resources/spektrafilm.metallib` and the dylib dispatches them by name, so
    # an old dylib against a new metallib is not a comparison, it is a crash:
    # the first run of this file died on `no kernel 'spk_transpose3'`, which is
    # the *right* error and a more honest one than a mismatched picture would
    # have been. Each engine is therefore given the resources beside its own
    # build directory.
    new_path = args.new or spk_ctypes.ENGINE / "build" / "libspektrafilm_engine.dylib"
    failures = 0
    with spk_ctypes.Engine(dylib=args.old,
                           resources=args.old.parent.parent / "resources") as old, \
            spk_ctypes.Engine(dylib=new_path,
                              resources=new_path.parent.parent / "resources") as new:
        if old.build_info == new.build_info:
            print("FAIL  the two engines report the same build info; this is comparing a "
                  "build with itself and would pass whatever it did")
            failures += 1
        for name, delta in CASES:
            if args.case and name not in args.case:
                continue
            a = renders(old, img, delta)
            b = renders(new, img, delta)
            bad = [(k, hashlib.sha1(a[k]).hexdigest()[:16], hashlib.sha1(b[k]).hexdigest()[:16])
                   for k in a if a[k] != b[k]]
            if bad:
                failures += 1
                print(f"FAIL  {name}: {len(bad)} of {len(a)} renders differ")
                for k, x, y in bad:
                    print(f"        {k}: old {x} new {y}")
            else:
                print(f"ok    {name}: {len(a)} renders, all byte-identical "
                      f"({hashlib.sha1(a['full/render']).hexdigest()[:16]})")

    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
