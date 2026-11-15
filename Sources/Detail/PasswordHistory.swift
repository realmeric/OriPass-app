import SwiftUI

/// The passwords a login used to have (`docs/look.md`, "Password history"),
/// newest first, as the sheet behind "View password history" lists them.
/// A copy of what the item held when the sheet went up: the sheet is the
/// panes', so it goes with them at the lock and when another item is chosen,
/// and it keeps nothing the item did not already hold.
struct PasswordHistory: Redacted {
    struct Entry: Identifiable, Redacted {
        /// The place in the list as it is drawn.
        let id: Int
        let password: String
        /// When it stopped being the password, or nil when the item does not
        /// say or says it in a way nobody reads.
        let used: Date?

        var redactedLabel: String { "HistoryEntry(\(id))" }

        /// "Last used" and the day, or what is said when the item has none.
        var when: String {
            used.map { "Last used " + ItemDetail.written($0, time: false) } ?? "Date unknown"
        }

        /// What VoiceOver hears for the value: never the password, until it
        /// is shown.
        func said(revealed: Bool) -> String { revealed ? password : ItemDetail.concealed }
    }

    let title: String
    let entries: [Entry]
    /// The entries standing spelled out.
    var revealed: Set<Int> = []
    /// The entry that says it was copied, for a moment.
    var copied: Int?

    var redactedLabel: String { "PasswordHistory(\(entries.count))" }

    /// Nil when the item has no earlier password to list.
    init?(item: Item) {
        guard !item.passwordHistory.isEmpty else { return nil }
        title = item.name
        // A date is the order, and an entry without one comes after those
        // with one and keeps the place the item gave it.
        let ordered = item.passwordHistory.enumerated().sorted { first, second in
            switch (first.element.lastUsed, second.element.lastUsed) {
            case let (one?, other?) where one != other: return one > other
            case (_?, nil): return true
            case (nil, _?): return false
            default: return first.offset < second.offset
            }
        }
        entries = ordered.enumerated().map { place, pair in
            Entry(id: place, password: pair.element.password, used: pair.element.lastUsed)
        }
    }
}

extension Panes {
    /// The sheet, over the chosen item's earlier passwords. Nothing when it
    /// has none. An earlier password is as hidden as the one in use, so an
    /// item that asks is answered for before the sheet goes up.
    func showHistory() {
        guard detail?.item.passwordHistory.isEmpty == false else { return }
        reading.menu = nil
        guarded(.reveal) { panes in
            guard let item = panes.detail?.item, let history = PasswordHistory(item: item) else { return }
            panes.reading.history = history
        }
    }

    func closeHistory() {
        if reading.history != nil { reading.history = nil }
    }

    func toggleRevealed(historyEntry id: Int) {
        guard reading.history?.entries.indices.contains(id) == true else { return }
        reading.history?.revealed.formSymmetricDifference([id])
    }

    /// One earlier password to the pasteboard, marked as every copy is.
    @discardableResult
    func copy(historyEntry id: Int) -> Bool {
        guard let entry = reading.history?.entries.first(where: { $0.id == id }) else { return false }
        clipboard.copy(entry.password)
        reading.copied = nil
        reading.history?.copied = id
        acknowledge()
        return true
    }
}

// MARK: - Drawn

/// The sheet over the window: a card with the item's name under its title,
/// one row for each earlier password, and Done. A click beside it puts it
/// away.
struct PasswordHistorySheet: View {
    let history: PasswordHistory
    var reveal: (Int) -> Void = { _ in }
    var copy: (Int) -> Void = { _ in }
    var close: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    Text("Password history")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(history.title)
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.wide)
                Hairline(.horizontal)
                // As tall as its rows, until there are more than the sheet
                // shows, and then scrolled.
                if CGFloat(history.entries.count) > Metrics.historyRowsShown {
                    ScrollView { rows }
                        .frame(height: Metrics.historyRow * Metrics.historyRowsShown)
                } else {
                    rows
                }
                Hairline(.horizontal)
                HStack {
                    Spacer(minLength: 0)
                    Button("Done", action: close)
                        .buttonStyle(FilledButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .padding(Metrics.wide)
            }
            .frame(width: Metrics.offerWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .clipShape(shape)
            .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Password history")
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(history.entries) { entry in
                if entry.id > 0 { Hairline(.horizontal).padding(.leading, Metrics.wide) }
                row(entry)
            }
        }
    }

    private func row(_ entry: PasswordHistory.Entry) -> some View {
        let isShown = history.revealed.contains(entry.id)
        let isCopied = history.copied == entry.id
        return HStack(spacing: Metrics.tight) {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                if isShown {
                    SpelledValue(value: entry.password)
                } else {
                    Text(ItemDetail.dots)
                        .font(Fonts.dots)
                        .tracking(Metrics.dotTracking)
                        .foregroundStyle(Palette.text)
                }
                Text(entry.when)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.secondText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Earlier password, \(entry.when)")
            .accessibilityValue(entry.said(revealed: isShown))
            .accessibilityAddTraits(.isStaticText)
            button(isShown ? .conceal : .reveal, name: isShown ? "Conceal" : "Reveal") { reveal(entry.id) }
            button(isCopied ? .tick : .copy, name: isCopied ? "Copied" : "Copy") { copy(entry.id) }
        }
        .padding(.leading, Metrics.wide)
        .padding(.trailing, Metrics.close)
        .frame(maxWidth: .infinity, minHeight: Metrics.historyRow, alignment: .leading)
    }

    private func button(_ glyph: Glyph, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
                .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// The sheet while the panes have one up.
struct PasswordHistoryLayer: View {
    let panes: Panes
    @ObservedObject var reading: Reading

    var body: some View {
        ZStack {
            if let history = reading.history {
                PasswordHistorySheet(history: history,
                                     reveal: { panes.toggleRevealed(historyEntry: $0) },
                                     copy: { panes.copy(historyEntry: $0) },
                                     close: panes.closeHistory)
                    .transition(Motion.transition(.fade))
            }
        }
        .animation(Motion.animation(Motion.quick), value: reading.history != nil)
    }
}

extension Surface {
    private static func history(_ name: String, _ arrange: @escaping @MainActor (Panes) -> Void) -> Surface {
        Surface(name: name, size: CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height)) { store in
            let panes = Panes(store: store)
            panes.select(item: store.shelves.all.first { $0.item.name == "İş Bankası" }?.id)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The password row's menu with its third entry under the pointer, the
    /// sheet as it opens, the sheet with one password spelled out and
    /// another just copied, and one with more earlier passwords than it
    /// shows at once, which the bank in the demo vault has not.
    static let histories: [Surface] = [
        history("history-menu") { panes in
            panes.reading.hovered = ItemDetail.passwordRow
            panes.toggleMenu(for: ItemDetail.passwordRow)
            panes.reading.menu?.highlighted = .history
        },
        history("history-sheet") { $0.showHistory() },
        history("history-revealed") { panes in
            panes.showHistory()
            panes.toggleRevealed(historyEntry: 1)
            panes.reading.history?.copied = 0
        },
        history("history-long") { panes in
            guard var item = panes.detail?.item else { return }
            let first = item.passwordHistory
            item.passwordHistory = (0..<8).map { place in
                var entry = first[place % first.count]
                entry.lastUsedDate = first[place % first.count].lastUsed.map { VaultDate.string($0.addingTimeInterval(-86_400 * 7 * Double(place))) }
                return entry
            }
            panes.reading.history = PasswordHistory(item: item)
        },
    ]
}
