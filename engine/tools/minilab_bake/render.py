#!/usr/bin/env python3
"""Engine renders used by the gates, plus the small image helpers.

Everything goes through `v2/eng2.py`, which runs the oracle in a *fresh child
process* per render (the research hooks are environment-driven, so a clean
process per hook configuration is the only honest way to use them).
"""
import numpy as np

# `negs.S/G/PITCH` are the chart tile geometry the research negatives use.
def _chart_geometry(n, cols):
    import negs
    S, G = negs.S, negs.G
    pitch = S + G
    rows = int(np.ceil(n / cols))
    return S, G, pitch, rows, rows * pitch + G, cols * pitch + G


def chart_image(film, spds, cols):
    """The engine input for a reflectance set at this film's ground-truth exposure.

    Same construction as `negs.neg_for_spectra` / `negs.engine_chart`: true film
    exposures times the film's own anchor, on the 96 px patch grid.
    """
    import chartlib as cl
    import e2lib as L
    import filmlib as fl

    spds = np.asarray(spds, float)
    S, G, pitch, rows, H, W = _chart_geometry(len(spds), cols)
    pos = [(G + (i // cols) * pitch, G + (i % cols) * pitch) for i in range(len(spds))]
    weights = fl.weights(film, True)
    anchor = np.load("study/out/e3/tables_%s.npz" % film)["anchor_C0"]
    vals = (spds @ weights) * 2.0 ** anchor
    bg = (L.D55 * cl.BG) @ weights * 2.0 ** anchor
    return cl.chart(vals, bg, pos=pos, S=S, H=H, W=W), pos, S


def patch_medians(out16, pos, S):
    q = S // 4
    return np.array([
        np.median(out16[y + q:y + S - q, x + q:x + S - q, :3].astype(float), axis=(0, 1))
        for y, x in pos]) / 65535.0


def render_chart(film, paper, spds, cols, env=None, di=False, extra_params=None):
    """-> (rgba16, patch medians in [0,1], pos, stderr). Chart taps true exposures."""
    import eng2
    import negs

    img, pos, S = chart_image(film, spds, cols)
    params = dict(eng2.BASE, film_stock=film, print_stock=paper, auto_exposure=False,
                  exposure_compensation_ev=negs.film_ev(film))
    params.update(extra_params or {})
    e = dict(env or {})
    e.setdefault("SPK_RESEARCH_RAW_PASSTHROUGH", 1)
    out, _, err = eng2.render(img, params, env=e, di=di)
    return out, patch_medians(out, pos, S), pos, err


def render_nef(film, paper, image, env=None, di=False, auto=True, extra_params=None):
    import eng2

    params = dict(eng2.BASE, film_stock=film, print_stock=paper, auto_exposure=auto)
    params.update(extra_params or {})
    out, _, err = eng2.render(image, params, env=dict(env or {}), di=di)
    return out, err


def load_apple(ctx):
    return np.load(ctx.work / "inputs" / "apple_2048.npy")


# --------------------------------------------------------------------------
# display


def display_srgb(rgba16):
    """sRGB-encoded uint8 from a 16-bit sRGB-output render."""
    import common as c
    lin = c.srgb_decode(rgba16[..., :3].astype(np.float64) / 65535.0)
    return (np.clip(c.srgb_encode(lin), 0, 1) * 255 + 0.5).astype(np.uint8)


def display_di(rgba16):
    """A Cineon-encoded DI render, decoded to linear and re-encoded for viewing."""
    import common as c
    import dilib as D
    lin = D.cineon_decode(rgba16[..., :3].astype(np.float64) / 65535.0)
    return (np.clip(c.srgb_encode(lin), 0, 1) * 255 + 0.5).astype(np.uint8)


def save_jpeg(path, rgb):
    from PIL import Image
    Image.fromarray(rgb).save(path, quality=90, optimize=True)
