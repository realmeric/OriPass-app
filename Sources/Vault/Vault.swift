import Foundation

/// A collection of an organisation's, as `bw` lists it. The sidebar shows it
/// as a vault that nothing can be moved into (D9).
struct SharedCollection: Equatable, Identifiable {
    let id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.string, let name = json["name"]?.string else { return nil }
        self.id = id
        self.name = name
    }
}

/// One row under VAULTS: Personal, a folder, or a collection (D9).
struct Vault: Equatable, Identifiable {
    enum Place: Hashable {
        /// The items in no folder.
        case personal
        case folder(String)
        case collection(String)
    }

    let id: Place
    let name: String

    /// A collection's items are put there by its organisation, not by a drag.
    var takesItems: Bool {
        if case .collection = id { return false }
        return true
    }

    /// Only a folder can be renamed or deleted. Personal is the absence of
    /// one, and a collection is its organisation's (D9).
    var isFolder: Bool {
        if case .folder = id { return true }
        return false
    }

    static let personal = Vault(id: .personal, name: "Personal")

    /// The sidebar's order: Personal, the folders by name, the collections by
    /// name.
    static func ordered(folders: [Folder], collections: [SharedCollection]) -> [Vault] {
        [personal]
            + folders.map { Vault(id: .folder($0.id), name: $0.name) }.sorted(by: comesFirst)
            + collections.map { Vault(id: .collection($0.id), name: $0.name) }.sorted(by: comesFirst)
    }

    /// By name as a Turkish reader files it: ç after c, ı before i, ş after
    /// s, whatever language the Mac is set to.
    private static func comesFirst(_ one: Vault, _ other: Vault) -> Bool {
        one.name.compare(other.name, options: [.caseInsensitive, .numeric], range: nil,
                         locale: Locale(identifier: "tr_TR")) == .orderedAscending
    }
}
