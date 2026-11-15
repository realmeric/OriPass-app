import AppKit
import SwiftUI

/// The field the master password is typed into. An `NSSecureTextField`, so
/// the characters are never drawn and never offered to the pasteboard, with
/// no border and no ground of its own: `LockScreen` draws those around it.
///
/// "Has the keys" means its editor is the first responder of the key window.
/// Secure input follows exactly that, and is let go when the window closes
/// with the caret still in the field, which ends no editing by itself.
final class PasswordTextField: NSSecureTextField {
    let secureInput = SecureInput()
    var focusChanged: ((Bool) -> Void)?

    private(set) var isEditing = false
    private var watching: [NSObjectProtocol] = []

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            isEditing = true
            settle()
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditing = false
        settle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let centre = NotificationCenter.default
        watching.forEach(centre.removeObserver)
        watching = []
        guard let window else {
            isEditing = false
            settle()
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            watching.append(centre.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                self?.settle()
            })
        }
        watching.append(centre.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                           queue: nil) { [weak self] _ in
            self?.letGo()
        })
    }

    /// Gives the keys up, wherever they were.
    func letGo() {
        if isEditing { window?.makeFirstResponder(nil) }
        isEditing = false
        settle()
    }

    private func settle() {
        secureInput.set(isEditing && window?.isKeyWindow == true)
        focusChanged?(isEditing)
    }

    deinit {
        watching.forEach(NotificationCenter.default.removeObserver)
    }
}

/// A way to take what a `PasswordField` holds without Return being pressed
/// in it: for a form, whose button is as good as the key. The field is empty
/// afterwards, as it is after Return.
@MainActor
final class TypedSecret {
    fileprivate weak var field: PasswordTextField?

    /// Puts the caret in the field, for a form that decides for itself
    /// when the password is what is typed next. False when there is no
    /// field yet.
    @discardableResult
    func takeKeys() -> Bool {
        guard let field, field.isEnabled, let window = field.window else { return false }
        return field.isEditing || window.makeFirstResponder(field)
    }

    /// Nil when nothing was typed. Whoever is handed the bytes wipes them.
    func take() -> SecretBytes? {
        guard let field, !field.stringValue.isEmpty else { return nil }
        let typed = SecretBytes(field.stringValue)
        field.stringValue = ""
        field.currentEditor()?.string = ""
        return typed
    }
}

struct PasswordField: NSViewRepresentable {
    let placeholder: String
    let isEnabled: Bool
    /// The lock screen's field takes the keys as soon as it can. A field
    /// that is not the first of its form waits to be tabbed to.
    var takesFocus = true
    var typed: TypedSecret?
    @Binding var isFocused: Bool
    /// What was typed, on Return. The field is empty by the time this runs,
    /// and whoever is handed the bytes wipes them.
    let submit: (SecretBytes) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PasswordTextField {
        let field = PasswordTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.lockFieldNative
        field.textColor = NSColor(Palette.text)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Fonts.lockFieldNative, .foregroundColor: NSColor(Palette.prompt),
        ])
        field.setAccessibilityLabel(placeholder)
        // The cell is the element VoiceOver lands on.
        field.cell?.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] focused in
            // This arrives in the middle of a view update as often as not.
            DispatchQueue.main.async { coordinator?.field.isFocused = focused }
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.isEnabled = isEnabled
        typed?.field = field
        if isEnabled, takesFocus { context.coordinator.focus(field) }
        return field
    }

    func updateNSView(_ field: PasswordTextField, context: Context) {
        context.coordinator.field = self
        typed?.field = field
        guard field.isEnabled != isEnabled else { return }
        // A disabled field that kept its editor would keep the keys too.
        if !isEnabled { field.letGo() }
        field.isEnabled = isEnabled
        if isEnabled, takesFocus { context.coordinator.focus(field) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PasswordTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.replacingUnspecifiedDimensions().width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: PasswordField

        init(_ field: PasswordField) {
            self.field = field
        }

        /// On the next turn of the run loop: the field is not in its window
        /// yet when it is made, and is not enabled yet when it is updated.
        func focus(_ view: PasswordTextField) {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEnabled, !view.isEditing else { return }
                view.window?.makeFirstResponder(view)
            }
        }

        /// Return is taken here and not as the field's action, which would
        /// end the editing first and hand the keys back for a moment.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            guard !control.stringValue.isEmpty else { return true }
            let typed = SecretBytes(control.stringValue)
            control.stringValue = ""
            textView.string = ""
            field.submit(typed)
            return true
        }
    }
}
