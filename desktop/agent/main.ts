import { readFile, copyFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { constants } from 'node:fs';
import { Workspace, removeTemporary, type Result } from './workspace';
import { mcp } from './tools';
import { parse } from './cli';
import { Refused } from './schema';
const usage=`SpektraLab CLI: status | schema | stocks | recipes | info|get|reset|process|latitude FILE
edit FILE --patch JSON|@FILE|- [--preview OUT.jpg]
place FILE --highlight STOPS --shadow STOPS [--preview OUT.jpg]
preview FILE -o OUT.jpg [--long-edge N]
export FILE [--recipe NAME] [--to DIRECTORY]
mcp  (newline JSON-RPC over stdio)
Enable Settings > Agents first. Source photographs are never overwritten.\n`;
async function main(){
  const argv=process.argv.slice(2),command=argv[0];
  if(!command||['help','--help','-h'].includes(command)){process.stdout.write(usage);return}
  let ws:Workspace|undefined;
  try{
    if(command==='mcp'){
      ws=new Workspace();const lines=createInterface({input:process.stdin,crlfDelay:Infinity});
      for await(const line of lines){if(!line.trim())continue;let response;
        if(line.length>2*1024*1024){response={jsonrpc:'2.0',id:null,error:{code:-32600,message:'Request exceeds2MiB'}}}
        else try{const message=JSON.parse(line);response=await mcp(message,(name,args)=>ws!.call(name,args),async(r:Result)=>{
          try{const content:unknown[]=[{type:'text',text:JSON.stringify(r.body)}];if(r.preview){const b=await readFile(r.preview);if(b.length>32*1024*1024)throw new Error('Preview exceeds32MiB');content.push({type:'image',mimeType:'image/jpeg',data:b.toString('base64')})}return content}finally{await removeTemporary(r)}})}catch{response={jsonrpc:'2.0',id:null,error:{code:-32700,message:'Parse error'}}}
        if(response)process.stdout.write(JSON.stringify(response)+'\n');
      }
      return;
    }
    // Parse/validate syntax before spawning any application or engine process.
    const parsed=command==='status'?null:await parse(argv);ws=new Workspace();
    if(!parsed){process.stdout.write(JSON.stringify({ok:true,...await ws.status()})+'\n');return}
    const r=await ws.call(parsed.name,parsed.args);
    try{const body=(r.body&&typeof r.body==='object'?r.body:{result:r.body}) as Record<string,unknown>;
      if(parsed.previewOut&&r.preview){await copyFile(r.preview,parsed.previewOut,constants.COPYFILE_EXCL);body.preview=parsed.previewOut}
      process.stdout.write(JSON.stringify({ok:true,...body})+'\n');
    }finally{await removeTemporary(r)}
  }catch(e){process.stdout.write(JSON.stringify({ok:false,refused:e instanceof Refused,error:(e as Error).message})+'\n');process.exitCode=e instanceof Refused?2:1}
  finally{if(ws)await ws.stop()}
}
void main();
