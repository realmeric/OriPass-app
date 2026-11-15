import Foundation
import LocalAuthentication

/// The user key in the keychain behind a face enrolled now (I4). The app
/// writes it after a password opens the vault; the app and the extension
/// read it to open the vault with no KDF and no network.
struct FaceKey: Sendable {
    let keychain: Keychain
    /// The mark of the faces enrolled now: iOS's, or a test's.
    var faces: @Sendable () -> Data? = FaceKey.enrolled

    static let app = FaceKey(keychain: .app)

    enum Failure: Error, Equatable {
        /// The person cancelled, or chose the password.
        case cancelled
        /// Face ID did not recognise them.
        case failed
        /// No key is kept: never written, or destroyed by a new face or a
        /// passcode turned off. The password is the way in.
        case gone
        /// This phone has no Face ID, or no passcode, or it is locked out.
        case unavailable
    }

    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var isKept: Bool { keychain.holds("userKey") }

    func keep(_ key: VaultKey) throws {
        try keychain.write(key.bytes, as: "userKey", protection: .currentFace)
        forgetMarks()
        if let faces = faces() { try? keychain.write(faces, as: FaceKey.marked) }
    }

    func forget() {
        keychain.delete("userKey")
        forgetMarks()
    }

    private func forgetMarks() {
        for bundle in ["com.meric.oripass.ios", "com.meric.oripass.ios.autofill"] { keychain.delete("faces " + bundle) }
        keychain.delete(FaceKey.marked)
    }

    /// Each bundle's own mark: iOS gives the app and its extension different
    /// marks for the same faces, so each compares its own, and the
    /// extension's is written the first time a face opens the key there.
    static var marked: String { "faces " + (Bundle.main.bundleIdentifier ?? "") }

    /// The mark of the faces enrolled now, which iOS changes when one is
    /// added or removed.
    static func enrolled() -> Data? {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.domainState.biometry.stateHash
    }

    /// Forgets a key kept under other faces than the ones enrolled now, and
    /// says so, before anybody is asked for a face that could not open it.
    func forgetIfFacesChanged() -> Bool {
        guard isKept, let kept = try? keychain.read(FaceKey.marked), let now = faces(), kept != now else { return false }
        forget()
        return true
    }

    /// The face first and the key after it, so that a key the keychain
    /// will no longer give a face that was just accepted is known as gone.
    func open(reason: String) async throws -> VaultKey {
        guard isKept else {
            Trace.note("no key is kept")
            throw Failure.gone
        }
        guard !forgetIfFacesChanged() else {
            Trace.note("the faces changed")
            throw Failure.gone
        }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password")
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            Trace.note("Face ID said \(error.code.rawValue)")
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: throw Failure.cancelled
            case .authenticationFailed: throw Failure.failed
            default: throw Failure.unavailable
            }
        }
        let keychain = keychain
        let data: Data?
        do {
            data = try await Task.detached { try keychain.read("userKey", context: context) }.value
        } catch let error as KeychainError {
            Trace.note("the key was not read: \(error.status)")
            throw error.refused ? Failure.cancelled : Failure.unavailable
        }
        // Not there at all is the one case that is gone; any other refusal
        // leaves the key for the next try.
        guard let data else { throw Failure.gone }
        guard let key = try? VaultKey(data) else {
            forget()
            throw Failure.gone
        }
        if (try? keychain.read(FaceKey.marked)) == nil, let faces = faces() {
            try? keychain.write(faces, as: FaceKey.marked)
        }
        return key
    }
}

extension LAContext: @retroactive @unchecked Sendable {}
