"""Final Tri-X renders on local test images. DI path (neutral positive). Env: DYLIB optional."""
import os, sys, numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0,'/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/engine/tests')
from spk_ctypes import Engine
H=os.path.dirname(os.path.abspath(__file__)); tag=sys.argv[1] if len(sys.argv)>1 else 'default'
IM=['smoke','R0030139','_DSC2439','_DSC2704','_DSC2715']
FILT=[('colour: Portra 400 print','kodak_portra_400',{}),('Tri-X, no filter','kodak_tri_x_400',{}),('W8 yellow','kodak_tri_x_400_w8',{}),('W21 orange','kodak_tri_x_400_w21',{}),('W25 red','kodak_tri_x_400_w25',{}),('W58 green','kodak_tri_x_400_w58',{}),('W47 blue','kodak_tri_x_400_w47',{})]
def load(n):
    if n=='smoke':
        sys.path.insert(0,'/Volumes/Hanze_Qiu/Documents/Summer 2026/spektrafilm/src')
        from spektrafilm.utils.io import load_image_oiio
        return np.ascontiguousarray(np.asarray(load_image_oiio('/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/tests/Test_image/_smoke_1mp.tif'),dtype=np.float32)[...,:3])
    return np.ascontiguousarray(np.load(H+'/'+n+'.npy'))
extra=eval(os.environ.get('EXTRA','{}'))
dy=os.environ.get('DYLIB')
with (Engine(dylib=__import__('pathlib').Path(dy),resources=H+'/res') if dy else Engine(resources=H+'/res')) as e:
    for n in IM:
        img=load(n); tiles=[]
        for label,st,d in FILT:
            p=dict(input_color_space='ProPhoto RGB',input_cctf_decoding=False,auto_exposure=True,film_stock=st,film_format_mm=35.0)
            if st!='kodak_portra_400': p.update(**(dict(digital_intermediate=True) if not os.environ.get('PAPER') else dict(print_stock=os.environ['PAPER'],m_filter_neutral=float(os.environ.get('M',20)),y_filter_neutral=float(os.environ.get('Y',60)),c_filter_neutral=0.0)),**extra)
            p.update(d)
            with e.open(img,p) as s: rgba,_=s.render('full')
            a=(rgba[...,:3]>>8).astype(np.uint8)
            if st!='kodak_portra_400': print(n,label,'max chan spread',int(np.abs(a.astype(int)-a[...,1:2]).max()),'mean',a.mean().round(1))
            t=Image.fromarray(a); 
            if label=='Tri-X, no filter': t.save(f'{H}/out_{tag}_{n}_trix.png')
            t.thumbnail((640,640)); ImageDraw.Draw(t).text((8,8),label,fill=(255,255,0)); tiles.append(t)
        W=sum(t.width for t in tiles); sh=Image.new('RGB',(W,tiles[0].height)); x=0
        for t in tiles: sh.paste(t,(x,0)); x+=t.width
        sh.save(f'{H}/sheet_{tag}_{n}.png')
