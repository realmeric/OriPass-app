import Foundation
import LocalAuthentication

/// The master password, kept for a finger (D7). After an unlock the engine
/// took, the password that opened it is sealed to an enclave key and written
/// as two files: `key`, the enclave key as the enclave wrapped it, and
/// `password`, the sealed bytes with the second they were sealed in beside
/// them in the clear. A finger opens them, and what comes out is sent to the
/// engine as if it had been typed. It is in neither file in the clear.
///
/// The date and the mark of the enrolled fingers are bound to the seal, so
/// a program that moves the one to keep an old seal alive, or the other so
/// that an orphan reads as ready, gets a seal that no longer opens.
///
/// Until 2026-10-11 the second file was `session` and held the session key
/// `bw` handed back. One of those is deleted as a seal is made over its
/// directory, without being opened: what is in it is nothing the app sends
/// any more, and the password is typed once to make the new one. So is a
/// `password` file that is not of this form: the first of them bound the
/// date alone, and would not open against what is bound now.
final class PasswordSeal {
    /// What the Touch ID sheet says the app is trying to do.
    static let reason = "unlock \(AppInfo.name)"

    enum Standing: Equatable {
        case none, ready
        /// Too old to be opened. Whoever sees this deletes it.
        case expired
        /// Sealed under a set of fingerprints that is not the one enrolled
        /// now, so the enclave's key is dead and no finger opens it. Deleted
        /// like one that expired.
        case orphaned
    }

    enum Failure: Error {
        case nothingSealed
    }

    let directory: URL
    private let enclave: Enclave
    private let now: () -> Date
    /// How old a seal may be and still open: D7's fourteen days, unless the
    /// settings say another number.
    private let lifetime: () -> TimeInterval

    private var keyFile: URL { directory.appendingPathComponent("key") }
    private var passwordFile: URL { directory.appendingPathComponent("password") }
    private var oldFile: URL { directory.appendingPathComponent("session") }

    private struct Sealed: Codable {
        /// What `plain` is made of. A file with another number here, or
        /// none, is not a seal this code opens.
        static let form = 2

        var form: Int?
        /// Seconds since 1970, whole, so that it reads back as it was written.
        var made: Int
        var encapsulated: Data
        var box: Data
        /// `Enclave.fingerprints` as it was when this was sealed.
        var fingers: Data?

        /// What is bound to the box: the date, and the mark as the file
        /// writes it, or nothing after the space when there was none.
        var plain: Data { Data("\(made) \(fingers?.base64EncodedString() ?? "")".utf8) }
    }

    init(directory: URL = AppPaths.seal, enclave: Enclave = TouchIDEnclave(),
         now: @escaping () -> Date = Date.init,
         lifetime: @escaping () -> TimeInterval = { LockChoices().fingerLifetime }) {
        self.directory = directory
        self.enclave = enclave
        self.now = now
        self.lifetime = lifetime
        dropOldForm()
    }

    /// The seal of a session, and the key it was sealed to, which seals
    /// nothing else. And a `password` file that is not this form's, with
    /// its key.
    private func dropOldForm() {
        let files = FileManager.default
        if files.fileExists(atPath: oldFile.path) {
            try? files.removeItem(at: oldFile)
            if !files.fileExists(atPath: passwordFile.path) { try? files.removeItem(at: keyFile) }
            Log.app.info("a seal from before the password was sealed is deleted")
        }
        if files.fileExists(atPath: passwordFile.path), read() == nil {
            forget()
            Log.app.info("a seal of another form is deleted")
        }
    }

    /// False with the lid shut over the sensor, or with no finger enrolled.
    var canSeal: Bool { enclave.hasFinger }

    /// The mark of the fingers enrolled now (`Enclave.fingerprints`).
    var fingerprints: Data? { enclave.fingerprints }

    private func read() -> (key: Data, sealed: Sealed)? {
        guard let key = try? Data(contentsOf: keyFile),
              let written = try? Data(contentsOf: passwordFile),
              let sealed = try? JSONDecoder().decode(Sealed.self, from: written),
              sealed.form == Sealed.form else { return nil }
        return (key, sealed)
    }

    var standing: Standing {
        guard let sealed = read()?.sealed else { return .none }
        let age = now().timeIntervalSince1970 - TimeInterval(sealed.made)
        if age >= lifetime() { return .expired }
        // Only when both are known: a shut lid is not another finger.
        if let then = sealed.fingers, let enrolled = enclave.fingerprints, then != enrolled { return .orphaned }
        return .ready
    }

    /// Replaces whatever was sealed before. The password is the caller's to
    /// wipe.
    func seal(_ password: SecretBytes) throws {
        var sealed = Sealed(form: Sealed.form, made: Int(now().timeIntervalSince1970),
                            encapsulated: Data(), box: Data(), fingers: enclave.fingerprints)
        let made = try enclave.seal(password, beside: sealed.plain)
        sealed.encapsulated = made.encapsulated
        sealed.box = made.box

        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for (file, bytes) in [(keyFile, made.key), (passwordFile, try JSONEncoder().encode(sealed))] {
            try bytes.write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Blocks on the finger, so never from the main thread. Age is not
    /// looked at here: `standing` is asked first. What comes back is the
    /// master password, and the caller's to wipe.
    func unseal(reason: String = PasswordSeal.reason, on context: LAContext? = nil) throws -> SecretBytes {
        guard let (key, sealed) = read() else { throw Failure.nothingSealed }
        return try enclave.open(EnclaveSeal(key: key, encapsulated: sealed.encapsulated, box: sealed.box),
                                beside: sealed.plain, reason: reason, on: context)
    }

    /// Ends the finger `unseal` is blocked on, if it is.
    func withdraw() {
        enclave.withdraw()
    }

    /// Deletes the two files. The enclave key goes with its blob: nothing else
    /// holds it.
    func forget() {
        try? FileManager.default.removeItem(at: keyFile)
        try? FileManager.default.removeItem(at: passwordFile)
    }
}
