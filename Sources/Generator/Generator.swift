import Foundation

/// The generator while it is up (`docs/look.md`, "The generator"): the
/// controls, and the one password the engine last made for them. This app
/// has no generator of its own (D4). Every password is the child's, asked
/// for again each time a control moves, and scored here as any other is
/// (`Strength`).
///
/// The controls are remembered. The password is in this object and in no
/// other place until it is put in a field or copied, and goes with it at a
/// close and at the lock (D6).
@MainActor
final class Generator: ObservableObject, Redacted {
    /// Raised by the button in a form's password row, where it can fill
    /// that field, or from the menu bar, where it can only be copied from.
    enum Purpose {
        case field, alone
    }

    static let noAnswer = "The engine made no password."

    let purpose: Purpose
    @Published var settings: GeneratorSettings {
        didSet {
            guard settings != oldValue else { return }
            if let defaults { settings.write(to: defaults) }
            ask()
        }
    }
    @Published private(set) var password = ""
    @Published private(set) var strength: Strength?
    /// The engine's sentence when it would not make one.
    @Published private(set) var refused: String?
    /// Whether the password that is showing has been copied.
    @Published var isCopied = false
    /// The question the engine has not answered yet, for a test to wait on.
    private(set) var asking: Task<Void, Never>?
    private var asked = 0
    private let store: VaultStore
    private let defaults: UserDefaults?

    var redactedLabel: String { "Generator(\(settings.kind.rawValue))" }

    /// The controls stand as they were left, unless a shot says how.
    init(store: VaultStore, defaults: UserDefaults? = nil, purpose: Purpose, settings: GeneratorSettings? = nil) {
        self.store = store
        self.defaults = defaults
        self.purpose = purpose
        self.settings = settings ?? GeneratorSettings(defaults)
    }

    /// Another password for the controls as they stand: the refresh glyph,
    /// and every change of a control. Only the last one asked for is
    /// shown, whichever answer comes back first.
    func ask() {
        asked += 1
        let number = asked
        let recipe = settings.recipe
        asking?.cancel()
        asking = Task { [weak self, store] in
            do {
                let made = try await store.generate(recipe)
                guard let self, !Task.isCancelled, number == self.asked else { return }
                self.show(made)
            } catch {
                guard let self, !Task.isCancelled, number == self.asked else { return }
                self.refused = Panes.sentence(for: error) ?? Self.noAnswer
            }
        }
    }

    /// What the engine made, or for a shot, which asks no engine, the demo's.
    func show(_ made: String) {
        password = made
        strength = made.isEmpty ? nil : Strength.of(made)
        refused = nil
        isCopied = false
    }

    /// Nothing asked comes back after this, and nothing made is left.
    func end() {
        asked += 1
        asking?.cancel()
        asking = nil
        password = ""
        strength = nil
    }
}

extension Panes {
    /// The wand in a form's password row, which also puts it away again.
    func toggleFieldGenerator() {
        if generator?.purpose == .field {
            endGenerating()
        } else {
            beginGenerating(for: .field)
        }
    }

    /// False when there is no password field to generate for, or something
    /// that asks a question is already over the window.
    @discardableResult
    func beginGenerating(for purpose: Generator.Purpose) -> Bool {
        guard choosing == nil, !isAskingToDiscard, confirming == nil else { return false }
        switch purpose {
        case .field:
            guard let editor, editor.original.type == .login else { return false }
            editor.menu = nil
        case .alone:
            guard pinned == nil else { return false }
            openMenu = nil
            detailMenu = nil
            if reading.menu != nil { reading.menu = nil }
            closeHistory()
            editor?.menu = nil
            showsKeys = false
        }
        generator?.end()
        let made = Generator(store: store, defaults: generatorDefaults, purpose: purpose)
        generator = made
        made.ask()
        return true
    }

    func endGenerating() {
        guard let generator else { return }
        generator.end()
        self.generator = nil
    }

    /// The button at the foot of the one a form raised: the password goes
    /// into the form, which is all that happens to it until Save.
    @discardableResult
    func useGenerated() -> Bool {
        guard let generator, generator.purpose == .field, let editor, !generator.password.isEmpty else {
            return false
        }
        editor.form.password = generator.password
        endGenerating()
        return true
    }

    /// To the pasteboard, as a password copied from an item goes
    /// (`Clipboard`).
    @discardableResult
    func copyGenerated() -> Bool {
        guard let generator, !generator.password.isEmpty else { return false }
        clipboard.copy(generator.password)
        generator.isCopied = true
        return true
    }
}
