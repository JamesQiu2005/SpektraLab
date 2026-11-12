// Assemble the portable from the same installed files just checked by CI.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { releaseInfo } from './windows-release.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const installed = process.argv.indexOf('--installed');
if (installed < 0 || !process.argv[installed + 1]) throw Error('--installed is required');
const source = resolve(process.argv[installed + 1]);
const { version } = releaseInfo(repo);
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
if (process.env.GITHUB_SHA && process.env.GITHUB_SHA !== commit) throw Error('Checkout does not match GITHUB_SHA');
const name = 'SpektraLab-' + version + '-windows-x64-portable';
const target = join(repo, 'desktop/release/windows', name);
if (existsSync(target)) throw Error('Portable destination already exists');
const required = ['spektralab.exe', 'spektralab-host.exe', 'host/engine/spektrafilm_constants.bin',
  'agents/node.exe', 'agents/agent.mjs', 'agents/NODE-LICENSE.txt'];
for (const name of required) if (!existsSync(join(source, name))) throw Error('Installed app lacks ' + name);
mkdirSync(target, { recursive: true });
for (const entry of readdirSync(source, { withFileTypes: true })) {
  if (/^uninstall.*\.exe$/i.test(entry.name)) continue;
  cpSync(join(source, entry.name), join(target, entry.name), { recursive: true, errorOnExist: true, force: false });
}
const pin = JSON.parse(readFileSync(join(repo, 'license/windows-runtime-notices.json'), 'utf8'));
for (const [path, expected] of Object.entries(pin.locks)) {
  const text = readFileSync(join(repo, path), 'utf8').replaceAll('\r\n', '\n').replaceAll(version, pin.baseline_version);
  if (createHash('sha256').update(text).digest('hex') !== expected) throw Error('Dependency notices need an audit: ' + path);
}
const notices = join(repo, 'license/windows-runtime-notices.zip');
if (createHash('sha256').update(readFileSync(notices)).digest('hex') !== pin.archive_sha256) throw Error('Dependency notice archive changed');
execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(repo, '.github/scripts/windows-notices.ps1'), '-ArchivePath', notices, '-Destination', target], { stdio: 'inherit', windowsHide: true });
cpSync(join(repo, 'license'), join(target, 'licenses/project'), { recursive: true });
for (const name of ['Cargo.lock', 'Cargo.toml']) cpSync(join(repo, 'desktop/src-tauri', name), join(target, 'licenses', name));
cpSync(join(repo, 'desktop/package-lock.json'), join(target, 'licenses/package-lock.json'));
cpSync(join(repo, 'desktop/agent/licenses/node-v24.19.0-LICENSE.txt'), join(target, 'licenses/Node-LICENSE.txt'));
writeFileSync(join(target, 'spektralab-cli.cmd'), '@echo off\r\n"%~dp0agents\\node.exe" "%~dp0agents\\agent.mjs" %*\r\n');
writeFileSync(join(target, 'README.txt'), [
  'SpektraLab Windows ' + version,
  'Extract the complete ZIP and run spektralab.exe. Do not mix files from older versions.',
  'Requires Windows x64, a working Vulkan driver and Microsoft Edge WebView2 Runtime.',
  'Portable means no installation; settings, caches and logs still use your Windows profile.',
  'Source commit: ' + commit,
  'Corresponding project source, dependency pins and build scripts accompany this release.',
  'https://github.com/' + (process.env.GITHUB_REPOSITORY || 'JamesQiu2005/SpektraLab'),
  ''
].join('\r\n'));
const files = [];
function inventory(folder, prefix = '') {
  for (const entry of readdirSync(folder, { withFileTypes: true })) {
    const path = join(folder, entry.name), name = prefix + entry.name;
    if (entry.isDirectory()) inventory(path, name + '/');
    else {
      const bytes = readFileSync(path);
      files.push({ path: name, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
    }
  }
}
inventory(target);
writeFileSync(join(target, 'BUILD-MANIFEST.json'), JSON.stringify({ version, commit, files }, null, 2) + '\n');
console.log('Staged ' + name + ' from the installed app (' + files.length + ' files).');

