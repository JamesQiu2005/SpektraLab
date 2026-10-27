"""Independent EXIF fixtures -> actual host metadata -> written-file roundtrip."""
import argparse
from pathlib import Path
import tempfile

from PIL import Image, TiffImagePlugin
import tifffile
from host_smoke import Host


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', type=Path, required=True)
    ap.add_argument('--resources', type=Path, required=True)
    ap.add_argument('--raw', type=Path)
    args = ap.parse_args()
    h = Host([str(args.host.resolve()), '--resources', str(args.resources.resolve())])

    def call(method, params, payload=b''):
        result, _ = h.call(method, params, payload)
        assert result['ok'], (method, result.get('error'))
        return result['result']

    def verify(metadata):
        assert metadata['datetime_original'].startswith('2026-10-01T')
        assert metadata['exposure_program'] == 3
        assert metadata['focal_35mm'] == 24
        assert abs(metadata['exposure_bias_ev'] + 1/3) < 1e-4

    try:
        with tempfile.TemporaryDirectory(prefix='spk-imprint-exif-') as tmp:
            tmp = Path(tmp)
            exif = Image.Exif()
            exif[0x010F] = 'Independent EXIF fixture'
            exif[0x8769] = {0x9003: '2026:10:01 23:58:00', 0x8822: 3, 0xA405: 24,
                0x9204: TiffImagePlugin.IFDRational(-1, 3), 0x829A: TiffImagePlugin.IFDRational(1, 250),
                0x829D: TiffImagePlugin.IFDRational(56, 10), 0x8827: 800}
            exif_bytes = exif.tobytes()
            for ext in ('jpg', 'png', 'tif'):
                source = tmp / ('source.'+ext)
                Image.new('RGB', (16, 12), (123, 145, 167)).save(source, exif=exif_bytes)
                verify(call('probe', {'path': str(source)})['metadata'])
                for fmt, target_ext in [('jpeg', 'jpg'), ('png', 'png'), ('tiff16', 'tif')]:
                    path = tmp / ('copied-'+ext+'.'+target_ext)
                    pixel = bytes([0, 64, 0, 128, 0, 192, 255, 255]) * (16*12)
                    call('write_image', {'path': str(path), 'source_path': str(source), 'width': 16, 'height': 12,
                                        'format': fmt, 'color_space': 'srgb'}, pixel)
                    verify(call('probe', {'path': str(path)})['metadata'])
            if args.raw:
                # TIFF-family RAWs carry these original EXIF values; LibRaw's
                # generic shooting info alone does not expose camera bias.
                with tifffile.TiffFile(args.raw) as image:
                    source_exif = image.pages[0].tags[34665].value
                metadata = call('probe', {'path': str(args.raw)})['metadata']
                for tag, key in [('ExposureProgram', 'exposure_program'), ('ExposureBiasValue', 'exposure_bias_ev'), ('FocalLengthIn35mmFilm', 'focal_35mm')]:
                    value = source_exif.get(tag)
                    if isinstance(value, tuple):
                        value = value[0] / value[1]
                    if value is not None and (key != 'focal_35mm' or value > 0):
                        assert key in metadata and abs(metadata[key]-float(value)) < 1e-5, (key, metadata)
                print('ok: actual RAW EXIF program/bias/35mm fields match source tags', flush=True)
        call('shutdown', {})
        assert h.p.wait(timeout=20) == 0
        print('ok: JPEG/PNG/TIFF EXIF and all 9 written-file roundtrips', flush=True)
        return 0
    finally:
        if h.p.poll() is None:
            h.p.kill()
            h.p.wait()


if __name__ == '__main__':
    raise SystemExit(main())
