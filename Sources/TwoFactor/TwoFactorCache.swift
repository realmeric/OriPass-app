import Foundation

/// The list as it came, in one file under Caches. It is public, so unlike
/// the icons' it says nothing of him, and a week old is as good as new: the
/// check asks again when the file's age passes `TwoFactorCheck.week`.
struct TwoFactorCache {
    static let fileName = "totp.json"

    let directory: URL

    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    /// The file and the moment it was written, or nil when there is none.
    func read() -> (data: Data, written: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let written = attributes[.modificationDate] as? Date,
              (attributes[.size] as? Int ?? .max) <= TwoFactorDirectory.largest,
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, written)
    }

    func write(_ data: Data, at moment: Date) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: moment], ofItemAtPath: file.path)
    }
}
