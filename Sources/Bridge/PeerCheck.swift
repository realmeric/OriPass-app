import Foundation
import Security

/// Who may be on the other end of the door, each by the name its code is
/// signed under: OP-68's host, OP-70's extension and OP-74's provider.
enum BridgeCaller: String, CaseIterable {
    case host = "com.meric.oripass.bridge"
    case safari = "com.meric.oripass.safari"
    case autofill = "com.meric.oripass.autofill"
}

/// Asks the system what is calling, from the socket and not from anything
/// the caller says. Apple's anchor, this team and one of the identifiers,
/// which names the team and not the certificate, so a Debug build and a
/// Developer ID build both pass (`docs/notes.md`, "The door for the
/// browser").
struct PeerCheck {
    /// The group's prefix, and the certificate's organisational unit: the
    /// team the app itself is signed by.
    static let team = BridgeWire.team

    /// A Release build turns away a peer that any process of his may attach
    /// to: a Debug helper left in DerivedData is signed by the same team. A
    /// Debug build has to take one, since `make test` signs with it.
    static var takesDebuggable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var team = PeerCheck.team
    /// What each caller's code is signed as. A test names itself here.
    var identifiers = Dictionary(uniqueKeysWithValues: BridgeCaller.allCases.map { ($0, $0.rawValue) })
    var takesDebuggable = PeerCheck.takesDebuggable

    /// `CS_RUNTIME` and `CS_GET_TASK_ALLOW` in `sys/codesign.h`, which Swift
    /// does not import.
    static let hardened: UInt32 = 0x10000
    static let debuggable: UInt32 = 0x4

    /// OriCode, which is who the phone's answer comes through, and only in a
    /// Debug build the one it builds for itself.
    static var oriCode: [String] {
        takesDebuggable ? ["com.realmeric.oricode", "com.realmeric.oricode.molten"] : ["com.realmeric.oricode"]
    }

    /// Nil for anyone else, which is every process with no signature.
    func caller(on descriptor: Int32) -> BridgeCaller? {
        guard let code = holdable(on: descriptor) else { return nil }
        return identifiers.first { _, identifier in
            guard let requirement = requirement(for: identifier) else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }?.key
    }

    /// The same, for one who is no caller of the door.
    func signs(_ descriptor: Int32, as identifier: String) -> Bool {
        guard let code = holdable(on: descriptor), let requirement = requirement(for: identifier) else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func holdable(on descriptor: Int32) -> SecCode? {
        guard let code = Self.code(of: descriptor), let status = Self.status(of: code),
              status & Self.hardened != 0, takesDebuggable || status & Self.debuggable == 0
        else { return nil }
        return code
    }

    private func requirement(for identifier: String) -> SecRequirement? {
        let written = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
        var requirement: SecRequirement?
        SecRequirementCreateWithString(written as CFString, [], &requirement)
        return requirement
    }

    /// By the audit token, which names one run of one program, where a pid
    /// can be another's by the time it is asked about.
    private static func code(of descriptor: Int32) -> SecCode? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// The flags the kernel holds for the running process, and not what the
    /// file on disk says now.
    static func status(of code: SecCode) -> UInt32? {
        var information: CFDictionary?
        // Takes a `SecCode` as well, which is the only kind that has a status.
        let copied = SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                                   SecCSFlags(rawValue: kSecCSDynamicInformation), &information)
        guard copied == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoStatus as String] as? UInt32
    }
}
