import CoreGraphics
import XCTest

/// The Mac's screen, for the tests that need it: one that orders a real
/// panel in, one that turns secure input on, one that makes a real enclave
/// key. Behind the login window no panel takes the keys and secure input is
/// the login window's, and the test of the real enclave failed there too.
enum Screen {
    /// What the window server says of this session. With no session at
    /// all, which is a run over ssh, nothing can be shown either.
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Skips the test it is called from, saying what was not asserted. A
    /// card that rests on such a test is not done until the test has run
    /// with the screen unlocked (`docs/notes.md`, "Building and signing").
    static func skipIfLocked(_ unasserted: String) throws {
        try XCTSkipIf(isLocked, "the screen is locked: \(unasserted) was not asserted")
    }
}
