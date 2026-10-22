#!/usr/bin/env python3
"""Prefilm held crop, full canvas metadata, original isolation and cache tests."""
import argparse
from pathlib import Path
import struct
import tempfile
import zlib

from host_smoke import Host
from host_proof import good


def png(path, pixels):
    h, w = len(pixels), len(pixels[0])
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + bytes(v for p in row for v in p) for row in pixels)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w,h,8,2,0,0,0)) +
                     chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def exercise(host, folder):
    pixels = [[(40+x, 30+y, 20+(x+y)//2) for x in range(192)] for y in range(128)]
    original = folder / 'source.png'
    png(original, pixels)
    crop = [row[48:144] for row in pixels[32:96]]
    # Clockwise turn then horizontal flip, independently of engine geometry.
    turned = [list(reversed(row)) for row in zip(*crop[::-1])]
    physical = folder / 'physical-cut.png'
    png(physical, turned)
    quiet = {'auto_exposure':False,'grain_active':False,'glare_active':False,'halation_active':False,
             'date_imprint_active':True,'date_imprint_text':'26 10 18','date_imprint_corner':'br'}
    opened, _ = good(host, 'open', {'path':str(original),'params':quiet})
    sid = opened['session']
    v = {'session':sid,'tier':'full','display':'srgb','generation':1}
    source = {'session':sid,'display':'srgb','long_edge':512}
    _, before = good(host, 'render_source', source)
    base, narrow = good(host, 'render_view', v)
    hello, _ = good(host, 'hello')
    assert hello['view_formats'] == ['rgba8', 'rgba16']
    wide, codes = good(host, 'render_view', {**v,'format':'rgba16'})
    assert wide['image']['format'] == 'rgba16' and wide['image']['row_bytes'] == 192 * 8
    values = [v for (v,) in struct.iter_unpack('<H', codes)]
    assert bytes((v * 255 + 32767) // 65535 for v in values) == narrow
    assert any(v % 257 for v in values), 'preview transport already truncated to eight bits'
    geometry = {'crop':{'x':.25,'y':.25,'width':.5,'height':.5}, 'quarterTurns':1,'flipH':True}
    for overscan in (False, True):
        params = {**quiet,'overscan_active':overscan,'overscan_format':'135','overscan_frame_seed':1234}
        result, actual = good(host, 'render_view', {**v,'params':params,'source_geometry':geometry})
        repeated, same = good(host, 'render_view', {**v,'params':params,'source_geometry':geometry})
        assert repeated['print_cached'] and actual == same, 'identical held crop regenerated the film'
        ref, _ = good(host, 'open', {'path':str(physical),'params':params})
        ref_view = {**v,'session':ref['session']}
        expected, wanted = good(host, 'render_view', ref_view)
        assert actual == wanted, f'prefilm physical crop differs from independently cropped input, overscan={overscan}'
        assert result['image']['source_width'] == expected['image']['width']
        assert result['image']['source_height'] == expected['image']['height']
        small, _ = good(host, 'render_view', {**v,'tier':'live','long_edge':31})
        assert small['image']['source_width'] == expected['image']['width']
        assert small['image']['source_height'] == expected['image']['height']
        _, intact = good(host, 'render_source', source)
        assert intact == before, 'held crop changed decoded original'
        good(host, 'close', {'session':ref['session']})
    # Atomic validation: malformed geometry cannot partially change film params.
    old, _ = good(host, 'get_params', {'session':sid})
    failed, data = host.call('render_view', {**v,'params':{'print_exposure':2},'source_geometry':{'quarterTurns':1.5}})
    assert not failed['ok'] and not data
    now, _ = good(host, 'get_params', {'session':sid})
    assert old == now
    cleared, _ = good(host, 'render_view', {**v,'params':{**quiet,'overscan_active':False},'source_geometry':{}})
    assert (cleared['image']['width'],cleared['image']['height']) == (192,128)
    good(host, 'close', {'session':sid})
    print('film edge host: independent physical crop parity, date/overscan, turns/flips, cache reuse, full canvas metadata, original isolation, atomic invalid input and reset passed', flush=True)


def main():
    p = argparse.ArgumentParser();p.add_argument('--host',required=True);p.add_argument('--resources',required=True)
    a=p.parse_args();host=Host([a.host,'--resources',a.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spektralab-film-edge-') as directory:
            exercise(host,Path(directory))
    finally:
        if host.p.poll() is None:
            good(host,'shutdown');host.p.wait(timeout=20)


if __name__ == '__main__':
    main()
