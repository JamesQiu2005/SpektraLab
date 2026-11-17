#!/usr/bin/env bash
# gate.sh -- the spk-library / spklib Mac gate (PRD-W3 T-B1..T-B5). Exit 0 only
# if every step passed. No step is skipped: a missing variable or tool fails.
#
#   SPKLIB_SRC=<clone of SpektraLab_library on windows/cross-compile-2026-11-17-on-0.4.0> \
#   LLVM_MINGW=<llvm-mingw UCRT toolchain folder> \
#   desktop/crates/spk-library/gate.sh
#
# T-B1  the SDK's own tests on the Mac (./build.sh test): every check passes,
#       and there are at least SPKLIB_EXPECT_CHECKS of them (670: 0.4.0's 611
#       plus the 59 Windows path-rule checks).
# T-B2  the Windows build: ./build.sh windows-x64 (host + tests .exe) and
#       windows-x64-release; both .exe are PE32+ x86-64; the import table is
#       exactly the expected system DLLs; the release's version string carries
#       the clone's commit; the release rebuilt from the vendored commit has the
#       vendored SHA-256 (vendor/spklib/windows-x64).
# T-B3  this crate's tests against the Mac-built helper (SPKLIB_HOST) and the
#       SDK's fixtures, Capture One catalog included (the package's bytes are
#       unchanged after a session).
# T-B4  the Windows path rules, unit tests run on the Mac (part of `cargo test`,
#       counted on their own).
# T-B5  cargo check --lib --target x86_64-pc-windows-gnu with rustup's toolchain
#       (Homebrew's rustc has no Windows std). Test binaries are never built for
#       Windows: the test suite is macOS-only by design.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
fail() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
[[ "$(uname -s)" == Darwin ]] || fail "this gate runs on macOS (the crate's tests are macOS-only by design)"
[[ -n "${SPKLIB_SRC:-}" && -x "$SPKLIB_SRC/build.sh" ]] || fail "SPKLIB_SRC must name the spklib clone (with build.sh)"
[[ -n "${LLVM_MINGW:-}" && -x "$LLVM_MINGW/bin/x86_64-w64-mingw32-clang++" ]] || fail "LLVM_MINGW must name an llvm-mingw toolchain"
command -v cargo >/dev/null || fail "cargo not found"
command -v rustup >/dev/null || fail "rustup not found (T-B5 needs its x86_64-pc-windows-gnu std)"
export LLVM_MINGW
expect_checks="${SPKLIB_EXPECT_CHECKS:-670}"
vendor="$repo/vendor/spklib/windows-x64"
log="$(mktemp -d "${TMPDIR:-/tmp}/spk-library-gate.XXXXXX")"
trap 'rm -rf "$log"' EXIT

# --- T-B1 -------------------------------------------------------------------------------------
(cd "$SPKLIB_SRC" && ./build.sh test) > "$log/t-b1.txt" 2>&1 || { tail -20 "$log/t-b1.txt"; fail "T-B1: ./build.sh test"; }
summary="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$log/t-b1.txt" | tail -n 1)"
passed="${summary%% passed*}"
[[ "$summary" == "$passed passed, 0 failed" && "$passed" -ge "$expect_checks" ]] \
  || fail "T-B1: '$summary' (want >= $expect_checks passed, 0 failed)"
warnings="$(grep -c 'warning:' "$log/t-b1.txt" || true)"
[[ "$warnings" == 0 ]] || fail "T-B1: $warnings compiler warnings on the Mac"
ok "T-B1 spklib on macOS: $summary, 0 warnings"
grep -q 'SPKLIB_C1_CATALOG not set' "$log/t-b1.txt" && echo "     (the SDK's real-catalog pass needs SPKLIB_C1_CATALOG, a real Capture One catalog; none on this Mac)"

# --- T-B2 -------------------------------------------------------------------------------------
mingw_imports() { "$LLVM_MINGW/bin/llvm-readobj" --coff-imports "$1" | sed -n -E 's/^ *Name: (.*\.[dD][lL][lL])$/\1/p' | sort -u | tr '\n' ' '; }
ucrt="api-ms-win-crt-convert-l1-1-0.dll api-ms-win-crt-environment-l1-1-0.dll api-ms-win-crt-filesystem-l1-1-0.dll api-ms-win-crt-heap-l1-1-0.dll api-ms-win-crt-locale-l1-1-0.dll api-ms-win-crt-math-l1-1-0.dll api-ms-win-crt-multibyte-l1-1-0.dll api-ms-win-crt-private-l1-1-0.dll api-ms-win-crt-runtime-l1-1-0.dll api-ms-win-crt-stdio-l1-1-0.dll api-ms-win-crt-string-l1-1-0.dll api-ms-win-crt-time-l1-1-0.dll api-ms-win-crt-utility-l1-1-0.dll"
want_host="$ucrt KERNEL32.dll Normaliz.dll SHELL32.dll "
want_tests="$ucrt KERNEL32.dll Normaliz.dll "
(cd "$SPKLIB_SRC" && rm -rf build/windows-x64 && ./build.sh windows-x64) > "$log/t-b2.txt" 2>&1 \
  || { tail -20 "$log/t-b2.txt"; fail "T-B2: ./build.sh windows-x64"; }
warnings="$(grep -c 'warning:' "$log/t-b2.txt" || true)"
[[ "$warnings" == 0 ]] || fail "T-B2: $warnings warnings in the Windows build"
for exe in spklib-host spklib-tests; do
  f="$SPKLIB_SRC/build/windows-x64/$exe.exe"
  file "$f" | grep -q 'PE32+ executable (console) x86-64' || fail "T-B2: $exe.exe is $(file -b "$f")"
  want="$want_host"; [[ $exe == spklib-tests ]] && want="$want_tests"
  got="$(mingw_imports "$f")"
  [[ "$got" == "$want" ]] || fail "T-B2: $exe.exe imports [$got], want [$want]"
done
ok "T-B2 windows-x64: spklib-host.exe and spklib-tests.exe are PE32+ x86-64, 0 warnings, imports exactly KERNEL32, SHELL32 (host only), Normaliz and 13 UCRT api sets"
(cd "$SPKLIB_SRC" && rm -rf build/windows-x64 build/release-windows-x64 && ./build.sh windows-x64-release) > "$log/t-b2r.txt" 2>&1 \
  || { tail -20 "$log/t-b2r.txt"; fail "T-B2: ./build.sh windows-x64-release"; }
rel="$SPKLIB_SRC/build/release-windows-x64/spklib-host.exe"
head12="$(cd "$SPKLIB_SRC" && git rev-parse --short=12 HEAD)"
version="$(cat "$SPKLIB_SRC/VERSION")+$head12"
LC_ALL=C grep -aq "$version" "$rel" || fail "T-B2: the release's version string does not carry the commit ($version)"
got="$(mingw_imports "$rel")"
[[ "$got" == "$want_host" ]] || fail "T-B2: the release imports [$got]"
ok "T-B2 windows-x64-release: version $version in the binary, same imports, $(wc -c < "$rel" | tr -d ' ') bytes"
# The vendored binary: its own .sha256, and the same bytes rebuilt from its commit.
(cd "$vendor" && shasum -a 256 -c spklib-host.exe.sha256 >/dev/null) || fail "T-B2: vendor/spklib/windows-x64/spklib-host.exe does not match its .sha256"
vendored_version="$(sed -n -E 's/^version +([^ ]+).*/\1/p' "$vendor/VERSION")"
if [[ "$vendored_version" == "$version" ]]; then
  [[ "$(shasum -a 256 < "$rel" | cut -d' ' -f1)" == "$(cut -d' ' -f1 "$vendor/spklib-host.exe.sha256")" ]] \
    || fail "T-B2: rebuilding $version does not give the vendored spklib-host.exe"
  ok "T-B2 vendored spklib-host.exe: matches its .sha256 and is byte-identical to the rebuild of $version"
else
  fail "T-B2: the clone is at $version but the vendored helper is $vendored_version; check out its commit (or re-vendor)"
fi

# --- T-B3 / T-B4 --------------------------------------------------------------------------------
(cd "$SPKLIB_SRC" && ./build.sh) > "$log/mac.txt" 2>&1 || fail "building the Mac helper"
export SPKLIB_HOST="$SPKLIB_SRC/build/spklib-host" SPKLIB_FIXTURES="$SPKLIB_SRC/tests/fixtures"
[[ -x "$SPKLIB_HOST" ]] || fail "no Mac helper at $SPKLIB_HOST"
(cd "$here" && cargo test --no-fail-fast) > "$log/t-b3.txt" 2>&1 || { grep -E 'FAILED|panicked|error' "$log/t-b3.txt" | head -20; fail "T-B3/T-B4: cargo test"; }
results="$(grep -E '^test result:' "$log/t-b3.txt")"
total=0; while read -r n; do total=$((total + n)); done < <(sed -n -E 's/^test result: ok\. ([0-9]+) passed.*/\1/p' <<<"$results")
grep -q ' 0 ignored' <<<"$results" || fail "T-B3: a test was ignored"
helper_tests="$(grep -cE '^test [a-z0-9_]+ \.\.\. ok$' "$log/t-b3.txt" || true)"
path_tests="$(grep -cE '^test paths::tests::[a-z0-9_]+ \.\.\. ok$' "$log/t-b3.txt" || true)"
[[ "$path_tests" -ge 5 ]] || fail "T-B4: only $path_tests path-rule tests ran"
[[ "$helper_tests" -ge 10 ]] || fail "T-B3: only $helper_tests tests against the helper ran"
ok "T-B3 spk-library against the Mac helper: $helper_tests helper tests; $total tests in all, 0 failed, 0 ignored"
ok "T-B4 Windows path rules on the Mac: $path_tests tests"

# --- T-B5 ------------------------------------------------------------------------------------
toolchain_bin="$(dirname "$(rustup which rustc)")"
sysroot="$("$toolchain_bin/rustc" --print sysroot)"
[[ -d "$sysroot/lib/rustlib/x86_64-pc-windows-gnu" ]] || fail "T-B5: rustup's $sysroot has no x86_64-pc-windows-gnu std"
(cd "$here" && PATH="$toolchain_bin:$PATH" cargo check --lib --target x86_64-pc-windows-gnu) > "$log/t-b5.txt" 2>&1 \
  || { tail -20 "$log/t-b5.txt"; fail "T-B5: cargo check --target x86_64-pc-windows-gnu"; }
warnings="$(grep -c '^warning' "$log/t-b5.txt" || true)"
[[ "$warnings" == 0 ]] || fail "T-B5: $warnings warnings"
ok "T-B5 cargo check --lib --target x86_64-pc-windows-gnu (rustc $("$toolchain_bin/rustc" --version | cut -d' ' -f2), sysroot $sysroot): 0 warnings"
echo
echo "spk-library gate: all passed"
