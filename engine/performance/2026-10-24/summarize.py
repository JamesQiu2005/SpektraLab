#!/usr/bin/env python3
"""Summarize the six-step integrated-engine ABBA benchmark without dropping misses."""
import argparse,json,statistics
from pathlib import Path
ap=argparse.ArgumentParser();ap.add_argument('input',type=Path);ap.add_argument('output',type=Path);a=ap.parse_args()
rows=json.loads(a.input.read_text())['results'];out=[]
for w,edge in sorted({(x['w'],x['edge']) for x in rows}):
    item=dict(width=w,edge=edge)
    for arm in ('before','after'):
        rs=[x['result'] for x in rows if (x['w'],x['edge'],x['arm'])==(w,edge,arm)]
        med=lambda xs:round(statistics.median(xs),3)
        item[arm]=dict(processes=len(rs),first_total_ms=med(x['first_total_ms'] for x in rs),
            first_render_ms=med(x['rows'][0]['wall_ms'] for x in rs),
            first_grain_edit_ms=med(x['rows'][1]['wall_ms'] for x in rs),
            later_grain_edit_ms=med(y['wall_ms'] for x in rs for y in x['rows'][2:5]),
            reprint_ms=med(x['rows'][5]['wall_ms'] for x in rs),
            peak_mib_median=med(x['peak_mib'] for x in rs),
            peak_mib_range=[round(min(x['peak_mib'] for x in rs),3),round(max(x['peak_mib'] for x in rs),3)],
            checkpoint_hits=sum(c.startswith('hit ') for x in rs for c in x.get('checkpoints',[])),
            checkpoint_events=[x.get('checkpoints',[]) for x in rs])
    out.append(item)
a.output.write_text(json.dumps(out,indent=2)+'\n')
for r in out:
    print(r['width'],r['edge'])
    for arm in ('before','after'):
        print(arm,{k:v for k,v in r[arm].items() if k!='checkpoint_events'})
