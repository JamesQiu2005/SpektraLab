#!/usr/bin/env python3
"""Real bundled CLI + MCP + native host; all source/store/output files are owned fixtures."""
import argparse, hashlib, json, os, queue, struct, subprocess, tempfile, threading, zlib
from pathlib import Path

def png(path):
    def chunk(name,data): return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data)&0xffffffff)
    w,h=64,48
    raw=b''.join(b'\0'+bytes(v for x in range(w) for v in (20+x*3,20+y*4,20+(x+y)%60*3)) for y in range(h))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))

class Lines:
    def __init__(self,args,env,log):
        self.p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding='utf-8',env=env)
        self.lines=queue.Queue(); self.serial=0
        def reader():
            for line in self.p.stdout: self.lines.put(line)
        threading.Thread(target=reader,daemon=True).start()
    def send(self,method,params=None,rpc=False):
        self.serial+=1; request={'id':self.serial,'method':method,'params':params or {}}
        if rpc: request['jsonrpc']='2.0'
        self.p.stdin.write(json.dumps(request)+'\n');self.p.stdin.flush()
        reply=json.loads(self.lines.get(timeout=120)); assert reply['id']==self.serial,reply;return reply
    def stop(self):
        self.p.stdin.close();self.p.wait(timeout=30);assert self.p.returncode==0

def run(app,host,resources,extra_inputs=()):
    with tempfile.TemporaryDirectory(prefix='spektralab-agent-smoke-') as temp:
        root=Path(temp);image=root/'源图.png';png(image);digest=hashlib.sha256(image.read_bytes()).hexdigest()
        profile=root/'profile';data=profile/'app.spektralab.desktop';access=data/'Agents/access.json'
        env=dict(os.environ,APPDATA=str(profile),XDG_DATA_HOME=str(profile),SPEKTRALAB_AGENT_APP=str(app/'spektralab.exe'),SPEKTRALAB_AGENT_HOST=str(host),SPEKTRALAB_AGENT_RESOURCES=str(resources))
        cmd=[str(app/'agents/node.exe'),str(app/'agents/agent.mjs')]
        def cli(*args,code=0):
            p=subprocess.run(cmd+list(args),env=env,text=True,encoding='utf-8',capture_output=True,timeout=120)
            assert p.returncode==code,(args,p.returncode,p.stdout,p.stderr);return json.loads(p.stdout)
        assert cli('status')['enabled'] is False
        assert cli('schema',code=2)['refused']
        with (root/'stderr.log').open('w',encoding='utf-8') as log:
            m=Lines(cmd+['mcp'],env,log)
            assert m.send('initialize',{'protocolVersion':'2025-06-18'},True)['result']['capabilities']['tools']=={}
            assert len(m.send('tools/list',rpc=True)['result']['tools'])==12
            def tool(name,args=None):return m.send('tools/call',{'name':name,'arguments':args or {}},True)['result']
            def good(name,args=None):
                r=tool(name,args);assert not r['isError'],r;return json.loads(r['content'][0]['text'])
            assert tool('get_schema')['isError']
            access.parent.mkdir(parents=True,exist_ok=True);access.write_text('{"enabled":true}')
            schema=good('get_schema');assert len(schema['fields'])>100
            # Existing invalid preferences must not silently use different pixels.
            rendering=access.parent/'rendering.json';rendering.write_text('{bad')
            assert tool('get_schema')['isError']
            rendering.write_text('{"recalculateEffectsAfterCrop":true,"diBlueCompensation":true}')
            good('get_schema')
            info=good('describe_image',{'path':str(image)});assert(info['width'],info['height'])==(64,48)
            old=good('get_edit',{'path':str(image)})
            patch={'adjustments':{'exposure':.25},'params':{'grainActive':False,'halationActive':False,'glareActive':False}}
            good('edit_image',{'path':str(image),'patch':patch,'preview':False})
            edited=good('get_edit',{'path':str(image)});assert edited['adjustments']['exposure']==.25
            sidecar=list((data/'Sidecars').glob('*.spektra.json'))[0];saved=sidecar.read_bytes()
            assert tool('edit_image',{'path':str(image),'patch':{'params':{'exposureCompensationEV':9}},'preview':False})['isError']
            assert sidecar.read_bytes()==saved
            good('process_image',{'path':str(image),'preview':False})
            measured=good('measure_latitude',{'path':str(image)});assert 'medium'in measured and 'fit'in measured
            good('place_scene',{'path':str(image),'highlight':0,'shadow':0,'preview':False})
            preview=root/'预览.jpg';good('preview_image',{'path':str(image),'output':str(preview),'long_edge':128});assert preview.read_bytes()[:2]==b'\xff\xd8'
            before=preview.read_bytes();assert tool('preview_image',{'path':str(image),'output':str(preview)})['isError'];assert preview.read_bytes()==before
            export=good('export_image',{'path':str(image),'folder':str(root/'导出')});assert len(export['files'])==1 and Path(export['files'][0]).is_file()
            pair=root/'半格.spektrapair'
            recipe={'schemaVersion':1,'folder':str(root),'left':{'path':str(image)},'right':None,'spacingMM':1,'onStrip':False,'turned':False}
            pair.write_text(json.dumps(recipe),encoding='utf-8')
            good('get_edit',{'path':str(pair)})
            partial=good('describe_image',{'path':str(pair)});assert partial['pair_info']['left']['available']
            assert tool('preview_image',{'path':str(pair),'output':str(root/'partial.jpg')})['isError']
            recipe['right']={'path':str(image)};pair.write_text(json.dumps(recipe),encoding='utf-8')
            good('preview_image',{'path':str(pair),'output':str(root/'pair.jpg'),'long_edge':128})
            for index,source in enumerate(extra_inputs):
                info=good('describe_image',{'path':str(source)});assert info['width']>0 and info['height']>0
                good('preview_image',{'path':str(source),'output':str(root/f'extra-{index}.jpg'),'long_edge':128})
            # Another process's lease is refused; killing that process releases it.
            f=Lines([str(app/'spektralab.exe'),'--agent-files'],env,log);assert f.send('begin')['ok']
            assert tool('get_edit',{'path':str(image)})['isError'];f.p.kill();f.p.wait(timeout=10)
            assert good('get_edit',{'path':str(image)})['adjustments']['exposure']==.25
            access.write_text('{"enabled":false}');assert tool('get_edit',{'path':str(image)})['isError']
            m.stop()
        assert hashlib.sha256(image.read_bytes()).hexdigest()==digest
        assert list(root.glob('*.spektra.json'))==[],'Agent wrote sidecar beside photograph'
        assert old['decode']==edited['decode']
    print(f'Agent actual CLI/MCP: opt-in/revocation, preferences, schemas, sidecars, Process/Fit, preview/export, complete/partial pairs, {len(extra_inputs)} extra input formats, Unicode paths, source protection and killed-process lease recovery PASS')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--host',type=Path,required=True);p.add_argument('--resources',type=Path,required=True);p.add_argument('--extra-input',type=Path,action='append',default=[]);a=p.parse_args();run(a.app,a.host,a.resources,a.extra_input)
