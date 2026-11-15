import SwiftUI

/// The item's files (`docs/look.md`, "Attachments"): under the custom
/// fields and standing free as they do, a paperclip, the file's name and its
/// size under it in grey. Under the pointer a row is a field's row with
/// "Open" where "Copy" would be, and its chevron drops Quick Look and Save
/// As. What the engine said when it would not hand a file over is where the
/// size was, in red, and a file on its way in is one more row at the foot.
struct AttachmentRows: View {
    let panes: Panes
    @ObservedObject var reading: Reading
    let files: [ItemDetail.File]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
                AttachmentRow(name: file.name, size: file.size, refusal: reading.unfetched[file.id],
                              isFetching: reading.fetching.contains(file.id), state: state(of: file.id),
                              acts: acts(for: file.id), save: { panes.saveAttachment(file.id) })
                    .id(file.id)
            }
            if let adding = reading.adding {
                AttachmentRow(name: adding.name, size: adding.sentence == nil ? Adding.underWay : nil,
                              refusal: adding.sentence)
            }
        }
    }

    private func state(of row: String) -> RowState {
        RowState(copies: true, hasMenu: true, isUnderPointer: reading.hovered == row,
                 isMenuOpen: reading.menu?.row == row)
    }

    private func acts(for row: String) -> RowActs {
        RowActs(hover: { isOver in
            if isOver {
                reading.hovered = row
            } else if reading.hovered == row {
                reading.hovered = nil
            }
        }, copy: { panes.openAttachment(row) }, menu: { panes.toggleMenu(for: row) })
    }
}

/// One file, as plain values, so a shot can draw any of it. Without acts it
/// is a row that does nothing: the file that is being added.
struct AttachmentRow: View {
    let name: String
    var size: String?
    /// The engine's sentence, in the size's place.
    var refusal: String?
    var isFetching = false
    var state = RowState()
    var acts = RowActs()
    var save: () -> Void = {}

    var body: some View {
        RowChrome(state: state, acts: acts, isFree: true, word: "Open") {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.close) {
                Glyph.attachment.image
                    .font(Fonts.sidebarGlyph)
                    .foregroundStyle(Palette.secondText)
                    .frame(width: Metrics.sidebarMark)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.hair) {
                    Text(name)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let second = refusal ?? size {
                        Text(second)
                            .font(Fonts.rowSecond)
                            .foregroundStyle(refusal == nil ? Palette.secondText : Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("attachment, \(name)")
            .accessibilityValue(spoken)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityAction(named: "Open") {
                if state.copies { acts.copy() }
            }
            .accessibilityAction(.default) {
                if state.copies { acts.copy() }
            }
            .accessibilityAction(named: "Save As") {
                if state.copies { save() }
            }
        } resting: {
            if isFetching {
                Text(Panes.fetching)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.secondText)
                    .lineLimit(1)
            }
        }
    }

    private var spoken: String {
        [refusal ?? size, isFetching ? Panes.fetching : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

extension Surface {
    private static func attachment(_ name: String, _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(item: store.shelves.all.first { !$0.item.attachments.isEmpty }?.id)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The note with two files as it is first drawn; a row under the
    /// pointer with its menu open and Save As under the pointer in turn;
    /// one file being fetched and the other refused to an account without
    /// Premium; and a file the engine would not add, under the two it has.
    static let attachments: [Surface] = [
        attachment("attachment-rows"),
        attachment("attachment-menu") { panes in
            guard let row = panes.detail?.attachments.first?.id else { return }
            panes.reading.hovered = row
            panes.toggleMenu(for: row)
            panes.reading.menu?.highlighted = .saveAs
        },
        attachment("attachment-refused") { panes in
            guard let rows = panes.detail?.attachments.map(\.id), rows.count > 1 else { return }
            panes.reading.fetching = [rows[0]]
            panes.reading.unfetched[rows[1]] = FakeBackend.needsPremium
        },
        attachment("attachment-not-added") { panes in
            panes.reading.adding = Adding(name: "sozlesme.pdf", sentence: FakeBackend.needsPremium)
        },
    ]
}
