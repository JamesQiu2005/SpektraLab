"""End to end on the worktree engine: Tri-X 400 + wire camera_filter + Ilford MGIV RC (filter 2) on local images."""
import sys, os, json, glob, numpy as np, rawpy
from pathlib import Path
from PIL import Image, ImageDraw
WT=Path('/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/.claude/worktrees/bw-tri-x'); H=Path(__file__).resolve().parent
sys.path.insert(0,str(WT/'engine/tests')); from spk_ctypes import Engine
T='/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/tests/Test_image/'
def raw(f):
    with rawpy.imread(f) as r: a=r.postprocess(gamma=(1,1),no_auto_bright=True,output_bps=16,output_color=rawpy.ColorSpace.ProPhoto,use_camera_wb=True,half_size=True).astype(np.float32)/65535
    h,w=a.shape[:2]; k=max(1,int(np.ceil(max(h,w)/1500))); return np.ascontiguousarray(a[:h//k*k,:w//k*k].reshape(h//k,k,w//k,k,3).mean((1,3)))
IM={'R0030139':T+'DNG RAW/R0030139.DNG','_DSC2439':T+'Nikon Z7ii/_DSC2439.NEF','_DSC2704':T+'Nikon Z7ii/_DSC2704.NEF','_DSC2715':T+'Nikon Z7ii/_DSC2715.NEF'}
res=H/'res'; os.system(f'cp "{H.parent}/paper/ilford_multigrade_iv_rc.json" "{res}/profiles/"')
B=dict(input_color_space='ProPhoto RGB',input_cctf_decoding=False,auto_exposure=True,film_stock='kodak_tri_x_400',print_stock='ilford_multigrade_iv_rc',c_filter_neutral=0.0,m_filter_neutral=0.0,y_filter_neutral=68.0,dir_couplers_amount=0.4)
with Engine(dylib=WT/'engine/build/libspektrafilm_engine.dylib',resources=res) as e:
    for n,f in IM.items():
        img=raw(f); tiles=[]
        for lab,d in [('Portra 400 / Endura',dict(film_stock='kodak_portra_400',print_stock='kodak_portra_endura',dir_couplers_amount=1.0,m_filter_neutral=None)),('Tri-X / MGIV filter 2',{}),('+ W8 yellow',dict(camera_filter='w8')),('+ W21 orange',dict(camera_filter='w21')),('+ W25 red',dict(camera_filter='w25')),('+ W58 green',dict(camera_filter='w58')),('+ W47 blue',dict(camera_filter='w47'))]:
            p={**B,**d}
            if p.get('m_filter_neutral') is None: [p.pop(k) for k in ('c_filter_neutral','m_filter_neutral','y_filter_neutral')]
            with e.open(img,p) as s: a=(s.render('full')[0][...,:3]>>8).astype(np.uint8)
            if 'Portra' not in lab: print(n,lab,'spread',int(np.abs(a.astype(int)-a[...,1:2]).max()),'mean',a.mean().round(1))
            t=Image.fromarray(a); t.thumbnail((560,560)); ImageDraw.Draw(t).text((8,8),lab,fill=(255,255,0)); tiles.append(t)
        sh=Image.new('RGB',(sum(t.width for t in tiles),tiles[0].height)); x=0
        for t in tiles: sh.paste(t,(x,0)); x+=t.width
        sh.save(H/f'e2e_{n}.png')
    # print with the film edge, 135
    img=raw(IM['_DSC2715'])
    with e.open(img,{**B,'camera_filter':'w21','overscan_active':True,'overscan_format':'135','overscan_edge_text':'KODAK 400TX','overscan_frame_number':15}) as s:
        Image.fromarray((s.render('full')[0][...,:3]>>8).astype(np.uint8)).save(H/'e2e_edge_135_print.png')
