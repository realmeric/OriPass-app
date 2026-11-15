import AppKit

/// The one way a value leaves this app for the pasteboard (D15,
/// `docs/notes.md` "The pasteboard"): the string with the marker clipboard
/// managers skip, kept on this Mac, and taken off again after ninety seconds
/// or at the lock, whichever comes first, unless something else has been
/// copied since. The ninety seconds and the staying are `ClipboardChoices`,
/// read at each copy. What was copied is not kept here. The change count is.
@MainActor
final class Clipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Nil writes nowhere, which is what a shot and most tests want.
    private let pasteboard: NSPasteboard?
    private let choices: () -> ClipboardChoices
    /// Another wait than the settings', for a test and the tour, which have
    /// no ninety seconds.
    var delay: TimeInterval?
    /// The pasteboard's count as this app left it.
    private var left: Int?
    /// The wait that ends in a clear, for a test to wait on too.
    private(set) var clearing: Task<Void, Never>?
    private var timer: Instruments.Registration?

    init(pasteboard: NSPasteboard?, delay: TimeInterval? = nil,
         choices: @escaping () -> ClipboardChoices = { ClipboardChoices() }) {
        self.pasteboard = pasteboard
        self.delay = delay
        self.choices = choices
    }

    deinit {
        clearing?.cancel()
    }

    /// Whether what is on the pasteboard is what this app put there.
    var isHolding: Bool {
        guard let pasteboard, let left else { return false }
        return pasteboard.changeCount == left
    }

    /// What is on the pasteboard now, whoever put it there. The one thing
    /// read from it is a private key for the editor's form (`PastedKey`).
    var string: String? { pasteboard?.string(forType: .string) }

    /// Kept off Universal Clipboard unless he has said a copy may leave.
    static func options(for choices: ClipboardChoices) -> NSPasteboard.ContentsOptions {
        choices.staysOnThisMac ? .currentHostOnly : []
    }

    func copy(_ value: String) {
        guard let pasteboard, !value.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setString("", forType: Self.concealed)
        let choices = choices()
        pasteboard.prepareForNewContents(with: Self.options(for: choices))
        pasteboard.writeObjects([item])
        left = pasteboard.changeCount

        clearing?.cancel()
        timer = Instruments.register("clear", kind: .timer, owner: "Clipboard")
        let delay = self.delay ?? choices.clearSeconds
        clearing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Empties the pasteboard if it is still as this app left it, and leaves
    /// it alone if it is not: what is there now is somebody else's. The lock
    /// calls this too (D6).
    @discardableResult
    func clear() -> Bool {
        clearing?.cancel()
        clearing = nil
        timer = nil
        let isOurs = isHolding
        left = nil
        if isOurs { pasteboard?.clearContents() }
        return isOurs
    }
}
