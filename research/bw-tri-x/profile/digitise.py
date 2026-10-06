"""Digitise F-4017 p7/p8 from the PDF's vector paths (pdftocairo -svg). Writes CSVs to ./csv."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from svgpaths import load
S=os.path.dirname(os.path.abspath(__file__)); os.makedirs(S+'/csv',exist_ok=True)
p7=load(S+'/pdf/p7.svg'); p8=load(S+'/pdf/p8.svg')
def stroked(ps): return [p for p in ps if p.get('stroke','none')!='none']
p7=stroked(p7); p8=stroked(p8)
def find(ps,xr,yr,minpts=4,dash='any'):
    out=[]
    for p in ps:
        a=p['pts']
        if len(a)<minpts: continue
        if a[:,0].min()<xr[0]-1 or a[:,0].max()>xr[1]+1 or a[:,1].min()<yr[0]-1 or a[:,1].max()>yr[1]+1: continue
        if dash!='any' and (p.get('stroke-dasharray') or '')[:6]!=dash[:6]: continue
        out.append(p)
    return out
def ticks(ps,xr,yr,vertical):
    """positions of 2-point tick/grid segments inside a box"""
    t=[]
    for p in ps:
        a=p['pts']
        if len(a)!=2: continue
        if a[:,0].min()<xr[0]-1 or a[:,0].max()>xr[1]+1 or a[:,1].min()<yr[0]-1 or a[:,1].max()>yr[1]+1: continue
        if vertical and abs(a[0,0]-a[1,0])<1e-3: t.append(a[0,0])
        if not vertical and abs(a[0,1]-a[1,1])<1e-3 and p.get('stroke-width','')[:5]=='0.432' and not p.get('stroke-dasharray'): t.append(a[0,1])
    return sorted(set(np.round(t,3)))
resid_rows=[]
def axis(name,pos,val):
    """least-squares linear axis; report residuals in data units"""
    pos=np.array(pos,float); val=np.array(val,float)
    A=np.c_[pos,np.ones_like(pos)]; (m,c),*_=np.linalg.lstsq(A,val,rcond=None)
    r=A@[m,c]-val
    resid_rows.append((name,len(pos),m,np.abs(r).max(),np.sqrt((r**2).mean())))
    return lambda p: m*np.asarray(p)+c
def curve(p,fx,fy):
    a=p['pts']; x=fx(a[:,0]); y=fy(a[:,1]); return x,y
def resample(x,y,grid):
    o=np.argsort(x,kind='stable'); x=x[o]; y=y[o]
    keep=np.r_[True,np.diff(x)>1e-9]; return np.interp(grid,x[keep],y[keep],left=np.nan,right=np.nan)

# ---------- spectral sensitivity (p7) ----------
fx=axis('spectral x (nm)',[86.9,107.0,127.1,147.2,167.3,187.4,207.5,227.5,247.6,267.7,287.4],np.arange(250,751,50))
fy=axis('spectral y (logS)',[291.7,329.5,367.3,405.1,443.0],[4,3,2,1,0])
c=find(p7,(100,260),(330,444),minpts=50)
assert len(c)==2
sol=[p for p in c if not p.get('stroke-dasharray')][0]; das=[p for p in c if p.get('stroke-dasharray')][0]
g=np.arange(300,671,5.0)
xs,ys=curve(sol,fx,fy); xd,yd=curve(das,fx,fy)
print('spectral solid(D=1.0?) x %.1f..%.1f y %.2f..%.2f ; dashed x %.1f..%.1f y %.2f..%.2f'%(xs.min(),xs.max(),ys.min(),ys.max(),xd.min(),xd.max(),yd.min(),yd.max()))
np.savetxt(S+'/csv/spectral_raw_solid.csv',np.c_[xs,ys],delimiter=',',header='wavelength_nm,log_sensitivity (solid line, flattened vector path)',comments='')
np.savetxt(S+'/csv/spectral_raw_dashed.csv',np.c_[xd,yd],delimiter=',',header='wavelength_nm,log_sensitivity (dashed line, flattened vector path)',comments='')
# the curves turn vertical near 650-660: resample on wavelength where single valued
np.savetxt(S+'/csv/spectral_sensitivity_5nm.csv',np.c_[g,resample(xs,ys,g),resample(xd,yd,g)],delimiter=',',fmt='%.4f',
           header='wavelength_nm,logS_solid,logS_dashed  (log10 of 1/(erg/cm^2); see REPORT for which density each line is)',comments='')

# ---------- characteristic curves ----------
def char(ps,xr,yr,name,xt,xv,yt,yv,times):
    fx=axis(name+' x (logH)',xt,xv); fy=axis(name+' y (D)',yt,yv)
    cs=find(ps,xr,yr,minpts=40)
    key={'':0,'3.2394':1,'6.4789':2,'16.197':3}
    cs=sorted(cs,key=lambda p:key[(p.get('stroke-dasharray') or '').split(' ')[0]])
    assert len(cs)==4,len(cs)
    g=np.round(np.arange(-3.44,0.3401,0.02),2); cols=[g]
    for p,t in zip(cs,times):
        x,y=curve(p,fx,fy); cols.append(resample(x,y,g))
        print(name,t,'min: logH %.3f..%.3f D %.3f..%.3f'%(x.min(),x.max(),y.min(),y.max()))
    np.savetxt(S+'/csv/char_%s.csv'%name,np.array(cols).T,delimiter=',',fmt='%.4f',header='logH_lux_s,'+','.join('D_%gmin'%t for t in times),comments='')
char(p7,(380,530),(100,245),'400TX_135_TMAX',[366.4,403.3,440.2,477.1,514.0,550.9],[-4,-3,-2,-1,0,1],[254.0,207.9,161.7,115.6,69.5],[0,1,2,3,4],[6,7,9,11])
char(p7,(380,530),(370,512),'400TX_120_TMAX',[367.2,404.1,440.9,477.8,514.7,551.6],[-4,-3,-2,-1,0,1],[518.2,472.1,426.0,379.9,333.7],[0,1,2,3,4],[6,7,9,11])
char(p8,(95,245),(115,240),'400TX_135_D76',[81.4,118.3,155.2,192.1,229.0,265.8],[-4,-3,-2,-1,0,1],[248.0,201.9,155.7,109.6,63.5],[0,1,2,3,4],[6,8,10,12])
char(p8,(95,245),(385,506),'400TX_120_D76',[81.4,118.3,155.2,192.1,229.0,265.8],[-4,-3,-2,-1,0,1],[511.5,465.4,419.2,373.1,327.0],[0,1,2,3,4],[6,8,10,12])

# ---------- contrast index curves (p8) ----------
fx=axis('CI x (min)',[353.9,384.7,415.4,446.1,476.8,507.6,538.3],[0,5,10,15,20,25,30])
fy=axis('CI y',[255.5,224.7,194.0,163.2,132.5,101.7,71.0],[0,.2,.4,.6,.8,1.0,1.2])
names={69:'HC-110(B)',70:'T-MAX RS',71:'T-MAX',72:'D-76',73:'XTOL',74:'XTOL 1:1',75:'D-76 (1:1)'}
allp=[p for p in load(S+'/pdf/p8.svg') if p.get('stroke','none')!='none']
ci=find(allp,(370,470),(90,205),minpts=3)
# identify by legend dash pattern + stroke width
leg={('3.239 1','0.432'):'T-MAX',('','0.432'):'D-76',('6.478 3.239','0.432'):'D-76 (1:1)',('16.195 3.239 3.239 3.239','0.432'):'XTOL 1:1',
     ('6.478 3.239','0.72'):'HC-110 (B)',('16.195 3.239 3.239 3.239 3.239 3.239','0.432'):'T-MAX RS',('6.478 3.239 0.99969 3.239','0.432'):'XTOL'}
rows=[]
for p in ci:
    d=(p.get('stroke-dasharray') or ''); w=p.get('stroke-width','')[:5].rstrip('0')
    nm=[v for (dd,ww),v in leg.items() if (d==dd or (dd=='3.239 1' and d.startswith('3.239 1'))) and w.startswith(ww.rstrip('0'))]
    x,y=curve(p,fx,fy); nm=nm[0] if nm else 'UNKNOWN '+d
    o=np.argsort(y); t56=np.interp(0.56,y[o],x[o]) if y.min()<=0.56<=y.max() else np.nan
    print('CI %-11s t %.2f..%.2f min CI %.3f..%.3f  t(CI=0.56)=%.2f min'%(nm,x.min(),x.max(),y.min(),y.max(),t56))
    for a,b in zip(x,y): rows.append('%s,%.3f,%.4f'%(nm,a,b))
open(S+'/csv/contrast_index.csv','w').write('developer,time_min,contrast_index\n'+'\n'.join(rows)+'\n')
with open(S+'/csv/axis_residuals.csv','w') as f:
    f.write('axis,n_ticks,units_per_pt,max_abs_residual,rms_residual\n')
    for r in resid_rows: f.write('%s,%d,%.6f,%.5f,%.5f\n'%r); print('AXIS %-28s n=%d %.5f/pt max|res| %.4f rms %.4f'%r)
