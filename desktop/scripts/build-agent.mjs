// Build the user CLI/MCP and optionally stage its runtime beside an app.
// node scripts/build-agent.mjs [APP_DIRECTORY] [--runtime]
import { build } from 'esbuild';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync, cpSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const desktop=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const app=resolve(process.argv.slice(2).find(a=>!a.startsWith('--'))??join(desktop,'agent-dist'));
const out=join(app,'agents');mkdirSync(out,{recursive:true});
await build({entryPoints:[join(desktop,'agent/main.ts')],outfile:join(out,'agent.mjs'),bundle:true,platform:'node',format:'esm',target:'node22',
  tsconfig:join(desktop,'tsconfig.base.json'),plugins:[{name:'headless-adapters',setup(b){
    b.onResolve({filter:/^(\.\.\/platform|\.\.\/host\/client)$/},args=>{
      if(!args.importer.replaceAll('\\','/').includes('/src/export/'))return;
      return{path:join(desktop,'agent',args.path.endsWith('client')?'host.ts':'platform.ts')};
    });
  }}]});
// Packaging stages the CLI before Tauri's web build generates public/assets.
// Read the tracked source so clean builds work and stale web assets cannot ship.
cpSync(resolve(desktop,'../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json'),join(out,'StockCatalog.json'));
// --target=win32 stages a Windows runtime from another OS (the macOS cross build of the
// installer): the executable cannot be run here, so it is identified by the SHA-256 the
// Node project publishes for it (https://nodejs.org/dist/v24.19.0/SHASUMS256.txt).
const NODE_SHA256={'win32-x64':'3602f2bb1a10f2cbab4c36886218a33c1ab3db87290e73b033c46c77147d0237'};
const targetPlatform=(process.argv.find(a=>a.startsWith('--target='))??'').slice('--target='.length)||process.platform;
const targetArch=targetPlatform===process.platform?process.arch:'x64';
if(process.argv.includes('--runtime')){
  const cross=targetPlatform!==process.platform;
  const executable=process.env.SPEKTRALAB_NODE_RUNTIME??(cross?null:process.execPath);
  if(!executable)throw new Error(`Packaging for ${targetPlatform} needs its Node v24.19.0 executable (SPEKTRALAB_NODE_RUNTIME).`);
  const sha=b=>createHash('sha256').update(b).digest('hex');
  let version;
  if(cross){
    const want=NODE_SHA256[`${targetPlatform}-${targetArch}`];
    if(!want||sha(readFileSync(executable))!==want)throw new Error(`${executable} is not the published Node v24.19.0 for ${targetPlatform}-${targetArch}.`);
    version='v24.19.0';
  }else version=execFileSync(executable,['-p','process.version'],{encoding:'utf8',windowsHide:true}).trim();
  if(version!=='v24.19.0')throw new Error('Packaging needs the verified Node v24.19.0 runtime (SPEKTRALAB_NODE_RUNTIME).');
  const license=join(desktop,'agent/licenses/node-v24.19.0-LICENSE.txt');
  if(sha(readFileSync(license,'utf8').replaceAll('\r\n','\n'))!=='148eacf7863ef4329224a29398623077200a27194aa075569faf4a0a85566ca5')throw new Error('Node license checksum mismatch.');
  cpSync(executable,join(out,targetPlatform==='win32'?'node.exe':'node'));cpSync(license,join(out,'NODE-LICENSE.txt'));
  writeFileSync(join(out,'runtime.json'),JSON.stringify({node:version,platform:targetPlatform,arch:targetArch,binary_sha256:sha(readFileSync(executable)),license_sha256:sha(readFileSync(license)),license_source:'https://raw.githubusercontent.com/nodejs/node/v24.19.0/LICENSE'},null,2));
  const win='@echo off\r\nrem SpektraLab portable CLI\r\n"%~dp0agents\\node.exe" "%~dp0agents\\agent.mjs" %*\r\n';
  const unix='#!/bin/sh\nexec "$(dirname "$0")/agents/node" "$(dirname "$0")/agents/agent.mjs" "$@"\n';
  writeFileSync(join(app,targetPlatform==='win32'?'spektralab-cli.cmd':'spektralab-cli'),targetPlatform==='win32'?win:unix,{mode:0o755});
}
console.log(`Agent CLI staged at ${out}`);
