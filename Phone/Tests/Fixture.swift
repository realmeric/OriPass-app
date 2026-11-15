import Foundation

/// A file under Tests/Fixtures, read from the test bundle.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle(for: Marker.self).url(forResource: name, withExtension: nil)!
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }

    private final class Marker {}
}

extension Data {
    init(hex: String) {
        let digits = Array(hex.filter(\.isHexDigit))
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    init(b64: Any?) {
        self.init(base64Encoded: b64 as! String)!
    }
}
