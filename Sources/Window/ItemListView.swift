import AppKit
import SwiftUI

/// The middle column (`docs/look.md`, "The item list"): a header with the
/// category at its left and find and sort at its right, and under it the
/// rows of `Panes.list`, grouped under small grey headings. What is selected,
/// how it is sorted and what is typed into the filter are the panes', so the
/// view holds nothing a fold or a lock would have to clear.
struct ItemListView: View {
    @ObservedObject var panes: Panes
    @ObservedObject private var store: VaultStore

    init(panes: Panes) {
        self.panes = panes
        store = panes.store
    }

    var body: some View {
        let list = panes.list
        VStack(spacing: 0) {
            ListHeader(panes: panes)
            Group {
                if list.isEmpty {
                    EmptyState(sentence: nothing)
                } else {
                    ItemRows(list: list, icons: panes.icons, selected: panes.selectedItem?.id,
                             hasKeys: panes.showsFocus && panes.focus == .list, click: panes.click(item:),
                             drag: panes.beginDrag)
                        // What a search found is a list of its own and starts
                        // at its top, or on the selected row when it found
                        // that, and so does the list that comes back after.
                        .id(panes.isSearching)
                }
            }
            .background(ListKeys(panes: panes, asked: panes.keysToList))
        }
    }
}

extension ItemListView {
    /// What an empty column says. An index is a moment behind the unlock,
    /// and a search typed inside that moment has not failed yet.
    private var nothing: String {
        if panes.isSearching { return store.searchIndex == nil ? "Searching…" : "No results" }
        return panes.isFiltering && !panes.filter.isEmpty ? "No matches" : "No items"
    }
}

/// The rows, built as they come into view: two thousand of them scroll in a
/// lazy stack without a dropped frame (`docs/notes.md`, "The item list").
struct ItemRows: View {
    let list: ItemList
    let icons: IconStore
    let selected: String?
    /// The arrows are the list's, and the selected row wears their ring.
    var hasKeys = false
    let click: (String) -> Void
    /// What a row hands the system when it is dragged off towards the
    /// sidebar, and nil for a list nothing is dragged out of.
    var drag: ((String) -> NSItemProvider)?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list.sections) { section in
                        Text(section.heading)
                            .font(Fonts.heading)
                            .tracking(Metrics.headingTracking)
                            .foregroundStyle(Palette.secondText)
                            .padding(.horizontal, Metrics.close + Metrics.gap)
                            .frame(height: Metrics.listHeading)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.entries) { entry in
                            ItemRow(item: entry.item, icons: icons, isSelected: entry.id == selected,
                                    hasKeys: hasKeys && entry.id == selected) { click(entry.id) }
                                .onDrag { drag?(entry.id) ?? NSItemProvider() }
                                .id(entry.id)
                        }
                    }
                }
                .padding(.bottom, Metrics.close)
                .background(ListStart(top: selected.flatMap(top(of:)), row: Metrics.listRow, height: height,
                                      order: list.sort))
            }
            // With no anchor it moves only as far as brings the row in.
            .onChange(of: selected) { _, id in
                if let id { scroll.scrollTo(id) }
            }
        }
    }

    /// How far down the stack a row starts. Every heading is one height and
    /// every row another, so nothing has to be measured.
    private func top(of id: String) -> CGFloat? {
        var above: CGFloat = 0
        for section in list.sections {
            above += Metrics.listHeading
            if let place = section.entries.firstIndex(where: { $0.id == id }) {
                return above + CGFloat(place) * Metrics.listRow
            }
            above += CGFloat(section.entries.count) * Metrics.listRow
        }
        return nil
    }

    /// The whole stack's, which the stack itself only guesses at until it
    /// has built its last row.
    private var height: CGFloat {
        CGFloat(list.sections.count) * Metrics.listHeading + CGFloat(list.entries.count) * Metrics.listRow
            + Metrics.close
    }
}

/// Brings the selected row to the middle of the list when the list is first
/// drawn and when it is put in another order, which are the two times the
/// row can be anywhere without the selection having moved. It lies behind
/// the rows and moves the scroll view it finds itself in, by a distance and
/// in its own layout. Asked through `ScrollViewReader` at those two moments,
/// a lazy stack moved for a row far down and not for one a screen away,
/// and a window that is drawn once, as a shot is, never moved at all.
private struct ListStart: NSViewRepresentable {
    /// Where the selected row starts, or nil with nothing selected.
    let top: CGFloat?
    let row: CGFloat
    /// What all the rows and headings come to.
    let height: CGFloat
    let order: ItemList.Sort

    func makeNSView(context: Context) -> Mover {
        let mover = Mover()
        mover.owed = top.map { ($0, row, height) }
        mover.order = order
        return mover
    }

    func updateNSView(_ mover: Mover, context: Context) {
        if mover.order != order {
            mover.order = order
            mover.owed = top.map { ($0, row, height) }
            mover.needsLayout = true
        } else if let owed = mover.owed, owed.top != top {
            // The selection moved before the list had been brought to it,
            // and that move is scrolled to by its own rule.
            mover.owed = nil
        }
    }

    final class Mover: NSView {
        var owed: (top: CGFloat, row: CGFloat, height: CGFloat)?
        var order: ItemList.Sort?
        private weak var watched: NSScrollView?

        @objc private func heScrolled(_ note: Notification) {
            owed = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let owed, let scroll = enclosingScrollView, let rows = scroll.documentView else { return }
            let clip = scroll.contentView
            let room = rows.frame.height - clip.bounds.height
            // Not yet: the rows have no height the first time through.
            guard clip.bounds.height > 0, room > 0 else { return }
            let wanted = min(max(0, owed.top - (clip.bounds.height - owed.row) / 2),
                             max(0, owed.height - clip.bounds.height))
            // A lazy stack guesses its height short of the truth, so a row
            // near the end is reached in more than one go: as far as there
            // is room now, and the rest as the stack grows and is laid out
            // again. A guess that stays short leaves the debt standing, and
            // his own scrolling is what ends it then, so the list is never
            // pulled back from where he took it.
            let down = min(wanted, room)
            if down >= wanted {
                self.owed = nil
            } else if watched !== scroll {
                watched = scroll
                NotificationCenter.default.addObserver(
                    self, selector: #selector(heScrolled(_:)),
                    name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: rows.isFlipped ? down : room - down))
            scroll.reflectScrolledClipView(clip)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// An icon about two lines of text tall, the title, and one grey line under
/// it. A favourite wears a star over the icon's lower right corner, and the
/// selected row sits on a pale rounded rectangle short of the column's
/// edges. Nothing divides one row from the next.
struct ItemRow: View {
    let item: Item
    let icons: IconStore
    let isSelected: Bool
    var hasKeys = false
    let select: () -> Void

    var body: some View {
        let second = item.secondLine
        Button(action: select) {
            HStack(spacing: Metrics.gap) {
                ItemIcon(item: item, icons: icons, side: Metrics.listIcon)
                    .overlay(alignment: .bottomTrailing) {
                        if item.favorite { star }
                    }
                VStack(alignment: .leading, spacing: Metrics.hair) {
                    Text(item.name)
                        .font(Fonts.rowTitle)
                        .foregroundStyle(Palette.text)
                    if let second {
                        Text(second)
                            .font(Fonts.rowSecond)
                            .foregroundStyle(Palette.secondText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gap)
            .frame(height: Metrics.listRow)
            .background(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .strokeBorder(hasKeys ? Palette.accent : Palette.accent.opacity(0), lineWidth: Metrics.dropRing)
            )
            .padding(.horizontal, Metrics.close)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(second ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var ground: Color {
        isSelected ? Palette.listSelection : Palette.content
    }

    private var star: some View {
        ZStack {
            Glyph.star.image.font(Fonts.starEdge).foregroundStyle(ground)
            Glyph.star.image.font(Fonts.star).foregroundStyle(Palette.star)
        }
        .offset(x: Metrics.starOverhang, y: Metrics.starOverhang)
        .accessibilityHidden(true)
    }
}

/// The strip over the rows. ⌥⌘F turns its left part into a field, and what
/// is typed there narrows the list where it stands. While the toolbar's
/// search has the list, it says so and offers nothing.
struct ListHeader: View {
    @ObservedObject var panes: Panes
    @FocusState private var fieldHasKeys: Bool

    var body: some View {
        HStack(spacing: Metrics.tight) {
            if panes.isSearching {
                found
                Spacer(minLength: 0)
            } else if panes.isFiltering {
                field
            } else {
                if let card = panes.watched {
                    named(card.title, .passwordHealth)
                } else {
                    category
                }
                Spacer(minLength: 0)
                glyphButton(.filter, "Find in List", action: panes.beginFilter)
            }
            if !panes.isSearching {
                glyphButton(.sort, "Sort", isOpen: panes.openMenu == .sort) { panes.toggle(.sort) }
            }
        }
        .padding(.leading, panes.isFiltering && !panes.isSearching ? Metrics.close : Metrics.wide)
        .padding(.trailing, Metrics.close)
        .frame(height: Metrics.listHeader)
    }

    private var category: some View {
        Button { panes.toggle(.categories) } label: {
            HStack(spacing: Metrics.close) {
                panes.category.glyph.image
                    .font(Fonts.sidebarGlyph)
                    .foregroundStyle(Palette.accent)
                    .frame(width: Metrics.sidebarMark)
                Text(panes.category.name)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Glyph.chevronDown.image
                    .font(Fonts.disclosure)
                    .foregroundStyle(Palette.secondText)
            }
            .frame(height: Metrics.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category")
        .accessibilityValue(panes.category.name)
    }

    /// Where the category stands, while the list is what a search found:
    /// the results are the whole vault's, in the search's own order, so
    /// there is no category to choose and nothing to sort.
    private var found: some View { named("Search Results", .search) }

    /// A list that is not a category's: what a search found, and the items
    /// of one of Password Health's cards, which are of whatever kind they are.
    private func named(_ name: String, _ glyph: Glyph) -> some View {
        HStack(spacing: Metrics.close) {
            glyph.image
                .font(Fonts.sidebarGlyph)
                .foregroundStyle(Palette.accent)
                .frame(width: Metrics.sidebarMark)
                .accessibilityHidden(true)
            // A card's name is said whole, on a second line when it is the
            // longest of them, as the card itself has it.
            Text(name)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: Metrics.buttonHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        return HStack(spacing: Metrics.close) {
            Glyph.filter.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
            TextField("Find in this list", text: $panes.filter)
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .focused($fieldHasKeys)
                .onExitCommand(perform: panes.endFilter)
                .onKeyPress(.downArrow) {
                    panes.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    panes.moveSelection(by: -1)
                    return .handled
                }
            Button(action: panes.endFilter) {
                Glyph.close.image
                    .font(Fonts.disclosure)
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.sidebarMark, height: Metrics.sidebarMark)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear")
        }
        .padding(.leading, Metrics.close)
        .padding(.trailing, Metrics.tight)
        .frame(height: Metrics.searchHeight)
        .background(shape.fill(Palette.field))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .onAppear { fieldHasKeys = true }
    }

    private func glyphButton(_ glyph: Glyph, _ name: String, isOpen: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.text)
                .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(isOpen ? Palette.listSelection : Palette.listSelection.opacity(0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// Where the keys go while the list has them: up and down move the
/// selection, a few letters jump to the first title that starts with them,
/// Delete archives the selected item, and Esc puts away an open menu or the
/// filter. An AppKit view, because a
/// first responder is the one thing that gets a key whatever the system's
/// keyboard navigation is set to.
struct ListKeys: NSViewRepresentable {
    let panes: Panes
    /// `Panes.keysToList`, here so that its moving is a change to this view.
    let asked: Int

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.panes = panes
        view.asked = asked
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) {
        view.panes = panes
        guard view.asked != asked else { return }
        view.asked = asked
        view.window?.makeFirstResponder(view)
    }

    final class Catcher: NSView {
        weak var panes: Panes?
        var asked = 0

        override var acceptsFirstResponder: Bool { true }

        /// A window that has just opened on the panes has nobody to give a
        /// key to, and the list is where a key is most likely meant.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard let panes, take(event, for: panes) else {
                super.keyDown(with: event)
                return
            }
        }

        private func take(_ event: NSEvent, for panes: Panes) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            // A space inside a word being typed is a letter of the title.
            if let key = Stroke(event).flatMap(PaneKey.init), !(key == .space && panes.isTyping) {
                return panes.press(key)
            }
            guard !panes.showsKeys, let typed = event.characters, !typed.isEmpty else { return false }
            guard typed.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0)
                    || CharacterSet.symbols.contains($0) || $0 == " "
            }) else { return false }
            // A letter no title starts with is still the list's, and is not
            // a beep.
            panes.type(typed)
            return true
        }
    }
}

/// One of the header's two menus, drawn by the app over the window as its
/// still has it: a card under the button, a tick at the right of the row in
/// force. A click anywhere else puts it away.
struct ListMenuLayer: View {
    @ObservedObject var panes: Panes
    let menu: ListMenu
    let layout: PaneLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.content.opacity(0)
                .contentShape(Rectangle())
                .onTapGesture { panes.openMenu = nil }
                .accessibilityHidden(true)
            ListMenuCard(panes: panes, menu: menu)
                .offset(x: left, y: Metrics.toolbarHeight + Metrics.listHeader - Metrics.tight)
        }
    }

    /// Under the category's mark, or under the sort button's left edge.
    private var left: CGFloat {
        switch menu {
        case .categories: return layout.sidebar + Metrics.close
        case .sort: return layout.sidebar + layout.list - Metrics.close - Metrics.buttonHeight
        }
    }
}

struct ListMenuCard: View {
    @ObservedObject var panes: Panes
    let menu: ListMenu

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            switch menu {
            case .sort: sort
            case .categories: categories
            }
        }
        .padding(.vertical, Metrics.close)
        .frame(width: Metrics.menuWidth)
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
    }

    @ViewBuilder
    private var sort: some View {
        Text(panes.list.caption)
            .font(Fonts.heading)
            .tracking(Metrics.headingTracking)
            .foregroundStyle(Palette.secondText)
            .padding(.horizontal, Metrics.wide)
            .frame(height: Metrics.menuRow)
        ForEach(ItemList.Key.allCases, id: \.self) { key in
            ListMenuRow(name: key.name, isTicked: panes.sort.key == key) { panes.order(by: key) }
        }
        rule
        ForEach(Array(panes.sort.key.directions.enumerated()), id: \.offset) { index, name in
            ListMenuRow(name: name, isTicked: panes.sort.isReversed == (index == 1)) {
                panes.order(reversed: index == 1)
            }
        }
    }

    @ViewBuilder
    private var categories: some View {
        ForEach(ItemList.Category.allCases, id: \.self) { category in
            ListMenuRow(name: category.name, glyph: category.glyph, isTicked: panes.category == category) {
                panes.choose(category)
            }
            if category == .all { rule }
        }
    }

    private var rule: some View {
        Hairline(.horizontal)
            .padding(.horizontal, Metrics.wide)
            .padding(.vertical, Metrics.tight)
    }
}

private struct ListMenuRow: View {
    let name: String
    var glyph: Glyph?
    let isTicked: Bool
    let choose: () -> Void
    @State private var isUnderPointer = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Metrics.close) {
                if let glyph {
                    glyph.image
                        .font(Fonts.sidebarGlyph)
                        .foregroundStyle(glyph == .categories ? Palette.accent : Palette.secondText)
                        .frame(width: Metrics.sidebarMark)
                }
                Text(name)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 0)
                if isTicked {
                    Glyph.tick.image
                        .font(Fonts.action)
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Metrics.close)
            .frame(height: Metrics.menuRow)
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

extension Surface {
    private static func list(_ name: String, icons: Bool = false,
                             _ arrange: @escaping @MainActor (Panes) -> Void) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: icons ? DemoIcons.seeded() : .off)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The list by date with a row selected and the sort menu open, as the
    /// sort still has it; by title with the category menu open; one
    /// category; the filter with something typed into it; and the list with
    /// the demo's site icons.
    static let lists: [Surface] = [
        list("list-dates") { panes in
            panes.order(by: .modified)
            panes.select(item: panes.list.entries.dropFirst(3).first?.id)
        },
        list("list-sort-menu") { panes in
            panes.order(by: .modified)
            panes.toggle(.sort)
        },
        list("list-category-menu") { panes in
            panes.moveSelection(by: 1)
            panes.toggle(.categories)
        },
        list("list-cards") { $0.choose(.card) },
        // Some logins with the icon their site has, the rest on tiles, and
        // the other types on their category's mark.
        list("list-icons", icons: true) { panes in
            panes.select(item: panes.list.entries.dropFirst(2).first?.id)
        },
        list("list-filter") { panes in
            panes.beginFilter()
            panes.filter = "kar"
        },
    ]
}

extension Surface {
    private static func search(_ name: String, _ query: String, hasKeys: Bool = true,
                               _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.query = query
            panes.searchHasKeys = hasKeys
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The field with the caret in it and nothing typed; a few letters that
    /// start one title and sit inside another; two words, with the first
    /// result chosen by Return; a word found in titles, usernames and notes
    /// alike; and one that nothing has.
    static let searches: [Surface] = [
        search("search-empty", ""),
        search("search-letters", "git"),
        search("search-words", "is bankasi", hasKeys: false) { $0.submitSearch() },
        search("search-ranked", "deniz"),
        search("search-nothing", "zeytin"),
    ]
}
