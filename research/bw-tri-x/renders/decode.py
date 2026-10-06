import rawpy, numpy as np, sys, glob, os
from PIL import Image
T='/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify/tests/Test_image/'
files=sorted(glob.glob(T+'Nikon Z7ii/*.NEF')+glob.glob(T+'A7m3/*.ARW')+glob.glob(T+'A7RV/*.ARW')+glob.glob(T+'DNG RAW/*.DNG'))
thumbs=[]
for f in files:
    n=os.path.splitext(os.path.basename(f))[0]
    try: r=rawpy.imread(f)
    except Exception as ex: print("skip",n,ex); continue
    if 1:
        try: a=r.postprocess(gamma=(1,1),no_auto_bright=True,output_bps=16,output_color=rawpy.ColorSpace.ProPhoto,use_camera_wb=True,half_size=True)
        except Exception as ex: print("skip",n,ex); continue
    a=a.astype(np.float32)/65535
    h,w=a.shape[:2]; k=max(1,int(np.ceil(max(h,w)/1800)))
    a=a[:h//k*k,:w//k*k].reshape(h//k,k,w//k,k,3).mean((1,3))
    np.save(n+'.npy',a)
    t=Image.fromarray((np.clip(a*2,0,1)**(1/2.2)*255).astype(np.uint8)); t.thumbnail((400,400)); thumbs.append((n,t)); print(n,a.shape)
W=sum(t.width for _,t in thumbs); sheet=Image.new('RGB',(W,400)); x=0
for n,t in thumbs: sheet.paste(t,(x,0)); x+=t.width
sheet.save('inputs.png'); print([n for n,_ in thumbs])
