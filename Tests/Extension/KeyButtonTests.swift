import AppKit
import XCTest
@testable import OriPass

/// `Extension/page.css` over WebKit's real buttons, which only a browser asks
/// for. `getComputedStyle` says nothing of them, so a field with a button is
/// held to the same field without one, pixel for pixel, with the marks on both.
@MainActor
final class KeyButtonTests: XCTestCase {
    private static var folder: URL?
    private static let fields = ["key", "key-long", "strong"]
    private static let marked = 6

    /// Every `data-button` on a page asks WebKit for that button: 1 the key,
    /// 2 contacts and 3 the strong password's words, on this Mac's WebKit.
    private static let plugIn = """
    #import <Foundation/Foundation.h>
    #import <JavaScriptCore/JavaScriptCore.h>
    #import <objc/message.h>

    @protocol WKWebProcessPlugIn <NSObject>
    @end
    @protocol WKWebProcessPlugInLoadDelegate <NSObject>
    @end
    @interface Buttons : NSObject <WKWebProcessPlugIn, WKWebProcessPlugInLoadDelegate>
    @end

    @implementation Buttons
    - (void)webProcessPlugIn:(id)controller didCreateBrowserContextController:(id)browser {
        ((void (*)(id, SEL, id))objc_msgSend)(browser, sel_registerName("setLoadDelegate:"), self);
    }

    - (void)webProcessPlugInBrowserContextController:(id)browser didFinishDocumentLoadForFrame:(id)frame {
        id world = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"WKWebProcessPlugInScriptWorld"),
                                                   sel_registerName("normalWorld"));
        JSContext *page = ((id (*)(id, SEL, id))objc_msgSend)(frame, sel_registerName("jsContextForWorld:"), world);
        JSValue *inputs = [page evaluateScript:@"[...document.querySelectorAll('input[data-button]')]"];
        for (int place = 0; place < [inputs[@"length"] toInt32]; place++) {
            id field = ((id (*)(id, SEL, id, id))objc_msgSend)(NSClassFromString(@"WKWebProcessPlugInNodeHandle"),
                                                               sel_registerName("nodeHandleWithJSValue:inContext:"),
                                                               inputs[place], page);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                field, sel_registerName("setHTMLInputElementAutoFillButtonEnabledWithButtonType:"),
                [inputs[place][@"dataset"][@"button"] toInt32]);
        }
    }
    @end
    """

    private static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.meric.oripass.tests.buttons</string>
    <key>CFBundleExecutable</key><string>Buttons</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>NSPrincipalClass</key><string>Buttons</string>
    </dict></plist>
    """

    private static func bundle() throws -> URL {
        let folder = try Self.folder ?? made()
        Self.folder = folder
        return folder.appendingPathComponent("Buttons.bundle")
    }

    private static func made() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("buttons-\(UUID().uuidString)")
        let contents = folder.appendingPathComponent("Buttons.bundle/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let source = folder.appendingPathComponent("buttons.m")
        try plugIn.write(to: source, atomically: true, encoding: .utf8)

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = ["clang", "-bundle", "-fobjc-arc", "-framework", "Foundation", "-framework", "JavaScriptCore",
                           "-o", contents.appendingPathComponent("MacOS/Buttons").path, source.path]
        let ours = ProcessInfo.processInfo.environment
        clang.environment = ["PATH": "/usr/bin:/bin",
                             "DEVELOPER_DIR": ours["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0)
        return folder
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = nil
        }
        super.tearDown()
    }

    private static func pageSheet() throws -> String {
        let data = try Data(contentsOf: ExtensionStage.folder.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(manifest["content_scripts"] as? [[String: Any]])
        let names = entries.compactMap { $0["css"] as? [String] }.flatMap { $0 }
        return try ExtensionStage.file(try XCTUnwrap(names.first))
    }

    /// The bytes of a field's box in one picture of the page.
    private func pixels(of id: String, in rep: NSBitmapImageRep, on stage: ExtensionStage) async throws -> Data {
        let box = try await stage.box(of: id)
        let scale = CGFloat(rep.pixelsWide) / stage.page.bounds.width
        let image = try XCTUnwrap(rep.cgImage?.cropping(to: CGRect(x: box.minX * scale, y: box.minY * scale,
                                                                   width: box.width * scale, height: box.height * scale)))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    }

    /// Whether each named field looks as the one beside it with no button does.
    private func looksPlain(_ names: [String], level: ExtensionStage.SheetLevel?) async throws -> [String: Bool] {
        let stage = ExtensionStage()
        stage.injectedBundle = try Self.bundle()
        if let level { stage.sheet = (try Self.pageSheet(), level) }
        try await stage.open()
        defer { stage.close() }
        try await stage.load("key-button")
        try await stage.until("live('.mark').length === \(Self.marked)")
        let shot = try await stage.snapshot(named: "key-button-\(level.map { "\($0)" } ?? "bare")", dark: false)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: shot)))
        var found: [String: Bool] = [:]
        for name in names {
            let drawn = try await pixels(of: name, in: rep, on: stage)
            let plain = try await pixels(of: "plain-\(name)", in: rep, on: stage)
            found[name] = drawn == plain
        }
        return found
    }

    func testWithNoSheetWebKitDrawsItsButtons() async throws {
        let found = try await looksPlain(Self.fields + ["contacts"], level: nil)
        XCTAssertEqual(found, ["key": false, "key-long": false, "strong": false, "contacts": false],
                       "with no button drawn the tests below hold nothing, and the bundle has stopped working")
    }

    func testTheKeyAndTheStrongPasswordGoAndGiveBackTheirRoomAtUserLevel() async throws {
        let found = try await looksPlain(Self.fields + ["contacts"], level: .user)
        XCTAssertEqual(found, ["key": true, "key-long": true, "strong": true, "contacts": false])
    }

    func testTheKeyAndTheStrongPasswordGoAndGiveBackTheirRoomAtAuthorLevel() async throws {
        let found = try await looksPlain(Self.fields + ["contacts"], level: .author)
        XCTAssertEqual(found, ["key": true, "key-long": true, "strong": true, "contacts": false])
    }

    func testTheSheetNamesTheTwoButtonsAndNothingOfThePage() async throws {
        let sheet = try Self.pageSheet()
        let rules = sheet.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        let selectors = rules.prefix { $0 != "{" }.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(selectors, ["input::-webkit-credentials-auto-fill-button",
                                   "input::-webkit-strong-password-auto-fill-button"])
        XCTAssertEqual(rules.filter { $0 == "{" }.count, 1, "one rule")

        let stage = ExtensionStage()
        try await stage.open()
        defer { stage.close() }
        try await stage.load("key-button")
        for selector in selectors {
            let known = try await stage.js("return CSS.supports('selector(\(selector))')") as? Bool
            XCTAssertEqual(known, true, selector)
        }
    }
}
