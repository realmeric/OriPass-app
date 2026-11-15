/// A type that holds a secret and so says nothing of what it holds: not to
/// `print`, not to string interpolation, not to `dump`, and so not to a crash
/// log or a failed assertion that prints its operands (D6).
protocol Redacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// What it may say: its kind, and an id where it has one.
    var redactedLabel: String { get }
}

extension Redacted {
    var description: String { redactedLabel }
    var debugDescription: String { redactedLabel }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
