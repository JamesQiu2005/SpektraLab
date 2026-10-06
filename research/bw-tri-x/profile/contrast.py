"""Kodak contrast index (arcs 0.2 / 2.2 from a point on the base+fog line), ISO speed point, average gradient
for each digitised curve, and the development time giving CI 0.56. Writes csv/curve_metrics.csv."""
import os, numpy as np
from scipy.optimize import brentq
S=os.path.dirname(os.path.abspath(__file__))
def arc_hit(x,y,x0,d0,r):
    f=np.hypot(x-x0,y-d0)-r; m=x>x0
    i=np.where(m[:-1]&(f[:-1]<0)&(f[1:]>=0))[0]
    if len(i)==0: return None
    i=i[0]; t=-f[i]/(f[i+1]-f[i]); return x[i]+t*(x[i+1]-x[i]), y[i]+t*(y[i+1]-y[i])
def contrast_index(x,y,dmin):
    def g(x0):
        a=arc_hit(x,y,x0,dmin,0.2); b=arc_hit(x,y,x0,dmin,2.2)
        if a is None or b is None: return np.nan
        return (a[0]-x0)*(b[1]-dmin)-(a[1]-dmin)*(b[0]-x0)   # cross product: collinear when 0
    xs=np.linspace(x[0]-1.0,x[-1]-2.0,400); v=np.array([g(t) for t in xs])
    for i in range(len(xs)-1):
        if np.isfinite(v[i]) and np.isfinite(v[i+1]) and v[i]*v[i+1]<0:
            x0=brentq(g,xs[i],xs[i+1]); b=arc_hit(x,y,x0,dmin,2.2); return (b[1]-dmin)/(b[0]-x0)
    return np.nan
def metrics(x,y):
    dmin=np.nanmin(y); ci=contrast_index(x,y,dmin)
    hm=np.interp(dmin+0.1,y,x)                      # ISO speed point: D = 0.1 over base+fog
    dD=np.interp(hm+1.3,x,y)-(dmin+0.1)             # ISO 6 condition wants 0.80 +- 0.05
    return dmin,ci,hm,0.8/10**hm,dD
if __name__=='__main__':
    out=['curve,time_min,Dmin,contrast_index,logH_speed_point,speed_0.8_over_Hm,deltaD_over_1.3logH']
    for name,times in [('400TX_135_TMAX',[6,7,9,11]),('400TX_120_TMAX',[6,7,9,11]),('400TX_135_D76',[6,8,10,12]),('400TX_120_D76',[6,8,10,12])]:
        a=np.genfromtxt(S+'/csv/char_%s.csv'%name,delimiter=',',skip_header=1); x=a[:,0]; cis=[]
        for k,t in enumerate(times):
            m=metrics(x,a[:,k+1]); cis.append(m[1]); out.append('%s,%g,%.3f,%.3f,%.3f,%.0f,%.3f'%((name,t)+m))
        t56=np.interp(0.56,cis,times) if min(cis)<=0.56<=max(cis) else float('nan')
        out.append('%s,t(CI=0.56) by interpolation across the plotted curves,%.2f,,,,'%(name,t56))
    open(S+'/csv/curve_metrics.csv','w').write('\n'.join(out)+'\n'); print('\n'.join(out))
