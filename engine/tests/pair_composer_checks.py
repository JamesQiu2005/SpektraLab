"""Independent double affine/bilinear oracle for the native pair composer.

Compiles a small driver against the actual header, never a second compositor.
No GPU, private image, or runtime dependency is added to the application.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import numpy as np

DRIVER = r'''
#include "pair_composer.hpp"
#include <iostream>
#include <iterator>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif
using namespace spkhost;
int main() {
 try {
#ifdef _WIN32
  _setmode(_fileno(stdout),_O_BINARY);
#endif
  std::string input((std::istreambuf_iterator<char>(std::cin)),{}), error;
  spk::Json j; if(!spk::Json::parse(input,j,error)) throw std::runtime_error(error);
  std::array<pair::Source,2> sources;
  for(size_t i=0;i<2;++i) {
   const auto& v=j.at("sources").items().at(i); if(v.is_null()) continue;
   auto& s=sources[i]; s.geometry=pair::geometry(v.at("geometry")); s.placement=pair::placement(v.at("placement"));
   s.exposure=pair::numeric(v,"exposure",0); s.metered=pair::numeric(v,"metered",0);
   s.pixels.width=uint32_t(v.at("width").as_int()); s.pixels.height=uint32_t(v.at("height").as_int());
   for(const auto& p:v.at("pixels").items()) s.pixels.rgb.push_back(float(p.as_double()));
  }
  const auto l=pair::layout(sources,j.at("spacing").as_double(1),j.at("turned").as_bool());
  spk::Json header=spk::Json::object(); header.set("width",spk::Json(double(l.size.w))); header.set("height",spk::Json(double(l.size.h)));
  header.set("hole_width",spk::Json(double(l.hole.w))); header.set("hole_height",spk::Json(double(l.hole.h))); header.set("advance",spk::Json(double(l.advance)));
  const auto text=header.dump(); const uint32_t bytes=uint32_t(text.size());
  std::cout.write(reinterpret_cast<const char*>(&bytes),4); std::cout.write(text.data(),text.size());
  if(!j.at("layout_only").as_bool()) {
   for(auto& s:sources) pair::sample_hole(s,l);
   const auto out=pair::compose(sources,l);
   std::cout.write(reinterpret_cast<const char*>(out.rgb.data()),out.rgb.size()*sizeof(float));
  }
  return 0;
 } catch(const std::exception& e) { std::cerr<<e.what(); return 1; }
}
'''

Q = [np.eye(3), np.array([[0,1,0],[-1,0,1],[0,0,1]]),
     np.array([[-1,0,1],[0,-1,1],[0,0,1]]), np.array([[0,-1,1],[1,0,0],[0,0,1]])]

def output_size(source):
    g = source.get('geometry', {})
    c = g.get('crop', [0,0,1,1])
    if isinstance(c, dict): c = [c['x'],c['y'],c['width'],c['height']]
    size = [max(1,int(np.floor(source['width']*c[2]+.5))),max(1,int(np.floor(source['height']*c[3]+.5)))]
    return (size[::-1] if g.get('quarterTurns',0)%2 else size), c

def source_rect(source, vertical, scale=1):
    size, _ = output_size(source)
    p = source.get('placement', {})
    if p.get('quarterTurns',0)%2: size=size[::-1]
    aspect = 4/3 if vertical else 3/4
    w,h=size
    if w/h>aspect: w=h*aspect
    else: h=w/aspect
    w/=scale; h/=scale
    return size, [(size[0]-w)*(1+p.get('x',0))/2,(size[1]-h)*(1+p.get('y',0))/2,w,h]

def oracle(spec):
    sources=spec['sources']; vertical=spec.get('turned',False)
    across=[]; longest=0
    for s in sources:
        if not s: continue
        size,_=output_size(s); longest=max(longest,*size)
        _,r=source_rect(s,vertical)
        across.append(r[2] if vertical else r[3])
    a=min(across) if across else 2400
    if longest: a=min(a,longest*24/37)
    a=max(8,int(np.floor(a))); along=max(6,int(np.floor(a*.75+.5)))
    advance=int(np.floor(along*(18+spec.get('spacing',1))/18+.5))
    hw,hh=(a,along) if vertical else (along,a)
    w,h=(a,advance+along) if vertical else (advance+along,a)
    header=dict(width=w,height=h,hole_width=hw,hole_height=hh,advance=advance)
    if spec.get('layout_only'): return header, None
    out=np.zeros((h,w,3),np.float32)
    yy,xx=np.mgrid[:hh,:hw]; xy=np.stack(((xx+.5)/hw,(yy+.5)/hh,np.ones_like(xx)),axis=0).reshape(3,-1)
    for side,s in enumerate(sources):
        if not s: continue
        placement=s.get('placement',{}); g=s.get('geometry',{}); native=np.array([s['width'],s['height']])
        _,crop=output_size(s)
        rotated,cut=source_rect(s,vertical,placement.get('scale',1))
        hole_to_turn=np.array([[cut[2]/rotated[0],0,cut[0]/rotated[0]],[0,cut[3]/rotated[1],cut[1]/rotated[1]],[0,0,1]])
        flip=np.array([[-1 if g.get('flipH') else 1,0,1 if g.get('flipH') else 0],
                       [0,-1 if g.get('flipV') else 1,1 if g.get('flipV') else 0],[0,0,1]])
        a=np.deg2rad(g.get('angle',0)); ca,sa=np.cos(a),np.sin(a)
        rotation=np.array([[ca,-sa,0],[sa,ca,0],[0,0,1]])
        local=np.array([[crop[2]*native[0],0,-crop[2]*native[0]/2],[0,crop[3]*native[1],-crop[3]*native[1]/2],[0,0,1]])
        centre=np.array([[1/native[0],0,crop[0]+crop[2]/2],[0,1/native[1],crop[1]+crop[3]/2],[0,0,1]])
        matrix=centre@rotation@local@Q[g.get('quarterTurns',0)%4]@flip@Q[placement.get('quarterTurns',0)%4]@hole_to_turn
        src=(matrix@xy)[:2].T*native-.5
        src=np.clip(src,[0,0],native-1); lo=np.floor(src).astype(int); hi=np.minimum(lo+1,native-1); f=src-lo
        pixels=np.array(s['pixels'],np.float32).reshape(native[1],native[0],3).astype(float)
        tx,ty=f[:,0,None],f[:,1,None]
        sampled=((pixels[lo[:,1],lo[:,0]]*(1-tx)+pixels[lo[:,1],hi[:,0]]*tx)*(1-ty)+
                 (pixels[hi[:,1],lo[:,0]]*(1-tx)+pixels[hi[:,1],hi[:,0]]*tx)*ty).astype(np.float32)
        sampled=(sampled.astype(float)*2**(s.get('exposure',0)+s.get('metered',0))).astype(np.float32).reshape(hh,hw,3)
        x,y=(0,side*advance) if vertical else (side*advance,0)
        out[y:y+hh,x:x+hw]=sampled
    return header,out

def source(w,h,**kw):
    y,x=np.mgrid[:h,:w]
    image=np.stack((x/31-y/47, .15+np.sin(x*.7)*.1+y/200, .2+((x+y)%3)/9),axis=-1).astype(np.float32)
    return dict(width=w,height=h,pixels=image.ravel().astype(float).tolist(),**kw)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--compiler',required=True); args=ap.parse_args()
    engine=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='spk-pair-math-') as tmp:
        cpp=Path(tmp)/'driver.cpp'; exe=Path(tmp)/'driver.exe'; cpp.write_text(DRIVER)
        subprocess.run([args.compiler,'-std=c++20','-O2','-I'+str(engine/'host'),'-I'+str(engine/'src/core'),str(cpp),str(engine/'src/core/json.cpp'),'-o',str(exe)],check=True)
        cases=[]
        for vertical in [False,True]:
            for q in range(4):
                for zoom in [1,1.7,4]:
                    cases.append(dict(sources=[source(47,31,geometry={'crop':[.13,.12,.61,.72],'angle':13,'quarterTurns':q,'flipH':True,'flipV':q%2==0},
                          placement={'quarterTurns':3-q,'scale':zoom,'x':-1,'y':1},exposure=.4,metered=-.2),
                          source(65,43,geometry={'quarterTurns':1},placement={'x':1,'y':-.6})],turned=vertical,spacing=1.7))
        cases += [dict(sources=[None,source(64,42)],spacing=.5),dict(sources=[source(64,42),None],turned=True,spacing=2)]
        cases += [dict(sources=[None,None],layout_only=True),dict(sources=[None,None],layout_only=True,turned=True)]
        max_error=0
        for spec in cases:
            expected,image=oracle(spec)
            r=subprocess.run([str(exe)],input=json.dumps(spec).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
            n,=struct.unpack('<I',r.stdout[:4]); actual=json.loads(r.stdout[4:4+n]); assert actual==expected,(actual,expected)
            if image is not None:
                got=np.frombuffer(r.stdout[4+n:],dtype='<f4').reshape(image.shape)
                error=float(np.max(np.abs(got-image))); max_error=max(max_error,error)
                assert error<=2e-7,(error,spec.get('turned'))
                assert np.array_equal(got[image==0],image[image==0]),'unexposed gap changed'
        print(f'ok: {len(cases)} pair affine/layout/linear-gain cases, max abs error {max_error:.9g}')

if __name__=='__main__': main()
