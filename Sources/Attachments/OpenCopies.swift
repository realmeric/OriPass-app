import Foundation

/// The one place this app writes something decrypted (D6): the copy of an
/// attachment that Quick Look is reading. Each copy is in a folder of its
/// own under one directory of mode 0700, under its own name, so the preview
/// is titled as the file is. A copy goes when its preview closes, every one
/// of them goes at the lock, and whatever a crash left is gone at the next
/// launch.
///
/// Taking the folder away, and not only the file in it, is what stops an
/// answer that arrives after the lock from being written: there is nowhere
/// left to write it.
final class OpenCopies {
    let directory: URL
    private let files = FileManager.default

    init(directory: URL) {
        self.directory = directory
    }

    /// Where the engine may write a file called `name`. Nothing is there
    /// yet but the folder.
    func place(for name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        // An older directory keeps the mode it was made with.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try files.createDirectory(at: folder, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent(Self.safe(name))
    }

    /// The copy and the folder made for it.
    func remove(_ copy: URL) {
        let folder = copy.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? files.removeItem(at: folder)
    }

    func removeAll() {
        try? files.removeItem(at: directory)
    }

    /// Every file under the directory, for a test and for the tour.
    var held: [URL] {
        let found = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return (found?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    /// A name the vault holds is whatever somebody typed into another
    /// client. Here it is one component of a path and nothing more: no
    /// slash, no colon, and not the two names that mean a directory.
    static func safe(_ name: String) -> String {
        let cleaned = String(name.map { "/:\0".contains($0) ? "_" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment" : cleaned
    }
}
