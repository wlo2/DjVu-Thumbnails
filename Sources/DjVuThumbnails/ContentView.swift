import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The app exists so macOS has somewhere to install the extension from, and so
/// the DjVu content type gets declared. The UI is a verification tool: drop a
/// .djvu file and it asks Quick Look — not our code directly — for a
/// thumbnail, which is exactly what Finder does.
struct ContentView: View {
    @StateObject private var model = PreviewModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DjVu Thumbnails")
                .font(.title2.bold())
            Text(
                "Finder shows DjVu covers as thumbnails once this app has been "
                    + "launched from /Applications. Drop a file below to check that "
                    + "Quick Look is using the extension."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            dropArea

            statusLine
        }
        .padding(20)
        .frame(width: 420)
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .textBackgroundColor))
                )

            switch model.state {
            case .idle:
                Text("Drop a .djvu file here")
                    .foregroundColor(.secondary)
            case .loading:
                ProgressView()
            case let .thumbnail(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .shadow(radius: 2)
            case let .failure(message):
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
        .frame(height: 260)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            model.load(from: provider)
            return true
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let name = model.fileName {
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case thumbnail(NSImage)
        case failure(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var fileName: String?
    // Lets a slow, earlier drop see that a newer one has replaced it.
    private var dropCount = 0

    func load(from provider: NSItemProvider) {
        dropCount += 1
        let drop = dropCount
        state = .loading
        fileName = nil
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
            let url: URL? = {
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                return item as? URL
            }()
            Task { @MainActor in
                guard drop == self.dropCount else { return }
                guard let url else {
                    self.state = .failure(error?.localizedDescription ?? "Not a file")
                    return
                }
                self.fileName = url.lastPathComponent
                let state = await Self.thumbnailState(for: url)
                if drop == self.dropCount {
                    self.state = state
                }
            }
        }
    }

    private static func thumbnailState(for url: URL) async -> State {
        // Deliberately routed through Quick Look so a failure here means the
        // extension is not registered, not that decoding is broken.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            return .thumbnail(representation.nsImage)
        } catch {
            return .failure(
                "Quick Look could not make a thumbnail:\n\(error.localizedDescription)"
            )
        }
    }
}
