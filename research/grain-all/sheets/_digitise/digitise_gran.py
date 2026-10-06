"""Digitise Kodak 'Diffuse rms Granularity Curves' from pdftocairo SVGs (vector editions).
usage: python3 -I digitise_gran.py out.json   (svgs in ./svg, made with: pdftocairo -svg -f P -l P sheet.pdf)"""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from svgpaths import load
HERE=os.path.dirname(os.path.abspath(__file__))
# name: (svg, plot bbox x0,x1,y0,y1 (page pt), density at frame top, x value at frame left, x at frame right)
SHEETS={
 'kodak_vision3_50d':  ('v50d_2015', (60,262,140,350), 3.0, 0.0, 5.0),
 'kodak_vision3_200t': ('v200t_2015',(60,262,140,345), 3.0, 0.0, 5.0),
 'kodak_vision3_250d': ('v250d_2009',(60,262,360,560), 3.0, 0.0, 5.0),
 'kodak_vision3_500t': ('v500t_2015',(60,262,140,350), 3.0, 0.0, 5.0),
 'kodak_verita_200d':  ('verita',    (370,530,230,402), 3.2, -3.0, 2.0),
}
def inside(a,b): return a[:,0].min()>=b[0] and a[:,0].max()<=b[1] and a[:,1].min()>=b[2] and a[:,1].max()<=b[3]
def run(name,svg,bbox,dtop,xl,xr):
    ps=[p for p in load(HERE+'/svg/'+svg+'.svg') if inside(p['pts'],bbox)]
    long=[p for p in ps if len(p['pts'])>=40 and p.get('stroke','none')!='none']
    assert len(long)==6,(name,len(long))
    X0=min(p['pts'][:,0].min() for p in long); X1=max(p['pts'][:,0].max() for p in long)
    # split: characteristic curves span > 0.9 density-units of height; granularity curves are flat
    hs=sorted(long,key=lambda p:np.ptp(p['pts'][:,1]))
    gran,char=hs[:3],hs[3:]
    # frame: the 5-point rectangle
    fr=[p for p in ps if len(p['pts'])==5 and np.ptp(p['pts'][:,0])>100 and np.ptp(p['pts'][:,1])>100]
    assert fr,name
    f=fr[0]['pts']; ytop,ybot=f[:,1].min(),f[:,1].max(); fx0,fx1=f[:,0].min(),f[:,0].max()
    # left density ticks (2-pt horizontal segments at the left frame edge)
    lt=sorted({round(float(p['pts'][0,1]),2) for p in ps if len(p['pts'])==2 and abs(p['pts'][0,1]-p['pts'][1,1])<1e-3 and p['pts'][:,0].max()<fx0+6 and np.ptp(p['pts'][:,0])<8})
    # right sigma ticks: tiny rects just right of frame
    rt=sorted({round(float(p['pts'][:,1].mean()),2) for p in ps if len(p['pts'])==5 and p['pts'][:,0].min()>=fx1-1.5 and np.ptp(p['pts'][:,0])<6 and np.ptp(p['pts'][:,1])<1})
    # merge duplicates
    m=[]
    for y in rt:
        if not m or y-m[-1]>0.6: m.append(y)
    rt=m
    y10=rt[0]; y01=rt[5]            # 0.10 and 0.01 (0.10,0.05,0.04,0.03,0.02,0.01 from the top)
    dec=y01-y10
    exp=[0.10,0.05,0.04,0.03,0.02,0.01,0.009,0.008,0.007,0.006,0.005,0.004,0.003,0.002,0.001]
    pred=[y10+dec*(-1-np.log10(v)) for v in exp]
    res=max(abs(a-b) for a,b in zip(rt,pred[:len(rt)]))
    fD=lambda y:(ybot-np.asarray(y))/(ybot-ytop)*dtop
    fS=lambda y:10**(-1-(np.asarray(y)-y10)/dec)
    fX=lambda x:xl+(np.asarray(x)-fx0)/(fx1-fx0)*(xr-xl)
    def xy(p):
        a=p['pts']; o=np.argsort(a[:,0],kind='stable'); return a[o,0],a[o,1]
    # channel order: char by Dmin (left-end density): B > G > R
    ch=sorted(char,key=lambda p:-fD(xy(p)[1][0]))
    # granularity: B is the highest on average; of the other two, G is the higher over the upper half of the scale
    def meanlog(p,lo=0.5,hi=0.95):
        x,y=xy(p); s=(x>=X0+lo*(X1-X0))&(x<=X0+hi*(X1-X0)); return np.log10(fS(y[s])).mean()
    gr=sorted(gran,key=lambda p:-meanlog(p,0.0,1.0)); b=gr[0]; rest=sorted(gr[1:],key=lambda p:-meanlog(p))
    # label check (read off the rendered page): Vision3 sheets label the upper of the two lower curves G;
    # the VERITA sheet labels the upper one 'Red Grain' and the lower one 'Green Grain'.
    grs={'B':b,'G':rest[0],'R':rest[1]} if name!='kodak_verita_200d' else {'B':b,'R':rest[0],'G':rest[1]}
    chs=dict(zip('BGR',ch))
    out={'svg':svg,'frame_pt':[fx0,fx1,ytop,ybot],'n_left_ticks':len(lt),'n_sigma_ticks':len(rt),'decade_pt':dec,
         'sigma_tick_max_residual_pt':res,'density_per_pt':dtop/(ybot-ytop),'channels':{}}
    grid=np.linspace(X0,X1,400)
    for c in 'RGB':
        xc,yc=xy(chs[c]); xg,yg=xy(grs[c])
        D=fD(np.interp(grid,xc,yc)); Sg=fS(np.interp(grid,xg,yg))
        dmin=float(D[:20].min()); 
        def at(target):
            i=np.where((D[:-1]<target)&(D[1:]>=target))[0]
            if not len(i): return None
            i=i[0]; t=(target-D[i])/(D[i+1]-D[i]); gx=grid[i]+t*(grid[i+1]-grid[i])
            return float(gx)
        g1=at(dmin+1.0)
        r={'dmin':round(dmin,3),'dmax_plotted':round(float(D.max()),3)}
        if g1 is not None:
            s=float(fS(np.interp(g1,xg,yg)))
            # sensitivity to +-1 pt vertical (half the heavy line's width) and +-0.05 D in the density target
            lo=float(fS(np.interp(g1,xg,yg)+1)); hi=float(fS(np.interp(g1,xg,yg)-1))
            ga=at(dmin+0.95); gb=at(dmin+1.05)
            sa=float(fS(np.interp(ga,xg,yg))); sb=float(fS(np.interp(gb,xg,yg)))
            r.update(logE_at_netD1=round(float(fX(g1)),3),rms_at_netD1=round(1000*s,2),
                     rms_pm1pt=[round(1000*lo,2),round(1000*hi,2)],rms_at_netD0p95_1p05=[round(1000*sa,2),round(1000*sb,2)])
        mid=(grid>=X0+0.3*(X1-X0))&(grid<=X0+0.8*(X1-X0))
        r.update(rms_min=round(1000*float(Sg.min()),2),rms_max=round(1000*float(Sg.max()),2),
                 rms_range_midscale=[round(1000*float(Sg[mid].min()),2),round(1000*float(Sg[mid].max()),2)])
        out['channels'][c]=r
    # common exposure: where GREEN net density = 1.0
    xc,yc=xy(chs['G']); D=fD(np.interp(grid,xc,yc)); dmin=D[:20].min()
    i=np.where((D[:-1]<dmin+1)&(D[1:]>=dmin+1))[0][0]; gx=grid[i]
    out['at_green_netD1_exposure']={c:round(1000*float(fS(np.interp(gx,*xy(grs[c])))),2) for c in 'RGB'}
    out['at_green_netD1_exposure']['net_density']={c:round(float(fD(np.interp(gx,*xy(chs[c])))-fD(np.interp(grid,*xy(chs[c])))[:20].min()),3) for c in 'RGB'}
    return out
res={n:run(n,*a) for n,a in SHEETS.items()}
json.dump(res,open(sys.argv[1],'w'),indent=1)
for n,r in res.items():
    print(n,'ticks L/R',r['n_left_ticks'],r['n_sigma_ticks'],'decade %.2f pt'%r['decade_pt'],'tick resid %.2f pt'%r['sigma_tick_max_residual_pt'])
    for c in 'RGB': print('  ',c,r['channels'][c])
    print('   at green netD=1 exposure:',r['at_green_netD1_exposure'])
