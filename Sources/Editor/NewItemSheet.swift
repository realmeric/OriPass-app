import SwiftUI

/// The sheet behind ⌘N (`docs/look.md`, "New Item"): a field across its
/// top and the five kinds under it as tiles, each a mark and a name. What
/// is typed narrows them, the arrows move the lit one, Return takes it, and
/// Esc or a click beside the sheet puts it away.
struct NewItemSheet: View {
    @Binding var choice: NewItemChoice
    var choose: (ItemType) -> Void = { _ in }
    var close: () -> Void = {}
    @FocusState private var fieldHasKeys: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack(alignment: .top) {
            Palette.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field
                Hairline(.horizontal)
                tiles
            }
            .frame(width: Metrics.newItemWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .clipShape(shape)
            .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
            // A third of the way down, where Quick Access stands.
            .padding(.top, Metrics.toolbarHeight + Metrics.apart + Metrics.apart)
            .padding(.horizontal, Metrics.loose)
        }
        .ignoresSafeArea()
        .onAppear { fieldHasKeys = true }
    }

    private var field: some View {
        HStack(spacing: Metrics.gap) {
            Glyph.search.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
                .accessibilityHidden(true)
            TextField("", text: $choice.query,
                      prompt: Text("What kind of item?").foregroundStyle(Palette.prompt))
                .textFieldStyle(.plain)
                .font(Fonts.newItemField)
                .foregroundStyle(Palette.text)
                .focused($fieldHasKeys)
                .onExitCommand(perform: close)
                .onSubmit {
                    if let lit = choice.lit { choose(lit) }
                }
                .onKeyPress(.leftArrow) {
                    // In the middle of a word the arrow is the caret's.
                    guard choice.query.isEmpty else { return .ignored }
                    choice.move(by: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard choice.query.isEmpty else { return .ignored }
                    choice.move(by: 1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    choice.move(by: choice.lit == choice.kinds.last ? -choice.kinds.count : 1)
                    return .handled
                }
                .accessibilityLabel("Kind of item")
        }
        .padding(.horizontal, Metrics.wide)
        .frame(height: Metrics.newItemField)
    }

    @ViewBuilder
    private var tiles: some View {
        let kinds = choice.kinds
        if kinds.isEmpty {
            Text("No kind of item is called “\(choice.query.trimmingCharacters(in: .whitespaces))”")
                .font(Fonts.sentence)
                .foregroundStyle(Palette.prompt)
                .lineLimit(1)
                .padding(.horizontal, Metrics.wide)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.newItemTile + Metrics.gap + Metrics.gap)
        } else {
            HStack(spacing: Metrics.tight) {
                // Five wide whatever is left, so a tile stays the size it was.
                ForEach(NewItemChoice.kinds.indices, id: \.self) { place in
                    if kinds.indices.contains(place) {
                        tile(kinds[place])
                    } else {
                        Palette.content.opacity(0).frame(maxWidth: .infinity).frame(height: Metrics.newItemTile)
                    }
                }
            }
            .padding(Metrics.gap)
        }
    }

    private func tile(_ type: ItemType) -> some View {
        let isLit = choice.lit == type
        return Button { choose(type) } label: {
            VStack(spacing: Metrics.gap) {
                CategoryTile(type: type, side: Metrics.newItemMark)
                Text(type.kind)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.newItemTile)
            .background(
                RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
                    .fill(isLit ? Palette.listSelection : Palette.listSelection.opacity(0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(type.kind)
        .accessibilityValue(isLit ? "selected" : "")
    }
}

/// The sheet over the panes while ⌘N has it up.
struct NewItemLayer: View {
    @ObservedObject var panes: Panes

    var body: some View {
        if panes.choosing != nil {
            NewItemSheet(choice: Binding(get: { panes.choosing ?? NewItemChoice() },
                                         set: { if panes.choosing != nil { panes.choosing = $0 } }),
                         choose: { panes.make($0) }, close: { panes.choosing = nil })
                .transition(Motion.transition(.fade))
        }
    }
}

extension Surface {
    private static func new(_ name: String, height: CGFloat = Metrics.windowSize.height,
                            _ arrange: @escaping @MainActor (Panes) throws -> Void) -> Surface {
        Surface(name: name, size: CGSize(width: Metrics.windowSize.width, height: height)) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(item: store.shelves.all.first { $0.item.name == "GitHub" }?.id)
            try arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// A form is drawn in the same turn it is asked for, and the engine
    /// answers in a later one, so a shot's blank item is made from the
    /// fake's templates without asking it, and a key's from this app's
    /// own three keys, as the store makes it.
    private static func blank(_ type: ItemType, in folder: String? = nil) throws -> Item {
        let templates = FakeBackend.templates
        let part = type.templateName.flatMap { templates[$0] } ?? (type == .sshKey ? Item.keyPart : .null)
        return try Item.blank(type, from: templates["item"] ?? .null, part: part, in: folder)
    }

    /// The sheet as ⌘N raises it, with a letter typed that leaves two of
    /// the five, and with a word that leaves none. A login's empty form. One with a title and a password
    /// typed, in the vault the sidebar had selected. A key's, which waits
    /// for its key.
    static let newItems: [Surface] = [
        new("new-item-sheet") { $0.beginNew() },
        new("new-item-sheet-typed") { panes in
            panes.beginNew()
            panes.choosing?.query = "c"
        },
        new("new-item-sheet-none") { panes in
            panes.beginNew()
            panes.choosing?.query = "passport"
        },
        new("new-item-login") { try $0.open(new: blank(.login)) },
        new("new-item-login-typed") { panes in
            panes.selectVault(at: 1)
            guard case .folder(let folder) = panes.newItemPlace else { return }
            try panes.open(new: blank(.login, in: folder))
            panes.editor?.form.title = "Kanarya Kitabevi"
            panes.editor?.form.username = "deniz@\(DemoVault.usernameDomain)"
            panes.editor?.form.password = DemoVault.made
            panes.editor?.addAddress()
        },
        new("new-item-key") { try $0.open(new: blank(.sshKey)) },
    ]
}
