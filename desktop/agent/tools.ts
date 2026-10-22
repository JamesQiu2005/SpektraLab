import { Refused } from './schema';
export interface ToolArgs { path?:string; patch?:unknown; preview?:boolean; highlight?:number; shadow?:number; output?:string; long_edge?:number; recipe?:string; folder?:string }
interface Property { type:string; minimum?:number; maximum?:number; description?:string }
const path={type:'string',description:'Absolute path of an existing photograph or half-frame pair.'};
const preview={type:'boolean',description:'Return a small preview (default true).'};
export const tools=[
  ['get_schema','schema','Every editable field, range and read-only rule.',{},[]],
  ['list_stocks','stocks','Film and paper stock IDs.',{},[]],
  ['list_recipes','recipes','Saved export recipes.',{},[]],
  ['describe_image','info','Image dimensions, metadata and processing state.',{path},['path']],
  ['get_edit','get','The four edit sections used by the application.',{path},['path']],
  ['edit_image','edit','Strict JSON merge patch. Invalid fields are refused without writing. Originals are preserved.',{path,patch:{type:'object'},preview},['path','patch']],
  ['reset_edit','reset','Reset film, print, grade and geometry; preserve decode.',{path,preview},['path']],
  ['process_image','process','Develop, meter and solve the print filter pack; clear Y/M offsets.',{path,preview},['path']],
  ['measure_latitude','latitude','Measure the scene and medium latitude and suggested pull-backs.',{path},['path']],
  ['place_scene','place','Apply Scene Placement only if the engine Fit accepts it.',{path,highlight:{type:'number',minimum:0,maximum:6},shadow:{type:'number',minimum:0,maximum:6},preview},['path','highlight','shadow']],
  ['preview_image','preview','Render a small finished sRGB JPEG.',{path,output:{type:'string'},long_edge:{type:'integer',minimum:64,maximum:4096}},['path']],
  ['export_image','export','Write with a named saved recipe. Export only when requested.',{path,recipe:{type:'string'},folder:{type:'string'}},['path']],
].map(([name,command,description,properties,required])=>({name:name as string,command:command as string,description:description as string,
  inputSchema:{type:'object',properties:properties as Record<string,Property>,required:required as string[],additionalProperties:false}}));
export function checkTool(name:string,args:unknown):ToolArgs{
  const tool=tools.find(t=>t.name===name);if(!tool)throw new Refused('Unknown tool: '+name);
  if(!args||typeof args!=='object'||Array.isArray(args))throw new Refused('Arguments must be an object.');
  const a=args as Record<string,unknown>;
  for(const key of tool.inputSchema.required)if(!(key in a))throw new Refused(`${name} needs ${key}.`);
  for(const[key,value]of Object.entries(a)){
    const p=tool.inputSchema.properties[key];if(!p)throw new Refused(`Unknown argument: ${key}`);
    if(p.type==='object'?(!value||typeof value!=='object'||Array.isArray(value)):p.type==='integer'?(!Number.isInteger(value)):typeof value!==p.type)throw new Refused(`Invalid ${key}: expected ${p.type}.`);
    if(typeof value==='number'&&(!Number.isFinite(value)||(p.minimum!==undefined&&value<p.minimum)||(p.maximum!==undefined&&value>p.maximum)))throw new Refused(`Invalid range for ${key}.`);
    if(typeof value==='string'&&(!value||value.includes('\0')))throw new Refused(`Invalid ${key}.`);
  }
  return a as ToolArgs;
}
export const instructions='SpektraLab develops film and prints onto paper. Read describe_image and get_schema, process_image once, then use small physical edits and inspect previews. Scene Placement must pass place_scene. Nothing overwrites an original. Export only when requested. Agent access is controlled by Settings > Agents; turning it off refuses the next call.';
export const editPrompt={name:'edit_photo',title:'Edit a photo from one sentence',description:'Edit a photograph with film, paper and physical controls.',arguments:[{name:'path',description:'Image path',required:true},{name:'instruction',description:'Desired look',required:true}]};
export async function mcp<R>(input:unknown,call:(name:string,args:ToolArgs)=>Promise<R>,image:(result:R)=>Promise<unknown[]>){
  const message=input as {id?:unknown;jsonrpc?:string;method?:string;params?:Record<string,unknown>};
  if(!message||typeof message!=='object'||Array.isArray(message))return{jsonrpc:'2.0',id:null,error:{code:-32600,message:'Invalid Request'}};
  if(!('id'in message))return null;
  const result=(r:unknown)=>({jsonrpc:'2.0',id:message.id,result:r});
  const error=(code:number,text:string)=>({jsonrpc:'2.0',id:message.id,error:{code,message:text}});
  if(message.jsonrpc!=='2.0'||typeof message.method!=='string')return error(-32600,'Invalid Request');
  const p=message.params??{};
  switch(message.method){
    case'initialize':return result({protocolVersion:'2025-06-18',capabilities:{tools:{},prompts:{}},serverInfo:{name:'spektralab',title:'SpektraLab',version:'1.3.3'},instructions});
    case'ping':return result({});
    case'tools/list':return result({tools:tools.map(({command:_command,...t})=>t)});
    case'tools/call':if(typeof p.name!=='string')return error(-32602,'tools/call needs a name');try{const a=checkTool(p.name,p.arguments??{});const r=await call(p.name,a);return result({content:await image(r),isError:false})}catch(e){return result({content:[{type:'text',text:(e instanceof Refused?'Refused: ':'Failed: ')+(e as Error).message}],isError:true})}
    case'prompts/list':return result({prompts:[editPrompt]});
    case'prompts/get':{if(p.name!=='edit_photo')return error(-32602,'No such prompt');const a=(p.arguments??{}) as Record<string,unknown>;return result({description:editPrompt.description,messages:[{role:'user',content:{type:'text',text:`Edit ${a.path??'<path>'} to match: ${a.instruction??''}. Read describe_image, get_schema and process_image. Prefer film, paper, exposure and Scene Placement; inspect each preview before refining.`}}]});}
    default:return error(-32601,'Method not found');
  }
}
