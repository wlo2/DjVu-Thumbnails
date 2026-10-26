<table>
<tr>
<td><img src="docs/icon.png" alt="" width="96"></td>
<td>

# DjVu Thumbnails

**Finder thumbnails for DjVu documents on macOS, like the ones PDFs already get.**

</td>
</tr>
</table>

A Quick Look thumbnail extension that renders page 1 of `.djvu` / `.djv` files, so
Finder shows the cover instead of a generic blank icon. It handles every DjVu
flavour: bitonal JB2 scans, IW44 colour pages, foreground/background layered
pages, shared JB2 dictionaries, and bundled multipage documents.

[DjVuLibre](https://djvu.sourceforge.net) does the decoding. It is built from
source and linked statically, so the extension depends on nothing outside its
own bundle. Universal: arm64 and x86_64.

## Install

Download the `.dmg` from the releases page, or build it yourself:

```bash
./scripts/make-dmg.sh
```

Then:

1. Drag **DjVu Thumbnails.app** to `/Applications`.
2. Clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/DjVu Thumbnails.app"
   ```
3. **Launch the app once.** This registers the DjVu document type with macOS.
   You can quit it afterwards and Finder keeps working.

To install a local build straight into `/Applications` instead, use
`./scripts/install.sh`.

If Finder still shows generic icons for files it had already cached:

```bash
qlmanage -r cache && killall Finder
```

## Build from source

Requirements: macOS 12+, full Xcode (the command line tools alone cannot build
the SwiftUI app), and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./scripts/build-app.sh
```

This downloads DjVuLibre 3.5.29 and verifies its checksum, builds it as a static
universal library, generates the Xcode project and builds a universal app.

| Script | Purpose |
| --- | --- |
| `build-djvulibre.sh` | Fetches and builds DjVuLibre as a static universal `.a` |
| `build-app.sh` | Generates the project and builds the app |
| `install.sh` | Installs to `/Applications` and registers it |
| `make-dmg.sh` | Packages a distributable `.dmg` and puts the DjVuLibre source tarball beside it; upload both to the release |
| `make-icon.swift` | Regenerates `AppIcon.icns` |
| `make-fixtures.sh` | Regenerates the DjVu test fixtures |
| `test.sh` | Runs the test suite |

The Xcode project is generated and not committed. To change it, edit
[`project.yml`](project.yml) and run `xcodegen generate`.

## Structure

| Component | Role |
| --- | --- |
| [`Sources/CDjVuRender`](Sources/CDjVuRender) | C shim over DjVuLibre's `ddjvu` API; decodes page 1 into an RGB bitmap |
| [`Sources/DjVuThumbnailExtension`](Sources/DjVuThumbnailExtension) | The `QLThumbnailProvider`. Sandboxed, statically linked against DjVuLibre |
| [`Sources/DjVuThumbnails`](Sources/DjVuThumbnails) | Host app: declares the DjVu content type, and lets you drop a file to verify the extension is live |

If you work on the code, three things will save you time.

**macOS ships no DjVu type declaration at all.** Nothing on a stock system maps
`.djvu` onto a content type, so Quick Look would never consult a thumbnail
extension. The host app declares `com.lizardtech.djvu` in
`UTExportedTypeDeclarations` and the extension registers for that type. That is
why the app has to be launched once.

**Quick Look's drawing context is not in the units the API implies.**
`QLThumbnailReply(contextSize:drawing:)` takes a size in points, but the context
handed to the drawing block is not necessarily scaled to match. Code that assumes
it is parks the page in a corner at the wrong scale. The provider takes its
drawing rect from `context.boundingBoxOfClipPath` instead, which is correct
either way.

**`xcodebuild` needs `-destination 'generic/platform=macOS'`.** Without it,
`xcodebuild` builds only the current Mac's architecture and gives no warning, so
the result will not run on Intel.

## Tests

```bash
./scripts/test.sh
```

The suite has three layers:

1. The decoder shim under AddressSanitizer. A non-DjVu file, a truncated one and
   a missing one must all be rejected without a crash or a hang.
2. Orientation and colour assertions against synthetic fixtures, plus a check
   that a multipage document thumbnails its cover and not a later page.
3. The installed extension through Quick Look, at large and Finder-icon sizes.
   Each thumbnail is compared against a direct decode of the same file. A
   thumbnail that is letterboxed into a corner, upside down or colour-swapped
   still has plausible dimensions, and only this comparison catches it.

Layer 3 needs the app installed and registered. It fails if the installed
extension is not the one in `build/`, so run `install.sh` after building. Any
`sample*.djvu` files in the repository root are tested too.

## Licence

GPL v3 (see [LICENSE](LICENSE)). DjVuLibre is licensed under GPL v2 or any
later version and is linked statically, which lets the combined work use v3.
