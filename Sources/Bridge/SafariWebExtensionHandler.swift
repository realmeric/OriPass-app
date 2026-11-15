import AppKit
import SafariServices

/// What Safari hands each `sendNativeMessage` to, in `OriPassSafari.appex`,
/// sandboxed and started by Safari. It does for Safari what `oripass-bridge`
/// does for Orion: one message to the door on a connection of its own, behind
/// a `hello` of its own, and the answer back. It holds neither. It is compiled
/// into the app as well, for the tests, where nothing makes one.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let hello = Data(#"{"v":\#(BridgeWire.version),"type":"hello","browser":"com.apple.Safari"}"#.utf8)

    private let door: URL?
    private let app: String

    /// What the system makes one with.
    override convenience init() {
        self.init(door: BridgeWire.doorInTheGroup, app: "com.meric.oripass")
    }

    init(door: URL?, app: String) {
        self.door = door
        self.app = app
    }

    func beginRequest(with context: NSExtensionContext) {
        let asked = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        // Off Safari's thread, since an answer can take as long as a finger.
        DispatchQueue.global().async { [self] in
            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: answer(to: asked)]
            context.completeRequest(returningItems: [item])
        }
    }

    private func answer(to asked: Any?) -> Any {
        guard let asked, JSONSerialization.isValidJSONObject(asked),
              var message = try? JSONSerialization.data(withJSONObject: asked)
        else { return noDoor }
        defer { message.resetBytes(in: 0..<message.count) }
        guard BridgeWire.kind(of: message) != nil, let door,
              var bytes = BridgeWire.pass(message, saying: Self.hello, to: door)
        else { return noDoor }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return (try? JSONSerialization.jsonObject(with: bytes)) ?? noDoor
    }

    /// The words `background.js` reads when the door said nothing: the app is
    /// up behind a lock, or it is not up.
    private var noDoor: [String: Any] {
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty
        return ["v": BridgeWire.version, "type": isRunning ? "locked" : "closed"]
    }
}
