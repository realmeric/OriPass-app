import AppKit

/// What says a sentence to somebody who is not looking. Quick Access keeps
/// the keys in its field while the arrows move down its rows, so VoiceOver,
/// which reads what has the keys, would say nothing of a list it never
/// lands on.
@MainActor
protocol Voice {
    func say(_ words: String, in window: NSWindow?)
}

/// VoiceOver's, through the announcement an app may ask it for. Nothing is
/// posted while VoiceOver is off.
@MainActor
struct SystemVoice: Voice {
    func say(_ words: String, in window: NSWindow?) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let element = window ?? NSApp.keyWindow else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: words,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
