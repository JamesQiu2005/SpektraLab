#!/usr/bin/env python3
"""RAW pair source-neutral calibration, cache reuse and hole boundary checks."""
import argparse
import json
import tempfile
from copy import deepcopy
from pathlib import Path
from host_smoke import Host
from host_proof import good

def exercise(host, root, raw):
    hole = {'path': str(raw.resolve()), 'decode': {'whiteBalance': 'As Shot', 'rawMode': 'headroom'},
            'geometry': {}, 'placement': {}, 'autoExposure': False, 'exposureEV': 0}
    pair = {'schemaVersion': 1, 'folder': str(root), 'spacingMM': 1, 'turned': False,
            'left': hole, 'right': deepcopy(hole)}
    path = root / 'neutral.spektrapair'; path.write_text(json.dumps(pair))
    params = {'auto_exposure': False, 'grain_active': False, 'halation_active': False, 'glare_active': False}
    opened, _ = good(host, 'open_pair', {'path': str(path), 'pair': pair, 'params': params})
    sid = opened['session']; gates = opened['pair_info']['gates']
    picked = []
    for side, gate in zip(('left', 'right'), gates):
        found = None
        for u, v in ((.3,.3),(.5,.5),(.7,.7),(.3,.7),(.7,.3)):
            point = {'session':sid,'side':side,'x':gate['x']+u*gate['width'],'y':gate['y']+v*gate['height']}
            reply, _ = host.call('pick_neutral', point)
            if reply['ok']:
                found = (point, reply['result']); break
        assert found, f'no calibrated patch in {side}'
        picked.append(found)
    # A source-cache hit must preserve calibration; undo the composed exposure
    # before interpreting clipping and camera white balance.
    exposed = deepcopy(pair); exposed['left']['exposureEV'] = 2; exposed['right']['exposureEV'] = -2
    good(host, 'update_pair', {'session':sid,'pair':exposed,'params':params})
    for point, expected in picked:
        actual, _ = good(host, 'pick_neutral', point)
        assert abs(actual['temperature_k']-expected['temperature_k']) < .05
        assert abs(actual['tint']-expected['tint']) < .01
    left, right = gates
    for side, x, y in (('left',right['x']+right['width']/2,.5),
                       ('right',left['width']/2,.5),
                       ('left',(left['width']+right['x'])/2,.5),
                       ('left',left['width'],.5),('wrong',.2,.5)):
        reply, _ = host.call('pick_neutral', {'session':sid,'side':side,'x':x,'y':y})
        assert not reply['ok'] and reply['error']['code']=='bad_request'
    good(host,'close',{'session':sid})
    print('RAW pair neutral: both hole calibration, warm source cache, exposure invariance, wrong side/gap/boundary rejection passed')

def main():
    p=argparse.ArgumentParser();p.add_argument('--host',required=True);p.add_argument('--resources',required=True);p.add_argument('--raw',type=Path,required=True);a=p.parse_args()
    host=Host([a.host,'--resources',a.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spk-pair-neutral-') as tmp:exercise(host,Path(tmp),a.raw)
    finally:
        if host.p.poll() is None:good(host,'shutdown');host.p.wait(timeout=20)
if __name__=='__main__':main()
