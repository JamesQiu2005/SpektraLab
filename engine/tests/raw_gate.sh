#!/usr/bin/env bash
# raw_gate.sh -- the LibRaw gate on a Mac (PRD-W3 T-A1..T-A4, and the engine's
# own CTests in the MoltenVK build). Exit 0 only if every step passed.
#
#   SPEKTRALAB_RAW_FIXTURES=<folder of camera files> engine/tests/raw_gate.sh
#
#   0. engine/setup-libraw.sh verifies (or fetches) the pinned LibRaw tree.
#   1. The native host against MoltenVK (engine/LINUX_WINDOWS.md §7) is built
#      in build/raw-gate-mac, with native codec prefixes from the setup
#      scripts and the pinned Vulkan-Headers (not /opt/homebrew/include, whose
#      jpeglib.h is libjpeg 8 and fails spk_host_codecs); its CTests must pass.
#   2. T-A1 engine/tests/raw_fixtures.py host: every fixture through that host.
#   3. T-A2 engine/tests/raw_pin_compare.sh: the previous pin against this one.
#   4. T-A3 engine/tests/raw_pin_guard.sh: the pin guards fire.
#   5. T-A4 engine/build-windows-cross.sh: spektralab-host.exe is PE32+
#      x86-64, imports system DLLs only (the script's own allowlist), carries
#      this LibRaw, and the staged licences name it.
# No step is skipped: the fixture variable unset, a tool missing or a step
# failing fails the gate. No timing is measured or asserted.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="$(cd "$here/.." && pwd)"
repo="$(cd "$engine/.." && pwd)"
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"
mac="${SPEKTRALAB_RAW_GATE_BUILD:-$repo/build/raw-gate-mac}"
fail() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
[[ -n "${SPEKTRALAB_RAW_FIXTURES:-}" && -d "$SPEKTRALAB_RAW_FIXTURES" ]] \
  || fail "SPEKTRALAB_RAW_FIXTURES must name the RAW fixture folder (required, never skipped)"
[[ "$(uname -s)" == Darwin ]] || fail "this gate is the Mac gate (MoltenVK host); Linux runs build-linux.sh"
for tool in cmake ninja python3 git glslangValidator x86_64-w64-mingw32-g++ x86_64-w64-mingw32-objdump; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}"   # volk dlopens libvulkan
logs="$repo/build/raw-gate-logs"
mkdir -p "$logs"
step() {   # name log command...: run, keep the log, fail with its tail
  local name="$1" log="$logs/$2"; shift 2
  if "$@" > "$log" 2>&1; then return 0; fi
  tail -25 "$log" >&2
  fail "$name (log: $log)"
}

# --- 0. the pin --------------------------------------------------------------------------------
"$engine/setup-deps.sh" "$deps" > "$logs/setup-deps.txt" 2>&1 || { tail -20 "$logs/setup-deps.txt"; fail "setup-deps.sh"; }
libraw="$("$engine/setup-libraw.sh" "$deps" 2>/dev/null | tail -n 1)"
ok "LibRaw pin verified: $libraw"

# --- 1. the native MoltenVK host and its CTests -------------------------------------------------
step "native input codecs" input-codecs.txt python3 "$engine/setup-input-codecs.py" --sources "$deps/input-codecs" \
  --build "$mac/codecs/input" --install "$deps/input-codecs/install-mac" --generator Ninja
step "native lens codecs" lens-codecs.txt python3 "$engine/setup-lens-codecs.py" --sources "$deps/lens-codecs" \
  --build "$mac/codecs/lens" --install "$deps/lens-codecs/install-mac" --generator Ninja
step "configure the MoltenVK host" configure.txt cmake -S "$repo" -B "$mac" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSPEKTRALAB_VULKAN_ON_APPLE=ON -DSPEKTRALAB_REQUIRE_VULKAN=ON \
  -DSPEKTRALAB_VULKAN_HEADERS="$deps/Vulkan-Headers/include" \
  -DSPEKTRALAB_BUILD_NATIVE_RAW=ON -DSPEKTRALAB_BUILD_HOST=ON -DSPEKTRALAB_LIBRAW_OPENMP=OFF \
  -DSPEKTRALAB_LIBRAW_SOURCE="$libraw" \
  -DSPEKTRALAB_INPUT_CODEC_PREFIX="$deps/input-codecs/install-mac" \
  -DSPEKTRALAB_LENS_PREFIX="$deps/lens-codecs/install-mac" -DBUILD_TESTING=ON
step "build the MoltenVK host" build.txt ninja -C "$mac"
step "CTest (MoltenVK build)" ctest.txt ctest --test-dir "$mac" --output-on-failure
ok "native build and CTests: $(grep -E 'tests passed' "$logs/ctest.txt")"

# --- 2. T-A1 ---------------------------------------------------------------------------------
step "T-A1 raw_fixtures.py host" t-a1.txt python3 "$here/raw_fixtures.py" host \
  --host "$mac/engine/host/spektralab-host" --resources "$mac/engine/resources"
ok "T-A1 every fixture through the host: $(grep -c '^ok' "$logs/t-a1.txt") checks, $(tail -n 1 "$logs/t-a1.txt")"

# --- 3. T-A2 ---------------------------------------------------------------------------------
step "T-A2 raw_pin_compare.sh" t-a2.txt "$here/raw_pin_compare.sh" "$repo/build/raw-pin-compare"
ok "T-A2 previous pin against this one: $(grep -c '^ok' "$logs/t-a2.txt") checks, $(tail -n 1 "$logs/t-a2.txt")"

# --- 4. T-A3 ---------------------------------------------------------------------------------
step "T-A3 raw_pin_guard.sh" t-a3.txt "$here/raw_pin_guard.sh" "$repo/build/raw-pin-guard"
ok "T-A3 the pin guards fire: $(grep -c '^ok' "$logs/t-a3.txt") checks, $(tail -n 1 "$logs/t-a3.txt")"

# --- 5. T-A4 ---------------------------------------------------------------------------------
step "T-A4 build-windows-cross.sh" t-a4.txt "$engine/build-windows-cross.sh"
exe="$repo/build/host-win-x64/spektralab-host.exe"
lic="$repo/build/host-win-x64/licenses"
file "$exe" | grep -q 'PE32+ executable (console) x86-64' || fail "T-A4: $(file -b "$exe")"
imports="$(x86_64-w64-mingw32-objdump -p "$exe" | awk '/DLL Name/ {print $3}' | sort -u | tr '\n' ' ')"
grep -qiE 'libstdc|libgcc|libwinpthread|libgomp|vulkan-1|libraw' <<<"$imports" && fail "T-A4: non-system import in [$imports]"
LC_ALL=C grep -aq "0.23.0-Snapshot202611" "$exe" || fail "T-A4: the exe does not carry LibRaw 0.23.0-Snapshot202611"
LC_ALL=C grep -aq "0.22.2-Release" "$exe" && fail "T-A4: the exe still carries LibRaw 0.22.2"
for f in LibRaw-LGPL-2.1.txt LibRaw-COPYRIGHT.txt LibRaw-SOURCE.txt; do [[ -s "$lic/$f" ]] || fail "T-A4: licenses/$f not staged"; done
grep -q "42f89c165763272a5482a254c446337f8048e0df" "$lic/LibRaw-SOURCE.txt" || fail "T-A4: LibRaw-SOURCE.txt does not name the pinned commit"
grep -q "GNU LESSER GENERAL PUBLIC LICENSE" "$lic/LibRaw-LGPL-2.1.txt" || fail "T-A4: LibRaw-LGPL-2.1.txt is not the LGPL"
ok "T-A4 spektralab-host.exe: PE32+ x86-64, $(wc -c < "$exe" | tr -d ' ') bytes, imports [$imports], LibRaw 0.23.0-Snapshot202611, LibRaw notices staged"
echo
echo "raw gate: all passed (logs in $logs)"
