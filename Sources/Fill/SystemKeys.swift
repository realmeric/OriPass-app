import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The real keys (`docs/notes.md`, "Typing into another app"): each one a
/// pair of `CGEvent`s, down and up, posted to one process and to nothing
/// else, so a key cannot land in an app that came in front a moment ago.
/// A character rides in the event as its own text. Tab and Return are their
/// virtual keys, which are the same on every layout.
///
/// Without Accessibility the post returns without an error and nothing
/// happens, which is why `Typist` asks first.
@MainActor
final class EventKeys: KeySink {
    func post(_ key: Key, to pid: pid_t) {
        for event in Self.events(for: key) { event.postToPid(pid) }
    }

    /// The two events of one key, made and not posted. Their source has a
    /// state of its own, and their flags are emptied: whatever is held on
    /// the real keyboard is no part of them.
    static func events(for key: Key) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        let code: Int
        switch key {
        case .text: code = kVK_ANSI_A
        case .tab: code = kVK_Tab
        case .enter: code = kVK_Return
        }
        return [true, false].compactMap { isDown in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown) else {
                return nil
            }
            event.flags = []
            if case .text(let character) = key {
                let units = Array(character.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            return event
        }
    }
}

/// What is in front, what is held and where the caret is, asked of the
/// system. None of the three changes anything, and only the third needs
/// Accessibility.
@MainActor
final class SystemForeground: Foreground {
    /// How long the app in front has to say where its caret is.
    static let patience: Float = 0.25

    var frontPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    var holdsModifier: Bool {
        let held = CGEventSource.flagsState(.combinedSessionState)
        return !held.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    /// The focused element's subrole is `AXSecureTextField`, in a window
    /// or on a web page. A terminal's password prompt is no field at all:
    /// there the sign is that the app has taken secure input, and the
    /// session says which process holds it. An app that does not answer,
    /// or names no element as having the keys, is unknown; one that names
    /// an element of any other kind is plain.
    func caret(in app: FrontApp) -> Caret {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let holder = session["kCGSSessionSecureInputPID"] as? Int, holder == Int(app.pid) {
            return .secure
        }
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(element, Self.patience)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == kAXSecureTextFieldSubrole ? .secure : .plain
    }
}

/// The grant, which belongs to the code signature and is kept in System
/// Settings › Privacy & Security › Accessibility.
@MainActor
final class SystemAccessibility: Accessibility {
    static let settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    var isTrusted: Bool { AXIsProcessTrusted() }

    func ask() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openSettings() {
        guard let url = URL(string: Self.settings) else { return }
        NSWorkspace.shared.open(url)
    }
}
