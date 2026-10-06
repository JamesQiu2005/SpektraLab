"""The wire `camera_filter` on the worktree engine: agrees with the baked profile variants, re-develops in a
live session, and leaves the Film Edge alone. Run with the REF venv python."""
import sys, os, numpy as np
from pathlib import Path
from PIL import Image
WT=Path('/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/.claude/worktrees/bw-tri-x'); H=Path(__file__).resolve().parent
sys.path.insert(0,str(WT/'engine/tests')); from spk_ctypes import Engine
img=np.ascontiguousarray(np.load(H.parent/'renders_in'/'R0030139.npy')) if (H.parent/'renders_in'/'R0030139.npy').exists() else None
if img is None:
    sys.path.insert(0,'/Volumes/Hanze_Qiu/Documents/Summer 2026/spektrafilm/src'); from spektrafilm.utils.io import load_image_oiio
    img=np.ascontiguousarray(np.asarray(load_image_oiio('/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/tests/Test_image/_smoke_1mp.tif'),dtype=np.float32)[...,:3])
B=dict(input_color_space='ProPhoto RGB',input_cctf_decoding=False,auto_exposure=True,film_stock='kodak_tri_x_400',digital_intermediate=True,grain_active=False)
def f8(r): return (r[...,:3]>>8).astype(int)
with Engine(dylib=WT/'engine/build/libspektrafilm_engine.dylib',resources=H/'res') as e:
    def run(d):
        with e.open(img,{**B,**d}) as s: return f8(s.render('full')[0])
    none=run({})
    for w in ('w8','w21','w25','w58','w47'):
        wire=run({'camera_filter':w}); baked=run({'film_stock':'kodak_tri_x_400_'+w})
        print(f'{w}: wire vs baked max|d| {np.abs(wire-baked).max()}  | wire vs no filter mean|d| {np.abs(wire-none).mean():.2f} max {np.abs(wire-none).max()}')
    try: run({'camera_filter':'w99'}); print('FAIL: unknown filter accepted')
    except Exception as ex: print('unknown filter refused:',str(ex)[:90])
    with e.open(img,B) as s:
        a=f8(s.render('full')[0]); s.set_params({'camera_filter':'w25'}); b=f8(s.render('full')[0]); s.set_params({'camera_filter':''}); c=f8(s.render('full')[0])
        print('live session: set w25 changes picture mean|d| %.2f; equals fresh w25: %s; cleared returns: %s'%(np.abs(a-b).mean(),np.abs(b-run({'camera_filter':'w25'})).max()==0,np.abs(a-c).max()==0))
    # colour stock: cast kept
    p=run({'film_stock':'kodak_portra_400','digital_intermediate':False,'camera_filter':'w8'}); q=run({'film_stock':'kodak_portra_400','digital_intermediate':False})
    print('Portra + w8 mean RGB',p.mean((0,1)).round(1),'vs none',q.mean((0,1)).round(1))
    # Film Edge
    for fmt in sys.argv[1:] or ['135']:
        O=dict(overscan_active=True,overscan_format=fmt,overscan_edge_text='KODAK 400TX',overscan_frame_number=15,digital_intermediate=False,scan_film=True)
        outs={}
        im=img
        if fmt=='120_645':
            h=img.shape[0]; wd=int(round(h*41.5/56)); x0=(img.shape[1]-wd)//2; im=np.ascontiguousarray(img[:, x0:x0+wd]) if wd<=img.shape[1] else np.ascontiguousarray(img[:int(img.shape[1]*56/41.5)])
        for w in ('','w25'):
            with e.open(im,{**B,**O,'camera_filter':w}) as s: r=s.render('full')[0]
            outs[w]=f8(r); Image.fromarray(outs[w].astype(np.uint8)).save(H/f'edge_{fmt}_{w or "none"}.png')
        a,b=outs[''],outs['w25']; d=np.abs(a-b).max(2); h,w_=d.shape; m=int(w_*0.05)
        print(fmt,a.shape,'filter changes: left edge band max',d[:,:m].max(),'right edge band max',d[:,-m:].max(),'| picture centre mean',d[h//3:2*h//3,w_//3:2*w_//3].mean().round(2),'| chan spread whole frame',np.abs(a-a[...,1:2]).max())
