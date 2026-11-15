import Foundation

/// Every choice a person makes, one value in the App Group's defaults, so
/// that the extension reads the same ones. A field that does not decode
/// costs that field and not the rest.
struct Choices: Codable, Equatable, Sendable {
    /// Seconds away from the app before the vault locks: 0 is at once.
    var lockAfter = 300
    /// The key kept for Face ID after a password unlock (I4).
    var faceID = true
    var siteIcons = true
    /// Minutes after a face in which AutoFill fills with no face again: 0
    /// is never, and the default (PH-25).
    var grace = 0

    static let lockTimes = [0, 60, 300, 900]
    static let graceTimes = [0, 1, 2, 5]

    private static var defaults: UserDefaults? { UserDefaults(suiteName: Shared.appGroup) }
    private static let key = "choices"

    static func read(from defaults: UserDefaults? = defaults) -> Choices {
        guard let data = defaults?.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Choices() }
        var choices = Choices()
        if let value = object["lockAfter"] as? Int, lockTimes.contains(value) { choices.lockAfter = value }
        if let value = object["faceID"] as? Bool { choices.faceID = value }
        if let value = object["siteIcons"] as? Bool { choices.siteIcons = value }
        if let value = object["grace"] as? Int, graceTimes.contains(value) { choices.grace = value }
        return choices
    }

    func write(to defaults: UserDefaults? = defaults) {
        defaults?.set(try? JSONEncoder().encode(self), forKey: Choices.key)
    }

    static func forget(in defaults: UserDefaults? = defaults) {
        defaults?.removeObject(forKey: key)
    }
}

/// When a vault that was left open locks: when the person comes back after
/// longer than the choice allows, and at once when the choice is 0.
enum LockRule {
    static func locks(leftAt: Date?, now: Date, after seconds: Int) -> Bool {
        guard let leftAt else { return false }
        return seconds == 0 || now.timeIntervalSince(leftAt) >= Double(seconds)
    }
}
