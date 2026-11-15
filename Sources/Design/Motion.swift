import AppKit
import SwiftUI

/// Every animation in the app is one of these, and every one of them goes
/// through `Motion.animation(_:)`, so that Reduce Motion is honoured in one
/// place and not in every view that moves (OP-58).
enum Motion {
    struct Curve: Equatable {
        let duration: Double
        /// 1 stops dead; below it the thing overshoots and comes back.
        let damping: Double

        var animation: Animation { .spring(response: duration, dampingFraction: damping) }
    }

    /// A row filling under the pointer, a value revealing, a glyph changing.
    static let quick = Curve(duration: 0.18, damping: 1)

    /// The lock screen giving way to the panes and coming back.
    static let door = Curve(duration: 0.32, damping: 0.9)

    /// A sheet, a popover's contents, Quick Access's actions sliding in.
    static let slide = Curve(duration: 0.26, damping: 0.92)

    /// A refused password: the field goes side to side this many times in
    /// this long.
    static let shakes = 3
    static let shakeDuration: Double = 0.36

    /// The mark breathing while an unlock runs: one breath, there and back,
    /// and how small it gets at the bottom of one.
    static let breath: Double = 1.6
    static let breathShallow: Double = 0.92

    /// How long "Copied" stands in for "Copy".
    static let acknowledged: Double = 1.6

    /// How often the line on the card over ssh is drawn again. It steps and
    /// does not glide, so Reduce Motion has nothing to take from it.
    static let runningDown: Double = 0.25

    /// What Reduce Motion replaces every curve with.
    static let reducedDuration: Double = 0.12

    /// The three curves, for the test that goes over them.
    static let curves = [quick, door, slide]

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// For what fades or changes colour where it stands. Its plain form is
    /// the same change, short and straight.
    static func animation(_ curve: Curve, reduced: Bool = reduceMotion) -> Animation {
        reduced ? .linear(duration: reducedDuration) : curve.animation
    }

    /// For what crosses the window to get where it is going: a column
    /// opening, rows making room, a knob going over. Its plain form is none,
    /// and the thing is there at once.
    static func travel(_ curve: Curve, reduced: Bool = reduceMotion) -> Animation? {
        reduced ? nil : curve.animation
    }

    /// The two that repeat or swing have no reduced form either: with
    /// Reduce Motion the mark stays still, at its full size, and the field
    /// does not shake.
    static func breathing(reduced: Bool = reduceMotion) -> Animation? {
        reduced ? nil : .easeInOut(duration: breath / 2).repeatForever(autoreverses: true)
    }

    static func breathDepth(reduced: Bool = reduceMotion) -> Double {
        reduced ? 1 : breathShallow
    }

    static func shaking(reduced: Bool = reduceMotion) -> Animation? {
        reduced ? nil : .linear(duration: shakeDuration)
    }

    /// How a view arrives and leaves. One that slides in fades in under
    /// Reduce Motion, and the rest are already plain.
    enum Entrance: Equatable {
        /// There and gone in the frame it changes in.
        case none
        case fade
        /// There at once, and faded out.
        case fadeOut
        case slide(Edge)

        func plain(_ reduced: Bool) -> Entrance {
            if case .slide = self, reduced { return .fade }
            return self
        }

        fileprivate var transition: AnyTransition {
            switch self {
            case .none: return .identity
            case .fade: return .opacity
            case .fadeOut: return .asymmetric(insertion: .identity, removal: .opacity)
            case .slide(let edge): return .move(edge: edge)
            }
        }
    }

    static func transition(_ entrance: Entrance, reduced: Bool = reduceMotion) -> AnyTransition {
        entrance.plain(reduced).transition
    }
}
