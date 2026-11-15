import SwiftUI
import UniformTypeIdentifiers

/// The two menus the strip over the details drops: the item's own, behind
/// the ellipsis, and the vaults it can be moved to, under the vault's name.
enum DetailMenu: Hashable {
    case item, move
}

/// A row of the item's menu (`docs/look.md`, "The item menu").
enum ItemAct: Hashable {
    case openWindow, favourite, unfavourite, move, duplicate, attach, archive, unarchive, delete
    /// The two an item in Recently Deleted has in place of all the rest.
    case restore, deleteForGood

    var name: String {
        switch self {
        case .openWindow: return "Open in New Window"
        case .favourite: return "Add to Favorites"
        case .unfavourite: return "Remove from Favorites"
        case .move: return "Move"
        case .duplicate: return "Duplicate"
        case .attach: return "Attach a File…"
        case .archive: return "Archive"
        case .unarchive: return "Unarchive"
        case .delete: return "Delete"
        case .restore: return "Restore"
        case .deleteForGood: return "Delete Permanently"
        }
    }

    var glyph: Glyph {
        switch self {
        case .openWindow: return .newWindow
        case .favourite: return .favorites
        case .unfavourite: return .unfavourite
        case .move: return .move
        case .duplicate: return .duplicate
        case .attach: return .attachment
        case .archive: return .archive
        case .unarchive, .restore: return .restore
        case .delete, .deleteForGood: return .trash
        }
    }

    var isRed: Bool { self == .delete || self == .deleteForGood }
}

extension Panes {
    /// What a drag out of the list carries: the item's id, to this process
    /// and no other.
    static let dragType = UTType(exportedAs: "com.meric.oripass.item")

    /// How long Recently Deleted keeps an item, which is the server's rule
    /// and is said to him before he cuts it short.
    static let trashDays = 30

    // MARK: The menus

    /// The menu's rows for the item in the details, a rule between one
    /// group and the next. A type this app cannot write is not favoured,
    /// moved or copied, and can still be put away and deleted, since those
    /// send nothing of it (D11).
    var itemActs: [[ItemAct]] {
        guard let item = selectedItem?.item else { return [] }
        if item.isInTrash { return [[.restore, .deleteForGood]] }
        var groups: [[ItemAct]] = pinned == nil ? [[.openWindow]] : []
        if item.canBeWritten {
            // An organisation's item is not copied: the copy would be
            // the organisation's too, in the same collections (D9).
            let copy: [ItemAct] = item.organizationID == nil ? [.duplicate] : []
            groups.append([item.favorite ? .unfavourite : .favourite, .move] + copy + [.attach])
        }
        groups.append([item.isArchived ? .unarchive : .archive, .delete])
        return groups
    }

    /// Whether the vault's name over the details is a menu.
    var canMove: Bool {
        guard let item = selectedItem?.item else { return false }
        return item.canBeWritten && !item.isInTrash
    }

    /// Personal and the folders. A collection's items are its
    /// organisation's to place (D9).
    var moveTargets: [Vault] { vaults.filter(\.takesItems) }

    func toggle(_ menu: DetailMenu) {
        openMenu = nil
        reading.menu = nil
        guard detailMenu != menu, selectedItem != nil, menu == .item || canMove else {
            detailMenu = nil
            return
        }
        detailMenu = menu
    }

    func perform(_ act: ItemAct) {
        guard let id = selectedItem?.id else { return }
        detailMenu = nil
        switch act {
        case .openWindow: windows?.open(id, from: self)
        case .move: toggle(.move)
        case .deleteForGood: confirming = id
        case .favourite: write(.favourite(true), to: id)
        case .unfavourite: write(.favourite(false), to: id)
        case .duplicate: write(.duplicate, to: id)
        case .attach: attachFile()
        case .archive: write(.archive, to: id)
        case .unarchive: write(.unarchive, to: id)
        case .delete: write(.delete, to: id)
        case .restore: write(.restore, to: id)
        }
    }

    func move(to place: Vault.Place) {
        guard canMove, let id = selectedItem?.id else { return }
        write(.move(place), to: id)
    }

    // MARK: The keys

    /// ⌘O.
    @discardableResult
    func openWindow() -> Bool {
        guard itemActs.joined().contains(.openWindow) else { return false }
        perform(.openWindow)
        return true
    }

    /// Whether ⇧⌘F has a page to open and a login to fill it with.
    var canOpenAndFill: Bool {
        armedFill != nil && selectedItem.map { ArmedFill.canOpen($0.item) } == true
    }

    /// ⇧⌘F: the login's first address in the default browser, and for two
    /// minutes ⌘\ in that browser fills this login (`ArmedFill`). Opening a
    /// page gives nothing up, so an item that asks is asked at the fill and
    /// not here.
    @discardableResult
    func openAndFill() -> Bool {
        guard let armedFill, let item = selectedItem?.item else { return false }
        return armedFill.open(item, at: store.now())
    }

    /// Something stands over the window and waits for an answer of its
    /// own, or the details are a form: a vault being named or deleted, the
    /// question before an item goes for good or a form is discarded, the
    /// sheet a new item is chosen from. The item lit in the list is not
    /// what a key pressed then is about, and Delete and ⌘Delete, which ask
    /// nothing, do nothing to it.
    var isAsking: Bool {
        deletingVault != nil || naming != nil || confirming != nil || isAskingToDiscard || choosing != nil
            || editor != nil
    }

    /// Whether ⌘Delete has an item to delete and nothing in its way.
    var canDeleteSelected: Bool {
        !isAsking && itemActs.joined().contains(where: \.isRed)
    }

    /// Delete: to the Archive. Nothing for an item that is already there or
    /// in Recently Deleted.
    @discardableResult
    func archiveSelected() -> Bool {
        guard !isAsking, itemActs.joined().contains(.archive) else { return false }
        perform(.archive)
        return true
    }

    /// ⌘Delete: to Recently Deleted, and from there, after the question,
    /// for good.
    @discardableResult
    func deleteSelected() -> Bool {
        guard canDeleteSelected, let act = itemActs.joined().first(where: \.isRed) else { return false }
        perform(act)
        return true
    }

    // MARK: Deleting for good

    func confirmDelete() {
        guard let id = confirming else { return }
        confirming = nil
        write(.deleteForGood, to: id)
    }

    // MARK: Dragging

    func beginDrag(_ id: String) -> NSItemProvider {
        dragged = id
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: Self.dragType.identifier,
                                            visibility: .ownProcess) { done in
            done(Data(id.utf8), nil)
            return nil
        }
        return provider
    }

    /// What dropping the dragged item on a row of the sidebar would do: move
    /// it to a vault it is not in, or archive it. Nil for every other row.
    func change(droppingOn row: SidebarRow) -> ItemChange? {
        guard let item = dragged.flatMap(store.entry(id:))?.item, !item.isInTrash else { return nil }
        switch row {
        case .vault(let place):
            let isThere = !item.isArchived && place == item.folderID.map(Vault.Place.folder) ?? .personal
            guard item.canBeWritten, !isThere, moveTargets.contains(where: { $0.id == place }) else { return nil }
            return .move(place)
        case .archive:
            return item.isArchived ? nil : .archive
        default:
            return nil
        }
    }

    @discardableResult
    func drop(on row: SidebarRow) -> Bool {
        defer {
            dragged = nil
            dropTarget = nil
        }
        guard let id = dragged, let change = change(droppingOn: row) else { return false }
        write(change, to: id)
        return true
    }

    // MARK: Writing

    /// One change, sent. When it has been made, the selection follows it: to
    /// the copy of a duplicate, and to the row that stood beside an item the
    /// change took out of the list. When it was refused, nothing has moved
    /// and `refused` says why, in the engine's sentence. One refused as out
    /// of date is followed by a sync, so that the same change asked again
    /// is made from the newer copy.
    @discardableResult
    func write(_ change: ItemChange, to id: String) -> Task<Void, Never> {
        detailMenu = nil
        refused = nil
        let wasSelected = pinned == nil && selectedItem?.id == id
        let beside = wasSelected ? neighbour(of: id) : nil
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self, store] in
            defer { self?.writes[number] = nil }
            do {
                let after = try await store.apply(change, to: id)
                guard let self, !Task.isCancelled else { return }
                if change == .duplicate, let after {
                    self.select(item: after.id)
                } else if wasSelected, self.selectedItem == nil {
                    self.select(item: beside)
                }
            } catch {
                if case VaultError.refused(let sentence) = error, Editor.isOutOfDate(sentence) {
                    await store.sync()
                }
                guard let self, !Task.isCancelled else { return }
                self.refused = Self.sentence(for: error)
            }
        }
        writes[number] = task
        writing = task
        return task
    }

    /// The row after it in the list, or the one before it at the end.
    private func neighbour(of id: String) -> String? {
        let entries = list.entries
        guard let place = list.place(of: id) else { return nil }
        if place + 1 < entries.count { return entries[place + 1].id }
        return place > 0 ? entries[place - 1].id : nil
    }

    /// Nil for a vault that locked under the change: the lock screen is
    /// already saying so. A refusal is the engine's sentence, but for the
    /// one that is the server's answer handed on whole.
    static func sentence(for error: Error) -> String? {
        switch error {
        case VaultError.refused(let sentence): return Editor.isOutOfDate(sentence) ? Editor.behind : sentence
        case VaultError.timeout: return "The engine took too long to answer."
        case VaultError.transport: return "The engine stopped answering."
        case VaultError.turnedAway(let status): return VaultError.turnedAwaySentence(status)
        default: return nil
        }
    }
}

// MARK: - Drawn

/// Where the two buttons that drop a menu stand in the window.
struct DetailMenuAnchor: PreferenceKey {
    static let defaultValue: [DetailMenu: Anchor<CGRect>] = [:]

    static func reduce(value: inout [DetailMenu: Anchor<CGRect>], nextValue: () -> [DetailMenu: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

/// Everything that is laid over an item's details: a row's menu, the two
/// menus of the strip, what the engine refused, and the question before an
/// item is deleted for good. The main window and a window of one item both
/// wear it.
struct ItemLayers: ViewModifier {
    @ObservedObject var panes: Panes

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(FieldMenuAnchor.self) { chevron in
                FieldMenuLayer(panes: panes, reading: panes.reading, anchor: chevron)
            }
            .overlayPreferenceValue(DetailMenuAnchor.self) { buttons in
                DetailMenuLayer(panes: panes, anchors: buttons)
            }
            .overlay(alignment: .bottomTrailing) {
                if let sentence = panes.refused {
                    RefusalBanner(sentence: sentence) { panes.refused = nil }
                        .padding(Metrics.wide)
                }
            }
            .overlay { PasswordHistoryLayer(panes: panes, reading: panes.reading) }
            .overlay {
                if let item = panes.confirming.flatMap(panes.store.entry(id:))?.item {
                    DeleteQuestion(title: item.name, cancel: { panes.confirming = nil }, delete: panes.confirmDelete)
                }
            }
            .overlay {
                if panes.isAskingToDiscard, let editor = panes.editor {
                    DiscardQuestion(title: editor.original.name, isNew: editor.isNew, keep: { panes.isAskingToDiscard = false },
                                    discard: panes.discardEdit)
                }
            }
    }
}

/// The open menu, hung from its button: the item's with its right edge on
/// the ellipsis's, as its still has it, and the vaults' under the vault's
/// name. A click anywhere else puts it away.
private struct DetailMenuLayer: View {
    @ObservedObject var panes: Panes
    let anchors: [DetailMenu: Anchor<CGRect>]

    var body: some View {
        if let menu = panes.detailMenu {
            GeometryReader { window in
                ZStack(alignment: .topLeading) {
                    Palette.content.opacity(0)
                        .contentShape(Rectangle())
                        .onTapGesture { panes.detailMenu = nil }
                        .accessibilityHidden(true)
                    if let anchor = anchors[menu] {
                        let button = window[anchor]
                        switch menu {
                        case .item:
                            ItemMenuCard(groups: panes.itemActs, choose: panes.perform)
                                .offset(x: max(Metrics.close, button.maxX - Metrics.itemMenuWidth),
                                        y: button.maxY + Metrics.tight)
                        case .move:
                            MoveMenuCard(vaults: panes.moveTargets, current: panes.detail?.vault.id,
                                         choose: panes.move(to:))
                                .offset(x: max(Metrics.close, button.minX - Metrics.wide),
                                        y: button.maxY + Metrics.tight)
                        }
                    }
                }
            }
        }
    }
}

struct MenuGround: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        content
            .padding(.vertical, Metrics.close)
            .frame(width: width)
            .background(shape.fill(Palette.menu))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
    }
}

/// The item's menu: a glyph at the left of every row, a rule between the
/// groups, and Delete in red.
struct ItemMenuCard: View {
    let groups: [[ItemAct]]
    let choose: (ItemAct) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { place, group in
                if place > 0 {
                    Hairline(.horizontal)
                        .padding(.horizontal, Metrics.wide)
                        .padding(.vertical, Metrics.close)
                }
                ForEach(group, id: \.self) { act in
                    DetailMenuRow(name: act.name, colour: act.isRed ? Palette.red : Palette.text) { choose(act) } mark: {
                        act.glyph.image
                            .font(Fonts.sidebarGlyph)
                            .foregroundStyle(act.isRed ? Palette.red : Palette.secondText)
                    }
                }
            }
        }
        .modifier(MenuGround(width: Metrics.itemMenuWidth))
    }
}

/// The vaults an item can be in, each behind its dot, with a tick on the
/// one it is in.
struct MoveMenuCard: View {
    let vaults: [Vault]
    let current: Vault.Place?
    let choose: (Vault.Place) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MOVE TO")
                .font(Fonts.heading)
                .tracking(Metrics.headingTracking)
                .foregroundStyle(Palette.secondText)
                .padding(.horizontal, Metrics.wide)
                .frame(height: Metrics.menuRow)
                .accessibilityAddTraits(.isHeader)
            ForEach(vaults) { vault in
                DetailMenuRow(name: vault.name, isTicked: vault.id == current) { choose(vault.id) } mark: {
                    VaultDot(name: vault.name)
                }
            }
        }
        .modifier(MenuGround(width: Metrics.menuWidth))
    }
}

struct DetailMenuRow<Mark: View>: View {
    let name: String
    var colour = Palette.text
    var isTicked = false
    let choose: () -> Void
    @ViewBuilder let mark: Mark
    @State private var isUnderPointer = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Metrics.gap) {
                mark.frame(width: Metrics.sidebarMark)
                Text(name)
                    .font(Fonts.body)
                    .foregroundStyle(colour)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isTicked {
                    Glyph.tick.image
                        .font(Fonts.action)
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Metrics.close)
            .frame(height: Metrics.itemMenuRow)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(isUnderPointer ? Palette.rowHover : Palette.rowHover.opacity(0))
            )
            .padding(.horizontal, Metrics.close)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isUnderPointer = $0 }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isTicked ? .isSelected : [])
    }
}

/// What the engine said when it would not make a change, at the foot of
/// the details until it is dismissed or the next change is asked for.
struct RefusalBanner: View {
    let sentence: String
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Metrics.close) {
            Glyph.warning.image
                .font(Fonts.sidebarGlyph)
                .foregroundStyle(Palette.red)
                .accessibilityHidden(true)
            Text(sentence)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Not changed")
                .accessibilityValue(sentence)
            Button(action: dismiss) {
                Glyph.close.image
                    .font(Fonts.disclosure)
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.sidebarMark, height: Metrics.sidebarMark)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Metrics.wide)
        .padding(.trailing, Metrics.close)
        .padding(.vertical, Metrics.gap)
        .frame(maxWidth: Metrics.lockSentence, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.red, lineWidth: Metrics.hairline))
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
    }
}

/// The question between Delete Permanently and the item being gone: its
/// name, and what he is cutting short.
struct DeleteQuestion: View {
    let title: String
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
                    Text("Delete “\(title)” permanently?")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text("Left in Recently Deleted, the server would have kept it for \(Panes.trashDays) days from the day it was deleted. Deleted now, it is gone from every device and cannot be brought back.")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.gap) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(ItemAct.deleteForGood.name, action: delete)
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

/// Takes an item dragged out of the list onto a row of the sidebar, when
/// that row has somewhere to put it.
struct ItemDrop: DropDelegate {
    let panes: Panes
    let row: SidebarRow

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [Panes.dragType]) && panes.change(droppingOn: row) != nil
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { panes.dropTarget = row }
    }

    func dropExited(info: DropInfo) {
        if panes.dropTarget == row { panes.dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        panes.drop(on: row)
    }
}

extension Surface {
    private static func item(_ name: String, of title: String, in row: SidebarRow = .allItems,
                             _ arrange: @escaping @MainActor (Panes) -> Void) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(row)
            panes.select(item: panes.list.entries.first { $0.item.name == title }?.id)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The item's menu open under the ellipsis, as its still has it; the
    /// vaults under the vault's name; the two rows an item in Recently
    /// Deleted has, and the question the second of them asks; a change the
    /// engine refused; an item over a vault it can be dropped on; and an
    /// item in a window of its own.
    static let itemMenus: [Surface] = [
        item("item-menu", of: "Spotify") { $0.toggle(.item) },
        item("item-menu-move", of: "İş Bankası") { $0.toggle(.move) },
        item("item-menu-deleted", of: "Kapanan hesap", in: .trash) { $0.toggle(.item) },
        item("item-delete-question", of: "Kapanan hesap", in: .trash) { $0.perform(.deleteForGood) },
        item("item-refused", of: "Spotify") { $0.refused = FakeBackend.offline },
        item("item-drop", of: "Spotify") { panes in
            panes.dragged = panes.selectedItem?.id
            panes.dropTarget = panes.vaults.dropFirst().first.map { .vault($0.id) }
        },
        Surface(name: "item-window", size: Metrics.itemWindow, frame: { ItemWindows.frame() }) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            let item = store.shelves.all.first { $0.item.name == "GitHub" }
            return AnyView(ItemWindowView(panes: panes.pinned(to: item?.id ?? "")))
        },
    ]
}
