import { readFile } from 'node:fs/promises';
import { tools, checkTool } from './tools';
import { Refused } from './schema';
import { absolute } from './io';
export async function parse(argv:string[],stdin=async()=>{let s='';for await(const b of process.stdin){s+=b;if(s.length>1024*1024)throw new Refused('Patch exceeds1MiB')}return s}){
  const [command,...rest]=argv,tool=tools.find(t=>t.command===command);if(!tool)throw new Refused('Unknown command. Use help.');
  const args:Record<string,unknown>={};let previewOut:string|undefined;
  if('path'in tool.inputSchema.properties){const file=rest.shift();if(!file||file.startsWith('-'))throw new Refused('A photograph path is required');args.path=absolute(file)}
  while(rest.length){const flag=rest.shift()!,v=rest.shift();if(v===undefined)throw new Refused(flag+' requires a value');
    if(flag==='--patch'&&tool.name==='edit_image'){const text=v==='-'?await stdin():v.startsWith('@')?await readFile(absolute(v.slice(1)),'utf8'):v;if(text.length>1024*1024)throw new Refused('Patch exceeds1MiB');try{args.patch=JSON.parse(text)}catch{throw new Refused('Patch is not valid JSON')}}
    else if(flag==='--preview'&&'preview'in tool.inputSchema.properties){previewOut=absolute(v);args.preview=true}
    else if((flag==='-o'||flag==='--output')&&tool.name==='preview_image')args.output=absolute(v);
    else if(flag==='--long-edge'&&tool.name==='preview_image')args.long_edge=Number(v);
    else if((flag==='--highlight'||flag==='--shadow')&&tool.name==='place_scene')args[flag.slice(2)]=Number(v);
    else if(flag==='--recipe'&&tool.name==='export_image')args.recipe=v;
    else if(flag==='--to'&&tool.name==='export_image')args.folder=absolute(v);
    else throw new Refused('Unknown option: '+flag);
  }
  if('preview'in tool.inputSchema.properties&&args.preview===undefined)args.preview=false;
  if(tool.name==='preview_image'&&!args.output)throw new Refused('preview needs -o OUT.jpg');
  return{name:tool.name,args:checkTool(tool.name,args),previewOut};
}
