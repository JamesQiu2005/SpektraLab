#!/usr/bin/env python3
"""Require a catalogued pair's exact resources; never borrow another pair's LUT.

    python engine/tests/minilab_resource_checks.py --output /tmp/check.json
    python engine/tests/minilab_resource_checks.py --film cinestill_800t \
        --paper kodak_2383 --output /tmp/cinestill.json

Every catalogued entry is checked for: a missing catalog, a corrupt table, a
missing table, a changed named profile, and -- for a `derived_from` alias -- a
changed inherited base profile. A pair that is not catalogued must keep
rendering on its own optical path and must not pick up another pair's table.

`--film/--paper` default to the frozen Portra pair so the existing callers keep
their meaning.
"""
import argparse
import json
import shutil
import tempfile
from pathlib import Path

from performance_compare import run

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--engine', type=Path, default=Path(__file__).resolve().parents[1])
ap.add_argument('--film', default='kodak_portra_400')
ap.add_argument('--paper', default='kodak_portra_endura')
ap.add_argument('--other-film', help='a film with no catalogued entry for this paper; '
                                        'default: the first such colour film found')
ap.add_argument('--output', type=Path, required=True)
a = ap.parse_args()
root = a.engine.resolve()
film, paper = a.film, a.paper
results = []


def overlay_profiles(dest):
    """The bundle's profiles: the base overlay, then the product overlay over it."""
    shutil.copytree(root / 'resources' / 'profiles', dest)
    product = root / 'resources_product' / 'profiles'
    if product.is_dir():
        for path in product.glob('*.json'):
            shutil.copy2(path, dest / path.name)


with tempfile.TemporaryDirectory() as td:
    res = Path(td) / 'resources'
    res.mkdir()
    for p in (root / 'resources').iterdir():
        if p.name in ('minilab', 'profiles'):
            continue
        (res / p.name).symlink_to(p, target_is_directory=p.is_dir())
    overlay_profiles(res / 'profiles')
    shutil.copytree(root / 'resources' / 'minilab', res / 'minilab')

    index = json.loads((res / 'minilab/index.json').read_text())
    entry = index['pairs'].get(film + '|' + paper)
    if entry is None:
        raise SystemExit('no catalogued entry for %s / %s' % (film, paper))
    name = entry['sRGB']['file']
    other = a.other_film
    if other is None:
        for path in sorted((res / 'profiles').glob('*.json')):
            data = json.loads(path.read_text())
            info = data.get('info', {})
            stock = path.stem
            if (info.get('stage') != 'filming' or info.get('type') != 'negative'
                    or info.get('channel_model') in ('bw', 'monochrome')):
                continue
            if stock not in index['pairs'] or film + '|' + paper == stock:
                pass
            if ('%s|%s' % (stock, paper)) not in index['pairs'] and stock != film:
                other = stock
                break
    if other is None or other == film:
        raise SystemExit('no uncatalogued colour film to use as --other-film')
    params = dict(film_stock=film, print_stock=paper)
    job = dict(root=str(root), resources=str(res), w=180,
               params=dict(params, grain_active=False, glare_active=False))

    def reject(case, params_=None):
        j = dict(job)
        if params_:
            j['params'] = dict(job['params'], **params_)
        try:
            run(j)
        except RuntimeError as e:
            assert 'minilab' in str(e), str(e)
            results.append(dict(case=case, rejected=True, error=str(e)[:200]))
        else:
            raise AssertionError(case + ' silently rendered')

    def accept(case, params_=None):
        j = dict(job)
        if params_:
            j['params'] = dict(job['params'], **params_)
        run(j)
        results.append(dict(case=case, passed=True))

    idx = res / 'minilab/index.json'
    original_idx = idx.read_bytes()
    idx.unlink()
    reject('missing_catalog')
    idx.write_bytes(original_idx)

    lut = res / 'minilab' / name
    original_lut = lut.read_bytes()
    lut.write_bytes(b'corrupt')
    reject('corrupt_table')
    accept('other_pair_independent', {'film_stock': other, 'print_stock': paper})
    lut.unlink()
    reject('missing_table')
    lut.write_bytes(original_lut)
    accept('pair_renders')

    profile = res / 'profiles' / (film + '.json')
    original_profile = profile.read_bytes()
    profile.write_bytes(original_profile + b'\n')
    reject('profile_identity')
    profile.write_bytes(original_profile)

    base = json.loads(original_profile).get('derived_from')
    if base:
        base_path = res / 'profiles' / (base + '.json')
        original_base = base_path.read_bytes()
        base_path.write_bytes(original_base + b'\n')
        reject('inherited_profile_identity')
        base_path.write_bytes(original_base)
        # Backward compatibility: an entry that does not declare the base hash
        # applies the older, narrower check rather than refusing to load.
        slim = json.loads(original_idx)
        for space_entry in slim['pairs'][film + '|' + paper].values():
            space_entry.pop('film_base_hash', None)
            space_entry.pop('paper_base_hash', None)
        idx.write_text(json.dumps(slim, indent=2) + '\n')
        accept('base_hash_optional')
        idx.write_bytes(original_idx)
    else:
        results.append(dict(case='inherited_profile_identity', skipped='not an alias'))

a.output.write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results))
