#!/bin/bash
# Builds DjVuLibre as a static universal (arm64 + x86_64) library that gets
# linked straight into the Quick Look extension, so the extension has no
# runtime dependency on Homebrew or anything else outside its own bundle.
set -euo pipefail

VERSION=3.5.29
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/djvulibre-$VERSION"
OUT="$VENDOR/djvulibre-install"
TARBALL="$VENDOR/djvulibre-$VERSION.tar.gz"
URL="https://downloads.sourceforge.net/project/djvu/DjVuLibre/$VERSION/djvulibre-$VERSION.tar.gz"
SHA256=d3b4b03ae2bdca8516a36ef6eb27b777f0528c9eda26745d9962824a3fdfeccf

# Match the deployment target of the app/extension.
export MACOSX_DEPLOYMENT_TARGET=12.0

mkdir -p "$VENDOR"

if [ ! -f "$TARBALL" ]; then
  echo "==> Downloading djvulibre-$VERSION"
  # Via a temporary name, so an interrupted download is retried, not reused.
  curl -fsSL -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

if [ ! -d "$SRC" ]; then
  echo "==> Extracting"
  # Via a temporary folder, so an interrupted extraction is redone, not reused.
  rm -rf "$SRC.part"
  mkdir "$SRC.part"
  tar xzf "$TARBALL" -C "$SRC.part"
  mv "$SRC.part/djvulibre-$VERSION" "$SRC"
  rmdir "$SRC.part"
fi

# DjVuLibre compiles its --prefix into the library as a data directory path (it
# looks for ICC profiles under $prefix/share/djvu). Configuring with a real build
# path would bake that path into every binary that links the library, so a
# neutral prefix is used and the files are staged elsewhere with DESTDIR.
NEUTRAL_PREFIX=/opt/djvulibre

build_arch() {
  local arch="$1" host="$2"
  local bdir="$VENDOR/build-$arch" pfx="$VENDOR/prefix-$arch$NEUTRAL_PREFIX"
  local destdir="$VENDOR/prefix-$arch"

  # The stamp makes a VERSION bump rebuild instead of reusing the old library.
  if [ -f "$pfx/lib/libdjvulibre.a" ] && [ "$(cat "$destdir/.version" 2>/dev/null)" = "$VERSION" ]; then
    echo "==> $arch already built"
    return
  fi

  echo "==> Configuring for $arch"
  rm -rf "$bdir" "$destdir"
  mkdir -p "$bdir"
  cd "$bdir"

  # Only libdjvu itself is needed. The command line tools, xmltools and
  # desktop files are all skipped; JPEG/TIFF are only used by the tools, not
  # by DjVu decoding, so they stay out too (keeps the lib dependency-free).
  # DjVuLibre's exception macros expand __FILE__, so without remapping, the
  # absolute build path of whoever compiled it ends up as string literals in
  # any binary that links the library. -ffile-prefix-map rewrites those (and
  # debug paths) to a stable relative form.
  local mapflag="-ffile-prefix-map=$VENDOR/="

  CC="clang -arch $arch" \
  CXX="clang++ -arch $arch" \
  CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET $mapflag" \
  CXXFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET $mapflag" \
  "$SRC/configure" \
      --prefix="$NEUTRAL_PREFIX" \
      --host="$host" \
      --enable-static --disable-shared \
      --disable-xmltools --disable-desktopfiles \
      --without-jpeg --without-tiff \
      --without-x \
      >"$bdir/configure.log" 2>&1 || { tail -40 "$bdir/configure.log"; exit 1; }

  echo "==> Building libdjvu for $arch"
  make -C libdjvu -j"$(sysctl -n hw.ncpu)" >"$bdir/make.log" 2>&1 \
    || { tail -60 "$bdir/make.log"; exit 1; }
  make -C libdjvu install DESTDIR="$destdir" >>"$bdir/make.log" 2>&1 \
    || { tail -60 "$bdir/make.log"; exit 1; }
  echo "$VERSION" >"$destdir/.version"
}

build_arch arm64  aarch64-apple-darwin
build_arch x86_64 x86_64-apple-darwin

echo "==> Creating universal library"
rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$VENDOR/prefix-arm64$NEUTRAL_PREFIX/include" "$OUT/include"
lipo -create \
  "$VENDOR/prefix-arm64$NEUTRAL_PREFIX/lib/libdjvulibre.a" \
  "$VENDOR/prefix-x86_64$NEUTRAL_PREFIX/lib/libdjvulibre.a" \
  -output "$OUT/lib/libdjvulibre.a"

lipo -info "$OUT/lib/libdjvulibre.a"
echo "==> Done: $OUT"
