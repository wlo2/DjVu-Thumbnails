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

# The multipage document plus what Spotlight indexes: a hidden text layer on
# both pages and document metadata. Page 1 has non-ASCII text, to test cutting
# on a character boundary, and is stored turned 90 degrees, so its size must
# come out landscape. Page 2 mixes valid 3- and 4-byte characters with bytes
# that are not UTF-8, as real OCR layers have: a stray byte (octal 370), then
# in brackets a surrogate, an overlong form, a code point past U+10FFFF and a
# cut-off character, and one more cut off at the very end.
cp "$FIXTURES/multipage.djvu" "$FIXTURES/text.djvu"
printf '(page 0 0 600 800 "Ünïcode quokka marginalia")\n' >"$FIXTURES/p1.txt"
p2='zebrafish second page \370 footnote “€𝄞” [\355\240\200] [\340\200\200]'
p2+=' [\364\220\200\200] [\342\202] end\342\202'
printf '(page 0 0 600 800 "%s")\n' "$p2" >"$FIXTURES/p2.txt"
printf '%s\n' 'title "Spotlight Fixture"' 'author "Ada Lovelace and Alan Turing"' \
  'keywords "quokka, fixture"' >"$FIXTURES/meta.txt"
"$TOOLS/djvused" "$FIXTURES/text.djvu" -s -e "select 1; set-txt $FIXTURES/p1.txt;
  set-rotation 1; select 2; set-txt $FIXTURES/p2.txt; select; set-meta $FIXTURES/meta.txt"
rm -f "$FIXTURES"/p1.txt "$FIXTURES"/p2.txt "$FIXTURES"/meta.txt

# Not a DjVu file at all: the extension must fail cleanly so Finder falls back
# to the generic icon.
head -c 200 /dev/urandom > "$FIXTURES/corrupt.djvu"
# A real document cut in half: it passes the header check and fails while
# decoding the page, which is the path that waits on DjVuLibre's messages.
head -c $(($(stat -f %z "$FIXTURES/multipage.djvu") / 2)) "$FIXTURES/multipage.djvu" \
  > "$FIXTURES/truncated.djvu"

rm -f "$FIXTURES"/*.ppm "$FIXTURES"/*.pbm
ls -l "$FIXTURES"
