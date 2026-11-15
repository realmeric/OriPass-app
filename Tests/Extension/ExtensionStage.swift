import AppKit
import WebKit
import XCTest
@testable import OriPass

/// WebKit with `Extension/` in it, which is the engine of Safari and Orion
/// both: a page in a real isolated world with `menu.js` and `content.js`, the
/// background page and the popup each in a web view of their own, and this
/// class between them where the browser would be. What it says of a sender
/// comes from the frame the message came from. Pages are served from the
/// fixtures under the scheme `fixture`, so nothing touches the network, and
/// that scheme is told to the extension as `https`, which is all it ever sees.
@MainActor
final class ExtensionStage: NSObject {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let folder = root.appendingPathComponent("Extension")
    private static let forms = root.appendingPathComponent("Tests/Fixtures/forms")
    private static let extensionHome = "fixture-extension://extension/"

    static func file(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    let world = WKContentWorld.world(name: "content")
    private(set) var page: WKWebView!
    private(set) var background: WKWebView!
    private(set) var popup: WKWebView?
    private var window: NSWindow?

    /// What the door is asked, in order, and how it answers: `nil` is an app
    /// that is not there, which rejects the call as a browser does.
    private(set) var heard: [[String: Any]] = []
    var door: ([String: Any]) -> [String: Any]? = ExtensionStage.openDoor
    /// How long the door takes over each answer, which on a busy Mac is
    /// longer than a popup takes to draw.
    var doorTakes: UInt64 = 0
    /// A browser with no `storage.session`, which is told before `open`.
    var noSessionStorage = false
    /// The door itself, which takes its time, for a test that wants the real
    /// one. It answers in place of `door`.
    var wholeDoor: (@MainActor ([String: Any]) async -> [String: Any]?)?
    /// A browser's own `navigator.credentials.get` that keeps what it was
    /// handed in `window.handedOver`, and a page that had got there first and
    /// keeps what crosses the wrapper's port in `window.portSaid`, from the
    /// wrapper, and `window.portHeard`, to it. Told before `open`.
    var countsTheBrowsersOwn = false
    /// An injected bundle for the page's web view, which is told before
    /// `open`: nothing else can make WebKit draw its own buttons.
    var injectedBundle: URL?
    /// A sheet for the page's top frame as a browser adds one, which is told
    /// before `open`, with the level WebKit gives it.
    var sheet: (source: String, level: SheetLevel)?

    enum SheetLevel: Int {
        case user, author
    }

    /// What each frame's script asked the background page, and the frames
    /// that asked, by host.
    private(set) var asked: [[String: Any]] = []
    private(set) var frames: [String: WKFrameInfo] = [:]

    static let username = "kanarya-user@example.test"
    static let password = "kanarya-password"
    static let generated = "kanarya-generated"

    static func openDoor(_ message: [String: Any]) -> [String: Any]? {
        switch message["type"] as? String {
        case "hello": return ["v": 1, "type": "ready"]
        case "logins":
            return ["v": 1, "type": "logins", "site": "example.test", "logins": [
                ["id": "one", "title": "Canary Mail", "username": username],
                ["id": "two", "title": "Canary Work", "username": "kanarya-other@example.test"],
                ["id": "three", "title": "No Name"],
            ]]
        case "fill":
            return ["v": 1, "type": "filled", "username": username, "password": password, "code": "123456"]
        case "known":
            return ["v": 1, "type": "known", "state": "new", "site": "example.test", "logins": [[String: String]]()]
        case "save":
            return ["v": 1, "type": "saved", "id": "made", "title": "example.test"]
        case "never":
            return ["v": 1, "type": "known", "state": "never"]
        case "usernames":
            var words = [username, "kanarya-work@example.test", "kanarya"]
            if message["address"] as? Bool == true { words.removeLast() }
            return ["v": 1, "type": "usernames", "usernames": words]
        case "generate":
            return ["v": 1, "type": "generated", "password": generated]
        default: return nil
        }
    }

    func open() async throws {
        background = view(contentWorld: .page, width: 1, height: 1)
        try await load(background, "\(Self.extensionHome)background.html")
        page = view(contentWorld: world, width: 800, height: 600)
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page
        window.orderFrontRegardless()
        window.makeFirstResponder(page)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func view(contentWorld: WKContentWorld, width: CGFloat, height: CGFloat) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(self, forURLScheme: "fixture")
        configuration.setURLSchemeHandler(self, forURLScheme: "fixture-extension")
        let content = configuration.userContentController
        for name in ["runtime", "native", "tabs"] {
            content.addScriptMessageHandler(self, contentWorld: contentWorld, name: name)
        }
        var sources = [(try? String(contentsOf: Self.root.appendingPathComponent("Tests/Support/standin-browser.js"),
                                    encoding: .utf8)) ?? ""]
        if noSessionStorage { sources.append("delete browser.storage.session;") }
        if contentWorld !== WKContentWorld.page {
            if let injectedBundle {
                configuration.setValue(Self.pool(with: injectedBundle), forKey: "processPool")
            }
            if let sheet { Self.add(sheet, to: content) }
            sources += ["menu.js", "fields.js", "typed.js", "toast.js", "content.js"].compactMap { try? Self.file($0) }
            if countsTheBrowsersOwn {
                content.addUserScript(WKUserScript(source: Self.theBrowsersOwn, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: false, in: .page))
            }
        }
        for source in sources {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: contentWorld))
        }
        return WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
    }

    /// WebKit's SPI by name: the one way into a web process, and the one way
    /// to put a sheet at a level a page's own `<style>` cannot be at.
    private static func pool(with bundle: URL) -> NSObject? {
        let configuration = (NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type)?.init()
        configuration?.setValue(bundle, forKey: "injectedBundleURL")
        let pool = WKProcessPool.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        return pool?.perform(NSSelectorFromString("_initWithConfiguration:"), with: configuration)?
            .takeUnretainedValue() as? NSObject
    }

    private static func add(_ sheet: (source: String, level: SheetLevel), to content: WKUserContentController) {
        guard let made = (NSClassFromString("_WKUserStyleSheet") as? NSObject.Type)?
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return }
        let start = NSSelectorFromString("initWithSource:forWKWebView:forMainFrameOnly:includeMatchPatternStrings:"
            + "excludeMatchPatternStrings:baseURL:level:contentWorld:")
        typealias Start = @convention(c) (AnyObject, Selector, NSString, AnyObject?, Bool, AnyObject?, AnyObject?,
                                          AnyObject?, Int, AnyObject?) -> Unmanaged<AnyObject>
        let begun = unsafeBitCast(made.method(for: start), to: Start.self)(
            made, start, sheet.source as NSString, nil, true, nil, nil, nil, sheet.level.rawValue, nil
        )
        _ = content.perform(NSSelectorFromString("_addUserStyleSheet:"), with: begun.takeUnretainedValue())
    }

    private static let theBrowsersOwn = """
    window.handedOver = [];
    window.portSaid = [];
    window.portHeard = [];
    CredentialsContainer.prototype.get = function (options) {
        window.handedOver.push(options);
        return Promise.resolve("the browser's own");
    };
    const send = MessagePort.prototype.postMessage;
    MessagePort.prototype.postMessage = function (message, ...rest) {
        window.portSaid.push(message);
        return send.call(this, message, ...rest);
    };
    const Channel = MessageChannel;
    window.MessageChannel = function () {
        const channel = new Channel();
        channel.port1.addEventListener("message", ({ data }) => window.portHeard.push(data));
        return channel;
    };
    """

    /// A form from `Tests/Fixtures/forms/`, as a page on `host`.
    func load(_ form: String, host: String = "www.example.test", query: String = "") async throws {
        try await load(page, "fixture://\(host)/\(form).html\(query)")
    }


    /// A door with no login for any page, which is what most sites have.
    static func noLogins(_ message: [String: Any]) -> [String: Any]? {
        guard message["type"] as? String == "logins" else { return openDoor(message) }
        return ["v": 1, "type": "logins", "site": "example.test", "logins": [[String: String]]()]
    }

    func openPopup() async throws {
        let popup = view(contentWorld: .page, width: 340, height: 240)
        self.popup = popup
        try await load(popup, "\(Self.extensionHome)popup.html")
    }

    private func load(_ view: WKWebView, _ address: String) async throws {
        let loaded = Navigated()
        view.navigationDelegate = loaded
        view.load(URLRequest(url: try XCTUnwrap(URL(string: address))))
        await withCheckedContinuation { loaded.done = $0.resume }
    }

    /// Whatever scheme a page was served from, what the extension is told.
    private static func told(_ url: URL?) -> String {
        (url?.absoluteString ?? "").replacingOccurrences(of: "fixture://", with: "https://")
    }

    /// What a browser says of the frame a message came from.
    private func sender(of frame: WKFrameInfo, in view: WKWebView?) -> [String: Any] {
        let address = frame.request.url
        if view === page {
            if let host = address?.host { frames[host] = frame }
            return ["url": Self.told(address), "frameId": frame.isMainFrame ? 0 : 7,
                    "tab": ["id": 1, "url": Self.told(page.url)]]
        }
        return ["url": address?.absoluteString ?? ""]
    }

    /// A message into the background page with a sender of the test's own.
    @discardableResult
    func deliver(_ message: [String: Any], from sender: [String: Any]) async throws -> [String: Any] {
        let answer = try await background.callAsyncJavaScript(
            "return await deliver(message, sender)", arguments: ["message": message, "sender": sender],
            in: nil, contentWorld: .page
        )
        return answer as? [String: Any] ?? [:]
    }

    @discardableResult
    func js(_ source: String, world: WKContentWorld? = nil, in frame: WKFrameInfo? = nil) async throws -> Any? {
        try await page.callAsyncJavaScript(source, arguments: [:], in: frame, contentWorld: world ?? self.world)
    }

    func until(_ condition: String, world: WKContentWorld? = nil, in frame: WKFrameInfo? = nil, seconds: Double = 10,
               file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if try await js("return Boolean(\(condition))", world: world, in: frame) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("still not so: \(condition)", file: file, line: line)
    }

    /// A click the window server might have sent, so `isTrusted` holds, at a
    /// point in the page counted from its top left.
    func click(_ point: CGPoint) throws {
        let window = try XCTUnwrap(window)
        let location = NSPoint(x: point.x, y: page.bounds.height - point.y)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
            ))
            if type == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
        }
    }

    enum Key {
        case down, up, enter, escape, tab

        var characters: String {
            switch self {
            case .down: return "\u{F701}"
            case .up: return "\u{F700}"
            case .enter: return "\r"
            case .escape: return "\u{1B}"
            case .tab: return "\t"
            }
        }

        var code: UInt16 {
            switch self {
            case .down: return 125
            case .up: return 126
            case .enter: return 36
            case .escape: return 53
            case .tab: return 48
            }
        }
    }

    func press(_ key: Key) throws {
        let window = try XCTUnwrap(window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
            ))
            if type == .keyDown { page.keyDown(with: event) } else { page.keyUp(with: event) }
        }
    }

    /// The box of an element of the page, as the page has it.
    func box(of id: String, in frame: WKFrameInfo? = nil) async throws -> CGRect {
        let parts = try await js("""
        const box = document.getElementById("\(id)").getBoundingClientRect();
        return [box.left, box.top, box.width, box.height];
        """, world: .page, in: frame) as? [Double]
        let found = try XCTUnwrap(parts)
        return CGRect(x: found[0], y: found[1], width: found[2], height: found[3])
    }

    /// `page` as a page that sets its own colours, whatever the Mac is set to.
    func paintPage(dark: Bool) async throws {
        try await js("""
        document.documentElement.style.background = \(dark ? "'#14161A'" : "'#FFFFFF'");
        document.documentElement.style.color = \(dark ? "'#E8E8E8'" : "'#111111'");
        for (const field of document.querySelectorAll("input")) {
            field.style.background = \(dark ? "'#23262C'" : "'#FFFFFF'");
            field.style.color = \(dark ? "'#E8E8E8'" : "'#111111'");
            field.style.border = "1px solid #7A7A7A";
            field.style.height = "30px";
        }
        """, world: .page)
    }

    func snapshot(named name: String, dark: Bool) async throws -> URL {
        page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try await Task.sleep(nanoseconds: 300_000_000)
        let image = try await page.takeSnapshot(configuration: nil)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }
}

extension ExtensionStage: WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let body = message.body as? [String: Any] ?? [:]
        switch message.name {
        case "native":
            let asked = body["message"] as? [String: Any] ?? [:]
            heard.append(asked)
            let quick = door(asked)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: doorTakes)
                let answer = await wholeDoor?(asked) ?? quick
                if let answer {
                    replyHandler(answer, nil)
                } else {
                    replyHandler(nil, "no host")
                }
            }
        case "tabs":
            if body["query"] != nil {
                replyHandler([["id": 1, "url": Self.told(page.url)]], nil)
                return
            }
            let sent = body["message"] ?? [:]
            Task { @MainActor in
                let answer = try? await page.callAsyncJavaScript(
                    "return await deliver(message, {})", arguments: ["message": sent], in: nil, contentWorld: world
                )
                replyHandler(answer, nil)
            }
        default:
            asked.append(body)
            let sender = sender(of: message.frameInfo, in: message.webView)
            Task { @MainActor in
                do {
                    let answer = try await background.callAsyncJavaScript(
                        "return await deliver(message, sender)", arguments: ["message": body, "sender": sender],
                        in: nil, contentWorld: .page
                    )
                    replyHandler(answer, nil)
                } catch {
                    replyHandler(nil, "\(error)")
                }
            }
        }
    }
}

extension ExtensionStage: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        var data: Data?
        if url.scheme == "fixture" {
            data = try? Data(contentsOf: Self.forms.appendingPathComponent(name))
        } else if name == "background.html" {
            data = Data("<!doctype html><script src=suffix.js></script><script src=background.js></script>".utf8)
        } else {
            data = try? Data(contentsOf: Self.folder.appendingPathComponent(url.path))
        }
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let kinds = ["html": "text/html", "js": "text/javascript", "css": "text/css"]
        task.didReceive(URLResponse(url: url, mimeType: kinds[url.pathExtension] ?? "text/plain",
                                    expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

private final class Navigated: NSObject, WKNavigationDelegate {
    var done: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done?()
        done = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done?()
        done = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done?()
        done = nil
    }
}
