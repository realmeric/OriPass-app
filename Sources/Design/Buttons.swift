import SwiftUI

/// The filled button: `Palette.lit` with a word on it. A surface has at most
/// one (`docs/look.md`, "The window").
struct FilledButtonStyle: ButtonStyle {
    /// `Palette.redLit`, for the one that deletes for good.
    var ground = Palette.lit
    /// As wide as what it stands in, in a stack of buttons.
    var fills = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.action)
            .foregroundStyle(Palette.onColour)
            .padding(.horizontal, Metrics.wide)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(height: Metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(ground)
            )
            .opacity(configuration.isPressed ? Palette.pressed : 1)
    }
}

/// A word or a glyph standing in a strip with no ground of its own: the
/// vault, Edit and the ellipsis over an item's details. It is drawn the same
/// whether or not it can be used, as its still has it.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.body)
            .foregroundStyle(Palette.text)
            .frame(minWidth: Metrics.buttonHeight, minHeight: Metrics.buttonHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? Palette.pressed : 1)
    }
}

/// The button beside the filled one: the same size, the field's grey, and the
/// word in the text's colour.
struct QuietButtonStyle: ButtonStyle {
    /// As wide as what it stands in, in a stack of buttons.
    var fills = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        return configuration.label
            .font(Fonts.action)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Metrics.wide)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(height: Metrics.buttonHeight)
            .background(shape.fill(Palette.field))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .opacity(configuration.isPressed ? Palette.pressed : 1)
    }
}
