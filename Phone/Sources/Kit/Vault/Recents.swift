import Foundation

/// The ids of the last ten items used, newest first, in the App Group:
/// ids and nothing else of an item.
enum Recents {
    static let most = 10
    private static var file: URL? { Shared.container?.appending(path: "recent.json") }

    static func read() -> [String] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func used(_ id: String) {
        var ids = read().filter { $0 != id }
        ids.insert(id, at: 0)
        guard let file, let data = try? JSONEncoder().encode(Array(ids.prefix(most))) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func forget() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
