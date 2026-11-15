import Foundation

/// Why something did not open. Each case names a cause and carries no value.
enum CryptoError: Error, Equatable {
    /// Text that is no encrypted string of any type.
    case unreadable
    /// A type this app does not read: 7 is the newer COSE format (I8).
    case unsupported(type: Int)
    /// The MAC did not match: the wrong key, or a string that was changed.
    case wrongKey
    /// A key of a length no type uses.
    case badKey
    /// CommonCrypto or Security refused, with its status.
    case failed(Int32)
}
