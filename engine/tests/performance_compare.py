#!/usr/bin/env python3
"""Before/after engine qualification and interleaved fresh-process measurements.

Requires numpy and two independently built engine directories. Input decoding,
Python startup and output copies are excluded from render timers. Peak footprint
is the whole worker process, including its input. No driver cache is purged.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

import numpy as np
import spk_ctypes as spk
from scene_curve_checks import table


def frame(w):
    h = round(w * 2 / 3)
    img = np.empty((h, w, 3), np.float32)
    x = np.geomspace(.00001, 4, w, dtype=np.float32)
    y = np.linspace(.1, 1, h, dtype=np.float32)[:, None]
    img[:, :, 0] = x * y
    img[:, :, 1] = x[::-1] * y
    img[:, :, 2] = x * .4
    return img


def audit(e):
    m = e.memory_report()
    assert m['pool']['live_bytes'] == 0, m
    for key in ('pending_held', 'over_releases', 'live_underflows', 'reclaim_while_encoding'):
        assert m['pool']['audit'][key] == 0, (key, m)
    return m


def render(s, copy=False, reprint=False):
    result = spk.SpkResult()
    start = time.perf_counter()
    fn = s._engine._lib.spk_reprint if reprint else s._engine._lib.spk_render
    if fn(s._handle, b'full', ctypes.byref(result)) != spk.SPK_OK:
        raise RuntimeError(s._engine._last_error())
    wall = (time.perf_counter() - start) * 1000
    try:
        a = None
        if copy:
            a = np.ctypeslib.as_array(result.rgba16, shape=(result.height * result.row_stride_px * 4,))
            a = a.reshape(result.height, result.row_stride_px, 4)[:, :result.width].copy()
        return a, dict(wall_ms=wall, engine_ms=result.elapsed_ms, cached=bool(result.negative_was_cached))
    finally:
        s._engine._lib.spk_result_free(ctypes.byref(result))


def worker(job):
    for key in list(os.environ):
        if key.startswith('SPK_') or key.startswith('SPEKTRALAB_'):
            os.environ.pop(key)
    os.environ.update(job.get('env', {}))
    root = Path(job['root'])
    img = np.load(job['input']) if job.get('input') else frame(job.get('w', 1200))
    params = dict(input_cctf_decoding=False, input_color_space='ProPhoto RGB',
                  output_color_space='sRGB', auto_exposure=False, grain_active=True,
                  glare_active=False, film_stock='kodak_portra_400', print_stock='kodak_portra_endura',
                  overscan_active=job.get('edge', False))
    params.update(job.get('params', {}))
    start = time.perf_counter()
    e = spk.Engine(dylib=root/'build/libspektralab_engine.dylib', resources=job.get('resources', root/'resources'))
    created = (time.perf_counter() - start) * 1000
    rows, closed = [], []
    try:
        for cycle in range(job.get('cycles', 1)):
            start = time.perf_counter()
            s = e.open(img, params)
            opened = (time.perf_counter() - start) * 1000
            try:
                for i, step in enumerate(job.get('steps', [{}])):
                    if step.get('delta'):
                        s.set_params(step['delta'])
                    if step.get('di'):
                        start = time.perf_counter()
                        a, info = s.render_digital_intermediate()
                        row = dict(wall_ms=(time.perf_counter()-start)*1000, di=info)
                    else:
                        a, row = render(s, bool(step.get('save')), step.get('reprint', False))
                    if step.get('save'):
                        np.save(step['save'], a)
                    rows.append(dict(cycle=cycle, step=i, open_ms=opened, **row, memory=audit(e)))
            finally:
                s.close()
            m = audit(e)
            assert m['persistent']['bytes'] == 0, m
            closed.append(dict(memory=m, fd_count=len(os.listdir('/dev/fd'))))
    finally:
        e.close()
    return dict(create_ms=created, first_total_ms=created+rows[0]['open_ms']+rows[0]['wall_ms'], rows=rows, closed=closed)


def run(job):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d)/'job.json'
        p.write_text(json.dumps(job))
        result = subprocess.run(['/usr/bin/time', '-l', sys.executable, __file__, 'worker', str(p)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout+result.stderr)
        data = json.loads(result.stdout.splitlines()[-1])
        match = re.search(r'(\d+)\s+peak memory footprint', result.stderr)
        data['peak_mib'] = int(match[1])/2**20 if match else None
        data['checkpoints'] = re.findall(r'\[checkpoint\] ([^\n]+)', result.stderr)
        data['pipelines'] = re.findall(r'\[metal\] pipeline (\S+) ([\d.]+) archive_hit=(\d)', result.stderr)
        return data


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'worker':
        print(json.dumps(worker(json.loads(Path(sys.argv[2]).read_text()))))
        return
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode', choices=['check', 'bench', 'lifecycle'])
    ap.add_argument('--before', type=Path, required=True)
    ap.add_argument('--after', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--blocks', type=int, default=3)
    args = ap.parse_args()
    roots = dict(before=str(args.before.resolve()), after=str(args.after.resolve()))
    results = []
    if args.mode == 'check':
        cases = [('default', {}), ('curve', {'scene_curve': table(rgb=.6, r=-.2)}),
                 ('dir_off', {'dir_couplers_active': False}), ('dir_1.5', {'dir_couplers_amount': 1.5}),

                 ('edge', {'overscan_active': True}), ('scan', {'scan_film': True})]
        # Colourspaces, transfer functions, positive stock and B&W exercise
        # conditions outside the Portra reference pair.
        for cs in ['sRGB', 'ProPhoto RGB', 'Display P3', 'Adobe RGB (1998)', 'ITU-R BT.2020', 'ACEScg']:
            cases.append((cs, {'output_color_space': cs}))
        cases += [('positive', {'film_stock': 'kodak_ektachrome_100'}),
                  ('encoded', {'input_color_space': 'sRGB', 'input_cctf_decoding': True}),
                  ('linear_output', {'output_cctf_encoding': False})]
        with tempfile.TemporaryDirectory() as d:
            for name, params in cases:
                paths = {k: str(Path(d)/(k+'.npy')) for k in roots}
                for k, root in roots.items():
                    run(dict(root=root, w=1200, params=params, steps=[dict(save=paths[k])]))
                a, b = [np.load(paths[k]) for k in roots]
                assert np.array_equal(a,b), (name, np.max(np.abs(a.astype(int)-b.astype(int))))
                results.append(dict(case=name, exact=True))
                print(name, 'exact', flush=True)
            # A changed Decode curve must change output, including after a warm render.
            for k, root in roots.items():
                paths = [str(Path(d)/f'{k}-{i}.npy') for i in range(3)]
                steps = [dict(save=paths[0]), dict(delta={'scene_curve': table(rgb=.6)}, save=paths[1]),
                         dict(delta={'scene_curve': ''}, save=paths[2])]
                run(dict(root=root, w=600, steps=steps))
                a, b, c = [np.load(p) for p in paths]
                assert not np.array_equal(a,b), 'Decode check did not exercise the curve'
                assert np.array_equal(a,c), 'Decode reset did not restore output'
                results.append(dict(arm=k, scene_curve_invalidation=True))
            for k, root in roots.items():
                run(dict(root=root, w=600, steps=[dict(di=True, save=str(Path(d)/(k+'-di.npy')))]))
            assert np.array_equal(np.load(Path(d)/'before-di.npy'), np.load(Path(d)/'after-di.npy'))
            results.append(dict(case='DI', exact=True))
    elif args.mode == 'bench':
        for w in (2560, 6000, 8256):
            for edge in (False, True):
                for block in range(args.blocks):
                    for arm in ('before', 'after', 'after', 'before'):
                        job = dict(root=roots[arm], w=w, edge=edge, steps=[{},
                            {'delta': {'grain_amount': .8}}, {'delta': {'grain_amount': 1.2}},
                            {'delta': {'print_exposure': .2}, 'reprint': True}])
                        load = dict(at=time.time(), averages=os.getloadavg(), processes=subprocess.check_output(['ps', '-Ao', '%cpu,comm', '-r'], text=True).splitlines()[:8])
                        data = run(job)
                        results.append(dict(arm=arm, w=w, edge=edge, block=block, result=data, load=load))
                    print(w, edge, block, 'complete', flush=True)
    else:
        for arm in ('before', 'after', 'after', 'before'):
            data = run(dict(root=roots[arm], w=1200, edge=True, cycles=16,
                            steps=[{}, {'delta': {'scene_curve': table(rgb=.5)}}, {'delta': {'grain_amount': .8}}]))
            fds = [r['fd_count'] for r in data['closed']]
            assert max(fds) == min(fds), fds
            results.append(dict(arm=arm, result=data))
            print(arm, '16 sessions / 48 renders audited', flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(roots=roots, results=results), indent=2))

if __name__ == '__main__':
    main()
