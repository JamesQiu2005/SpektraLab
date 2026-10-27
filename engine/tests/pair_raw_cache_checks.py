"""Opt-in real RAW cache checks; input photo read-only, isolated recipe only."""
import argparse,copy,hashlib,json,tempfile
from pathlib import Path
from host_smoke import Host
ap=argparse.ArgumentParser();ap.add_argument('--host',type=Path,required=True);ap.add_argument('--resources',type=Path,required=True);ap.add_argument('--pair',type=Path,required=True);ap.add_argument('--raw',type=Path,required=True);args=ap.parse_args()
raw=args.raw.resolve();original=hashlib.sha256(raw.read_bytes()).hexdigest()
doc=json.loads(args.pair.read_text(encoding='utf-8-sig'))
for side in ['left','right']:
    hole=doc[side];assert Path(hole['path']).resolve()==raw,'test allows the authorised RAW only'
    hole.pop('meteredEV',None);hole.pop('meteredFor',None);hole['autoExposure']=True
out=Path(tempfile.mkdtemp(prefix='spk-pair-raw-cache-'));recipe=out/'pair.spektrapair'
h=Host([str(args.host.resolve()),'--resources',str(args.resources.resolve())])
params={'grain_active':False,'halation_active':False,'glare_active':False,'overscan_active':True}
def opened(d,render=False):
    recipe.write_text(json.dumps(d),encoding='utf-8')
    r,_=h.call('open',{'path':str(recipe),'params':params,'pair_presentation':'client'});assert r['ok'],r
    r=r['result'];digest=None
    if render:
        rr,p=h.call('render',{'session':r['session'],'tier':'full','format':'rgba16'});assert rr['ok'],rr
        digest=hashlib.sha256(p).hexdigest()
    h.call('close',{'session':r['session']})
    return r,digest
try:
    cold,pixels=opened(doc,True)
    assert [s['bitmap_reused'] for s in cold['pair']['sources']]==[False,False]
    for side,s in zip(['left','right'],cold['pair']['sources']):doc[side].update(meteredEV=s['metered_ev'],meteredFor=s['metered_for'])
    warm,again=opened(doc,True)
    assert pixels==again,'warm RAW bitmap changed rendered pixels'
    assert all(s['bitmap_reused'] and s['meter_reused'] for s in warm['pair']['sources'])
    moved=copy.deepcopy(doc);moved['left']['placement']={'scale':1.2,'x':.4,'y':-.2,'quarterTurns':0}
    last,_=opened(moved)
    assert [s['bitmap_reused'] for s in last['pair']['sources']]==[False,True]
    assert all(s['meter_reused'] for s in last['pair']['sources'])
    memory,_=h.call('memory_report');assert memory['ok'],memory
    report={'output':str(out),'raw_sha256':original,'cold_decode_ms':cold['timings_ms']['decode'],
        'warm_decode_ms':warm['timings_ms']['decode'],'one_changed_hole_decode_ms':last['timings_ms']['decode'],
        'full_pixel_sha256':pixels,'cache':memory['result']['pair_bitmap_cache'],
        'note':'same authorised RAW twice; actual native input/engine cache, not GUI click acceptance or a repeated performance benchmark'}
    (out/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report))
    assert hashlib.sha256(raw.read_bytes()).hexdigest()==original,'RAW changed'
finally:
    if h.p.poll() is None:h.p.stdin.close();h.p.wait(timeout=30)
