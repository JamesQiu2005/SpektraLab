// Bundle-time adapter for the same captureExportFrames/exportFrame modules.
import { mkdir, access, readFile } from 'node:fs/promises';
import { Refused } from './schema';
import type { FileService } from './io';
let service:FileService;
export function setFiles(s:FileService){service=s}
export const baseName=(p:string)=>p.split(/[\\/]/).pop()??p;
export const dirName=(p:string)=>{const i=Math.max(p.lastIndexOf('/'),p.lastIndexOf('\\'));return i>0?p.slice(0,i):p};
export const joinPath=(dir:string,name:string)=>dir.replace(/[\\/]$/,'')+'/'+name;
export const platform=()=>({
  sidecarLoad:(image:string)=>service.call('sidecar_load',{path:image}),
  pairLoad:async(path:string)=>{const b=await readFile(path);if(b.length>1024*1024)throw new Refused('Pair document too large');return JSON.parse(b.toString())},
  ensureDir:async(path:string)=>{await mkdir(path,{recursive:true})},
  pathExists:async(path:string)=>{try{await access(path);return true}catch{return false}},
  log:(_level:string,message:string)=>process.stderr.write(message+'\n'),
});
