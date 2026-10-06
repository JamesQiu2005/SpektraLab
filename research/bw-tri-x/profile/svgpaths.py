"""Parse pdftocairo SVG: return stroked paths as flattened polylines in page points."""
import re, sys, numpy as np
import xml.etree.ElementTree as ET
NS='{http://www.w3.org/2000/svg}'
def parse_transform(t):
    M=np.eye(3)
    if not t: return M
    for name,args in re.findall(r'(\w+)\(([^)]*)\)',t):
        a=[float(x) for x in re.split(r'[ ,]+',args.strip())]
        m=np.eye(3)
        if name=='matrix': m=np.array([[a[0],a[2],a[4]],[a[1],a[3],a[5]],[0,0,1]])
        elif name=='translate': m[0,2]=a[0]; m[1,2]=a[1] if len(a)>1 else 0
        elif name=='scale': m[0,0]=a[0]; m[1,1]=a[1] if len(a)>1 else a[0]
        M=M@m
    return M
def flatten(d,nseg=12):
    toks=re.findall(r'[MLHVCZmlhvcz]|-?[\d.]+(?:e-?\d+)?',d)
    i=0; pts=[]; subs=[]; cur=None; cmd=None
    def num():
        nonlocal i; v=float(toks[i]); i+=1; return v
    while i<len(toks):
        if re.match(r'[A-Za-z]',toks[i]): cmd=toks[i]; i+=1
        if cmd=='M':
            if pts: subs.append(pts)
            cur=(num(),num()); pts=[cur]; cmd='L'
        elif cmd=='L': cur=(num(),num()); pts.append(cur)
        elif cmd=='H': cur=(num(),cur[1]); pts.append(cur)
        elif cmd=='V': cur=(cur[0],num()); pts.append(cur)
        elif cmd=='C':
            p0=np.array(cur); p1=np.array((num(),num())); p2=np.array((num(),num())); p3=np.array((num(),num()))
            for t in np.linspace(0,1,nseg+1)[1:]:
                pts.append(tuple((1-t)**3*p0+3*(1-t)**2*t*p1+3*(1-t)*t*t*p2+t**3*p3))
            cur=tuple(p3)
        elif cmd in 'Zz':
            if pts: pts.append(pts[0])
        else: raise ValueError(cmd)
    if pts: subs.append(pts)
    return subs
def load(svg):
    root=ET.parse(svg).getroot(); out=[]
    def walk(el,M,inh):
        M=M@parse_transform(el.get('transform'))
        st=dict(inh)
        for k in ('stroke','fill','stroke-width','stroke-dasharray'):
            if el.get(k) is not None: st[k]=el.get(k)
        tag=el.tag.replace(NS,'')
        if tag in('defs','clipPath','symbol'): return
        if tag=='path' and el.get('d'):
            for sub in flatten(el.get('d')):
                a=np.array(sub); a=(M@np.c_[a,np.ones(len(a))].T).T[:,:2]
                out.append(dict(pts=a,**st))
        for c in el: walk(c,M,st)
    walk(root,np.eye(3),{})
    return out
if __name__=='__main__':
    for k,p in enumerate(load(sys.argv[1])):
        if p.get('stroke','none')=='none': continue
        a=p['pts']; print(k,len(a),'x %.1f..%.1f y %.1f..%.1f'%(a[:,0].min(),a[:,0].max(),a[:,1].min(),a[:,1].max()),'w',p.get('stroke-width'),'dash',p.get('stroke-dasharray'))
