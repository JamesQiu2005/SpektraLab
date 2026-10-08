"""Digitise F-4016 (June 2018) p8 from the PDF's vector paths (pdftocairo -svg): the D-76 small-tank
characteristic curves and the spectral sensitivity at 0.3 above D-min. Writes CSVs to ./csv."""
import os, numpy as np
from svgpaths import load
S=os.path.dirname(os.path.abspath(__file__))
ps=[p for p in load(S+'/pdf/tmax_p8.svg') if p.get('stroke','none')!='none']
def axis(name,pos,val):
    pos=np.array(pos,float); val=np.array(val,float); A=np.c_[pos,np.ones_like(pos)]
    (m,c),*_=np.linalg.lstsq(A,val,rcond=None); r=A@[m,c]-val; print('AXIS %-24s n=%d max|res| %.4f'%(name,len(pos),np.abs(r).max()))
    return lambda p:m*np.asarray(p)+c
def find(xr,yr,minpts):
    return [p for p in ps if len(p['pts'])>=minpts and p['pts'][:,0].min()>=xr[0]-1 and p['pts'][:,0].max()<=xr[1]+1 and p['pts'][:,1].min()>=yr[0]-1 and p['pts'][:,1].max()<=yr[1]+1]
# spectral sensitivity: grid lines at 300..700 nm, and at log S 1, 0, -1
fx=axis('spectral x (nm)',[94.7,114.8,134.89,154.98,175.08,195.18,215.27,235.37,255.47],np.arange(300,701,50))
fy=axis('spectral y (logS)',[536.36,574.23,612.1],[1,0,-1])
c=sorted(find((130,260),(500,650),100),key=lambda p:p['pts'][:,1].min()); assert len(c)==2
for p,n in zip(c,('0.3','1.0')):                       # the upper curve is the more sensitive: 0.3 above D-min, as labelled
    x,y=fx(p['pts'][:,0]),fy(p['pts'][:,1]); print('spectral D-min+%s: %.1f..%.1f nm, logS %.2f..%.2f'%(n,x.min(),x.max(),y.min(),y.max()))
    np.savetxt(S+'/csv/spectral_tmax_raw_%s.csv'%n,np.c_[x,y],delimiter=',',fmt='%.4f',header='wavelength_nm,log_sensitivity (reciprocal of erg/cm^2 for D-min + %s)'%n,comments='')
# characteristic curves, D-76 small tank 20 C, daylight: ticks at log H -3..0 and D 3, 2, 1, frame bottom D 0
fx=axis('char x (logH)',[392.49,429.38,466.27,503.16],[-3,-2,-1,0]); fy=axis('char y (D)',[103.13,149.25,195.36,241.5],[3,2,1,0])
cs=find((380,530),(100,235),40); key={'':0,'3.2392':1,'6.4785':2}
cs=sorted(cs,key=lambda p:key[(p.get('stroke-dasharray') or '').split(' ')[0]]); assert len(cs)==3
g=np.round(np.arange(-3.14,0.641,0.02),2); cols=[g]
for p,t in zip(cs,(10,7.5,6)):
    x,y=fx(p['pts'][:,0]),fy(p['pts'][:,1]); o=np.argsort(x,kind='stable'); x,y=x[o],y[o]; k=np.r_[True,np.diff(x)>1e-9]
    cols.append(np.interp(g,x[k],y[k],left=np.nan,right=np.nan)); print('D-76 %g min: logH %.3f..%.3f D %.3f..%.3f'%(t,x.min(),x.max(),y.min(),y.max()))
np.savetxt(S+'/csv/char_tmax_D76.csv',np.array(cols).T,delimiter=',',fmt='%.4f',header='logH_lux_s,D_10min,D_7.5min,D_6min',comments='')
