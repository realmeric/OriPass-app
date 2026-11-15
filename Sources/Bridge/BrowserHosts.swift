import Foundation

/// The file that tells Orion where the host is, which is the whole of what
/// the app writes outside its own folders for a browser. It takes Orion's
/// folder, so that no test writes in `~/Library`, and writes only under one
/// that is there: an Orion that was never run has nothing to read it.
///
/// `allowed_origins` is the origins the card let in, for the day a browser
/// reads it. Orion does not (`docs/spikes/orion-2026-10.md`), and what keeps
/// another extension out is the card, by origin.
struct BrowserHosts {
    var orion = AppPaths.orion
    var app = Bundle.main.bundleURL
    var isDemo = Demo.isOn

    var host: URL { app.appendingPathComponent("Contents/Helpers/oripass-bridge") }

    /// An Orion that was never run has no folder, and nothing to read a file.
    var hasOrion: Bool { FileManager.default.fileExists(atPath: orion.path) }

    private var manifest: URL {
        orion.appendingPathComponent("NativeMessagingHosts/\(BridgeCaller.host.rawValue).json")
    }

    /// A copy in DerivedData says nothing about where the app is, unless it
    /// is a demo, which may write. A demo's choices are its own, though, so
    /// its "off" is no reason to take away the installed app's file.
    func follow(_ choices: BrowserChoices) {
        if isDemo ? !choices.inOrion : app.path.contains("/DerivedData/") { return }
        do {
            if choices.inOrion {
                try write(allowed: choices.allowed)
            } else if FileManager.default.fileExists(atPath: manifest.path) {
                try FileManager.default.removeItem(at: manifest)
            }
        } catch {
            Log.app.error("bridge: Orion's file did not follow: \((error as NSError).code)")
        }
    }

    private func write(allowed: [String]) throws {
        guard hasOrion else { return }
        let written: [String: Any] = [
            "name": BridgeCaller.host.rawValue, "description": AppInfo.name, "path": host.path,
            "type": "stdio", "allowed_origins": allowed,
        ]
        let data = try JSONSerialization.data(withJSONObject: written,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: manifest, options: .atomic)
    }
}
