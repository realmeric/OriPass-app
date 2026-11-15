import SwiftUI

/// The sidebar (`docs/look.md`, "The sidebar"): the account and its menu
/// under the traffic lights, then All Items, Favorites and Password Health, the
/// vaults under their heading, and Archive and Recently Deleted, over a foot
/// that says how old the list is. What is selected and what is folded are
/// the panes', because ⇧⌘D takes this view out of the window and brings back
/// a new one.
struct SidebarView: View {
    @ObservedObject var panes: Panes
    @ObservedObject private var store: VaultStore
    /// What the foot says when it is not the store's to say: a shot of a
    /// standing its store was never in.
    private let standing: SyncStanding?

    init(panes: Panes, standing: SyncStanding? = nil) {
        self.panes = panes
        self.standing = standing
        store = panes.store
    }

    var body: some View {
        VStack(spacing: 0) {
            account
                .padding(.top, Metrics.toolbarHeight)
            Hairline(.horizontal)
            ScrollView {
                VStack(spacing: Metrics.wide) {
                    group(panes.upperRows)
                    vaults
                    group(panes.lowerRows)
                }
                .padding(.horizontal, Metrics.close)
                .padding(.vertical, Metrics.gap)
            }
            Hairline(.horizontal)
            SyncFoot(standing: standing ?? store.standing)
        }
        .background(SidebarGround())
    }

    // MARK: The account

    private var account: some View {
        Menu {
            accountRows(isRuled: true)
        } label: {
            HStack(spacing: Metrics.close) {
                LetterTile(title: store.email ?? "", side: Metrics.sidebarAvatar)
                Text(store.email ?? "")
                    .font(Fonts.rowTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                // Over the plus beside VAULTS, as the still has the two.
                Glyph.chevronDown.image
                    .font(Fonts.disclosure)
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.sidebarMark)
            }
            .padding(.leading, Metrics.wide)
            .padding(.trailing, Metrics.close + Metrics.gap)
            .frame(height: Metrics.sidebarHeader)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // A label that is drawn is read a part at a time, each part a menu
        // button with no name. This is the same menu under a title, and
        // without its rule, which is read as a thing with no name too.
        .accessibilityRepresentation {
            Menu("Account, \(store.email ?? "")") { accountRows(isRuled: false) }
        }
    }

    @ViewBuilder
    private func accountRows(isRuled: Bool) -> some View {
        Button("Settings…") { panes.showSettings?() }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(panes.showSettings == nil)
        Button("Sync Now") { panes.syncNow() }
        if isRuled { Divider() }
        Button("Lock") { panes.lock() }
    }

    // MARK: The rows

    private func group(_ rows: [SidebarRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                SidebarRowView(label: Self.label(for: row), isSelected: panes.selection == row,
                               takesDrop: panes.dropTarget == row, hasKeys: hasKeys(row),
                               select: { panes.click(row) }) {
                    Self.mark(for: row)
                }
                .onDrop(of: [Panes.dragType], delegate: ItemDrop(panes: panes, row: row))
            }
        }
    }

    private var vaults: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.close) {
                Button(action: panes.toggleVaults) {
                    HStack(spacing: Metrics.close) {
                        (panes.vaultsFolded ? Glyph.chevronRight : Glyph.chevronDown).image
                            .font(Fonts.disclosure)
                            .frame(width: Metrics.sidebarMark)
                        Text("VAULTS")
                            .font(Fonts.heading)
                            .tracking(Metrics.headingTracking)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Metrics.sidebarRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vaults")
                .accessibilityValue(panes.vaultsFolded ? "collapsed" : "expanded")
                Button { panes.beginNewVault() } label: {
                    Glyph.add.image
                        .font(Fonts.disclosure)
                        .frame(width: Metrics.sidebarMark, height: Metrics.sidebarRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Vault")
            }
            .foregroundStyle(Palette.secondText)
            .padding(.horizontal, Metrics.gap)

            if !panes.vaultsFolded {
                ForEach(panes.vaults) { vault in
                    let row = SidebarRow.vault(vault.id)
                    SidebarRowView(label: vault.name, isSelected: panes.selection == row,
                                   takesDrop: panes.dropTarget == row, hasKeys: hasKeys(row),
                                   select: { panes.click(row) }) {
                        VaultDot(name: vault.name)
                    }
                    .onDrop(of: [Panes.dragType], delegate: ItemDrop(panes: panes, row: row))
                    .modifier(VaultMenu(panes: panes, vault: vault))
                }
            }
        }
        .animation(Motion.travel(Motion.slide), value: panes.vaultsFolded)
    }

    /// The selected row, while the arrows are the sidebar's.
    private func hasKeys(_ row: SidebarRow) -> Bool {
        panes.showsFocus && panes.focus == .sidebar && panes.selection == row
    }

    static func label(for row: SidebarRow) -> String {
        switch row {
        case .allItems: return "All Items"
        case .favorites: return "Favorites"
        case .passwordHealth: return "Password Health"
        case .vault: return ""
        case .archive: return "Archive"
        case .trash: return "Recently Deleted"
        }
    }

    @ViewBuilder
    private static func mark(for row: SidebarRow) -> some View {
        switch row {
        case .favorites:
            Glyph.star.image.foregroundStyle(Palette.star)
        case .allItems:
            Glyph.allItems.image.foregroundStyle(Palette.accent)
        case .passwordHealth:
            Glyph.passwordHealth.image.foregroundStyle(Palette.secondText)
        case .archive:
            Glyph.archive.image.foregroundStyle(Palette.secondText)
        case .trash:
            Glyph.trash.image.foregroundStyle(Palette.secondText)
        case .vault:
            EmptyView()
        }
    }
}

/// A folder's row drops Rename and Delete under a right click. Personal and
/// a collection have no menu, and are not given an empty one.
private struct VaultMenu: ViewModifier {
    let panes: Panes
    let vault: Vault

    @ViewBuilder
    func body(content: Content) -> some View {
        let acts = panes.acts(for: vault)
        if acts.isEmpty {
            content
        } else {
            content
                .contextMenu {
                    ForEach(acts, id: \.self) { act in
                        Button(act.name) { panes.perform(act, on: vault) }
                    }
                }
                .accessibilityAction(named: "Rename") { panes.perform(.rename, on: vault) }
                .accessibilityAction(named: "Delete") { panes.perform(.delete, on: vault) }
        }
    }
}

/// The foot (`docs/look.md`, "The sidebar"): one grey line that says when the
/// server last answered, or that it did not. A row's shape, a mark and then
/// the words under the labels above it, and smaller and fainter than a row,
/// since nothing happens when it is clicked. The age is the one worked out
/// when this was last drawn (`VaultStore.standing`); no clock redraws it.
struct SyncFoot: View {
    let standing: SyncStanding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.close) {
            (standing.isOffline ? Glyph.offline : Glyph.sync).image
                .font(Fonts.footGlyph)
                .foregroundStyle(Palette.faintText)
                .frame(width: Metrics.sidebarMark)
            Text(standing.sentence)
                .font(Fonts.rowSecond)
                .foregroundStyle(Palette.secondText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.close + Metrics.gap)
        .padding(.vertical, Metrics.gap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(standing.sentence)
    }
}

/// A small mark and a label, on a rounded rectangle nearly as wide as the
/// sidebar when it is the selected one, and inside a ring of the accent
/// while an item is held over it that it would take, or while the arrows
/// are moving it.
private struct SidebarRowView<Mark: View>: View {
    let label: String
    let isSelected: Bool
    var takesDrop = false
    var hasKeys = false
    let select: () -> Void
    @ViewBuilder let mark: Mark

    var body: some View {
        Button(action: select) {
            HStack(spacing: Metrics.close) {
                mark
                    .font(Fonts.sidebarGlyph)
                    .frame(width: Metrics.sidebarMark)
                Text(label)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gap)
            .frame(height: Metrics.sidebarRow)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(isSelected ? Palette.sidebarSelection : Palette.sidebarSelection.opacity(0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .strokeBorder(takesDrop || hasKeys ? Palette.accent : Palette.accent.opacity(0),
                                  lineWidth: Metrics.dropRing)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension Surface {
    private static func sidebar(_ name: String, standing: SyncStanding? = nil,
                                _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store)
            arrange(panes)
            return AnyView(PanesView(panes: panes, standing: standing))
        }
    }

    /// A vault selected, the section folded shut over it, and the last row.
    static let sidebars: [Surface] = [
        sidebar("sidebar-vault") { $0.selectVault(at: 2) },
        sidebar("sidebar-folded") { panes in
            panes.selectVault(at: 2)
            panes.toggleVaults()
        },
        sidebar("sidebar-deleted") { $0.select(.trash) },
    ]

    /// The foot in each thing it says. The demo's store was synced as the
    /// shots began and never failed, so the other standings are handed in.
    static let syncFeet: [Surface] = [
        sidebar("sidebar-synced", standing: .synced(2 * 60)),
        sidebar("sidebar-syncing", standing: .syncing),
        sidebar("sidebar-offline", standing: .offline),
    ]
}
