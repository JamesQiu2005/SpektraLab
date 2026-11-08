#!/usr/bin/env python3
"""Inventory every engine film x paper combination, including product overlays.

Read-only for profiles and catalog; emits a resumable job seed, not qualification.
No third-party packages or Metal device required.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

SPACES = ('sRGB', 'ProPhoto RGB')
TABLE_BYTES = 28 + 65 ** 3 * 3 * 4


def inventory(engine, catalog):
    paths = {}
    for folder in (engine / 'resources/profiles', engine / 'resources_product/profiles'):
        for path in sorted(folder.glob('*.json')):
            paths[path.stem] = path
    raw = {stock: json.loads(path.read_text()) for stock, path in paths.items()}
    records = {}
    for stock, data in raw.items():
        base = data.get('derived_from')
        dependencies = [stock]
        if base:
            if base not in raw or raw[base].get('derived_from'):
                raise ValueError(f'{stock}: missing or nested alias base {base}')
            info = dict(raw[base]['info'])
            info.update(data.get('info', {}))
            dependencies.append(base)
        else:
            info = dict(data['info'])
        if info.get('stage') not in ('filming', 'printing'):
            raise ValueError(f'{stock}: unknown stage {info.get("stage")}')
        model = info.get('channel_model', 'color')
        if model not in ('color', 'bw', 'monochrome'):
            raise ValueError(f'{stock}: unknown channel model {model}')
        records[stock] = dict(id=stock, stage=info['stage'], type=info['type'],
            monochrome=model in ('bw', 'monochrome'), derived_from=base,
            target_print=info.get('target_print'),
            profile_sha256={str(paths[k].relative_to(engine)): hashlib.sha256(paths[k].read_bytes()).hexdigest() for k in dependencies})
    visible = None if catalog is None else {s['id'] for s in json.loads(catalog.read_text())['stocks']}
    index = json.loads((engine / 'resources/minilab/index.json').read_text())
    films = sorted((r for r in records.values() if r['stage'] == 'filming'), key=lambda r:r['id'])
    papers = sorted((r for r in records.values() if r['stage'] == 'printing'), key=lambda r:r['id'])
    pairs = []
    for film in films:
        for paper in papers:
            f,p = film['id'],paper['id']
            if film['type'] == 'positive':
                route,reason = 'positive_bypass','Reversal scan bypasses paper; do not invent a negative minilab calibration.'
            elif film['monochrome'] != paper['monochrome']:
                route,reason = 'incompatible_channel_models','Colour/silver mismatch; preserve the product pairing rule.'
            elif film['monochrome']:
                route,reason = 'silver_path','Dedicated monochrome path; colour hue recovery is not applicable.'
            else:
                route,reason = 'colour_minilab','Bake and qualify this explicit negative-film / colour-paper pair.'
            entry = index['pairs'].get(f+'|'+p, {})
            pair = dict(film=f, paper=p, route=route, reason=reason,
                default_pair=film['target_print']==p,
                catalogued_spaces=[s for s in SPACES if s in entry],
                missing_spaces=[s for s in SPACES if s not in entry] if route=='colour_minilab' else [],
                state=('catalogued_recheck' if entry else 'pending') if route=='colour_minilab' else 'accounted_special_path',
                alias_dependency_check_required=bool(film['derived_from'] or paper['derived_from']),
                profile_sha256={**film['profile_sha256'],**paper['profile_sha256']})
            if visible is not None:pair['visible_in_supplied_app_catalog']=f in visible and p in visible
            pairs.append(pair)
    counts=Counter(p['route'] for p in pairs)
    eligible=counts['colour_minilab']
    return dict(schema_version=1, note='Inventory only. Catalog presence is not a new QA pass; no rows are silently dropped.',
        recipe=dict(side=65,storage='float32',spaces=list(SPACES),r_blend=1.0,ymode='opt',mode='hybrid',print_ev=0.0),
        summary=dict(films=len(films),papers=len(papers),all_pairs=len(pairs),routes=dict(counts),
            colour_pairs_with_both_catalog_entries=sum(p['route']=='colour_minilab' and not p['missing_spaces'] for p in pairs),
            total_production_tables=eligible*2,production_payload_bytes=eligible*2*TABLE_BYTES),
        films=films,papers=papers,pairs=pairs)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine',type=Path,default=Path(__file__).resolve().parents[1])
    ap.add_argument('--catalog',type=Path)
    ap.add_argument('--output',type=Path,required=True)
    a=ap.parse_args();data=inventory(a.engine.resolve(),a.catalog)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps(data['summary'],indent=2))

if __name__=='__main__':main()
