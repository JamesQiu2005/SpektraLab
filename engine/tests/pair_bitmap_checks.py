"""Actual native pair bitmap reuse/invalidation with public float TIFFs."""
import argparse,copy,json,tempfile,os
from pathlib import Path
import numpy as np,tifffile
from host_smoke import Host
ap=argparse.ArgumentParser();ap.add_argument('--host',type=Path,required=True);ap.add_argument('--resources',type=Path,required=True);args=ap.parse_args()
out=Path(tempfile.mkdtemp(prefix='spk-pair-bitmaps-'))
y,x=np.mgrid[:100,:180];v=(.02+x/500+y/600).astype('float32')
for name,gain in [('a',1),('b',.7)]:tifffile.imwrite(out/(name+'.tif'),np.stack([v,v*.8,v*.5],-1)*np.float32(gain),photometric='rgb')
doc={'schemaVersion':1,'folder':str(out),'left':{'path':str(out/'a.tif'),'autoExposure':False},'right':{'path':str(out/'b.tif'),'autoExposure':False}}
recipe=out/'bitmaps.spektrapair'
h=Host([str(args.host.resolve()),'--resources',str(args.resources.resolve())])
def opened(d,render=False):
    recipe.write_text(json.dumps(d),encoding='utf-8')
    r,_=h.call('open',{'path':str(recipe),'params':{'grain_active':False,'halation_active':False,'glare_active':False}});assert r['ok'],r
    r=r['result'];pixels=None
    if render:
        rr,pixels=h.call('render',{'session':r['session'],'tier':'full','format':'rgba16'});assert rr['ok'],rr
    h.call('close',{'session':r['session']})
    return [s.get('bitmap_reused') for s in r['pair']['sources']],pixels
try:
    first,cold=opened(doc,True);assert first==[False,False],'missing native cold-cache status'
    warm,again=opened(doc,True);assert warm==[True,True] and cold==again,'warm cache changed engine pixels'
    gap=copy.deepcopy(doc);gap['spacingMM']=2
    assert opened(gap)[0]==[True,True],'gap should reuse both hole bitmaps'
    trim=copy.deepcopy(doc);trim['left']['exposureEV']=1
    assert opened(trim)[0]==[True,True],'exposure trim should not decode'
    for patch in [{'placement':{'scale':2,'x':1}}, {'geometry':{'crop':[.1,0,.8,1]}}, {'decode':{'whiteBalance':'As Shot','temperature':3200}}]:
        changed=copy.deepcopy(doc);changed['left'].update(patch)
        assert opened(changed)[0]==[False,True],patch
    changed=copy.deepcopy(doc);changed['turned']=True
    assert opened(changed)[0]==[False,False],'turned geometry needs new hole sizes/aspect'
    opened(doc)
    stamp=(out/'a.tif').stat().st_mtime_ns;os.utime(out/'a.tif',ns=(stamp+2_000_000_000,stamp+2_000_000_000))
    assert opened(doc)[0]==[False,True],'modified source must invalidate only its own bitmap'
    rr,_=h.call('memory_report');assert rr['ok'],rr
    cache=rr['result']['pair_bitmap_cache']
    assert cache['entries']<=3 and cache['bytes']<=192*1024*1024 and cache['limit_bytes']==192*1024*1024,cache
    print(json.dumps({'output':str(out),'pixel_bytes':len(cold),'cache':cache}))
    print('ok: native hole bitmap LRU reuse, byte/count bounds, pixel equality and input invalidation')
finally:
    if h.p.poll() is None:h.p.stdin.close();h.p.wait(timeout=20)
