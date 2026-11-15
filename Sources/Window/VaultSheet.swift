import SwiftUI

/// What the sidebar's rows can do to a vault, behind a right click
/// (`docs/look.md`, "The sidebar").
enum VaultAct: Hashable {
    case rename, delete

    var name: String {
        switch self {
        case .rename: return "Rename…"
        case .delete: return "Delete…"
        }
    }
}

/// The card that asks for a vault's name, while the plus beside VAULTS or
/// Rename has it up: what is typed, and the sentence under it when the name
/// was refused. Nothing is sent until Return.
struct VaultNaming: Equatable {
    enum Purpose: Equatable {
        case making
        case renaming(Vault.Place, was: String)
    }

    let purpose: Purpose
    /// A new keystroke takes the refusal off, since it was about the name as
    /// it stood.
    var name: String {
        didSet { problem = nil }
    }
    var problem: String?
    /// The engine has the name and has not answered.
    var isSending = false

    init(_ purpose: Purpose) {
        self.purpose = purpose
        if case .renaming(_, let was) = purpose { name = was } else { name = "" }
    }

    var title: String {
        switch purpose {
        case .making: return "New Vault"
        case .renaming(_, let was): return "Rename “\(was)”"
        }
    }

    var sentence: String {
        switch purpose {
        case .making: return "A vault is a folder of this account, so every device signed in to it shows the new one."
        case .renaming: return "Every device signed in to this account shows the new name."
        }
    }

    var button: String {
        if case .making = purpose { return "Create" }
        return "Rename"
    }

    var place: Vault.Place? {
        if case .renaming(let place, _) = purpose { return place }
        return nil
    }

    var canSend: Bool {
        !isSending && !name.allSatisfy(\.isWhitespace)
    }
}

extension Panes {
    /// What a vault's menu has: a folder's two acts, and nothing for
    /// Personal or a collection. A window of one item has no sidebar.
    func acts(for vault: Vault) -> [VaultAct] {
        pinned == nil && vault.isFolder ? [.rename, .delete] : []
    }

    func perform(_ act: VaultAct, on vault: Vault) {
        switch act {
        case .rename: beginRename(vault.id)
        case .delete: beginDelete(vault.id)
        }
    }

    /// The plus beside VAULTS.
    @discardableResult
    func beginNewVault() -> Bool {
        guard pinned == nil else { return false }
        putAwayForNaming()
        naming = VaultNaming(.making)
        return true
    }

    @discardableResult
    func beginRename(_ place: Vault.Place) -> Bool {
        guard let vault = vaults.first(where: { $0.id == place }), !acts(for: vault).isEmpty else { return false }
        putAwayForNaming()
        naming = VaultNaming(.renaming(place, was: vault.name))
        return true
    }

    @discardableResult
    func beginDelete(_ place: Vault.Place) -> Bool {
        guard let vault = vaults.first(where: { $0.id == place }), !acts(for: vault).isEmpty else { return false }
        putAwayForNaming()
        deletingVault = vault
        return true
    }

    private func putAwayForNaming() {
        openMenu = nil
        detailMenu = nil
        naming = nil
        deletingVault = nil
        if reading.menu != nil { reading.menu = nil }
    }

    /// Return on the card. A name that cannot be used is said so at once and
    /// the engine is not asked; one it refuses is said in its own sentence,
    /// and either way what was typed stays. Nil when nothing was sent.
    @discardableResult
    func submitNaming() -> Task<Void, Never>? {
        guard let asking = naming, asking.canSend else { return nil }
        let name: String
        do {
            name = try store.checkedName(asking.name, renaming: asking.place)
        } catch {
            naming?.problem = Self.sentence(for: error)
            return nil
        }
        naming?.isSending = true
        refused = nil
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, store] in
            defer { self?.writes[number] = nil }
            do {
                switch asking.purpose {
                case .making:
                    let made = try await store.makeVault(named: name)
                    guard let self, !Task.isCancelled else { return }
                    self.naming = nil
                    if let made { self.show(made) }
                case .renaming(let place, _):
                    try await store.renameVault(place, to: name)
                    guard let self, !Task.isCancelled else { return }
                    self.naming = nil
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.naming?.isSending = false
                self.naming?.problem = Self.sentence(for: error)
            }
        }
        writes[number] = task
        writing = task
        return task
    }

    /// The new vault's row, opened under the heading if that was folded.
    /// A form with something in it is not asked about: it has not been left.
    private func show(_ vault: Vault) {
        if vaultsFolded { toggleVaults() }
        if editor == nil { select(.vault(vault.id)) }
    }

    /// Delete Vault on the question. The items are the engine's to place;
    /// the row he was on goes to All Items by itself once the folder is gone.
    @discardableResult
    func confirmDeleteVault() -> Task<Void, Never>? {
        guard let vault = deletingVault else { return nil }
        deletingVault = nil
        refused = nil
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, store] in
            defer { self?.writes[number] = nil }
            do {
                try await store.deleteVault(vault.id)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.refused = Self.sentence(for: error)
            }
        }
        writes[number] = task
        writing = task
        return task
    }
}

// MARK: - Drawn

/// What is laid over the window for a vault: the card asking for a name, or
/// the question before one is deleted.
struct VaultLayer: View {
    @ObservedObject var panes: Panes

    var body: some View {
        if let naming = panes.naming {
            VaultNameCard(naming: Binding(get: { panes.naming ?? naming },
                                          set: { if panes.naming != nil { panes.naming = $0 } }),
                          cancel: { panes.naming = nil }, send: { panes.submitNaming() })
                .transition(Motion.transition(.fade))
        } else if let vault = panes.deletingVault {
            VaultDeleteQuestion(name: vault.name, cancel: { panes.deletingVault = nil },
                                delete: { panes.confirmDeleteVault() })
                .transition(Motion.transition(.fade))
        }
    }
}

private struct VaultNameCard: View {
    @Binding var naming: VaultNaming
    let cancel: () -> Void
    let send: () -> Void
    @FocusState private var fieldHasKeys: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            VStack(spacing: Metrics.loose) {
                Glyph.move.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.secondText)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.close) {
                    Text(naming.title)
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text(naming.sentence)
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Metrics.close) {
                    field
                    // Held open, so the card does not jump when a refusal arrives.
                    Text(naming.problem ?? " ")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(naming.problem == nil)
                }
                HStack(spacing: Metrics.gap) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(naming.button, action: send)
                        .buttonStyle(FilledButtonStyle())
                        .opacity(naming.canSend ? 1 : Palette.disabled)
                        .disabled(!naming.canSend)
                }
            }
            .padding(Metrics.apart)
            .frame(width: Metrics.offerWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
        }
        .ignoresSafeArea()
        .onAppear { fieldHasKeys = true }
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
        return TextField("", text: $naming.name, prompt: Text("Name").foregroundStyle(Palette.prompt))
            .textFieldStyle(.plain)
            .font(Fonts.lockField)
            .foregroundStyle(Palette.text)
            .focused($fieldHasKeys)
            .onSubmit(send)
            .onExitCommand(perform: cancel)
            .padding(.horizontal, Metrics.gap)
            .frame(height: Metrics.lockField.height)
            .background(shape.fill(Palette.field))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.lockFieldRadius + Metrics.focusRing, style: .continuous)
                    .strokeBorder(Palette.focusRing, lineWidth: Metrics.focusRing)
                    .padding(-Metrics.focusRing)
                    .opacity(fieldHasKeys ? 1 : 0)
            )
            .opacity(naming.isSending ? Palette.disabled : 1)
            .disabled(naming.isSending)
            .accessibilityLabel("Name of the vault")
    }
}

/// The question between Delete and a vault being gone: its name, and what
/// happens to what was in it.
struct VaultDeleteQuestion: View {
    let name: String
    var cancel: () -> Void = {}
    var delete: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim.ignoresSafeArea()
            VStack(spacing: Metrics.loose) {
                Glyph.trash.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.red)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.close) {
                    Text("Delete the vault “\(name)”?")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text("Its items are kept. They fall back to Personal, and the vault is gone from every device signed in to this account.")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.gap) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Delete Vault", action: delete)
                        .buttonStyle(FilledButtonStyle(ground: Palette.redLit))
                }
            }
            .padding(Metrics.apart)
            .frame(width: Metrics.offerWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        }
        .ignoresSafeArea()
    }
}

extension Surface {
    private static func vault(_ name: String, _ arrange: @escaping @MainActor (Panes) -> Void) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The card the plus raises, with a name typed and with one that is
    /// taken; Rename on a vault; and the question Delete asks.
    static let vaultSheets: [Surface] = [
        vault("vault-new") { $0.beginNewVault() },
        vault("vault-new-typed") { panes in
            panes.beginNewVault()
            panes.naming?.name = "Okul"
        },
        vault("vault-new-taken") { panes in
            panes.beginNewVault()
            panes.naming?.name = "personal"
            panes.submitNaming()
        },
        vault("vault-rename") { panes in
            panes.selectVault(at: 2)
            if let place = panes.vaults.dropFirst(2).first?.id { panes.beginRename(place) }
        },
        vault("vault-delete-question") { panes in
            panes.selectVault(at: 2)
            if let place = panes.vaults.dropFirst(2).first?.id { panes.beginDelete(place) }
        },
    ]
}
