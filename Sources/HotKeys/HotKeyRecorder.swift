import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The control that listens for a combination.
///
/// An `NSView` rather than a SwiftUI gesture: what is wanted is the next key
/// event with its modifiers, before anybody's key equivalents run, and only
/// AppKit's responder chain offers that. The General room of the settings
/// has one for each action.
final class HotKeyRecorderView: NSView {
    var onRecord: ((HotKey) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    var words: String = "" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording.toggle()
        if isRecording {
            window?.makeFirstResponder(self)
        } else {
            onCancel?()
        }
    }

    /// Every key while recording, including the ones with menu equivalents:
    /// this runs before the menu gets a look, which is the only way to record
    /// a combination somebody's menu already uses and then refuse it for a
    /// reason rather than never seeing it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return record(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, record(event) else { return super.keyDown(with: event) }
    }

    private func record(_ event: NSEvent) -> Bool {
        // Escape gets out rather than being recorded: it is the one key
        // somebody presses when they have changed their mind.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            onCancel?()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = HotKey(key: UInt32(event.keyCode),
                         carbon: HotKey.carbonModifiers(from: flags))
        isRecording = false
        onRecord?(key)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: Metrics.hairlineInset, dy: Metrics.hairlineInset),
                                   xRadius: Metrics.recorderRadius, yRadius: Metrics.recorderRadius)
        NSColor(isRecording ? Palette.recording : Palette.field).setFill()
        rounded.fill()
        NSColor(isRecording ? Palette.accent : Palette.outline).setStroke()
        rounded.stroke()

        let text = isRecording ? "Press keys…" : (words.isEmpty ? "Not set" : words)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Fonts.recorder,
            .foregroundColor: NSColor(words.isEmpty && !isRecording ? Palette.prompt : Palette.text),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attributes)
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    let words: String
    let record: (HotKey) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onRecord = record
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.onRecord = record
        view.words = words
    }
}
