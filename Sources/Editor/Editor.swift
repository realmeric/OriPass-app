import Foundation

/// The menus the form drops, one at a time.
enum EditorMenu: Hashable {
    /// The vaults the item can be in, under the vault's name.
    case vault
    /// A card's brand, and the month it runs out in.
    case brand, month
    /// The match rules, behind the address with this id.
    case match(Int)
    /// What the linked field with this id points at.
    case linked(Int)
    /// The kinds of custom field, behind "add more".
    case addField
}

/// One item being changed (`docs/look.md`, "Editing"): the item the form
/// was filled from, and the form. It is the panes', made by ⌘E and dropped
/// by a save, a cancel and the lock, and whatever was typed into it and not
/// saved is in no other place (D6).
///
/// What is sent is `Item.patched` of the first against the second, so a
/// save sends back the object that was read with only the changed keys
/// replaced, and a passkey or a key this app has never heard of goes back
/// as it came.
@MainActor
final class Editor: ObservableObject, Redacted {
    /// What the banner says when the item was changed under the form.
    static let changedElsewhere = "This item was changed somewhere else while it was open here. "
        + "The form now holds the newer copy, with what you typed laid over it. "
        + "Save again to keep that, or cancel to leave the newer copy as it is."
    /// What a save says of an item a sync has taken away.
    static let gone = "This item is no longer in the vault."
    /// What a write says when the server holds a newer copy than the engine
    /// and no sync has brought it, in place of the engine's own sentence,
    /// which is the server's answer as it came, braces and all.
    static let behind = "This item was changed somewhere else. Sync, then try again."

    /// The rows of the form that hide what they hold.
    static let passwordRow = "password"
    static let totpRow = "totp"
    static let numberRow = "number"
    static let codeRow = "code"
    static func row(ofField id: Int) -> String { "field-\(id)" }
    static func row(of key: Identity.Key) -> String { "identity-\(key.rawValue)" }

    let id: String
    /// The item the form was filled from, or after a change somewhere else
    /// the item that change brought.
    private(set) var original: Item
    @Published var form: EditorForm {
        didSet {
            if form.password != oldValue.password { strength = Self.strength(of: form.password) }
        }
    }
    @Published var menu: EditorMenu?
    /// The hidden rows standing shown, which are the form's and go with it.
    @Published var revealed: Set<String> = []
    /// The banner over the form, once the item has been changed under it.
    @Published private(set) var notice: String?
    /// Why the last paste was not taken for a key.
    @Published private(set) var keyRefusal: String?
    @Published var isSaving = false
    /// How strong the password in the form is, worked out as it is typed.
    @Published private(set) var strength: Strength?
    private var made = 0

    var redactedLabel: String { "Editor(\(id))" }

    init(item: Item) {
        id = item.id
        original = item
        form = EditorForm(item: item)
        strength = Self.strength(of: form.password)
    }

    private static func strength(of password: String) -> Strength? {
        password.isEmpty ? nil : Strength.of(password)
    }

    /// Whether anything in the form is not what the item has.
    var isDirty: Bool { form != EditorForm(item: original) }

    /// Whether the form is of an item the engine has not been told of.
    var isNew: Bool { original.isNew }

    /// An item has to have a name, and a key that is being made a key.
    var canSave: Bool {
        guard !isSaving, !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !isNew || original.type != .sshKey || !form.key.privateKey.isEmpty
    }

    /// The item as the form has it, for `VaultStore.apply`.
    var edited: Item { form.applied(to: original) }

    // MARK: Addresses

    private func nextID() -> Int {
        made += 1
        return 1000 + made
    }

    func addAddress() {
        form.addresses.append(.init(id: nextID(), uri: "", match: nil))
    }

    /// Every address that would be asked for in the clear, written with
    /// `https` instead. Nothing is saved: it is a change in the form like
    /// any other.
    func secureAddresses() {
        for place in form.addresses.indices where Watch.isUnsecured(form.addresses[place].uri) {
            form.addresses[place].uri = Watch.secured(form.addresses[place].uri)
        }
    }

    func removeAddress(_ id: Int) {
        form.addresses.removeAll { $0.id == id }
        if menu == .match(id) { menu = nil }
    }

    func match(_ id: Int, by rule: URIMatch?) {
        menu = nil
        guard let place = form.addresses.firstIndex(where: { $0.id == id }) else { return }
        form.addresses[place].match = rule
    }

    // MARK: Custom fields

    /// What a linked field of this item can point at.
    var linkable: [(id: Int, name: String)] { EditorForm.linkable(in: original.type, username: form.username) }

    /// The kinds "add more" offers: all four, less Linked where the type
    /// has nothing to link to.
    var fieldKinds: [Field.Kind] {
        Field.Kind.allCases.filter { $0 != .linked || !linkable.isEmpty }
    }

    func addField(_ kind: Field.Kind) {
        menu = nil
        guard fieldKinds.contains(kind) else { return }
        form.fields.append(.init(id: nextID(), name: "", value: kind == .boolean ? "false" : "", kind: kind,
                                 linkedID: kind == .linked ? linkable.first?.id : nil))
    }

    func removeField(_ id: Int) {
        form.fields.removeAll { $0.id == id }
        revealed.remove(Self.row(ofField: id))
        if menu == .linked(id) { menu = nil }
    }

    /// Up for a step below nought, down for one above. A field at either
    /// end stays there.
    func moveField(_ id: Int, by step: Int) {
        guard let place = form.fields.firstIndex(where: { $0.id == id }) else { return }
        let target = place + step
        guard form.fields.indices.contains(target) else { return }
        form.fields.swapAt(place, target)
    }

    func link(_ id: Int, to linked: Int) {
        menu = nil
        guard let place = form.fields.firstIndex(where: { $0.id == id }) else { return }
        form.fields[place].linkedID = linked
    }

    func toggle(_ menu: EditorMenu) {
        self.menu = self.menu == menu ? nil : menu
    }

    // MARK: A card and a key

    func brand(_ brand: String) {
        menu = nil
        form.card.brand = brand
    }

    /// Nil is no month.
    func month(_ month: Int?) {
        menu = nil
        // July stays `07` in an item that spelled it so.
        guard Int(form.card.month.trimmingCharacters(in: .whitespaces)) != month || month == nil else { return }
        form.card.month = month.map(String.init) ?? ""
    }

    /// The private key is replaced by a whole new one or not at all, and
    /// the public key and the fingerprint go with it. Anything that is not
    /// a key leaves the three as they were and says why.
    @discardableResult
    func replaceKey(with pasted: String) -> Bool {
        do {
            let key = try PastedKey(pasted: pasted)
            form.key = .init(privateKey: key.privateKey, publicKey: key.publicKey, fingerprint: key.fingerprint)
            keyRefusal = nil
            return true
        } catch {
            keyRefusal = ((error as? PastedKey.Refusal) ?? .notAKey).sentence
            return false
        }
    }

    /// Whether the form holds a key that the item does not.
    var hasNewKey: Bool { form.key != EditorForm(item: original).key }

    // MARK: Revealing

    /// Every row that hides something, whether or not it holds anything.
    var hiddenRows: [String] {
        let own: [String]
        switch original.payload {
        case .login: own = [Self.passwordRow, Self.totpRow]
        case .card: own = [Self.numberRow, Self.codeRow]
        case .identity: own = Identity.Key.allCases.filter(\.isHidden).map(Self.row(of:))
        case .secureNote, .sshKey, .unknown: own = []
        }
        return own + form.fields.filter { $0.kind == .hidden }.map { Self.row(ofField: $0.id) }
    }

    var isAllRevealed: Bool { revealed.isSuperset(of: hiddenRows) }

    /// ⌘R, as it is in the details.
    func toggleRevealed() {
        revealed = isAllRevealed ? [] : Set(hiddenRows)
    }

    func toggleRevealed(_ row: String) {
        revealed.formSymmetricDifference([row])
    }

    // MARK: Changed somewhere else

    /// The item under the form is now `newer`. What he typed stays, and the
    /// rest of the form is the newer copy's.
    func rebase(onto newer: Item) {
        form = form.rebased(from: original, onto: newer)
        original = newer
        notice = Self.changedElsewhere
    }

    /// Whether the engine's sentence is the one for a write made from a
    /// copy older than the server's. 2026.9.1 hands on the server's whole
    /// answer behind "EditCipherError:", and the three words are the part
    /// of it a person wrote (`Tests/Fixtures/refused-out-of-date.json`).
    static func isOutOfDate(_ sentence: String) -> Bool {
        sentence.localizedCaseInsensitiveContains("out of date")
    }
}

extension Panes {
    /// Whether ⌘E and the Edit button have anything to do: an item of a
    /// type this app knows that is not in Recently Deleted, and no form
    /// already open.
    var canEdit: Bool {
        guard editor == nil, let item = selectedItem?.item else { return false }
        return item.canBeWritten && !item.isInTrash
    }

    /// The button beside a key's private half: whatever is on the
    /// pasteboard, taken for a key or refused.
    @discardableResult
    func pasteKey() -> Bool {
        editor?.replaceKey(with: clipboard.string ?? "") ?? false
    }

    /// ⌘E: the details become a form in place, once an item that asks has
    /// been answered for. The form shows nothing hidden by itself, and its
    /// eyes ask nothing more. `securing` is a banner's "Use https": the form
    /// opens with the addresses already changed, and nothing is saved.
    @discardableResult
    func beginEdit(securing: Bool = false) -> Bool {
        // The store's own, as the details are (`Panes.detail`): a form
        // filled from a row the old index was still answering with would
        // be refused at the save as changed elsewhere.
        guard canEdit, let row = selectedItem?.item else { return false }
        let item = store.entry(id: row.id)?.item ?? row
        guard !isHeldBack else {
            guarded(.edit) { $0.beginEdit(securing: securing) }
            return true
        }
        openMenu = nil
        detailMenu = nil
        if reading.menu != nil { reading.menu = nil }
        closeHistory()
        if !reading.revealed.isEmpty { reading.revealed = [] }
        if reading.cursor != nil { reading.cursor = nil }
        refused = nil
        let form = Editor(item: item)
        if securing { form.secureAddresses() }
        editor = form
        return true
    }

    /// Esc and Cancel: the form goes, after a question if anything in it
    /// was changed.
    func cancelEdit() {
        guard let editor else { return }
        if editor.menu != nil { editor.menu = nil }
        if editor.isDirty {
            isAskingToDiscard = true
        } else {
            discardEdit()
        }
    }

    /// The question's answer, and what the lock does without asking.
    func discardEdit() {
        isAskingToDiscard = false
        editor = nil
    }

    /// What everything that would take the window to another item asks
    /// first. True when there is no form in the way, which a form with
    /// nothing changed in it is not: it is put away. One with something
    /// changed stays, and the question goes up.
    func leaveEdit() -> Bool {
        guard let editor else { return true }
        guard editor.isDirty else {
            discardEdit()
            return true
        }
        isAskingToDiscard = true
        return false
    }

    /// ⌘S and Save. Nothing is sent for a form in which nothing was
    /// changed. A new item's form goes to `saveNew`. When the item was changed somewhere else meanwhile, nothing
    /// is sent either: the form is laid over the newer copy and stays open
    /// under a banner. Any other refusal leaves the form as it was typed,
    /// with the engine's sentence at the foot of the window.
    @discardableResult
    func saveEdit() -> Task<Void, Never>? {
        guard let editor, editor.canSave else { return nil }
        isAskingToDiscard = false
        editor.menu = nil
        guard editor.isDirty else {
            self.editor = nil
            return nil
        }
        refused = nil
        if editor.isNew { return saveNew(editor) }
        let id = editor.id
        // A sync took it while the form was open. There is nothing to lay
        // the form over, and it stays as it was typed.
        guard store.entry(id: id) != nil else {
            refused = Editor.gone
            return nil
        }
        editor.isSaving = true
        let edited = editor.edited
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, weak editor, store] in
            defer { self?.writes[number] = nil }
            var refusal: String?
            do {
                try await store.apply(.edit(edited), to: id)
            } catch is ItemChangedElsewhere {
                refusal = ""
            } catch VaultError.refused(let sentence) where Editor.isOutOfDate(sentence) {
                // The engine's copy is behind the server's. A sync brings
                // the newer one, and then it is the case above.
                refusal = sentence
                await store.sync()
            } catch {
                guard let self, !Task.isCancelled else { return }
                editor?.isSaving = false
                self.refused = Self.sentence(for: error)
                return
            }
            guard let self, let editor, !Task.isCancelled, self.editor === editor else { return }
            editor.isSaving = false
            guard let refusal else {
                self.editor = nil
                return
            }
            if let newer = store.entry(id: id)?.item, newer.raw != editor.original.raw {
                editor.rebase(onto: newer)
            } else {
                self.refused = refusal.isEmpty || store.entry(id: id) == nil ? Editor.gone : Editor.behind
            }
        }
        writes[number] = task
        writing = task
        return task
    }
}
