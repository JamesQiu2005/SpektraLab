import os,sys,numpy as np
from PIL import Image
sys.path.insert(0,'/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/engine/tests'); from spk_ctypes import Engine
H=os.path.dirname(os.path.abspath(__file__)); a=np.load(H+'/_DSC2439.npy'); img=np.ascontiguousarray(a[250:650,250:650]); img=np.ascontiguousarray(np.kron(img,np.ones((2,2,1),np.float32)))
dy=os.environ.get('DYLIB'); ex=eval(os.environ.get('EXTRA','{}'))
with (Engine(dylib=__import__('pathlib').Path(dy),resources=H+'/res') if dy else Engine(resources=H+'/res')) as e:
    p=dict(input_color_space='ProPhoto RGB',input_cctf_decoding=False,auto_exposure=True,film_stock='kodak_tri_x_400',film_format_mm=800*0.006,digital_intermediate=True,**ex)
    with e.open(img,p) as s: rgba,_=s.render('full')
    g=(rgba[...,:3]>>8).astype(np.uint8); Image.fromarray(g).save(H+'/grain_'+sys.argv[1]+'.png'); print(sys.argv[1],'std in flat bg patch',g[20:120,20:120,1].std().round(2))
