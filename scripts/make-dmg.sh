#!/bin/bash
# Packages the built app into a distributable .dmg.
#
# The app is ad-hoc signed (there is no Developer ID here), so on any other Mac
# Gatekeeper will quarantine it. That is why INSTALL.txt ships inside the image:
# without clearing the quarantine flag, macOS refuses to load the extension.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
APP="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/DjVu Thumbnails.app"

if [ ! -d "$APP" ]; then
  echo "==> Not built yet, building first"
  "$ROOT/scripts/build-app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
VOLNAME="DjVu Thumbnails"
DMG="$ROOT/build/DjVu-Thumbnails-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat >"$STAGE/INSTALL.txt" <<'EOF'
DjVu Thumbnails
===============

Makes Finder show the cover page of .djvu files as a thumbnail.

Installing
----------

1. Drag "DjVu Thumbnails.app" onto the Applications shortcut in this window.

2. This app is signed ad hoc rather than with an Apple Developer ID, so macOS
   quarantines anything copied from another machine. Clear that flag, in
   Terminal:

       xattr -dr com.apple.quarantine "/Applications/DjVu Thumbnails.app"

   Skipping this step means macOS silently refuses to load the extension:
   the app may open, but Finder keeps showing generic icons.

3. Launch the app once. This is required — it is what registers the DjVu
   document type with macOS. You can quit it straight afterwards.

4. Drop a .djvu file on the app's window to confirm Quick Look is using the
   extension. Finder thumbnails should now appear.

If Finder still shows generic icons for files it had already cached:

    qlmanage -r cache && killall Finder

Uninstalling
------------

Delete the app from /Applications, then run:

    qlmanage -r cache && killall Finder

Licence
-------

Uses DjVuLibre (https://djvu.sourceforge.net), GPL v2, linked statically.
This software is therefore GPL v2 as well.
EOF

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

echo "==> Verifying"
hdiutil verify "$DMG" >/dev/null && echo "image checksum OK"
ls -lh "$DMG"
echo
echo "Built: $DMG"
