import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { hostSha256 as fileSha256, windowsBuildSource } from './windows-build-source.mjs';

const manifest = 'host-artifact.json';

function fileMap(root, prefix = '') {
  const files = Object.create(null);
  for (const entry of readdirSync(join(root, prefix), { withFileTypes: true })) {
    const path = prefix ? prefix + '/' + entry.name : entry.name;
    if (path === manifest) continue;
    if (entry.isDirectory()) Object.assign(files, fileMap(root, path));
    else if (entry.isFile()) files[path] = fileSha256(join(root, path));
    else throw Error('Unexpected entry in staged Windows host: ' + path);
  }
  return files;
}

export function writeWindowsHostArtifact(root, commit) {
  const files = fileMap(root);
  if (!files['spektralab-host.exe']) throw Error('Staged Windows host executable is missing');
  writeFileSync(join(root, manifest), JSON.stringify({ schema: 1, commit, files }, null, 2) + '\n');
}

export function verifyWindowsHostArtifact(root, commit) {
  const path = join(root, manifest);
  if (!existsSync(path)) throw Error('Staged Windows host is missing its artifact record');
  const record = JSON.parse(readFileSync(path, 'utf8'));
  if (record?.schema !== 1 || record.commit !== commit || !record.files || Array.isArray(record.files) ||
      typeof record.files !== 'object') {
    throw Error('Staged Windows host artifact is not from this checkout');
  }
  const files = fileMap(root);
  if (!files['spektralab-host.exe']) throw Error('Staged Windows host executable is missing');
  for (const name of new Set([...Object.keys(files), ...Object.keys(record.files)])) {
    if (!Object.hasOwn(files, name) || !Object.hasOwn(record.files, name) || files[name] !== record.files[name]) {
      throw Error('Staged Windows host artifact differs at ' + name);
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [action, root] = process.argv.slice(2);
  if (!root || !['write', 'verify'].includes(action)) {
    throw Error('Usage: node windows-host-artifact.mjs <write|verify> <staged-host-directory>');
  }
  const commit = process.env.GITHUB_SHA;
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) throw Error('Windows host artifact requires GITHUB_SHA');
  if (action === 'write') {
    const repo = fileURLToPath(new URL('../../', import.meta.url));
    const source = windowsBuildSource(repo);
    if (source.commit !== commit || source.dirty) {
      throw Error('Recording a Windows host artifact requires a clean checkout at GITHUB_SHA');
    }
    writeWindowsHostArtifact(resolve(root), commit);
  } else {
    verifyWindowsHostArtifact(resolve(root), commit);
  }
}
