#!/usr/bin/env bash
# gate-mac.sh — W2's whole Mac gate (PRD-W2 §4; PRD-W0 §6.5). Exits non-zero on the first failure.
# No step is skipped silently: a step that cannot run fails.
#
#   desktop/scripts/gate-mac.sh             phase 1: T1, T2+T3, T4, T6 (the installer must exist)
#   SPEKTRALAB_GATE_PACKAGE=1 …             build the installer first (npm run package:win)
#
#   SPEKTRALAB_GATE_PHASE=2 SPEKTRALAB_RAW_FIXTURES=<RAW folder> SPKLIB_SRC=<spklib clone> \
#   LLVM_MINGW=<llvm-mingw UCRT toolchain> desktop/scripts/gate-mac.sh
#       phase 2, in order: T1; T2/T2b/T3; T4; the one MoltenVK host and the Mac helper built;
#       T5a (the Rust layer on them, and the same test failing without its RAW); T5b (the real app
#       driving itself); the installer built from this tree (package:win) and T6; then the scheduler,
#       library and RAW gates. Every variable is required: unset fails.
#
# One Mac host build serves T5a, T5b and the scheduler gate (build/host-mac, staged by
# scripts/build-host-mac.sh from build/raw-gate-mac); the RAW gate then builds the rest of that same
# directory and runs its own checks unchanged. Nothing here measures time; nothing runs a Windows binary.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
desktop="$(cd "$here/.." && pwd)"
repo="$(cd "$desktop/.." && pwd)"
cd "$desktop"
step() { printf '\n== %s\n' "$*"; }
phase="${SPEKTRALAB_GATE_PHASE:-1}"
if [[ "$phase" == 2 ]]; then
  : "${SPEKTRALAB_RAW_FIXTURES:?phase 2 needs SPEKTRALAB_RAW_FIXTURES (the RAW fixture folder)}"
  : "${SPKLIB_SRC:?phase 2 needs SPKLIB_SRC (the spklib clone)}"
  : "${LLVM_MINGW:?phase 2 needs LLVM_MINGW (the llvm-mingw UCRT toolchain)}"
  [[ -d "$SPEKTRALAB_RAW_FIXTURES" && -x "$SPKLIB_SRC/build.sh" && -x "$LLVM_MINGW/bin/x86_64-w64-mingw32-clang++" ]] \
    || { echo "SPEKTRALAB_RAW_FIXTURES, SPKLIB_SRC or LLVM_MINGW does not name what it should" >&2; exit 1; }
  export SPEKTRALAB_RAW_FIXTURES SPKLIB_SRC LLVM_MINGW
fi

# rustup's toolchain first: Homebrew's rustc has no Windows std, and the crate gates require rustup's.
command -v rustup >/dev/null || { echo "rustup is not installed" >&2; exit 1; }
rustup_cargo="$(rustup which --toolchain stable cargo)"
export PATH="$(dirname "$rustup_cargo"):$PATH"

step "T1  npm run check (typecheck, eslint --max-warnings 0, vitest)"
npm run check

step "T2+T2b+T3  Playwright: design conformance and fidelity, v2 behaviour, v1's browser cases (mock backends)"
npx playwright test

step "T4  cargo test (the app crate, on this Mac)"
(cd src-tauri && cargo test --lib --bins)

step "T4  cargo check --target x86_64-pc-windows-gnu (rustup's toolchain)"
rustc --print target-libdir --target x86_64-pc-windows-gnu >/dev/null
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc}"
export CC_x86_64_pc_windows_gnu="${CC_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-gcc}"
export AR_x86_64_pc_windows_gnu="${AR_x86_64_pc_windows_gnu:-x86_64-w64-mingw32-ar}"
(cd src-tauri && cargo check --target x86_64-pc-windows-gnu)

if [[ "$phase" == 2 ]]; then
  step "the MoltenVK host (scripts/build-host-mac.sh: build/raw-gate-mac -> build/host-mac) and the Mac library helper"
  "$here/build-host-mac.sh"
  (cd "$SPKLIB_SRC" && ./build.sh) > /dev/null
  [[ -x "$SPKLIB_SRC/build/spklib-host" ]] || { echo "no Mac helper at $SPKLIB_SRC/build/spklib-host" >&2; exit 1; }

  step "T5a  the Rust layer on the real host and helper (src-tauri/tests/t5a_real_host.rs)"
  t5a() { (cd src-tauri && env SPK_REQUIRE_REAL_HOST=1 SPEKTRALAB_HOST_DIR="$repo/build/host-mac" \
      SPKLIB_HOST="$SPKLIB_SRC/build/spklib-host" SPKLIB_FIXTURES="$SPKLIB_SRC/tests/fixtures" "$@" \
      cargo test --test t5a_real_host -- --nocapture); }
  t5a SPEKTRALAB_RAW_FIXTURES="$SPEKTRALAB_RAW_FIXTURES"
  empty="$(mktemp -d "${TMPDIR:-/tmp}/spk-t5a-empty.XXXXXX")"
  if t5a SPEKTRALAB_RAW_FIXTURES="$empty" > /dev/null 2>&1; then
    rmdir "$empty"; echo "T5a passed with no RAW to develop: the gate cannot trust it" >&2; exit 1
  fi
  rmdir "$empty"; echo "ok: T5a fails without its RAW"

  step "T5b  the real app on this Mac, driving itself (scripts/selftest-mac.sh)"
  "$here/selftest-mac.sh"
fi

if [[ "${SPEKTRALAB_GATE_PACKAGE:-0}" == 1 || "$phase" == 2 ]]; then
  step "R11  npm run package:win (the host built from this tree, the vendored helper; cross-built NSIS)"
  npm run package:win
fi

step "T6  the installer, listed and inspected (never run)"
node scripts/check-installer.mjs

if [[ "$phase" == 2 ]]; then
  for g in "$desktop/crates/spk-scheduler/gate.sh" "$desktop/crates/spk-library/gate.sh" "$repo/engine/tests/raw_gate.sh"; do
    step "phase 2: $g"
    [[ -f "$g" ]] || { echo "missing gate $g" >&2; exit 1; }
    bash "$g"
  done
fi

printf '\ngate-mac: all steps passed\n'
