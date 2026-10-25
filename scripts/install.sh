#!/bin/bash
# Installs the built app into /Applications and makes Finder pick up the
# extension. Run scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
SRC="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/DjVu Thumbnails.app"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST="$DEST_DIR/DjVu Thumbnails.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -d "$SRC" ]; then
  echo "Not built yet. Run scripts/build-app.sh first." >&2
  exit 1
fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Registering with Launch Services"
# xcodebuild registers the build copy too; with both registered, Quick Look may
# run the dev build instead of the installed one.
"$LSREGISTER" -u "$SRC"
pluginkit -r "$SRC/Contents/PlugIns/DjVuThumbnailExtension.appex" 2>/dev/null || true
"$LSREGISTER" -f "$DEST"

echo "==> Enabling the Quick Look extension"
# Explicit, because Launch Services registers it lazily and, right after the
# removal above, sometimes not at all.
pluginkit -a "$DEST/Contents/PlugIns/DjVuThumbnailExtension.appex"
pluginkit -e use -i org.djvuthumbnails.DjVuThumbnails.Thumbnail 2>/dev/null || true

echo "==> Resetting the Quick Look thumbnail cache"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

echo
echo "Installed. Launch it once so macOS registers the DjVu type:"
echo "  open \"$DEST\""
echo
echo "If Finder still shows generic icons for files it has already cached,"
echo "reset the icon cache and relaunch Finder:"
echo "  killall Finder"
