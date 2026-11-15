import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class ShotsTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-shots-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func bitmap(_ file: String) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(file))))
    }

    /// How far the details column of a shot is from a colour, as the largest
    /// difference in any of the three channels. The point is a toolbar's
    /// height under the toolbar and as far inside the window's right edge,
    /// clear of the empty state in the column's middle.
    private func distance(ofTheDetailsIn bitmap: NSBitmapImageRep, from hex: UInt32) throws -> CGFloat {
        // The components as they are in the file, which `Shots` wrote in sRGB.
        // `colorAt` hands them back under a calibrated name, and converting
        // from that moves them.
        XCTAssertEqual(bitmap.colorSpace, .sRGB)
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let inset = Int(Metrics.toolbarHeight * scale)
        let middle = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - inset, y: inset * 2))
        let wanted = Palette.nsColor(hex)
        return max(abs(middle.redComponent - wanted.redComponent),
                   abs(middle.greenComponent - wanted.greenComponent),
                   abs(middle.blueComponent - wanted.blueComponent))
    }

    private let broken = Surface(name: "broken", size: Metrics.windowSize) { _ in
        throw Shots.Failure.brokenOnPurpose
    }

    private let four = ["light", "dark", "compact-light", "compact-dark"]

    func testTheEmptyWindowIsWrittenInItsLightHalfAndItsDarkHalf() async throws {
        let report = await Shots.write(Surface.all, from: DemoVault.backend(), into: directory)
        XCTAssertEqual(report.problems, [])
        XCTAssertTrue(report.written.contains("window-empty-light.png"))
        XCTAssertTrue(report.written.contains("window-empty-dark.png"))
        XCTAssertEqual(Shots.looks.map(\.name), four)
        XCTAssertEqual(report.written.count, Surface.all.count * 4)
        for surface in Surface.all {
            for look in four {
                XCTAssertTrue(report.written.contains("\(surface.name)-\(look).png"), "\(surface.name) \(look)")
            }
        }
        XCTAssertEqual(Metrics.density, .comfortable, "the run leaves the app's own density as it was")

        let light = try bitmap("window-empty-light.png")
        let dark = try bitmap("window-empty-dark.png")
        XCTAssertEqual(light.size, Metrics.windowSize)
        XCTAssertEqual(dark.size, Metrics.windowSize)
        // `Palette.content`, each half where it belongs. A shot that took the
        // system's appearance for both would fail one of the two.
        XCTAssertLessThan(try distance(ofTheDetailsIn: light, from: 0xFFFFFF), 0.02)
        XCTAssertLessThan(try distance(ofTheDetailsIn: dark, from: 0x1D1D1D), 0.02)

        let written = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        XCTAssertEqual(try JSONDecoder().decode(ShotReport.self, from: written), report)
    }

    func testASurfaceThatThrowsIsAProblemAndTheOthersAreStillWritten() async throws {
        let report = await Shots.write([broken, .emptyWindow], from: DemoVault.backend(), into: directory)
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.problems.map(\.surface), ["broken", "broken", "broken", "broken"])
        XCTAssertEqual(report.problems.map(\.appearance), four)
        XCTAssertEqual(report.problems.first?.reason, "brokenOnPurpose")
        XCTAssertEqual(report.written, four.map { "window-empty-\($0).png" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken-light.png").path))

        let written = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        XCTAssertEqual(try JSONDecoder().decode(ShotReport.self, from: written).problems.count, 4)
    }

    /// A compact shot is the same surface in the same appearance with its
    /// rows closer: the same size and the same ground, and other pixels.
    func testTheCompactShotsAreOfTheSameSurfaceDrawnTighter() async throws {
        let login = try XCTUnwrap(Surface.all.first { $0.name == "detail-login" })
        let report = await Shots.write([login], from: DemoVault.backend(), into: directory)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.written, four.map { "detail-login-\($0).png" })

        for (appearance, ground) in [("light", UInt32(0xFFFFFF)), ("dark", 0x1D1D1D)] {
            let comfortable = try bitmap("detail-login-\(appearance).png")
            let compact = try bitmap("detail-login-compact-\(appearance).png")
            XCTAssertEqual(compact.size, comfortable.size)
            XCTAssertLessThan(try distance(ofTheDetailsIn: compact, from: ground), 0.02, appearance)
            XCTAssertNotEqual(compact.tiffRepresentation, comfortable.tiffRepresentation, appearance)
        }
    }

    /// A text field kept at a height that is not its line's, which is how
    /// the first layout now and then leaves one on a busy Mac.
    private struct Squeezed: NSViewRepresentable {
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(labelWithString: "Spotify")
            field.font = .boldSystemFont(ofSize: 24)
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {}

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
            CGSize(width: 200, height: 12)
        }
    }

    func testAFieldThatIsNotTheHeightOfItsLineIsSeenAndNoShotIsWrittenOfIt() async throws {
        let field = NSTextField(string: "Spotify")
        field.font = .boldSystemFont(ofSize: 24)
        let line = NSLayoutManager().defaultLineHeight(for: .boldSystemFont(ofSize: 24))
        let around = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        around.addSubview(field)
        for (height, isMisfit) in [(line, false), (line + 1, false), (line - 1, false), (line - 12, true), (line + 4, true)] {
            field.frame = NSRect(x: 0, y: 0, width: 200, height: height)
            XCTAssertEqual(Shots.misfitField(in: around) != nil, isMisfit, "\(height) for a line of \(line)")
        }

        let squeezed = Surface(name: "squeezed", size: Metrics.windowSize) { _ in
            AnyView(Squeezed())
        }
        let report = await Shots.write([squeezed, .emptyWindow], from: DemoVault.backend(), into: directory)
        let said = "misfitField(line: \(line), height: 12.0)"
        XCTAssertEqual(report.problems.map(\.reason), [said, said, said, said], "the problem says the two heights")
        XCTAssertEqual(report.written, four.map { "window-empty-\($0).png" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("squeezed-light.png").path))
    }

    /// A window for each shot, and none of them left when the shots are
    /// written, and a file that this run did not write gone from beside
    /// them, whatever it is called.
    func testAfterARunNoWindowIsLeftAndNoFileItDidNotWrite() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stray in ["report 2.json", "window-empty-light 2.png", "no-longer-drawn-dark.png"] {
            try Data("old".utf8).write(to: directory.appendingPathComponent(stray))
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("report.json"))
        let windows = NSApp.windows.count

        let report = await Shots.write(Surface.all, from: DemoVault.backend(), into: directory)
        XCTAssertEqual(NSApp.windows.count, windows, "\(report.written.count) shots left windows behind")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.sorted(), (report.written + ["report.json"]).sorted())
        let written = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        XCTAssertEqual(try JSONDecoder().decode(ShotReport.self, from: written), report, "the report replaced the old one")
    }

    func testDrawingStartsNoChildAndAsksTheBackendNothing() async {
        let backend = DemoVault.backend()
        let children = Shots.childCount
        let report = await Shots.write(Surface.all, from: backend, into: directory)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(report.children, children)

        // What an unlock asks and nothing after it: no surface went round the
        // store.
        let unlockedOnly = DemoVault.backend()
        let store = VaultStore(backend: unlockedOnly)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.backgroundSync?.value
        XCTAssertEqual(backend.calls.sorted(), unlockedOnly.calls.sorted())
        XCTAssertFalse(backend.calls.isEmpty)
    }
}
