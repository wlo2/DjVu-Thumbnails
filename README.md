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

A Spotlight importer makes DjVu books searchable: it indexes the hidden OCR text
layer (up to 10 MB per file), the title, authors and keywords, and the page
count. Search for any word in a book with Spotlight (⌘Space) or a Finder search
(⌘F). Scans without a text layer get the metadata and page count only.

[DjVuLibre](https://djvu.sourceforge.net) does the decoding. It is built from
source and linked statically, so the extension and the importer depend on
nothing outside their own bundles. Universal: arm64 and x86_64.

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
3. **Launch the app once.** This registers the DjVu document type with macOS
   and has Spotlight index the DjVu files already on your Mac. You can quit it
   afterwards and Finder and Spotlight keep working.

To install a local build straight into `/Applications` instead, use
`./scripts/install.sh`.

If Finder still shows generic icons for files it had already cached:

```bash
qlmanage -r cache && killall Finder
```

To have Spotlight index a folder of DjVu files again right away:

```bash
mdimport ~/Books
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
| [`Sources/CDjVuRender`](Sources/CDjVuRender) | C shim over DjVuLibre's `ddjvu` API; decodes page 1 into an RGB bitmap, and reads the text layer and metadata |
| [`Sources/DjVuThumbnailExtension`](Sources/DjVuThumbnailExtension) | The `QLThumbnailProvider`. Sandboxed, statically linked against DjVuLibre |
| [`Sources/DjVuImporter`](Sources/DjVuImporter) | The Spotlight importer, a CFPlugIn installed at `Contents/Library/Spotlight` in the app. Statically linked against DjVuLibre |
| [`Sources/DjVuThumbnails`](Sources/DjVuThumbnails) | Host app: declares the DjVu content type, registers the importer on first launch, and lets you drop a file to verify the extension is live |

If you work on the code, four things will save you time.

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

**The Spotlight importer is a classic `.mdimporter`, not an app extension.**
Spotlight on macOS does not call `CSImportExtension` app extensions for ordinary
files, and Apple's developer support names the old `MDImport` plug-in as the
only working route. Every build registers the copy in `build/` as well, and
Spotlight may run either copy for a while; `test.sh` checks that the installed
copy is identical. `mdimport -t -d2 file.djvu` shows which copy ran and what it
returned.

## Tests

```bash
./scripts/test.sh
```

The suite has four layers:

1. The decoder shim under AddressSanitizer. A non-DjVu file, a truncated one and
   a missing one must all be rejected without a crash or a hang. Then 300 fresh
   processes each render from 8 threads at once, the way Quick Look calls the
   extension, because DjVuLibre is not safe to start up from several threads.
2. Orientation and colour assertions against synthetic fixtures, plus a check
   that a multipage document thumbnails its cover and not a later page.
3. The Spotlight importer, called directly and under AddressSanitizer: the text
   of every page, the metadata, and the 10 MB cap, which must never split a
   UTF-8 character.
4. The installed app. Quick Look renders thumbnails at large and Finder-icon
   sizes, and each is compared against a direct decode of the same file: a
   thumbnail that is letterboxed into a corner, upside down or colour-swapped
   still has plausible dimensions, and only this comparison catches it. Then
   Spotlight indexes a fixture and must find it by a word that only its second
   page contains.

Layer 4 needs the app installed and registered. It fails if the installed
extension or importer is not the one in `build/`, so run `install.sh` after
building. Any `sample*.djvu` files in the repository root are tested too.

## Licence

GPL v3 (see [LICENSE](LICENSE)). DjVuLibre is licensed under GPL v2 or any
later version and is linked statically, which lets the combined work use v3.
