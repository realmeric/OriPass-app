import SwiftUI

/// Password Health's page (`docs/look.md`, "Password Health"), where the item list and
/// the details would be: its name and what it is, the strength bar, and the
/// cards three across. No half ring and no score (D13). Drawn from values,
/// so it reads no store and holds nothing a lock would have to clear.
struct DashboardView: View {
    let dashboard: Dashboard
    let show: (WatchCard) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.wide) {
                header
                strength
                cards
            }
            .padding(.horizontal, Metrics.loose)
            .padding(.vertical, Metrics.wide)
            .frame(maxWidth: Metrics.dashboardWidth)
            .frame(maxWidth: .infinity)
        }
        // Not under the toolbar, which a ground that ignored the safe area
        // would cover.
        .background(Palette.page, ignoresSafeAreaEdges: [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.close) {
            HStack(spacing: Metrics.gap) {
                Glyph.passwordHealth.image
                    .font(Fonts.pageMark)
                    .foregroundStyle(Palette.secondText)
                    .accessibilityHidden(true)
                Text("Password Health")
                    .font(Fonts.title)
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("How the vault is doing, counted on this Mac from the items in it.\nOpen a card's items to put them right.")
                .font(Fonts.body)
                .foregroundStyle(Palette.secondText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.close)
    }

    private var strength: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text("Password Strength")
                .font(Fonts.pageHeading)
                .foregroundStyle(Palette.text)
                .accessibilityValue(dashboard.spoken)
                .accessibilityAddTraits(.isHeader)
            // The name says what the bar shows.
            StrengthBar(segments: dashboard.segments)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.wide)
        .padding(.vertical, Metrics.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardGround())
    }

    /// Rows of three, the last filled out with nothing, so a card in it is
    /// as wide as the ones above it.
    private var cards: some View {
        let across = Metrics.cardsAcross
        let rows = stride(from: 0, to: dashboard.cards.count, by: across).map { start in
            Array(dashboard.cards[start..<min(start + across, dashboard.cards.count)])
        }
        return Grid(horizontalSpacing: Metrics.wide, verticalSpacing: Metrics.wide) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { card in
                        WatchCardView(card: card) { show(card.kind) }
                    }
                    ForEach(row.count..<across, id: \.self) { _ in
                        Palette.card.opacity(0)
                            .gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }
}

/// A card's white ground inside its outline.
private struct CardGround: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        content
            .background(shape.fill(Palette.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }
}

/// One rounded bar in a segment for each level a password is at, the
/// strongest at the left, each as long as its share of the passwords. A
/// level with a single password among hundreds is still given enough to be
/// seen, and a vault with no passwords has the empty track.
struct StrengthBar: View {
    let segments: [Dashboard.Segment]

    var body: some View {
        GeometryReader { bar in
            let total = CGFloat(segments.reduce(0) { $0 + $1.count })
            let gaps = Metrics.strengthGap * CGFloat(max(segments.count - 1, 0))
            // What is left once every segment has its least is shared out.
            let shared = max(bar.size.width - gaps - Metrics.strengthLeast * CGFloat(segments.count), 0)
            HStack(spacing: Metrics.strengthGap) {
                ForEach(segments) { segment in
                    Palette.strength[segment.level.rawValue]
                        .frame(width: Metrics.strengthLeast + shared * CGFloat(segment.count) / max(total, 1))
                        .help("\(segment.count) \(segment.level.word)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // The card's own colour would not show on it in dark.
            .background(Palette.well)
            .clipShape(Capsule())
        }
        .frame(height: Metrics.strengthBar)
    }
}

/// A card (`docs/look.md`, "Password Health"): the count at its top left and the
/// drawing at its top right, its name, what the count means, and under a
/// hairline "Show Items". A card with something on it has its drawing in
/// the red and a little of the red from its top; one at nought is grey, and
/// is drawn all the same.
private struct WatchCardView: View {
    let card: Dashboard.Card
    let show: () -> Void

    private var asks: Bool { (card.count ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.close) {
                HStack(alignment: .top, spacing: 0) {
                    // Kept at its height while there is no count to draw.
                    Text(card.count.map(String.init) ?? " ")
                        .font(Fonts.count)
                        .foregroundStyle(Palette.text)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    WatchDrawing(card: card.kind)
                        .stroke(asks ? Palette.red : Palette.secondText, style: WatchDrawing.stroke)
                        .opacity(Palette.drawing)
                        .frame(width: Metrics.watchDrawing.width, height: Metrics.watchDrawing.height)
                        .accessibilityHidden(true)
                }
                Text(card.kind.title)
                    .font(Fonts.cardTitle)
                    .foregroundStyle(Palette.text)
                    .accessibilityValue(card.count.map(String.init) ?? "")
                    .accessibilityAddTraits(.isHeader)
                Text(card.kind.sentence)
                    .font(Fonts.body)
                    .foregroundStyle(Palette.secondText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.wide)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline(.horizontal)
            Button(action: show) {
                HStack(spacing: Metrics.close) {
                    Text("Show Items")
                    Spacer(minLength: 0)
                    Glyph.onward.image
                        .accessibilityHidden(true)
                }
                .font(Fonts.rowTitle)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, Metrics.wide)
                .frame(height: Metrics.cardFooter)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Items, \(card.kind.title)")
        }
        .background(alignment: .top) {
            if asks {
                LinearGradient(colors: [Palette.red.opacity(Palette.wash), Palette.red.opacity(0)],
                               startPoint: .top, endPoint: .center)
            }
        }
        .modifier(CardGround())
    }
}

extension Surface {
    private static func page(_ name: String, width: CGFloat = Metrics.windowSize.width,
                             height: CGFloat = Metrics.windowSize.height,
                             _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: CGSize(width: width, height: height)) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(.passwordHealth)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    private static func cards(_ name: String, _ dashboard: Dashboard) -> Surface {
        Surface(name: name, size: CGSize(width: Metrics.windowSize.width - Metrics.sidebarWidth,
                                         height: Metrics.windowSize.height), isBare: true) { _ in
            AnyView(DashboardView(dashboard: dashboard) { _ in })
        }
    }

    /// The page over the demo vault; at the window's minimum, where the
    /// sidebar has folded; the items of Reused Passwords with one chosen;
    /// a vault with nothing to say against it; and one not counted yet.
    /// Then the breach check switched on: its card leading the page, its
    /// items, and the card before the first answer is in. Then the list of
    /// two-factor sites on its own, its items, and with both switches on,
    /// which is six cards and the whole of the still.
    static let healthSurfaces: [Surface] = [
        page("passwordHealth"),
        page("passwordHealth-minimum", width: Metrics.windowMinimum.width, height: Metrics.windowMinimum.height),
        page("passwordHealth-reused") { panes in
            panes.show(.reused)
            panes.select(item: panes.list.entries.first?.id)
        },
        cards("passwordHealth-zero", Dashboard(levels: [0, 0, 0, 2, 9], counts: [:])),
        cards("passwordHealth-uncounted", Dashboard(nil)),
        vulnerable(page("passwordHealth-vulnerable")),
        vulnerable(page("passwordHealth-vulnerable-shown") { panes in
            panes.show(.vulnerable)
            panes.select(item: panes.list.entries.first?.id)
        }),
        cards("passwordHealth-unasked", Dashboard(levels: [0, 3, 0, 2, 9], counts: [.weak: 3],
                                              cards: WatchCard.allCases)),
        twoFactor(page("passwordHealth-twofactor")),
        twoFactor(page("passwordHealth-twofactor-shown") { panes in
            panes.show(.twoFactor)
            panes.select(item: panes.list.entries.first?.id)
        }),
        twoFactor(vulnerable(page("passwordHealth-six"))),
    ]

    /// A surface with the list of two-factor sites switched on.
    static func twoFactor(_ surface: Surface) -> Surface {
        var surface = surface
        surface.asksTwoFactor = true
        return surface
    }

    /// A surface with the breach check's switch on.
    static func vulnerable(_ surface: Surface) -> Surface {
        var surface = surface
        surface.asksBreaches = true
        return surface
    }
}
