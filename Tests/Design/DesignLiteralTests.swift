import Foundation
import XCTest
@testable import OriPass

/// Reads `Sources/` line by line for a colour, a font size or a distance
/// written as a literal anywhere but `Palette`, `Fonts` and `Metrics`.
///
/// It is a grep and not a parser, so it knows the ways such a literal is
/// usually spelled and nothing more. Two things it lets through on purpose:
/// zero, which is the absence of a distance, and a share of a side
/// (`side * 0.13`), which is how `AppMark` draws itself in whatever rect it
/// is given and is a shape and not a measurement.
final class DesignLiteralTests: XCTestCase {
    private static let home = ["Palette.swift", "Fonts.swift", "Metrics.swift"]

    private static let colourNames = "white|black|clear|gray|grey|red|orange|yellow|green|mint|teal|cyan|blue"
        + "|indigo|purple|pink|brown|primary|secondary|accentColor"

    private static let rules: [(kind: String, pattern: String)] = [
        // 0xRRGGBB, with or without alpha.
        ("colour", #"\b0x[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?\b"#),
        ("colour", #"\b(NS|CG|UI)?Color\(\s*(\.sRGB|\.displayP3|red:|white:|hue:|srgbRed:|calibratedRed:|calibratedWhite:|deviceRed:|deviceWhite:|displayP3Red:|genericGamma22White:|gray:)"#),
        ("colour", #"#colorLiteral"#),
        ("colour", #"\bColor\.(\#(colourNames))\b"#),
        ("colour", #"\bNSColor\.[a-zA-Z]+\b(?!\()"#),
        ("colour", #"\.(foregroundStyle|foregroundColor|fill|stroke|background|tint|border|shadow|listRowBackground)\(\s*(color:\s*)?\.(\#(colourNames))\b"#),
        // A share of a colour is another colour. Nought and one are there
        // and not there.
        ("colour", #"\.(opacity|withAlphaComponent)\(\s*(0?\.\d+|0\.\d*[1-9]\d*)\s*\)"#),

        ("font size", #"\.system\(\s*size:"#),
        ("font size", #"\bFont\.custom\("#),
        ("font size", #"\bNSFont\b.*\b(ofSize|size):"#),
        ("font size", #"\.font\(\s*(Font)?\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b"#),

        ("distance", #"\b(width|height|minWidth|idealWidth|maxWidth|minHeight|idealHeight|maxHeight|spacing|cornerRadius|lineWidth|radius|size|x|y|dx|dy|top|leading|bottom|trailing|left|right|horizontal|vertical)\s*:\s*-?(\d*\.)?\d*[1-9]"#),
        // A constant a view keeps for itself, and a size handed to
        // `Metrics.scaled` from outside it.
        ("distance", #"\bCGFloat\s*=\s*-?(\d*\.)?\d*[1-9]"#),
        ("distance", #"\bscaled\(\s*-?(\d*\.)?\d*[1-9]"#),
        ("distance", #"\.(padding|blur|inset|insetBy|offset)\(\s*(\.[a-zA-Z]+\s*,\s*|\[[^\]]*\]\s*,\s*)?-?(\d*\.)?\d*[1-9]"#),
    ]

    private struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let kind: String
        let text: String

        var description: String { "\(file):\(line) has a literal \(kind): \(text)" }
    }

    /// What a line of code says once its comment is taken off. A string that
    /// holds two slashes loses its tail too, which costs nothing here.
    private static func code(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[..<comment.lowerBound])
    }

    private static func kinds(in line: String) -> [String] {
        let text = code(line)
        return rules.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.kind)
    }

    /// The repository, from where this file was compiled. The tests run on
    /// the Mac that built them, so the sources are still there.
    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func swiftFiles() throws -> [URL] {
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    func testNoColourFontSizeOrDistanceIsWrittenOutsideDesign() throws {
        let files = try Self.swiftFiles()
        // Fewer than this and the walk did not find the sources at all.
        XCTAssertGreaterThan(files.count, 20, "read \(files.count) files under \(Self.sources.path)")
        for name in Self.home {
            XCTAssertTrue(files.contains { $0.lastPathComponent == name }, "\(name) was not read")
        }

        var hits: [Hit] = []
        for file in files where !Self.home.contains(file.lastPathComponent) {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                for kind in Self.kinds(in: line) {
                    hits.append(Hit(file: file.lastPathComponent, line: index + 1, kind: kind,
                                    text: line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "\n" + hits.map(\.description).joined(separator: "\n"))
    }

    /// The three files it skips are where the literals are, so a rule that
    /// stopped matching would show here before it showed anywhere else.
    func testTheThreeFilesItSkipsAreFullOfThem() throws {
        for name in Self.home {
            let file = try XCTUnwrap(Self.swiftFiles().first { $0.lastPathComponent == name })
            let text = try String(contentsOf: file, encoding: .utf8)
            let found = text.components(separatedBy: "\n").flatMap(Self.kinds(in:))
            XCTAssertGreaterThan(found.count, 5, "\(name) has \(found.count) literals the rules can see")
        }
    }

    func testItCatchesWhatAViewWouldWrite() {
        let caught = [
            "Color(red: 0.1, green: 0.2, blue: 0.3)",
            "let ground = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)",
            "static let content = dynamic(light: 0xFFFFFF, dark: 0x1E1F22)",
            "Text(name).foregroundStyle(.red)",
            "Circle().fill(Color.white)",
            "view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor",
            "Text(name).foregroundStyle(Palette.text.opacity(0.6))",
            "Text(name).font(.system(size: 13))",
            "Text(name).font(.headline)",
            "field.font = NSFont.systemFont(ofSize: 13)",
            "contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),",
            "HStack(spacing: 8) {",
            ".padding(12)",
            ".padding(.horizontal, 16)",
            ".frame(width: 250)",
            "RoundedRectangle(cornerRadius: 7.5)",
            ".offset(x: -4)",
            ".stroke(Palette.hairline, lineWidth: 0.5)",
            "private let inset: CGFloat = 14",
            ".frame(height: Metrics.scaled(28))",
        ]
        for line in caught {
            XCTAssertFalse(Self.kinds(in: line).isEmpty, "let through: \(line)")
        }
    }

    func testItLetsThroughWhatIsNotALiteral() {
        let allowed = [
            "contentRect: NSRect(origin: .zero, size: Metrics.windowSize),",
            "HStack(spacing: Metrics.close) {",
            ".padding(.horizontal, Metrics.wide)",
            ".frame(width: Metrics.sidebarWidth)",
            ".frame(maxWidth: .infinity)",
            "let rect = CGRect(x: 0, y: 0, width: side, height: side)",
            "let radius = side * 0.13",
            "width: side * 0.92, height: side * 0.66)",
            "Text(name).font(Fonts.body).foregroundStyle(Palette.text)",
            ".opacity(isShown ? 1 : 0)",
            ".opacity(0)",
            "var offset: CGFloat = 0",
            ".frame(height: Metrics.scaled(row))",
            ".padding(.top) // 12 would be a literal",
            "var hash: UInt64 = 0xcbf2_9ce4_8422_2325",
            "static let quick = Curve(duration: 0.18, damping: 1)",
            "let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })",
        ]
        for line in allowed {
            XCTAssertEqual(Self.kinds(in: line), [], "caught: \(line)")
        }
    }
}
