import AppKit

/// A window that a value of the vault's is typed into: the main one and a
/// window of one item. macOS rewrites what is typed into a text view unless
/// it is told not to, which is right for prose and wrong here. A stock
/// field corrects a word it takes for a slip, expands whatever is in his
/// Text Replacements, and offers a completion, in a note that holds a
/// recovery code or a command and in a password typed with its eye open,
/// and the form saves what the field then holds.
///
/// Every field in the window is typed into through a text view that
/// becomes the first responder, the notes' own or the one editor the
/// window lends each field in turn, so that is where each is told.
final class VaultWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { PlainTyping.keep(text) }
        return super.makeFirstResponder(responder)
    }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let text = editor as? NSTextView { PlainTyping.keep(text) }
        return editor
    }
}

/// What is typed is what is kept: nothing substituted, corrected, completed
/// or detected, and nothing offered to Writing Tools, which would send a
/// note out of this app to be rewritten.
@MainActor
enum PlainTyping {
    static func keep(_ text: NSTextView) {
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.writingToolsBehavior = .none
    }
}
