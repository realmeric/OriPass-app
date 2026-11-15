import XCTest
@testable import OriPass

final class AppInfoTests: XCTestCase {
    /// The defaults domain, the log subsystem and the folder under Application
    /// Support are all this string, and `make canary` searches by it.
    func testTheBundleIsOriPass() {
        XCTAssertEqual(AppInfo.bundleID, "com.meric.oripass")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.meric.oripass")
    }

    /// A door, or anything else, that took the app's own defaults unless it
    /// was handed others would read and write the real ones in every test
    /// that forgot to hand it some. The delegate names them where it means
    /// them.
    func testNothingTakesTheAppsOwnDefaultsWithoutBeingHandedThem() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "read \(files.count) files under \(sources.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(text.range(of: #"UserDefaults\??\s*=\s*\.standard"#, options: .regularExpression),
                         "\(file.lastPathComponent) has a parameter that is the app's defaults when nobody says")
        }
    }
}
