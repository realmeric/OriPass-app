import AppKit

/// One element of a view as accessibility has it: what it is, and every
/// word it would be read out with.
struct Heard: CustomStringConvertible {
    var role: String
    var label: String
    var value: String
    var title: String
    var help: String
    /// The names in its menu of actions, which is where VoiceOver finds
    /// what else can be done to it.
    var actions: [String]

    /// What VoiceOver has to say for it, in the order it says it.
    var words: String { [label, title, value].filter { !$0.isEmpty }.joined(separator: ", ") }
    var isSilent: Bool { words.isEmpty }
    var description: String { "\(role) \"\(words)\"" }

    /// The roles a pointer or a key does something to, and a picture, which
    /// says nothing by itself.
    static let controls: Set<String> = Set([
        NSAccessibility.Role.button, .textField, .textArea, .checkBox, .radioButton, .slider, .popUpButton,
        .menuButton, .link, .incrementor, .disclosureTriangle, .comboBox, .menuItem, .image, .unknown,
    ].map(\.rawValue))

    var isControl: Bool { Self.controls.contains(role) }
}

/// Every element under a view, itself first, in the order `said(in:)` walks
/// them. SwiftUI's elements answer the selectors and are not the protocol,
/// so each is asked by name.
func heard(in element: Any?, depth: Int = 0) -> [Heard] {
    guard let object = element as? NSObject, element is NSAccessibilityElementProtocol, depth < 40 else { return [] }
    func word(_ key: String) -> String {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    func things(_ key: String) -> [Any] {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return [] }
        return object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
    }
    let actions = things("accessibilityCustomActions").compactMap { ($0 as? NSAccessibilityCustomAction)?.name }
    let own = Heard(role: word("accessibilityRole"), label: word("accessibilityLabel"),
                    value: word("accessibilityValue"), title: word("accessibilityTitle"),
                    help: word("accessibilityHelp"), actions: actions)
    var children = things("accessibilityChildren")
    // A lazy stack says it has no children and hands over the rows it has
    // built when it is asked for them by index.
    if children.isEmpty {
        let count = object.accessibilityArrayAttributeCount(.children)
        children = count > 0 ? object.accessibilityArrayAttributeValues(.children, index: 0, maxCount: count) : []
    }
    return [own] + children.flatMap { heard(in: $0, depth: depth + 1) }
}
