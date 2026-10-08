"""Render each new film's edge print through the built engine (scan_film, shown inverted, as the owner's
strips are). Run from the repo root with the reference venv's python:  python research/bw-films/edge/render_edge.py"""
import os, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[3]; ENGINE=ROOT/'engine'; OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(ENGINE/'tests'))
import spk_ctypes as spk
def overlay(tmp):
    res=Path(tmp)/'resources'; (res/'profiles').mkdir(parents=True)
    for f in (ENGINE/'resources').iterdir():
        if f.name!='profiles': os.symlink(f,res/f.name)
    for d in (ENGINE/'resources'/'profiles',ENGINE/'resources_product'/'profiles'):
        for f in d.glob('*.json'): os.symlink(f,res/'profiles'/f.name)
    return res
QUIET={"grain_active":False,"glare_active":False,"halation_active":False,"dir_couplers_active":False,"auto_exposure":False,
       "input_cctf_decoding":False,"input_color_space":"sRGB","output_color_space":"sRGB","output_cctf_encoding":True,
       "print_stock":"ilford_multigrade_iv_rc","scan_film":True,"overscan_active":True,"overscan_camera_seed":3,"overscan_frame_seed":5}
FILMS={'kodak_tmax_100':('KODAK 100TMX',7),'fujifilm_neopan_acros_100_ii':('FUJI 100 ACROS II',1),'ilford_hp5_plus_400':('ILFORD HP5 PLUS',12),'kodak_tri_x_400':('KODAK 400TX',15)}
def pic(w,h):
    y,x=np.mgrid[0:h,0:w]; return (0.04+0.5*(x/w)[...,None]*np.ones(3)+0.25*(y/h)[...,None]).astype(np.float32)
if __name__=='__main__':
    only=sys.argv[1:] 
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(resources=overlay(tmp)) as e:
        for st,(txt,n) in FILMS.items():
            if only and st not in only: continue
            for fmt,(w,h) in {'135':(1800,1200),'120_6x6':(1200,1200)}.items():
                s=e.open(pic(w,h),{**QUIET,"film_stock":st,"overscan_format":fmt,"overscan_edge_text":txt,"overscan_frame_number":n})
                try: rgba,_=s.render('full')
                finally: s.close()
                a=255-(rgba[...,:3].astype(np.float64)/257).astype(np.uint8)
                Image.fromarray(a).save(OUT/('render_%s_%s.png'%(st,fmt))); print(st,fmt,a.shape)
