#!/usr/bin/env python3
"""Cineon export: actual two-page TIFF, frozen edits, editor/cache lifetime."""
import argparse
from pathlib import Path
import struct
import tempfile

from host_smoke import Host, write_png
from host_proof import good


def directory(data, at):
    count = struct.unpack_from('<H', data, at)[0]
    entries = {}
    for i in range(count):
        tag, kind, n, value = struct.unpack_from('<HHII', data, at + 2 + i * 12)
        entries[tag] = (kind, n, value)
    return entries, struct.unpack_from('<I', data, at + 2 + count * 12)[0]


def pixels(data, fields):
    offsets, counts = fields[273], fields[279]
    def longs(field):
        return [field[2]] if field[1] == 1 else struct.unpack_from('<' + 'I' * field[1], data, field[2])
    return b''.join(data[o:o + n] for o, n in zip(longs(offsets), longs(counts)))


def exercise(host, root, resources):
    source = root / '输入.png'
    write_png(str(source), 97, 65)
    hello, _ = good(host, 'hello')
    assert 'export_cineon' in hello['methods']
    params = dict(grain_active=False, halation_active=False, glare_active=False, auto_exposure=False)
    opened, _ = good(host, 'open', dict(path=str(source), params=params))
    sid = opened['session']
    view = dict(session=sid, tier='full', display='srgb')
    _, before = good(host, 'render_view', view)
    request = dict(session=sid, params=params, geometry=dict(quarterTurns=1),
                   adjustments=dict(exposure=5, saturation=100), long_edge=3, color_space='rec2020')
    first = root / '数字中间片.tif'
    reply, payload = good(host, 'export_cineon', dict(request, path=str(first)))
    assert not payload and (reply['width'], reply['height']) == (65, 97)
    assert reply['encoding'] == 'cineon' and reply['color_space'] == 'untagged Cineon'
    data = first.read_bytes()
    a, next_ifd = directory(data, struct.unpack_from('<I', data, 4)[0])
    b, last = directory(data, next_ifd)
    assert not last and 34675 not in a and 34675 in b and b[254][2] == 1
    exif, _ = directory(data, a[34665][2])
    assert exif[0xA001][2] == 65535
    assert a[258][1] == 3 and struct.unpack_from('<3H', data, a[258][2]) == (16, 16, 16)
    for name in ['SpektraLab DI view, Cineon to ProPhoto RGB.cube', 'SpektraLab DI view, Cineon to Rec709.cube']:
        assert (root / name).read_bytes() == (resources / 'DI' / name).read_bytes()
    second = root / 'neutral.tif'
    good(host, 'export_cineon', dict(request, adjustments={}, path=str(second)))
    neutral = second.read_bytes()
    fields, _ = directory(neutral, struct.unpack_from('<I', neutral, 4)[0])
    assert pixels(data, a) == pixels(neutral, fields), 'Post-Dev leaked into Cineon codes'
    proof, rgba = good(host, 'render_proof', dict(request, format='di', proof_long_edge=1024, display='srgb', generation=6))
    assert proof['encoding'] == 'cineon' and proof['generation'] == 6
    assert (proof['file_width'], proof['file_height']) == (65, 97)
    assert pixels(data, b) == bytes(v for i, v in enumerate(rgba) if i % 4 != 3), 'TIFF view and DI proof differ'
    _, after = good(host, 'render_view', view)
    assert after == before, 'DI export/proof changed the editor'
    rejected, payload = host.call('export_cineon', dict(request, path=str(first)))
    assert not rejected.get('ok') and not payload and first.read_bytes() == data
    good(host, 'cancel', dict(session=sid, progress_id='cancel-di'))
    cancelled = root / 'cancel.tif'
    rejected, _ = host.call('export_cineon', dict(request, path=str(cancelled), progress_id='cancel-di'))
    assert not rejected.get('ok') and not cancelled.exists()
    bad = root / 'missing' / 'file.tif'
    rejected, _ = host.call('export_cineon', dict(request, path=str(bad)))
    assert not rejected.get('ok') and not bad.exists()
    compressed = root / 'cineon-lzw.tif'
    _, payload = good(host, 'export_cineon', dict(request, path=str(compressed), tiff_compression='lzw'))
    assert not payload
    packed = compressed.read_bytes()
    fields, nxt = directory(packed, struct.unpack_from('<I', packed, 4)[0])
    assert fields[259][2] == 5 and 34675 not in fields and nxt % 2 == 0
    fields, nxt = directory(packed, nxt)
    assert fields[259][2] == 5 and 34675 in fields and not nxt
    good(host, 'close', dict(session=sid))
    print('Cineon host: exact LUT assets, untagged 16-bit codes, EXIF uncalibrated, second-page/proof equality, no Post-Dev, geometry, unchanged editor, overwrite/cancel/disk failure passed', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--resources', required=True)
    args = parser.parse_args()
    host = Host([args.host, '--resources', args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spektralab-cineon-') as root:
            exercise(host, Path(root), Path(args.resources))
    finally:
        if host.p.poll() is None:
            good(host, 'shutdown')
            host.p.wait(timeout=20)


if __name__ == '__main__':
    main()
