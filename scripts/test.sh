#!/bin/bash
# Two layers of checks:
#   1. the decoder shim on its own, under AddressSanitizer;
#   2. the installed extension through Quick Look, which is the path Finder uses.
# Layer 2 only passes once the app has been installed and registered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURES="$ROOT/tests/fixtures"
if [ ! -f "$FIXTURES/page1.djvu" ]; then
  "$ROOT/scripts/make-fixtures.sh" >/dev/null
fi

status=0

echo "== Decoder shim (ASan) =="
clang -O1 -g -fsanitize=address \
  -o "$WORK/render_smoke" \
  tests/render_smoke.c Sources/CDjVuRender/DjVuRender.c \
  -ISources/CDjVuRender/include -Ivendor/djvulibre-install/include \
  vendor/djvulibre-install/lib/libdjvulibre.a -lc++ -framework CoreFoundation || exit 1

for name in page1 page2 bitonal multipage; do
  "$WORK/render_smoke" "$FIXTURES/$name.djvu" 512 "$WORK/$name.ppm" || status=1
done
# A non-DjVu file must be rejected rather than crash or hang.
if "$WORK/render_smoke" "$FIXTURES/corrupt.djvu" 512 >/dev/null 2>&1; then
  echo "FAIL corrupt.djvu was accepted"
  status=1
else
  echo "OK   corrupt.djvu rejected"
fi
if "$WORK/render_smoke" "$ROOT/does-not-exist.djvu" 512 >/dev/null 2>&1; then
  echo "FAIL missing file was accepted"
  status=1
else
  echo "OK   missing file rejected"
fi

echo
echo "== Orientation and colour =="
python3 - "$WORK" <<'PY'
import sys
w = sys.argv[1]

def load(p):
    d = open(p, 'rb').read()
    i = d.index(b'255\n') + 4
    hdr = d[:i].split()
    return int(hdr[1]), int(hdr[2]), d[i:]

fail = 0

# The red block covers source pixels 50..250 of a 600x800 page, which lands at
# roughly 32..160 once scaled to 512 tall. Sampling inside it checks row order
# and channel order at once.
pw, ph, px = load(f"{w}/page1.ppm")
sx = sy = int(0.15 * ph)
r, g, b = px[(sy * pw + sx) * 3:(sy * pw + sx) * 3 + 3]
if not (r > 150 and g < 120 and b < 200):
    print(f"FAIL page1 at ({sx},{sy}) is ({r},{g},{b}); expected the red block")
    fail = 1
else:
    print(f"OK   page1 red block found at ({sx},{sy}): ({r},{g},{b})")

# The multipage document must thumbnail its cover, not a later page. Page 2 is
# solid blue, so any blue-dominant result means the wrong page was picked.
_, _, m = load(f"{w}/multipage.ppm")
_, _, p1 = load(f"{w}/page1.ppm")
if m != p1:
    print("FAIL multipage.djvu did not render the same image as page1.djvu")
    fail = 1
else:
    print("OK   multipage.djvu renders its cover page")

# Bars start at y=100 of 1400, so at 512 px tall the first dark row is ~37.
bw, bh, bpx = load(f"{w}/bitonal.ppm")
top = next((y for y in range(bh) if any(bpx[(y * bw + x) * 3] < 200 for x in range(bw))), None)
if top is None or not (30 <= top <= 45):
    print(f"FAIL bitonal first dark row is {top}; expected ~37")
    fail = 1
else:
    print(f"OK   bitonal first dark row is {top}")

sys.exit(fail)
PY
[ $? -eq 0 ] || status=1

echo
echo "== Quick Look end to end (needs the app installed) =="
# qlcheck links the shim too, so it can compare Quick Look's thumbnail against
# a direct decode of the same file.
clang -O2 -c Sources/CDjVuRender/DjVuRender.c -o "$WORK/DjVuRender.o" \
  -ISources/CDjVuRender/include -Ivendor/djvulibre-install/include || exit 1
swiftc -O tests/qlcheck.swift "$WORK/DjVuRender.o" \
  -import-objc-header Sources/CDjVuRender/include/DjVuRender.h \
  vendor/djvulibre-install/lib/libdjvulibre.a -lc++ -framework CoreFoundation \
  -o "$WORK/qlcheck" || exit 1

extra=()
for f in "$ROOT"/sample*.djvu; do
  [ -f "$f" ] && extra+=("$f")
done
targets=(
  "$FIXTURES/page1.djvu" "$FIXTURES/bitonal.djvu" "$FIXTURES/multipage.djvu"
  "${extra[@]+"${extra[@]}"}"
)
# Portrait and landscape pages at both a Finder icon size and a large size:
# a wrong drawing rect tends to show up at only some of these.
for spec in "512 2" "128 2" "64 1"; do
  set -- $spec
  "$WORK/qlcheck" --size "$1" --scale "$2" --dump-dir "$WORK" "${targets[@]}" || status=1
  echo
done

echo
[ $status -eq 0 ] && echo "ALL PASS" || echo "FAILURES (see above)"
exit $status
