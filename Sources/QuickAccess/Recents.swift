import Foundation

/// The ten items used last through Quick Access, the newest first, which is
/// what the panel lists before a letter is typed. Only their ids are kept,
/// here and in one small file: a list of the ids Bitwarden gave them, and
/// no title, no username and no address (D6). An id that is not one of
/// those is neither read nor written, so nothing else can get into the file
/// by way of this class.
///
/// The file outlives a lock. The ids name nothing to anyone without the
/// vault, and an id the open vault does not hold is passed over when the
/// panel draws.
final class Recents {
    static let most = 10

    private(set) var ids: [String]
    private let file: URL?

    /// Without a file the list is in memory only, which is what a shot, a
    /// demo and most tests want.
    init(file: URL?) {
        self.file = file
        let read = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        ids = Array(Self.unique(read.filter(Self.isID)).prefix(Self.most))
    }

    func use(_ id: String) {
        guard Self.isID(id), ids.first != id else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        ids = Array(ids.prefix(Self.most))
        write()
    }

    /// The account has gone from this Mac, and its ids with it.
    func forget() {
        ids = []
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func write() {
        guard let file, let data = try? JSONEncoder().encode(ids) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.app.error("the recent items were not written: \((error as NSError).code)")
        }
    }

    static func isID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    private static func unique(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
