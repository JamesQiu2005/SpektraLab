#!/bin/sh
# Turns the .deb (desktop/release/linux/*_amd64.deb, from `node scripts/package.mjs linux`) into a snap with
# `snap pack`: no snapcraft, LXD or root. The snap carries the .deb's files as they are and takes its
# libraries from two runtime snaps that snapd installs with it: gnome-core26 (GTK 3 and WebKitGTK 4.1, which
# the window needs) and mesa-2604 (the Vulkan loader and drivers, which the engine host needs).
#
#   SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux && sh scripts/build-snap.sh
#   sudo snap install --dangerous release/snap/<name>_<version>_amd64.snap
#
# SNAP_NAME (default spektralab) and SNAP_TITLE set the snap's name; APPID is read from tauri.conf.json.
set -e
cd "$(dirname "$0")/.."
DEB=$(ls release/linux/*_amd64.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || { echo "build-snap: no .deb in release/linux; run: SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux"; exit 1; }
VERSION=$(dpkg-deb -f "$DEB" Version)
NAME=${SNAP_NAME:-spektralab}
TITLE=${SNAP_TITLE:-$(grep -m1 '"productName"' src-tauri/tauri.conf.json | cut -d'"' -f4)}
APPID=$(grep -m1 '"identifier"' src-tauri/tauri.conf.json | cut -d'"' -f4)
P=release/snap/prime
rm -rf release/snap
mkdir -p "$P"
dpkg-deb -x "$DEB" "$P"
[ -x "$P/usr/bin/spektralab" ] && [ -x "$P/usr/bin/spektralab-host" ] || { echo "build-snap: the .deb has no usr/bin/spektralab or spektralab-host"; exit 1; }

# The desktop entry and icon, pointing at the snap's command and icon
ICON=$(ls "$P"/usr/share/icons/hicolor/512x512/apps/*.png | head -1)
install -Dm644 "$ICON" "$P/meta/gui/$NAME.png"
DESKTOP=$(ls "$P"/usr/share/applications/*.desktop | head -1)
sed -e "s|^Exec=.*|Exec=$NAME %F|" -e "s|^Icon=.*|Icon=\${SNAP}/meta/gui/$NAME.png|" \
    -e 's|^MimeType=\(.*[^;]\)$|MimeType=\1;|' "$DESKTOP" > "$P/meta/gui/$NAME.desktop"

install -Dm755 packaging/snap/desktop-launch "$P/snap/command-chain/desktop-launch"
install -Dm755 packaging/snap/gpu-2604-wrapper "$P/snap/command-chain/gpu-2604-wrapper"
# A fallback launcher, from an installed GNOME runtime snap, for when gnome-core26 is not connected yet
for r in /snap/gnome-core26/current /snap/gnome-46-2404/current; do
    if [ -x "$r/command-chain/desktop-launch" ]; then
        install -Dm755 "$r/command-chain/desktop-launch" "$P/snap/command-chain/desktop-launch-bundled"
        break
    fi
done
[ -x "$P/snap/command-chain/desktop-launch-bundled" ] || { echo "build-snap: no GNOME runtime snap to take desktop-launch from (sudo snap install gnome-core26)"; exit 1; }

# Layout and content targets must exist when packing; the runtimes are mounted over them
mkdir -p "$P/gnome-platform/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1" \
         "$P/gnome-platform/usr/libexec/glycin-loaders" "$P/gnome-platform/usr/share/xml/iso-codes" \
         "$P/gpu-2604" "$P/data-dir/themes" "$P/data-dir/icons" "$P/data-dir/sounds"
sed -e "s/@NAME@/$NAME/g" -e "s/@VERSION@/$VERSION/g" -e "s/@TITLE@/$TITLE/g" -e "s/@APPID@/$APPID/g" \
    packaging/snap/snap.yaml.in > "$P/meta/snap.yaml"
snap pack "$P" release/snap/
ls -la release/snap/*.snap
