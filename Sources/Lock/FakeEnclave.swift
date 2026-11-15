import Foundation
import LocalAuthentication

/// An enclave with no sensor, for every test and for the canary's tour. It
/// keeps its keys in memory, counts what it is asked, and can be told that
/// the sheet was cancelled or that another fingerprint was enrolled.
///
/// What it seals is hidden for real, under a pad as long as the secret that
/// never leaves this object, so a search of the files for the password means
/// something against the fake too.
final class FakeEnclave: Enclave {
    enum Refusal: Error {
        case cancelled
        /// The key was made under another set of fingerprints, or was never
        /// made here at all.
        case keyGone
        case tampered
    }

    var hasFinger = true
    /// The next sheets are cancelled.
    var cancels = false
    /// The next sheets stay up until they are told to go, as a real one does
    /// with nobody at the sensor.
    var holds = false
    /// The reason of every sheet that would have been raised.
    private(set) var asked: [String] = []
    /// The context each of those was asked for on, nil for the sheet.
    private(set) var contexts: [LAContext?] = []
    /// How many times a sheet was told to go.
    private(set) var withdrawn = 0

    private var enrolled = 0

    var fingerprints: Data? { hasFinger ? Data("set \(enrolled)".utf8) : nil }
    private var keys: [Data: (pad: [UInt8], plain: Data, fingerprints: Int)] = [:]

    /// What `biometryCurrentSet` does to every key made before it.
    func enrolAnotherFinger() {
        enrolled += 1
    }

    func seal(_ secret: SecretBytes, beside plain: Data) throws -> EnclaveSeal {
        let pad = (0..<secret.count).map { _ in UInt8.random(in: .min ... .max) }
        let key = Self.random(24)
        keys[key] = (pad, plain, enrolled)
        let box = secret.withBytes { bytes in Data(zip(bytes, pad).map { $0 ^ $1 }) }
        return EnclaveSeal(key: key, encapsulated: Self.random(65), box: box)
    }

    func open(_ sealed: EnclaveSeal, beside plain: Data, reason: String, on context: LAContext?) throws -> SecretBytes {
        asked.append(reason)
        contexts.append(context)
        if cancels { throw Refusal.cancelled }
        if holds {
            let told = withdrawn
            while withdrawn == told { Thread.sleep(forTimeInterval: 0.005) }
            throw Refusal.cancelled
        }
        guard let kept = keys[sealed.key], kept.fingerprints == enrolled else {
            throw Refusal.keyGone
        }
        guard kept.plain == plain, kept.pad.count == sealed.box.count else {
            throw Refusal.tampered
        }
        return SecretBytes(Data(zip(sealed.box, kept.pad).map { $0 ^ $1 }))
    }

    func withdraw() {
        withdrawn += 1
    }

    private static func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
}
