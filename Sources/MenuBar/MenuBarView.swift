import SwiftUI

/// The menu the mark drops, drawn for a shot. The real one is the system's
/// and no window of this app can be asked to draw it off screen, so this is
/// made from the same rows (`MarkMenu.rows`) and shows what is in it,
/// in what order and with which key, and not how the system draws a menu.
struct MenuBarCard: View {
    let rows: [MarkMenu.Row]
    /// The row the pointer is on. The still has Open Quick Access lit.
    let lit: MarkMenu.Command?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.statusMenuRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.command == nil {
                    Rectangle().fill(Palette.outline)
                        .frame(height: Metrics.hairline)
                        .frame(height: Metrics.statusMenuRule)
                } else {
                    line(row)
                }
            }
        }
        .padding(.vertical, Metrics.statusMenuPad)
        .frame(width: Metrics.statusMenuWidth)
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
        .accessibilityElement(children: .contain)
    }

    private func line(_ row: MarkMenu.Row) -> some View {
        let isLit = row.command == lit
        return HStack(spacing: Metrics.close) {
            Text(row.title)
            Spacer(minLength: Metrics.close)
            if !row.caps.isEmpty { Text(row.caps.joined(separator: " ")) }
        }
        .font(Fonts.body)
        .foregroundStyle(isLit ? Palette.onColour : Palette.text)
        .opacity(row.isEnabled ? 1 : Palette.disabled)
        .padding(.horizontal, Metrics.close)
        .frame(height: Metrics.statusMenuRow)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(isLit ? Palette.lit : Palette.lit.opacity(0))
        )
        .padding(.horizontal, Metrics.tight)
        .accessibilityElement(children: .combine)
    }
}

/// The corner of the menu bar the mark stands in, and its menu open under
/// it, with the mark lit as it is while its menu is out.
struct MenuBarShot: View {
    let rows: [MarkMenu.Row]

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.tight) {
            ZStack(alignment: .trailing) {
                Palette.statusBar
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(Palette.statusLit)
                    .frame(width: Metrics.statusBarMark.width, height: Metrics.statusBarMark.height)
                    .padding(.trailing, Metrics.close)
                AppMark()
                    .fill(Palette.text, style: AppMark.fill)
                    .frame(width: Metrics.menuBarMark, height: Metrics.menuBarMark)
                    .padding(.trailing, Metrics.close + (Metrics.statusBarMark.width - Metrics.menuBarMark) / 2)
            }
            .frame(height: Metrics.statusBarHeight)
            MenuBarCard(rows: rows, lit: .openQuick)
                .padding(.trailing, Metrics.close)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.content)
    }
}

extension Surface {
    /// The menu, as the first of its two kinds of click opens it: signed in,
    /// so that Lock is not grey.
    static let menuBars: [Surface] = [
        Surface(name: "menu-bar", size: Metrics.statusMenuShot, isBare: true) { store in
            let door = Door(store: store)
            let quick = QuickAccess(door: door, present: { _ in })
            defer { quick.end() }
            let menu = MarkMenu(door: door, quick: quick, lock: LockCommands(door: door), showApp: {},
                                   showSettings: {}, quickKey: { HotKeyAction.quickAccess.fallback })
            return AnyView(MenuBarShot(rows: menu.rows()))
        },
        Surface(name: "menu-bar-passes", size: Metrics.statusMenuPassShot, isBare: true) { store in
            let door = Door(store: store)
            door.passes.fingers = { Data() }
            AgentPass.demo(door.passes)
            let quick = QuickAccess(door: door, present: { _ in })
            defer { quick.end() }
            let menu = MarkMenu(door: door, quick: quick, lock: LockCommands(door: door), showApp: {},
                                   showSettings: {}, quickKey: { HotKeyAction.quickAccess.fallback })
            return AnyView(MenuBarShot(rows: menu.rows()))
        },
    ]
}
