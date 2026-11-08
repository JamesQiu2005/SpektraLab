#!/usr/bin/env python3
"""Require archive hits, then prove missing/corrupt optional artifacts fall back."""
import argparse
import json
from pathlib import Path
import shutil
import tempfile
import numpy as np
from performance_compare import run

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--engine', type=Path, default=Path(__file__).resolve().parents[1])
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--foreign-archive', type=Path, help='Optional archive from the before engine')
args = ap.parse_args()
root = args.engine.resolve()
rows = []
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    res = tmp/'resources'
    res.mkdir()
    for item in (root/'resources').iterdir():
        if item.name not in ('spektralab.metalar', 'cam16'):
            (res/item.name).symlink_to(item, target_is_directory=item.is_dir())
    archive = res/'spektralab.metalar'
    shutil.copy2(root/'resources/spektralab.metalar', archive)
    shutil.copytree(root/'resources/cam16', res/'cam16')
    output = tmp/'image.npy'
    job = dict(root=str(root), resources=str(res), w=1200, edge=True, steps=[dict(save=str(output))],
               env={'SPK_METAL_ARCHIVE_MODE': 'required', 'SPK_METAL_PIPELINE_LOG': '1'})
    data = run(job)
    assert data['pipelines'] and all(p[2]=='1' for p in data['pipelines']), data['pipelines']
    reference = np.load(output)
    rows.append(dict(mode='required', exact=True, pipelines=data['pipelines']))
    for mode in ['off', 'missing', 'corrupt', 'missing_cam16', 'corrupt_cam16']:
        job['env'] = {'SPK_METAL_PIPELINE_LOG': '1'}
        if mode == 'off':
            job['env']['SPK_METAL_ARCHIVE_MODE'] = 'off'
        elif mode == 'missing':
            archive.unlink()
        elif mode == 'corrupt':
            archive.write_bytes(b'not a Metal archive')
        elif mode == 'missing_cam16':
            shutil.rmtree(res/'cam16')
        elif mode == 'corrupt_cam16':
            shutil.copytree(root/'resources/cam16', res/'cam16')
            for file in (res/'cam16').glob('*.cam16'):
                file.write_bytes(b'not a CAM16 table')
        data = run(job)
        assert np.array_equal(reference, np.load(output)), mode
        rows.append(dict(mode=mode, exact=True, pipelines=data['pipelines']))
        print(mode, 'exact fallback', flush=True)
    if args.foreign_archive:
        shutil.copy2(args.foreign_archive, archive)
        data = run(job)
        assert np.array_equal(reference, np.load(output)), 'foreign archive fallback'
        assert any(p[2] == '0' for p in data['pipelines']), 'old archive unexpectedly contained every new kernel'
        rows.append(dict(mode='foreign', exact=True, pipelines=data['pipelines']))
        print('foreign exact fallback', flush=True)
    # The archive check must fail when required, proving the normal fallback
    # cases above did not silently turn the assertion off.
    job['env']['SPK_METAL_ARCHIVE_MODE'] = 'required'
    try:
        run(job)
    except RuntimeError as e:
        assert 'could not build a pipeline' in str(e), str(e)
        rows.append(dict(mode='required_invalid_or_incomplete', rejected=True))
    else:
        raise AssertionError('invalid or incomplete archive satisfied required mode')
args.output.write_text(json.dumps(rows, indent=2))
