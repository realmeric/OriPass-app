import SwiftUI

/// The sheet behind ⌘/: every key the app answers to, under four headings,
/// each with its keys drawn as caps at the right. It is handed the rows of
/// `KeyTable` that work and draws nothing else, so a key waiting for its
/// card is not on it. Esc, ⌘/ again or a click beside it puts it away.
struct KeySheet: View {
    let commands: [KeyCommand]
    var close: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ZStack {
            Palette.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Metrics.gap)
                    Button(action: close) {
                        Glyph.close.image
                            .font(Fonts.disclosure)
                            .foregroundStyle(Palette.secondText)
                            .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.leading, Metrics.loose)
                .padding(.trailing, Metrics.gap)
                .frame(height: Metrics.toolbarHeight)
                Hairline(.horizontal)
                // Whole when the window is tall enough for it, and under a
                // scroll when it is not.
                ViewThatFits(in: .vertical) {
                    columns
                    ScrollView { columns }
                }
            }
            .frame(width: Metrics.keySheetWidth)
            .background(shape.fill(Palette.content))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .clipShape(shape)
            // Clear of the traffic lights, which stand over the scrim.
            .padding(.top, Metrics.toolbarHeight)
            .padding([.horizontal, .bottom], Metrics.loose)
        }
        .ignoresSafeArea()
    }

    /// The window's keys and the app's at the left, which are half of them,
    /// and at the right the ones that move about and act on an item.
    private var columns: some View {
        HStack(alignment: .top, spacing: Metrics.apart) {
            column([.window, .anywhere])
            column([.moving, .item])
        }
        .padding(.horizontal, Metrics.loose)
        .padding(.top, Metrics.close)
        .padding(.bottom, Metrics.wide)
    }

    private func column(_ sections: [KeyCommand.Section]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.self) { section in
                let rows = commands.filter { $0.section == section }
                if !rows.isEmpty {
                    Text(section.rawValue.uppercased())
                        .font(Fonts.heading)
                        .tracking(Metrics.headingTracking)
                        .foregroundStyle(Palette.secondText)
                        .frame(height: Metrics.sidebarRow, alignment: .bottom)
                        .padding(.bottom, Metrics.tight)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(rows) { KeyRow(command: $0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a key does, and the key.
private struct KeyRow: View {
    let command: KeyCommand

    var body: some View {
        HStack(spacing: Metrics.close) {
            Text(command.name)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: Metrics.close)
            if command.isRun, let first = command.strokes.first, let last = command.strokes.last {
                caps(first)
                Text("to").font(Fonts.caption).foregroundStyle(Palette.secondText)
                caps(last)
            } else {
                ForEach(command.strokes, id: \.self, content: caps)
            }
        }
        .frame(height: Metrics.keyRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.name)
        .accessibilityValue(said)
        .accessibilityAddTraits(.isStaticText)
    }

    private var said: String {
        let strokes = command.isRun ? [command.strokes.first, command.strokes.last].compactMap { $0 }
            : command.strokes
        return strokes.map(\.symbols).joined(separator: command.isRun ? " to " : ", ")
    }

    /// One press: a cap for each thing held and one for the key.
    private func caps(_ stroke: Stroke) -> some View {
        HStack(spacing: Metrics.hair) {
            ForEach(stroke.caps, id: \.self) { cap in
                let shape = RoundedRectangle(cornerRadius: Metrics.keycapRadius, style: .continuous)
                Text(cap)
                    .font(Fonts.keycap)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, Metrics.tight + Metrics.hair)
                    .frame(minWidth: Metrics.keycap, minHeight: Metrics.keycap)
                    .background(shape.fill(Palette.field))
                    .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            }
        }
    }
}

/// The sheet over the panes while ⌘/ has it up.
struct KeySheetLayer: View {
    @ObservedObject var panes: Panes

    var body: some View {
        if panes.showsKeys {
            KeySheet(commands: panes.keyCommands) { panes.showsKeys = false }
                .transition(Motion.transition(.fade))
        }
    }
}

extension Surface {
    private static func keys(_ name: String, size: CGSize = Metrics.windowSize, zoom: Zoom = .actual,
                             _ arrange: @escaping @MainActor (Panes) -> Void) -> Surface {
        var surface = Surface(name: name, size: size) { store in
            let panes = Panes(store: store)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
        surface.zoom = zoom
        return surface
    }

    @MainActor
    private static func choose(_ title: String, in panes: Panes) {
        if let entry = panes.list.entries.first(where: { $0.item.name == title }) { panes.select(item: entry.id) }
    }

    /// The sheet, whole and in the smallest window. The ring on each of the
    /// three columns as the arrows reach it. The chevrons with somewhere to
    /// go back to. The window at the other two sizes.
    static let keys: [Surface] = [
        keys("keys-sheet") { $0.toggleKeys() },
        keys("keys-sheet-minimum", size: Metrics.windowMinimum) { $0.toggleKeys() },
        keys("keys-sidebar") { panes in
            choose("GitHub", in: panes)
            panes.press(.left)
            panes.press(.down)
        },
        keys("keys-list") { panes in
            choose("GitHub", in: panes)
            panes.press(.down)
        },
        keys("keys-details") { panes in
            choose("GitHub", in: panes)
            panes.press(.right)
            panes.press(.down)
        },
        keys("keys-back") { panes in
            choose("GitHub", in: panes)
            panes.selectVault(at: 0)
            panes.goBack()
        },
        keys("zoom-small", zoom: .small) { choose("GitHub", in: $0) },
        keys("zoom-large", zoom: .large) { choose("GitHub", in: $0) },
    ]
}
