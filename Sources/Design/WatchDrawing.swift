import SwiftUI

/// The line drawing at a card's top right corner on Password Health's page, this
/// app's own and drawn in code (D8): a padlock beside a warning sign, two
/// padlocks that are the same one, a gauge low over a short password, a page
/// beside a padlock left open, a phone beside a padlock with a code ringed
/// above it, and a card beside a clock.
///
/// Each is laid out on a grid of eighty by sixty and drawn in whatever rect
/// it is given, to be stroked and never filled.
struct WatchDrawing: Shape {
    let card: WatchCard

    func path(in rect: CGRect) -> Path {
        Pen(rect: rect).draw(card)
    }

    static var stroke: StrokeStyle {
        StrokeStyle(lineWidth: Metrics.drawingLine, lineCap: .round, lineJoin: .round)
    }

    private struct Pen {
        let rect: CGRect
        var path = Path()

        func at(_ across: CGFloat, _ down: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + across / 80 * rect.width, y: rect.minY + down / 60 * rect.height)
        }

        func length(_ units: CGFloat) -> CGFloat { units / 60 * rect.height }

        mutating func line(_ points: (CGFloat, CGFloat)...) {
            guard let first = points.first else { return }
            path.move(to: at(first.0, first.1))
            for point in points.dropFirst() { path.addLine(to: at(point.0, point.1)) }
        }

        mutating func box(_ across: CGFloat, _ down: CGFloat, _ wide: CGFloat, _ tall: CGFloat, corner: CGFloat) {
            let origin = at(across, down)
            let frame = CGRect(origin: origin, size: CGSize(width: wide / 80 * rect.width, height: length(tall)))
            path.addRoundedRect(in: frame, cornerSize: CGSize(width: length(corner), height: length(corner)),
                                style: .continuous)
        }

        mutating func ring(_ across: CGFloat, _ down: CGFloat, _ radius: CGFloat) {
            let centre = at(across, down)
            let reach = length(radius)
            path.addEllipse(in: CGRect(origin: CGPoint(x: centre.x - reach, y: centre.y - reach),
                                       size: CGSize(width: reach * 2, height: reach * 2)))
        }

        /// The upper half of a circle, from its left end over to its right.
        mutating func arch(_ across: CGFloat, _ down: CGFloat, _ radius: CGFloat) {
            path.move(to: at(across - radius, down))
            path.addArc(center: at(across, down), radius: length(radius), startAngle: .degrees(180),
                        endAngle: .degrees(0), clockwise: false)
        }

        /// A padlock whose body's top left corner is here. An open one has
        /// its shackle lifted off the right side.
        mutating func padlock(_ across: CGFloat, _ down: CGFloat, isOpen: Bool = false) {
            box(across, down, 26, 21, corner: 4)
            let lift: CGFloat = isOpen ? 5 : 0
            line((across + 6, down), (across + 6, down - 5 - lift))
            arch(across + 13, down - 5 - lift, 7)
            if isOpen {
                line((across + 20, down - 10), (across + 20, down - 7))
            } else {
                line((across + 20, down - 5), (across + 20, down))
            }
            ring(across + 13, down + 9, 2.2)
            line((across + 13, down + 11.2), (across + 13, down + 15))
        }

        func draw(_ card: WatchCard) -> Path {
            var pen = self
            switch card {
            case .vulnerable:
                pen.padlock(8, 28)
                pen.line((46, 49), (61, 20), (76, 49), (46, 49))
                pen.line((61, 31), (61, 40))
                pen.ring(61, 44.5, 0.9)
            case .reused:
                pen.padlock(8, 30)
                pen.padlock(46, 30)
            case .weak:
                pen.arch(40, 31, 23)
                pen.line((40, 31), (25, 19))
                pen.ring(40, 31, 2.2)
                pen.box(9, 39, 62, 14, corner: 7)
                for dot in [19.0, 28.0, 37.0] { pen.ring(CGFloat(dot), 46, 1.6) }
            case .unsecured:
                pen.box(4, 9, 44, 36, corner: 5)
                pen.line((4, 19), (48, 19))
                pen.ring(10.5, 14, 1.4)
                pen.ring(16, 14, 1.4)
                pen.line((11, 28), (36, 28))
                pen.line((11, 35), (28, 35))
                pen.padlock(52, 34, isOpen: true)
            case .twoFactor:
                pen.box(8, 6, 26, 48, corner: 5)
                pen.line((17, 47), (25, 47))
                pen.padlock(44, 30)
                for dot in [47.0, 57.0, 67.0] { pen.ring(CGFloat(dot), 12, 1.6) }
            case .expiring:
                pen.box(4, 11, 46, 32, corner: 5)
                pen.line((4, 21), (50, 21))
                pen.line((11, 34), (26, 34))
                pen.ring(64, 42, 12)
                pen.line((64, 35), (64, 42), (69, 45))
            }
            return pen.path
        }
    }
}
