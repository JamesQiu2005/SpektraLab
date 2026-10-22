import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Refused } from './schema';
export const here=dirname(fileURLToPath(import.meta.url));
export const appExe=process.env.SPEKTRALAB_AGENT_APP??[join(here,'..',process.platform==='win32'?'spektralab.exe':'spektralab'),
  ...(process.platform==='linux'?[join(process.env.APPDIR??'','usr/bin/spektralab'),'/usr/bin/spektralab']:[])].find(p=>existsSync(p))??join(here,'..','spektralab.exe');
interface Reply<T=unknown> { result:T; payload:Buffer }
interface Header { id?:number; ok?:boolean; result?:unknown; error?:string|{message?:string;code?:string} }
type Waiter={resolve:(v:Reply)=>void;reject:(e:Error)=>void;timer:ReturnType<typeof setTimeout>};
class Child {
  process:ChildProcessWithoutNullStreams; next=1; waiting=new Map<number,Waiter>();
  constructor(executable:string,args:string[]){
    this.process=spawn(executable,args,{stdio:['pipe','pipe','pipe'],windowsHide:true});
    this.process.stderr.on('data',b=>process.stderr.write(b));
    this.process.on('error',e=>this.fail(e));this.process.on('exit',()=>this.fail(new Error('SpektraLab service exited.')));
  }
  fail(e:Error){for(const w of this.waiting.values()){clearTimeout(w.timer);w.reject(e)}this.waiting.clear()}
  receive(q:Header,payload=Buffer.alloc(0)) {const w=this.waiting.get(q.id??-1);if(!w)return;this.waiting.delete(q.id??-1);clearTimeout(w.timer);if(q.ok===false)w.reject(Object.assign(new Error(typeof q.error==='string'?q.error:(typeof q.error==='object'?q.error.message:undefined)??'Service failed'),{code:typeof q.error==='object'?q.error.code:undefined}));else w.resolve({result:q.result,payload});}
  send(method:string,params:Record<string,unknown>,binary:boolean,timeout=300000):Promise<Reply>{
    const id=this.next++,json=Buffer.from(JSON.stringify({id,method,params}));
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.waiting.delete(id);this.process.kill();reject(new Error(`Timed out: ${method}`))},timeout);this.waiting.set(id,{resolve,reject,timer});
      if(binary){const prefix=Buffer.alloc(8);prefix.writeUInt32LE(json.length);this.process.stdin.write(Buffer.concat([prefix,json]));}else this.process.stdin.write(json.toString()+'\n');});
  }
  stop(){this.process.stdin.end();setTimeout(()=>this.process.kill(),2000).unref()}
}
export class FileService extends Child {
  constructor(){super(appExe,['--agent-files']);createInterface({input:this.process.stdout}).on('line',line=>{try{this.receive(JSON.parse(line))}catch{this.fail(new Error('Invalid file-service response'))}})}
  async call<T=unknown>(method:string,params:Record<string,unknown>={}):Promise<T> {try{return(await this.send(method,params,false)).result as T}catch(e){throw new Refused((e as Error).message)}}
}
export class NativeHost extends Child {
  private buffered=Buffer.alloc(0);
  constructor(){
    const dir=process.env.SPEKTRALAB_HOST_DIR??dirname(appExe);
    const executable=process.env.SPEKTRALAB_AGENT_HOST??join(dir,process.platform==='win32'?'spektralab-host.exe':'spektralab-host');
    const resources=process.env.SPEKTRALAB_AGENT_RESOURCES??[join(dir,'engine'),join(dir,'host','engine'),join(here,'..','host','engine')].find(p=>existsSync(p));
    if(!resources)throw new Error('Engine resources are missing. Reinstall the complete application.');
    super(executable,['--resources',resources]);
    this.process.stdout.on('data',(b:Buffer)=>{
      this.buffered=Buffer.concat([this.buffered,b]);
      while(this.buffered.length>=8){const h=this.buffered.readUInt32LE(0),p=this.buffered.readUInt32LE(4);
        if(h>8*1024*1024||p>128*1024*1024){this.fail(new Error('Oversized engine response'));this.process.kill();return}
        if(this.buffered.length<8+h+p)return;
        try{this.receive(JSON.parse(this.buffered.subarray(8,8+h).toString()),this.buffered.subarray(8+h,8+h+p))}catch(e){this.fail(e as Error)}
        this.buffered=this.buffered.subarray(8+h+p);
      }
    });
  }
  request=(method:string,params:Record<string,unknown>={},opts?:{timeoutMs?:number})=>this.send(method,params,true,opts?.timeoutMs??300000);
  async result<T=Record<string,unknown>>(method:string,params:Record<string,unknown>={}):Promise<T>{return(await this.request(method,params)).result as T}
}
export function absolute(path:string){return resolve(path.startsWith('~/')?join(process.env.USERPROFILE??process.env.HOME??'',path.slice(2)):path)}
