import AppKit
import SwiftUI

/// Site icons for the demo vault, drawn here, since a demo asks nobody. Some
/// of the demo's hosts have one and the rest have none, so a list of it
/// shows both what an icon looks like and what a missing one does.
enum DemoIcons {
    /// The demo logins whose sites have an icon.
    static let hosts: Set<String> = [
        "github.com", "www.isbank.com.tr", "accounts.google.com", "account.apple.com", "accounts.spotify.com",
        "www.figma.com", "linear.app", "vercel.com", "slack.com", "www.notion.so", "cloud.digitalocean.com",
        "dash.cloudflare.com", "www.trendyol.com", "www.garantibbva.com.tr",
    ]

    /// A store for the demo: the fetcher below, no files.
    @MainActor
    static func store() -> IconStore {
        IconStore(fetcher: Fetcher(), directory: nil)
    }

    /// A store with every demo icon already in memory, for a shot.
    @MainActor
    static func seeded() -> IconStore {
        let store = IconStore(fetcher: nil, directory: nil)
        store.seed(Dictionary(uniqueKeysWithValues: hosts.compactMap { host in png(for: host).map { (host, $0) } }))
        return store
    }

    struct Fetcher: IconFetcher {
        func fetch(host: String) async -> IconAnswer {
            guard hosts.contains(host) else { return .none }
            return await MainActor.run { png(for: host).map(IconAnswer.image) ?? .failed }
        }
    }

    /// A ring on a colour taken from the host: nothing like a lettered tile.
    @MainActor
    static func png(for host: String) -> Data? {
        let renderer = ImageRenderer(content: Art(host: host).frame(width: Metrics.listIcon, height: Metrics.listIcon))
        renderer.scale = 3
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private struct Art: View {
        let host: String

        var body: some View {
            GeometryReader { box in
                let side = min(box.size.width, box.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: side * Metrics.iconCorner, style: .continuous)
                        .fill(Palette.hue(for: host))
                    Circle()
                        .strokeBorder(Palette.onColour, lineWidth: side * 0.12)
                        .frame(width: side * 0.5, height: side * 0.5)
                }
            }
        }
    }
}
