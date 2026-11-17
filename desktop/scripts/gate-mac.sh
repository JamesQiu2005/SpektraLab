#!/usr/bin/env bash
# gate-mac.sh — W2's whole Mac gate (PRD-W2 §4; PRD-W0 §6.5). Exits non-zero on
# the first failure. No step is skipped silently: a step that cannot run fails.
#
#   desktop/scripts/gate-mac.sh             T1, T2+T3, T4, T6 (the installer must exist)
#   SPEKTRALAB_GATE_PACKAGE=1 …             build the installer first (npm run package:win)
#   SPEKTRALAB_GATE_PHASE=2 …               also the scheduler, library and RAW gates (phase 2)
#
# T5 (the real host through the scheduler) is phase 2 and is not here yet.
# Nothing here measures time; nothing here runs a Windows binary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
desktop="$(cd "$here/.." && pwd)"
repo="$(cd "$desktop/.." && pwd)"
cd "$desktop"
step() { printf '\n== %s\n' "$*"; }

step "T1  npm run check (typecheck, eslint --max-warnings 0, vitest)"
npm run check

step "T2+T3  Playwright: design conformance, v2 behaviour, v1's browser cases (mock backends)"
npx playwright test

step "T4  cargo test (the app crate, on this Mac)"
(cd src-tauri && cargo test)

step "T4  cargo check --target x86_64-pc-windows-gnu (rustup's toolchain; Homebrew's rustc has no Windows std)"
command -v rustup >/dev/null || { echo "rustup is not installed: the Windows target cannot be checked" >&2; exit 1; }
rustup_cargo="$(rustup which --toolchain stable cargo)"
export PATH="$(dirname "$rustup_cargo"):$PATH"
rustc --print target-libdir --target x86_64-pc-windows-gnu >/dev/null
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc}"
export CC_x86_64_pc_windows_gnu="${CC_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-gcc}"
export AR_x86_64_pc_windows_gnu="${AR_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-ar}"
(cd src-tauri && cargo check --target x86_64-pc-windows-gnu)

if [[ "${SPEKTRALAB_GATE_PACKAGE:-0}" == 1 ]]; then
  step "R11  npm run package:win (cross-built NSIS installer)"
  npm run package:win
fi

step "T6  the installer, listed and inspected (never run)"
node scripts/check-installer.mjs

if [[ "${SPEKTRALAB_GATE_PHASE:-1}" == 2 ]]; then
  for g in "$desktop/crates/spk-scheduler/gate.sh" "$desktop/crates/spk-library/gate.sh" "$repo/engine/tests/raw_gate.sh"; do
    step "phase 2: $g"
    [[ -x "$g" || -f "$g" ]] || { echo "missing gate $g" >&2; exit 1; }
    bash "$g"
  done
fi

printf '\ngate-mac: all steps passed\n'
