#!/bin/bash
# Regenerates the DjVu test fixtures using DjVuLibre's own encoders, so the
# tests do not depend on any checked-in binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
# Tools of the build that matches this Mac, so they can run here.
TOOLS="$ROOT/vendor/build-$(uname -m)/tools"

"$ROOT/scripts/build-djvulibre.sh" >/dev/null

if [ ! -x "$TOOLS/c44" ]; then
  echo "==> Building DjVuLibre command line tools (encoders for the fixtures)"
  make -C "$TOOLS" -j"$(sysctl -n hw.ncpu)" >/dev/null
fi

mkdir -p "$FIXTURES"

echo "==> Generating source images"
python3 - "$FIXTURES" <<'PY'
import sys
d = sys.argv[1]

def ppm(path, w, h, fn):
    with open(path, 'wb') as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(bytes(bytearray(
            v for y in range(h) for x in range(w) for v in fn(x, y, w, h))))

# Page 1 carries a red block in the top-left corner. That is what makes the
# fixture useful: it pins down both row order and RGB channel order, and it
# tells page 1 apart from page 2 in the multipage document.
ppm(f"{d}/p1.ppm", 600, 800,
    lambda x, y, w, h: (255, 40, 40) if (50 < x < 250 and 50 < y < 250)
    else (x * 255 // w, y * 255 // h, 180))
ppm(f"{d}/p2.ppm", 600, 800, lambda x, y, w, h: (40, 40, 255))

# Bitonal page: two black bars near the top, so the topmost dark row acts as an
# orientation check.
w, h = 1000, 1400
rows = []
for y in range(h):
    bits = bytearray()
    acc = n = 0
    for x in range(w):
        v = 1 if (100 < y < 140 and 100 < x < 800) or (200 < y < 220 and 100 < x < 600) else 0
        acc = (acc << 1) | v
        n += 1
        if n == 8:
            bits.append(acc)
            acc = n = 0
    if n:
        bits.append(acc << (8 - n))
    rows.append(bytes(bits))
open(f"{d}/bitonal.pbm", "wb").write(b"P4\n%d %d\n" % (w, h) + b"".join(rows))
PY

echo "==> Encoding DjVu fixtures"
"$TOOLS/c44"  -dpi 300 "$FIXTURES/p1.ppm"       "$FIXTURES/page1.djvu"
"$TOOLS/c44"  -dpi 300 "$FIXTURES/p2.ppm"       "$FIXTURES/page2.djvu"
"$TOOLS/cjb2" -dpi 300 "$FIXTURES/bitonal.pbm"  "$FIXTURES/bitonal.djvu"
"$TOOLS/djvm" -c "$FIXTURES/multipage.djvu" "$FIXTURES/page1.djvu" "$FIXTURES/page2.djvu"

# Not a DjVu file at all: the extension must fail cleanly so Finder falls back
# to the generic icon.
head -c 200 /dev/urandom > "$FIXTURES/corrupt.djvu"
# A real document cut in half: it passes the header check and fails while
# decoding the page, which is the path that waits on DjVuLibre's messages.
head -c $(($(stat -f %z "$FIXTURES/multipage.djvu") / 2)) "$FIXTURES/multipage.djvu" \
  > "$FIXTURES/truncated.djvu"

rm -f "$FIXTURES"/*.ppm "$FIXTURES"/*.pbm
ls -l "$FIXTURES"
