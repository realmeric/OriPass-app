import Foundation

/// Why a write did not take.
enum SaveFailure: Error, Equatable {
    /// The item changed somewhere else since this copy; the vault was
    /// synced and the write can be tried again.
    case outOfDate
    case refused(String?)
    case notOpen

    /// The server's refusal read: its sentence for a write made from an
    /// older copy is "The cipher you are updating is out of date. ..."
    init(_ failure: Api.Failure) {
        switch failure {
        case .status(400, let said?) where said.localizedCaseInsensitiveContains("out of date"): self = .outOfDate
        case .status(_, let said): self = .refused(said)
        default: self = .refused(nil)
        }
    }
}

/// A login or a note written to the account, from the app or from the
/// AutoFill extension: an edit with only what changed encrypted again, or a
/// new item under the user key, and then a sync, whose answer is returned.
enum Saving {
    static func save(_ draft: Draft, editing item: Item?, in vault: Vault, with api: Api) async throws -> Data {
        guard let data = VaultFile.read() else { throw SaveFailure.notOpen }
        do {
            if let item {
                guard let raw = Writes.raw(item.id, in: data) else { throw SaveFailure.notOpen }
                let body = try Writes.edit(raw, from: item, to: draft, key: vault.key(for: item.id))
                _ = try await api.send("ciphers/\(item.id)", method: "PUT", json: JSONSerialization.data(withJSONObject: body))
            } else {
                let body = try Writes.create(draft, key: vault.userKey)
                _ = try await api.send("ciphers", method: "POST", json: JSONSerialization.data(withJSONObject: body))
            }
        } catch let failure as Api.Failure {
            throw SaveFailure(failure)
        }
        return try await VaultFile.sync(with: api)
    }

    /// A passkey kept on a login, or on a new one named for its site. The
    /// extension reads the vault as it was last synced, so a write refused
    /// as out of date goes once more from a sync taken here.
    static func keep(_ passkey: Item.Passkey, on item: Item?, in vault: Vault, with api: Api) async throws -> Data {
        do {
            return try await save(draft(for: passkey, on: item), editing: item, in: vault, with: api)
        } catch SaveFailure.outOfDate {
            guard let item else { throw SaveFailure.outOfDate }
            let fresh = try Vault(data: await VaultFile.sync(with: api), userKey: vault.userKey)
            let current = try fresh.item(id: item.id)
            return try await save(draft(for: passkey, on: current), editing: current, in: fresh, with: api)
        }
    }

    private static func draft(for passkey: Item.Passkey, on item: Item?) -> Draft {
        var draft = item.map(Draft.init) ?? Draft()
        if item == nil {
            draft.name = passkey.rpId
            draft.username = passkey.userName ?? ""
            draft.uris = ["https://" + passkey.rpId]
        }
        draft.passkey = passkey
        return draft
    }

    /// The login for a site and a username, when the vault has one: a
    /// password saved from a sign-up form or a change goes there.
    static func existing(host: String, username: String, in vault: Vault) -> Item? {
        let page = Matching(pages: [Matching.Page(url: nil, host: host.lowercased(), app: nil)])
        guard let summary = vault.summaries().first(where: { $0.kind == .login && $0.username == username && page.matches($0) })
        else { return nil }
        return try? vault.item(id: summary.id)
    }
}
