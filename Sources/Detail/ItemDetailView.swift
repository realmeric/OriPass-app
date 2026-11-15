import SwiftUI

/// The third column with an item in it (`docs/look.md`, "Item details"): a
/// strip that says where the item lives, the icon and the title, the main
/// fields inside one rounded outline, and under it the addresses, the custom
/// fields, the notes and the date, each standing free.
///
/// Nothing here can be selected as text. Copying is the row's job: a click
/// anywhere on it (`docs/look.md`, "A field under the pointer").
struct ItemDetailView: View {
    @ObservedObject var panes: Panes
    @ObservedObject private var reading: Reading
    let detail: ItemDetail
    /// The password's level, handed in and not read from the store, so the
    /// row is drawn again when it arrives.
    var strength: Strength?
    /// What Password Health says of the item, handed in for the same reason.
    var banners: [Banner]

    init(panes: Panes, detail: ItemDetail, strength: Strength? = nil, banners: [Banner] = []) {
        self.panes = panes
        reading = panes.reading
        self.detail = detail
        self.strength = strength
        self.banners = banners
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailBar(vault: detail.vault, editHelp: detail.editHelp, canMove: panes.canMove,
                      open: panes.detailMenu, toggle: panes.toggle,
                      edit: panes.canEdit ? { panes.beginEdit() } : nil)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.loose) {
                        header
                        if let notice = detail.notice { NoticeBanner(words: notice) }
                        if !banners.isEmpty {
                            VStack(spacing: Metrics.close) {
                                ForEach(banners) { BannerView(banner: $0, perform: panes.perform(banner:)) }
                            }
                        }
                        if !detail.main.isEmpty {
                            Outlined {
                                ForEach(Array(detail.main.enumerated()), id: \.element.id) { place, row in
                                    if place > 0 { Hairline(.horizontal) }
                                    FieldRow(row: row, strength: row.id == ItemDetail.passwordRow ? strength : nil,
                                             isRevealed: reading.shows(row.id), isHeldBack: panes.isHeldBack,
                                             state: state(of: row.id), acts: acts(for: row.id))
                                        .id(row.id)
                                }
                            }
                        }
                        if !detail.websites.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(detail.websites) {
                                    WebsiteRow(website: $0, state: state(of: $0.row), acts: acts(for: $0.row))
                                        .id($0.row)
                                }
                            }
                        }
                        if !detail.fields.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(detail.fields) {
                                    FieldRow(row: $0, isRevealed: reading.shows($0.id), state: state(of: $0.id),
                                             acts: acts(for: $0.id), isFree: true)
                                        .id($0.id)
                                }
                            }
                        }
                        if !detail.attachments.isEmpty || reading.adding != nil {
                            AttachmentRows(panes: panes, reading: reading, files: detail.attachments)
                        }
                        if let note = detail.note {
                            Outlined { NoteView(note: note) }
                                .overlay { KeyRing(isOn: hasKeys(ItemDetail.notesRow)) }
                                .overlay(alignment: .topTrailing) { copyNote }
                                .id(ItemDetail.notesRow)
                                .onHover { hover(ItemDetail.notesRow, $0) }
                        }
                        DatesRow(edited: detail.edited, created: detail.created, isOpen: panes.showsCreated,
                                 toggle: panes.toggleCreated)
                    }
                    .padding(.horizontal, Metrics.wide)
                    .padding(.top, Metrics.wide)
                    .padding(.bottom, Metrics.apart)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The arrows bring the field they reach into view.
                .onChange(of: reading.cursor) { _, row in
                    if let row { scroll.scrollTo(row) }
                }
            }
        }
        // A link in a note and a website's host both come through here.
        .environment(\.openURL, OpenURLAction { link in
            panes.follow(link)
            return .handled
        })
    }

    /// How a row stands: under the pointer, with its menu open, just copied.
    private func state(of row: String) -> RowState {
        RowState(copies: detail.value(of: row) != nil, hasMenu: !panes.actions(for: row).isEmpty,
                 isUnderPointer: reading.hovered == row, isMenuOpen: reading.menu?.row == row,
                 isCopied: reading.copied == row, hasKeys: hasKeys(row))
    }

    /// The row the arrows are on, while they are the details'.
    private func hasKeys(_ row: String) -> Bool {
        panes.showsFocus && panes.focus == .details && reading.cursor == row
    }

    private func acts(for row: String) -> RowActs {
        RowActs(hover: { hover(row, $0) }, copy: { panes.copy(row) }, menu: { panes.toggleMenu(for: row) })
    }

    /// The pointer leaving one row after it has entered the next must not
    /// take the next one's fill away.
    private func hover(_ row: String, _ isOver: Bool) {
        if isOver {
            reading.hovered = row
        } else if reading.hovered == row {
            reading.hovered = nil
        }
    }

    /// A note is too full of links for a click anywhere on it to copy, so
    /// the word is a button and the only part that does.
    @ViewBuilder
    private var copyNote: some View {
        let isCopied = reading.copied == ItemDetail.notesRow
        if isCopied || reading.hovered == ItemDetail.notesRow || hasKeys(ItemDetail.notesRow) {
            Button { panes.copy(ItemDetail.notesRow) } label: {
                Text(isCopied ? "Copied" : "Copy")
                    .font(Fonts.action)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, Metrics.gap)
                    .frame(height: Metrics.buttonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Palette.rowHover)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(Metrics.close)
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.wide) {
            ItemIcon(item: detail.item, icons: panes.icons, side: Metrics.detailIcon)
                .overlay(alignment: .bottomTrailing) {
                    if detail.isFavourite { star }
                }
            Text(detail.title)
                .font(Fonts.title)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Metrics.wide)
        .padding(.vertical, Metrics.close)
    }

    private var star: some View {
        ZStack {
            Glyph.star.image.font(Fonts.detailStarEdge).foregroundStyle(Palette.content)
            Glyph.star.image.font(Fonts.detailStar).foregroundStyle(Palette.star)
        }
        .offset(x: Metrics.starOverhang, y: Metrics.starOverhang)
        .accessibilityLabel("Favourite")
    }
}

/// Over the details: the vault the item is in, which is the menu that moves
/// it, and at the right Edit and the ellipsis, which drops the item's menu
/// (`ItemMenu`). Edit turns the details into a form (`Editor`), for an item
/// that has one.
private struct DetailBar: View {
    let vault: Vault
    /// Why Edit will never work on this item, shown when it is held under
    /// the pointer.
    var editHelp: String?
    /// False for an item that has no other vault to go to: one this app
    /// cannot write, one in Recently Deleted.
    var canMove = false
    var open: DetailMenu?
    var toggle: (DetailMenu) -> Void = { _ in }
    /// Nil for an item with no form.
    var edit: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.wide) {
            Button { toggle(.move) } label: {
                HStack(spacing: Metrics.close) {
                    VaultDot(name: vault.name)
                    Text(vault.name).lineLimit(1)
                    if canMove {
                        Glyph.chevronDown.image
                            .font(Fonts.disclosure)
                            .foregroundStyle(Palette.secondText)
                    }
                }
                .padding(.horizontal, Metrics.close)
                .frame(minHeight: Metrics.buttonHeight)
                .background(lit(open == .move))
            }
            .disabled(!canMove)
            .accessibilityLabel("Vault")
            .accessibilityValue(vault.name)
            .anchorPreference(key: DetailMenuAnchor.self, value: .bounds) { open == .move ? [.move: $0] : [:] }
            .padding(.leading, -Metrics.close)
            Spacer(minLength: 0)
            Button { edit?() } label: {
                HStack(spacing: Metrics.tight) {
                    Glyph.edit.image.font(Fonts.toolbarGlyph)
                    Text("Edit")
                }
            }
            .help(editHelp ?? "")
            .disabled(edit == nil)
            Button { toggle(.item) } label: {
                Glyph.more.image
                    .font(Fonts.toolbarGlyph)
                    .rotationEffect(.degrees(90))
                    .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                    .background(lit(open == .item))
            }
            .accessibilityLabel("More")
            .accessibilityValue(open == .item ? "open" : "shut")
            .anchorPreference(key: DetailMenuAnchor.self, value: .bounds) { open == .item ? [.item: $0] : [:] }
        }
        .buttonStyle(BarButtonStyle())
        .padding(.leading, Metrics.wide + Metrics.wide)
        .padding(.trailing, Metrics.gap)
        .frame(height: Metrics.listHeader)
    }

    /// The ground a button of the strip stands on while its menu is open,
    /// as the still has the ellipsis.
    private func lit(_ isOpen: Bool) -> some View {
        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
            .fill(isOpen ? Palette.listSelection : Palette.listSelection.opacity(0))
    }
}

/// One rounded outline around whatever it is given.
struct Outlined<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A row's fill under the pointer stops at the outline's corners.
            .clipShape(shape)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
                    .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
            )
    }
}

/// The accent around the field the arrows are on, with the outline's own
/// corners so that it sits inside the first and the last row of a group.
struct KeyRing: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
            .strokeBorder(isOn ? Palette.accent : Palette.accent.opacity(0), lineWidth: Metrics.dropRing)
            .allowsHitTesting(false)
    }
}

/// How a row stands, as plain values, so a shot can draw any of it.
struct RowState {
    /// False for a tick and for a pointer at another field: no fill, no
    /// word and nothing to click. True for an attachment, whose click opens
    /// it.
    var copies = false
    var hasMenu = false
    var isUnderPointer = false
    var isMenuOpen = false
    var isCopied = false
    /// The arrows are on it, and Return copies it.
    var hasKeys = false

    /// Filled, with "Copy" at its right. A row whose menu is open stays so
    /// though the pointer has gone down into the menu.
    var isLit: Bool { copies && (isUnderPointer || isMenuOpen || hasKeys) }
}

struct RowActs {
    var hover: (Bool) -> Void = { _ in }
    var copy: () -> Void = {}
    var menu: () -> Void = {}
}

/// What every row that can be copied has around it (`docs/look.md`, "A
/// field under the pointer"): under the pointer it fills with a pale grey,
/// says "Copy" in bold at its right and grows a square with a chevron at its
/// far right, which opens the row's menu. A click anywhere else on it
/// copies. What a row shows at its right the rest of the time, a password's
/// strength, gives way to the word. An attachment's row wears the same and
/// says "Open", since a click on it copies nothing.
struct RowChrome<Content: View, Resting: View>: View {
    let state: RowState
    let acts: RowActs
    var isFree = false
    var word = "Copy"
    @ViewBuilder let content: Content
    @ViewBuilder let resting: Resting

    private var showsButton: Bool { state.isLit && state.hasMenu }

    var body: some View {
        HStack(spacing: Metrics.close) {
            content.frame(maxWidth: .infinity, alignment: .leading)
            if state.isCopied || state.isLit {
                Text(state.isCopied ? "Copied" : word)
                    .font(Fonts.action)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .accessibilityHidden(!state.isCopied)
            } else {
                resting
            }
        }
        .padding(.leading, Metrics.wide)
        .padding(.trailing, showsButton ? Metrics.fieldButton + Metrics.wide : Metrics.wide)
        .padding(.vertical, Metrics.close)
        .frame(maxWidth: .infinity, minHeight: Metrics.fieldRow, alignment: .leading)
        .background(state.isLit ? Palette.rowHover : Palette.rowHover.opacity(0))
        .overlay(alignment: .trailing) {
            if showsButton { menuButton }
        }
        .clipShape(RoundedRectangle(cornerRadius: isFree ? Metrics.groupRadius : 0, style: .continuous))
        .overlay { KeyRing(isOn: state.hasKeys) }
        .contentShape(Rectangle())
        .onTapGesture {
            if state.copies { acts.copy() }
        }
        .onHover(perform: acts.hover)
    }

    private var menuButton: some View {
        Button(action: acts.menu) {
            Glyph.chevronDown.image
                .font(Fonts.disclosure)
                .foregroundStyle(Palette.text)
                .frame(width: Metrics.fieldButton)
                .frame(maxHeight: .infinity)
                .background(Palette.rowButton)
                .overlay(alignment: .leading) { Hairline(.vertical) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
        .accessibilityValue(state.isMenuOpen ? "open" : "shut")
        .anchorPreference(key: FieldMenuAnchor.self, value: .bounds) { state.isMenuOpen ? $0 : nil }
    }
}

/// What a row does when VoiceOver presses it, and the name that has in its
/// menu of actions: the click, for somebody with no pointer. A row that a
/// click does nothing to has neither.
struct Pressed: ViewModifier {
    let isOn: Bool
    let name: String
    let act: () -> Void

    func body(content: Content) -> some View {
        if isOn {
            content
                .accessibilityAction(named: name, act)
                .accessibilityAction(.default, act)
        } else {
            content
        }
    }
}

/// A small label in the violet blue over its value. A one-time code is its
/// digits and the time they have left (`CodeRow`). A hidden value is ten
/// dots to the eye and the word "concealed" to VoiceOver, and the value
/// itself is in neither until the row is revealed. Then it is spelled out
/// in the fixed-width face, digits and symbols coloured apart from letters.
/// A password's row ends in how strong it is: the word in grey and a ring
/// filled as far as the level goes.
private struct FieldRow: View {
    let row: ItemDetail.Row
    var strength: Strength?
    var isRevealed = false
    /// The item asks, and has not been answered for: its code is dots
    /// until it has, as its password is until it is revealed.
    var isHeldBack = false
    var state = RowState()
    var acts = RowActs()
    var isFree = false

    var body: some View {
        RowChrome(state: state, acts: acts, isFree: isFree) {
            if case .code(let totp?) = row.value, !isHeldBack {
                // The digits are said by what draws them, which is drawn
                // again as they change.
                VStack(alignment: .leading, spacing: Metrics.hair) {
                    FieldLabel(row.label).accessibilityHidden(true)
                    CodeRow(totp: totp, label: row.label, isLit: state.isLit)
                        .modifier(Pressed(isOn: state.copies, name: "Copy", act: acts.copy))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Metrics.hair) {
                    FieldLabel(row.label)
                    value
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.said(revealed: isRevealed))
                .accessibilityAddTraits(.isStaticText)
                .modifier(Pressed(isOn: state.copies, name: "Copy", act: acts.copy))
            }
        } resting: {
            if let strength {
                HStack(spacing: Metrics.close) {
                    Text(strength.word)
                        .font(Fonts.rowSecond)
                        .foregroundStyle(Palette.secondText)
                        .lineLimit(1)
                    StrengthRing(strength: strength)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("strength")
                .accessibilityValue(strength.word)
                .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        switch row.value {
        case .text(let text):
            Text(text)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        case .hidden(let value) where isRevealed:
            SpelledValue(value: value)
        case .masked(let whole, _) where isRevealed:
            SpelledValue(value: whole)
        case .hidden:
            Text(ItemDetail.dots)
                .font(Fonts.dots)
                .tracking(Metrics.dotTracking)
                .foregroundStyle(Palette.text)
        case .masked(_, let last):
            HStack(spacing: Metrics.close) {
                Text(ItemDetail.numberDots)
                    .font(Fonts.dots)
                    .tracking(Metrics.dotTracking)
                Text(last).font(Fonts.body)
            }
            .foregroundStyle(Palette.text)
        case .tick(let isOn):
            (isOn ? Glyph.tick : Glyph.unticked).image
                .font(Fonts.action)
                .foregroundStyle(isOn ? Palette.accent : Palette.faintText)
        case .pointer(let name):
            HStack(spacing: Metrics.tight) {
                Glyph.link.image
                    .font(Fonts.disclosure)
                    .foregroundStyle(Palette.secondText)
                Text(name)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
            }
        case .code(.some):
            // Held back. One that may be read is drawn by `CodeRow`.
            Text(ItemDetail.dots)
                .font(Fonts.dots)
                .tracking(Metrics.dotTracking)
                .foregroundStyle(Palette.text)
        case .code(.none):
            InvalidCode()
        }
    }
}

/// A revealed value a character at a time, each in its kind's colour, as
/// Large Type has it: the details' rows and the password history's.
struct SpelledValue: View {
    let value: String

    var body: some View {
        Text(spelled)
            .font(Fonts.code)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var spelled: AttributedString {
        var spelled = AttributedString()
        for character in value {
            var one = AttributedString(String(character))
            one.foregroundColor = LargeTypeView.colour(of: LargeType.Kind(character))
            spelled += one
        }
        return spelled
    }
}

/// The line over a type this app can read and not change.
struct NoticeBanner: View {
    let words: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.close) {
            Glyph.info.image
                .font(Fonts.disclosure)
                .foregroundStyle(Palette.secondText)
                .accessibilityHidden(true)
            Text(words)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous).fill(Palette.field))
        .accessibilityElement(children: .combine)
    }
}

/// A level as a ring: a faint whole circle, and over it an arc in the
/// level's colour that starts at the top and goes a fifth of the way round
/// for each level.
struct StrengthRing: View {
    let strength: Strength

    var body: some View {
        ZStack {
            Circle().stroke(Palette.outline, lineWidth: Metrics.ringLine)
            Circle()
                .trim(from: 0, to: strength.share)
                .stroke(Palette.strength[strength.rawValue],
                        style: StrokeStyle(lineWidth: Metrics.ringLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(Metrics.ringLine / 2)
        .frame(width: Metrics.ring, height: Metrics.ring)
        .accessibilityHidden(true)
    }
}

struct FieldLabel: View {
    let word: String

    init(_ word: String) {
        self.word = word
    }

    var body: some View {
        Text(word)
            .font(Fonts.label)
            .foregroundStyle(Palette.label)
            .lineLimit(1)
    }
}

/// "website" over the address, with the host in link blue and the rest in
/// the text's own colour. The host is the link, and the only part of the
/// row that opens anything. A click on the rest of the row copies the
/// address.
private struct WebsiteRow: View {
    let website: ItemDetail.Website
    var state = RowState()
    var acts = RowActs()

    var body: some View {
        RowChrome(state: state, acts: acts, isFree: true) {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                FieldLabel("website")
                Text(address)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } resting: {
            EmptyView()
        }
    }

    private var address: AttributedString {
        var host = AttributedString(website.host)
        host.link = website.link
        host.foregroundColor = Palette.accent
        return AttributedString(website.scheme) + host + AttributedString(website.rest)
    }
}

/// The notes, a block under a block, inside their own outline.
private struct NoteView: View {
    let note: NoteText

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ForEach(note.blocks) { block in
                self.block(block)
            }
        }
        .padding(Metrics.wide)
        .tint(Palette.accent)
    }

    @ViewBuilder
    private func block(_ block: NoteText.Block) -> some View {
        switch block.kind {
        case .paragraph:
            words(block, Fonts.body)
        case .heading(let level):
            words(block, Fonts.noteHeading(level)).accessibilityAddTraits(.isHeader)
        case .bullet(let depth):
            listed("•", block, depth: depth)
        case .numbered(let number, let depth):
            listed("\(number).", block, depth: depth)
        case .continued(let depth):
            words(block, Fonts.body).padding(.leading, Metrics.noteIndent * CGFloat(depth))
        case .quote:
            words(block, Fonts.body, Palette.secondText)
                .padding(.leading, Metrics.gap)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.faintText).frame(width: Metrics.quoteBar)
                }
        case .code:
            words(block, Fonts.code)
                .padding(Metrics.close)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Palette.field)
                )
        }
    }

    private func words(_ block: NoteText.Block, _ font: Font, _ colour: Color = Palette.text) -> some View {
        var text = block.text
        for run in text.runs where run.link != nil {
            text[run.range].foregroundColor = Palette.accent
        }
        return Text(text)
            .font(font)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The mark in a column of its own, so a row that wraps comes back
    /// under its first word and not under its mark.
    private func listed(_ mark: String, _ block: NoteText.Block, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.tight) {
            Text(mark)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .frame(width: Metrics.noteIndent, alignment: .trailing)
                .accessibilityHidden(true)
            words(block, Fonts.body)
        }
        .padding(.leading, Metrics.noteIndent * CGFloat(depth - 1))
    }
}

/// "Last edited" and the date written out, behind a chevron that opens onto
/// the date the item was made.
private struct DatesRow: View {
    let edited: Date?
    let created: Date?
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.close) {
            if let edited {
                Button(action: toggle) {
                    HStack(spacing: Metrics.close) {
                        (isOpen ? Glyph.chevronDown : Glyph.chevronRight).image
                            .font(Fonts.disclosure)
                            .foregroundStyle(Palette.secondText)
                            .frame(width: Metrics.gap)
                        line("Last edited \(ItemDetail.written(edited))")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(created == nil)
                .accessibilityValue(isOpen ? "open" : "shut")
            }
            if let created, isOpen || edited == nil {
                line("Created \(ItemDetail.written(created))")
                    .padding(.leading, edited == nil ? 0 : Metrics.gap + Metrics.close)
            }
        }
        .padding(.horizontal, Metrics.wide)
    }

    private func line(_ words: String) -> some View {
        Text(words)
            .font(Fonts.body)
            .foregroundStyle(Palette.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Surface {
    private static func detail(_ name: String, of title: String, height: CGFloat = Metrics.windowSize.height,
                               icons: Bool = false,
                               _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: CGSize(width: Metrics.windowSize.width, height: height)) { store in
            let panes = Panes(store: store, icons: icons ? DemoIcons.seeded() : .off)
            panes.select(item: store.shelves.all.first { $0.item.name == title }?.id)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// A login with everything a login can have, in a window tall enough to
    /// show all of it; one with a passkey and a note in Markdown; one that
    /// is no more than a username, a password and an address, with its
    /// site's icon and "Last edited" opened; and one with neither a
    /// username nor an address.
    /// The same row twice, over a name and over an address, since every
    /// username in the demo vault is an address and its details all say
    /// email. The word is `Login.word`'s, as it is in a real row.
    static let usernameWords: [Surface] = [
        Surface(name: "username-words",
                size: CGSize(width: Metrics.windowSize.width - Metrics.sidebarWidth - Metrics.listWidth,
                             height: Metrics.fieldRow + Metrics.fieldRow
                                 + Metrics.toolbarHeight + Metrics.toolbarHeight)) { _ in
            AnyView(
                Outlined {
                    ForEach(["deniz", "deniz@\(DemoVault.usernameDomain)"], id: \.self) { username in
                        if username != "deniz" { Hairline(.horizontal) }
                        FieldRow(row: ItemDetail.Row(id: "username", label: Login.word(forUsername: username),
                                                     value: .text(username)))
                    }
                }
                .padding(Metrics.wide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.content)
            )
        },
    ]

    /// The five levels under one another, as five password rows, since the
    /// demo vault has no password at each of them.
    static let strengths: [Surface] = [
        Surface(name: "strength-levels",
                size: CGSize(width: Metrics.windowSize.width - Metrics.sidebarWidth - Metrics.listWidth,
                             height: Metrics.fieldRow * CGFloat(Strength.allCases.count)
                                 + Metrics.toolbarHeight + Metrics.toolbarHeight)) { _ in
            AnyView(
                Outlined {
                    ForEach(Strength.allCases, id: \.self) { level in
                        if level != .guessable { Hairline(.horizontal) }
                        FieldRow(row: ItemDetail.Row(id: ItemDetail.passwordRow, label: "password", value: .hidden("")),
                                 strength: level)
                    }
                }
                .padding(Metrics.wide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.content)
            )
        },
    ]

    static let details: [Surface] = [
        detail("detail-login", of: "İş Bankası", height: Metrics.windowSize.height + Metrics.windowSize.height / 4),
        detail("detail-passkey", of: "GitHub", icons: true),
        detail("detail-dates", of: "Spotify", icons: true) { $0.toggleCreated() },
        detail("detail-bare", of: "Ev Wi-Fi"),
    ]

    /// A row under the pointer with its menu open and one of the menu's
    /// rows under it in turn, as the Large Type still has it; ⌘R on a login
    /// with a hidden field and on a card; a free-standing row under the
    /// pointer; and a row just copied.
    static let fieldRows: [Surface] = [
        detail("field-menu", of: "İş Bankası") { panes in
            panes.reading.hovered = ItemDetail.passwordRow
            panes.toggleMenu(for: ItemDetail.passwordRow)
            panes.reading.menu?.highlighted = .largeType
        },
        detail("field-revealed", of: "İş Bankası", height: Metrics.windowSize.height + Metrics.windowSize.height / 4) {
            $0.toggleRevealed()
        },
        detail("field-revealed-card", of: "Bonus Kart") { $0.toggleRevealed() },
        detail("field-website", of: "Spotify", icons: true) { panes in
            panes.reading.hovered = panes.detail?.websites.first?.row
        },
        detail("field-copied", of: "GitHub", icons: true) { $0.copyPrimary() },
        detail("field-code", of: "İş Bankası") { $0.reading.hovered = ItemDetail.codeRow },
    ]

    /// The other four types and a fifth this app does not know, from the
    /// demo vault: a card, an identity, a note with a hidden field, an SSH
    /// key and a driving licence.
    static let otherDetails: [Surface] = [
        detail("detail-card", of: "Bonus Kart"),
        detail("detail-identity", of: "Deniz Yılmaz", height: Metrics.windowSize.height + Metrics.windowSize.height / 4),
        detail("detail-note", of: "Yazılım lisansı"),
        detail("detail-ssh", of: "Sunucu anahtarı"),
        detail("detail-unknown", of: "Ehliyet"),
    ]
}
