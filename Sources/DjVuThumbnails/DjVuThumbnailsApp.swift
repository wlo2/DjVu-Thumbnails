import SwiftUI

@main
struct DjVuThumbnailsApp: App {
    init() {
        registerSpotlightImporter()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Registers the bundled Spotlight importer and has Spotlight reimport every
/// DjVu file already on disk. Spotlight does not always find importers inside
/// apps by itself, and launching the app once is already an install step.
/// Runs once per build and app location, so later launches do not reindex
/// everything again, but a copy moved out of the disk image registers anew.
private func registerSpotlightImporter() {
    let key = "registeredImporter"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let registration = "\(build) \(Bundle.main.bundlePath)"
    guard UserDefaults.standard.string(forKey: key) != registration,
        let importer = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent()
            .appendingPathComponent("Library/Spotlight/DjVuImporter.mdimporter")
    else { return }
    let mdimport = Process()
    mdimport.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
    mdimport.arguments = ["-r", importer.path]
    mdimport.terminationHandler = { process in
        if process.terminationStatus == 0 {
            UserDefaults.standard.set(registration, forKey: key)
        }
    }
    try? mdimport.run()
}
