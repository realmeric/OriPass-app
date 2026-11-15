import Foundation

/// A master password on its way to the engine or to its seal. A class, so
/// there is one copy and `wipe()` reaches it whoever is holding it, and its
/// own allocation, so that copy is overwritten with zeros where it lies: an
/// array or a `Data` would quietly move to a fresh buffer the moment a second
/// reference existed, and the zeros would land in the wrong one (D6).
///
/// What is typed arrives as a `String`, and that copy is the system's to
/// free. This is everything after it.
final class SecretBytes: Redacted {
    private var storage: UnsafeMutableRawBufferPointer
    private(set) var count = 0

    init(capacity: Int = 64) {
        storage = .allocate(byteCount: max(capacity, 16), alignment: 1)
    }

    convenience init(_ string: String) {
        self.init(capacity: string.utf8.count)
        append(string)
    }

    convenience init(_ data: Data) {
        self.init(capacity: data.count)
        data.withUnsafeBytes { append($0) }
    }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count > 0 else { return }
        if count + bytes.count > storage.count {
            let grown = UnsafeMutableRawBufferPointer.allocate(
                byteCount: max(storage.count * 2, count + bytes.count), alignment: 1
            )
            grown.copyMemory(from: UnsafeRawBufferPointer(rebasing: storage[..<count]))
            release()
            storage = grown
        }
        UnsafeMutableRawBufferPointer(rebasing: storage[count...]).copyMemory(from: bytes)
        count += bytes.count
    }

    func append(_ string: String) {
        var string = string
        string.withUTF8 { append(UnsafeRawBufferPointer($0)) }
    }

    func append(_ other: SecretBytes) {
        other.withBytes(append)
    }

    func withBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(rebasing: storage[..<count]))
    }

    func withMutableBytes<Result>(_ body: (UnsafeMutableRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeMutableRawBufferPointer(rebasing: storage[..<count]))
    }

    /// Zeros over every byte. The length stays, so a wiped secret can still
    /// be told from an empty one.
    func wipe() {
        // Not `memset`, which the optimiser may drop before a free.
        memset_s(storage.baseAddress, storage.count, 0, storage.count)
    }

    var isWiped: Bool { withBytes { $0.allSatisfy { $0 == 0 } } }

    /// A second one with the same bytes, for whoever has to keep the
    /// password past the call that wipes it. Each is wiped by its holder.
    func copy() -> SecretBytes {
        let copy = SecretBytes(capacity: count)
        copy.append(self)
        return copy
    }

    func matches(_ other: SecretBytes) -> Bool {
        withBytes { mine in other.withBytes { mine.elementsEqual($0) } }
    }

    /// The bytes as a JSON string, quotes included, for the one request that
    /// carries a password.
    func jsonString() -> SecretBytes {
        let out = SecretBytes(capacity: count + 16)
        out.append("\"")
        withBytes { bytes in
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"):
                    out.append("\\")
                    withUnsafeBytes(of: byte) { out.append($0) }
                case 0..<0x20:
                    out.append(String(format: "\\u%04x", byte))
                default:
                    withUnsafeBytes(of: byte) { out.append($0) }
                }
            }
        }
        out.append("\"")
        return out
    }

    private func release() {
        wipe()
        storage.deallocate()
    }

    deinit { release() }

    var redactedLabel: String { "SecretBytes(\(count))" }
}
