import XCTest
@testable import OriPass

/// `scripts/release.sh check` is everything the release script reads from a
/// bundle before it will install it. Each test makes a bundle that is right
/// in every way but one, in a temporary directory, and holds the script to
/// refusing it with the sentence for that one thing and no other. The
/// bundles are never run: their executable is a copy of `/usr/bin/true`.
final class ReleaseScriptTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let one = "com.apple.security.automation.apple-events"
    private static let groups = "com.apple.security.application-groups"
    private static let group = "\(team).oripass"
    private static let hostID = "com.meric.oripass.bridge"
    private static let sandbox = "com.apple.security.app-sandbox"
    private static let appexID = "com.meric.oripass.safari"
    private static let providerID = "com.meric.oripass.autofill"
    private static let capability = "com.apple.developer.authentication-services.autofill-credential-provider"
    private static let appIDKey = "com.apple.application-identifier"
    private static let teamKey = "com.apple.developer.team-identifier"
    /// The team this Mac's Apple Development certificate is under, which the
    /// test host was signed by, and which every run of the script is handed.
    private static let team = PeerCheck.team

    /// A key and a certificate of no one's, for the invented profiles: the
    /// script reads what a profile says and leaves its signature to macOS.
    private static let signer: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-signer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        made.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=invented",
                          "-keyout", folder.appendingPathComponent("key.pem").path,
                          "-out", folder.appendingPathComponent("cert.pem").path]
        made.standardError = FileHandle.nullDevice
        try? made.run()
        made.waitUntilExit()
        return folder
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: signer)
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ tool: String, _ arguments: [String],
                     environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: tool)
        run.arguments = arguments
        run.environment = (environment ?? ProcessInfo.processInfo.environment).merging(["OP_TEAM": Self.team]) { _, team in team }
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        return (run.terminationStatus, output)
    }

    /// A bundle with everything the script looks for, not yet signed.
    private func bundle(id: String = "com.meric.oripass") throws -> URL {
        let app = directory.appendingPathComponent("OriPass.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("MacOS/OriPass"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleExecutable": "OriPass", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.0.0", "CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("icns".utf8).write(to: resources.appendingPathComponent("AppIcon.icns"))
        try Data("car".utf8).write(to: resources.appendingPathComponent("Assets.car"))
        try Data("// rules".utf8).write(to: resources.appendingPathComponent("public_suffix_list.dat"))
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("Helpers/oripass-bridge"))
        try extensionBundle(at: Self.appex(in: app))
        try providerBundle(at: Self.provider(in: app))
        try profile(for: "com.meric.oripass").copy(to: contents.appendingPathComponent("embedded.provisionprofile"))
        return app
    }

    private static func appex(in app: URL) -> URL {
        app.appendingPathComponent("Contents/PlugIns/OriPassSafari.appex")
    }

    private static func provider(in app: URL) -> URL {
        app.appendingPathComponent("Contents/PlugIns/OriPassAutoFill.appex")
    }

    /// A signed plist, which is what a profile is, right unless told
    /// otherwise, and invented: it holds no one's key and authorises nothing.
    private func profile(for id: String, team: String = team, capability: Bool = true, allDevices: Bool = true,
                         expires: Date = Date().addingTimeInterval(86_400)) throws -> Invented {
        var entitlements: [String: Any] = [Self.appIDKey: "\(team).\(id)", Self.teamKey: team]
        if capability { entitlements[Self.capability] = true }
        var keys: [String: Any] = ["Name": "OriPass", "ExpirationDate": expires, "Entitlements": entitlements]
        if allDevices { keys["ProvisionsAllDevices"] = true }
        let name = UUID().uuidString
        let plist = directory.appendingPathComponent("\(name).plist")
        let made = directory.appendingPathComponent("\(name).provisionprofile")
        try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: plist)
        let signed = try run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", plist.path,
                                                  "-signer", Self.signer.appendingPathComponent("cert.pem").path,
                                                  "-inkey", Self.signer.appendingPathComponent("key.pem").path, "-out", made.path])
        XCTAssertEqual(signed.status, 0, signed.output)
        return Invented(url: made)
    }

    private struct Invented {
        let url: URL

        func copy(to place: URL) throws {
            try? FileManager.default.removeItem(at: place)
            try FileManager.default.copyItem(at: url, to: place)
        }
    }

    private func providerBundle(at appex: URL) throws {
        let contents = appex.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("MacOS/OriPassAutoFill"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": Self.providerID, "CFBundleExecutable": "OriPassAutoFill", "CFBundlePackageType": "XPC!",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.authentication-services-credential-provider-ui",
                            "NSExtensionPrincipalClass": "OriPassAutoFill.CredentialProviderViewController",
                            "NSExtensionAttributes": ["ASCredentialProviderExtensionCapabilities": ["ProvidesOneTimeCodes": true,
                                                                                                    "ProvidesPasskeys": true,
                                                                                                    "ProvidesPasswords": true]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try profile(for: Self.providerID).copy(to: contents.appendingPathComponent("embedded.provisionprofile"))
    }

    private func extensionBundle(at appex: URL) throws {
        let contents = appex.appendingPathComponent("Contents")
        for folder in ["MacOS", "Resources/icons"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("MacOS/OriPassSafari"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": Self.appexID, "CFBundleExecutable": "OriPassSafari", "CFBundlePackageType": "XPC!",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
                            "NSExtensionPrincipalClass": "OriPassSafari.SafariWebExtensionHandler"],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("{}".utf8).write(to: contents.appendingPathComponent("Resources/manifest.json"))
        try Data("png".utf8).write(to: contents.appendingPathComponent("Resources/icons/16.png"))
    }

    /// What the host is signed as, right unless a test says otherwise.
    private struct Host {
        var id = ReleaseScriptTests.hostID
        var entitlements: [String: Any] = [ReleaseScriptTests.groups: [ReleaseScriptTests.group]]
        var runtime = true
        var identity: String?
    }

    /// What the extension is signed as, right unless a test says otherwise.
    private struct Appex {
        var id = ReleaseScriptTests.appexID
        var entitlements: [String: Any] = [ReleaseScriptTests.sandbox: true,
                                           ReleaseScriptTests.groups: [ReleaseScriptTests.group]]
        var runtime = true
        var identity: String?
    }

    /// What the provider is signed as, right unless a test says otherwise.
    private struct Provider {
        var id = ReleaseScriptTests.providerID
        var entitlements: [String: Any] = Provider.right
        var runtime = true
        var identity: String?

        static let right: [String: Any] = [
            ReleaseScriptTests.sandbox: true, ReleaseScriptTests.groups: [ReleaseScriptTests.group],
            ReleaseScriptTests.capability: true, ReleaseScriptTests.teamKey: ReleaseScriptTests.team,
            ReleaseScriptTests.appIDKey: "\(ReleaseScriptTests.team).\(ReleaseScriptTests.providerID)",
        ]
    }

    /// Signed ad hoc unless an identity is named, which every check before
    /// the team's is indifferent to.
    private func sign(_ app: URL, entitlements: [String] = [one], group: String? = group, granted: Bool = true,
                      runtime: Bool = true, identity: String = "-", host: Host = Host(), appex: Appex = Appex(),
                      provider: Provider = Provider(), profiled: [String: Any] = appKeys) throws {
        if FileManager.default.fileExists(atPath: Self.provider(in: app).path) {
            let file = directory.appendingPathComponent("provider.plist")
            try PropertyListSerialization.data(fromPropertyList: provider.entitlements, format: .xml, options: 0).write(to: file)
            var arguments = ["--force", "--timestamp=none", "--identifier", provider.id, "--entitlements", file.path,
                             "--sign", provider.identity ?? identity]
            if provider.runtime { arguments += ["--options", "runtime"] }
            let signed = try run("/usr/bin/codesign", arguments + [Self.provider(in: app).path])
            XCTAssertEqual(signed.status, 0, signed.output)
        }
        if FileManager.default.fileExists(atPath: Self.appex(in: app).path) {
            let file = directory.appendingPathComponent("appex.plist")
            try PropertyListSerialization.data(fromPropertyList: appex.entitlements, format: .xml, options: 0).write(to: file)
            var arguments = ["--force", "--timestamp=none", "--identifier", appex.id, "--entitlements", file.path,
                             "--sign", appex.identity ?? identity]
            if appex.runtime { arguments += ["--options", "runtime"] }
            let signed = try run("/usr/bin/codesign", arguments + [Self.appex(in: app).path])
            XCTAssertEqual(signed.status, 0, signed.output)
        }
        let helper = app.appendingPathComponent("Contents/Helpers/oripass-bridge")
        if FileManager.default.fileExists(atPath: helper.path) {
            let file = directory.appendingPathComponent("host.plist")
            try PropertyListSerialization.data(fromPropertyList: host.entitlements, format: .xml, options: 0).write(to: file)
            var arguments = ["--force", "--timestamp=none", "--identifier", host.id, "--entitlements", file.path,
                             "--sign", host.identity ?? identity]
            if host.runtime { arguments += ["--options", "runtime"] }
            let signed = try run("/usr/bin/codesign", arguments + [helper.path])
            XCTAssertEqual(signed.status, 0, signed.output)
        }
        var arguments = ["--force", "--timestamp=none", "--sign", identity]
        if runtime { arguments += ["--options", "runtime"] }
        if !entitlements.isEmpty {
            let file = directory.appendingPathComponent("entitlements.plist")
            var keys: [String: Any] = Dictionary(uniqueKeysWithValues: entitlements.map { ($0, granted) })
            if let group { keys[Self.groups] = [group] }
            keys.merge(profiled) { $1 }
            try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: file)
            arguments += ["--entitlements", file.path]
        }
        let signed = try run("/usr/bin/codesign", arguments + [app.path])
        XCTAssertEqual(signed.status, 0, signed.output)
    }

    /// What ties the app to its profile, and the capability the profile is for.
    private static let appKeys: [String: Any] = [capability: true, teamKey: team, appIDKey: "\(team).com.meric.oripass"]

    /// The script's answer for a bundle: refused, with one sentence.
    private func refusal(of app: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let script = Self.root.appendingPathComponent("scripts/release.sh").path
        let checked = try run("/bin/bash", [script, "check", app.path])
        XCTAssertEqual(checked.status, 1, checked.output, file: file, line: line)
        let sentences = checked.output.split(separator: "\n").filter { $0.hasPrefix("xx ") }
        XCTAssertEqual(sentences.count, 1, checked.output, file: file, line: line)
        XCTAssertFalse(checked.output.contains("verified"), checked.output, file: file, line: line)
        return String(sentences.first ?? "")
    }

    func testAFolderThatIsNoBundleIsRefusedForItsPlist() throws {
        let app = try bundle()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Info.plist"))
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx no Info.plist in "), said)
    }

    func testABundleUnderAnotherIdIsRefusedByItsId() throws {
        let app = try bundle(id: "com.meric.oripass.debug")
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx the bundle id is com.meric.oripass.debug, and com.meric.oripass was expected")
    }

    func testABundleWithoutItsIconIsRefusedForTheIcon() throws {
        let app = try bundle()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the icon is missing"), said)
    }

    func testABundleWithoutTheSuffixListIsRefusedForTheList() throws {
        let app = try bundle()
        try FileManager.default.removeItem(
            at: app.appendingPathComponent("Contents/Resources/public_suffix_list.dat"))
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the Public Suffix List is not in the bundle"), said)
    }

    func testADebugBuildsSecondBinaryIsNamed() throws {
        let app = try bundle()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: app.appendingPathComponent("Contents/MacOS/OriPass.debug.dylib"))
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx Contents/MacOS holds more than the app"), said)
        XCTAssertTrue(said.contains("OriPass.debug.dylib"), said)
    }

    func testAFileChangedAfterTheSignatureIsRefusedByTheSignature() throws {
        let app = try bundle()
        try sign(app)
        try Data("// other rules".utf8)
            .write(to: app.appendingPathComponent("Contents/Resources/public_suffix_list.dat"))
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature does not verify"), said)
    }

    func testABundleThatWasNeverSignedIsRefusedByTheSignature() throws {
        let app = try bundle()
        let unsigned = try run("/usr/bin/codesign", ["--remove-signature", app.path])
        XCTAssertEqual(unsigned.status, 0, unsigned.output)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature does not verify"), said)
    }

    func testASignatureWithoutTheHardenedRuntimeIsRefusedForIt() throws {
        let app = try bundle()
        try sign(app, runtime: false)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the hardened runtime is off"), said)
    }

    func testGetTaskAllowIsRefusedByName() throws {
        let app = try bundle()
        try sign(app, entitlements: [Self.one, "com.apple.security.get-task-allow"])
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature carries get-task-allow"), said)
    }

    func testASignatureWithNoEntitlementIsRefused() throws {
        let app = try bundle()
        try sign(app, entitlements: [])
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature carries no entitlement"), said)
    }

    func testTheEntitlementWrittenAsFalseIsRefused() throws {
        let app = try bundle()
        try sign(app, granted: false)
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx \(Self.one) is there and is not true")
    }

    func testAGroupThatIsNotTheDoorsIsRefused() throws {
        let app = try bundle()
        try sign(app, group: "\(Self.team).other")
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx \(Self.groups) does not name \(Self.group), where the door for the browser stands")
    }

    func testAThirdEntitlementIsRefusedAndNamed() throws {
        let app = try bundle()
        try sign(app, entitlements: [Self.one, "com.apple.security.cs.disable-library-validation"])
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature should carry \(Self.capability), \(Self.groups), \(Self.one) and its App ID and team alone"), said)
        XCTAssertTrue(said.contains("com.apple.security.cs.disable-library-validation"), said)
    }

    /// Right in everything the script reads before the team, so this is the
    /// one sentence left to say.
    func testAnAdHocSignatureIsRefusedForHavingNoTeam() throws {
        let app = try bundle()
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature's team is not set, and \(Self.team) was expected"), said)
    }

    /// The same bundle under this Mac's certificate passes, which is what
    /// shows that the refusals above are each for their one reason.
    func testABundleThatIsRightInEveryWayIsVerified() throws {
        let app = try bundle()
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        try XCTSkipUnless(identities.output.contains("Apple Development"),
                          "no Apple Development identity on this Mac, so nothing was signed and nothing verified")
        try sign(app, identity: "Apple Development")
        let script = Self.root.appendingPathComponent("scripts/release.sh").path
        let checked = try run("/bin/bash", [script, "check", app.path])
        XCTAssertEqual(checked.status, 0, checked.output)
        XCTAssertTrue(checked.output.contains("OriPass 0.0.0 verified"), checked.output)
        XCTAssertFalse(checked.output.contains("xx "), checked.output)
    }

    // MARK: The host for Orion

    /// Under this Mac's certificate, so that the app's own checks all pass
    /// and what is left is the host's.
    private func refusalOfTheHost(signed host: Host = Host(), removing: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        try XCTSkipUnless(identities.output.contains("Apple Development"), "no Apple Development identity on this Mac")
        let app = try bundle()
        if removing {
            try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Helpers/oripass-bridge"))
        }
        try sign(app, identity: "Apple Development", host: host)
        return try refusal(of: app, file: file, line: line)
    }

    func testABundleWithoutTheHostIsRefusedForIt() throws {
        let said = try refusalOfTheHost(removing: true)
        XCTAssertEqual(said, "xx the host for Orion is not in the bundle, at Contents/Helpers/oripass-bridge")
    }

    func testAHostUnderAnotherNameIsRefused() throws {
        let said = try refusalOfTheHost(signed: Host(id: "com.meric.oripass.other", identity: "Apple Development"))
        XCTAssertEqual(said, "xx the host is signed as com.meric.oripass.other, and the door takes \(Self.hostID)")
    }

    func testAHostWithoutTheHardenedRuntimeIsRefused() throws {
        let said = try refusalOfTheHost(signed: Host(runtime: false, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the host's hardened runtime is off"), said)
    }

    func testAHostAnyoneMayAttachToIsRefused() throws {
        let keys: [String: Any] = [Self.groups: [Self.group], "com.apple.security.get-task-allow": true]
        let said = try refusalOfTheHost(signed: Host(entitlements: keys, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the host should carry \(Self.groups) alone"), said)
        XCTAssertTrue(said.contains("get-task-allow"), said)
    }

    func testAHostOutsideTheGroupIsRefused() throws {
        let keys: [String: Any] = [Self.groups: ["\(Self.team).other"]]
        let said = try refusalOfTheHost(signed: Host(entitlements: keys, identity: "Apple Development"))
        XCTAssertEqual(said, "xx the host's \(Self.groups) does not name \(Self.group), where the door stands")
    }

    func testAHostOfNoTeamIsRefused() throws {
        let said = try refusalOfTheHost(signed: Host(identity: "-"))
        XCTAssertTrue(said.hasPrefix("xx the host's team is not set, and \(Self.team) was expected"), said)
    }

    // MARK: Safari's extension

    /// Under this Mac's certificate, so that the app's and the host's checks
    /// all pass and what is left is the extension's.
    private func refusalOfTheExtension(signed appex: Appex = Appex(), changing change: (URL) throws -> Void = { _ in },
                                       file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        try XCTSkipUnless(identities.output.contains("Apple Development"), "no Apple Development identity on this Mac")
        let app = try bundle()
        try change(Self.appex(in: app))
        try sign(app, identity: "Apple Development", appex: appex)
        return try refusal(of: app, file: file, line: line)
    }

    func testABundleWithoutTheExtensionIsRefusedForIt() throws {
        let said = try refusalOfTheExtension { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(said, "xx Safari's extension is not in the bundle, at Contents/PlugIns/OriPassSafari.appex")
    }

    func testAnExtensionAtAnotherPointIsRefused() throws {
        let said = try refusalOfTheExtension { appex in
            let plist = appex.appendingPathComponent("Contents/Info.plist")
            var keys = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: plist), format: nil) as? [String: Any])
            keys["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]
            try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: plist)
        }
        XCTAssertTrue(said.hasPrefix("xx the extension's point is com.apple.widgetkit-extension"), said)
    }

    func testAnExtensionWithoutItsManifestIsRefused() throws {
        let said = try refusalOfTheExtension {
            try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/Resources/manifest.json"))
        }
        XCTAssertTrue(said.hasPrefix("xx the extension's manifest and icons are not at the top"), said)
    }

    func testAnExtensionUnderAnotherNameIsRefused() throws {
        let said = try refusalOfTheExtension(signed: Appex(id: "com.meric.oripass.other", identity: "Apple Development"))
        XCTAssertEqual(said, "xx the extension is signed as com.meric.oripass.other, and the door takes \(Self.appexID)")
    }

    func testAnExtensionWithoutTheHardenedRuntimeIsRefused() throws {
        let said = try refusalOfTheExtension(signed: Appex(runtime: false, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the extension's hardened runtime is off"), said)
    }

    func testAnExtensionOutsideTheSandboxIsRefused() throws {
        let keys: [String: Any] = [Self.groups: [Self.group]]
        let said = try refusalOfTheExtension(signed: Appex(entitlements: keys, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the extension should carry \(Self.sandbox) and \(Self.groups) alone"), said)
    }

    func testASandboxWrittenAsFalseIsRefused() throws {
        let keys: [String: Any] = [Self.sandbox: false, Self.groups: [Self.group]]
        let said = try refusalOfTheExtension(signed: Appex(entitlements: keys, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the extension's sandbox is there and is not on"), said)
    }

    func testAnExtensionOutsideTheGroupIsRefused() throws {
        let keys: [String: Any] = [Self.sandbox: true, Self.groups: ["\(Self.team).other"]]
        let said = try refusalOfTheExtension(signed: Appex(entitlements: keys, identity: "Apple Development"))
        XCTAssertEqual(said, "xx the extension's \(Self.groups) does not name \(Self.group), where the door stands")
    }

    func testAnExtensionWithAThirdEntitlementIsRefusedAndNamed() throws {
        let keys: [String: Any] = [Self.sandbox: true, Self.groups: [Self.group],
                                   "com.apple.security.network.client": true]
        let said = try refusalOfTheExtension(signed: Appex(entitlements: keys, identity: "Apple Development"))
        XCTAssertTrue(said.contains("com.apple.security.network.client"), said)
    }

    func testAnExtensionOfNoTeamIsRefused() throws {
        let said = try refusalOfTheExtension(signed: Appex(identity: "-"))
        XCTAssertTrue(said.hasPrefix("xx the extension's team is not set, and \(Self.team) was expected"), said)
    }

    // MARK: The system's AutoFill

    /// Under this Mac's certificate, so that everything before the provider
    /// passes and what is left is the provider's.
    private func refusalOfTheProvider(signed provider: Provider = Provider(identity: "Apple Development"),
                                      changing change: (URL) throws -> Void = { _ in },
                                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        try XCTSkipUnless(identities.output.contains("Apple Development"), "no Apple Development identity on this Mac")
        let app = try bundle()
        try change(Self.provider(in: app))
        try sign(app, identity: "Apple Development", provider: provider)
        return try refusal(of: app, file: file, line: line)
    }

    private func keys(_ change: (inout [String: Any]) -> Void) -> Provider {
        var keys = Provider.right
        change(&keys)
        return Provider(entitlements: keys, identity: "Apple Development")
    }

    func testAProviderWithNoPlistIsRefusedForIt() throws {
        let said = try refusalOfTheProvider { try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/Info.plist")) }
        XCTAssertEqual(said, "xx the AutoFill provider has no Info.plist, at Contents/PlugIns/OriPassAutoFill.appex")
    }

    /// A build with neither profile leaves the provider out, and what is
    /// left has to be that build all the way through.
    private func bundleWithNoProvider() throws -> URL {
        let app = try bundle()
        try FileManager.default.removeItem(at: Self.provider(in: app))
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/embedded.provisionprofile"))
        return app
    }

    func testABundleWithNoProviderAndNoProfileIsVerified() throws {
        let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        try XCTSkipUnless(identities.output.contains("Apple Development"), "no Apple Development identity on this Mac")
        let app = try bundleWithNoProvider()
        try sign(app, identity: "Apple Development", profiled: [:])
        let script = Self.root.appendingPathComponent("scripts/release.sh").path
        let checked = try run("/bin/bash", [script, "check", app.path])
        XCTAssertEqual(checked.status, 0, checked.output)
        XCTAssertTrue(checked.output.contains("\(Self.hostID) and \(Self.appexID) the same"), checked.output)
    }

    /// The capability with nothing to use it, which macOS would not start
    /// without a profile.
    func testABundleWithNoProviderThatClaimsTheCapabilityIsRefused() throws {
        let app = try bundleWithNoProvider()
        try sign(app)
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature should carry \(Self.groups) and \(Self.one) alone"), said)
        XCTAssertTrue(said.contains(Self.capability), said)
    }

    func testABundleWithNoProviderThatHoldsAProfileIsRefused() throws {
        let app = try bundleWithNoProvider()
        try profile(for: "com.meric.oripass").copy(to: app.appendingPathComponent("Contents/embedded.provisionprofile"))
        try sign(app, identity: "Apple Development", profiled: [:])
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx the app holds a provisioning profile and no AutoFill provider, at Contents/embedded.provisionprofile")
    }

    func testAProviderAtAnotherPointIsRefused() throws {
        let said = try refusalOfTheProvider { appex in
            let plist = appex.appendingPathComponent("Contents/Info.plist")
            var keys = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: plist), format: nil) as? [String: Any])
            keys["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension"]
            try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: plist)
        }
        XCTAssertTrue(said.hasPrefix("xx the provider's point is com.apple.Safari.web-extension"), said)
    }

    /// Without one of them the system offers the provider for no passkey or
    /// no code, and says nothing about why.
    private func refusalWith(_ capability: String, said value: Bool?) throws -> String {
        try refusalOfTheProvider { appex in
            let plist = appex.appendingPathComponent("Contents/Info.plist")
            var keys = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: plist), format: nil) as? [String: Any])
            var capabilities: [String: Any] = ["ProvidesPasswords": true, "ProvidesPasskeys": true, "ProvidesOneTimeCodes": true]
            capabilities[capability] = value
            keys["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.authentication-services-credential-provider-ui",
                                   "NSExtensionPrincipalClass": "OriPassAutoFill.CredentialProviderViewController",
                                   "NSExtensionAttributes": ["ASCredentialProviderExtensionCapabilities": capabilities]]
            try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0).write(to: plist)
        }
    }

    func testAProviderThatDoesNotSayItProvidesPasskeysIsRefused() throws {
        let said = try refusalWith("ProvidesPasskeys", said: nil)
        XCTAssertEqual(said, "xx the provider's ProvidesPasskeys is missing, and the system would offer it no passkey")
    }

    func testAProviderThatSaysItDoesNotProvidePasskeysIsRefused() throws {
        let said = try refusalWith("ProvidesPasskeys", said: false)
        XCTAssertEqual(said, "xx the provider's ProvidesPasskeys is false, and the system would offer it no passkey")
    }

    func testAProviderThatDoesNotSayItProvidesOneTimeCodesIsRefused() throws {
        let said = try refusalWith("ProvidesOneTimeCodes", said: nil)
        XCTAssertEqual(said, "xx the provider's ProvidesOneTimeCodes is missing, and the system would offer it no code field")
    }

    func testAProviderUnderAnotherNameIsRefused() throws {
        let said = try refusalOfTheProvider(signed: Provider(id: "com.meric.oripass.other", identity: "Apple Development"))
        XCTAssertEqual(said, "xx the provider is signed as com.meric.oripass.other, and the door takes \(Self.providerID)")
    }

    func testAProviderWithoutTheHardenedRuntimeIsRefused() throws {
        let said = try refusalOfTheProvider(signed: Provider(runtime: false, identity: "Apple Development"))
        XCTAssertTrue(said.hasPrefix("xx the provider's hardened runtime is off"), said)
    }

    /// The entitlement the whole card is for.
    func testAProviderWithoutTheCapabilityIsRefused() throws {
        let said = try refusalOfTheProvider(signed: keys { $0[Self.capability] = nil })
        XCTAssertTrue(said.hasPrefix("xx the provider should carry \(Self.capability)"), said)
    }

    func testTheCapabilityWrittenAsFalseIsRefused() throws {
        let said = try refusalOfTheProvider(signed: keys { $0[Self.capability] = false })
        XCTAssertEqual(said, "xx the provider's \(Self.capability) is there and is not true")
    }

    func testAProviderOutsideTheSandboxIsRefused() throws {
        let said = try refusalOfTheProvider(signed: keys { $0[Self.sandbox] = false })
        XCTAssertTrue(said.hasPrefix("xx the provider's sandbox is there and is not on"), said)
    }

    func testAProviderOutsideTheGroupIsRefused() throws {
        let said = try refusalOfTheProvider(signed: keys { $0[Self.groups] = ["\(Self.team).other"] })
        XCTAssertEqual(said, "xx the provider's \(Self.groups) does not name \(Self.group), where the door stands")
    }

    func testAProviderUnderAnotherAppIDIsRefused() throws {
        let said = try refusalOfTheProvider(signed: keys { $0[Self.appIDKey] = "\(Self.team).com.meric.oripass" })
        XCTAssertEqual(said, "xx the provider's \(Self.appIDKey) is not \(Self.team).\(Self.providerID)")
    }

    func testAProviderWithAnotherEntitlementIsRefusedAndNamed() throws {
        let said = try refusalOfTheProvider(signed: keys { $0["com.apple.security.network.client"] = true })
        XCTAssertTrue(said.contains("com.apple.security.network.client"), said)
    }

    func testAProviderOfNoTeamIsRefused() throws {
        let said = try refusalOfTheProvider(signed: Provider(identity: "-"))
        XCTAssertTrue(said.hasPrefix("xx the provider's team is not set, and \(Self.team) was expected"), said)
    }

    func testAProviderWithNoProfileIsRefused() throws {
        let said = try refusalOfTheProvider {
            try FileManager.default.removeItem(at: $0.appendingPathComponent("Contents/embedded.provisionprofile"))
        }
        XCTAssertEqual(said, "xx the provider has no provisioning profile, at Contents/embedded.provisionprofile, and nothing would load it")
    }

    /// Each with the app's own profile right, so what is refused is the
    /// provider's.
    func testAProfileForTheWrongAppIsRefused() throws {
        let wrong = try profile(for: "com.meric.oripass")
        let said = try refusalOfTheProvider { try wrong.copy(to: $0.appendingPathComponent("Contents/embedded.provisionprofile")) }
        XCTAssertEqual(said, "xx the provider's provisioning profile is not for \(Self.team).\(Self.providerID)")
    }

    func testAProfileWithoutTheCapabilityIsRefused() throws {
        let wrong = try profile(for: Self.providerID, capability: false)
        let said = try refusalOfTheProvider { try wrong.copy(to: $0.appendingPathComponent("Contents/embedded.provisionprofile")) }
        XCTAssertEqual(said, "xx the provider's provisioning profile does not hold the AutoFill capability, \(Self.capability)")
    }

    func testADevelopmentProfileIsRefused() throws {
        let wrong = try profile(for: Self.providerID, allDevices: false)
        let said = try refusalOfTheProvider { try wrong.copy(to: $0.appendingPathComponent("Contents/embedded.provisionprofile")) }
        XCTAssertTrue(said.hasPrefix("xx the provider's provisioning profile is not a Developer ID one"), said)
    }

    func testAProfileThatRanOutIsRefused() throws {
        let wrong = try profile(for: Self.providerID, expires: Date().addingTimeInterval(-86_400))
        let said = try refusalOfTheProvider { try wrong.copy(to: $0.appendingPathComponent("Contents/embedded.provisionprofile")) }
        XCTAssertTrue(said.hasPrefix("xx the provider's provisioning profile ran out on "), said)
    }

    func testWhatIsNoProfileIsRefused() throws {
        let said = try refusalOfTheProvider {
            try Data("not a profile".utf8).write(to: $0.appendingPathComponent("Contents/embedded.provisionprofile"))
        }
        XCTAssertTrue(said.hasPrefix("xx the provider's provisioning profile does not read as one"), said)
    }

    /// The app holds the capability too, and starts on the strength of its
    /// own profile.
    func testAnAppWithNoProfileIsRefused() throws {
        let app = try bundle()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/embedded.provisionprofile"))
        try sign(app, identity: "Apple Development")
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx the app has no provisioning profile, at Contents/embedded.provisionprofile, and macOS would not start it")
    }

    func testAnAppUnderAProfileForTheProviderIsRefused() throws {
        let app = try bundle()
        try profile(for: Self.providerID).copy(to: app.appendingPathComponent("Contents/embedded.provisionprofile"))
        try sign(app, identity: "Apple Development")
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx the app's provisioning profile is not for \(Self.team).com.meric.oripass")
    }

    func testAnAppWithoutTheCapabilityIsRefused() throws {
        let app = try bundle()
        try sign(app, profiled: [Self.teamKey: Self.team, Self.appIDKey: "\(Self.team).com.meric.oripass"])
        let said = try refusal(of: app)
        XCTAssertTrue(said.hasPrefix("xx the signature should carry \(Self.capability)"), said)
    }

    func testAnAppUnderAnotherAppIDIsRefused() throws {
        let app = try bundle()
        try sign(app, profiled: [Self.capability: true, Self.teamKey: Self.team, Self.appIDKey: "\(Self.team).\(Self.providerID)"])
        let said = try refusal(of: app)
        XCTAssertEqual(said, "xx \(Self.appIDKey) is not \(Self.team).com.meric.oripass")
    }

    /// One profile is a mistake, and says so before the minutes it would take.
    func testOneProfileWithoutTheOtherStopsBeforeItBuildsAnything() throws {
        let built = directory.appendingPathComponent("built")
        let tools = try tools(["xcodegen": "touch \"\(built.path)\"", "xcodebuild": "touch \"\(built.path)\""])
        let one = try profile(for: "com.meric.oripass").url.path
        for (app, provider) in [(one, nil), (nil, one), (one, "/nowhere")] as [(String?, String?)] {
            let ran = try script([], tools: tools, profiles: (app, provider))
            XCTAssertEqual(ran.status, 1, ran.output)
            XCTAssertEqual(ran.output, "xx the system's AutoFill needs both OP_APP_PROFILE and OP_AUTOFILL_PROFILE, each the path of a Developer ID provisioning profile; nothing was built\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: built.path))
        }
    }

    private static let leftOut = "== no provisioning profiles, so this build leaves the system's AutoFill out"

    /// Neither is a build for Safari and the SSH agent: the provider it built
    /// is taken out before anything is signed, and the app is signed as a
    /// Debug app is, with nothing a profile would have to cover.
    func testABuildWithNeitherProfileLeavesTheProviderOutAndSaysSo() throws {
        let app = try bundle()
        let log = directory.appendingPathComponent("signed.log")
        let ran = try release(build: #"mkdir -p "$out"; cp -R "\#(app.path)" "$out/OriPass.app"; rm "$out/OriPass.app/Contents/embedded.provisionprofile""#, also: ["codesign": """
            case " $* " in *" --sign "*) echo "$*" >> "\(log.path)" ;; esac
            exec /usr/bin/codesign "$@"
            """], neither: true)
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx the signature's team is not set"), ran.output)
        XCTAssertEqual(ran.output.components(separatedBy: Self.leftOut).count, 2, ran.output)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("OriPassAutoFill") }, "\(lines)")
        XCTAssertTrue(lines[2].hasSuffix("/OriPass.app"), lines[2])
        XCTAssertTrue(lines[2].contains("oripass-release.OriPass.entitlements"), lines[2])
        XCTAssertFalse(lines[2].contains("release.entitlements"), lines[2])
    }

    /// The profiles are a later step, and an install is not to wait for them.
    func testAnInstallWithNeitherProfileGoesOnToTheBuild() throws {
        let built = directory.appendingPathComponent("built")
        let ran = try script(["install"], tools: tools(["xcodegen": "exit 0", "xcodebuild": "touch \"\(built.path)\"; exit 65"]),
                             profile: "oripass")
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains(Self.leftOut), ran.output)
        XCTAssertTrue(ran.output.contains("xx the build failed"), ran.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: built.path))
    }

    func testABuildGivenTheWrongProfileStopsBeforeItBuildsAnything() throws {
        let built = directory.appendingPathComponent("built")
        let tools = try tools(["xcodegen": "touch \"\(built.path)\"", "xcodebuild": "touch \"\(built.path)\""])
        let app = try profile(for: "com.meric.oripass").url.path
        let ran = try script([], tools: tools, profiles: (app, app))
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx the provider's provisioning profile is not for"), ran.output)
        XCTAssertEqual(ran.left, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: built.path))
    }

    /// What goes up to the bundle is the file handed in, each to its own
    /// place, and before the code it authorises is signed.
    func testTheProfilesGoInBeforeTheCodeIsSigned() throws {
        let app = try bundle()
        let log = directory.appendingPathComponent("signed.log")
        let given = (try profile(for: "com.meric.oripass").url, try profile(for: Self.providerID).url)
        let ran = try release(build: #"mkdir -p "$out"; cp -R "\#(app.path)" "$out/OriPass.app""#, also: ["codesign": """
            case " $* " in *" --sign "*)
                last="${@: -1}"
                sum=$(shasum "$last/Contents/embedded.provisionprofile" 2>/dev/null | cut -d' ' -f1)
                echo "$sum" >> "\(log.path)" ;;
            esac
            exec /usr/bin/codesign "$@"
            """], profiles: (given.0.path, given.1.path))
        XCTAssertEqual(ran.status, 1, ran.output)
        func sum(_ file: URL) throws -> String {
            try run("/usr/bin/shasum", [file.path]).output.split(separator: " ").first.map(String.init) ?? ""
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [try sum(given.1), try sum(given.0)], "the provider's, then the app's, once the host is signed")
    }

    /// The files the script signs with hold what it looks for, the team as
    /// Xcode writes it, which the script puts in before it signs, and the
    /// provider asks for passwords and nothing a list of identities would
    /// be needed for.
    func testTheProviderTheScriptWantsIsTheOneInTheFiles() throws {
        let read = { (path: String) throws -> [String: Any] in
            let file = try Data(contentsOf: Self.root.appendingPathComponent(path))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
        }
        let provider = try read("AutoFill/OriPassAutoFill.entitlements")
        XCTAssertEqual(provider.count, 5, "\(provider)")
        XCTAssertEqual(provider[Self.capability] as? Bool, true)
        XCTAssertEqual(provider[Self.sandbox] as? Bool, true)
        XCTAssertEqual(provider[Self.groups] as? [String], ["$(DEVELOPMENT_TEAM).oripass"])
        XCTAssertEqual(provider[Self.appIDKey] as? String, "$(DEVELOPMENT_TEAM).\(Self.providerID)")
        XCTAssertEqual(provider[Self.teamKey] as? String, "$(DEVELOPMENT_TEAM)")

        let app = try read("AutoFill/OriPass.release.entitlements")
        XCTAssertEqual(app.count, 5, "\(app)")
        XCTAssertEqual(app[Self.capability] as? Bool, true)
        XCTAssertEqual(app[Self.one] as? Bool, true)
        XCTAssertEqual(app[Self.groups] as? [String], ["$(DEVELOPMENT_TEAM).oripass"])
        XCTAssertEqual(app[Self.appIDKey] as? String, "$(DEVELOPMENT_TEAM).com.meric.oripass")
        XCTAssertEqual(app[Self.teamKey] as? String, "$(DEVELOPMENT_TEAM)")

        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        XCTAssertEqual(Self.providerID, BridgeCaller.autofill.rawValue)
        XCTAssertTrue(script.contains("\nAUTOFILL_ID=\(Self.providerID)\n"), "AUTOFILL_ID in release.sh")
        XCTAssertTrue(script.contains("\nAUTOFILL_KEY=\(Self.capability)\n"), "AUTOFILL_KEY in release.sh")
    }

    // MARK: What a run leaves behind

    /// Fakes on the path of a run of the script, each a line of bash.
    private func tools(_ stubs: [String: String]) throws -> URL {
        let tools = directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for (name, body) in stubs {
            let file = tools.appendingPathComponent(name)
            try Data("#!/bin/bash\n\(body)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return tools
    }

    private func script(_ arguments: [String], tools: URL, profile: String? = nil,
                        profiles: (app: String?, provider: String?) = (nil, nil)) throws
        -> (status: Int32, output: String, left: [String]) {
        let temporary = directory.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var environment = ["PATH": "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporary.path + "/",
                           "OP_IDENTITY": "-", "HOME": directory.path]
        environment["OP_NOTARY_PROFILE"] = profile
        environment["OP_APP_PROFILE"] = profiles.app
        environment["OP_AUTOFILL_PROFILE"] = profiles.provider
        let path = Self.root.appendingPathComponent("scripts/release.sh").path
        let ran = try run("/bin/bash", [path] + arguments, environment: environment)
        let left = try FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted()
        return (ran.status, ran.output, left)
    }

    /// The whole script, with an `xcodegen` that does nothing and an
    /// `xcodebuild` that is `build`, in a `$TMPDIR` of the test's own. It
    /// signs ad hoc, so the run ends at the team's check at the latest:
    /// nothing is started and nothing is installed.
    private func release(build: String, also: [String: String] = [:],
                         profiles: (app: String, provider: String)? = nil, neither: Bool = false) throws
        -> (status: Int32, output: String, left: [String]) {
        let profiles: (app: String?, provider: String?) = neither ? (nil, nil)
            : try profiles ?? (profile(for: "com.meric.oripass").url.path, profile(for: Self.providerID).url.path)
        let stubs = ["xcodegen": "exit 0", "xcodebuild": """
            for word in "$@"; do
                case "$word" in CONFIGURATION_BUILD_DIR=*) out=${word#CONFIGURATION_BUILD_DIR=} ;; esac
            done
            echo "what the build said"
            \(build)
            """]
        return try script([], tools: tools(stubs.merging(also) { $1 }), profiles: profiles)
    }

    func testABuildThatFailsACheckIsRemovedAndItsLogsAreKept() throws {
        let app = try bundle()
        let ran = try release(build: """
            mkdir -p "$out/OriPass.app.dSYM" "$out/OriPass.swiftmodule"
            cp -R "\(app.path)" "$out/OriPass.app"
            """)
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx the signature's team is not set"), ran.output)
        XCTAssertFalse(ran.output.contains("replacing"), ran.output)
        XCTAssertEqual(ran.left, ["oripass-release.log", "oripass-release.sign.log"])
        let log = try String(contentsOf: directory.appendingPathComponent("tmp/oripass-release.log"), encoding: .utf8)
        XCTAssertEqual(log, "what the build said\n")
    }

    func testABuildThatDidNotBuildLeavesItsLogAndNothingElse() throws {
        let ran = try release(build: """
            mkdir -p "$out/OriPass.swiftmodule"
            exit 65
            """)
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx the build failed"), ran.output)
        XCTAssertEqual(ran.left, ["oripass-release.log"])
    }

    /// The app's signature seals what is inside it, so what is inside it is
    /// signed first, each with a timestamp Apple's notary will take. What the
    /// script's `codesign`s were handed is read from a `codesign` that writes
    /// it down and goes on to the real one.
    func testTheExtensionsAndTheHostAreSignedBeforeTheApp() throws {
        let app = try bundle()
        let log = directory.appendingPathComponent("signed.log")
        let ran = try release(build: #"mkdir -p "$out"; cp -R "\#(app.path)" "$out/OriPass.app""#, also: ["codesign": """
            case " $* " in *" --sign "*) echo "$*" >> "\(log.path)" ;; esac
            exec /usr/bin/codesign "$@"
            """])
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx the signature's team is not set"), ran.output)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertTrue(lines[0].hasSuffix("/Contents/PlugIns/OriPassSafari.appex"), lines[0])
        XCTAssertTrue(lines[0].contains("oripass-release.OriPassSafari.entitlements"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("/Contents/PlugIns/OriPassAutoFill.appex"), lines[1])
        XCTAssertTrue(lines[1].contains("oripass-release.OriPassAutoFill.entitlements"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("/Contents/Helpers/oripass-bridge"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("/OriPass.app"), lines[3])
        XCTAssertTrue(lines[3].contains("oripass-release.OriPass.release.entitlements"), lines[3])
        for line in lines {
            XCTAssertTrue(line.contains("--options runtime"), line)
            XCTAssertTrue(line.contains("--timestamp "), line)
            XCTAssertFalse(line.contains("--timestamp=none"), line)
        }
    }

    // MARK: Notarizing

    /// An `xcrun` that writes down what it was asked and answers for Apple,
    /// and a Gatekeeper that takes anything, in a run where nothing leaves
    /// this Mac.
    private func notarytool(saying answer: String, staple: Int = 0, validate: Int = 0) throws -> (tools: URL, log: URL) {
        let log = directory.appendingPathComponent("xcrun.log")
        let tools = try tools(["spctl": "exit 0", "xcrun": """
            echo "$*" >> "\(log.path)"
            case "$1 $2" in
                "notarytool submit") printf '%s' '\(answer)' ;;
                "stapler staple") exit \(staple) ;;
                "stapler validate") exit \(validate) ;;
            esac
            """])
        return (tools, log)
    }

    private func asked(in log: URL) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
    }

    func testAnInstallWithNoProfileStopsBeforeItBuildsAnything() throws {
        let built = directory.appendingPathComponent("built")
        let ran = try script(["install"], tools: tools(["xcodegen": "touch \"\(built.path)\"", "xcodebuild": "touch \"\(built.path)\""]))
        XCTAssertEqual(ran.status, 1, ran.output)
        let sentences = ran.output.split(separator: "\n").filter { $0.hasPrefix("xx ") }
        XCTAssertEqual(sentences, ["xx make install needs OP_NOTARY_PROFILE, the name given to xcrun notarytool store-credentials; nothing was built or installed"])
        XCTAssertEqual(ran.output.split(separator: "\n").count, 1, ran.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: built.path))
        XCTAssertEqual(ran.left, [])
    }

    func testAnAcceptedBuildIsStapledAndThenHeldToItsTicket() throws {
        let app = try bundle()
        let (tools, log) = try notarytool(saying: #"{"id":"one","status":"Accepted"}"#)
        let ran = try script(["notarize", app.path], tools: tools, profile: "oripass")
        XCTAssertEqual(ran.status, 0, ran.output)
        XCTAssertEqual(try asked(in: log), ["notarytool submit", "stapler staple", "stapler validate"])
        let submitted = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")[0]
        XCTAssertTrue(submitted.contains("--keychain-profile oripass"), String(submitted))
        XCTAssertTrue(submitted.contains("--wait"), String(submitted))
        XCTAssertEqual(ran.left, [], "the zip went to Apple and nothing keeps it")
    }

    func testABuildAppleTurnedDownGetsNoTicketAndSaysWhereWhyIs() throws {
        let app = try bundle()
        let (tools, log) = try notarytool(saying: #"{"id":"one","status":"Invalid"}"#)
        let ran = try script(["notarize", app.path], tools: tools, profile: "oripass")
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx Apple said Invalid of the build; xcrun notarytool log one --keychain-profile oripass has why"), ran.output)
        XCTAssertEqual(try asked(in: log), ["notarytool submit"])
    }

    func testNoAnswerFromAppleIsSaidAndGoesNoFurther() throws {
        let app = try bundle()
        let (tools, log) = try notarytool(saying: "")
        let ran = try script(["notarize", app.path], tools: tools, profile: "nothing")
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx Apple gave no answer: is nothing a profile on this Mac"), ran.output)
        XCTAssertEqual(try asked(in: log), ["notarytool submit"])
    }

    func testATicketThatWouldNotStapleIsSaid() throws {
        let app = try bundle()
        let (tools, _) = try notarytool(saying: #"{"id":"one","status":"Accepted"}"#, staple: 65)
        let ran = try script(["notarize", app.path], tools: tools, profile: "oripass")
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx Apple accepted the build and its ticket would not staple"), ran.output)
    }

    func testABundleWithNoTicketIsRefused() throws {
        let app = try bundle()
        let (tools, _) = try notarytool(saying: "", validate: 65)
        let ran = try script(["ticket", app.path], tools: tools)
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx no ticket is stapled to \(app.path)"), ran.output)
    }

    func testAStapledBundleGatekeeperRefusesIsRefused() throws {
        let app = try bundle()
        let (tools, _) = try notarytool(saying: "")
        try Data("#!/bin/bash\necho rejected >&2\nexit 3\n".utf8).write(to: tools.appendingPathComponent("spctl"))
        let ran = try script(["ticket", app.path], tools: tools)
        XCTAssertEqual(ran.status, 1, ran.output)
        XCTAssertTrue(ran.output.contains("xx Gatekeeper does not take \(app.path): rejected"), ran.output)
    }

    /// Between the signing and the copy, on the build and again on the copy,
    /// which no test can run, since it replaces the real app.
    func testTheCopyInApplicationsComesAfterTheTicket() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        let notarized = try XCTUnwrap(script.range(of: "\nnotarize \"$APP\"\n"))
        let removed = try XCTUnwrap(script.range(of: "rm -rf \"$INSTALLED\""))
        let again = try XCTUnwrap(script.range(of: "\nticket \"$INSTALLED\"\n"))
        XCTAssertLessThan(notarized.lowerBound, removed.lowerBound)
        XCTAssertLessThan(removed.lowerBound, again.lowerBound)
    }

    /// `check` is handed somebody's bundle to read, and removes nothing.
    func testTheChecksAloneLeaveTheBundleTheyRead() throws {
        let app = try bundle()
        try sign(app)
        _ = try refusal(of: app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    /// The script signs with the file the app is built with, and looks for
    /// the key that file holds.
    func testTheEntitlementTheScriptWantsIsTheOneInTheFile() throws {
        let file = try Data(contentsOf: Self.root.appendingPathComponent("OriPass.entitlements"))
        let keys = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
        XCTAssertEqual(keys.count, 2, "\(keys)")
        XCTAssertEqual(keys[Self.one] as? Bool, true)
        XCTAssertEqual(keys[Self.groups] as? [String], ["$(DEVELOPMENT_TEAM).oripass"])
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("\nENTITLEMENT=\(Self.one)\n"), "ENTITLEMENT in release.sh")
        XCTAssertTrue(script.contains("\nGROUP=$TEAM.oripass\n"), "GROUP in release.sh")
    }

    /// And the host's, which holds the group alone, under the name the door
    /// takes it by.
    func testTheHostTheScriptWantsIsTheOneTheDoorTakes() throws {
        let file = try Data(contentsOf: Self.root.appendingPathComponent("Helper/oripass-bridge.entitlements"))
        let keys = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
        XCTAssertEqual(keys.count, 1, "\(keys)")
        XCTAssertEqual(keys[Self.groups] as? [String], ["$(DEVELOPMENT_TEAM).oripass"])
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        XCTAssertEqual(Self.hostID, BridgeCaller.host.rawValue)
        XCTAssertTrue(script.contains("\nHELPER_ID=\(Self.hostID)\n"), "HELPER_ID in release.sh")
    }

    /// And the extension's, the sandbox and the group, which is all the
    /// system lets it have and all it needs.
    func testTheExtensionTheScriptWantsIsTheOneInTheFile() throws {
        let file = try Data(contentsOf: Self.root.appendingPathComponent("Safari/OriPassSafari.entitlements"))
        let keys = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
        XCTAssertEqual(keys.count, 2, "\(keys)")
        XCTAssertEqual(keys[Self.sandbox] as? Bool, true)
        XCTAssertEqual(keys[Self.groups] as? [String], ["$(DEVELOPMENT_TEAM).oripass"])
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
        XCTAssertEqual(Self.appexID, BridgeCaller.safari.rawValue)
        XCTAssertTrue(script.contains("\nEXTENSION_ID=\(Self.appexID)\n"), "EXTENSION_ID in release.sh")
        XCTAssertTrue(script.contains("\nSANDBOX=\(Self.sandbox)\n"), "SANDBOX in release.sh")
    }
}
