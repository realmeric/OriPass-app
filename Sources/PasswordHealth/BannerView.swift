import SwiftUI

/// The line over an item's details when it is on one of Password Health's lists:
/// a warning mark, one sentence, and at the right the one button that does
/// something about it, if there is one. The ground is the faint red of a
/// card that has something on it.
struct BannerView: View {
    let banner: Banner
    var perform: (Banner.Act) -> Void = { _ in }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous)
        HStack(alignment: .center, spacing: Metrics.close) {
            Glyph.warning.image
                .font(Fonts.disclosure)
                .foregroundStyle(Palette.red)
                .accessibilityHidden(true)
            Text(banner.sentence)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.gap)
            if let act = banner.act {
                Button(act.name) { perform(act) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        // As tall with no button as with one.
        .frame(minHeight: Metrics.buttonHeight)
        .padding(.horizontal, Metrics.gap)
        .padding(.vertical, Metrics.close)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.red.opacity(Palette.wash)))
        .overlay(shape.strokeBorder(Palette.red.opacity(Palette.drawing), lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
    }
}

extension Surface {
    private static func banner(_ name: String, of title: String,
                               _ arrange: @escaping @MainActor (Panes) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(item: store.shelves.all.first { $0.item.name == title }?.id)
            arrange(panes)
            return AnyView(PanesView(panes: panes))
        }
    }

    /// One banner for each of the four lists; an address in the clear with
    /// a weak password, which has two, the more serious first; and the form
    /// that "Use https" opens, with the address changed and not saved. And
    /// with the breach check on, a password that has been seen and is weak,
    /// and with the two-factor list on, a login the site would give a code.
    static let banners: [Surface] = [
        banner("banner-reused", of: "Trendyol"),
        banner("banner-weak", of: "Çiçeksepeti"),
        banner("banner-expiring", of: "Bonus Kart"),
        banner("banner-two", of: "Eski forum"),
        banner("banner-secured", of: "Eski forum") { $0.perform(banner: .secure) },
        vulnerable(banner("banner-vulnerable", of: "Yemeksepeti")),
        twoFactor(banner("banner-twofactor", of: "Google")),
    ]
}
