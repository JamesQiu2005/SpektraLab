"""Real Vulkan print-layer transactions; public synthetic pixels, no mock."""
import argparse,json,tempfile
from pathlib import Path
import numpy as np,tifffile
from host_smoke import Host
ap=argparse.ArgumentParser();ap.add_argument('--host',type=Path,required=True);ap.add_argument('--resources',type=Path,required=True);args=ap.parse_args()
out=Path(tempfile.mkdtemp(prefix='spk-pair-layers-'))
y,x=np.mgrid[:120,:180];v=(.03+x/500+y/600).astype('float32')
for name,gain in [('a',1),('b',.6)]:tifffile.imwrite(out/(name+'.tif'),np.stack([v,v*.8,v*.5],-1)*np.float32(gain),photometric='rgb')
doc={'folder':str(out),'schemaVersion':1,'left':{'path':str(out/'a.tif'),'autoExposure':False,'print':{'brightnessStops':.5}},'right':{'path':str(out/'b.tif'),'autoExposure':False}}
pair=out/'layers.spektrapair';pair.write_text(json.dumps(doc),encoding='utf-8')
h=Host([str(args.host.resolve()),'--resources',str(args.resources.resolve())])
def call(method,params):
    r,p=h.call(method,params);assert r['ok'],(method,r);return r['result'],p
try:
    base={'grain_active':False,'halation_active':False,'glare_active':False,'auto_exposure':False,'preview_long_edge':800}
    refused,_=h.call('open',{'path':str(pair),'params':base});assert not refused['ok'] and refused['error']['code']=='unsupported'
    r,_=call('open',{'path':str(pair),'params':base,'pair_presentation':'client'});sid=r['session']
    before,_=call('get_params',{'session':sid})
    raw,pixels=call('render',{'session':sid,'tier':'full','format':'rgba16'})
    layer,p2=call('render_layer',{'session':sid,'tier':'full','format':'rgba16','delta':{'print_exposure':2}})
    assert layer['reprinted'] and layer['image']==raw['image'] and p2!=pixels
    after,_=call('get_params',{'session':sid});assert before==after,'print layer leaked its temporary params'
    _,again=call('render',{'session':sid,'tier':'full','format':'rgba16'});assert again==pixels,'base print changed after layer'
    for delta,fmt in [({'film_stock':'kodak_gold_200'},'rgba16'),({'print_exposure':2},'bad-format')]:
        failed,_=h.call('render_layer',{'session':sid,'tier':'full','format':fmt,'delta':delta});assert not failed['ok']
        after,_=call('get_params',{'session':sid});assert after==before,'failed layer did not restore params'
    failed,_=h.call('export_image',{'session':sid,'path':str(out/'must-not-exist.png'),'format':'png'})
    assert not failed['ok'] and failed['error']['code']=='unsupported' and not (out/'must-not-exist.png').exists()
    print(json.dumps({'output':str(out),'bytes':len(pixels),'different_components':int(np.count_nonzero(np.frombuffer(pixels,np.uint16)!=np.frombuffer(p2,np.uint16)))}))
    print('ok: native print layers reprint one negative, restore on success/failure, require client presentation')
finally:
    if h.p.poll() is None:h.p.stdin.close();h.p.wait(timeout=20)
