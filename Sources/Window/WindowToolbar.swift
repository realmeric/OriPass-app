import SwiftUI

/// The strip across the top of the list and the details: back and forward,
/// the search field, and the window's one filled button. It is drawn by the
/// app and is not an `NSToolbar`, because it stops at the sidebar's edge.
///
/// The field is the search: what is typed into it is `Panes.query`, and the
/// item list shows what that finds. The chevrons walk `Panes.history`, and
/// the button raises the sheet of kinds (`NewItemSheet`).
struct WindowToolbar: View {
    @ObservedObject var panes: Panes
    /// Whose vault the field says it searches.
    var account: String?
    @FocusState private var fieldHasKeys: Bool
    /// With the sidebar folded the traffic lights are over this strip, and it
    /// starts to their right.
    var clearsTrafficLights = false

    var body: some View {
        HStack(spacing: Metrics.gap) {
            HStack(spacing: Metrics.tight) {
                chevron(.back, "Back", isOn: panes.canGoBack) { panes.goBack() }
                chevron(.forward, "Forward", isOn: panes.canGoForward) { panes.goForward() }
            }
            searchField
            Button { panes.beginNew() } label: {
                HStack(spacing: Metrics.tight) {
                    Glyph.add.image.font(Fonts.action)
                    Text("New Item")
                }
            }
            .buttonStyle(FilledButtonStyle())
        }
        .padding(.leading, clearsTrafficLights ? Metrics.trafficLights : Metrics.gap)
        .padding(.trailing, Metrics.gap)
        .frame(height: Metrics.toolbarHeight)
        .overlay(alignment: .bottom) { Hairline(.horizontal) }
    }

    /// A mid grey with somewhere to go and a faint one without, as the
    /// overview still has back and forward.
    private func chevron(_ glyph: Glyph, _ name: String, isOn: Bool, go: @escaping () -> Void) -> some View {
        Button(action: go) {
            glyph.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(isOn ? Palette.secondText : Palette.faintText)
                .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn)
        .accessibilityLabel(name)
    }

    /// A magnifier, what is typed, and a round cross once something is.
    /// With the keys it wears the accent's ring, as its still has it.
    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        return HStack(spacing: Metrics.close) {
            Glyph.search.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
                .accessibilityHidden(true)
            TextField("", text: $panes.query,
                      prompt: Text(account.map { "Search in \($0)" } ?? "Search").foregroundStyle(Palette.prompt))
                .textFieldStyle(.plain)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .focused($fieldHasKeys)
                .onExitCommand(perform: panes.endSearch)
                .onSubmit(panes.submitSearch)
                .onKeyPress(.downArrow) {
                    panes.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    panes.moveSelection(by: -1)
                    return .handled
                }
                .accessibilityLabel("Search")
            if !panes.query.isEmpty {
                Button(action: panes.endSearch) {
                    Glyph.clear.image
                        .font(Fonts.toolbarGlyph)
                        .foregroundStyle(Palette.faintText)
                        .frame(width: Metrics.sidebarMark, height: Metrics.sidebarMark)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.leading, Metrics.close)
        .padding(.trailing, panes.query.isEmpty ? Metrics.close : Metrics.tight)
        .frame(height: Metrics.searchHeight)
        .frame(maxWidth: .infinity)
        .background(shape.fill(Palette.searchField))
        .overlay(shape.strokeBorder(panes.searchHasKeys ? Palette.accent : Palette.outline,
                                    lineWidth: Metrics.hairline))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.controlRadius + Metrics.focusRing, style: .continuous)
                .strokeBorder(Palette.focusRing, lineWidth: Metrics.focusRing)
                .padding(-Metrics.focusRing)
                .opacity(panes.searchHasKeys ? 1 : 0)
        )
        .onChange(of: panes.keysToSearch) { fieldHasKeys = true }
        .onChange(of: fieldHasKeys) { _, has in panes.searchHasKeys = has }
    }
}
