#!/usr/bin/env python3
"""Actual host half-frame source/layer/export integration, owned PNG fixtures."""
import argparse
from copy import deepcopy
from pathlib import Path
import json
import struct
import tempfile
from host_smoke import Host, write_png
from host_proof import good, tiff_pixels


def exercise(host, root):
    left, right = root / 'left.png', root / 'right.png'
    write_png(str(left), 96, 64); write_png(str(right), 80, 120)
    def hole(path):
        return {'path': str(path), 'decode': {'whiteBalance': 'As Shot', 'lensCorrection': False},
                'geometry': {}, 'placement': {}, 'autoExposure': False, 'exposureEV': 0}
    pair = {'schemaVersion': 1, 'folder': str(root), 'spacingMM': 1, 'turned': False,
            'left': hole(left), 'right': hole(right), 'printEffects': True}
    path = root / 'owned.spektrapair'; path.write_text(json.dumps(pair))
    params = {'auto_exposure': False, 'grain_active': True, 'halation_active': False,
              'glare_active': False, 'overscan_active': False, 'date_imprint_active': False,
              'film_format_mm': 37, 'overscan_pair': True, 'overscan_format': '135_half'}
    hello, _ = good(host, 'hello'); assert {'open_pair', 'update_pair'} <= set(hello['methods'])
    probed, _ = good(host, 'probe', {'path': str(path)})
    assert (probed['width'], probed['height']) == (99, 64) and probed['kind'] == 'pair'
    thumb, payload = good(host, 'thumbnail', {'path': str(path), 'long_edge': 64})
    assert thumb['source'] == 'pair-previews' and len(payload) == thumb['image']['width'] * thumb['image']['height'] * 4
    opened, _ = good(host, 'open_pair', {'path': str(path), 'pair': pair, 'params': params})
    sid = opened['session']; assert (opened['width'], opened['height']) == (99, 64)
    assert opened['pair_info']['left']['available'] and opened['pair_info']['right']['available']
    view = {'session': sid, 'tier': 'full', 'display': 'srgb', 'generation': 1}
    first, original = good(host, 'render_view', view)
    assert len(first['pair_info']['gates']) == 2
    _, original16 = good(host, 'render_view', dict(view, format='rgba16'))
    assert len(original16) == 99 * 64 * 8
    reduced = bytes((v * 255 + 32767) // 65535 for (v,) in struct.iter_unpack('<H', original16))
    assert max(abs(a-b) for a,b in zip(reduced,original)) <= 1
    layer = deepcopy(pair); layer['right']['adjustments'] = {'exposure': .5}
    updated, _ = good(host, 'update_pair', {'session': sid, 'pair': layer, 'params': params})
    assert updated['session'] == sid
    changed, graded = good(host, 'render_view', view)
    assert changed['print_cached'] and graded != original
    for y in range(64):
        assert graded[y*99*4:(y*99+49)*4] == original[y*99*4:(y*99+49)*4], 'per-hole grade changed first hole/gap'
    good(host, 'update_pair', {'session': sid, 'pair': pair, 'params': params})
    _, restored = good(host, 'render_view', view); assert restored == original, 'pair edit regenerated grain'
    solved, _ = good(host, 'solve', {'session': sid, 'target': 'both'})
    assert 'exposure_compensation_ev' not in solved['solved_params'], 'pair globally metered its gap'
    target = root / 'pair.tif'
    export = {'session': sid, 'source_path': str(path), 'pair': layer, 'params': params,
              'adjustments': {}, 'geometry': {}, 'color_space': 'srgb', 'format': 'tiff8', 'path': str(target)}
    written, payload = good(host, 'export_frame', export)
    assert not payload and (written['width'], written['height']) == (99, 64)
    proof, rgba = good(host, 'render_proof', dict(export, proof_long_edge=256, display='srgb', generation=8))
    assert proof['generation'] == 8 and tiff_pixels(target) == bytes(v for i,v in enumerate(rgba) if i%4 != 3)
    _, restored = good(host, 'render_view', view); assert restored == original, 'frozen export/proof changed pair editor'
    private = deepcopy(pair); private['left']['exposureEV'] = 1
    private_export = dict(export, pair=private, path=str(root/'private.tif'))
    good(host, 'export_frame', private_export)
    _, restored = good(host, 'render_view', view); assert restored == original, 'private pair export lost original random cache'
    # A pending fit for the selected right hole must not overwrite left's curve.
    placement_params = dict(params, grain_active=False, scene_latitude_active=True,
                            scene_latitude_b_active=True, scene_latitude_split=.5,
                            scene_latitude_highlight_knee=2, scene_latitude_highlight_room=1,
                            scene_latitude_b_highlight_knee=2, scene_latitude_b_highlight_room=1)
    good(host, 'render_proof', dict(export, params=placement_params, pair=pair, proof_long_edge=128,
         display='srgb', generation=10, scene_placement_side='right',
         scene_placement={'highlight_pull_back':0,'shadow_pull_back':0,'region':[.5,0,1,1]}))
    fitted, _ = good(host, 'get_params', {'session':sid})
    assert fitted['params']['scene_latitude_active'] and not fitted['params']['scene_latitude_b_active'], 'right fit overwrote left placement'
    # Actual engine meters are returned per hole and reused across movement.
    metered = deepcopy(pair); metered['left']['autoExposure'] = True
    result, _ = good(host, 'update_pair', {'session': sid, 'pair': metered, 'params': params})
    ev = result['pair_info']['left']['metered_ev']
    key = result['pair_info']['left']['metered_for']; assert isinstance(key,str) and key
    _, measured_grain = good(host,'render_view',view)
    metered['left'].update(meteredEV=ev,meteredFor=key)
    good(host,'update_pair',{'session':sid,'pair':metered,'params':params})
    absorbed, same_grain = good(host,'render_view',view)
    assert absorbed['print_cached'] and same_grain==measured_grain, 'meter metadata absorption regenerated random negative'
    metered['left']['placement'] = {'scale': 2, 'x': .4}
    result, _ = good(host, 'update_pair', {'session': sid, 'pair': metered, 'params': params})
    assert result['pair_info']['left']['metered_ev'] == ev
    # After movement a new composer/private export must retain the original
    # reading, rather than measuring the new nonuniform crop again.
    deterministic=dict(params,grain_active=False)
    good(host,'update_pair',{'session':sid,'pair':metered,'params':deterministic})
    warm_export=dict(export,pair=metered,params=deterministic,path=str(root/'meter-warm.tif'))
    good(host,'export_frame',warm_export)
    cold_export=dict(warm_export,path=str(root/'meter-cold.tif'));cold_export.pop('session')
    good(host,'export_frame',cold_export)
    assert tiff_pixels(root/'meter-warm.tif')==tiff_pixels(root/'meter-cold.tif'), 'cold export changed persisted hole exposure'
    reopened,_=good(host,'open_pair',{'path':str(path),'pair':metered,'params':deterministic})
    assert reopened['pair_info']['left']['metered_ev']==ev and reopened['pair_info']['left']['metered_for']==key
    good(host,'close',{'session':reopened['session']})
    missing = deepcopy(pair); missing['right']['path'] = str(root/'absent.NEF')
    result, _ = good(host, 'update_pair', {'session': sid, 'pair': missing, 'params': params})
    assert not result['pair_info']['right']['available'] and result['pair_info']['right']['error']
    rejected, _ = host.call('export_frame', dict(export, pair=missing, path=str(root/'missing.tif')))
    assert not rejected.get('ok') and not (root/'missing.tif').exists()
    good(host, 'cancel', {'session': sid, 'progress_id': 'cancel-pair'})
    rejected, _ = host.call('export_frame', dict(export, pair=private, path=str(root/'cancelled.tif'), progress_id='cancel-pair'))
    assert not rejected.get('ok') and rejected['error']['code'] == 'cancelled' and not (root/'cancelled.tif').exists()
    good(host, 'close', {'session': sid})
    print('Pair host: layout/probe/thumbnail, half-frame display16, per-hole grade and cached grain, frozen export/proof equality, private-source preservation, actual per-hole meter, missing-hole refusal and cancellation passed', flush=True)


def main():
    p = argparse.ArgumentParser(); p.add_argument('--host', required=True); p.add_argument('--resources', required=True); args=p.parse_args()
    host=Host([args.host,'--resources',args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spektralab-pair-') as root: exercise(host,Path(root))
    finally:
        if host.p.poll() is None:
            good(host,'shutdown'); host.p.wait(timeout=20)

if __name__ == '__main__': main()
