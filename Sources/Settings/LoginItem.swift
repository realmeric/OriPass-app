import ServiceManagement

/// Whether the app is opened when he logs in to the Mac. It is not a field
/// of `Settings`: the system keeps the answer, in System Settings › General
/// › Login Items, where he can change it behind the app's back, so it is
/// asked for each time it is drawn.
@MainActor
protocol LoginItem: AnyObject {
    var isOn: Bool { get }
    func set(_ isOn: Bool) throws
}

/// The app's: `SMAppService.mainApp`, which registers the bundle that is
/// running. A test, a shot, the demo and the tour never make one.
@MainActor
final class SystemLoginItem: LoginItem {
    var isOn: Bool { SMAppService.mainApp.status == .enabled }

    func set(_ isOn: Bool) throws {
        if isOn {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// One that is as it is told to be, and can be told to refuse.
@MainActor
final class FakeLoginItem: LoginItem {
    struct Refused: Error {}

    private(set) var isOn: Bool
    var refuses = false
    private(set) var asked: [Bool] = []

    init(isOn: Bool = false) {
        self.isOn = isOn
    }

    func set(_ isOn: Bool) throws {
        asked.append(isOn)
        if refuses { throw Refused() }
        self.isOn = isOn
    }
}
