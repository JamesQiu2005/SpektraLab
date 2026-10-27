"""Product B&W resources through the real host, Vulkan and file encoders."""
import argparse,json,tempfile,hashlib
from pathlib import Path
import numpy as np,tifffile
from PIL import Image
from host_smoke import Host
ap=argparse.ArgumentParser();ap.add_argument('--host',type=Path,required=True);ap.add_argument('--resources',type=Path,required=True);args=ap.parse_args()
out=Path(tempfile.mkdtemp(prefix='spk-bw-host-'));source=out/'colour.tif'
y,x=np.mgrid[:100,:180];v=(.03+x/600+y/800).astype('float32')
tifffile.imwrite(source,np.stack([v,v*.6,v*.2],-1),photometric='rgb')
films=['kodak_tri_x_400','kodak_tmax_100','fujifilm_neopan_acros_100_ii','ilford_hp5_plus_400'];paper='ilford_multigrade_iv_rc'
h=Host([str(args.host.resolve()),'--resources',str(args.resources.resolve())]);proof=[]
def call(m,p):
    r,b=h.call(m,p);assert r['ok'],(m,r);return r['result'],b
try:
    for film in films:
        p={'film_stock':film,'print_stock':paper,'c_filter_neutral':0,'m_filter_neutral':0,'y_filter_neutral':68,
            'grain_active':False,'grain_sublayers_active':False,'halation_active':False,'glare_active':False,'auto_exposure':False}
        r,_=call('open',{'path':str(source),'params':p});sid=r['session']
        r,b=call('render',{'session':sid,'tier':'full','format':'rgba16','display':'srgb'})
        px=np.frombuffer(b,dtype='<u2').reshape(r['image']['height'],r['image']['width'],4)[...,:3]
        spread=int(np.max(np.max(px,2).astype('int32')-np.min(px,2)))
        assert spread/65535<2e-3,(film,spread)
        for ext,format in [('jpg','jpeg'),('png','png'),('tif','tiff16')]:
            f=out/(film+'.'+ext);call('export_image',{'session':sid,'path':str(f),'format':format,'output_color_space':'sRGB'})
            with Image.open(f) as im:
                im.load();assert im.size==(180,100) and len(im.info.get('icc_profile',b''))>100
                icc=len(im.info.get('icc_profile',b''))
            if ext=='tif':assert tifffile.imread(f).dtype==np.uint16
            proof.append({'film':film,'format':format,'path':str(f),'icc_bytes':icc,'channel_spread16':spread})
        # The engine's measured colour pack must be restored when returning.
        call('set_params',{'session':sid,'delta':{'film_stock':'kodak_portra_400','print_stock':'kodak_supra_endura'}})
        q,_=call('get_params',{'session':sid});assert q['params']['y_filter_neutral']!=68,q
        call('close',{'session':sid})
    result={'output':str(out),'files':proof,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'note':'real native host/Vulkan/encoders; no GUI acceptance claim'}
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');print(json.dumps(result))
finally:
    if h.p.poll() is None:h.p.stdin.close();h.p.wait(timeout=20)
