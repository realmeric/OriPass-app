import SwiftUI

struct SignInView: View {
    let model: AppModel

    enum Where: Hashable { case us, eu, own }

    @State private var place = Where.us
    @State private var ownServer = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var step: SignIn.Step?
    @State private var signIn: SignIn?
    @State private var busy = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    enum Field { case email, password, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Server", selection: $place) {
                        Text(verbatim: "bitwarden.com").tag(Where.us)
                        Text(verbatim: "bitwarden.eu").tag(Where.eu)
                        Text("Self-hosted").tag(Where.own)
                    }
                    if place == .own {
                        TextField("Server URL", text: $ownServer)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .disabled(asking)

                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Master Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(go)
                }
                .disabled(asking)

                if let prompt {
                    Section {
                        TextField("Code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .code)
                        if step != .code(.authenticator) {
                            Button("Send Again") { Task { try? await signIn?.sendCodeAgain() } }
                        }
                    } footer: {
                        Text(prompt)
                    }
                }

                Section {
                    Button(action: go) {
                        HStack {
                            Text(asking ? "Continue" : "Sign In")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(!ready || busy)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("OriPass")
            .onAppear { if QuickActions.shared.pending == nil { focus = .email } }
        }
    }

    private var asking: Bool {
        switch step { case .code, .deviceCode: true; default: false }
    }

    private var prompt: String? {
        switch step {
        case .code(.authenticator): String(localized: "Enter the code from your authenticator app.")
        case .code(.email): String(localized: "Enter the code Bitwarden emailed you.")
        case .deviceCode: String(localized: "Enter the code Bitwarden emailed you to confirm this new device.")
        default: nil
        }
    }

    private var server: Server? {
        switch place {
        case .us: .us
        case .eu: .eu
        case .own: Server.own(typed: ownServer)
        }
    }

    private var ready: Bool {
        if asking { return code.count >= 6 }
        return server != nil && email.contains("@") && !password.isEmpty
    }

    private func go() {
        guard ready, !busy, let server else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                let next: SignIn.Step
                if let signIn, asking {
                    next = try await signIn.submit(code: code)
                } else {
                    let secret = SecretBytes(password)
                    defer { secret.wipe() }
                    let fresh = SignIn(client: Client(server: server), email: email, password: secret)
                    signIn = fresh
                    next = try await fresh.start()
                }
                step = next
                if next == .done, let opened = await signIn?.opened {
                    password = ""
                    try model.signedIn(opened)
                } else {
                    code = ""
                    focus = .code
                }
            } catch let failure as SignIn.Failure {
                self.failure = failure.sentence
            } catch {
                self.failure = String(localized: "Something went wrong.")
            }
        }
    }
}

extension SignIn.Failure {
    var sentence: String {
        switch self {
        case .refused(let said): said
        case .unsupportedSecondStep: String(localized: "This account's two-step login is one OriPass can't answer yet. Use an authenticator app or email.")
        case .noMasterPassword: String(localized: "This account doesn't sign in with a master password.")
        case .unreachable: String(localized: "The server can't be reached.")
        }
    }
}
