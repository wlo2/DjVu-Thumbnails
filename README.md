<img src="docs/icon.png" alt="" width="96" align="left">

# DjVu Thumbnails

**Finder thumbnails for DjVu documents on macOS — the way PDFs already get them.**

<br clear="left">

A Quick Look thumbnail extension that renders page 1 of `.djvu` / `.djv` files, so
Finder shows the cover instead of a generic blank icon. Every DjVu flavour is
handled: bitonal JB2 scans, IW44 colour pages, foreground/background layered
pages, shared JB2 dictionaries, and bundled multipage documents.

Decoding is done by [DjVuLibre](https://djvu.sourceforge.net), built from source
and linked statically, so the extension depends on nothing outside its own
bundle — no Homebrew, no dylibs to keep in sync. Universal: arm64 and x86_64.

## Install

Download the `.dmg` from the releases page, or build it yourself:

```bash
./scripts/build-app.sh
./scripts/make-dmg.sh
```

Then:

1. Drag **DjVu Thumbnails.app** to `/Applications`.
2. Clear the quarantine flag (see [Signing](#signing) — this step is not
   optional if the app came from another machine):
   ```bash
   xattr -dr com.apple.quarantine "/Applications/DjVu Thumbnails.app"
   ```
3. **Launch the app once.** This is what registers the DjVu document type with
   macOS. Quit it afterwards; Finder keeps working.

To install a local build straight into `/Applications` instead, use
`./scripts/install.sh`.

If Finder still shows generic icons for files whose icons it had already cached:

```bash
qlmanage -r cache && killall Finder
```

## Signing

The app is signed **ad hoc**, because signing with a Developer ID and notarizing
requires a paid Apple Developer account. Gatekeeper therefore quarantines the app
on any machine it did not come from, and a quarantined Quick Look extension is
refused **silently** — the app opens and looks perfectly healthy while Finder
keeps showing generic icons, with nothing to explain why. Hence step 2 above.

With a Developer ID, set `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in
[`project.yml`](project.yml) and notarize the DMG with `xcrun notarytool`; the
quarantine step then disappears.

## Build from source

Requirements: macOS 12+, Xcode command line tools, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/build-app.sh
```

This downloads DjVuLibre 3.5.29 (checksum verified), builds it as a static
universal library, generates the Xcode project and builds a universal app.

| Script | Purpose |
| --- | --- |
| `build-djvulibre.sh` | Fetches and builds DjVuLibre as a static universal `.a` |
| `build-app.sh` | Generates the project and builds the app |
| `install.sh` | Installs to `/Applications` and registers it |
| `make-dmg.sh` | Packages a distributable `.dmg` |
| `make-icon.swift` | Regenerates `AppIcon.icns` |
| `make-fixtures.sh` | Regenerates the DjVu test fixtures |
| `test.sh` | Runs the test suite |

The Xcode project is generated, not committed — edit
[`project.yml`](project.yml) and run `xcodegen generate`.

## How it fits together

| Component | Role |
| --- | --- |
| [`Sources/CDjVuRender`](Sources/CDjVuRender) | C shim over DjVuLibre's `ddjvu` API; decodes page 1 into an RGB bitmap |
| [`Sources/DjVuThumbnailExtension`](Sources/DjVuThumbnailExtension) | The `QLThumbnailProvider`. Sandboxed, statically linked against DjVuLibre |
| [`Sources/DjVuThumbnails`](Sources/DjVuThumbnails) | Host app: declares the DjVu content type, and lets you drop a file to verify the extension is live |

Three things are worth knowing if you work on this:

**macOS ships no DjVu type declaration at all.** Nothing on a stock system maps
`.djvu` onto a content type, so a thumbnail extension would never be consulted.
The host app declares `com.lizardtech.djvu` in `UTExportedTypeDeclarations` and
the extension registers for that type. This is why the app is not merely a
container you can skip launching.

**Quick Look's drawing context is not in the units the API implies.**
`QLThumbnailReply(contextSize:drawing:)` takes a size in points, but the context
handed to the drawing block is not necessarily scaled to match. Assuming it is
parks the page in a corner at the wrong scale. The provider takes its drawing
rect from `context.boundingBoxOfClipPath` instead, which is correct either way.

**`xcodebuild` needs `-destination 'generic/platform=macOS'`.** Without it, only
the current Mac's architecture gets built — silently, with no warning — and the
result will not run on Intel.

## Tests

```bash
./scripts/test.sh
```

Three layers:

1. **The decoder shim under AddressSanitizer**, including a non-DjVu file and a
   missing file, which must both be rejected rather than crash or hang.
2. **Orientation and colour assertions** against synthetic fixtures, plus a
   check that a multipage document thumbnails its cover and not a later page.
3. **The installed extension through Quick Look**, at large and Finder-icon
   sizes, with each thumbnail compared against a direct decode of the same file.
   That comparison is the point: a thumbnail letterboxed into a corner, upside
   down or colour-swapped still has plausible dimensions, but will not match.

Layer 3 needs the app installed and registered. Drop any `sample*.djvu` files in
the repository root and the tests will pick them up.

## Licence

GPL v2 — see [LICENSE](LICENSE). DjVuLibre is GPL v2 and is linked statically,
so this extension is GPL v2 as well.
