import SwiftUI
import XCTest
@testable import OriPass

/// Every animation the app has, twice over: what each of `Motion`'s forms
/// becomes under Reduce Motion, and a read of `Sources/` for an animation
/// that did not come through `Motion` and so has no plain form.
///
/// The second is a grep and not a parser, as `DesignLiteralTests` is.
final class MotionTests: XCTestCase {
    // MARK: The plain forms

    func testEveryCurveBecomesOneShortStraightFadeUnderReduceMotion() {
        XCTAssertEqual(Motion.curves, [Motion.quick, Motion.door, Motion.slide])
        let plain = Animation.linear(duration: Motion.reducedDuration)
        for curve in Motion.curves {
            XCTAssertEqual(Motion.animation(curve, reduced: true), plain)
            XCTAssertEqual(Motion.animation(curve, reduced: false),
                           .spring(response: curve.duration, dampingFraction: curve.damping))
            XCTAssertNotEqual(Motion.animation(curve, reduced: false), plain)
            XCTAssertLessThan(Motion.reducedDuration, curve.duration, "the plain form is the shorter one")
        }
    }

    func testWhatCrossesTheWindowDoesNotMoveUnderReduceMotion() {
        for curve in Motion.curves {
            XCTAssertNil(Motion.travel(curve, reduced: true), "it is where it is going at once")
            XCTAssertEqual(Motion.travel(curve, reduced: false), curve.animation)
        }
    }

    func testTheMarkDoesNotBreatheAndTheFieldDoesNotShake() {
        XCTAssertNil(Motion.breathing(reduced: true))
        XCTAssertEqual(Motion.breathDepth(reduced: true), 1, "and it is still at its full size")
        XCTAssertNil(Motion.shaking(reduced: true))

        XCTAssertEqual(Motion.breathing(reduced: false),
                       .easeInOut(duration: Motion.breath / 2).repeatForever(autoreverses: true))
        XCTAssertEqual(Motion.breathDepth(reduced: false), Motion.breathShallow)
        XCTAssertLessThan(Motion.breathShallow, 1)
        XCTAssertEqual(Motion.shaking(reduced: false), .linear(duration: Motion.shakeDuration))
    }

    func testWhatSlidesInFadesInAndTheRestArriveAsTheyDid() {
        for edge in Edge.allCases {
            XCTAssertEqual(Motion.Entrance.slide(edge).plain(true), .fade)
            XCTAssertEqual(Motion.Entrance.slide(edge).plain(false), .slide(edge))
        }
        for entrance in [Motion.Entrance.none, .fade, .fadeOut] {
            XCTAssertEqual(entrance.plain(true), entrance)
            XCTAssertEqual(entrance.plain(false), entrance)
        }
    }

    // MARK: The sources

    /// What an animation is spelled with when it is written by hand. Each
    /// is allowed in `Motion.swift` and nowhere else.
    private static let rules: [(kind: String, pattern: String)] = [
        ("a curve of its own", #"\.(spring|easeIn|easeOut|easeInOut|linear|bouncy|smooth|snappy|interactiveSpring|interpolatingSpring|timingCurve)\("#),
        ("a curve of its own", #"\bAnimation\b"#),
        ("an animation that is not Motion's", #"\bwithAnimation\s*(\{|\((?!\s*Motion\.))"#),
        ("an animation that is not Motion's", #"\.animation\((?![^\n]*Motion\.)"#),
        ("an animation that is not Motion's", #"\.animation\(\s*\.default\b"#),
        ("a transition that is not Motion's", #"(?<!Motion)\.transition\((?!\s*Motion\.transition\()"#),
        ("a transition that is not Motion's", #"\bAnyTransition\b"#),
        ("one that repeats", #"\brepeatForever\b|\brepeatCount\b"#),
        ("a transaction", #"\bwithTransaction\b|\.transaction\("#),
        ("an animator", #"\b(phaseAnimator|keyframeAnimator|matchedGeometryEffect|symbolEffect|contentTransition)\b"#),
        ("AppKit's", #"\bNSAnimationContext\b|\.animator\(\)|\banimate:\s*true\b|\bNSViewAnimation\b"#),
        ("Core Animation's", #"\bCA(Basic|Keyframe|Spring)Animation\b|\bCATransition\b|\bCAAnimationGroup\b"#),
    ]

    private static func code(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[..<comment.lowerBound])
    }

    private static func kinds(in line: String) -> [String] {
        let text = code(line)
        return rules.filter { text.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.kind)
    }

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func lines() throws -> [(file: String, number: Int, text: String)] {
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        return try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated().map {
                (file.lastPathComponent, $0.offset + 1, $0.element)
            }
        }
    }

    func testNoAnimationIsWrittenOutsideMotion() throws {
        let lines = try Self.lines()
        XCTAssertTrue(lines.contains { $0.file == "Motion.swift" }, "the walk did not find the sources")
        let hits = lines.filter { $0.file != "Motion.swift" }.flatMap { line in
            Self.kinds(in: line.text).map {
                "\(line.file):\(line.number) has \($0): \(line.text.trimmingCharacters(in: .whitespaces))"
            }
        }
        XCTAssertTrue(hits.isEmpty, "\n" + hits.joined(separator: "\n"))
    }

    /// Each place that animates names one of `Motion`'s forms, and a curve
    /// it is handed is one of the three the first test went over. All five
    /// forms are in use, so the read is of something.
    func testEveryPlaceThatAnimatesNamesAFormThatHasAPlainOne() throws {
        let call = try NSRegularExpression(pattern: #"Motion\.(animation|travel|breathing|shaking|transition)\(([^()]*(\([^()]*\))?[^()]*)\)"#)
        let curves = ["Motion.quick", "Motion.door", "Motion.slide"]
        let entrances = [".none", ".fade", ".fadeOut", ".slide(.leading)", ".slide(.trailing)", ".slide(.top)",
                         ".slide(.bottom)"]
        var used: [String: Int] = [:]
        var sites = 0
        for line in try Self.lines() where line.file != "Motion.swift" {
            let text = Self.code(line.text)
            let found = call.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let animates = text.contains(".animation(") || text.contains("withAnimation(") || text.contains(".transition(")
            if animates {
                sites += 1
                XCTAssertFalse(found.isEmpty, "\(line.file):\(line.number) animates with none of Motion's forms")
            }
            for match in found {
                let form = (text as NSString).substring(with: match.range(at: 1))
                let argument = (text as NSString).substring(with: match.range(at: 2))
                used[form, default: 0] += 1
                switch form {
                case "animation", "travel":
                    XCTAssertTrue(curves.contains(argument), "\(line.file):\(line.number) hands \(form) \(argument)")
                case "transition":
                    XCTAssertTrue(entrances.contains(argument), "\(line.file):\(line.number) arrives by \(argument)")
                default:
                    XCTAssertEqual(argument, "", "\(line.file):\(line.number) says for itself whether to move")
                }
            }
        }
        XCTAssertGreaterThan(sites, 20, "read \(sites) places that animate")
        XCTAssertEqual(Set(used.keys), ["animation", "travel", "breathing", "shaking", "transition"])
    }

    func testItCatchesWhatAViewWouldWrite() {
        let caught = [
            "withAnimation { isOpen.toggle() }",
            "withAnimation(.spring()) { isOpen.toggle() }",
            "withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }",
            ".animation(.default, value: isOpen)",
            ".animation(.linear(duration: 0.1), value: isOpen)",
            ".transition(.opacity)",
            ".transition(.move(edge: .leading))",
            "let curve: Animation = .bouncy",
            ".symbolEffect(.bounce, value: count)",
            "NSAnimationContext.runAnimationGroup { _ in }",
            "window.animator().alphaValue = 0",
            "window.setFrame(frame, display: true, animate: true)",
            "let fade = CABasicAnimation(keyPath: \"opacity\")",
        ]
        for line in caught {
            XCTAssertFalse(Self.kinds(in: line).isEmpty, "let through: \(line)")
        }
        let allowed = [
            ".animation(Motion.animation(Motion.quick), value: isOpen)",
            ".animation(door.panes == nil ? nil : Motion.animation(Motion.door), value: door.panes == nil)",
            "withAnimation(Motion.shaking()) { shaken = 1 }",
            ".transition(Motion.transition(.fade))",
            "panel.animationBehavior = .none",
            "// .transition(.opacity) is what it was",
        ]
        for line in allowed {
            XCTAssertEqual(Self.kinds(in: line), [], "caught: \(line)")
        }
    }
}
