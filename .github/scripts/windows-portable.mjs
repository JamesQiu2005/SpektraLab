// Assemble the portable from the same installed files just checked by CI.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { releaseInfo } from './windows-release.mjs';
import { verifiedWindowsRuntimeNotices } from './windows-runtime-notices.mjs';
import { verifyWindowsBuild, windowsBuildSource } from './windows-build-source.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const installed = process.argv.indexOf('--installed');
if (installed < 0 || !process.argv[installed + 1]) throw Error('--installed is required');
const source = resolve(process.argv[installed + 1]);
const output = process.argv.indexOf('--output-root');
if (output >= 0 && !process.argv[output + 1]) throw Error('--output-root needs a directory');
const { version } = releaseInfo(repo);
const recordFile = join(source, 'host/windows-build.json');
const hasRecord = existsSync(recordFile);
const record = hasRecord ? JSON.parse(readFileSync(recordFile, 'utf8')) : null;
const sourceIdentity = hasRecord ? windowsBuildSource(repo) : {
  commit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim(),
  dirty: execFileSync('git', ['status', '--porcelain'], { cwd: repo, encoding: 'utf8' }).trim().length > 0,
};
const { commit, dirty } = sourceIdentity;
if (process.env.GITHUB_SHA && process.env.GITHUB_SHA !== commit) throw Error('Checkout does not match GITHUB_SHA');
if (process.env.GITHUB_SHA && dirty) throw Error('Portable artifacts require a clean checkout in CI');
if (process.env.GITHUB_SHA && !hasRecord) throw Error('Installed app is missing its Windows build source record');
const name = 'SpektraLab-' + version + '-windows-x64-portable';
const target = join(output >= 0 ? resolve(process.argv[output + 1]) : join(repo, 'desktop/release/windows'), name);
if (existsSync(target)) throw Error('Portable destination already exists');
const config = JSON.parse(readFileSync(join(repo, 'desktop/src-tauri/tauri.windows.conf.json'), 'utf8'));
const executable = config.mainBinaryName + '.exe';
const required = [executable, 'spektralab-host.exe', 'spklib-host.exe', 'host/engine/spektrafilm_constants.bin',
  'agents/node.exe', 'agents/agent.mjs', 'agents/NODE-LICENSE.txt'];
for (const name of required) if (!existsSync(join(source, name))) throw Error('Installed app lacks ' + name);
const notices = verifiedWindowsRuntimeNotices(repo, version);
if (hasRecord) verifyWindowsBuild(record, sourceIdentity, version, join(source, 'spektralab-host.exe'));
mkdirSync(target, { recursive: true });
for (const entry of readdirSync(source, { withFileTypes: true })) {
  if (/^uninstall.*\.exe$/i.test(entry.name)) continue;
  cpSync(join(source, entry.name), join(target, entry.name), { recursive: true, errorOnExist: true, force: false });
}
execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(repo, '.github/scripts/windows-notices.ps1'), '-ArchivePath', notices, '-Destination', target], { stdio: 'inherit', windowsHide: true });
mkdirSync(join(target, 'licenses/project'), { recursive: true });
for (const file of ['LICENSE', 'SPEKTRAFILM_LICENSE.txt']) cpSync(join(repo, 'license', file), join(target, 'licenses/project', file));
for (const name of ['Cargo.lock', 'Cargo.toml']) cpSync(join(repo, 'desktop/src-tauri', name), join(target, 'licenses', name));
cpSync(join(repo, 'desktop/package-lock.json'), join(target, 'licenses/package-lock.json'));
cpSync(join(repo, 'desktop/agent/licenses/node-v24.19.0-LICENSE.txt'), join(target, 'licenses/Node-LICENSE.txt'));
writeFileSync(join(target, 'spektralab-cli.cmd'), '@echo off\r\n"%~dp0agents\\node.exe" "%~dp0agents\\agent.mjs" %*\r\n');
writeFileSync(join(target, 'README.txt'), [
  'SpektraLab Windows ' + version,
  'Extract the complete ZIP and run ' + executable + '. Do not mix files from older versions.',
  'Requires Windows x64, a working Vulkan driver and Microsoft Edge WebView2 Runtime.',
  'Portable means no installation; settings, caches and logs still use your Windows profile.',
  (dirty ? 'Local validation build with uncommitted changes; base commit: ' : 'Source commit: ') + commit,
  ...(record ? ['Source tree: ' + record.sourceTree] : []),
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
writeFileSync(join(target, 'BUILD-MANIFEST.json'), JSON.stringify({ version, commit, dirty, ...(record ? { sourceTree: record.sourceTree, hostSha256: record.hostSha256 } : {}), files }, null, 2) + '\n');
console.log('Staged ' + name + ' from the installed app (' + files.length + ' files).');

