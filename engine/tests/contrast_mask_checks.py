"""RFC-024 integration: real GPU mask, independent host oracle and band seams.

The pointwise CTest checks each shader against double precision separately.
This check pins the original truncated Gaussian boundary rule, calibration,
negative cache, zero/off identity, and stripe origin through the public ABI.
It uses synthetic linear-light input, never a user's photograph or settings.
"""
import argparse
import os
from pathlib import Path
import tempfile

import numpy as np
import spk_ctypes as spk


def gaussian_matrix(length, sigma):
    d = np.arange(length)[:, None] - np.arange(length)[None, :]
    weights = np.where(np.abs(d) <= np.ceil(4 * sigma), np.exp(-0.5 * (d / sigma) ** 2), 0)
    return weights / weights.sum(axis=1, keepdims=True)


def curve(base, highlights, shadows, core):
    out = np.zeros_like(base, dtype=np.float64)
    for selected, amount, distance, sign in (
        (base < -core, highlights, -core - base, 1),
        (base > core, shadows, base - core, -1),
    ):
        if amount <= 0:
            continue
        delta = amount * 6 / np.sqrt(36 - amount * amount)
        t = max(4 - delta, 1e-3)
        room = np.float32(4 * t / np.sqrt(16 - t * t)).item()
        d = distance[selected]
        out[selected] = sign * (d - d * room / np.sqrt(room * room + d * d))
    return out * 6 / np.sqrt(36 + out * out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dylib', type=Path, required=True)
    args = parser.parse_args()
    for key in ('SPEKTRAFILM_MASK_GUIDED', 'SPEKTRAFILM_MASK_POINTWISE', 'SPEKTRAFILM_MASK_DUMP'):
        if key in os.environ:
            raise RuntimeError(f'run with {key} unset; research modes would change this test')
    h, w = 93, 577
    y, x = np.mgrid[0:h, 0:w]
    ev = -9 + 16 * x / (w - 1) + 0.7 * np.sin(y * 0.19)
    image = (0.18 * np.exp2(ev)[..., None] * np.array([0.7, 1, 1.3])).astype('float32')
    base = dict(film_stock='kodak_portra_400', print_stock='kodak_supra_endura',
                grain_active=False, glare_active=False, auto_exposure=False)
    failures = 0

    def check(ok, label, detail=''):
        nonlocal failures
        print(f'{"ok" if ok else "FAIL"}: {label} {detail}', flush=True)
        failures += not ok

    with tempfile.TemporaryDirectory(prefix='spk-mask-check-') as tmp, spk.Engine(dylib=args.dylib) as engine:
        with engine.open(image, base) as session:
            bare, _ = session.render('full')
            session.set_params(dict(contrast_mask_active=True, contrast_mask_highlights=0, contrast_mask_shadows=0))
            zero, _ = session.render('full')
            check(np.array_equal(bare, zero), 'zero amount preserves exact unmasked output')
            check(session.contrast_mask_field('full').size == 0, 'zero amount has no active field')
            reference = None
            for scale in (0.002, 0.03, 0.12):
                session.set_params(dict(contrast_mask_highlights=2, contrast_mask_shadows=1.5,
                                        contrast_mask_core=0.5, contrast_mask_scale=scale))
                dump = Path(tmp) / 'analysis.bin'
                os.environ['SPEKTRAFILM_MASK_DUMP'] = str(dump)
                try:
                    field = session.contrast_mask_field('full')
                finally:
                    del os.environ['SPEKTRAFILM_MASK_DUMP']
                with dump.open('rb') as stream:
                    gw, gh = np.fromfile(stream, dtype='<u4', count=2)
                    exposure, blurred, delta = np.fromfile(stream, dtype='<f4').reshape(3, gh, gw)
                wanted = max(512, int(np.ceil(4 / scale)))
                cells = min(wanted, max(h, w))
                sigma = max(0.5, scale * cells)
                expected = gaussian_matrix(int(gh), sigma) @ exposure.astype('float64') @ gaussian_matrix(int(gw), sigma).T
                error = float(np.max(np.abs(expected - blurred)))
                check(error < 2e-6, f'Gaussian boundaries scale={scale}', f'max_abs={error:.3g}')
                error = float(np.max(np.abs(curve(expected, 2, 1.5, 0.5) - delta)))
                check(error < 2e-6, f'bounded gain scale={scale}', f'max_abs={error:.3g}')
                check(np.array_equal(field, delta) and np.isfinite(field).all() and np.max(np.abs(field)) < 6,
                      f'public field matches diagnostic scale={scale}')
                before = session.get_params()
                masked, result = session.render('full', reprint=True)
                check(bool(result.negative_was_cached), f'print edit reuses actual negative scale={scale}')
                check(np.any(masked != bare), f'nonzero mask changes actual print scale={scale}')
                session.contrast_mask_field('full')
                again, _ = session.render('full', reprint=True)
                check(np.array_equal(masked, again) and before == session.get_params(),
                      f'field read preserves render/cache/parameters scale={scale}')
                if scale == 0.03:
                    reference = masked
            session.set_params(dict(contrast_mask_active=False))
            restored, _ = session.render('full', reprint=True)
            check(np.array_equal(bare, restored), 'off toggle recovers exact unmasked output')
        for rows in (1, 7, 41):
            params = dict(base, striped=True, strip_rows=rows, contrast_mask_active=True,
                          contrast_mask_highlights=2, contrast_mask_shadows=1.5,
                          contrast_mask_core=0.5, contrast_mask_scale=0.03)
            with engine.open(image, params) as session:
                striped, _ = session.render('full')
                check(np.array_equal(reference, striped), f'whole frame == stripe rows={rows}',
                      f'max_channel={np.abs(reference.astype(int)-striped.astype(int)).max()}')
        for mode in (dict(scan_film=True), dict(digital_intermediate=True), dict(print_stock='fujifilm_provia_100f')):
            with engine.open(image, dict(base, contrast_mask_active=True, contrast_mask_highlights=2, **mode)) as session:
                session.render('full')
                check(session.contrast_mask_field('full').size == 0, f'non-paper path excludes mask {mode}')
        for amount in (0.25, 1, 2, 3):
            check(abs(curve(np.array([-5., 5.]), amount, amount, 1)[0] - amount) < 2e-6,
                  f'original amount calibration at four stops past knee: {amount}')
    print(f'{failures} failure(s)')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
