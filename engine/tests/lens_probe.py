"""The lens stage alone (API-SPEC §21.5-§21.6), through `spk_lens_probe` in the dylib.

`spk_lens_probe` (engine/src/pipeline/lens.cpp, not in a hardened build) runs
`film_lens`'s two nodes -- the diffusion filter, then the aberrations -- on a
linear float32 RGB image the caller hands it, as the film's raw exposure, at a
given pitch, whole or in bands cut as `render_banded` cuts them. That is what
lets `lens_checks.py` and `diffusion_checks.py` measure a PSF in linear light,
which the full render (a tone curve, a print, an encode) does not show.

Also here: the oracle (`spektrafilm/model/diffusion.py`, loaded from the
upstream checkout with its two heavy imports stubbed: nothing the checks call
uses them) and a PNG writer with no PIL.
"""
import ctypes, importlib.util, json, os, struct, sys, types, zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent
# The upstream reference tree (spektrafilm's checkout), by SPEKTRALAB_REFERENCE_ROOT; without it the oracle cases skip.
UPSTREAM = Path(os.environ.get("SPEKTRALAB_REFERENCE_ROOT", "")) / "src/spektrafilm/model/diffusion.py"

_lib = None


def lib(dylib: Path | None = None):
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL(str(dylib or ENGINE / "build" / "libspektralab_engine.dylib"))
        f = _lib.spk_lens_probe
        f.restype = ctypes.c_int
        f.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_float),
                      ctypes.c_uint32, ctypes.c_uint32, ctypes.c_double, ctypes.POINTER(ctypes.c_float),
                      ctypes.c_char_p, ctypes.c_size_t]
    return _lib


def psf(params: dict) -> dict:
    """The diffusion filter's host tables for a wire delta: {p_s, exps: [[lambda_um, wr, wg, wb, group]]}."""
    f = lib().spk_diffusion_psf_json
    f.restype = ctypes.c_int
    f.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
    buf = ctypes.create_string_buffer(16384)
    if f(json.dumps(params).encode(), buf, len(buf)) != 0:
        raise RuntimeError("spk_diffusion_psf_json failed")
    return json.loads(buf.value.decode())


LAST = {}   # the last run's report: the pyramid's levels, its fit's rms, the pass's ms


def run(img: np.ndarray, params: dict, pixel_um: float, exact: bool = False, repeat: int = 1,
        chunk_rows: int = 0) -> np.ndarray:
    """The lens pass (`Pipeline::lens_source`) on `img` (H, W, 3) float32 linear
    at `pixel_um` per px; returns the same shape. `exact`: the filter by the
    exact path (the reference). `repeat`: run it n times, `LAST["ms"]` the
    fastest. `chunk_rows`: the rows the pass's chunks take (0: its own 512)."""
    a = np.ascontiguousarray(img, dtype=np.float32)
    h, w = a.shape[:2]
    out = np.empty_like(a)
    err = ctypes.create_string_buffer(512)
    opts = {"exact": 1 if exact else 0, "repeat": int(repeat), "chunk_rows": int(chunk_rows)}
    rc = lib().spk_lens_probe(str(ENGINE / "resources" / "spektralab.metallib").encode(),
                              json.dumps(params).encode(), json.dumps(opts).encode(),
                              a.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), h, w, float(pixel_um),
                              out.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), err, len(err))
    if rc != 0:
        raise RuntimeError(err.value.decode())
    LAST.clear()
    LAST.update(json.loads(err.value.decode()))
    return out


def _cell_kernel(lam, R, ss=9, inner=3, ss_in=96):
    """A 2-D exponential e^(-r/lam) / (2 pi lam^2) over each pixel cell of a
    (2R+1)^2 grid: supersampled ss x ss, the inner cells ss_in x ss_in."""
    ax = (np.arange(ss) + 0.5) / ss - 0.5
    off = np.arange(-R, R + 1)
    xs = (off[:, None] + ax[None, :]).ravel()
    K = np.zeros((2 * R + 1, 2 * R + 1))
    for i in range(2 * R + 1):
        r = np.sqrt(xs[None, :] ** 2 + (off[i] + ax)[:, None] ** 2)
        K[i] = np.exp(-r / lam).reshape(ss, 2 * R + 1, ss).mean(axis=(0, 2)) / (2 * np.pi * lam ** 2)
    a2 = (np.arange(ss_in) + 0.5) / ss_in - 0.5
    for dy in range(-inner, inner + 1):
        for dx in range(-inner, inner + 1):
            yy, xx = dy + a2[:, None], dx + a2[None, :]
            K[dy + R, dx + R] = np.exp(-np.sqrt(xx ** 2 + yy ** 2) / lam).mean() / (2 * np.pi * lam ** 2)
    return K


def cell_truth(img: np.ndarray, params: dict, pixel_um: float) -> np.ndarray:
    """The filter's continuous model, resolved: (1 - p_s) E + p_s K * E with K
    the PSF (the native host tables, `psf`) integrated over each pixel's cell,
    to 10 lambda_max, by FFT with replicated edges (the native edge rule). The
    oracle samples the PSF at pixel centres and renormalises, which at a fine
    pitch moves a sub-pixel core's weight (the oracle's own error, up to ~900
    codes); this is the reference the fast path is fitted to."""
    ps = psf(params)
    lams = [e[0] / pixel_um for e in ps["exps"]]
    R = min(int(np.ceil(max(10 * max(lams), 8))), min(img.shape[:2]) // 2 - 1)
    cells = [_cell_kernel(l, R) for l in lams]
    out = np.empty(img.shape, np.float64)
    for c in range(3):
        K = sum(e[1 + c] * k for e, k in zip(ps["exps"], cells))
        pad = np.pad(img[..., c].astype(np.float64), ((R, R), (R, R)), mode="edge")
        s0, s1 = pad.shape[0] + K.shape[0] - 1, pad.shape[1] + K.shape[1] - 1
        full = np.fft.irfft2(np.fft.rfft2(pad, (s0, s1)) * np.fft.rfft2(K, (s0, s1)), (s0, s1))
        out[..., c] = (1 - ps["p_s"]) * img[..., c] + ps["p_s"] * full[2 * R:2 * R + img.shape[0], 2 * R:2 * R + img.shape[1]]
    return out


def oracle():
    """`spektrafilm.model.diffusion`, the upstream file itself. Its module
    imports scipy and three spektrafilm utilities; the checks call only the
    tables, the profile, the PSF and `apply_diffusion_filter_um`, which need
    numpy and `scipy.signal.fftconvolve` -- given here by numpy's FFT."""
    if not UPSTREAM.is_file():
        return None
    def fftconvolve(a, k, mode="same"):
        s0, s1 = a.shape[0] + k.shape[0] - 1, a.shape[1] + k.shape[1] - 1
        full = np.fft.irfft2(np.fft.rfft2(a, (s0, s1)) * np.fft.rfft2(k, (s0, s1)), (s0, s1))
        o0, o1 = (k.shape[0] - 1) // 2, (k.shape[1] - 1) // 2
        return full[o0:o0 + a.shape[0], o1:o1 + a.shape[1]]
    stubs = {
        "scipy": {}, "scipy.ndimage": {}, "scipy.signal": {"fftconvolve": fftconvolve},
        "spektrafilm": {}, "spektrafilm.utils": {},
        "spektrafilm.utils.fast_gaussian_filter": {"fast_exponential_filter": None, "fast_gaussian_filter": None},
        "spektrafilm.utils.numba_boost_hightlights": {"boost_highlights": None},
        "spektrafilm.utils.precision": {"float_dtype": None},
    }
    saved = {k: sys.modules.get(k) for k in stubs}
    try:
        for name, attrs in stubs.items():
            if name.startswith("scipy"):
                try:
                    __import__(name)
                    continue   # a real scipy: use it
                except ImportError:
                    pass
            m = types.ModuleType(name); m.__dict__.update(attrs); sys.modules[name] = m
        sys.modules["scipy"].ndimage = sys.modules["scipy.ndimage"]
        sys.modules["scipy"].signal = sys.modules["scipy.signal"]
        spec = importlib.util.spec_from_file_location("upstream_diffusion", UPSTREAM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        for k, v in saved.items():
            if v is None: sys.modules.pop(k, None)
            else: sys.modules[k] = v


def write_png(path, rgb: np.ndarray):
    """8-bit RGB PNG, by hand (zlib)."""
    a = np.ascontiguousarray(np.clip(rgb, 0, 255).astype(np.uint8))
    h, w = a.shape[:2]
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def display(lin: np.ndarray, exposure=1.0) -> np.ndarray:
    """Linear light to 8-bit, a plain sRGB-ish tone (x / (1 + x), gamma 2.2), for looking."""
    x = np.maximum(lin * exposure, 0)
    return 255.0 * (x / (1.0 + x)) ** (1 / 2.2) * 1.0
