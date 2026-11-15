import Foundation

/// The extension's way in: the account, the encrypted vault and the key,
/// read from where the app left them, with no KDF and no request (I5).
enum Unlocking {
    enum Failure: Error, Equatable {
        case signedOut
        case face(FaceKey.Failure)
        case unreadable
    }

    static func open(face: FaceKey = .app, reason: String) async throws -> Vault {
        guard Account.stored() != nil, let data = VaultFile.read() else { throw Failure.signedOut }
        let key: VaultKey
        do {
            key = try await face.open(reason: reason)
        } catch let failure as FaceKey.Failure {
            throw Failure.face(failure)
        }
        GraceKey.app.keep(key, minutes: Choices.read().grace)
        do {
            return try Vault(data: data, userKey: key)
        } catch {
            throw Failure.unreadable
        }
    }

    /// The vault with no face, while a grace the person chose lasts.
    static func openInGrace() -> Vault? {
        guard Choices.read().grace > 0, let key = GraceKey.app.take(), let data = VaultFile.read() else { return nil }
        return try? Vault(data: data, userKey: key)
    }
}
