#!/usr/bin/env python3
"""RFC-035: Film Exposure and Decode must invalidate a warm v2 checkpoint.

Build with engine/build.sh dylib, then run with a numpy-enabled Python.
Every step must equal forced-full execution; traces must prove real reuse.
"""
import argparse
import json
from pathlib import Path
import tempfile

import numpy as np
from performance_compare import run
from scene_curve_checks import bump


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    results = []
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        # A local bump is required: a uniform gain commutes with Film Exposure.
        params = dict(product_defaults=True, scene_curve=bump(0.0))
        deltas = [{}, {'grain_amount': .8}, {'grain_amount': 1.2},
                  {'exposure_compensation_ev': 1.0},
                  {'grain_amount': .8}, {'grain_amount': 1.2},
                  {'exposure_compensation_ev': 0.0},
                  {'grain_amount': .8}, {'grain_amount': 1.2},
                  {'scene_curve': bump(1.0)},
                  {'grain_amount': .8}, {'grain_amount': 1.2}]
        for mode in ('off', 'auto'):
            result = run(dict(root=str(args.engine.resolve()), w=1200, params=params,
                              env=dict(SPK_CHECKPOINT_MODE=mode, SPK_CHECKPOINT_TRACE='1',
                                       SPK_CHECKPOINT_TEST_FORCE_ADMISSION='1'),
                              steps=[dict(delta=delta, save=str(directory / f'{mode}-{i}.npy'))
                                     for i, delta in enumerate(deltas)]))
            results.append(result)
        for i in range(len(deltas)):
            assert np.array_equal(np.load(directory / f'off-{i}.npy'),
                                  np.load(directory / f'auto-{i}.npy')), f'stale checkpoint at step {i}: {deltas[i]}'
        image = lambda i: np.load(directory / f'auto-{i}.npy')
        assert not np.array_equal(image(2), image(5)), 'Film Exposure did not change the developed picture'
        assert np.array_equal(image(2), image(8)), 'resetting Film Exposure did not restore the picture'
        assert not np.array_equal(image(8), image(11)), 'Decode change did not change the picture'
        hits = [event for event in results[1]['checkpoints'] if event.startswith('hit ')]
        assert len(hits) >= 4, f'expected reuse before and after each invalidation: {results[1]["checkpoints"]}'
    report = dict(exact_steps=len(deltas), checkpoint_hits=len(hits),
                  events=results[1]['checkpoints'], exposure_changed=True,
                  exposure_reset_exact=True, curve_changed=True)
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
