import SwiftUI

/// The generator's card (`docs/look.md`, "The generator"): the password in
/// a box across the top, its strength under it with a glyph that asks for
/// another and one that copies, the three kinds, the chosen kind's
/// controls, and at the foot the button that puts the password in the
/// field, or copies it when no field raised the card.
struct GeneratorCard: View {
    @ObservedObject var panes: Panes
    @ObservedObject var generator: Generator

    /// The card is as tall as its kind's controls make it, and is hung by
    /// that height before it is drawn.
    static func height(of kind: GeneratorSettings.Kind) -> CGFloat {
        let fixed = Metrics.wide + Metrics.generatorPassword + Metrics.close + Metrics.buttonHeight
            + Metrics.gap + Metrics.buttonHeight + Metrics.close
        let foot = Metrics.gap + Metrics.hairline + Metrics.gap + Metrics.buttonHeight + Metrics.gap
        return fixed + CGFloat(rows(of: kind)) * Metrics.generatorRow + foot
    }

    private static func rows(of kind: GeneratorSettings.Kind) -> Int {
        switch kind {
        case .random: return 3
        case .memorable: return 4
        case .pin: return 1
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                password
                    .padding(.bottom, Metrics.close)
                strength
                    .padding(.bottom, Metrics.gap)
                Segments(choices: GeneratorSettings.Kind.allCases, word: \.name, name: \.name, label: "Kind",
                         chosen: $generator.settings.kind)
                    .padding(.bottom, Metrics.close)
                controls
            }
            .padding(.horizontal, Metrics.wide)
            .padding(.top, Metrics.wide)
            .padding(.bottom, Metrics.gap)
            Hairline(.horizontal)
            foot
                .padding(.horizontal, Metrics.wide)
                .padding(.vertical, Metrics.gap)
        }
        .frame(width: Metrics.generatorWidth, height: Self.height(of: generator.settings.kind))
        .background(shape.fill(Palette.menu))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        // One shadow, the card's, and none under each thing on it.
        .compositingGroup()
        .shadow(color: Palette.shadow, radius: Metrics.menuShadow, y: Metrics.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Password Generator")
    }

    // MARK: The password

    /// Digits and symbols in the colours Large Type gives them, so an l
    /// and a 1 are told apart. A space of no width follows each character,
    /// in what is drawn and nowhere else, so a line ends where the box does
    /// and not at the last symbol before it.
    private var coloured: AttributedString {
        var whole = AttributedString()
        for cell in LargeType(generator.password).cells {
            var one = AttributedString("\(cell.character)\u{200B}")
            one.foregroundColor = LargeTypeView.colour(of: cell.kind)
            whole.append(one)
        }
        return whole
    }

    private var password: some View {
        Group {
            if let refused = generator.refused {
                Text(refused)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.red)
            } else {
                Text(coloured)
                    .font(Fonts.code)
                    .lineSpacing(Metrics.hair)
                    .accessibilityLabel("generated password")
                    .accessibilityValue(generator.password)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Metrics.gap)
        .padding(.vertical, Metrics.close)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.generatorPassword, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Palette.well)
        )
        .clipped()
    }

    private var strength: some View {
        HStack(spacing: Metrics.close) {
            if let strength = generator.strength {
                StrengthRing(strength: strength)
                Text(strength.word)
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.secondText)
                    .accessibilityLabel("strength")
                    .accessibilityValue(strength.word)
            }
            Spacer(minLength: 0)
            if generator.isCopied {
                Text("Copied")
                    .font(Fonts.rowSecond)
                    .foregroundStyle(Palette.accent)
            }
            glyph(.refresh, "Generate Another") { generator.ask() }
            glyph(generator.isCopied ? .tick : .copy, "Copy") { panes.copyGenerated() }
        }
        .frame(height: Metrics.buttonHeight)
    }

    private func glyph(_ glyph: Glyph, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            glyph.image
                .font(Fonts.toolbarGlyph)
                .foregroundStyle(Palette.secondText)
                .frame(width: Metrics.buttonHeight, height: Metrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    // MARK: The controls

    @ViewBuilder
    private var controls: some View {
        switch generator.settings.kind {
        case .random:
            row("Characters") {
                Stepped(value: $generator.settings.length, range: GeneratorSettings.lengths, name: "Characters")
            }
            row("Numbers") { Switch(isOn: $generator.settings.digits, name: "Numbers") }
            row("Symbols") { Switch(isOn: $generator.settings.symbols, name: "Symbols") }
        case .memorable:
            row("Words") {
                Stepped(value: $generator.settings.words, range: GeneratorSettings.wordCounts, name: "Words")
            }
            row("Between") {
                Segments(choices: GeneratorSettings.Separator.allCases, word: \.mark, name: \.name,
                         label: "Separator",
                         chosen: $generator.settings.separator, font: Fonts.statement)
            }
            row("Capitals") { Switch(isOn: $generator.settings.capitals, name: "Capitals") }
            row("A number") { Switch(isOn: $generator.settings.number, name: "A number") }
        case .pin:
            row("Digits") {
                Stepped(value: $generator.settings.pinDigits, range: GeneratorSettings.pinLengths, name: "Digits")
            }
        }
    }

    private func row<Control: View>(_ word: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(word)
                .font(Fonts.body)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .frame(width: Metrics.generatorWidth / 4, alignment: .leading)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            control()
        }
        .frame(height: Metrics.generatorRow)
    }

    // MARK: The foot

    private var foot: some View {
        HStack(spacing: Metrics.gap) {
            Spacer(minLength: 0)
            switch generator.purpose {
            case .field:
                Button("Cancel", action: panes.endGenerating)
                    .buttonStyle(QuietButtonStyle())
                Button("Use Password") { panes.useGenerated() }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(generator.password.isEmpty)
            case .alone:
                Button("Close", action: panes.endGenerating)
                    .buttonStyle(QuietButtonStyle())
                Button("Copy Password") {
                    if panes.copyGenerated() { panes.endGenerating() }
                }
                .buttonStyle(FilledButtonStyle())
                .disabled(generator.password.isEmpty)
            }
        }
    }
}

extension GeneratorSettings.Separator {
    /// What its segment is drawn as: the character itself, and for a space
    /// the mark a keyboard has on its space bar.
    var mark: String { self == .spaces ? "␣" : character }
}

// MARK: - The controls, drawn

/// One of a few, side by side on the field's grey, the chosen one raised.
/// The settings window's rooms have them too.
struct Segments<Choice: Hashable>: View {
    let choices: [Choice]
    /// What a segment is drawn as, and what VoiceOver calls it.
    let word: KeyPath<Choice, String>
    let name: KeyPath<Choice, String>
    let label: String
    @Binding var chosen: Choice
    /// One face for every segment, where the words are single marks.
    var font: Font?
    /// What the track is sunk into: a card's grey, unless told it stands
    /// on the content's own.
    var ground = Palette.well

    var body: some View {
        HStack(spacing: Metrics.hair) {
            ForEach(choices, id: \.self) { choice in
                let isChosen = choice == chosen
                Button { chosen = choice } label: {
                    Text(choice[keyPath: word])
                        .font(font ?? (isChosen ? Fonts.action : Fonts.rowSecond))
                        .foregroundStyle(isChosen ? Palette.text : Palette.secondText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.buttonHeight - Metrics.tight)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.controlRadius - Metrics.hair, style: .continuous)
                                .fill(isChosen ? Palette.rowButton : Palette.rowButton.opacity(0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label): \(choice[keyPath: name])")
                .accessibilityValue(isChosen ? "selected" : "")
            }
        }
        .padding(Metrics.hair)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(ground))
    }
}

/// A slider over whole numbers, with the number at its end. The arrows
/// move it one at a time for VoiceOver.
private struct Stepped: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let name: String

    private var share: CGFloat {
        CGFloat(value - range.lowerBound) / CGFloat(max(range.count - 1, 1))
    }

    var body: some View {
        HStack(spacing: Metrics.close) {
            GeometryReader { track in
                let run = track.size.width - Metrics.knob
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.outline)
                        .frame(height: Metrics.sliderTrack)
                    Capsule().fill(Palette.accent)
                        .frame(width: Metrics.knob / 2 + run * share, height: Metrics.sliderTrack)
                    Circle().fill(Palette.onColour)
                        .overlay(Circle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        .shadow(color: Palette.shadow, radius: Metrics.hair, y: Metrics.hairline)
                        .frame(width: Metrics.knob, height: Metrics.knob)
                        .offset(x: run * share)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let along = min(max((drag.location.x - Metrics.knob / 2) / max(run, 1), 0), 1)
                    let now = range.lowerBound + Int((along * CGFloat(range.count - 1)).rounded())
                    if now != value { value = now }
                })
            }
            .frame(height: Metrics.buttonHeight)
            Text(String(value))
                .font(Fonts.body)
                .monospacedDigit()
                .foregroundStyle(Palette.secondText)
                .frame(width: Metrics.sliderNumber, alignment: .trailing)
        }
        // To VoiceOver it is the system's slider, which it knows how to
        // move.
        .accessibilityRepresentation {
            Slider(value: Binding { Double(value) } set: { value = Int($0.rounded()) },
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(name)
                .accessibilityValue(String(value))
        }
    }
}

/// On or off: the accent with the knob at its right, or grey with it at
/// its left. The editor's form has one too.
struct Switch: View {
    @Binding var isOn: Bool
    let name: String

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Palette.accent : Palette.rowButton)
                .frame(width: Metrics.switchSize.width, height: Metrics.switchSize.height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Palette.onColour)
                        .frame(width: Metrics.knob, height: Metrics.knob)
                        .padding(.horizontal, Metrics.hair)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.travel(Motion.quick), value: isOn)
        .accessibilityLabel(name)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Where it stands

/// Where the wand stands in a form's column, while the generator it raised
/// is up.
struct GeneratorAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The card hung under the wand with their right edges together, or over
/// it when the column ends first. A click anywhere else puts it away.
struct FieldGeneratorLayer: View {
    @ObservedObject var panes: Panes
    let anchor: Anchor<CGRect>?

    var body: some View {
        if let generator = panes.generator, generator.purpose == .field, let anchor {
            GeometryReader { column in
                let wand = column[anchor]
                let height = GeneratorCard.height(of: generator.settings.kind)
                let below = wand.maxY + Metrics.tight
                let fits = below + height + Metrics.close <= column.size.height
                let rightmost = column.size.width - Metrics.generatorWidth - Metrics.close
                ZStack(alignment: .topLeading) {
                    Palette.content.opacity(0)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: panes.endGenerating)
                        .accessibilityHidden(true)
                    GeneratorCard(panes: panes, generator: generator)
                        .offset(x: max(Metrics.close, min(wand.maxX - Metrics.generatorWidth, rightmost)),
                                y: fits ? below : max(Metrics.close, min(below, column.size.height - height - Metrics.close)))
                }
            }
        }
    }
}

/// The card by itself over the dimmed window, where the sheet of kinds
/// stands.
struct GeneratorLayer: View {
    @ObservedObject var panes: Panes

    var body: some View {
        if let generator = panes.generator, generator.purpose == .alone {
            ZStack(alignment: .top) {
                Palette.scrim
                    .contentShape(Rectangle())
                    .onTapGesture(perform: panes.endGenerating)
                    .accessibilityHidden(true)
                GeneratorCard(panes: panes, generator: generator)
                    .padding(.top, Metrics.toolbarHeight + Metrics.apart + Metrics.apart)
            }
            .ignoresSafeArea()
            .transition(Motion.transition(.fade))
        }
    }
}

// MARK: - Shots

extension Surface {
    private static func generating(_ name: String, for purpose: Generator.Purpose,
                                   _ arrange: @escaping (inout GeneratorSettings) -> Void = { _ in }) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { store in
            let panes = Panes(store: store, icons: DemoIcons.seeded())
            panes.select(item: store.shelves.all.first { $0.item.name == "GitHub" }?.id)
            if purpose == .field { panes.beginEdit() }
            // A shot asks no engine: the password is the demo's for the
            // controls as they stand.
            var settings = GeneratorSettings()
            arrange(&settings)
            let generator = Generator(store: store, purpose: purpose, settings: settings)
            generator.show(DemoVault.generated(settings.recipe))
            panes.generator = generator
            return AnyView(PanesView(panes: panes))
        }
    }

    /// The card under a form's wand in its three kinds, the random one
    /// as it first comes up; and by itself at its longest, where it can
    /// only be copied from.
    static let generators: [Surface] = [
        generating("generator-random", for: .field),
        generating("generator-memorable", for: .field) { settings in
            settings.kind = .memorable
            settings.capitals = true
            settings.number = true
        },
        generating("generator-pin", for: .field) { $0.kind = .pin },
        generating("generator-alone", for: .alone) { settings in
            settings.length = GeneratorSettings.lengths.upperBound
        },
    ]
}
