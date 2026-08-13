// Generates the app icon: a rounded slate-blue tile with a "DjVu" wordmark.
// Renders every size macOS asks for and packs them with iconutil.
//
// Usage: swift scripts/make-icon.swift <output.icns> [preview.png]
//
// The optional PNG is written straight from the renderer rather than by resizing
// the .icns with sips, which would attach EXIF/XMP metadata chunks.

import AppKit
import CoreText

let sizes = [16, 32, 64, 128, 256, 512, 1024]

// Deep slate blue to a lighter indigo, top to bottom.
let topColor = CGColor(red: 0.16, green: 0.22, blue: 0.38, alpha: 1)
let bottomColor = CGColor(red: 0.28, green: 0.36, blue: 0.60, alpha: 1)

func render(side: Int) -> CGImage? {
    let scale = CGFloat(side) / 1024
    guard
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.scaleBy(x: scale, y: scale)  // draw everything in a 1024 space

    // macOS icons leave a margin around the tile rather than filling the canvas.
    let inset: CGFloat = 84
    let tile = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let corner = tile.width * 0.2237  // close to Apple's continuous corner radius

    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [bottomColor, topColor] as CFArray, locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY),
            options: [])
    }
    context.restoreGState()

    // At icon sizes the full wordmark turns to mush, so small tiles get just
    // the initial. This is the usual favicon trade-off.
    let text = side <= 32 ? "D" : "DjVu"
    let targetWidth = tile.width * (text.count == 1 ? 0.42 : 0.76)

    // Size the font by measuring once at a reference size and scaling.
    let reference: CGFloat = 200
    let probe = NSFont.systemFont(ofSize: reference, weight: .bold)
    let probeLine = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: probe]))
    let probeWidth = CTLineGetTypographicBounds(probeLine, nil, nil, nil)
    guard probeWidth > 0 else { return nil }
    let font = NSFont.systemFont(ofSize: reference * targetWidth / CGFloat(probeWidth), weight: .bold)

    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
    // Centre on the glyph bounds, not the typographic ones, so the wordmark sits
    // optically centred rather than pushed up by the descender of the "j".
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
        x: tile.midX - bounds.width / 2 - bounds.minX,
        y: tile.midY - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, context)

    return context.makeImage()
}

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.icns")

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// iconutil wants each size as both a 1x and the 2x of the size below it.
var names: [Int: [String]] = [:]
for size in sizes where size <= 512 {
    names[size, default: []].append("icon_\(size)x\(size).png")
    names[size * 2, default: []].append("icon_\(size)x\(size)@2x.png")
}

for (side, fileNames) in names {
    guard let image = render(side: side) else {
        FileHandle.standardError.write(Data("failed to render \(side)px\n".utf8))
        exit(1)
    }
    guard
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { exit(1) }
    for name in fileNames {
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")

/// Drops every ancillary PNG chunk except sRGB. The system PNG writer attaches
/// eXIf and XMP blocks; they hold nothing sensitive here, but a published image
/// may as well carry no metadata at all rather than invite the question.
func stripMetadata(fromPNG data: Data) -> Data {
    let keep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "tRNS"]
    var output = Data(data[0..<8])  // PNG signature
    var index = 8
    while index + 8 <= data.count {
        let length = Int(data[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) })
        let type = String(decoding: data[index + 4..<index + 8], as: UTF8.self)
        let end = index + 12 + length
        guard end <= data.count else { break }
        if keep.contains(type) {
            output.append(data[index..<end])
        }
        index = end
        if type == "IEND" { break }
    }
    return output
}

if CommandLine.arguments.count > 2 {
    let previewPath = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let image = render(side: 256),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { exit(1) }
    try stripMetadata(fromPNG: data).write(to: previewPath)
    print("wrote \(previewPath.path)")
}
