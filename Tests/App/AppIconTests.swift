import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The icon is ten files that `scripts/make-icon.swift` drew and git keeps.
/// The script cannot import the app, so these read the files back and hold
/// them to what the app says its mark and its blue are, and to the script
/// as it stands today.
@MainActor
final class AppIconTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let iconSet = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")

    /// The ten macOS asks for, in points and pixels to the point.
    private static let sizes: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    private static func name(_ points: Int, _ scale: Int) -> String {
        "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    }

    /// One file's pixels, as the four numbers each was written with.
    private struct Pixels {
        let bitmap: NSBitmapImageRep
        var side: Int { bitmap.pixelsWide }

        init(_ url: URL) throws {
            bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)), url.lastPathComponent)
        }

        /// Red, green, blue and alpha at a pixel counted from the top left.
        func at(_ x: Int, _ y: Int) -> [CGFloat] {
            guard let colour = bitmap.colorAt(x: x, y: y) else { return [0, 0, 0, 0] }
            return [colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent]
        }

        func isClose(_ x: Int, _ y: Int, to wanted: [CGFloat], within: CGFloat = 0.03) -> Bool {
            zip(at(x, y), wanted).allSatisfy { abs($0 - $1) < within }
        }
    }

    /// `Palette.lit` as it is in light, which is the one appearance an icon
    /// has.
    private var blue: [CGFloat] {
        var found: [CGFloat] = []
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let colour = NSColor(Palette.lit).usingColorSpace(.sRGB) {
                found = [colour.redComponent, colour.greenComponent, colour.blueComponent, 1]
            }
        }
        return found
    }

    /// The smallest rectangle of pixels that holds every one in `blue`.
    private func pass(in pixels: Pixels) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let blue = blue
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in 0..<pixels.side {
            for x in 0..<pixels.side where pixels.isClose(x, y, to: blue) {
                box = box.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return box
    }

    func testTheCatalogueHoldsEverySizeAtItsOwnPixels() throws {
        struct Contents: Decodable {
            struct Image: Decodable, Hashable {
                let filename: String
                let idiom: String
                let scale: String
                let size: String
            }
            let images: [Image]
        }
        let listed = try JSONDecoder().decode(
            Contents.self, from: Data(contentsOf: Self.iconSet.appendingPathComponent("Contents.json"))).images
        XCTAssertEqual(Set(listed), Set(Self.sizes.map { points, scale in
            Contents.Image(filename: Self.name(points, scale), idiom: "mac", scale: "\(scale)x",
                           size: "\(points)x\(points)")
        }))
        XCTAssertEqual(listed.count, 10)

        let found = try FileManager.default.contentsOfDirectory(atPath: Self.iconSet.path)
        XCTAssertEqual(Set(found), Set(listed.map(\.filename) + ["Contents.json"]), "a file nothing lists")

        for (points, scale) in Self.sizes {
            let name = Self.name(points, scale)
            let pixels = try Pixels(Self.iconSet.appendingPathComponent(name))
            XCTAssertEqual(pixels.bitmap.pixelsWide, points * scale, name)
            XCTAssertEqual(pixels.bitmap.pixelsHigh, points * scale, name)
            XCTAssertEqual(pixels.bitmap.size, NSSize(width: points, height: points), name)
            // Nothing in the corner, where the tile is round and the grid
            // leaves a margin.
            XCTAssertEqual(pixels.at(0, 0)[3], 0, name)
            XCTAssertEqual(pixels.at(pixels.side - 1, 0)[3], 0, name)
        }
    }

    /// At every size, the sixteen pixels of the smallest included: a block
    /// of the app's blue most of the tile wide, wider than it is tall, with
    /// three holes in a row across it.
    func testThePassAndItsThreeDotsAreThereAtEverySize() throws {
        let blue = blue
        XCTAssertEqual(blue.count, 4)
        for (points, scale) in Self.sizes {
            let name = Self.name(points, scale)
            let pixels = try Pixels(Self.iconSet.appendingPathComponent(name))
            let box = try XCTUnwrap(pass(in: pixels), "\(name) has none of the app's blue in it")
            let width = box.maxX - box.minX + 1
            let height = box.maxY - box.minY + 1
            XCTAssertGreaterThan(CGFloat(width), CGFloat(pixels.side) * 0.5, "\(name): the pass is a speck")
            XCTAssertGreaterThan(width, height, name)
            // The pass sits in the middle of the tile, to a pixel.
            XCTAssertLessThanOrEqual(abs(box.minX - (pixels.side - 1 - box.maxX)), 1, name)

            // The row with the most in it that is not blue is the dots'.
            var most = 0
            for y in box.minY...box.maxY {
                var runs = 0
                var wasBlue = true
                // Inside the round corners and the fold.
                for x in (box.minX + width / 5)...(box.maxX - width / 5) {
                    let isBlue = pixels.isClose(x, y, to: blue)
                    if wasBlue && !isBlue { runs += 1 }
                    wasBlue = isBlue
                }
                most = max(most, runs)
            }
            XCTAssertEqual(most, 3, "\(name): the dots cannot be counted")
        }
    }

    /// From 64 pixels up the shape is `AppMark`'s own, share for share. The
    /// two files under that are set on whole pixels by hand and are held by
    /// the test above only.
    func testTheShapeIsTheAppsOwnMark() throws {
        let blue = blue
        for (points, scale) in Self.sizes where points * scale >= 64 {
            let name = Self.name(points, scale)
            let pixels = try Pixels(Self.iconSet.appendingPathComponent(name))
            let box = try XCTUnwrap(pass(in: pixels), name)
            // The pass is 0.92 of the mark's square wide and in its middle.
            let unit = AppMark().path(in: CGRect(x: 0, y: 0, width: 1, height: 1)).boundingRect
            let side = CGFloat(box.maxX - box.minX + 1) / unit.width
            let square = CGRect(x: CGFloat(box.minX + box.maxX + 1) / 2 - side / 2,
                                y: CGFloat(box.minY + box.maxY + 1) / 2 - side / 2, width: side, height: side)
            let path = AppMark().path(in: square)

            var read = 0
            var wrong = 0
            let step = max(1, pixels.side / 128)
            for y in stride(from: Int(square.minY), to: Int(square.maxY), by: step) {
                for x in stride(from: Int(square.minX), to: Int(square.maxX), by: step) {
                    read += 1
                    let centre = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    if path.contains(centre, eoFill: true) != pixels.isClose(x, y, to: blue) { wrong += 1 }
                }
            }
            XCTAssertGreaterThan(read, 1000, name)
            // What is left over is the edge, which is half one and half the
            // other for a pixel's width.
            XCTAssertLessThan(CGFloat(wrong) / CGFloat(read), 0.03, "\(name): \(wrong) of \(read) are not the mark's")
        }
    }

    /// D1 and D8: at no size somebody else's. Bitwarden's tile is blue, and
    /// black where macOS draws icons dark, with a white mark on it;
    /// 1Password's is a ring. This one's tile is paper and its mark is solid,
    /// so a script that was handed the lock screen's white on blue fails
    /// here.
    func testTheTileIsPaperAndTheMarkIsSolid() throws {
        for (points, scale) in Self.sizes {
            let name = Self.name(points, scale)
            let pixels = try Pixels(Self.iconSet.appendingPathComponent(name))
            let box = try XCTUnwrap(pass(in: pixels), name)
            let middle = pixels.side / 2
            // Half way between the tile's edge and the pass, above and under.
            for y in [(pixels.side / 10 + box.minY) / 2, (pixels.side * 9 / 10 + box.maxY) / 2] {
                let ground = pixels.at(middle, y)
                XCTAssertGreaterThan(ground[3], 0.99, "\(name) row \(y)")
                XCTAssertGreaterThan(ground[0...2].min() ?? 0, 0.85, "\(name) row \(y): the tile is not paper")
            }
            // Not a ring: the pass is blue from its left edge to its first
            // dot, a little above the dots' row.
            let y = box.minY + (box.maxY - box.minY) / 4
            for x in (box.minX + 2)..<middle where x < box.maxX - (box.maxX - box.minX) / 4 {
                XCTAssertTrue(pixels.isClose(x, y, to: blue), "\(name): a gap in the pass at \(x), \(y)")
            }
        }
    }

    /// What is checked in is what the script draws today. It is run in a
    /// directory of its own, where it writes a catalogue of its own, and no
    /// file of the repository is touched.
    func testTheScriptStillDrawsWhatIsCheckedIn() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        // A module cache of its own, so the run leaves nothing under the
        // home directory.
        run.arguments = ["swift", "-module-cache-path", work.appendingPathComponent("modules").path,
                         Self.root.appendingPathComponent("scripts/make-icon.swift").path]
        run.currentDirectoryURL = work
        // xcodebuild's own environment names an SDK and a toolchain for the
        // test, which are not the script's.
        let ours = ProcessInfo.processInfo.environment
        run.environment = ["PATH": "/usr/bin:/bin", "HOME": work.path, "TMPDIR": work.path,
                           "DEVELOPER_DIR": ours["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("wrote 10 app icon sizes\n"), output)
        XCTAssertTrue(output.hasSuffix("wrote the iPhone's icon in three looks\n"), output)

        let drawn = work.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
        for (points, scale) in Self.sizes {
            let name = Self.name(points, scale)
            let fresh = try Pixels(drawn.appendingPathComponent(name))
            let kept = try Pixels(Self.iconSet.appendingPathComponent(name))
            XCTAssertEqual(fresh.side, kept.side, name)
            var different = 0
            for y in 0..<min(fresh.side, kept.side) {
                for x in 0..<min(fresh.side, kept.side) where !fresh.isClose(x, y, to: kept.at(x, y), within: 0.01) {
                    different += 1
                }
            }
            XCTAssertEqual(different, 0, "\(name) is not what `make icon` writes: run it and commit")
        }
        XCTAssertEqual(try Data(contentsOf: drawn.appendingPathComponent("Contents.json")),
                       try Data(contentsOf: Self.iconSet.appendingPathComponent("Contents.json")))
    }

    /// The build compiled the catalogue into the bundle and the Info.plist
    /// names it, so the Dock has something to draw.
    func testTheBundleCarriesTheIcon() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, AppIcon.name)
        let icon = try XCTUnwrap(AppIcon.image, "the bundle has no AppIcon")
        let widest = icon.representations.map(\.pixelsWide).max() ?? 0
        XCTAssertGreaterThanOrEqual(widest, 1024)
    }

    /// The three renders `make shots` leaves beside the surfaces are of the
    /// bundle's own icon, each from the file drawn for its size.
    func testTheRendersBesideTheShotsAreTheBundlesIcon() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-icon-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let icon = try XCTUnwrap(AppIcon.image)
        let report = await Shots.write([], from: DemoVault.backend(), into: directory, icon: icon)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.written, [])
        XCTAssertEqual(report.icons, ["icon-16.png", "icon-32.png", "icon-512.png"])

        let blue = blue
        for points in AppIcon.renders {
            // Still there after the run swept the directory.
            let pixels = try Pixels(directory.appendingPathComponent(AppIcon.file(points)))
            XCTAssertEqual(pixels.side, points * 2)
            XCTAssertEqual(pixels.bitmap.size, NSSize(width: points, height: points))
            XCTAssertEqual(pixels.at(0, 0)[3], 0, "\(points)")
            // Above the dots, a third of the way down, the pass.
            XCTAssertTrue(pixels.isClose(pixels.side / 2, pixels.side * 2 / 5, to: blue, within: 0.05), "\(points)")
        }

        let none = await Shots.write([], from: DemoVault.backend(), into: directory)
        XCTAssertEqual(none.icons, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icon-16.png").path),
                       "a run that drew no icon leaves the last run's")
    }
}
