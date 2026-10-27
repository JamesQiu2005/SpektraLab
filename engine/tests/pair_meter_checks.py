"""Real native per-hole readings survive placement; no private images/mock."""
import argparse,copy,json,tempfile,time
from pathlib import Path
import numpy as np,tifffile
from host_smoke import Host
ap=argparse.ArgumentParser();ap.add_argument('--host',type=Path,required=True);ap.add_argument('--resources',type=Path,required=True);args=ap.parse_args()
out=Path(tempfile.mkdtemp(prefix='spk-pair-meter-'))
y,x=np.mgrid[:100,:300];v=(.005*np.exp2(x/35)).astype('float32')
photo=out/'ramp.tif';tifffile.imwrite(photo,np.stack([v,v*.8,v*.5],-1),photometric='rgb')
doc={'schemaVersion':1,'folder':str(out),'left':{'path':str(photo),'autoExposure':True,'meterMethod':'balanced'},'right':None}
recipe=out/'meter.spektrapair'
h=Host([str(args.host.resolve()),'--resources',str(args.resources.resolve())])
def opened(d):
    recipe.write_text(json.dumps(d),encoding='utf-8')
    reply,_=h.call('open',{'path':str(recipe),'params':{'grain_active':False,'halation_active':False,'glare_active':False}})
    assert reply['ok'],reply
    r=reply['result'];h.call('close',{'session':r['session']})
    return r['pair']['sources'][0]
try:
    first=opened(doc)
    assert first.get('metered_for','').startswith('windows-pair-meter-v1:'),'missing persisted meter identity'
    assert not first.get('meter_reused',True),'first read cannot be reused'
    saved=copy.deepcopy(doc);saved['left'].update(meteredEV=first['metered_ev'],meteredFor=first['metered_for'])
    moved=copy.deepcopy(saved);moved['left']['placement']={'scale':2,'x':1,'y':0,'quarterTurns':0}
    again=opened(moved)
    assert again['meter_reused'] and again['metered_ev']==first['metered_ev'],'placement pumped exposure'
    assert again['metered_for']==first['metered_for']
    # A fresh reading of that bright crop really differs; reuse is meaningful.
    fresh=copy.deepcopy(moved);fresh['left'].pop('meteredFor');fresh['left'].pop('meteredEV')
    changed=opened(fresh)
    assert abs(changed['metered_ev']-first['metered_ev'])>.1,'fixture needs a different cropped meter'
    for field,value in [('meterMethod','protect_highlights'),('geometry',{'crop':[.1,0,.8,1]}),('decode',{'whiteBalance':'As Shot','temperature':3200,'tint':0})]:
        test=copy.deepcopy(saved);test['left'][field]=value
        r=opened(test);assert not r['meter_reused'] and r['metered_for']!=first['metered_for'],field
    # Corrupt values never become exposure gains.
    test=copy.deepcopy(saved);test['left']['meteredEV']=1e100
    r=opened(test);assert not r['meter_reused'] and abs(r['metered_ev'])<64
    # A modified source cannot inherit a reading for the old file.
    stamp=photo.stat().st_mtime_ns
    import os
    os.utime(photo,ns=(stamp+2_000_000_000,stamp+2_000_000_000))
    r=opened(saved);assert not r['meter_reused'] and r['metered_for']!=first['metered_for']
    print(json.dumps({'output':str(out),'original_ev':first['metered_ev'],'fresh_moved_ev':changed['metered_ev'],'reused_ev':again['metered_ev']}))
    print('ok: persisted per-hole meter, placement stability and decode/crop/method/source invalidation')
finally:
    if h.p.poll() is None:h.p.stdin.close();h.p.wait(timeout=20)
