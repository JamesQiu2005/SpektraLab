"""Real native half-frame pair decode/render checks; no GUI/mock acceptance."""
import argparse
import json
from pathlib import Path
import tempfile
import numpy as np
import tifffile
from host_smoke import Host
from pair_composer_checks import oracle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', type=Path, required=True)
    ap.add_argument('--resources', type=Path, required=True)
    args = ap.parse_args()
    h = Host([str(args.host.resolve()), '--resources', str(args.resources.resolve())])
    def call(method, params, payload=b''):
        reply, payload = h.call(method, params, payload)
        assert reply['ok'], (method, reply)
        return reply['result'], payload
    try:
        folder = Path(tempfile.mkdtemp(prefix='spk-pair-host-'))
        yy, xx = np.mgrid[:240, :360]
        a = np.stack((0.05+xx/900, 0.1+yy/700, 0.12+xx*0), -1).astype('float32')
        b = np.stack((0.2+xx*0, 0.07+xx/1000, 0.15+yy/800), -1).astype('float32')
        for name, data in [('left', a), ('right', b)]:
            tifffile.imwrite(folder/(name+'.tif'), data, photometric='rgb')
        doc = {'schemaVersion': 1, 'folder': str(folder),
               'left': {'path': str(folder/'left.tif'), 'autoExposure': False},
               'right': {'path': str(folder/'right.tif'), 'autoExposure': False},
               'spacingMM': 1, 'onStrip': False, 'turned': False}
        pair = folder/'test.spektrapair'
        pair.write_text(json.dumps(doc), encoding='utf-8')
        base = {'grain_active': False, 'glare_active': False, 'halation_active': False,
                'auto_exposure': False, 'preview_long_edge': 800}
        opened, _ = call('open', {'path': str(pair), 'params': base})
        assert opened['kind'] == 'pair' and opened['pair']['complete']
        assert opened['params']['film_format_mm']==37,opened['params']['film_format_mm']
        assert (opened['width'], opened['height']) == (360, 233), opened
        sid = opened['session']
        live_info,_=call('pair_info',{'session':sid})
        assert live_info==opened['pair']
        probed,_=call('probe',{'path':str(pair)})
        assert probed['kind']=='pair' and (probed['width'],probed['height'])==(360,233)
        preview,pixels=call('thumbnail',{'path':str(pair),'long_edge':256})
        pi=preview['image']; assert max(pi['width'],pi['height'])<=256
        assert preview['source']=='pair-source-preview' and len(pixels)==pi['width']*pi['height']*4
        camera=np.frombuffer(pixels,np.uint8).reshape(pi['height'],pi['width'],4)
        assert np.max(camera[:,pi['width']//2,:3])==0,'source preview must retain the unexposed gap'
        result, data = call('render', {'session': sid, 'tier': 'full', 'format': 'rgba16'})
        assert result['image']['width'] == 360 and len(data) == 360*233*8
        written,_=call('write_image',{'session':sid,'source_path':str(pair),'path':str(folder/'pair-R1.tif'),
            'format':'tiff16','color_space':'sRGB','width':360,'height':233},data)
        assert written['exif_copied']
        for fmt, ext in [('jpeg', 'jpg'), ('png', 'png'), ('tiff16', 'tif')]:
            target = folder/('pair.'+ext)
            exported, _ = call('export_image', {'session': sid, 'path': str(target), 'format': fmt, 'color_space': 'sRGB'})
            assert (exported['width'], exported['height']) == (360,233)
            assert target.stat().st_size > 1000
        image=tifffile.imread(folder/'pair.tif')
        with tifffile.TiffFile(folder/'pair.tif') as decoded:
            assert image.dtype==np.uint16 and len(decoded.pages[0].tags[34675].value)>100
        from PIL import Image
        for ext in ('jpg','png'):
            with Image.open(folder/('pair.'+ext)) as decoded:
                assert decoded.size==(360,233) and len(decoded.info['icc_profile'])>100

        # Missing holes remain visible as unexposed film but cannot be exported.
        missing={**doc,'right': {'path': str(folder/'missing.tif')}}
        pair.write_text(json.dumps(missing),encoding='utf-8')
        partial,_=call('open',{'path':str(pair),'params':base})
        assert not partial['pair']['complete'] and not partial['pair']['sources'][1]['present']
        for method in ('export_image','export_di','export_cineon'):
            result,_=h.call(method,{'session':partial['session'],'path':str(folder/'must-not-exist.tif')})
            assert not result['ok'] and result['error']['code']=='bad_request',(method,result)
        assert not (folder/'must-not-exist.tif').exists()
        failed,_=h.call('write_image',{'session':partial['session'],'source_path':str(pair),
            'path':str(folder/'must-not-exist.tif'),'format':'tiff16','color_space':'sRGB','width':360,'height':233},data)
        assert not failed['ok'] and not (folder/'must-not-exist.tif').exists()
        call('render',{'session':partial['session'],'tier':'live'})
        call('close',{'session':partial['session']})

        # Each meter reads its placed hole, not the combined strip and gap.
        metered={**doc,'left':{**doc['left'],'autoExposure':True},'right':{**doc['right'],'autoExposure':True}}
        pair.write_text(json.dumps(metered),encoding='utf-8')
        auto,_=call('open',{'path':str(pair),'params':{**base,'auto_exposure':True}})
        assert auto['params']['auto_exposure'] is False
        def spec(pixels):
            return {'width':pixels.shape[1],'height':pixels.shape[0],'pixels':pixels.ravel().astype(float).tolist()}
        _,canvas=oracle({'sources':[spec(a),spec(b)],'spacing':1})
        for i,rect in enumerate(auto['pair']['rects']):
            x,y,w,hole_h=rect
            x=int(round(x*360)); w=int(round(w*360))
            target=folder/f'meter-{i}.tif'
            tifffile.imwrite(target,canvas[:,x:x+w],photometric='rgb')
            one,_=call('open',{'path':str(target),'params':{**base,'auto_exposure':True,'film_format_mm':24}})
            solved,_=call('solve',{'session':one['session'],'target':'exposure'})
            expected=solved['solved_params']['exposure_compensation_ev']
            assert abs(expected-auto['pair']['sources'][i]['metered_ev'])<2e-5,(expected,auto['pair'])
            call('close',{'session':one['session']})
        assert abs(auto['pair']['sources'][0]['metered_ev']-auto['pair']['sources'][1]['metered_ev'])>.01
        bad,_=h.call('set_params',{'session':auto['session'],'delta':{'auto_exposure':True}})
        assert not bad['ok']
        for target in ('exposure','both'):
            bad,_=h.call('solve',{'session':auto['session'],'target':target})
            assert not bad['ok'] and bad['error']['code']=='bad_request'
        call('solve',{'session':auto['session'],'target':'filter_pack'})
        call('render',{'session':auto['session'],'tier':'live'})
        call('close',{'session':auto['session']})

        # Turned strip + per-hole geometry/placement survives a re-decode.
        turned={**doc,'turned':True,'onStrip':True,'left':{**doc['left'],
            'geometry':{'crop':[.1,.1,.7,.7],'quarterTurns':1,'flipH':True},
            'placement':{'scale':1.7,'x':.8,'y':-.5,'quarterTurns':1},'exposureEV':.5}}
        pair.write_text(json.dumps(turned),encoding='utf-8')
        strip,_=call('open',{'path':str(pair),'params':{**base,'date_imprint_active':True,
            'date_imprint_text':"'26 10 1",'date_imprint_text_b':"'26 10 3"}})
        assert strip['pair']['turned'] and strip['pair']['on_strip']
        rendered,baseline=call('render',{'session':strip['session'],'tier':'full'})
        layout,_=call('overscan_geometry',{'session':strip['session']})
        assert layout['valid'] and len(layout['gates'])==2
        assert abs(layout['gate_mm'][0]-18)<.2 and abs(layout['gate_mm'][1]-24)<.2,layout
        call('set_params',{'session':strip['session'],'delta':{'date_imprint_text_b':"'26 12 31"}})
        changed,pixels=call('render',{'session':strip['session'],'tier':'full'})
        dims=rendered['image']; before=np.frombuffer(baseline,np.uint8).reshape(dims['height'],dims['width'],4)
        after=np.frombuffer(pixels,np.uint8).reshape(before.shape)
        dy,dx=np.where(np.any(before[...,:3]!=after[...,:3],axis=-1))
        assert len(dx)>5 and dy.mean()>dims['height']*.5,(len(dx),dy.mean())
        reopened,_=call('redecode',{'session':strip['session']})
        assert reopened['pair']['complete'] and reopened['session']==strip['session']
        assert (reopened['width'],reopened['height'])==(strip['width'],strip['height'])
        # A strip switch recomposes the actual spacing, not only the rendered frame.
        change,_=call('set_params',{'session':strip['session'],'delta':{'overscan_active':False}})
        assert change['pair']['on_strip'] is False
        call('close',{'session':strip['session']})

        # Invalid edits fail explicitly and leave existing sessions usable.
        for broken in ('{not json',json.dumps({**doc,'left':{**doc['left'],'print':{'brightnessStops':1}}}),
                       json.dumps({**doc,'left':{'path':str(pair)}}), json.dumps({**doc,'turned':'false'}),
                       json.dumps({**doc,'left':{**doc['left'],'geometry':42}}),
                       json.dumps({**doc,'left':{**doc['left'],'autoExposure':'false'}})):
            pair.write_text(broken,encoding='utf-8')
            failed,_=h.call('open',{'path':str(pair),'params':base})
            assert not failed['ok']
            call('render',{'session':sid,'tier':'live'})
        call('close', {'session': sid})
        pair.write_text(json.dumps(doc),encoding='utf-8')
        failed,_=h.call('open',{'path':str(pair),'decode':{'white_balance':{'mode':'custom','temperature_k':3200}}})
        assert not failed['ok'] and failed['error']['code']=='unsupported'
        (folder/'verification.json').write_text(json.dumps({'checks':[
            'native pair open/render/JPEG/PNG/TIFF with ICC', 'incomplete pair render and all raw/ordinary export refusal',
            'per-hole independent meter versus independently sampled source images', 'turned strip with two physical gates',
            'second date changes the second gate', 'redecode and strip-mode rebuild',
            'invalid pair/nesting/unsupported per-hole edits fail without corrupting the existing session'],
            'pair_file':str(pair),'destination':str(folder)},indent=2),encoding='utf-8')
        print(json.dumps({'destination': str(folder), 'pair': opened['pair']}), flush=True)
        call('shutdown', {})
        assert h.p.wait(timeout=20) == 0
        print('ok: native pair decode, Vulkan render and JPEG/PNG/TIFF exports')
    finally:
        if h.p.poll() is None:
            h.p.kill(); h.p.wait()


if __name__ == '__main__':
    main()
