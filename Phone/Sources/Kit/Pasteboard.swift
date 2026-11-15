import UIKit
import UniformTypeIdentifiers

/// The one way a value reaches the pasteboard: on this phone only, gone
/// after ninety seconds, and marked concealed for any clipboard manager on
/// a Mac that honours the mark.
enum Pasteboard {
    static let lifetime: TimeInterval = 90

    /// Where a copy goes: the system's pasteboard, or a test's.
    nonisolated(unsafe) static var writer: (_ items: [[String: Any]], _ options: [UIPasteboard.OptionsKey: Any]) -> Void = {
        UIPasteboard.general.setItems($0, options: $1)
    }

    static func copy(_ value: String) {
        writer([[UTType.plainText.identifier: value, "org.nspasteboard.ConcealedType": value]],
               [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: lifetime)])
    }
}
