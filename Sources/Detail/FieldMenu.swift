import SwiftUI

/// Where the chevron of the row whose menu is open stands, so the menu can
/// be drawn over the whole window and still hang from it.
struct FieldMenuAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A row's menu, drawn by the app as the list's two are: a card under the
/// chevron with its right edge on the row's, or over the chevron when the
/// window ends too soon under it. A click anywhere else puts it away.
struct FieldMenuLayer: View {
    let panes: Panes
    @ObservedObject var reading: Reading
    let anchor: Anchor<CGRect>?

    var body: some View {
        if let menu = reading.menu {
            GeometryReader { window in
                ZStack(alignment: .topLeading) {
                    Palette.content.opacity(0)
                        .contentShape(Rectangle())
                        .onTapGesture { reading.menu = nil }
                        .accessibilityHidden(true)
                    if let anchor {
                        let chevron = window[anchor]
                        let height = FieldMenuCard.height(of: menu)
                        let under = chevron.maxY + Metrics.tight
                        let fits = under + height + Metrics.close <= window.size.height
                        FieldMenuCard(menu: menu, highlight: { reading.menu?.highlighted = $0 },
                                      choose: { panes.perform($0, on: menu.row) })
                            .offset(x: chevron.maxX - Metrics.menuWidth,
                                    y: fits ? under : chevron.minY - Metrics.tight - height)
                    }
                }
            }
        }
    }
}

struct FieldMenuCard: View {
    let menu: FieldMenu
    let highlight: (FieldAction?) -> Void
    let choose: (FieldAction) -> Void

    static func height(of menu: FieldMenu) -> CGFloat {
        Metrics.menuRow * CGFloat(menu.actions.count) + Metrics.close + Metrics.close
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(menu.actions, id: \.name) { action in
                row(action)
            }
        }
        .padding(.vertical, Metrics.close)
        .frame(width: Metrics.menuWidth)
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
    }

    /// The row under the pointer is filled with the accent, as its still
    /// has it, and not with the grey the list's menus use.
    private func row(_ action: FieldAction) -> some View {
        let isLit = menu.highlighted == action
        return Button { choose(action) } label: {
            Text(action.name)
                .font(Fonts.body)
                .foregroundStyle(isLit ? Palette.onColour : Palette.text)
                .padding(.horizontal, Metrics.close)
                .frame(maxWidth: .infinity, minHeight: Metrics.menuRow, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(isLit ? Palette.lit : Palette.lit.opacity(0))
                )
                .padding(.horizontal, Metrics.close)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { highlight($0 ? action : nil) }
        .accessibilityLabel(action.name)
    }
}
