#!/bin/bash
# Builds the universal app bundle (with the Quick Look extension inside it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"

"$ROOT/scripts/build-djvulibre.sh"

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $CONFIGURATION"
# The generic destination matters: without it xcodebuild builds only the
# architecture of this Mac, and the result would not run on Intel.
xcodebuild \
  -project DjVuThumbnails.xcodeproj \
  -scheme DjVuThumbnails \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  build

APP="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/DjVu Thumbnails.app"
echo "==> Built: $APP"
lipo -info "$APP/Contents/PlugIns/DjVuThumbnailExtension.appex/Contents/MacOS/DjVuThumbnailExtension"
