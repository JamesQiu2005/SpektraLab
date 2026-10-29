#!/usr/bin/env python3
"""Exposure handoff preserves actual rendered bytes, including scene placement."""
import argparse
from copy import deepcopy
from pathlib import Path
import tempfile
from host_smoke import Host, write_png
from host_proof import good


def exercise(host, root):
    image = root / 'owned.png'
    write_png(str(image), 96, 64)
    base = {'auto_exposure': True, 'auto_exposure_method': 'balanced',
            'exposure_compensation_ev': .4, 'grain_active': True,
            'glare_active': False, 'overscan_active': False, 'date_imprint_active': False}
    for placement in (False, True):
        params = {**base, 'scene_latitude_active': placement, 'scene_latitude_highlight_knee': 1,
                  'scene_latitude_highlight_room': 2, 'scene_latitude_shadow_knee': -1, 'scene_latitude_shadow_room': 2}
        opened, _ = good(host, 'open', {'path': str(image), 'params': params})
        sid = opened['session']
        for method in ('balanced', 'center', 'protect_highlights', 'protect_shadows'):
            good(host, 'set_params', {'session': sid, 'delta': {'auto_exposure': True, 'auto_exposure_method': method}})
            solved, _ = good(host, 'solve', {'session': sid, 'target': 'exposure'})
            ev = solved['solved_params']['exposure_compensation_ev']
            request = {'session': sid, 'tier': 'full', 'format': 'rgba16', 'display': 'srgb'}
            _, before = good(host, 'render', request)
            good(host, 'set_params', {'session': sid, 'delta': {'auto_exposure': False, 'exposure_baseline_ev': ev}})
            _, after = good(host, 'render', request)
            assert before == after, (placement, method, 'handoff moved pixels')
            # An immutable reopen must retain the same result, not depend on a warm cache.
            frozen = {**params, 'auto_exposure': False, 'auto_exposure_method': method, 'exposure_baseline_ev': ev}
            reopened, _ = good(host, 'open', {'path': str(image), 'params': frozen})
            _, cold = good(host, 'render', {**request, 'session': reopened['session']})
            assert cold == before, 'reopened exposure differs'
            good(host, 'close', {'session': reopened['session']})
        good(host, 'set_params', {'session': sid, 'delta': {'exposure_baseline_ev': 0, 'exposure_compensation_ev': 0}})
        _, reset = good(host, 'render', request)
        fresh, _ = good(host, 'open', {'path': str(image), 'params': {**params, 'auto_exposure': False, 'exposure_compensation_ev': 0}})
        _, shot = good(host, 'render', {**request, 'session': fresh['session']})
        assert reset == shot, 'As Shot retained the frozen meter'
        good(host, 'close', {'session': fresh['session']})
        # User path: automatic -> As Shot -> type the same exposure again.
        # The manual slider must edit the pre-scene term, not the compensated
        # post-scene film term. Compare actual pixels, not just the displayed sum.
        for method in ('balanced', 'center', 'protect_highlights', 'protect_shadows'):
            good(host, 'set_params', {'session': sid, 'delta': {'auto_exposure': True,
                 'auto_exposure_method': method, 'exposure_compensation_ev': 0, 'exposure_baseline_ev': 0}})
            solved, _ = good(host, 'solve', {'session': sid, 'target': 'exposure'})
            ev = solved['solved_params']['exposure_compensation_ev']
            _, automatic = good(host, 'render', request)
            good(host, 'set_params', {'session': sid, 'delta': {'auto_exposure': False,
                 'exposure_compensation_ev': 0, 'exposure_baseline_ev': 0}})
            good(host, 'render', request)
            good(host, 'set_params', {'session': sid, 'delta': {'exposure_baseline_ev': ev}})
            _, manual = good(host, 'render', request)
            assert manual == automatic, (placement, method, 'manual re-entry after As Shot differs')
        good(host, 'close', {'session': sid})
    hole = {'path': str(image), 'autoExposure': True, 'exposureEV': .4}
    pair = {'schemaVersion': 1, 'left': hole, 'right': deepcopy(hole)}
    opened, _ = good(host, 'open_pair', {'path': str(root / 'owned.spektrapair'), 'pair': pair, 'params': base})
    sid = opened['session']
    view = {'session': sid, 'tier': 'full', 'generation': 1, 'format': 'rgba16', 'display': 'srgb', 'adjustments': {}, 'geometry': {}}
    _, before = good(host, 'render_view', view)
    frozen = deepcopy(pair)
    frozen['left'].update(autoExposure=False, exposureBaselineEV=opened['pair_info']['left']['metered_ev'])
    good(host, 'update_pair', {'session': sid, 'pair': frozen, 'params': base})
    _, after = good(host, 'render_view', view)
    assert after == before, 'pair handoff moved pixels'
    good(host, 'close', {'session': sid})
    print('Exposure handoff: all four meters, scene placement on/off, cold reopen, As Shot/manual re-entry and pair pixels identical')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True); parser.add_argument('--resources', required=True)
    args = parser.parse_args()
    host = Host([args.host, '--resources', args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spektralab-exposure-') as tmp:
            exercise(host, Path(tmp))
    finally:
        if host.p.poll() is None:
            good(host, 'shutdown'); host.p.wait(timeout=20)
