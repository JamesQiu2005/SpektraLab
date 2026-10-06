"""Load the Tri-X profile (and baked filter variants) through the built engine from a scratch resources copy.
Run: SPEKTRAFILM_ENGINE_RESOURCES=$PWD/resources PYTHONPATH="$REF/src:<repo>/engine/tests" python render_test.py"""
import os, sys, json, numpy as np
from PIL import Image
from spk_ctypes import Engine
S=os.path.dirname(os.path.abspath(__file__)); REPO='/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify'
def save(rgba,name): Image.fromarray((rgba[...,:3]>>8).astype(np.uint8)).save(S+'/renders/'+name+'.png')
# colour chart, linear values in the session's input space
PATCH={'grey18':(.184,.184,.184),'white':(.9,.9,.9),'black':(.02,.02,.02),'red':(.45,.04,.03),'yellow':(.6,.5,.05),'green':(.08,.25,.06),
       'sky':(.15,.28,.55),'blue':(.03,.05,.35),'skin':(.42,.27,.2)}
names=list(PATCH); P=96
chart=np.zeros((P,P*len(names),3),np.float32)
for i,n in enumerate(names): chart[:,i*P:(i+1)*P]=PATCH[n]
def patches(rgba):
    v=rgba[...,:3].astype(float)/65535
    return np.array([v[16:-16,i*P+16:(i+1)*P-16].mean((0,1)) for i in range(len(names))])
QUIET={"grain_active":False,"glare_active":False,"halation_active":False,"input_cctf_decoding":False,"dir_couplers_active":False}
out=[]
with Engine() as e:
    print('engine',e.build_info,'resources',e._resources)
    def run(img,delta,tier='full'):
        with e.open(img,delta) as s:
            rgba,_=s.render(tier); return rgba,s.reply
    # 1. does it load and render, per output path
    for label,d in [('print_default',{}),('scan_film',{"scan_film":True}),('digital_intermediate',{"digital_intermediate":True})]:
        try:
            rgba,reply=run(chart,{**QUIET,"auto_exposure":False,"film_stock":"kodak_tri_x_400",**d})
            p=patches(rgba); print('OK  %-22s print_stock=%s  grey18 RGB=%s  max|chan-G| over patches=%.4f'%(label,reply['params'].get('print_stock'),np.round(p[0],4),np.abs(p-p[:,1:2]).max()))
            save(rgba,'chart_trix_'+label); 
            if label=='print_default': print('   resolved:',{k:reply['params'].get(k) for k in ('input_color_space','c_filter_neutral','m_filter_neutral','y_filter_neutral','enlarger_illuminant','print_exposure')}); 
        except Exception as ex: print('FAIL',label,ex)
    for k in reply:
        if k!='params': print('  reply.%s: %s'%(k,str(reply[k])[:300]))
    # 2. filters on the chart (print path), AE off: metered variants and one raw variant
    rows=[]
    base,_=run(chart,{**QUIET,"auto_exposure":False,"film_stock":"kodak_tri_x_400"}); b=patches(base)[:,1]
    for st in ['kodak_tri_x_400']+['kodak_tri_x_400_w%s'%w for w in ('8','15','21','25','11','58','47')]+['kodak_tri_x_400_w25raw','kodak_tri_x_400_w8raw']:
        for ae in (False,True):
            try:
                rgba,reply=run(chart,{**QUIET,"auto_exposure":ae,"film_stock":st}); g=patches(rgba)[:,1]
                rows.append((st,ae,g)); save(rgba,'chart_%s_ae%d'%(st,ae))
            except Exception as ex: print('FAIL',st,ex)
    hdr='stock,auto_exposure,'+','.join(names); lines=[hdr]+['%s,%d,'%(st,ae)+','.join('%.4f'%v for v in g) for st,ae,g in rows]
    open(S+'/csv/render_patches.csv','w').write('\n'.join(lines)+'\n'); print('\n'.join(lines))
    # 3. the 1 MP frame
    from spektrafilm.utils.io import load_image_oiio
    frame=np.ascontiguousarray(np.asarray(load_image_oiio(REPO+'/tests/Test_image/_smoke_1mp.tif'),dtype=np.float32)[...,:3])
    for st in ['kodak_portra_400','kodak_tri_x_400','kodak_tri_x_400_w8','kodak_tri_x_400_w25','kodak_tri_x_400_w58','kodak_tri_x_400_w47']:
        try:
            rgba,reply=run(frame,{"film_stock":st}); v=rgba[...,:3].astype(float)/65535
            print('frame %-26s %s mean RGB %s  mean|R-G| %.4f mean|B-G| %.4f'%(st,rgba.shape,np.round(v.mean((0,1)),4),np.abs(v[...,0]-v[...,1]).mean(),np.abs(v[...,2]-v[...,1]).mean())); save(rgba,'frame_'+st)
        except Exception as ex: print('FAIL frame',st,ex)
    try:
        rgba,_=run(frame,{"film_stock":"kodak_tri_x_400","scan_film":True}); save(rgba,'frame_kodak_tri_x_400_scan_film')
    except Exception as ex: print('FAIL scan',ex)
