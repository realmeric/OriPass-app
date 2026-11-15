import SwiftUI

/// The question that follows the first unlock by password: whether a finger
/// should open the vault from now on (D7). It is asked once, over the window
/// that has just opened, and it holds nothing of the vault's.
struct FingerOffer: View {
    var answer: (Bool) -> Void = { _ in }

    var body: some View {
        ZStack {
            Palette.scrim.ignoresSafeArea()
            VStack(spacing: Metrics.loose) {
                Glyph.fingerprint.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                VStack(spacing: Metrics.close) {
                    Text("Open \(AppInfo.name) with Touch ID?")
                        .font(Fonts.statement)
                        .foregroundStyle(Palette.text)
                    Text("This Mac keeps the master password, sealed so that only a finger enrolled now opens it. After fourteen days it is deleted and asked for again.")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.gap) {
                    Button("Not Now") { answer(false) }
                        .buttonStyle(QuietButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Use Touch ID") { answer(true) }
                        .buttonStyle(FilledButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Metrics.apart)
            .frame(width: Metrics.offerWidth)
            .background(
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .fill(Palette.content)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
            )
        }
        .ignoresSafeArea()
    }
}

extension Surface {
    static let fingerOffer = Surface(name: "finger-offer", size: Metrics.windowSize) { store in
        AnyView(ZStack {
            PanesView(panes: Panes(store: store))
            FingerOffer()
        })
    }
}
