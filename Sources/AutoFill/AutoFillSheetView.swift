import SwiftUI

/// The sheet: the logins, passkeys or codes under who asked, or a lock and what to do about it,
/// and Cancel. With nothing named by the system a field stands over all of it
/// and has the keys. Return takes the first row, as a list of one mostly is.
struct AutoFillSheetView: View {
    @ObservedObject var sheet: AutoFillSheet
    @FocusState private var fieldHasKeys: Bool

    var body: some View {
        VStack(spacing: Metrics.gap) {
            if sheet.showsField { field }
            if sheet.rows.isEmpty {
                Spacer(minLength: 0)
                standing
                Spacer(minLength: 0)
            } else {
                Text(verbatim: sheet.statement)
                    .font(Fonts.statement)
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    VStack(spacing: Metrics.hair) {
                        ForEach(sheet.rows) { row(for: $0) }
                    }
                }
            }
            if let refusal = sheet.refusal {
                Text(verbatim: refusal)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", action: sheet.cancel)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.loose)
        .frame(width: Metrics.autoFillSheet.width, height: Metrics.autoFillSheet.height)
        .background(Palette.content)
    }

    private var field: some View {
        HStack(spacing: Metrics.gap) {
            Glyph.search.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
                .accessibilityHidden(true)
            TextField("", text: $sheet.word,
                      prompt: Text("Find a login").foregroundStyle(Palette.prompt))
                .textFieldStyle(.plain)
                .font(Fonts.rowTitle)
                .foregroundStyle(Palette.text)
                .focused($fieldHasKeys)
                .accessibilityLabel("Find a login")
                .disabled(sheet.isFilling)
                .onSubmit(sheet.chooseFirst)
                .onAppear { fieldHasKeys = true }
        }
        .padding(Metrics.gap)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Palette.field))
    }

    /// Under the field it is a line: nothing here is locked.
    private var standing: some View {
        VStack(spacing: Metrics.close) {
            if !sheet.showsField {
                Glyph.lock.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
            }
            Text(verbatim: sheet.statement)
                .font(sheet.showsField ? Fonts.sentence : Fonts.statement)
                .foregroundStyle(sheet.showsField ? Palette.secondText : Palette.text)
            if let sentence = sheet.sentence {
                Text(verbatim: sentence)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func row(for row: SheetRow) -> some View {
        let isFirst = row.id == sheet.rows.first?.id
        Button { sheet.choose(row) } label: {
            VStack(alignment: .leading, spacing: Metrics.hair) {
                Text(verbatim: row.title)
                    .font(Fonts.rowTitle)
                    .foregroundStyle(Palette.text)
                if let username = row.username {
                    Text(verbatim: username)
                        .font(Fonts.rowSecond)
                        .foregroundStyle(Palette.secondText)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Metrics.listRow, alignment: .leading)
            .padding(.horizontal, Metrics.gap)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(sheet.state == .filling(id: row.id) ? Palette.listSelection : Palette.cell)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isFirst ? KeyboardShortcut.defaultAction : nil)
        .disabled(sheet.state != .listed)
    }
}
