#!/usr/bin/env bash
# gate.sh -- spk-scheduler's whole Mac gate (PRD-W0 §6.5). Exits non-zero on any failure.
#
#   SPEKTRALAB_RAW_FIXTURES=/path/to/RAW_decode_tests desktop/crates/spk-scheduler/gate.sh
#
# 1. rustfmt --check; clippy with warnings denied (this Mac, all targets; Windows, the library)
# 2. T1-T4: the unit tests (the ported selftest and its mutation run among them), tests/wire.rs,
#    tests/host_engine.rs
# 3. T2 again as the Swift ran it: `scheduler-selftest --self-test`, every mutation caught
# 4. T5: tests/real_host.rs against the real host (SPK_HOST_BIN, default build/host-mac/spektralab-host,
#    made by tools/build-host-mac.sh) on SPEKTRALAB_RAW_FIXTURES -- both required: unset or missing fails.
#    Then the same test with the fixture folder pointed somewhere empty, which must fail: the gate's
#    own check that T5 cannot pass by not running.
# 5. T6: `cargo check --lib --target x86_64-pc-windows-gnu`. Only the library: the test suite is macOS-only
#    by design and is never built for Windows (README, "Tests").
#
# No step asserts on time. Uses the rustup toolchain (Homebrew's rustc has no Windows std).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
cd "$here"
[[ "$(uname -s)" == Darwin ]] || { echo "gate.sh runs on macOS only" >&2; exit 1; }
toolchain="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/stable-$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
[[ -x "$toolchain/bin/cargo" ]] || { echo "no rustup stable toolchain at $toolchain" >&2; exit 1; }
export PATH="$toolchain/bin:$PATH"
[[ "$(rustc --print sysroot)" == "$toolchain" ]] || { echo "rustc is not the rustup toolchain's" >&2; exit 1; }
: "${SPEKTRALAB_RAW_FIXTURES:?set SPEKTRALAB_RAW_FIXTURES to the RAW test folder}"
export SPK_HOST_BIN="${SPK_HOST_BIN:-$repo/build/host-mac/spektralab-host}"
[[ -x "$SPK_HOST_BIN" ]] || { echo "no host at $SPK_HOST_BIN: run tools/build-host-mac.sh" >&2; exit 1; }
[[ -d "$SPEKTRALAB_RAW_FIXTURES" ]] || { echo "SPEKTRALAB_RAW_FIXTURES=$SPEKTRALAB_RAW_FIXTURES is not a folder" >&2; exit 1; }
export SPK_REQUIRE_REAL_HOST=1
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib

step() { echo; echo "== $*"; }
step "fmt"; cargo fmt --check
step "clippy (macOS, all targets)"; cargo clippy --all-targets --features selftest -- -D warnings
step "clippy (Windows, library)"; cargo clippy --lib --target x86_64-pc-windows-gnu -- -D warnings
step "T1-T5: cargo test"; cargo test --features selftest
step "T2: scheduler-selftest --self-test"; cargo run -q --features selftest --bin scheduler-selftest -- --self-test
step "T5 must fail without its fixture"
empty="$(mktemp -d "${TMPDIR:-/tmp}/spk-scheduler-empty.XXXXXX")"
if SPEKTRALAB_RAW_FIXTURES="$empty" cargo test -q --test real_host >/dev/null 2>&1; then
  rmdir "$empty"; echo "T5 passed with no RAW to develop: the gate cannot trust it" >&2; exit 1
fi
rmdir "$empty"; echo "ok: it fails"
step "T6: cargo check --lib --target x86_64-pc-windows-gnu"; cargo check --lib --target x86_64-pc-windows-gnu
echo; echo "spk-scheduler gate: green"
