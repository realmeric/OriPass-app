import AppKit
import SwiftUI

/// How tall the panel is for what it holds. The model sizes the window by
/// this and the view fills it, so nothing is measured on the way.
enum QuickLayout {
    /// The most results and the most actions that are drawn before the list
    /// scrolls.
    static let rows = 8
    static let actions = 9

    static let field = Metrics.quickField + Metrics.quickPad * 2

    static func results(_ count: Int, headings: Int = 0) -> CGFloat {
        CGFloat(min(count, rows)) * Metrics.quickRow + CGFloat(headings) * Metrics.quickHeading
    }

    static func actions(_ actions: [QuickAction]) -> CGFloat {
        let rules = actions.filter(\.startsGroup).count
        let most = CGFloat(Self.actions) * Metrics.quickAction + Metrics.quickRule * 2
        return min(CGFloat(actions.count) * Metrics.quickAction + CGFloat(rules) * Metrics.quickRule, most)
    }

    static func height(isOpen: Bool, rows: Int, headings: Int = 0, actions: [QuickAction]?,
                       foundNothing: Bool) -> CGFloat {
        if !isOpen { return field + Metrics.quickLock }
        if let actions {
            return field + Metrics.quickHeader + Metrics.quickRule + Self.actions(actions) + Metrics.quickPad
                + Metrics.quickFooter
        }
        if rows > 0 { return field + results(rows, headings: headings) + Metrics.quickPad + Metrics.quickHints }
        return foundNothing ? field + Metrics.quickRow + Metrics.quickPad : field
    }
}

/// What the panel shows (`docs/look.md`, "Quick Access"): the field, large,
/// on a grey that lets a little of what is behind it through, and under it
/// the results, or one item opened onto its actions, or the lock.
struct QuickAccessView: View {
    @ObservedObject var quick: QuickAccess
    @ObservedObject private var store: VaultStore
    @ObservedObject private var door: Door
    /// A shot's say on whether a finger can open the vault. The door's
    /// otherwise.
    private let showsFinger: Bool?

    init(quick: QuickAccess, showsFinger: Bool? = nil) {
        self.quick = quick
        store = quick.door.store
        door = quick.door
        self.showsFinger = showsFinger
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if !quick.isOpen {
                QuickLock(quick: quick, state: store.state, refusal: store.refusal,
                          hasSeal: showsFinger ?? door.hasSeal)
            } else if let notice = quick.notice {
                QuickNotice(notice: notice, allow: quick.allowTyping)
            } else if let opened = quick.opened {
                QuickItem(quick: quick, opened: opened, icons: icons)
            } else {
                QuickResults(quick: quick, icons: icons)
                // There while nothing is listed too, at no height, like the
                // rows over it: the first letter finds it made.
                QuickHints(offer: quick.offer)
                    .frame(height: quick.rows.isEmpty ? 0 : Metrics.quickHints, alignment: .top)
                    .clipped()
                    .accessibilityHidden(quick.rows.isEmpty)
                if quick.foundNothing {
                    Text(QuickAccess.nothing)
                        .font(Fonts.quickSecond)
                        .foregroundStyle(Palette.secondText)
                        .frame(height: Metrics.quickRow)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            SidebarMaterial(material: .menu, state: .active, radius: Metrics.quickRadius)
                .overlay(Palette.quickGround.opacity(Palette.quickVeil))
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.quickRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.quickRadius)
                .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
        }
        .ignoresSafeArea()
    }

    /// The open panes' icons, which end with them at the lock.
    private var icons: IconStore { door.panes?.icons ?? .off }

    private var field: some View {
        HStack(spacing: Metrics.quickPad) {
            Glyph.search.image
                .font(Fonts.quickGlyph)
                .foregroundStyle(Palette.accent)
                .frame(width: Metrics.quickGlyph)
                .accessibilityHidden(true)
            QuickField(quick: quick)
        }
        .padding(.horizontal, Metrics.quickPad + Metrics.quickPad)
        .frame(height: Metrics.quickField)
        .background(Palette.quickField, in: RoundedRectangle(cornerRadius: Metrics.quickFieldRadius))
        .padding(Metrics.quickPad)
    }
}

/// The field itself, an `NSTextField` with no border and no ground, so that
/// the panel can put the keys in it the moment it is ordered in and not a
/// turn of the run loop later.
struct QuickField: NSViewRepresentable {
    @ObservedObject var quick: QuickAccess

    func makeCoordinator() -> Coordinator { Coordinator(quick) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.quickField
        field.textColor = NSColor(Palette.text)
        field.placeholderAttributedString = NSAttributedString(string: Self.placeholder, attributes: [
            .font: Fonts.quickField, .foregroundColor: NSColor(Palette.prompt),
        ])
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(Self.placeholder)
        field.cell?.setAccessibilityLabel(Self.placeholder)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        quick.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        guard field.stringValue != quick.query else { return }
        field.stringValue = quick.query
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: nsView.intrinsicContentSize.height)
    }

    static let placeholder = "Search"

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let quick: QuickAccess

        init(_ quick: QuickAccess) {
            self.quick = quick
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            quick.query = field.stringValue
        }
    }
}

// MARK: - The results

/// One line each: a small icon, the title, and after a dash the grey line
/// the item list gives it and the site. The selected one is filled with the
/// accent, says what Return would do, and has the square that opens it.
/// While some of the list is suggested, the first of each kind has a small
/// grey name over it: the site's or the app's, and "Recently Used".
///
/// Eight places and no scroll view: the arrows move the eight down the
/// list (`QuickAccess.top`). A place keeps its views from one letter to the
/// next, and while nothing is listed too, and is handed another item, which
/// is most of what keeps a letter inside a frame (`docs/notes.md`,
/// "Timing"). Only the icon is made again.
private struct QuickResults: View {
    @ObservedObject var quick: QuickAccess
    let icons: IconStore

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<QuickLayout.rows, id: \.self) { slot in
                let place = quick.top + slot
                QuickRow(item: quick.rows.indices.contains(place) ? quick.rows[place].item : nil,
                         heading: quick.headings[place], icons: icons,
                         isSelected: place == quick.selected, enter: quick.offer.enter,
                         choose: { quick.click(row: place) }, more: { quick.openSelected() })
            }
        }
        .frame(height: QuickLayout.results(quick.rows.count, headings: quick.headingsDrawn), alignment: .top)
        .clipped()
        // The list says how many it holds before any of its rows is read.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(quick.counted ?? "")
        .padding(.horizontal, Metrics.quickPad)
        .padding(.bottom, quick.rows.isEmpty ? 0 : Metrics.quickPad)
    }
}

private struct QuickRow: View {
    /// Nil for a place past the end of the list, which is drawn empty and
    /// is cut off by the list's own height.
    let item: Item?
    /// The name over the row, for the first of the suggested and the first
    /// of the used. There at no height otherwise, as an empty row is.
    let heading: String?
    let icons: IconStore
    let isSelected: Bool
    let enter: String?
    let choose: () -> Void
    let more: () -> Void

    var body: some View {
        let second = item.flatMap(QuickAccess.second)
        let isSelected = isSelected && item != nil
        let corner = Metrics.quickRowRadius
        VStack(spacing: 0) {
            Text(heading ?? "")
                .font(Fonts.quickHeading)
                .foregroundStyle(Palette.secondText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Metrics.quickGap)
                .padding(.top, Metrics.quickPad / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: heading == nil ? 0 : Metrics.quickHeading)
                .clipped()
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(heading == nil)
            row(second: second, isSelected: isSelected, corner: corner)
        }
    }

    private func row(second: String?, isSelected: Bool, corner: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if let item {
                        ItemIcon(item: item, icons: icons, side: Metrics.quickIcon)
                            .id(item.id)
                    }
                }
                .frame(width: Metrics.quickIcon, height: Metrics.quickIcon)
                .padding(.trailing, Metrics.quickGap)
                Text(item?.name ?? "")
                    .font(Fonts.quickTitle)
                    .foregroundStyle(isSelected ? Palette.onColour : Palette.text)
                    .layoutPriority(1)
                Text(second.map { " – \($0)" } ?? "")
                    .font(Fonts.quickSecond)
                    .foregroundStyle(isSelected ? Palette.onColour.opacity(Palette.quickOnSelection)
                        : Palette.secondText)
                Spacer(minLength: Metrics.quickGap)
                Text(isSelected ? enter ?? "" : "")
                    .font(Fonts.quickTitle)
                    .foregroundStyle(Palette.onColour)
                    .fixedSize()
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Metrics.quickGap)
            .frame(height: Metrics.quickRow)
            .background(isSelected ? Palette.lit : Palette.lit.opacity(0),
                        in: UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: corner))
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            // One element, pressed as it is clicked.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item?.name ?? "")
            .accessibilityValue(second ?? "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: isSelected ? enter ?? QuickAccess.choosing : QuickAccess.choosing, choose)
            .accessibilityAction(.default, choose)
            Button(action: more) {
                Glyph.more.image
                    .font(Fonts.quickMore)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.quickMore, height: Metrics.quickRow)
                    .background(Palette.quickMore,
                                in: UnevenRoundedRectangle(bottomTrailingRadius: corner, topTrailingRadius: corner))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More Actions")
            .frame(width: isSelected ? Metrics.quickMore : 0)
            .clipped()
            .accessibilityHidden(!isSelected)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHidden(item == nil)
    }
}

/// The strip under the results: the keys that act on the selected row
/// without opening it, each in caps with its action after it.
private struct QuickHints: View {
    let offer: QuickAccess.Offer

    var body: some View {
        HStack(spacing: Metrics.quickGap + Metrics.quickGap) {
            if let primary = offer.primary { hint(Stroke("c", .command), primary) }
            if let password = offer.password { hint(Stroke("c", [.command, .shift]), password) }
            hint(Stroke(Stroke.right), "More Actions")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.quickPad + Metrics.quickGap)
        .frame(height: Metrics.quickHints)
        .background(Palette.quickFooter)
        .overlay(alignment: .top) { Palette.outline.frame(height: Metrics.hairline) }
    }

    private func hint(_ stroke: Stroke, _ name: String) -> some View {
        HStack(spacing: Metrics.quickPad) {
            QuickCaps(stroke: stroke)
            Text(name)
                .font(Fonts.quickHint)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(stroke.symbols)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// One press as caps: one for each key held and one for the key.
private struct QuickCaps: View {
    let stroke: Stroke

    var body: some View {
        HStack(spacing: Metrics.quickPad / 4) {
            ForEach(stroke.caps, id: \.self) { cap in
                let shape = RoundedRectangle(cornerRadius: Metrics.quickKeycapRadius, style: .continuous)
                Text(cap)
                    .font(Fonts.quickKeycap)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, Metrics.quickPad - Metrics.quickPad / 4)
                    .frame(minWidth: Metrics.quickKeycap, minHeight: Metrics.quickKeycap)
                    .background(shape.fill(Palette.quickKeycap))
                    .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            }
        }
    }
}

// MARK: - One item, opened

/// The item as a header, then what can be done with it, one a row with its
/// keys at the right, and at the foot the vault it lives in.
private struct QuickItem: View {
    @ObservedObject var quick: QuickAccess
    let opened: QuickAccess.Opened
    let icons: IconStore

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(opened.actions.enumerated()), id: \.element.id) { place, action in
                            if action.startsGroup { rule }
                            row(action, isChosen: place == opened.chosen)
                                .id(action.id)
                        }
                    }
                }
                .frame(height: QuickLayout.actions(opened.actions))
                .onChange(of: opened.chosen) { _, place in
                    guard opened.actions.indices.contains(place) else { return }
                    reader.scrollTo(opened.actions[place].id)
                }
            }
            .padding(.bottom, Metrics.quickPad)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.quickGap + Metrics.quickPad / 2) {
            ItemIcon(item: opened.entry.item, icons: icons, side: Metrics.quickHeaderIcon)
            VStack(alignment: .leading, spacing: Metrics.quickPad / 4) {
                Text(opened.detail.title)
                    .font(Fonts.quickHeader)
                    .foregroundStyle(Palette.text)
                if let second = QuickAccess.second(of: opened.entry.item) {
                    Text(second)
                        .font(Fonts.quickKeys)
                        .foregroundStyle(Palette.secondText)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: { quick.back() }) {
                Glyph.close.image
                    .font(Fonts.quickMore)
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.quickMore, height: Metrics.quickMore)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
        }
        .padding(.horizontal, Metrics.quickPad + Metrics.quickGap)
        .frame(height: Metrics.quickHeader)
    }

    private var rule: some View {
        Palette.outline
            .frame(height: Metrics.hairline)
            .padding(.horizontal, Metrics.quickPad)
            .frame(height: Metrics.quickRule)
    }

    private func row(_ action: QuickAction, isChosen: Bool) -> some View {
        HStack(spacing: Metrics.quickGap) {
            Text(action.name)
                .font(Fonts.quickAction)
                .foregroundStyle(isChosen ? Palette.onColour : Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let keys = action.keys {
                Text(keys.symbols)
                    .font(Fonts.quickKeys)
                    .foregroundStyle(isChosen ? Palette.onColour.opacity(Palette.quickOnSelection) : Palette.secondText)
            }
        }
        .padding(.horizontal, Metrics.quickGap)
        .frame(height: Metrics.quickAction)
        .background {
            if isChosen { RoundedRectangle(cornerRadius: Metrics.quickRowRadius).fill(Palette.lit) }
        }
        .padding(.horizontal, Metrics.quickPad)
        .contentShape(Rectangle())
        .onTapGesture { quick.perform(action) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.name)
        .accessibilityValue(action.keys?.symbols ?? "")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        HStack(spacing: Metrics.quickPad) {
            Text("Located in")
                .foregroundStyle(Palette.secondText)
            VaultDot(name: opened.detail.vault.name)
            Text(opened.detail.vault.name)
                .foregroundStyle(Palette.text)
            Spacer(minLength: 0)
        }
        .font(Fonts.quickKeys)
        .lineLimit(1)
        .padding(.horizontal, Metrics.quickPad + Metrics.quickGap)
        .frame(height: Metrics.quickFooter)
        .background(Palette.quickFooter)
        .overlay(alignment: .top) { Palette.outline.frame(height: Metrics.hairline) }
    }
}

// MARK: - A notice

/// What is under the field when a login that was to be typed was copied
/// or was not typed (`FillNotice`): what happened, the one sentence that
/// says why, and for Accessibility the button that goes and asks for it,
/// which Return presses.
private struct QuickNotice: View {
    let notice: FillNotice
    let allow: () -> Void

    var body: some View {
        HStack(spacing: Metrics.quickGap) {
            Circle()
                .fill(Palette.lit)
                .frame(width: Metrics.quickLockMark, height: Metrics.quickLockMark)
                .overlay(
                    Glyph.keyboard.image
                        .font(Fonts.quickKeycap)
                        .foregroundStyle(Palette.onColour)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.quickPad / 4) {
                Text(notice.title)
                    .font(Fonts.quickTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Text(notice.sentence)
                    .font(Fonts.quickKeys)
                    .foregroundStyle(Palette.secondText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let button = notice.button {
                Button(button, action: allow)
                    .buttonStyle(FilledButtonStyle())
                    .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.quickPad + Metrics.quickGap)
        .padding(.bottom, Metrics.quickPad)
        .frame(height: Metrics.quickNotice)
    }
}

// MARK: - The lock

/// What is under the field while the vault is shut: the mark, the field the
/// master password goes in, and the fingerprint when a finger can open it.
/// The other states have nothing to type, and say where to go.
private struct QuickLock: View {
    let quick: QuickAccess
    let state: VaultStore.State
    let refusal: String?
    let hasSeal: Bool

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: Metrics.quickGap) {
            Circle()
                .fill(Palette.lit)
                .frame(width: Metrics.quickLockMark, height: Metrics.quickLockMark)
                .overlay(
                    AppMark()
                        .fill(Palette.onColour, style: AppMark.fill)
                        .frame(width: Metrics.quickLockMark * Metrics.lockMarkShare,
                               height: Metrics.quickLockMark * Metrics.lockMarkShare)
                )
                .accessibilityHidden(true)
            switch state {
            case .locked, .unlocking, .unlocked:
                door
            case .noCLI, .loggedOut, .failed:
                Text(sentence)
                    .font(Fonts.quickSecond)
                    .foregroundStyle(Palette.secondText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Open \(AppInfo.name)", action: quick.openApp)
                    .buttonStyle(FilledButtonStyle())
            }
        }
        .padding(.horizontal, Metrics.quickPad + Metrics.quickGap)
        .padding(.bottom, Metrics.quickPad)
        .frame(height: Metrics.quickLock)
    }

    private var sentence: String {
        switch state {
        case .loggedOut: return "Nobody is signed in."
        case .noCLI: return "\(AppInfo.name) needs Bitwarden's command line tool."
        default: return "The vault did not open."
        }
    }

    @ViewBuilder private var door: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.quickFieldRadius, style: .continuous)
        HStack(spacing: 0) {
            PasswordField(placeholder: "Master password", isEnabled: state == .locked,
                          takesFocus: !hasSeal, typed: quick.typedPassword, isFocused: $isFocused,
                          submit: quick.unlock)
                .padding(.horizontal, Metrics.quickGap)
            if hasSeal {
                Palette.outline
                    .frame(width: Metrics.hairline)
                    .padding(.vertical, Metrics.quickPad)
                Button(action: quick.askForFinger) {
                    Glyph.fingerprint.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: Metrics.quickIcon, height: Metrics.quickIcon)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, Metrics.quickGap)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state != .locked)
                .accessibilityLabel("Unlock with Touch ID")
            }
        }
        .frame(height: Metrics.quickLockField)
        .background(shape.fill(Palette.quickField))
        .overlay(shape.strokeBorder(isFocused ? Palette.focusRing : Palette.outline,
                                    lineWidth: isFocused ? Metrics.dropRing : Metrics.hairline))
        .opacity(state == .locked ? 1 : Palette.disabled)
        if let refusal {
            Text(refusal)
                .font(Fonts.quickKeys)
                .foregroundStyle(Palette.red)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Shots

extension Surface {
    /// The panel is drawn at its own height at the top of the shot, and the
    /// rest of the shot is nothing.
    private static func quickAccess(_ name: String, used: [String] = [], showsFinger: Bool? = nil,
                                    typist: (@MainActor () -> Typist)? = nil,
                                    over own: (@MainActor () -> VaultStore)? = nil,
                                    _ arrange: @escaping @MainActor (QuickAccess) -> Void) -> Surface {
        Surface(name: name, size: Metrics.quickShot, isBare: true) { demo in
            let store = own?() ?? demo
            let recents = Recents(file: nil)
            for title in used.reversed() {
                if let entry = store.shelves.all.first(where: { $0.item.name == title }) { recents.use(entry.id) }
            }
            // The app's own door has the arming, so an opened login has its
            // Open & Fill row.
            let door = Door(store: store, armedFill: ArmedFill(sites: FakeSites()))
            let quick = QuickAccess(door: door, recents: recents, typist: typist?(), present: { _ in })
            arrange(quick)
            let height = quick.height
            // The view below is the one that is drawn. The panel's own would
            // keep the panel alive after the shot.
            quick.end()
            return AnyView(QuickAccessView(quick: quick, showsFinger: showsFinger)
                .frame(height: height)
                .frame(maxHeight: .infinity, alignment: .top))
        }
    }

    /// A typist that types nothing, for the rows that offer one.
    @MainActor
    private static func typist(isTrusted: Bool) -> Typist {
        Typist(access: FakeAccessibility(isTrusted: isTrusted), ground: FakeForeground(), sink: FakeSink())
    }

    /// A vault nobody has opened, which the one every surface is handed
    /// cannot be.
    @MainActor
    private static func shut() -> VaultStore {
        VaultStore(backend: FakeBackend(items: [], folders: [], password: DemoVault.password))
    }

    /// The panel as it first comes up, with items used before, with two
    /// letters typed, opened on a login, and over a vault that is shut.
    static let quickAccesses: [Surface] = [
        quickAccess("quick-access") { _ in },
        quickAccess("quick-access-suggestions",
                    used: ["GitHub", "İş Bankası", "Spotify", "Garanti BBVA", "Digital Ocean"]) { _ in },
        // GitHub's sign-in page in a browser, with two of the used under it,
        // and Spotify's own app, whose bundle id read backwards is its site.
        quickAccess("quick-access-site", used: ["İş Bankası", "GitHub", "Spotify"]) { quick in
            quick.look(at: FrontApp(pid: 0, bundleID: "com.apple.Safari", name: "Safari"),
                       on: "https://github.com/login")
        },
        quickAccess("quick-access-app") { quick in
            quick.look(at: FrontApp(pid: 0, bundleID: "com.spotify.client", name: "Spotify"))
        },
        quickAccess("quick-access-results") { quick in
            quick.query = "is"
            quick.move(by: 1)
        },
        quickAccess("quick-access-actions") { quick in
            quick.query = "is ban"
            quick.openSelected()
        },
        // Opened on Spotify's login over Spotify's app, where the fill is
        // one of the actions, and the same fill before macOS allows it.
        quickAccess("quick-access-fill", typist: { typist(isTrusted: true) }) { quick in
            quick.look(at: FrontApp(pid: 0, bundleID: "com.spotify.client", name: "Spotify"))
            quick.openSelected()
        },
        quickAccess("quick-access-not-allowed", typist: { typist(isTrusted: false) }) { quick in
            quick.look(at: FrontApp(pid: 0, bundleID: "com.spotify.client", name: "Spotify"))
            quick.tell(.copiedInstead(of: "Spotify"))
        },
        // A login with no username, and a caret that was in no password's
        // field: nothing was typed, and there is nothing to switch on.
        quickAccess("quick-access-no-username", typist: { typist(isTrusted: true) }) { quick in
            quick.look(at: FrontApp(pid: 0, bundleID: "com.kagi.kagimacOS", name: "Orion"))
            quick.tell(.needsPasswordField(in: "Orion"))
        },
        quickAccess("quick-access-locked", showsFinger: false, over: shut) { $0.query = "is" },
        quickAccess("quick-access-locked-finger", showsFinger: true, over: shut) { $0.query = "is" },
    ]
}
