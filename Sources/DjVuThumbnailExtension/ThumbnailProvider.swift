import CoreGraphics
import Foundation
import QuickLookThumbnailing
import os.log

private let log = OSLog(subsystem: "org.djvuthumbnails.DjVuThumbnails", category: "thumbnail")

enum DjVuThumbnailError: Error, LocalizedError {
    case renderFailed(code: DJVResult, message: String?)
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case let .renderFailed(code, message):
            let detail = message.map { ": \($0)" } ?? ""
            return "DjVu page could not be decoded (code \(code.rawValue))\(detail)"
        case .imageCreationFailed:
            return "Decoded DjVu page could not be turned into an image"
        }
    }
}

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL

        // Quick Look asks in points; render at the device pixel size so the
        // thumbnail stays sharp on Retina displays.
        let maximumPixels = Int(
            max(request.maximumSize.width, request.maximumSize.height) * request.scale
        )

        do {
            let page = try DjVuPage(url: url, maximumPixelSize: max(maximumPixels, 1))
            let contextSize = page.contextSize(fitting: request.maximumSize)

            handler(QLThumbnailReply(contextSize: contextSize) { context -> Bool in
                // Take the drawable area from the context rather than assuming
                // it matches contextSize: whether Quick Look hands over a
                // point-scaled or a pixel-sized context varies, and guessing
                // wrong parks the page in one corner at the wrong scale.
                let rect = context.boundingBoxOfClipPath
                // DjVu pages are opaque paper; fill first so any transparent
                // edge from rounding reads as page, not as a hole.
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(rect)
                context.interpolationQuality = .high
                context.draw(page.image, in: rect)
                return true
            }, nil)
        } catch {
            os_log(
                "Failed to render thumbnail for %{public}@: %{public}@",
                log: log, type: .error, url.lastPathComponent,
                error.localizedDescription
            )
            // Reporting the error lets Finder fall back to the generic icon.
            handler(nil, error)
        }
    }
}

/// The decoded cover page of a DjVu document.
struct DjVuPage {
    let image: CGImage

    init(url: URL, maximumPixelSize: Int) throws {
        var bitmap = DJVBitmap()
        let result = url.withUnsafeFileSystemRepresentation { path -> DJVResult in
            guard let path else { return DJVResultBadArgument }
            return DJVRenderFirstPage(path, Int32(maximumPixelSize), &bitmap)
        }
        guard result == DJVResultOK, bitmap.data != nil else {
            throw DjVuThumbnailError.renderFailed(code: result, message: Self.lastErrorMessage())
        }
        defer { DJVBitmapFree(&bitmap) }

        guard
            let provider = CGDataProvider(
                data: Data(bytes: bitmap.data, count: bitmap.length) as CFData
            ),
            let image = CGImage(
                width: Int(bitmap.width),
                height: Int(bitmap.height),
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: Int(bitmap.bytesPerRow),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw DjVuThumbnailError.imageCreationFailed
        }
        self.image = image
    }

    /// Largest size, in points, that preserves the page aspect ratio inside
    /// `maximumSize`.
    func contextSize(fitting maximumSize: CGSize) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, maximumSize.width > 0, maximumSize.height > 0 else {
            return maximumSize
        }
        let scale = min(maximumSize.width / width, maximumSize.height / height)
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    private static func lastErrorMessage() -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        guard DJVLastErrorMessage(&buffer, buffer.count) == 1 else { return nil }
        return String(cString: buffer)
    }
}
