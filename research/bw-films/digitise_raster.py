"""Acros II (AF3-0258E p3) and HP5 Plus (Nov 2018, p1 + p5): the charts are raster images in the PDFs.
Rendered at 600 dpi (pdftocairo -png -gray -r 600) and traced. Writes csv/ and out/trace_*.png overlays."""
import os, numpy as np
from rastertrace import *
from PIL import Image, ImageDraw
S=os.path.dirname(os.path.abspath(__file__)); s=600/110
def box(a,b,c,d): return (int(s*a),int(s*b),int(s*c),int(s*d))
def mid(g): return [(a+b)/2 for a,b in g]
resid=[]
def overlay(name,path,bx,curves):
    im=Image.open(path).convert('RGB').crop(bx); d=ImageDraw.Draw(im)
    for xs,ys in curves:
        for x,y in zip(xs[::6],ys[::6]): d.ellipse((x-2,y-2,x+2,y+2),fill=(255,0,0))
    im.save(S+'/out/trace_%s.png'%name)
def seeds(m,x,cols,rows,min_th=3):
    gr=np.zeros(m.shape[0],bool)
    for a,b in rows: gr[a-1:b+2]=True
    return [(a+b)/2 for a,b in runs(m[:,x]) if b-a+1>=min_th and not gr[a:b+1].all()]

# ---------------- Acros II, D-76 characteristic curves (4, 7, 10 min)
P=S+'/pdf/acros600-3.png'; bx=box(520,500,810,690); m=load(P,bx); cols,rows=gridlines(m,0.5)
fx,rx,_=axis(mid(cols),np.arange(-3.5,1.01,0.5)); fy,ry,ky=axis(mid(rows),np.arange(3.0,-0.01,-0.5))
resid+=[('acros D-76 x (logH)',rx),('acros D-76 y (D)',ry)]
x0=int((cols[6][1]+cols[7][0])/2)                      # between -0.5 and 0.0: three separate curves, no labels
sd=sorted(seeds(m,x0,cols,rows)); assert len(sd)==3,sd
g=np.round(np.arange(-3.2,0.521,0.02),2); cols_out=[g]; ov=[]
for y0,t in zip(sd,(10,7,4)):
    xs,ys,th=trace(m,x0,y0,cols[0][0]-40,cols[-1][0]-6,cols,rows)
    ov.append((xs,ys)); X=fx(xs); Y=fy(ys); o=np.argsort(X)
    cols_out.append(np.interp(g,X[o],Y[o],left=np.nan,right=np.nan)); print('acros D-76 %2d min: logH %.3f..%.3f D %.3f..%.3f n=%d'%(t,X.min(),X.max(),Y.min(),Y.max(),len(xs)))
np.savetxt(S+'/csv/char_acros_D76.csv',np.array(cols_out).T,delimiter=',',fmt='%.4f',header='logH_lux_s,D_10min,D_7min,D_4min',comments='')
overlay('acros_char',P,bx,ov)

# ---------------- Acros II, spectrogram to daylight 5400 K (relative log)
bx=box(90,810,370,1050); m=load(P,bx); cols,rows=gridlines(m,0.5)
fx,rx,_=axis(mid(cols[1:5]),[400,500,600,700]); r=mid(rows)
fy=lambda p:(r[2]-np.asarray(p))/(r[2]-r[1])            # 0 on the lower line, 1.0 on the upper (the sheet's "1.0" bracket)
resid+=[('acros spectrogram x (nm)',rx)]
x0=int(mid(cols)[1]+60); sd=seeds(m,x0,cols,rows); assert len(sd)==1,sd
xs,ys,th=trace(m,x0,sd[0],cols[1][1]+3,cols[4][0]-3,cols,rows,max_jump=40)
# the cut-off near 650 nm is nearly vertical: there a column holds one tall run; take its lower end going down
X=fx(xs); Y=fy(ys); print('acros spectrogram: %.1f..%.1f nm, log %.3f..%.3f, n=%d, thickest run %d px'%(X.min(),X.max(),Y.min(),Y.max(),len(xs),th.max()))
np.savetxt(S+'/csv/spectral_acros_raw.csv',np.c_[X,Y,th],delimiter=',',fmt='%.4f',header='wavelength_nm,relative_log_response_to_5400K (0 = lower line, 1 = upper),run_px',comments='')
overlay('acros_spec',P,bx,[(xs,ys)])

# ---------------- HP5 Plus, characteristic curve (ILFOTEC HC 1+31, 6.5 min), relative log exposure
P=S+'/pdf/hp5_600-5.png'; bx=box(80,125,362,325); m=load(P,bx); cols,rows=gridlines(m,0.5)
fx,rx,_=axis(mid(cols),np.arange(0,4.51,0.5)); fy,ry,_=axis(mid(rows),np.arange(3.0,-0.01,-0.5)); resid+=[('hp5 x (rel logE)',rx),('hp5 y (D)',ry)]
x0=int((cols[5][1]+cols[6][0])/2); sd=seeds(m,x0,cols,rows,6); assert len(sd)==1,sd
xs,ys,th=trace(m,x0,sd[0],cols[0][1]+3,cols[-1][0]-3,cols,rows,max_jump=20,min_th=6)
X=fx(xs); Y=fy(ys); g=np.round(np.arange(0.04,4.101,0.02),2); o=np.argsort(X)
print('hp5 curve: rel logE %.3f..%.3f D %.3f..%.3f n=%d'%(X.min(),X.max(),Y.min(),Y.max(),len(xs)))
np.savetxt(S+'/csv/char_hp5_ILFOTEC_HC.csv',np.c_[g,np.interp(g,X[o],Y[o],left=np.nan,right=np.nan)],delimiter=',',fmt='%.4f',header='relative_log_exposure,D',comments='')
overlay('hp5_char',P,bx,[(xs,ys)])

# ---------------- HP5 Plus, wedge spectrogram to tungsten 2850 K
P=S+'/pdf/hp5_600-1.png'; bx=box(85,870,400,1015); m=load(P,bx); cols,rows=gridlines(m,0.5)
bot=rows[1]; right=cols[1]
tx=mid(groups(np.where(m[bot[1]+12,:right[0]])[0])); ty=mid(groups(np.where(m[:bot[0]-5,right[1]+12])[0]))
print('hp5 spectrogram ticks x',np.round(tx,1),'y',np.round(ty,1),'bottom',mid([bot]))
fx,rx,_=axis(tx,[400,450,500,550,600,650]); fy,ry,_=axis(ty+mid([bot]),[1.0,0.5,0.0]); resid+=[('hp5 spectrogram x (nm)',rx),('hp5 spectrogram y',ry)]
x0=int(tx[2]); sd=[v for v in seeds(m,x0,cols,rows,6) if v<bot[0]]; assert len(sd)==1,sd
xs,ys,th=trace(m,x0,sd[0],cols[0][1]+3,right[0]-3,cols,rows,max_jump=60,min_th=6)
X=fx(xs); Y=fy(ys); print('hp5 spectrogram: %.1f..%.1f nm, %.3f..%.3f, n=%d'%(X.min(),X.max(),Y.min(),Y.max(),len(xs)))
np.savetxt(S+'/csv/spectral_hp5_raw.csv',np.c_[X,Y,th],delimiter=',',fmt='%.4f',header='wavelength_nm,wedge_height (sheet axis "Sensitivity", 0..1),run_px',comments='')
overlay('hp5_spec',P,bx,[(xs,ys)])
with open(S+'/csv/axis_residuals_raster.csv','w') as f:
    f.write('axis,max_abs_residual\n')
    for n,r in resid: f.write('%s,%.5f\n'%(n,r)); print('AXIS %-28s max|res| %.4f'%(n,r))
