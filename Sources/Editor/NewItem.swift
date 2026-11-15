import Foundation

/// The sheet behind ⌘N while it is up (`docs/look.md`, "New Item"): what is
/// typed into its field, and which of the tiles that leaves is lit, which is
/// the one Return takes.
struct NewItemChoice: Equatable {
    /// The five, in the order the categories' menu has them (D11).
    static let kinds: [ItemType] = [.login, .secureNote, .card, .identity, .sshKey]

    var query = "" {
        didSet { cursor = 0 }
    }
    private(set) var cursor = 0

    /// The tiles drawn: all five, or the ones whose name has what was typed
    /// in it, with İ, I, ı and i as one letter.
    var kinds: [ItemType] {
        let wanted = SearchIndex.folded(query.trimmingCharacters(in: .whitespaces))
        guard !wanted.isEmpty else { return Self.kinds }
        return Self.kinds.filter { SearchIndex.folded($0.kind).contains(wanted) }
    }

    var lit: ItemType? {
        let kinds = self.kinds
        return kinds.indices.contains(cursor) ? kinds[cursor] : nil
    }

    /// Left and right. The tile at either end stays lit.
    mutating func move(by step: Int) {
        cursor = min(max(cursor + step, 0), max(kinds.count - 1, 0))
    }
}

extension ItemType {
    /// What one item of the type is called, on its tile and in its form.
    var kind: String {
        switch self {
        case .login: return "Login"
        case .secureNote: return "Secure Note"
        case .card: return "Credit Card"
        case .identity: return "Identity"
        case .sshKey: return "SSH Key"
        case .unknown: return "Item"
        }
    }
}

extension Panes {
    /// Whether ⌘N and the toolbar's button have anything to do, which a
    /// window of one item has not.
    var canMakeNew: Bool { pinned == nil }

    /// ⌘N and the toolbar's button: the sheet goes up. A form with
    /// something changed in it asks its question first.
    @discardableResult
    func beginNew() -> Bool {
        guard canMakeNew, leaveEdit() else { return false }
        openMenu = nil
        detailMenu = nil
        if reading.menu != nil { reading.menu = nil }
        closeHistory()
        showsKeys = false
        choosing = NewItemChoice()
        return true
    }

    /// Where a new item goes: the vault the sidebar has selected, and
    /// Personal under every other row.
    var newItemPlace: Vault.Place {
        if case .vault(let place) = selection, vaults.first(where: { $0.id == place })?.takesItems == true {
            return place
        }
        return .personal
    }

    /// A tile chosen, or Return on the lit one: the sheet goes, and the
    /// details become that type's empty form once the engine has said what
    /// such an item is made of. Nothing is sent to it until Save.
    @discardableResult
    func make(_ type: ItemType) -> Task<Void, Never>? {
        guard choosing != nil, canMakeNew, editor == nil else { return nil }
        choosing = nil
        refused = nil
        let place = newItemPlace
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, store] in
            defer { self?.writes[number] = nil }
            do {
                let blank = try await store.blank(type, in: place)
                guard let self, !Task.isCancelled else { return }
                self.open(new: blank)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if let shape = error as? ShapeError {
                    self.refused = shape.sentence
                } else {
                    self.refused = Self.sentence(for: error)
                }
            }
        }
        writes[number] = task
        writing = task
        return task
    }

    /// The details as the form of an item that is nowhere yet.
    func open(new blank: Item) {
        guard blank.isNew, editor == nil else { return }
        if !reading.revealed.isEmpty { reading.revealed = [] }
        if reading.cursor != nil { reading.cursor = nil }
        editor = Editor(item: blank)
    }

    /// Save on a form that has no item under it: the engine makes one, and
    /// the list is brought to it. A refusal leaves the form as it was typed.
    func saveNew(_ editor: Editor) -> Task<Void, Never> {
        editor.isSaving = true
        let edited = editor.edited
        let blank = editor.original
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, weak editor, store] in
            defer { self?.writes[number] = nil }
            let made: Item?
            do {
                made = try await store.create(edited, from: blank)
            } catch {
                guard let self, !Task.isCancelled else { return }
                editor?.isSaving = false
                self.refused = Self.sentence(for: error)
                return
            }
            guard let self, let editor, !Task.isCancelled, self.editor === editor else { return }
            editor.isSaving = false
            self.editor = nil
            guard let made else { return }
            self.select(item: made.id)
            // A category it is not in, Favourites, or a search.
            if self.selectedItem == nil { self.show(item: made.id) }
        }
        writes[number] = task
        writing = task
        return task
    }
}
