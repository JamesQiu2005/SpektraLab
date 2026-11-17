#!/usr/bin/env bash
# selftest-mac.sh — T5b (PRD-W2 T5, phase 2): the real Tauri app, built and launched natively on this
# Mac with the real MoltenVK host and the real library helper, drives itself (`--selftest`,
# src-tauri/src/selftest.rs and src/app/selftest.ts) and exits; this script then checks what it wrote.
#
#   SPEKTRALAB_RAW_FIXTURES=<RAW folder> SPKLIB_SRC=<spklib clone> desktop/scripts/selftest-mac.sh
#
# - the app: `tauri build --debug --no-bundle` (the frontend embedded; a debug build has the self-test,
#   a release package never does);
# - the host: build/host-mac (scripts/build-host-mac.sh); the helper: $SPKLIB_SRC/build/spklib-host;
# - isolation: HOME and CFFIXED_USER_HOME point into build/t5b/home, and the library store into
#   build/t5b/store, so neither the person's app data nor their libraries are touched;
# - fixtures: one RAW (A7m3/DSC03710.ARW) copied into a folder to link; a Capture One 16.8 catalog
#   made from spklib's fixture schema, whose every file's bytes and times must be unchanged afterwards;
# - the checks: exit 0 and `selftest-result.json` ok; `canvas.png` a PNG of a picture (size, not one
#   colour); `status.json` says Developed and the job is done; the export a JPEG at the long edge asked;
#   the Library saw the folder's frame and the catalog's two, read-only; no process left behind.
# No screencapture, nothing that needs a privacy grant, no timing asserted (a timeout is a failure).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
desktop="$(cd "$here/.." && pwd)"
repo="$(cd "$desktop/.." && pwd)"
fail() { echo "FAIL T5b: $*" >&2; exit 1; }
ok() { echo "ok   T5b: $*"; }
[[ "$(uname -s)" == Darwin ]] || fail "this runs on macOS"
[[ -n "${SPEKTRALAB_RAW_FIXTURES:-}" && -f "$SPEKTRALAB_RAW_FIXTURES/A7m3/DSC03710.ARW" ]] || fail "SPEKTRALAB_RAW_FIXTURES must hold A7m3/DSC03710.ARW"
[[ -n "${SPKLIB_SRC:-}" && -x "$SPKLIB_SRC/build/spklib-host" ]] || fail "SPKLIB_SRC must name the spklib clone with a Mac helper built (build/spklib-host)"
schema="$SPKLIB_SRC/tests/fixtures/capture_one_16_8_schema.sql"
[[ -f "$schema" ]] || fail "no Capture One schema at $schema"
host="$repo/build/host-mac"
[[ -x "$host/spektralab-host" ]] || fail "no host at $host (scripts/build-host-mac.sh)"
scratch="$repo/build/t5b"
rm -rf "$scratch"; mkdir -p "$scratch/home" "$scratch/out" "$scratch/store" "$scratch/fixtures/Folder" "$scratch/fixtures/Photos"
raw="$scratch/fixtures/DSC03710.ARW"
cp "$SPEKTRALAB_RAW_FIXTURES/A7m3/DSC03710.ARW" "$raw"
cp "$raw" "$scratch/fixtures/Folder/DSC03710.ARW"

# The Capture One catalog: spklib's 16.8 schema and two images, the first the RAW.
cp "$raw" "$scratch/fixtures/Photos/A.ARW"; printf 'arw-b' > "$scratch/fixtures/Photos/B.ARW"
pkg="$scratch/fixtures/Fixture.cocatalog"; mkdir -p "$pkg/Originals"
rel="${scratch#/}/fixtures/Photos"
cat "$schema" > "$scratch/c1.sql"
cat >> "$scratch/c1.sql" <<SQL
INSERT INTO ZVERSIONINFO VALUES (32, 1, '16.8.6.25 Pro Mac', '9.0.0 Mac', 160800, '16.8.6.25 Pro Mac', 160800);
INSERT INTO ZDOCUMENTCONTENT (Z_ENT, Z_PK, ZDATECREATED, ZDOCUMENTTYPE, ZDOCUMENTUUID, ZROOTCOLLECTION) VALUES (34, 1, 1729735821, 1, 'BBBBBBBB-2222-3333-4444-555555555555', 1);
INSERT INTO ZPATHLOCATION (Z_ENT, Z_PK, ZMACROOT, ZRELATIVEPATH, ZISRELATIVE, ZVOLUME) VALUES (38, 3, '/', '$rel', 0, '/');
INSERT INTO ZIMAGE (Z_ENT, Z_PK, ZIMAGEUUID, ZIMAGEFILENAME, ZDISPLAYNAME, ZIMAGELOCATION, ZISINSIDECATALOG, ZISTRASHED, ZIMAGECLASSIFICATION, ZWIDTH, ZHEIGHT, ZEXP_DATE, ZIMPORTDATE, ZCAMERA_MAKE, ZCAMERA_MODEL, ZISO) VALUES
 (12, 1, 'IMG-A', 'A.ARW', 'A', 3, 0, 0, 17, 6000, 4000, 1704757144.25, 1729841315.9, 'SONY', 'ILCE-7M3', 100),
 (12, 2, 'IMG-B', 'B.ARW', 'B', 3, 0, 0, 17, 6000, 4000, 1704757148, 1729841315.9, 'SONY', 'ILCE-7M3', 400);
INSERT INTO ZVARIANT (Z_ENT, Z_PK, ZINDEX, ZVARIANTUUID, ZIMAGE, ZCOMBINEDSETTINGS, ZISMODIFIED) VALUES (15, 1, 127, 'VAR-A1', 1, 101, 0), (15, 2, 127, 'VAR-B1', 2, 102, 0);
INSERT INTO ZVARIANTLAYER (Z_ENT, Z_PK, ZVARIANT, ZROTATION, ZFLIP) VALUES (20, 101, 1, 0, 0), (20, 102, 2, 0, 0);
INSERT INTO ZVARIANTMETADATA (Z_ENT, Z_PK, ZLAYER, ZBASIC_RATING, ZCOLOR_TAG_INDEX) VALUES (13, 101, 101, 0, 0), (13, 102, 102, 4, 1);
INSERT INTO ZCOLLECTION (Z_ENT, Z_PK, ZUUID, ZNAME, ZPARENT, ZCOLLECTIONINDEX, ZFOLDERLOCATION, ZALLIMAGESCOLLECTION, ZLASTIMPORTSCOLLECTION, ZLASTCAPTURESCOLLECTION, ZTRASHCOLLECTION) VALUES
 (7, 1, 'COL-ROOT', 'root', NULL, 0, NULL, 2, 3, 4, 5), (40, 2, 'COL-ALL', 'All Images', 1, 1, NULL, NULL, NULL, NULL, NULL),
 (8, 3, 'COL-RI', 'Recent Imports', 1, 2, NULL, NULL, NULL, NULL, NULL), (8, 4, 'COL-RC', 'Recent Captures', 1, 3, NULL, NULL, NULL, NULL, NULL),
 (11, 5, 'COL-TRASH', 'Trash', 1, 4, NULL, NULL, NULL, NULL, NULL), (2, 8, 'COL-PICKS', 'Picks', 1, 6, NULL, NULL, NULL, NULL, NULL);
INSERT INTO ZIMAGEINCOLLECTION (Z_ENT, Z_PK, ZCOLLECTION, ZIMAGE) VALUES (47, 4, 8, 2);
SQL
/usr/bin/sqlite3 "$pkg/Fixture.cocatalogdb" ".read $scratch/c1.sql" || fail "building the Capture One fixture catalog"
census() { (cd "$pkg" && find . -print0 | sort -z | xargs -0 stat -f '%N %z %m %p' && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }
before="$(census)"

echo "== T5b: building the app (tauri build --debug --no-bundle)"
(cd "$desktop" && npx tauri build --debug --no-bundle) > "$scratch/build.txt" 2>&1 || { tail -30 "$scratch/build.txt"; fail "tauri build --debug"; }
app="$desktop/src-tauri/target/debug/spektralab"
[[ -x "$app" ]] || fail "no app at $app"

# The window may be behind others while it runs: App Nap must not suspend its timers. The preference
# goes into the run's own home (CFFIXED_USER_HOME), not the person's.
mkdir -p "$scratch/home/Library/Preferences"
for domain in .GlobalPreferences spektralab app.spektralab.desktop; do
  /usr/bin/plutil -create xml1 "$scratch/home/Library/Preferences/$domain.plist"
  /usr/bin/plutil -insert NSAppSleepDisabled -bool YES "$scratch/home/Library/Preferences/$domain.plist"
done
echo "== T5b: launching $app --selftest"
set +e
env HOME="$scratch/home" CFFIXED_USER_HOME="$scratch/home" \
  SPEKTRALAB_HOST_DIR="$host" DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
  SPKLIB_HOST="$SPKLIB_SRC/build/spklib-host" SPEKTRALAB_LIBRARY_STORE="$scratch/store" \
  SPEKTRALAB_SELFTEST_FOLDER="$scratch/fixtures/Folder" SPEKTRALAB_SELFTEST_C1="$pkg" \
  SPEKTRALAB_SELFTEST_TIMEOUT="${SPEKTRALAB_SELFTEST_TIMEOUT:-420}" \
  "$app" --selftest "$raw" "$scratch/out" > "$scratch/app.txt" 2>&1
code=$?
set -e
# Nothing left running: not the app, not the host it started, not the helper.
sleep 2
left="$(pgrep -fl "$desktop/src-tauri/target/debug/spektralab|$host/spektralab-host|$SPKLIB_SRC/build/.*/spklib-host" || true)"
if [[ -n "$left" ]]; then
  pkill -f "$desktop/src-tauri/target/debug/spektralab|$host/spektralab-host|$SPKLIB_SRC/build/.*/spklib-host" || true
  fail "processes left behind after the app exited: $left"
fi
ok "the app exited ($code) and left nothing running"
[[ -f "$scratch/out/selftest-result.json" ]] || { tail -40 "$scratch/app.txt"; fail "no selftest-result.json (exit $code)"; }
[[ $code == 0 ]] || { cat "$scratch/out/selftest-result.json"; tail -40 "$scratch/app.txt"; fail "the app's self-test exited $code"; }

python3 - "$scratch/out" "$pkg" <<'PY' || fail "the self-test's output"
import json, struct, sys, zlib, os
out, pkg = sys.argv[1], sys.argv[2]
def die(m): print("FAIL T5b: " + m); sys.exit(1)
r = json.load(open(f"{out}/selftest-result.json"))
if not r.get("ok"): die(f"result: {r}")
# canvas.png: a PNG, its size, its pixels not one colour (decoded here, no imaging library).
b = open(f"{out}/canvas.png", "rb").read()
if b[:8] != b"\x89PNG\r\n\x1a\n": die("canvas.png is not a PNG")
w, h, depth, ctype = struct.unpack(">IIBB", b[16:26])
idat, i = b"", 8
while i < len(b):
    n, kind = struct.unpack(">I4s", b[i:i+8]); data = b[i+8:i+8+n]; i += 12 + n
    if kind == b"IDAT": idat += data
raw = zlib.decompress(idat)
bpp = {6: 4, 2: 3}[ctype] * depth // 8
stride = w * bpp
rows, prev, px = [], bytearray(stride), []
for y in range(h):
    f, line = raw[y*(stride+1)], bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
    for x in range(stride):
        a = line[x-bpp] if x >= bpp else 0; up = prev[x]; c = prev[x-bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + up) & 255
        elif f == 3: line[x] = (line[x] + (a + up) // 2) & 255
        elif f == 4:
            p = a + up - c; pa, pb, pc = abs(p-a), abs(p-up), abs(p-c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
    prev = line
    if y % 8 == 0: px += [tuple(line[x:x+3]) for x in range(0, stride, bpp*8)]
distinct = len(set(px)); mean = sum(p[1] for p in px) / len(px)
if w < 200 or h < 200: die(f"canvas.png is {w}x{h}")
if distinct < 50: die(f"canvas.png is not a picture ({distinct} distinct colours sampled)")
if not 5 < mean < 250: die(f"canvas.png is black or white (mean green {mean:.1f})")
print(f"ok   T5b: canvas.png {w}x{h}, {distinct} distinct colours in {len(px)} samples, mean green {mean:.1f}")
s = json.load(open(f"{out}/status.json"))
if not s["status"].startswith("Developed"): die(f"status line: {s['status']!r}")
if s["job"]["state"] != "done" or s["job"]["kind"] != "canvasDevelop": die(f"job: {s['job']}")
if s["pageJob"]["state"] != "done": die(f"the page's job: {s['pageJob']}")
print(f"ok   T5b: status line {s['status']!r}; job {s['job']['kind']} {s['job']['state']} ({s['job']['jobId']}), then {s['pageJob']['kind']} {s['pageJob']['state']}; "
      f"backend {s['backend'].get('api')} on {s['backend'].get('device_name')}; scheduler {s['budget']['engine']['name']}, policy {s['budget']['policy']['device']}")
e = json.load(open(f"{out}/export.json"))
f = e["files"][0]["path"]; jb = open(f, "rb").read()
if jb[:2] != b"\xff\xd8": die(f"{f} is not a JPEG")
i, size = 2, None
while i + 9 < len(jb):
    m, n = jb[i+1], struct.unpack(">H", jb[i+2:i+4])[0]
    if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC): size = struct.unpack(">HH", jb[i+5:i+9]); break
    i += 2 + n
if not size or max(size) != 1200: die(f"{f}: size {size}, not a 1200 long edge")
print(f"ok   T5b: export {os.path.basename(f)} is a JPEG {size[1]}x{size[0]}, {len(jb)} bytes")
l = json.load(open(f"{out}/library.json"))
if l["folder"]["total"] < 1 or "DSC03710.ARW" not in l["folder"]["images"]: die(f"folder: {l['folder']}")
c = l["captureOne"]
if c["kind"] != "captureOneCatalog" or not c["readOnly"] or c["total"] != 2: die(f"Capture One: {c}")
print(f"ok   T5b: Library on the real helper (spklib {l['state']['version']}, {l['state']['origin']}): a linked folder ({l['folder']['total']}), "
      f"a Capture One catalog read-only ({c['total']} images; {', '.join(c['collections'][:6])})")
PY
[[ "$(census)" == "$before" ]] || fail "the Capture One package changed"
ok "the Capture One package is byte for byte, size and time, as it was"
echo "T5b: passed (output in $scratch/out)"
