"""Actual host Cineon view/export, using the shipped LUT as an independent oracle."""
import argparse
import hashlib
from pathlib import Path
import tempfile

import numpy as np
import tifffile
from host_smoke import Host, write_png


def lut_oracle(codes, source):
    rows = [line.split() for line in source.read_text().splitlines()
            if line and (line[0].isdigit() or line[0] in '-.')]
    table = np.array(rows, dtype=np.float32).astype(np.float16).astype(np.float64).reshape(65, 65, 65, 3)
    pos = codes.astype(np.float64) * (64 / 65535)
    low = np.floor(pos).astype(int)
    high = np.minimum(low + 1, 64)
    t = pos - low
    out = np.zeros_like(pos)
    for b in (0, 1):
        for g in (0, 1):
            for r in (0, 1):
                ix = np.where([r, g, b], high, low)
                weight = np.prod(np.where([r, g, b], t, 1-t), axis=-1)
                out += table[ix[..., 2], ix[..., 1], ix[..., 0]] * weight[..., None]
    return np.floor(np.clip(out, 0, 1) * 65535 + 0.5).astype(np.uint16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', type=Path, required=True)
    ap.add_argument('--resources', type=Path, required=True)
    args = ap.parse_args()
    host = Host([str(args.host.resolve()), '--resources', str(args.resources.resolve())])

    def call(method, params=None):
        h, payload = host.call(method, params)
        assert h['ok'], (method, h.get('error'))
        return h['result'], payload

    try:
        hello, _ = call('hello')
        assert 'export_cineon' in hello['methods'], 'Cineon file endpoint is missing (legacy export_di is density)'
        assert 'digital_intermediate' not in hello['capabilities']['backend'].get('unsupported_features', [])
        with tempfile.TemporaryDirectory(prefix='spk-cineon-host-') as temp:
            tmp = Path(temp)
            source = tmp / 'input.png'
            write_png(str(source), 96, 64)
            opened, _ = call('open', dict(path=str(source), params=dict(grain_active=False, glare_active=False)))
            sid = opened['session']
            original, _ = call('get_params', dict(session=sid))
            di_path = tmp / 'Cineon.tif'
            exported, _ = call('export_cineon', dict(session=sid, path=str(di_path)))
            assert exported['di']['encoding'] == 'cineon'
            assert exported['di']['primaries'] == 'ProPhoto RGB'
            with tifffile.TiffFile(di_path) as tif:
                assert len(tif.pages) == 2, 'raw Cineon TIFF needs the original-view preview page'
                assert tif.pages[0].dtype == np.uint16 and tif.pages[0].samplesperpixel == 3
                assert 34675 not in tif.pages[0].tags, 'Cineon codes must not carry an RGB ICC profile'
                codes = tif.pages[0].asarray()
                assert tif.pages[1].dtype == np.uint8 and 34675 in tif.pages[1].tags
                assert tif.pages[1].tags['NewSubfileType'].value == 1
                preview = tif.pages[1].asarray()
                assert tif.pages[0].tags['ExifTag'].value['ColorSpace'] == 65535
            for name in ('SpektraLab DI view, Cineon to ProPhoto RGB.cube', 'SpektraLab DI view, Cineon to Rec709.cube'):
                original_lut = args.resources / 'di' / name
                assert (tmp / name).read_bytes() == original_lut.read_bytes(), 'view LUT changed during export'
            current, _ = call('get_params', dict(session=sid))
            assert current == original, 'Cineon export mutated the canvas session'
            call('set_params', dict(session=sid, delta=dict(digital_intermediate=True)))
            rendered, payload = call('render', dict(session=sid, tier='full', format='rgba16', display='prophoto'))
            info = rendered['image']
            view = np.frombuffer(payload, '<u2').reshape(info['height'], info['width'], 4)[..., :3]
            reference = lut_oracle(codes, args.resources / 'di' / 'SpektraLab DI view, Cineon to ProPhoto RGB.cube')
            err = int(np.max(np.abs(view.astype(int)-reference.astype(int))))
            assert err <= 1, f'canvas is not raw Cineon through the shipped half-float view: max16={err}'
            assert np.max(np.abs(preview.astype(int) - np.floor(reference.astype(float) / 257 + 0.5).astype(int))) <= 1
            print(f'ok: Cineon file -> original LUT -> actual host view, max16={err}', flush=True)
            assert np.any(view != codes), 'view was silently bypassed'
            proof = tmp / 'view.tif'
            call('export_image', dict(session=sid, path=str(proof), format='tiff16', color_space='prophoto'))
            with tifffile.TiffFile(proof) as tif:
                assert 34675 in tif.pages[0].tags, 'ordinary viewed export requires its RGB profile'
                assert np.array_equal(tif.pages[0].asarray(), view), 'ordinary export and canvas used different views'
            before, _ = call('get_params', dict(session=sid))
            crop_path = tmp / 'cropped.tif'
            call('export_cineon', dict(session=sid, path=str(crop_path), geometry=dict(
                geometry_crop_x=0.25, geometry_crop_y=0, geometry_crop_w=0.5, geometry_crop_h=1,
                geometry_quarter_turns=1)))
            with tifffile.TiffFile(crop_path) as tif:
                assert tif.pages[0].shape == (48, 64, 3), tif.pages[0].shape
            after, _ = call('get_params', dict(session=sid))
            assert before == after, 'temporary DI crop leaked into the canvas'
            saved_hash = hashlib.sha256(di_path.read_bytes()).digest()
            rejected, _ = host.call('export_cineon', dict(session=sid, path=str(di_path)))
            assert not rejected['ok'], 'existing DI file overwritten without authorization'
            assert hashlib.sha256(di_path.read_bytes()).digest() == saved_hash
            # Even an error after the temporary crop must restore the session
            # and preserve the user's existing LUT instead of replacing it.
            collision = tmp / 'SpektraLab DI view, Cineon to Rec709.cube'
            collision.write_text('existing user table')
            before, _ = call('get_params', dict(session=sid))
            failed_path = tmp / 'must-not-land.tif'
            bad, _ = host.call('export_cineon', dict(session=sid, path=str(failed_path),
                                                    geometry=dict(geometry_crop_w=0.75)))
            assert not bad['ok'] and 'differs' in bad['error']['message']
            assert not failed_path.exists() and collision.read_text() == 'existing user table'
            after, _ = call('get_params', dict(session=sid))
            assert before == after, 'failed export leaked its crop into the canvas'
            call('close', dict(session=sid))
            positive, _ = call('open', dict(path=str(source), params=dict(film_stock='fujifilm_provia_100f', digital_intermediate=True,
                                                                       grain_active=False, glare_active=False)))
            bad, _ = host.call('export_cineon', dict(session=positive['session'], path=str(tmp / 'slide.tif')))
            assert not bad['ok'] and 'slide film' in bad['error']['message']
            call('render', dict(session=positive['session'], tier='full'))
            call('close', dict(session=positive['session']))
            print('ok: ordinary export, ICC distinction, crop/rotation, parameters, overwrite and slide boundaries', flush=True)
        call('shutdown')
        assert host.p.wait(timeout=20) == 0
        return 0
    finally:
        if host.p.poll() is None:
            host.p.kill()
            host.p.wait()


if __name__ == '__main__':
    raise SystemExit(main())
