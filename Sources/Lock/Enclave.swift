import CryptoKit
import Foundation
import LocalAuthentication

/// What `PasswordSeal` needs of the Secure Enclave, and no more, so that a test
/// and the canary's tour can stand a fake behind it: no session can put a
/// finger on the sensor.
///
/// `plain` travels beside the seal in the clear and is bound to it. Opening
/// with different bytes fails.
protocol Enclave {
    /// Whether there is a sensor and a finger enrolled on it. Asking raises
    /// nothing.
    var hasFinger: Bool { get }

    /// A mark of the set of fingerprints enrolled now, which is another
    /// once one is added or taken away, and nil when there is no saying:
    /// the lid shut over the sensor, or no finger at all. It says nothing
    /// of the fingers themselves, and asking raises nothing.
    var fingerprints: Data? { get }

    /// Asks for nothing.
    func seal(_ secret: SecretBytes, beside plain: Data) throws -> EnclaveSeal

    /// Asks for a finger and blocks on it, so never from the main thread:
    /// on `context` when a view is drawing it, which is then where the
    /// finger is asked for, and otherwise on the Touch ID sheet. Any error
    /// means the finger did not open it, whichever error it is: a cancel, a
    /// changed set of fingerprints, a lid shut over the sensor.
    func open(_ sealed: EnclaveSeal, beside plain: Data, reason: String, on context: LAContext?) throws -> SecretBytes

    /// Takes down a finger being asked for, which `open` then answers with
    /// an error. Without one it does nothing.
    func withdraw()
}

/// The real one (`docs/notes.md`, "A finger without a provisioning profile").
struct TouchIDEnclave: Enclave {
    /// The context a finger is being asked for on, for `withdraw`.
    private final class Sheet {
        private let lock = NSLock()
        private var context: LAContext?

        func hold(_ context: LAContext?) { lock.withLock { self.context = context } }
        func take() -> LAContext? { lock.withLock { defer { context = nil }; return context } }
    }

    private let sheet = Sheet()

    /// A context for a view to draw the finger on, handed back to `open`.
    /// Making one asks nothing.
    static func context() -> LAContext { LAContext() }

    var hasFinger: Bool { refusal == nil }

    /// Why there is no finger to ask, or nil when there is one: no enclave,
    /// or the number LocalAuthentication refused with, which is -4 while the
    /// lid is shut over the sensor (`docs/notes.md`, "A finger without a
    /// provisioning profile"). Asking raises no sheet and makes no key.
    var refusal: String? {
        guard SecureEnclave.isAvailable else { return "no Secure Enclave" }
        var error: NSError?
        guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        return "LAError \(error?.code ?? 0)"
    }

    var fingerprints: Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.domainState.biometry.stateHash
    }

    func seal(_ secret: SecretBytes, beside plain: Data) throws -> EnclaveSeal {
        try secret.withBytes { try EnclaveSeal.seal($0, authenticating: plain) }
    }

    func open(_ sealed: EnclaveSeal, beside plain: Data, reason: String, on context: LAContext?) throws -> SecretBytes {
        let context = context ?? LAContext()
        sheet.hold(context)
        defer { sheet.hold(nil) }
        var opened = try sealed.open(authenticating: plain, reason: reason, context: context)
        // CryptoKit hands the password back as a `Data`, which is zeroed here
        // as far as a `Data` can be.
        defer { opened.resetBytes(in: 0..<opened.count) }
        return SecretBytes(opened)
    }

    func withdraw() {
        sheet.take()?.invalidate()
    }
}
