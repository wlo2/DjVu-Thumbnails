#!/bin/bash
# Four layers of checks:
#   1. the decoder shim on its own, under AddressSanitizer;
#   2. orientation and colour of its output against synthetic fixtures;
#   3. the Spotlight importer's text, metadata and 10 MB cap, called directly;
#   4. the installed app through Quick Look and Spotlight, the paths Finder uses.
# Layer 4 only passes once this build has been installed and registered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIXTURES="$ROOT/tests/fixtures"
# Also rebuilt after make-fixtures.sh changes, so new checks never run on old files.
if [ ! "$FIXTURES/text.djvu" -nt "$ROOT/scripts/make-fixtures.sh" ]; then
  "$ROOT/scripts/make-fixtures.sh" >/dev/null
fi

status=0
# What a test program needs to link the C shim against the static DjVuLibre.
DJVULIBRE=(-ISources/CDjVuRender/include -Ivendor/djvulibre-install/include
  vendor/djvulibre-install/lib/libdjvulibre.a -lc++ -framework CoreFoundation)

echo "== Decoder shim (ASan) =="
clang -O1 -g -fsanitize=address -o "$WORK/render_smoke" \
  tests/render_smoke.c Sources/CDjVuRender/DjVuRender.c "${DJVULIBRE[@]}" || exit 1

for name in page1 page2 bitonal multipage; do
  "$WORK/render_smoke" "$FIXTURES/$name.djvu" 512 "$WORK/$name.ppm" || status=1
done
# A non-DjVu file, a truncated one and a missing one must all be rejected
# rather than crash or hang.
for f in "$FIXTURES/corrupt.djvu" "$FIXTURES/truncated.djvu" "$ROOT/does-not-exist.djvu"; do
  if "$WORK/render_smoke" "$f" 512 >/dev/null 2>&1; then
    echo "FAIL $(basename "$f") was accepted"
    status=1
  else
    echo "OK   $(basename "$f") rejected"
  fi
done
# Errors are logged as DjVuLibre's message name and parameters, on one line.
message="$("$WORK/render_smoke" "$ROOT/does-not-exist.djvu" 512)"
if grep -q "(ByteStream.open_fail Parameter: .*does-not-exist.djvu Parameter: " <<<"$message"; then
  echo "OK   error message is readable"
else
  echo "FAIL error message for a missing file is not 'ByteStream.open_fail ...'"
  status=1
fi
# Parallel renders in fresh processes; a race hits about 1 process in 100, so
# 300 runs catch it almost surely. The alarm turns a hang into a failure.
clang -O2 -o "$WORK/threads_smoke" tests/threads_smoke.c Sources/CDjVuRender/DjVuRender.c \
  "${DJVULIBRE[@]}" || exit 1
bad=0
for _ in $(seq 300); do
  perl -e 'alarm 10; exec @ARGV' "$WORK/threads_smoke" "$FIXTURES/page1.djvu" 2>/dev/null \
    || bad=$((bad + 1))
done
if [ $bad -eq 0 ]; then
  echo "OK   300 processes rendering from 8 threads at once"
else
  echo "FAIL $bad of 300 processes rendering from 8 threads at once failed, crashed or hung"
  status=1
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
echo "== Spotlight importer (ASan) =="
clang -O1 -g -fsanitize=address -o "$WORK/info_smoke" \
  tests/info_smoke.c Sources/CDjVuRender/DjVuRender.c "${DJVULIBRE[@]}" || exit 1
clang -O1 -g -fsanitize=address -o "$WORK/importer_check" tests/importer_check.c \
  Sources/DjVuImporter/DjVuImporter.c Sources/CDjVuRender/DjVuRender.c \
  "${DJVULIBRE[@]}" -framework CoreServices || exit 1
python3 - "$WORK" "$FIXTURES" <<'PY'
import plistlib, subprocess, sys
work, fixtures = sys.argv[1], sys.argv[2]
fail = 0

def check(ok, what):
    global fail
    print(("OK   " if ok else "FAIL ") + what)
    fail |= not ok

def info(name, cap):
    out = subprocess.run([f"{work}/info_smoke", f"{fixtures}/{name}", str(cap)],
                         capture_output=True).stdout
    head, _, text = out.partition(b"\ntext:")
    return head.decode(), text.decode()  # decode() also proves the text is valid UTF-8

head, text = info("text.djvu", 10 * 1024 * 1024)
# Page 1 is 144x192 points but stored turned 90 degrees.
check(head.startswith("OK pages=2 size=192x144 truncated=0"),
      "text.djvu page count, and page 1's size turned landscape")
check("meta title=Spotlight Fixture" in head, "text.djvu metadata")
# Every byte that is not valid UTF-8 becomes one space; valid characters stay.
page2 = "zebrafish second page   footnote “€𝄞” [   ] [   ] [    ] [  ] end  "
check(text == "Ünïcode quokka marginalia\n\n" + page2,
      "text of both pages, with every invalid byte turned into a space")
# "Ü" and "ï" take two bytes each, so a 4-byte cap must stop before "ï".
head, text = info("text.djvu", 4)
check(text == "Ün" and "truncated=1" in head, "text cap stops on a character boundary")
head, text = info("text.djvu", 1)
check(text == "" and "truncated=1" in head, "text cap smaller than one character")
head, text = info("page1.djvu", 100)
check(head.startswith("OK pages=1") and text == "", "a page without a text layer")

out = subprocess.run([f"{work}/importer_check", f"{fixtures}/text.djvu"],
                     capture_output=True).stdout
attributes = plistlib.loads(out)
check(attributes.get("kMDItemTitle") == "Spotlight Fixture"
      and attributes.get("kMDItemAuthors") == ["Ada Lovelace", "Alan Turing"]
      and attributes.get("kMDItemKeywords") == ["quokka", "fixture"]
      and attributes.get("kMDItemNumberOfPages") == 2
      and attributes.get("kMDItemPageWidth") == 192
      and "zebrafish" in attributes.get("kMDItemTextContent", ""),
      "importer attributes")
rejected = subprocess.run([f"{work}/importer_check", f"{fixtures}/corrupt.djvu"],
                          capture_output=True).returncode != 0
check(rejected, "importer rejects corrupt.djvu")
sys.exit(fail)
PY
[ $? -eq 0 ] || status=1

echo
echo "== Quick Look and Spotlight end to end (needs the app installed) =="
# Quick Look and Spotlight run whatever is installed, so check that it is this build.
APP_BUILT="$ROOT/build/DerivedData/Build/Products/${CONFIGURATION:-Release}/DjVu Thumbnails.app"
APP_INSTALLED="${DEST_DIR:-/Applications}/DjVu Thumbnails.app"
for part in PlugIns/DjVuThumbnailExtension.appex/Contents/MacOS/DjVuThumbnailExtension \
  Library/Spotlight/DjVuImporter.mdimporter/Contents/MacOS/DjVuImporter; do
  if ! cmp -s "$APP_BUILT/Contents/$part" "$APP_INSTALLED/Contents/$part"; then
    echo "FAIL the installed ${part%%/*} is not this build; run build-app.sh and install.sh"
    status=1
  fi
done
# qlcheck links the extension's decoding code too, so it can compare Quick
# Look's thumbnail against a direct decode of the same file.
clang -O2 -c Sources/CDjVuRender/DjVuRender.c -o "$WORK/DjVuRender.o" \
  -ISources/CDjVuRender/include -Ivendor/djvulibre-install/include || exit 1
swiftc -O tests/qlcheck/main.swift Sources/DjVuThumbnailExtension/ThumbnailProvider.swift \
  "$WORK/DjVuRender.o" \
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

# Spotlight: index a copy of the text fixture and find it by a word that only
# page 2's text layer contains. build/ sits in the home folder, which Spotlight
# indexes; /tmp is not indexed.
SPOT="$ROOT/build/spotlight-check"
rm -rf "$SPOT"
mkdir -p "$SPOT"
cp "$FIXTURES/text.djvu" "$SPOT/text-$$.djvu"
mdimport "$SPOT/text-$$.djvu" >/dev/null 2>&1
indexed=0
for _ in $(seq 60); do
  # Search and attributes can land in the index at slightly different times.
  if [ -n "$(mdfind -onlyin "$SPOT" zebrafish 2>/dev/null)" ] &&
    [ "$(mdls -raw -name kMDItemTitle "$SPOT/text-$$.djvu" 2>/dev/null)" = "Spotlight Fixture" ]; then
    indexed=1
    break
  fi
  sleep 1
done
if [ $indexed -eq 1 ]; then
  echo "OK   Spotlight finds text.djvu by its text and title"
else
  echo "FAIL Spotlight did not index text.djvu (is Spotlight enabled? mdutil -s /)"
  status=1
fi

echo
[ $status -eq 0 ] && echo "ALL PASS" || echo "FAILURES (see above)"
exit $status
