#!/usr/bin/env python3
"""Replay the complete research-v2 baseline versus all three optimization passes.

The research trees/resources are separate prerequisites; this does not turn
those experiments on in the product engine. Use performance_compare.py for the
committed product implementation.
"""
from pathlib import Path
import argparse,json,os,sys,subprocess,time
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tests'))
import performance_compare as pc

def audit(e):
    m=e.memory_report()
    for k in ('pending_held','over_releases','live_underflows','reclaim_while_encoding'):
        assert m['pool']['audit'][k]==0,(k,m)
    # The untouched full-v2 baseline retains its factory plane until teardown.
    return m
pc.audit=audit
pc.__file__=__file__
if len(sys.argv)>1 and sys.argv[1]=='worker':
    print(json.dumps(pc.worker(json.loads(Path(sys.argv[2]).read_text()))))
    sys.exit()
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--before',type=Path,required=True)
ap.add_argument('--after',type=Path,required=True)
ap.add_argument('--research-dir',type=Path,required=True)
ap.add_argument('--output',type=Path,required=True)
ap.add_argument('--blocks',type=int,default=3)
ap.add_argument('--cold-only',action='store_true',help='First render only, no checkpoint read/write on either arm')
args=ap.parse_args()
RESEARCH=args.research_dir.resolve()
ROOTS={'before':str(args.before.resolve()),'after':str(args.after.resolve())}
OUT=args.output
rows=[]
for w in (2560,6000,8256):
  for edge in (False,True):
    for block in range(args.blocks):
      for arm in ('before','after','after','before'):
        env=dict(SPK_RESEARCH_MINILAB_LOGPOS=str(RESEARCH/'Metamerism/v2/minilab/kodak_portra_400__kodak_portra_endura_f10.lut3d'),
                 SPK_RESEARCH_SEED='12345',SPK_CHECKPOINT_MODE='off')
        if edge:env.update(SPK_RESEARCH_MODE='fixed_factory',SPK_RESEARCH_RETURN='.02')
        if arm=='after':
            env.update(SPK_PERF_FUSE='1',SPK_PERF_TABLE_CACHE='1',SPK_COLD_CAM16_BAKED_DIR=str(RESEARCH/'v2-cold-performance/baked'),
                SPK_COLD_CAM16_HOIST='1',SPK_COLD_CAM16_PARALLEL='1',SPK_COLD_DI_PREFIX='1',SPK_COLD_CURVE_CACHE='1',
                SPK_GPU_FUSE_DIR='1',SPK_GPU_FUSE_GAMUT='1',SPK_GPU_ARCHIVE=str(RESEARCH/'v2-gpu-performance/pipelines-offline27.metalar'),SPK_GPU_ARCHIVE_STRICT='1',
                SPK_CHECKPOINT_MODE='disk',SPK_CHECKPOINT_CUT='grain',SPK_CHECKPOINT_BUDGET_MB='1024')
        if args.cold_only:env['SPK_CHECKPOINT_MODE']='off'
        load=dict(at=time.time(),averages=os.getloadavg(),processes=subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:8])
        job=dict(root=ROOTS[arm],w=w,edge=edge,env=env,steps=[{}, {'delta':{'grain_amount':.8}}, {'delta':{'grain_amount':1.2}}, {'delta':{'print_exposure':.2},'reprint':True}])
        if args.cold_only:job['steps']=[{}]
        data=pc.run(job)
        rows.append(dict(arm=arm,w=w,edge=edge,block=block,result=data,load=load,env=env))
        OUT.write_text(json.dumps(dict(roots=ROOTS,results=rows),indent=1))
      print(w,edge,block,'complete',flush=True)
