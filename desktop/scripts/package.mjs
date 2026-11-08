// package.mjs — build the installers.
//
//   node scripts/package.mjs linux   → release/linux/*.deb, *.AppImage
//   node scripts/package.mjs win     → release/windows/*-setup.exe (NSIS, cross-built)
//
// Both stage the engine host the backend built (`build/host-<os>-x64/`):
//   spektralab-host[.exe] → src-tauri/binaries/spektralab-host-<triple>[.exe]
//                            (Tauri `bundle.externalBin`: installed beside the app)
//   engine/, licenses/    → src-tauri/host-staging/ → `<resources>/host/…`
// and pass that as an extra config (`tauri.bundle.json`), so the base config
// builds and `cargo check`s without a staged host.
//
// The Windows build **refuses** to run without build/host-win-x64/spektralab-host.exe:
// an installer without its engine would install an app that cannot develop
// anything.
//
// On a Windows machine (CI) `win` builds natively with MSVC
// (x86_64-pc-windows-msvc, no cross runner, the system PATH untouched).
// On Linux, Windows is cross-built with the x86_64-pc-windows-gnu target and mingw-w64
// (Tauri's documented cargo-xwin/MSVC path is behind SPEKTRALAB_WIN_TOOLCHAIN=msvc;
// its CRT download was refused here), NSIS from the system (`makensis`).
// Env: SPEKTRALAB_HOST_BUILD overrides the repo's build/ directory.

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const desktop = resolve(here, '..');
const tauriDir = join(desktop, 'src-tauri');
const repo = resolve(desktop, '..');
const buildDir = process.env.SPEKTRALAB_HOST_BUILD ?? join(repo, 'build');
const which = process.argv[2];

const TARGETS = {
  linux: {
    hostDir: join(buildDir, 'host-linux-x64'),
    exe: 'spektralab-host',
    triple: 'x86_64-unknown-linux-gnu',
    bundles: 'deb,appimage',
    out: 'linux',
    extra: [],
  },
  // MinGW by default: cargo-xwin's MSVC CRT download (aka.ms) is refused by
  // this build machine's egress policy. SPEKTRALAB_WIN_TOOLCHAIN=msvc uses
  // Tauri's documented cargo-xwin path where that download is allowed.
  win:
    // Native on Windows (CI's windows-latest): MSVC, no cross runner.
    process.platform === 'win32'
      ? {
          hostDir: join(buildDir, 'host-win-x64'),
          exe: 'spektralab-host.exe',
          triple: 'x86_64-pc-windows-msvc',
          bundles: 'nsis',
          out: 'windows',
          extra: ['--target', 'x86_64-pc-windows-msvc'],
        }
      : process.env.SPEKTRALAB_WIN_TOOLCHAIN === 'msvc'
      ? {
          hostDir: join(buildDir, 'host-win-x64'),
          exe: 'spektralab-host.exe',
          triple: 'x86_64-pc-windows-msvc',
          bundles: 'nsis',
          out: 'windows',
          extra: ['--runner', 'cargo-xwin', '--target', 'x86_64-pc-windows-msvc'],
        }
      : {
          hostDir: join(buildDir, 'host-win-x64'),
          exe: 'spektralab-host.exe',
          triple: 'x86_64-pc-windows-gnu',
          bundles: 'nsis',
          out: 'windows',
          extra: ['--target', 'x86_64-pc-windows-gnu'],
        },
};

function die(msg) {
  console.error(`package: ${msg}`);
  process.exit(1);
}

function stage(t) {
  const exe = join(t.hostDir, t.exe);
  if (!existsSync(exe)) die(`no engine host at ${exe}. Build it first (engine/host, see engine/WINDOWS.md / the backend's notes); refusing to package an app without its engine.`);
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
  const conf = {
    bundle: {
      externalBin: ['binaries/spektralab-host'],
      resources: { 'host-staging/engine': 'host/engine', 'host-staging/licenses': 'host/licenses' },
    },
  };
  const confPath = join(tauriDir, 'tauri.bundle.json');
  writeFileSync(confPath, JSON.stringify(conf, null, 2));
  return confPath;
}

function collect(t) {
  const release = join(desktop, 'release', t.out);
  rmSync(release, { recursive: true, force: true });
  mkdirSync(release, { recursive: true });
  // A cross build lands under target/<triple>/; a native one under target/release/.
  const roots = which === 'linux' ? [join(tauriDir, 'target', 'release', 'bundle')] : [join(tauriDir, 'target', t.triple, 'release', 'bundle')];
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
  console.log('package: wrote\n  ' + found.join('\n  '));
}

const t = TARGETS[which];
if (!t) die('usage: node scripts/package.mjs linux|win');
const conf = stage(t);
const env = { ...process.env };
const onWindows = process.platform === 'win32';
if (which === 'win' && !onWindows) {
  // Cross build: cargo-xwin's clang-cl/lld-link, and llvm-rc for the resource script.
  env.PATH = `${process.env.HOME}/.cargo/bin:/usr/lib/llvm-18/bin:${env.PATH}`;
}
if (which === 'linux') env.NO_STRIP = env.NO_STRIP ?? 'true'; // linuxdeploy's strip cannot read newer ELF notes
// On Windows `npx` is npx.cmd, which needs a shell; the shell then needs a
// quoted path if the checkout's path has a space in it.
const arg = (a) => (onWindows && /\s/.test(a) ? `"${a}"` : a);
execFileSync('npx', ['tauri', 'build', '--config', conf, '--bundles', t.bundles, ...t.extra].map(arg), { cwd: desktop, stdio: 'inherit', env, shell: onWindows });
collect(t);
