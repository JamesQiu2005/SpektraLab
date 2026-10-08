"""Trace curves off a 600 dpi greyscale render of a raster chart. Gridlines are found as long dark runs;
a curve is followed column by column from a seed, taking the dark run nearest the extrapolated position."""
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS=None
def load(path,box):
    """box = (x0,y0,x1,y1) in pixels of the 600 dpi page; returns dark mask"""
    a=np.asarray(Image.open(path).convert('L'),float)[box[1]:box[3],box[0]:box[2]]
    return a<128
def groups(idx):
    idx=np.asarray(idx); 
    if len(idx)==0: return []
    cut=np.where(np.diff(idx)>1)[0]; s=np.r_[0,cut+1]; e=np.r_[cut,len(idx)-1]
    return [(idx[a],idx[b]) for a,b in zip(s,e)]
def gridlines(m,frac=0.6):
    """(columns, rows) of grid/frame lines as (first,last) pixel groups"""
    cols=groups(np.where(m.mean(0)>frac)[0]); rows=groups(np.where(m.mean(1)>frac)[0])
    return cols,rows
def runs(col):
    return groups(np.where(col)[0])
def trace(m,seed_x,seed_y,x_lo,x_hi,cols,rows,max_jump=10,min_th=3):
    """follow one curve; returns x[],y[] (run centres), skipping grid columns and runs touching a grid row"""
    gc=np.zeros(m.shape[1],bool)
    for a,b in cols: gc[max(a-2,0):b+3]=True
    gr=np.zeros(m.shape[0],bool)
    for a,b in rows: gr[max(a-1,0):b+2]=True
    out={}
    for step in (1,-1):
        y=seed_y; dy=0.0; x=seed_x
        while x_lo<=x<=x_hi:
            if not gc[x]:
                rs=[r for r in runs(m[:,x]) if r[1]-r[0]+1>=min_th]
                if rs:
                    c=np.array([(a+b)/2 for a,b in rs]); k=np.argmin(np.abs(c-(y+dy)))
                    if abs(c[k]-(y+dy))<=max_jump:
                        a,b=rs[k]
                        dy=0.7*dy+0.3*(c[k]-y); y=c[k]
                        if not gr[a:b+1].any(): out[x]=(c[k],b-a+1)
            x+=step
    xs=np.array(sorted(out)); return xs,np.array([out[x][0] for x in xs]),np.array([out[x][1] for x in xs])
def axis(pos,val):
    pos=np.array(pos,float); val=np.array(val,float); A=np.c_[pos,np.ones_like(pos)]
    (k,c),*_=np.linalg.lstsq(A,val,rcond=None); r=A@[k,c]-val
    return (lambda p:k*np.asarray(p)+c), float(np.abs(r).max()), k
