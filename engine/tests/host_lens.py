#!/usr/bin/env python3
"""Full RAW lens decode: real profile, current original, exact disabled restore."""
import argparse
from pathlib import Path
import shutil
import tempfile
from host_smoke import Host, write_png
from host_proof import good


def main():
    p=argparse.ArgumentParser();p.add_argument('--host',required=True);p.add_argument('--resources',required=True)
    p.add_argument('--raw',type=Path,required=True);a=p.parse_args()
    host=Host([a.host,'--resources',a.resources])
    try:
        with tempfile.TemporaryDirectory(prefix='spk-lens-') as t:
            folder=Path(t);raw=folder/('镜头校正'+a.raw.suffix);shutil.copyfile(a.raw,raw)
            probe,_=good(host,'probe',{'path':str(raw)})
            assert probe['metadata']['lens_correction']['available'], 'fixture requires an actual matching lens calibration'
            print('Matched:',probe['metadata']['lens_correction'],flush=True)
            for mode in ('compatible16','headroom'):
                opened,_=good(host,'open',{'path':str(raw),'decode':{'raw_mode':mode}});sid=opened['session']
                def original():return good(host,'render_source',{'session':sid,'display':'srgb','long_edge':512})[1]
                before=original()
                corrected,_=good(host,'redecode',{'session':sid,'decode':{'raw_mode':mode,'lens_correction':True}})
                assert corrected['metadata']['lens_correction']['applied']
                assert (corrected['width'],corrected['height'])==(opened['width'],opened['height'])
                after=original();assert after!=before,'matched correction did not change real image'
                good(host,'redecode',{'session':sid,'decode':{'raw_mode':mode,'lens_correction':False}})
                assert original()==before,'turning lens correction off changed baseline pixels'
                good(host,'close',{'session':sid})
                print(mode+': full RAW, original preview, profile metadata, orientation, exact off restore passed',flush=True)
            png=folder/'unsupported.png';write_png(str(png),32,24)
            error,pixels=host.call('open',{'path':str(png),'decode':{'lens_correction':True}})
            assert not error['ok'] and not pixels and error['error']['code']=='unsupported'
    finally:
        if host.p.poll() is None:good(host,'shutdown');host.p.wait(timeout=20)


if __name__=='__main__':main()
