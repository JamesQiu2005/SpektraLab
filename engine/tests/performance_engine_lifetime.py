#!/usr/bin/env python3
"""Repeated engine teardown: pool audit, FD stability and macOS physical footprint.

Footprint is a process measurement (including Metal/OS caches), not a proof
that every individual driver allocation is freed immediately.
"""
import argparse,gc,json,os,re,subprocess
from pathlib import Path
from performance_compare import frame,render,audit,spk
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--engine',type=Path,default=Path(__file__).resolve().parents[1])
ap.add_argument('--archive',choices=['off','required'],default='required')
ap.add_argument('--cycles',type=int,default=40)
ap.add_argument('--output',type=Path,required=True)
a=ap.parse_args();root=a.engine.resolve();os.environ['SPK_METAL_ARCHIVE_MODE']=a.archive
rows=[];img=frame(600)
for i in range(a.cycles):
    with spk.Engine(dylib=root/'build/libspektralab_engine.dylib',resources=root/'resources') as e:
        with e.open(img,dict(input_cctf_decoding=False,grain_active=True,glare_active=False,auto_exposure=False)) as s:render(s)
        m=audit(e);assert m['persistent']['bytes']==0
    gc.collect()
    text=subprocess.check_output(['/usr/bin/footprint','-p',str(os.getpid())],text=True)
    m=re.search(r'Footprint:\s*([\d.]+)\s*([KMGT]?B)',text);assert m,text
    rows.append(dict(engine=i,footprint_mib=float(m[1])*{'B':1,'KB':2**10,'MB':2**20,'GB':2**30,'TB':2**40}[m[2]]/2**20,fds=len(os.listdir('/dev/fd'))))
assert len({r['fds'] for r in rows})==1,rows
a.output.write_text(json.dumps(dict(archive=a.archive,rows=rows),indent=2))
print('last 10 footprint MiB:',[r['footprint_mib'] for r in rows[-10:]],'stable FDs:',rows[0]['fds'])
