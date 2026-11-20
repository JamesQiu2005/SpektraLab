// check-installer.mjs — T6: the Windows installer, listed, never run.
//
//   node scripts/check-installer.mjs [path/to/SpektraLab_<version>_x64-setup.exe]
//
// With no path it takes the newest *-setup.exe in release/windows/ (where
// `npm run package:win` writes it). No installer is a failure, not a skip.
// It asserts, with `file` and 7-Zip:
//  - the installer is an NSIS self-extracting archive. NSIS's own stub is a
//    32-bit (PE32, i386) program whatever it installs, so that is what `file`
//    must say of it; what it installs is checked below;
//  - the members the app needs: the v2 app, the engine host
//    (spektralab-host.exe), a WebView2 loader for GNU builds, resources under
//    host/engine/ (the constants, the film and paper profiles, the .spv
//    kernels), the licences, the uninstaller;
//  - the app, the host and the library helper (spklib-host.exe), extracted to a
//    scratch folder, are PE32+ x86-64; the helper is byte for byte the vendored
//    one (vendor/spklib/windows-x64/spklib-host.exe.sha256); the host carries the
//    pinned LibRaw's version string (engine/setup-libraw.sh) and not the old pin's;
//  - the licences: the host's (GPL, LibRaw's LGPL, COPYRIGHT and SOURCE) and spklib's MIT.
//  - the version in its name is package.json's, and so are the app's version
//    resource's ProductName ("SpektraLab") and ProductVersion.
// Nothing is executed but `file` and `7zz`.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const windowsConfig = JSON.parse(readFileSync(join(desktop, 'src-tauri/tauri.windows.conf.json'), 'utf8'));
const appName = windowsConfig.mainBinaryName + '.exe';
const productName = windowsConfig.productName;
const failures = [];
const fail = (m) => failures.push(m);
const run = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 << 20 });
const sevenZip = process.env.SPEKTRALAB_7ZIP ?? (process.platform === 'win32' ? '7z.exe' : '7zz');

let exe = process.argv[2];
if (!exe) {
  const dir = join(desktop, 'release', 'windows');
  const found = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('-setup.exe')).map((f) => join(dir, f)) : [];
  found.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  exe = found[0];
}
if (!exe || !existsSync(exe)) {
  console.error(`check-installer: no installer${exe ? ` at ${exe}` : ' in release/windows/'} — run npm run package:win first`);
  process.exit(1);
}

const version = JSON.parse(readFileSync(join(desktop, 'package.json'), 'utf8')).version;
if (!basename(exe).includes(`_${version}_`)) fail(`the installer's name ${basename(exe)} does not carry version ${version}`);

const kind = run('file', ['-b', exe]).trim();
if (!/^PE32 executable.*\(GUI\).*Intel (?:i386|80386).*Nullsoft Installer self-extracting archive/.test(kind)) fail(`file says "${kind}", not an NSIS installer`);

const listing = run(sevenZip, ['l', '-slt', exe]);
if (!/^Type = Nsis$/m.test(listing)) fail('7zz does not read it as an NSIS archive');
const members = [...listing.matchAll(/^Path = (.+)$/gm)].map((m) => m[1].replaceAll('\\', '/')).slice(1);
const has = (p) => members.includes(p);
const count = (re) => members.filter((m) => re.test(m)).length;

const required = [
  appName, 'spektralab-host.exe', 'spklib-host.exe', 'uninstall.exe',
  'agents/node.exe', 'agents/agent.mjs', 'agents/NODE-LICENSE.txt',
  'host/licenses/LibRaw-LGPL-2.1.txt', 'host/licenses/LibRaw-COPYRIGHT.txt', 'host/licenses/LibRaw-SOURCE.txt',
  'host/licenses/spklib-LICENSE.txt', 'host/licenses/spklib-VERSION.txt',
  'host/licenses/windows-v2-runtime-notices.zip',
  'host/engine/spektrafilm_constants.bin', 'host/engine/print_luts.json', 'host/engine/io/sRGB.icc',
  'host/engine/profiles/kodak_portra_400.json', 'host/engine/profiles/kodak_portra_endura.json',
];
// More members a caller requires (comma-separated).
required.push(...(process.env.SPEKTRALAB_INSTALLER_REQUIRE ?? '').split(',').map((x) => x.trim()).filter(Boolean));
for (const p of required) if (!has(p)) fail(`missing member ${p}`);
const spv = count(/^host\/engine\/.+\.spv$/);
if (spv < 30) fail(`only ${spv} .spv kernels under host/engine/ (v1 ships 34 or more)`);
const profiles = count(/^host\/engine\/profiles\/.+\.json$/);
if (profiles < 20) fail(`only ${profiles} profiles under host/engine/profiles/`);
const licences = count(/^host\/licenses\/.+/);
if (licences < 1) fail('no licence texts under host/licenses/');

const scratch = mkdtempSync(join(process.env.CLAUDE_JOB_DIR ? join(process.env.CLAUDE_JOB_DIR, 'tmp') : tmpdir(), 'installer-'));
try {
  run(sevenZip, ['e', '-y', `-o${scratch}`, exe, appName, 'spektralab-host.exe', 'spklib-host.exe']);
  for (const [name, gui] of [[appName, true], ['spektralab-host.exe', false], ['spklib-host.exe', false]]) {
    const p = join(scratch, name);
    if (!existsSync(p)) { fail(`could not extract ${name}`); continue; }
    const k = run('file', ['-b', p]).trim();
    if (!new RegExp(`^PE32\\+ executable.*\\(${gui ? 'GUI' : 'console'}\\).*x86-64`).test(k)) fail(`${name}: file says "${k}", not a PE32+ x86-64 ${gui ? 'GUI' : 'console'} program`);
  }
  // The helper is the vendored build, byte for byte.
  const helper = join(scratch, 'spklib-host.exe');
  if (existsSync(helper)) {
    const want = readFileSync(join(desktop, '..', 'vendor', 'spklib', 'windows-x64', 'spklib-host.exe.sha256'), 'utf8').trim().split(/\s+/)[0];
    const got = createHash('sha256').update(readFileSync(helper)).digest('hex');
    if (got !== want) fail(`spklib-host.exe is ${got}, not the vendored ${want}`);
    else console.log(`spklib-host.exe: ${got} (the vendored build)`);
  }
  // The host carries the pinned LibRaw (engine/setup-libraw.sh: "reports itself as <version>").
  const host = join(scratch, 'spektralab-host.exe');
  const pin = /reports itself as (\S+)/.exec(readFileSync(join(desktop, '..', 'engine', 'setup-libraw.sh'), 'utf8'))?.[1];
  if (!pin) fail('engine/setup-libraw.sh does not say which LibRaw it pins');
  else if (existsSync(host)) {
    const bytes = readFileSync(host);
    if (!bytes.includes(Buffer.from(pin))) fail(`spektralab-host.exe does not carry LibRaw ${pin}`);
    else if (bytes.includes(Buffer.from('0.22.2-Release'))) fail('spektralab-host.exe still carries LibRaw 0.22.2');
    else console.log(`spektralab-host.exe: LibRaw ${pin}`);
  }
  // The app's version resource (VS_VERSIONINFO, UTF-16 strings): its ProductName and ProductVersion are package.json's.
  const app = join(scratch, appName);
  if (existsSync(app)) {
    const bytes = readFileSync(app);
    if (bytes.includes(Buffer.from('WebView2Loader.dll')) && !has('WebView2Loader.dll')) fail('GNU app imports WebView2Loader.dll, but the installer omits it');
    const text = bytes.toString('utf16le') + '\n' + bytes.subarray(1).toString('utf16le');
    const field = (key) => new RegExp(`${key}\\u0000+([^\\u0000]+)`).exec(text)?.[1];
    const product = field('ProductName'), productVersion = field('ProductVersion');
    if (product !== productName) fail(`${appName}'s ProductName is ${JSON.stringify(product)}, not ${JSON.stringify(productName)}`);
    if (productVersion !== version) fail(`${appName}'s ProductVersion is ${JSON.stringify(productVersion)}, not package.json's ${version}`);
    else console.log(`version resource: ${product} ${productVersion}`);
  }
} finally { rmSync(scratch, { recursive: true, force: true }); }

console.log(`installer: ${exe}`);
console.log(`  ${kind}`);
console.log(`  ${(statSync(exe).size / 1e6).toFixed(1)} MB, ${members.length} members: ${spv} .spv kernels, ${profiles} profiles, ${licences} licence files`);
if (failures.length) {
  for (const f of failures) console.error(`FAIL ${f}`);
  process.exit(1);
}
console.log('check-installer: ok');
