import SwiftUI

/// Signing in, over the lock screen that said nobody was (`docs/look.md`,
/// "The lock screen"). A card on a scrim, as the Touch ID question is. The
/// form first: the server, the email and the master password, or an API key
/// in their place. A second step only when the engine asks for one.
///
/// What is typed into the plain fields is the view's own. The master
/// password and the API key's secret are never a `String` of this view's:
/// they stay in their secure fields until they are taken as `SecretBytes`.
struct SignInSheet: View {
    @ObservedObject var model: SignIn
    var cancel: () -> Void = {}

    enum ServerChoice: Hashable, CaseIterable {
        case com, eu, own

        var title: String {
            switch self {
            case .com: return "bitwarden.com"
            case .eu: return "bitwarden.eu"
            case .own: return "Self-hosted"
            }
        }
    }

    private enum Field: Hashable {
        case address, email, clientID, code
    }

    @State private var choice: ServerChoice
    @State private var address: String
    @State private var email: String
    @State private var clientID = ""
    @State private var code = ""
    @State private var secretHasKeys = false
    @State private var secret = TypedSecret()
    @FocusState private var focus: Field?

    init(model: SignIn, cancel: @escaping () -> Void = {}, choice: ServerChoice = .com,
         address: String = "", email: String = "") {
        self.model = model
        self.cancel = cancel
        _choice = State(initialValue: choice)
        _address = State(initialValue: address)
        _email = State(initialValue: email)
    }

    private var server: SignInServer {
        switch choice {
        case .com: return .com
        case .eu: return .eu
        case .own: return .own(address)
        }
    }

    var body: some View {
        ZStack {
            Palette.scrim.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Metrics.wide) {
                switch model.step {
                case .form: form
                case .method(let offered): methods(offered)
                case .code(let wanted): codeStep(wanted)
                }
            }
            .padding(Metrics.loose)
            .frame(width: Metrics.signInWidth)
            .background(
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .fill(Palette.content)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                    .strokeBorder(Palette.outline, lineWidth: Metrics.hairline)
            )
        }
        .ignoresSafeArea()
        .onChange(of: model.step) { _, step in
            code = ""
            if case .code = step { focus = .code }
        }
        .onChange(of: model.refusal) { _, _ in code = "" }
    }

    // MARK: The form

    private var form: some View {
        Group {
            heading("Sign In", model.usesAPIKey
                ? "The key is in the web vault, under Settings, Security, Keys. It signs in, and the master password still unlocks."
                : "The account stays signed in on this Mac. The master password is not kept.")
            VStack(spacing: Metrics.close) {
                serverPicker
                if choice == .own {
                    framed(isFocused: focus == .address) {
                        TextField("https://vault.example.com", text: $address, prompt: prompt("https://vault.example.com"))
                            .focused($focus, equals: .address)
                            .accessibilityLabel("Server address")
                    }
                }
                if model.usesAPIKey {
                    framed(isFocused: focus == .clientID) {
                        TextField("client_id", text: $clientID, prompt: prompt("client_id"))
                            .focused($focus, equals: .clientID)
                            .accessibilityLabel("client_id")
                    }
                    secretField("client_secret")
                } else {
                    framed(isFocused: focus == .email) {
                        TextField("Email", text: $email, prompt: prompt("Email"))
                            .focused($focus, equals: .email)
                            .textContentType(.username)
                            .accessibilityLabel("Email")
                    }
                    secretField("Master password")
                }
            }
            .disabled(model.isWorking)
            refusal
            HStack(spacing: Metrics.gap) {
                Button(model.usesAPIKey ? "Use the master password" : "Use an API key") {
                    model.usesAPIKey.toggle()
                    focus = model.usesAPIKey ? .clientID : .email
                }
                .buttonStyle(.plain)
                .font(Fonts.action)
                .foregroundStyle(Palette.accent)
                .disabled(model.isWorking)
                Spacer(minLength: 0)
                working
                Button("Cancel", action: cancel)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") { submit(secret.take()) }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
                    .opacity(model.isWorking ? Palette.disabled : 1)
            }
        }
        .onAppear { focus = model.usesAPIKey ? .clientID : .email }
    }

    private func submit(_ typed: SecretBytes?) {
        if model.usesAPIKey {
            model.signIn(server: server, clientID: clientID, secret: typed)
        } else {
            model.signIn(server: server, email: email, password: typed)
        }
    }

    /// Three places an account can be, side by side, with the chosen one
    /// lifted off the track.
    private var serverPicker: some View {
        let track = RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
        return HStack(spacing: Metrics.hair) {
            ForEach(ServerChoice.allCases, id: \.self) { option in
                let thumb = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                Button {
                    choice = option
                    if option == .own { focus = .address }
                } label: {
                    Text(option.title)
                        .font(choice == option ? Fonts.action : Fonts.rowSecond)
                        .foregroundStyle(choice == option ? Palette.text : Palette.secondText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(thumb.fill(choice == option ? Palette.content : .clear))
                        .overlay(thumb.strokeBorder(choice == option ? Palette.outline : .clear,
                                                    lineWidth: Metrics.hairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == option ? .isSelected : [])
            }
        }
        .padding(Metrics.hair)
        .frame(height: Metrics.searchHeight)
        .background(track.fill(Palette.field))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server")
    }

    private func secretField(_ placeholder: String) -> some View {
        framed(isFocused: secretHasKeys) {
            PasswordField(placeholder: placeholder, isEnabled: !model.isWorking, takesFocus: false,
                          typed: secret, isFocused: $secretHasKeys, submit: submit)
        }
        // One field for either secret, and a fresh one when the form turns
        // over, so half a password is never left under the other's name.
        .id(placeholder)
    }

    // MARK: The second step

    private func methods(_ offered: [SecondStep]) -> some View {
        Group {
            heading("Two-step login", "Choose how to show it is you.")
            VStack(spacing: Metrics.close) {
                ForEach(offered, id: \.self) { method in
                    Button { model.choose(method) } label: {
                        HStack {
                            Text(SignIn.title(for: method))
                                .font(Fonts.body)
                                .foregroundStyle(Palette.text)
                            Spacer()
                            Glyph.chevronRight.image
                                .font(Fonts.caption)
                                .foregroundStyle(Palette.faintText)
                        }
                        .padding(.horizontal, Metrics.gap)
                        .frame(height: Metrics.lockField.height)
                        .background(fieldShape.fill(Palette.field))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(model.isWorking)
            refusal
            HStack(spacing: Metrics.gap) {
                Spacer(minLength: 0)
                working
                Button("Back", action: model.startOver)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func codeStep(_ wanted: SignInCode) -> some View {
        let ask = model.ask(for: wanted)
        return Group {
            heading(ask.title, ask.more)
            framed(isFocused: focus == .code) {
                TextField("Code", text: $code, prompt: prompt("Code"))
                    .font(Fonts.code)
                    .focused($focus, equals: .code)
                    .textContentType(.oneTimeCode)
                    .accessibilityLabel("Code")
            }
            .disabled(model.isWorking)
            refusal
            HStack(spacing: Metrics.gap) {
                Spacer(minLength: 0)
                working
                Button("Back", action: model.startOver)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.enter(code: code) }
                    .buttonStyle(FilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
                    .opacity(model.isWorking ? Palette.disabled : 1)
            }
        }
        .onAppear { focus = .code }
    }

    // MARK: Pieces

    private var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
    }

    private func heading(_ title: String, _ more: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            Text(title)
                .font(Fonts.statement)
                .foregroundStyle(Palette.text)
            Text(more)
                .font(Fonts.sentence)
                .foregroundStyle(Palette.secondText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The grey the secure field's own placeholder is drawn in, so the two
    /// kinds of field read as one.
    private func prompt(_ words: String) -> Text {
        Text(words).foregroundStyle(Palette.prompt)
    }

    /// A field as the lock screen draws its own, on the card's grey.
    private func framed<Content: View>(isFocused: Bool,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(Fonts.lockField)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Metrics.gap)
            .frame(height: Metrics.lockField.height)
            .background(fieldShape.fill(Palette.field))
            .overlay(fieldShape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.lockFieldRadius + Metrics.focusRing, style: .continuous)
                    .strokeBorder(Palette.focusRing, lineWidth: Metrics.focusRing)
                    .padding(-Metrics.focusRing)
                    .opacity(isFocused && !model.isWorking ? 1 : 0)
            )
            .opacity(model.isWorking ? Palette.disabled : 1)
    }

    @ViewBuilder
    private var refusal: some View {
        if let sentence = model.refusal {
            Text(sentence)
                .font(Fonts.sentence)
                .foregroundStyle(Palette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var working: some View {
        if model.isWorking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Signing in")
        }
    }
}

extension Surface {
    private static func signIn(_ name: String, _ model: @escaping @MainActor () -> SignIn,
                               choice: SignInSheet.ServerChoice = .com, address: String = "",
                               email: String = "") -> Surface {
        Surface(name: name, size: Metrics.windowSize) { _ in
            AnyView(ZStack {
                LockScreen(state: .loggedOut, isSigningIn: true)
                SignInSheet(model: model(), choice: choice, address: address, email: email)
            })
        }
    }

    private static let demoEmail = "demo@oripass.invalid"

    static let signInSheets: [Surface] = [
        signIn("sign-in") { SignIn(drawn: .form) },
        signIn("sign-in-refused", {
            SignIn(drawn: .form, refusal: SignIn.sentence(for: .credentials, on: .eu))
        }, choice: .eu, email: demoEmail),
        signIn("sign-in-working", { SignIn(drawn: .form, isWorking: true) }, email: demoEmail),
        signIn("sign-in-api-key", {
            SignIn(drawn: .form, refusal: SignIn.sentence(for: .noMethod, on: .com), usesAPIKey: true)
        }, choice: .own, address: "https://vault.oripass.invalid"),
        signIn("sign-in-method") { SignIn(drawn: .method([.authenticator, .email])) },
        signIn("sign-in-code") {
            SignIn(drawn: .code(.secondStep(.authenticator)),
                   refusal: SignIn.sentence(forRefused: .secondStep(.authenticator)))
        },
        signIn("sign-in-new-device") { SignIn(drawn: .code(.newDevice), email: demoEmail) },
    ]
}
