// End-to-end check of the installed extension.
//
// For each file it asks Quick Look — the same path Finder uses — for a
// thumbnail, then decodes the same file directly through the extension's
// DjVuPage and compares the two. Comparing against a direct decode is what makes this
// meaningful: a thumbnail that is letterboxed into a corner, upside down, or
// colour-swapped still has plausible dimensions, but it will not match.
//
// Usage: qlcheck [--dump-dir DIR] [--size N] [--scale N] file.djvu ...

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Mean absolute difference per channel, on a 0-255 scale, below which the two
// renders count as the same image. Quick Look resamples, so it is never zero.
let matchTolerance = 12.0

var dumpDir: URL?
var size: CGFloat = 512
var scale: CGFloat = 2
var paths: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--dump-dir":
        if let dir = args.first {
            args.removeFirst()
            dumpDir = URL(fileURLWithPath: dir)
        }
    case "--size":
        if let value = args.first.flatMap(Double.init) {
            args.removeFirst()
            size = CGFloat(value)
        }
    case "--scale":
        if let value = args.first.flatMap(Double.init) {
            args.removeFirst()
            scale = CGFloat(value)
        }
    default:
        paths.append(arg)
    }
}
guard !paths.isEmpty else {
    FileHandle.standardError.write(
        Data("usage: qlcheck [--dump-dir DIR] [--size N] [--scale N] file...\n".utf8))
    exit(2)
}

/// Reduces an image to a small greyscale grid, so two renders of the same page
/// can be compared regardless of their exact pixel dimensions.
func signature(of image: CGImage, side: Int = 24) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: side * side)
    pixels.withUnsafeMutableBytes { raw in
        guard
            let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    return pixels
}

func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    return Double(total) / Double(a.count)
}

// A missing content type is the most likely reason for the extension never
// being consulted at all, so report it up front.
if let type = UTType(filenameExtension: "djvu") {
    print("UTI for .djvu: \(type.identifier) (declared: \(type.isDeclared))")
} else {
    print("UTI for .djvu: NONE — Launch Services does not know the DjVu type")
}
print("requesting \(Int(size))pt @\(Int(scale))x")

var failures = 0
let group = DispatchGroup()
let lock = NSLock()

for path in paths {
    let url = URL(fileURLWithPath: path)
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: CGSize(width: size, height: size),
        scale: scale,
        representationTypes: .thumbnail
    )
    group.enter()
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
        defer { group.leave() }
        lock.lock()
        defer { lock.unlock() }

        let name = url.lastPathComponent
        guard let representation else {
            failures += 1
            print("FAIL \(name): \(error?.localizedDescription ?? "no reason given")")
            return
        }
        let image = representation.cgImage

        // DjVuPage is the extension's own decoder, so this bypasses only Quick Look.
        guard
            let reference = try? DjVuPage(
                url: url, maximumPixelSize: max(image.width, image.height)
            ).image
        else {
            failures += 1
            print("FAIL \(name): Quick Look produced an image but direct decoding failed")
            return
        }
        let difference = meanAbsoluteDifference(signature(of: image), signature(of: reference))
        let matches = difference <= matchTolerance
        if !matches { failures += 1 }
        print(
            "\(matches ? "OK  " : "FAIL") \(name): \(image.width)x\(image.height), "
                + String(format: "difference from a direct decode %.1f", difference)
                + " (tolerance \(Int(matchTolerance)))")

        guard let dumpDir else { return }
        let out = dumpDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("png")
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        {
            try? data.write(to: out)
            print("     wrote \(out.path)")
        }
    }
}

if group.wait(timeout: .now() + 120) == .timedOut {
    print("FAIL timed out waiting for Quick Look")
    exit(1)
}
exit(failures == 0 ? 0 : 1)
