import SwiftUI

/// One item as a row: its icon, its name, and its second line.
struct ItemRow: View {
    let item: Item
    let server: Server?
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        HStack(spacing: 12) {
            ItemIcon(item: item, server: server)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.isEmpty ? String(localized: "Untitled") : item.name)
                    .lineLimit(size.isAccessibilitySize ? 4 : 1)
                if let line = item.secondLine {
                    Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(size.isAccessibilitySize ? 4 : 1)
                }
            }
        }
    }
}

/// A site's icon, or a tile with the name's first letter, or the type's mark.
struct ItemIcon: View {
    let item: Item
    let server: Server?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
                    .background(.white, in: .rect(cornerRadius: 8))
            } else if item.kind == .login, let letter = item.name.first {
                Text(String(letter).uppercased())
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: item.hue, saturation: 0.5, brightness: 0.7), in: .rect(cornerRadius: 8))
            } else {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(item.kind.tint, in: .rect(cornerRadius: 8))
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
        .task(id: item.iconHost) {
            guard let host = item.iconHost, let server else { return }
            image = await IconStore.shared.icon(for: host, server: server)
        }
    }
}

extension Item {
    /// What a row says under the name: a login's username, a card's brand
    /// and last four, an identity's name, a note's first line.
    var secondLine: String? {
        switch kind {
        case .login: return login?.username
        case .card:
            let last = value("number").map { "•••• " + $0.suffix(4) }
            return [value("brand"), last].compactMap { $0 }.joined(separator: " ").nonEmpty
        case .identity: return [value("firstName"), value("lastName")].compactMap { $0 }.joined(separator: " ").nonEmpty
        case .note: return notes?.split(separator: "\n").first.map(String.init)
        case .sshKey: return value("keyFingerprint")
        case .unknown: return nil
        }
    }

    /// A tile's colour, the same for the same name every time.
    var hue: Double {
        Double(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 360) / 360
    }
}

extension Item.Kind {
    var symbol: String {
        switch self {
        case .login: "key.fill"
        case .note: "note.text"
        case .card: "creditcard.fill"
        case .identity: "person.text.rectangle.fill"
        case .sshKey: "terminal.fill"
        case .unknown: "questionmark.square.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .login: .blue
        case .note: .yellow
        case .card: .green
        case .identity: .indigo
        case .sshKey: .gray
        case .unknown: .secondary
        }
    }

    var plural: String {
        switch self {
        case .login: String(localized: "Logins")
        case .note: String(localized: "Secure Notes")
        case .card: String(localized: "Credit Cards")
        case .identity: String(localized: "Identities")
        case .sshKey: String(localized: "SSH Keys")
        case .unknown: String(localized: "Other")
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Item.Kind: Identifiable {
    public var id: Self { self }
}
