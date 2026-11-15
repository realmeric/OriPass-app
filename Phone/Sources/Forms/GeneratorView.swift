import SwiftUI

/// The generator as a sheet: the password, its strength, and the controls
/// that make it. With `use`, a form's password field takes the result.
struct GeneratorView: View {
    let copying: Copying
    var use: ((String) -> Void)?

    @State private var recipe = Recipe.stored()
    @State private var made = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(made)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("generated")
                    let strength = Strength.of(made)
                    Gauge(value: strength.share) {
                        Text(strength.word)
                    }
                    .tint(strength.colour)
                }
                Section {
                    Picker("Type", selection: $recipe.kind) {
                        Text("Password").tag(Recipe.Kind.password)
                        Text("Passphrase").tag(Recipe.Kind.passphrase)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if recipe.kind == .password {
                    Section {
                        VStack(alignment: .leading) {
                            LabeledContent("Length", value: "\(recipe.length)")
                            Slider(value: Binding(get: { Double(recipe.length) }, set: { recipe.length = Int($0) }),
                                   in: Double(Recipe.lengths.lowerBound)...Double(Recipe.lengths.upperBound), step: 1)
                        }
                        Toggle("Uppercase", isOn: $recipe.uppercase)
                        Toggle("Lowercase", isOn: $recipe.lowercase)
                        Toggle("Numbers", isOn: $recipe.digits)
                        Toggle("Symbols", isOn: $recipe.symbols)
                        Toggle("Avoid Look-Alikes", isOn: $recipe.avoidAmbiguous)
                    }
                } else {
                    Section {
                        Stepper("Words: \(recipe.words)", value: $recipe.words, in: Recipe.wordCounts)
                        Picker("Separator", selection: $recipe.separator) {
                            Text(verbatim: "-").tag("-")
                            Text(verbatim: ".").tag(".")
                            Text(verbatim: "_").tag("_")
                            Text("Space").tag(" ")
                        }
                        Toggle("Capitalize", isOn: $recipe.capitalize)
                        Toggle("Include a Number", isOn: $recipe.includeNumber)
                    } footer: {
                        Text("Words from EFF's long word list.")
                    }
                }
            }
            .navigationTitle("Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Password", systemImage: "arrow.clockwise") { made = Generator.make(recipe) }
                }
                ToolbarItem(placement: .bottomBar) {
                    if let use {
                        Button("Use This Password") {
                            use(made)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Copy", systemImage: "doc.on.doc") { copying.copy(made, String(localized: "Password copied")) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .onAppear {
                made = Generator.make(recipe)
                #if !AUTOFILL_EXTENSION
                // A field behind the sheet keeps the keyboard up otherwise.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
            }
            .onChange(of: recipe) {
                recipe.store()
                made = Generator.make(recipe)
            }
            .sensoryFeedback(.selection, trigger: made)
        }
        .modifier(CopiedNotice(copying: copying))
    }
}

extension Strength {
    var colour: Color {
        switch self {
        case .guessable, .weak: .red
        case .fair: .orange
        case .good: .yellow
        case .strong: .green
        }
    }
}
