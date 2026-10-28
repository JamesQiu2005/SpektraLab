// package.mjs — build the installers.
//
//   node scripts/package.mjs linux                 → release/linux/*.deb, *.AppImage
//   node scripts/package.mjs windows [--host-dir D] → release/windows/*-setup.exe (NSIS)
//   (`win` is the same as `windows`.)
//
// Both stage the engine host the backend built (`build/host-<os>-x64/`):
//   spektralab-host[.exe] → src-tauri/binaries/spektralab-host-<triple>[.exe]
//                            (Tauri `bundle.externalBin`: installed beside the app)
//   engine/, licenses/    → src-tauri/host-staging/ → `<resources>/host/…`
// and pass that as an extra config (`tauri.bundle.json`), so the base config
// builds and `cargo check`s without a staged host.
//
// Where the host comes from, first match wins:
//   --host-dir <dir>              the staged host directory itself (has spektralab-host[.exe] + engine/)
//   SPEKTRALAB_HOST_DIR=<dir>     the same, from the environment
//   SPEKTRALAB_HOST_BUILD=<dir>   a build root holding host-<os>-x64/ (default: the repo's build/)
// The build **refuses** to run without the host executable and its engine/
// resources: an installer without its engine would install an app that
// cannot develop anything.
//
// Windows toolchains (docs: desktop/docs/WINDOWS-INSTALLER.md):
//   - on Windows (CI): native MSVC, x86_64-pc-windows-msvc.
//   - on macOS / Linux: cross-built, x86_64-pc-windows-gnu with MinGW-w64
//     (rustup's target, the system `x86_64-w64-mingw32-gcc`/`-windres`) and
//     NSIS from the system (`makensis`). The engine host is MinGW-built too.
//     SPEKTRALAB_WIN_TOOLCHAIN=msvc selects Tauri's cargo-xwin/MSVC path instead.
//   A GNU build links WebView2Loader.dll dynamically (webview2-com-sys); Tauri's
//   NSIS bundler installs it beside the app for -gnu targets. WebView2 itself is
//   bootstrapped by the installer (tauri.conf.json `webviewInstallMode`).
// Homebrew installs `rust` as well as `rustup`; only rustup's toolchain has the
// Windows target, so on macOS rustup's proxies are put first on PATH.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const desktop = resolve(here, '..');
const tauriDir = join(desktop, 'src-tauri');
const repo = resolve(desktop, '..');

function die(msg) {
  console.error(`package: ${msg}`);
  process.exit(1);
}

const args = process.argv.slice(2);
let which = args.shift();
if (which === 'win') which = 'windows';
let hostDirArg = process.env.SPEKTRALAB_HOST_DIR ?? null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--host-dir') hostDirArg = args[++i] ?? die('--host-dir needs a directory');
  else if (args[i].startsWith('--host-dir=')) hostDirArg = args[i].slice('--host-dir='.length);
  else die(`unknown argument ${args[i]}`);
}
const buildDir = process.env.SPEKTRALAB_HOST_BUILD ?? join(repo, 'build');
const onWindows = process.platform === 'win32';
const winToolchain = onWindows ? 'native' : process.env.SPEKTRALAB_WIN_TOOLCHAIN === 'msvc' ? 'msvc' : 'gnu';

const TARGETS = {
  linux: {
    hostDir: join(buildDir, 'host-linux-x64'),
    exe: 'spektralab-host',
    triple: 'x86_64-unknown-linux-gnu',
    bundles: 'deb,appimage',
    out: 'linux',
    extra: [],
  },
  windows: {
    hostDir: join(buildDir, 'host-win-x64'),
    exe: 'spektralab-host.exe',
    triple: winToolchain === 'gnu' ? 'x86_64-pc-windows-gnu' : 'x86_64-pc-windows-msvc',
    bundles: 'nsis',
    out: 'windows',
    extra: winToolchain === 'msvc'
      ? ['--runner', 'cargo-xwin', '--target', 'x86_64-pc-windows-msvc']
      : ['--target', winToolchain === 'gnu' ? 'x86_64-pc-windows-gnu' : 'x86_64-pc-windows-msvc'],
  },
};

const t = TARGETS[which];
if (!t) die('usage: node scripts/package.mjs linux | windows [--host-dir <staged host dir>]');
if (hostDirArg) t.hostDir = resolve(hostDirArg);

const env = { ...process.env };

/** Run a command quietly; null when it is missing or fails. */
function probe(cmd, cmdArgs) {
  try {
    return execFileSync(cmd, cmdArgs, { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true }).trim();
  } catch {
    return null;
  }
}

/** Cross-building Windows: put the right Rust first and check every tool before Tauri starts. */
function prepareWindowsCross() {
  const home = process.env.HOME ?? '';
  // rustup's proxies: ~/.cargo/bin (rustup-init), Homebrew's keg-only rustup.
  const rustupBins = [join(home, '.cargo', 'bin'), '/opt/homebrew/opt/rustup/bin', '/usr/local/opt/rustup/bin']
    .filter((d) => existsSync(join(d, 'rustup')));
  const extra = [...rustupBins];
  if (winToolchain === 'msvc') extra.push('/opt/homebrew/opt/llvm/bin', '/usr/local/opt/llvm/bin', '/usr/lib/llvm-18/bin');
  env.PATH = [...extra, env.PATH].join(delimiter);
  if (!probe('rustup', ['--version'])) die('rustup is not on PATH. Install it (brew install rustup, then rustup-init or `rustup default stable`).');
  const installed = (probe('rustup', ['target', 'list', '--installed']) ?? '').split(/\s+/);
  if (!installed.includes(t.triple)) die(`the Rust target ${t.triple} is not installed. Run: rustup target add ${t.triple}`);
  const rustc = probe('rustc', ['--print', 'sysroot']) ?? '';
  if (!rustc.includes('.rustup')) die(`rustc on PATH is not rustup's (${rustc || 'none'}); it would not have ${t.triple}.`);
  const tools = ['makensis'];
  if (winToolchain === 'gnu') tools.push('x86_64-w64-mingw32-gcc', 'x86_64-w64-mingw32-windres');
  else tools.push('cargo-xwin', 'clang-cl', 'lld-link', 'llvm-rc');
  for (const tool of tools) {
    if (!probe(tool, tool === 'makensis' ? ['-VERSION'] : ['--version'])) {
      die(`${tool} is not on PATH (macOS: brew install ${tool === 'makensis' ? 'makensis' : tool.startsWith('x86_64') ? 'mingw-w64' : tool === 'cargo-xwin' ? 'cargo-xwin via `cargo install --locked cargo-xwin`' : 'llvm'}).`);
    }
  }
  if (winToolchain === 'gnu') {
    // Pin the linker and archiver so a Homebrew gcc/ld cannot be picked by accident.
    env.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = env.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER ?? 'x86_64-w64-mingw32-gcc';
    env.CC_x86_64_pc_windows_gnu = env.CC_x86_64_pc_windows_gnu ?? 'x86_64-w64-mingw32-gcc';
    env.AR_x86_64_pc_windows_gnu = env.AR_x86_64_pc_windows_gnu ?? 'x86_64-w64-mingw32-ar';
    env.WINDRES_x86_64_pc_windows_gnu = env.WINDRES_x86_64_pc_windows_gnu ?? 'x86_64-w64-mingw32-windres';
  }
}

function stage() {
  const exe = join(t.hostDir, t.exe);
  if (!existsSync(exe)) die(`no engine host at ${exe}. Build it first (engine/build-windows-cross.sh / engine/build-linux.sh) or pass --host-dir; refusing to package an app without its engine.`);
  if (!existsSync(join(t.hostDir, 'engine'))) die(`no engine resources at ${join(t.hostDir, 'engine')}`);
  const bin = join(tauriDir, 'binaries');
  const staging = join(tauriDir, 'host-staging');
  rmSync(bin, { recursive: true, force: true });
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(bin, { recursive: true });
  const ext = t.exe.endsWith('.exe') ? '.exe' : '';
  cpSync(exe, join(bin, `spektralab-host-${t.triple}${ext}`));
  cpSync(join(t.hostDir, 'engine'), join(staging, 'engine'), { recursive: true });
  if (existsSync(join(t.hostDir, 'licenses'))) cpSync(join(t.hostDir, 'licenses'), join(staging, 'licenses'), { recursive: true });
  else mkdirSync(join(staging, 'licenses'), { recursive: true });
  // The user command needs no separately installed Node/npm. The same native
  // app provides the locked sidecar service used by the GUI and by the CLI.
  // A Windows installer built elsewhere carries Windows' node.exe, not this machine's node.
  const agentArgs = [join(here, 'build-agent.mjs'), staging, '--runtime'];
  if (which === 'windows' && !onWindows) {
    env.SPEKTRALAB_NODE_RUNTIME = env.SPEKTRALAB_NODE_RUNTIME ?? windowsNode();
    agentArgs.push('--target=win32');
  }
  execFileSync(process.execPath, agentArgs, { stdio: 'inherit', windowsHide: true, env });
  const resources = { 'host-staging/engine': 'host/engine', 'host-staging/licenses': 'host/licenses', 'host-staging/agents': 'agents' };
  const conf = { bundle: { externalBin: ['binaries/spektralab-host'], resources } };
  const confPath = join(tauriDir, 'tauri.bundle.json');
  writeFileSync(confPath, JSON.stringify(conf, null, 2));
  return confPath;
}

/** Node v24.19.0's win-x64 node.exe for the bundled CLI, cached in desktop/.cache/ and checked
 * against the SHA-256 nodejs.org publishes (build-agent.mjs checks it again). */
function windowsNode() {
  const url = 'https://nodejs.org/dist/v24.19.0/win-x64/node.exe';
  const sha256 = '3602f2bb1a10f2cbab4c36886218a33c1ab3db87290e73b033c46c77147d0237';
  const file = join(desktop, '.cache', 'node-v24.19.0-win-x64', 'node.exe');
  const ok = () => existsSync(file) && createHash('sha256').update(readFileSync(file)).digest('hex') === sha256;
  if (!ok()) {
    mkdirSync(dirname(file), { recursive: true });
    console.log(`package: fetching ${url}`);
    execFileSync('curl', ['-fsSL', '--retry', '3', '-o', file, url], { stdio: 'inherit' });
    if (!ok()) { rmSync(file, { force: true }); die(`${url} did not match its published SHA-256`); }
  }
  return file;
}

function collect() {
  const release = join(desktop, 'release', t.out);
  rmSync(release, { recursive: true, force: true });
  mkdirSync(release, { recursive: true });
  // A cross build lands under target/<triple>/; a native one under target/release/.
  const targetDir = env.CARGO_TARGET_DIR ? resolve(env.CARGO_TARGET_DIR) : join(tauriDir, 'target');
  const roots = which === 'linux' ? [join(targetDir, 'release', 'bundle')] : [join(targetDir, t.triple, 'release', 'bundle')];
  const found = [];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    for (const kind of readdirSync(root)) {
      for (const f of readdirSync(join(root, kind))) {
        const p = join(root, kind, f);
        if (statSync(p).isFile() && /\.(deb|AppImage|exe|rpm)$/.test(f)) {
          cpSync(p, join(release, f));
          found.push(`${join('release', t.out, f)} (${(statSync(p).size / 1e6).toFixed(1)} MB)`);
        }
      }
    }
  }
  if (!found.length) die(`the build finished but no installer was found under ${roots.join(', ')}`);
  console.log(`package: host from ${t.hostDir}`);
  console.log('package: wrote\n  ' + found.join('\n  '));
}

if (which === 'windows' && !onWindows) prepareWindowsCross();
const conf = stage();
if (which === 'linux') env.NO_STRIP = env.NO_STRIP ?? 'true'; // linuxdeploy's strip cannot read newer ELF notes
// On Windows `npx` is npx.cmd, which needs a shell; the shell then needs a
// quoted path if the checkout's path has a space in it.
const arg = (a) => (onWindows && /\s/.test(a) ? `"${a}"` : a);
execFileSync('npx', ['tauri', 'build', '--config', conf, '--bundles', t.bundles, ...t.extra].map(arg), { cwd: desktop, stdio: 'inherit', env, shell: onWindows });
collect();
