import SwiftUI
import UIKit

/// The two Home Screen quick actions: the generator, which needs no vault,
/// and search, which asks for the face first.
@MainActor @Observable
final class QuickActions {
    static let shared = QuickActions()

    enum Action: String {
        case generate = "com.meric.oripass.ios.generate"
        case search = "com.meric.oripass.ios.search"
    }

    var pending: Action?

    func take(_ item: UIApplicationShortcutItem) {
        pending = Action(rawValue: item.type)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { MainActor.assumeIsolated { QuickActions.shared.take(item) } }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActions.shared.take(shortcutItem) }
        completionHandler(true)
    }
}
