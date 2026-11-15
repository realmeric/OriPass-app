import UIKit
import XCTest
@testable import OriPass

final class PasteboardTests: XCTestCase {
    func testACopyStaysOnThisPhoneAndGoesInNinetySeconds() {
        var written: ([[String: Any]], [UIPasteboard.OptionsKey: Any])?
        let real = Pasteboard.writer
        Pasteboard.writer = { written = ($0, $1) }
        defer { Pasteboard.writer = real }
        Pasteboard.copy("kanarya-pass-1-Xr8")
        let (items, options) = try! XCTUnwrap(written)
        XCTAssertEqual(items.first?["public.plain-text"] as? String, "kanarya-pass-1-Xr8")
        XCTAssertNotNil(items.first?["org.nspasteboard.ConcealedType"])
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        let expiry = try! XCTUnwrap(options[.expirationDate] as? Date)
        XCTAssertEqual(expiry.timeIntervalSinceNow, 90, accuracy: 2)
    }
}
