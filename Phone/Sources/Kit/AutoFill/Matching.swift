import AuthenticationServices
import Foundation

/// Which logins belong to the page or the app AutoFill was asked from, by
/// Bitwarden's six rules for a login's address: 0 the same site (the
/// default), 1 the same host and port, 2 the page starting with it, 3 the
/// same address, 4 a regular expression, 5 never.
struct Matching: Sendable {
    let pages: [Page]

    struct Page: Sendable {
        var url: URL?
        var host: String?
        var app: String?
    }

    init(_ services: [ASCredentialServiceIdentifier]) {
        pages = services.map(Matching.page)
    }

    init(pages: [Page]) {
        self.pages = pages
    }

    static func page(_ service: ASCredentialServiceIdentifier) -> Page {
        if #available(iOS 26.2, *), service.type == .app { return Page(app: service.identifier.lowercased()) }
        let written = service.identifier.contains("://") ? service.identifier : "https://" + service.identifier
        let url = URL(string: written)
        return Page(url: service.type == .URL ? url : nil, host: url?.host()?.lowercased())
    }

    func matches(_ summary: Summary) -> Bool {
        summary.uris.contains { uri in pages.contains { Matching.holds(uri, for: $0) } }
    }

    static func holds(_ uri: Item.Uri, for page: Page) -> Bool {
        let written = uri.uri.trimmingCharacters(in: .whitespaces)
        if let app = page.app {
            return written.lowercased() == "iosapp://" + app
        }
        guard let pageHost = page.host, !written.lowercased().hasPrefix("iosapp://"),
              !written.lowercased().hasPrefix("androidapp://") else { return false }
        if uri.match == 4 {
            guard let expression = try? Regex(written).ignoresCase() else { return false }
            return (page.url?.absoluteString ?? "https://" + pageHost).contains(expression)
        }
        let full = written.contains("://") ? written : "https://" + written
        guard let own = URL(string: full), let ownHost = own.host()?.lowercased() else { return false }
        switch uri.match ?? 0 {
        case 1:
            return ownHost == pageHost && (page.url == nil || own.port == page.url?.port)
        case 2:
            guard let page = page.url?.absoluteString else { return ownHost == pageHost }
            return page.hasPrefix(full)
        case 3:
            guard let page = page.url?.absoluteString else { return ownHost == pageHost }
            return page == full
        case 5:
            return false
        default:
            return site(of: ownHost) == site(of: pageHost)
        }
    }

    /// The registrable part of a host, or the host itself for one the list
    /// does not know: localhost, an address, a name on a private network.
    static func site(of host: String) -> String {
        PublicSuffix.standard.site(of: host) ?? host
    }
}
