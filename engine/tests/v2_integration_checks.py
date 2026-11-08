#!/usr/bin/env python3
"""Qualify the promoted v2 engine against the original full research renderer.

The reference is the original minilab + fixed-factory research build, not 1.x
or the optical app engine. Research paths are explicit offline prerequisites.
"""
import argparse, json, os, sys, tempfile, time, subprocess
from pathlib import Path
import numpy as np
import performance_compare as pc
from scene_curve_checks import table

# Original research kept a factory plane alive until session teardown.
def audit(e):
    m=e.memory_report()
    for k in ('pending_held','over_releases','live_underflows','reclaim_while_encoding'):
        assert m['pool']['audit'][k] == 0, (k,m)
    return m
pc.audit=audit
pc.__file__=__file__
if len(sys.argv)>1 and sys.argv[1]=='worker':
    print(json.dumps(pc.worker(json.loads(Path(sys.argv[2]).read_text())))); sys.exit()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('mode',choices=['check','pictures','bench','lifecycle','pair'])
    ap.add_argument('--before',type=Path,required=True)
    ap.add_argument('--after',type=Path,default=Path(__file__).resolve().parents[1])
    ap.add_argument('--research-dir',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--blocks',type=int,default=3)
    ap.add_argument('--input',type=Path,action='append',help='Explicit scene-linear float32 .npy photograph for pictures mode')
    ap.add_argument('--pair',help="'film|paper' for the minilab reference arm (default: the Portra pair)")
    ap.add_argument('--table-dir',type=Path,help='directory holding <film>__<paper>[_pp].lut3d for --pair; default: the research f10 tables')
    ap.add_argument('--before-resources',type=Path,help='resources for the reference arm (default: <before>/resources)')
    ap.add_argument('--after-resources',type=Path,help='resources for the promoted arm (default: <after>/resources)')
    a=ap.parse_args(); rows=[]
    roots={'before':str(a.before.resolve()),'after':str(a.after.resolve())}
    pair=a.pair.split('|') if a.pair else ['kodak_portra_400','kodak_portra_endura']
    def env(arm,params):
        if arm=='after': return dict(SPK_CHECKPOINT_TRACE='1',SPK_METAL_ARCHIVE_MODE='required')
        d=dict(SPK_CHECKPOINT_MODE='off')
        film=params.get('film_stock',pair[0]); paper=params.get('print_stock',pair[1])
        if film==pair[0] and paper==pair[1] and not params.get('scan_film',False) and not params.get('digital_intermediate',False):
            space=params.get('output_color_space','sRGB'); suffix='' if space=='sRGB' else '_pp'
            if a.table_dir: name=f'{film}__{paper}{suffix}.lut3d'; base=a.table_dir
            else: name=f'{film}__{paper}_f10{suffix}.lut3d'; base=a.research_dir/'Metamerism/v2/minilab'
            d['SPK_RESEARCH_MINILAB_LOGPOS']=str(base/name)
        if params.get('overscan_active'):d.update(SPK_RESEARCH_MODE='fixed_factory',SPK_RESEARCH_RETURN='.02')
        return d
    def run(arm,params={},**kw):
        d=dict(root=roots[arm],params=params,env=env(arm,params));d.update(kw)
        if arm=='before' and a.before_resources: d['resources']=str(a.before_resources.resolve())
        if arm=='after' and a.after_resources: d['resources']=str(a.after_resources.resolve())
        return pc.run(d)
    with tempfile.TemporaryDirectory() as td:
        td=Path(td)
        if a.mode=='check':
            cases=[('default',{}),('edge',dict(overscan_active=True)),('halation_zero',dict(overscan_active=True,halation_amount=0)),
                   ('dir_off',dict(dir_couplers_active=False)),('dir_high',dict(dir_couplers_amount=1.5)),
                   ('scan',dict(scan_film=True)),('DI',dict(digital_intermediate=True)),
                   ('positive',dict(film_stock='kodak_ektachrome_100')),('other_pair',dict(film_stock='kodak_gold_200')),
                   ('encoded',dict(input_cctf_decoding=True,input_color_space='sRGB')),('linear',dict(output_cctf_encoding=False))]
            cases += [(cs,dict(output_color_space=cs)) for cs in ['ProPhoto RGB','Display P3','Adobe RGB (1998)','ITU-R BT.2020','ACEScg']]
            for name,p in cases:
                for arm in roots:run(arm,p,w=1200,steps=[dict(save=str(td/f'{arm}.npy'))])
                x,y=[np.load(td/f'{arm}.npy') for arm in roots]
                assert np.array_equal(x,y),(name,int(np.max(np.abs(x.astype(int)-y.astype(int)))))
                rows.append(dict(case=name,exact=True));print(name,'exact',flush=True)
            # The source reference predates scene_curve. Compare forced-full vs
            # checkpoint execution within the promoted engine for that new input.
            for name,p in [('plain',{}),('edge',dict(overscan_active=True)),('curve',dict(scene_curve=table(rgb=.6,r=-.2))),
                           ('geometry',dict(geometry_rotation_deg=12.0,geometry_crop_w=.8,geometry_crop_h=.8))]:
                deltas=[{},dict(grain_amount=.8),dict(grain_amount=1.2),dict(grain_active=False),dict(grain_active=True),
                        dict(scene_curve=table(rgb=.3)),dict(grain_amount=.7),dict(grain_amount=.9),dict(halation_amount=0),
                        dict(grain_amount=.6),dict(grain_amount=1),dict(dir_couplers_amount=1.5),dict(grain_amount=.8),dict(grain_amount=1.1),
                        dict(grain_sublayers_active=False),dict(grain_sublayers_active=True)]
                results=[]
                for mode in ('off','auto'):
                    steps=[dict(delta=d,save=str(td/f'{mode}-{i}.npy')) for i,d in enumerate(deltas)]
                    results.append(run('after',p,w=2560,env=dict(SPK_CHECKPOINT_MODE=mode,SPK_CHECKPOINT_TRACE='1',SPK_CHECKPOINT_TEST_FORCE_ADMISSION='1'),steps=steps))
                for i in range(len(deltas)):
                    assert np.array_equal(np.load(td/f'off-{i}.npy'),np.load(td/f'auto-{i}.npy')),(name,i)
                assert any(c.startswith('hit ') for c in results[1]['checkpoints']),results[1]['checkpoints']
                for r in results:
                    assert all(x['memory']['pool']['live_bytes']==0 for x in r['rows'])
                rows.append(dict(case='checkpoint_'+name,exact=len(deltas),events=results[1]['checkpoints']))
                print('checkpoint',name,'exact',flush=True)
            for fault in ('write','read','short'):
                steps=[dict(save=str(td/f'{fault}-{i}.npy'),delta={} if i==0 else {'grain_amount':.7+i*.1}) for i in range(4)]
                r=run('after',dict(overscan_active=True),w=2560,env=dict(SPK_CHECKPOINT_TEST_FAULT=fault,SPK_CHECKPOINT_TRACE='1',SPK_CHECKPOINT_TEST_FORCE_ADMISSION='1'),steps=steps)
                full=[dict(s,save=str(td/f'full-{i}.npy')) for i,s in enumerate(steps)]
                run('after',dict(overscan_active=True),w=2560,env=dict(SPK_CHECKPOINT_MODE='off'),steps=full)
                assert all(np.array_equal(np.load(td/f'{fault}-{i}.npy'),np.load(td/f'full-{i}.npy')) for i in range(4))
                rows.append(dict(case='fault_'+fault,exact=4,events=r['checkpoints'])); print(fault,'fallback exact',flush=True)
        elif a.mode=='pair':
            # The runtime execution gate for one catalogued pair: the same table
            # file consumed by the research build and by the promoted engine must
            # produce identical RGBA16. Grain and glare off; deterministic.
            for space in ('sRGB','ProPhoto RGB'):
                p=dict(film_stock=pair[0],print_stock=pair[1],output_color_space=space,
                       grain_active=False,glare_active=False)
                for arm in roots: run(arm,p,w=1200,steps=[dict(save=str(td/f'{arm}.npy'))])
                x,y=[np.load(td/f'{arm}.npy') for arm in roots]
                assert np.array_equal(x,y),(space,int(np.max(np.abs(x.astype(int)-y.astype(int)))))
                rows.append(dict(case='pair_'+space,film=pair[0],paper=pair[1],exact=True))
                print(pair[0],pair[1],space,'exact',flush=True)
        elif a.mode=='pictures':
            assert a.input, 'pictures mode needs --input'
            for source in a.input:
                img=np.load(source,mmap_mode='r'); h,w=img.shape[:2]
                cases=[('photo',dict(auto_exposure=True)),('photo_edge',dict(auto_exposure=True,overscan_active=True))]
                if max(h,w)<=2560:
                    cases.append(('photo_date',dict(overscan_active=True,date_imprint_active=True,date_imprint_text='26 10 24')))
                    # Crop the photograph to the measured 6x7 gate before adding its edge.
                    ratio=(69.5/56)/(max(h,w)/min(h,w))
                    crop={'geometry_crop_w' if w>=h else 'geometry_crop_h':ratio}
                    cases.append(('photo_120',dict(overscan_active=True,overscan_format='120_6x7',**crop)))
                for name,p in cases:
                    for arm in roots:run(arm,p,input=str(source),steps=[dict(save=str(td/f'{arm}.npy'))])
                    x,y=[np.load(td/f'{arm}.npy',mmap_mode='r') for arm in roots]
                    assert np.array_equal(x,y),(name,source.name)
                    rows.append(dict(case=name,input=source.name,width=w,height=h,exact=True));print(source.name,name,'exact',flush=True)
        elif a.mode=='bench':
            for w in (2560,6000,8256):
                for edge in (False,True):
                    for block in range(a.blocks):
                        for arm in ('before','after','after','before'):
                            p=dict(overscan_active=edge)
                            load=dict(at=time.time(),averages=os.getloadavg(),processes=subprocess.check_output(['ps','-Ao','%cpu,comm','-r'],text=True).splitlines()[:8])
                            steps=[{}]+[dict(delta={'grain_amount':v}) for v in (.8,1.2,.9,1.1)]+[dict(delta={'print_exposure':.2},reprint=True)]
                            r=run(arm,p,w=w,steps=steps)
                            rows.append(dict(arm=arm,w=w,edge=edge,block=block,result=r,load=load))
                            a.output.write_text(json.dumps(dict(roots=roots,results=rows),indent=1))
                        print(w,edge,block,'complete',flush=True)
        else:
            for arm in ('before','after','after','before'):
                r=run(arm,dict(overscan_active=True),w=2560,cycles=16,steps=[{},dict(delta={'grain_amount':.8}),dict(delta={'grain_amount':1.2})])
                fds=[x['fd_count'] for x in r['closed']];assert min(fds)==max(fds),fds
                if arm=='after':assert all(x['memory']['pool']['live_bytes']==0 for x in r['rows'])
                rows.append(dict(arm=arm,result=r));print(arm,'16 sessions / 48 renders',flush=True)
    a.output.write_text(json.dumps(dict(roots=roots,results=rows),indent=1))
if __name__=='__main__': main()
