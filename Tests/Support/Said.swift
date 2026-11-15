import AppKit

/// Everything a view says, as accessibility reads it out: the labels, values
/// and titles of it and of everything under it. A hosting view answers this
/// in a window that was never shown (`docs/notes.md`, "The window").
func said(in element: Any?, keys: [String] = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"],
          depth: Int = 0) -> [String] {
    guard let element = element as? NSAccessibilityElementProtocol & NSObjectProtocol, depth < 40 else { return [] }
    let object = element as AnyObject
    var words: [String] = []
    for key in keys {
        let selector = NSSelectorFromString(key)
        if object.responds(to: selector), let word = object.perform(selector)?.takeUnretainedValue() as? String {
            words.append(word)
        }
    }
    var children = (object as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
    // A lazy stack says it has no children and hands over the rows it has
    // built when it is asked for them by index.
    if children.isEmpty, let lazy = object as? NSObject {
        let count = lazy.accessibilityArrayAttributeCount(.children)
        children = count > 0 ? lazy.accessibilityArrayAttributeValues(.children, index: 0, maxCount: count) : []
    }
    return words + children.flatMap { said(in: $0, keys: keys, depth: depth + 1) }
}
