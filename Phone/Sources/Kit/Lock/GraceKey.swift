import Foundation

/// A second copy of the user key, with no face on it, for the minutes after
/// a face that a person chose to let AutoFill fill without another (PH-25).
/// It is readable only while the phone is unlocked, carries the moment it
/// stops, and is deleted when it is found past that, at every lock by hand
/// and when the phone locks. Off unless chosen.
struct GraceKey: Sendable {
    let keychain: Keychain

    static let app = GraceKey(keychain: .app)

    private struct Kept: Codable {
        let key: Data
        let until: Date
    }

    func keep(_ key: VaultKey, minutes: Int, now: Date = .now) {
        guard minutes > 0, let data = try? JSONEncoder().encode(Kept(key: key.bytes, until: now.addingTimeInterval(Double(minutes) * 60)))
        else { return forget() }
        try? keychain.write(data, as: "graceKey", protection: .whileUnlocked)
    }

    /// The key while its minutes last; nil and deleted after them.
    func take(now: Date = .now) -> VaultKey? {
        guard let data = try? keychain.read("graceKey"), let kept = try? JSONDecoder().decode(Kept.self, from: data) else { return nil }
        guard now < kept.until, let key = try? VaultKey(kept.key) else {
            forget()
            return nil
        }
        return key
    }

    func forget() {
        keychain.delete("graceKey")
    }
}
