import Combine
import Foundation
import LocalAuthentication

/// What an item that asks to be guarded is asked for.
enum GuardedAct: String, CaseIterable {
    case reveal, copy, edit, fill, largeType
    /// A signature for ssh, which is no item's to ask for: every use of a
    /// key is asked about (`SSHAgent`).
    case sign
    /// A passkey's signature, whose flags say a person was verified: every
    /// one is asked about, whatever the item says (`PasskeyDoor`).
    case passkey
    /// A new passkey, which is asked about for the same reason.
    case makePasskey
    /// A pass, which keeps every SSH key in memory with the vault shut
    /// (`AgentPass`).
    case pass
    /// A phone, which may then answer what a pass leaves to the card
    /// (`PhoneDoor`).
    case phone
    /// A login found by a word on the system's sheet, which no address holds
    /// to anything: every one is asked about (`BrowserDoor`).
    case pick
    /// A password a page took, going over the one a login has: every one is
    /// asked about, whatever the item says (`SaveDoor`).
    case overwrite

    /// How the Touch ID sheet ends its sentence about what the app is
    /// trying to do. No item is named in it.
    var reason: String {
        switch self {
        case .reveal: return "show an item that asks first"
        case .copy: return "copy from an item that asks first"
        case .edit: return "change an item that asks first"
        case .fill: return "type an item that asks first into another app"
        case .largeType: return "show an item that asks first in Large Type"
        case .sign: return "use an SSH key"
        case .passkey: return "sign in with a passkey"
        case .makePasskey: return "make a passkey"
        case .pass: return "keep every SSH key in memory for a pass"
        case .phone: return "let a phone answer for a pass"
        case .pick: return "hand a login to the app in front"
        case .overwrite: return "change a saved password to the one a page took"
        }
    }

    /// The same, as the card that asks for the password ends its own.
    var wanted: String {
        switch self {
        case .reveal: return "what it hides is shown"
        case .copy: return "anything is copied from it"
        case .edit: return "it is changed"
        case .fill: return "it is typed into another app"
        case .largeType: return "it is shown in Large Type"
        case .sign: return "it is used"
        case .passkey: return "it signs in with a passkey"
        case .makePasskey: return "a passkey is made for it"
        case .pass: return "it is kept in memory for a pass"
        case .phone: return "it may answer for a pass"
        case .pick: return "it is handed to the app in front"
        case .overwrite: return "its password is changed to the one the page took"
        }
    }
}

/// Whoever can say that the person at the Mac is the one who opened the
/// vault. The real one is `OwnerCheck`, a finger or the master password; a
/// test and the canary's tour stand `FakeAuthoriser` behind it.
@MainActor
protocol Authoriser: AnyObject {
    /// Whether the answer would be a finger, and not the master password.
    var hasFinger: Bool { get }
    /// Asked for one act at a time. `name` is the item's, for a question
    /// that is drawn by this app. `context` is one a view on the screen is
    /// drawing the finger for, where the system would otherwise raise its
    /// sheet.
    func authorise(_ act: GuardedAct, for name: String, on context: LAContext?) async -> Bool
    /// The vault has shut. Whatever is being asked is answered no.
    func withdraw()
}

extension Authoriser {
    func authorise(_ act: GuardedAct, for name: String) async -> Bool {
        await authorise(act, for: name, on: nil)
    }
}

/// Bitwarden's "master password re-prompt": an item with `reprompt` set
/// gives nothing up until whoever is asking has shown again that the vault
/// is his. He is asked once for each item in each unlock, whichever act
/// came first, and the lock forgets every answer.
///
/// One for the app, so that the window, a window of one item and Quick
/// Access ask once between them. It holds ids and nothing of an item.
@MainActor
final class Reprompt {
    let authoriser: Authoriser
    /// The items he has answered for since the vault opened.
    private var answered: Set<String> = []
    /// Moves at each lock, so an answer that comes after one is no answer.
    private var unlock = 0
    /// The question being asked, for a test to wait on.
    private(set) var asking: Task<Void, Never>?
    private var watching: AnyCancellable?

    init(store: VaultStore, authoriser: Authoriser) {
        self.authoriser = authoriser
        watching = store.$state.sink { [weak self] state in
            if state != .unlocked { self?.forget() }
        }
    }

    /// Whether an act on this item would be held for a question.
    func asks(about item: Item) -> Bool {
        item.reprompt && !answered.contains(item.id)
    }

    /// How many items have been answered for, which after a lock is none.
    var count: Int { answered.count }

    /// Does `go` now for an item that does not ask, or has been answered
    /// for, and says true. Otherwise he is asked and `go` is done when he
    /// has answered yes, with the vault still open: whoever hands it over
    /// looks again at what it is about to act on. An act that arrives
    /// while another is being asked about is dropped. `refused` is every
    /// way of not doing `go`, for a caller that has to answer someone.
    @discardableResult
    func allow(_ act: GuardedAct, on item: Item, then go: @escaping @MainActor () -> Void,
               refused: @escaping @MainActor () -> Void = {}) -> Bool {
        guard asks(about: item) else {
            go()
            return true
        }
        ask(act, about: item, then: go, refused: refused)
        return false
    }

    private func ask(_ act: GuardedAct, about item: Item, then go: @escaping @MainActor () -> Void,
                     refused: @escaping @MainActor () -> Void) {
        ask(act, named: item.name, id: item.id, then: go, refused: refused)
    }

    private func ask(_ act: GuardedAct, named name: String, id: String?, then go: @escaping @MainActor () -> Void,
                     refused: @escaping @MainActor () -> Void) {
        guard asking == nil else { return refused() }
        let asked = unlock
        asking = Task { [weak self, authoriser] in
            let isHis = await authoriser.authorise(act, for: name)
            guard let self, self.unlock == asked else { return refused() }
            self.asking = nil
            guard isHis else { return refused() }
            if let id { self.answered.insert(id) }
            go()
        }
    }

    /// `allow`, for a caller that waits on the answer and has no act to
    /// hand over.
    func answer(_ act: GuardedAct, on item: Item) async -> Bool {
        await withCheckedContinuation { answer in
            allow(act, on: item, then: { answer.resume(returning: true) },
                  refused: { answer.resume(returning: false) })
        }
    }

    /// `answer`, asked every time, whatever the item says and whether it has
    /// been answered for. The one question stands for the item as well.
    func confirm(_ act: GuardedAct, on item: Item) async -> Bool {
        await withCheckedContinuation { answer in
            ask(act, about: item, then: { answer.resume(returning: true) },
                refused: { answer.resume(returning: false) })
        }
    }

    /// `confirm`, for what is no item yet: a question about `name` that
    /// nothing is remembered from.
    func confirm(_ act: GuardedAct, named name: String) async -> Bool {
        await withCheckedContinuation { answer in
            ask(act, named: name, id: nil, then: { answer.resume(returning: true) },
                refused: { answer.resume(returning: false) })
        }
    }

    private func forget() {
        unlock += 1
        answered = []
        guard asking != nil else { return }
        asking = nil
        authoriser.withdraw()
    }
}

/// An authoriser with no sensor and no field, for a test and for the
/// canary's tour. It answers what it was told to and counts what it was
/// asked.
@MainActor
final class FakeAuthoriser: Authoriser {
    var answer = true
    var hasFinger = true
    /// Held until `release` when set, so a test can lock under a question.
    var holds = false
    /// What the real one tells the enclave.
    var onWithdraw: () -> Void = {}
    private(set) var asked: [GuardedAct] = []
    /// The context each of those was asked on.
    private(set) var contexts: [LAContext?] = []
    private(set) var withdrawn = 0
    private var held: CheckedContinuation<Bool, Never>?

    func authorise(_ act: GuardedAct, for name: String, on context: LAContext?) async -> Bool {
        asked.append(act)
        contexts.append(context)
        guard holds else { return answer }
        return await withCheckedContinuation { held = $0 }
    }

    func release(_ answer: Bool) {
        held?.resume(returning: answer)
        held = nil
    }

    func withdraw() {
        withdrawn += 1
        release(false)
        onWithdraw()
    }
}
