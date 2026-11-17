// check-installer.mjs — T6: the Windows installer, listed, never run.
//
//   node scripts/check-installer.mjs [path/to/SpektraLab_<version>_x64-setup.exe]
//
// With no path it takes the newest *-setup.exe in release/windows/ (where
// `npm run package:win` writes it). No installer is a failure, not a skip.
// It asserts, with `file` and `7zz` (Homebrew's sevenzip):
//  - the installer is an NSIS self-extracting archive. NSIS's own stub is a
//    32-bit (PE32, i386) program whatever it installs, so that is what `file`
//    must say of it; what it installs is checked below;
//  - the members the app needs: the app (spektralab.exe), the engine host
//    (spektralab-host.exe), WebView2Loader.dll, the host's resources under
//    host/engine/ (the constants, the film and paper profiles, the .spv
//    kernels), the licences, the uninstaller;
//  - the app and the host, extracted to a scratch folder, are PE32+ x86-64.
//  - the version in its name is package.json's, and so are the app's version
//    resource's ProductName ("SpektraLab") and ProductVersion.
// Nothing is executed but `file` and `7zz`.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const failures = [];
const fail = (m) => failures.push(m);
const run = (cmd, args) => execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 << 20 });

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
if (!/^PE32 executable \(GUI\) Intel 80386.*Nullsoft Installer self-extracting archive/.test(kind)) fail(`file says "${kind}", not an NSIS installer`);

const listing = run('7zz', ['l', '-slt', exe]);
if (!/^Type = Nsis$/m.test(listing)) fail('7zz does not read it as an NSIS archive');
const members = [...listing.matchAll(/^Path = (.+)$/gm)].map((m) => m[1].replaceAll('\\', '/')).slice(1);
const has = (p) => members.includes(p);
const count = (re) => members.filter((m) => re.test(m)).length;

const required = [
  'spektralab.exe', 'spektralab-host.exe', 'WebView2Loader.dll', 'uninstall.exe',
  'host/engine/spektrafilm_constants.bin', 'host/engine/print_luts.json', 'host/engine/io/sRGB.icc',
  'host/engine/profiles/kodak_portra_400.json', 'host/engine/profiles/kodak_portra_endura.json',
];
// Phase 2 adds the library helper: SPEKTRALAB_INSTALLER_REQUIRE=spklib-host.exe (comma-separated members).
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
  run('7zz', ['e', '-y', `-o${scratch}`, exe, 'spektralab.exe', 'spektralab-host.exe']);
  for (const [name, gui] of [['spektralab.exe', true], ['spektralab-host.exe', false]]) {
    const p = join(scratch, name);
    if (!existsSync(p)) { fail(`could not extract ${name}`); continue; }
    const k = run('file', ['-b', p]).trim();
    if (!k.startsWith(`PE32+ executable (${gui ? 'GUI' : 'console'}) x86-64`)) fail(`${name}: file says "${k}", not a PE32+ x86-64 ${gui ? 'GUI' : 'console'} program`);
  }
  // The app's version resource (VS_VERSIONINFO, UTF-16 strings): its ProductName and ProductVersion are package.json's.
  const app = join(scratch, 'spektralab.exe');
  if (existsSync(app)) {
    const bytes = readFileSync(app);
    const text = bytes.toString('utf16le') + '\n' + bytes.subarray(1).toString('utf16le');
    const field = (key) => new RegExp(`${key}\\u0000+([^\\u0000]+)`).exec(text)?.[1];
    const product = field('ProductName'), productVersion = field('ProductVersion');
    if (product !== 'SpektraLab') fail(`spektralab.exe's ProductName is ${JSON.stringify(product)}, not "SpektraLab"`);
    if (productVersion !== version) fail(`spektralab.exe's ProductVersion is ${JSON.stringify(productVersion)}, not package.json's ${version}`);
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
