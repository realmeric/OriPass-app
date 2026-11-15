import SwiftUI

/// The value one character to a cell, very large and monospaced, digits and
/// symbols coloured apart from letters, and each cell numbered underneath so
/// a character can be read out by its place.
struct LargeTypeView: View {
    let value: LargeType
    let perLine: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(value.lines(of: perLine).enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        ForEach(line) { cell(_: $0) }
                    }
                }
            }
            .padding(Metrics.largeTypePad)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Large Type")
        .accessibilityValue(String(value.cells.map(\.character)))
        .accessibilityAddTraits(.isStaticText)
    }

    private func cell(_ cell: LargeType.Cell) -> some View {
        VStack(spacing: Metrics.tight) {
            Text(String(cell.character))
                .font(Fonts.largeType)
                .foregroundStyle(Self.colour(of: cell.kind))
            Text(String(cell.id))
                .font(Fonts.largeTypeIndex)
                .foregroundStyle(Palette.secondText)
        }
        .frame(width: Metrics.largeTypeCell.width, height: Metrics.largeTypeCell.height)
        .background(cell.id.isMultiple(of: 2) ? Palette.cell.opacity(0) : Palette.cell)
    }

    static func colour(of kind: LargeType.Kind) -> Color {
        switch kind {
        case .letter, .blank: return Palette.text
        case .digit: return Palette.digit
        case .symbol: return Palette.symbol
        }
    }
}

extension Surface {
    /// The panel as it would stand on a screen `width` wide, with a margin
    /// of nothing around it.
    private static func largeType(_ name: String, width: CGFloat, _ value: String) -> Surface {
        let cells = LargeType(value)
        let fit = cells.fit(width: width, height: Metrics.windowSize.height)
        let margin = Metrics.largeTypePad
        let size = CGSize(width: fit.size.width + margin + margin, height: fit.size.height + margin + margin)
        return Surface(name: name, size: size, isBare: true) { _ in
            AnyView(
                LargeTypeView(value: cells, perLine: fit.perLine)
                    .frame(width: fit.size.width, height: fit.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
    }

    /// Large Type on the fixtures' own password, which has a letter, a
    /// symbol and a digit in it, and on one of the demo's, long enough to
    /// take a second line.
    static let largeTypes: [Surface] = [
        largeType("large-type", width: Metrics.windowSize.width, "CANARY-1"),
        largeType("large-type-long", width: Metrics.windowSize.width, DemoVault.shared),
    ]
}
