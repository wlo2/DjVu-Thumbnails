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
/// Runs once per build, so later launches do not reindex everything again.
private func registerSpotlightImporter() {
    let key = "registeredImporterBuild"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    guard UserDefaults.standard.string(forKey: key) != build,
        let importer = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent()
            .appendingPathComponent("Library/Spotlight/DjVuImporter.mdimporter")
    else { return }
    let mdimport = Process()
    mdimport.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
    mdimport.arguments = ["-r", importer.path]
    mdimport.terminationHandler = { process in
        if process.terminationStatus == 0 {
            UserDefaults.standard.set(build, forKey: key)
        }
    }
    try? mdimport.run()
}
