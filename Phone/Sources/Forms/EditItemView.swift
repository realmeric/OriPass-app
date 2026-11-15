import SwiftUI

/// Any of the five types as a form, for an item or a new one, in the app or
/// in the AutoFill extension; `save` is where it goes.
struct EditItemView: View {
    let item: Item?
    let copying: Copying
    let save: (Draft) async throws -> Void
    /// The usernames the vault already uses, most used first (PH-27).
    var usernames: [String] = []

    @State private var draft: Draft
    @FocusState private var usernameFocused: Bool
    @State private var showing = false
    @State private var generating = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(item: Item?, kind: Item.Kind = .login, start: Draft? = nil, copying: Copying, usernames: [String] = [],
         save: @escaping (Draft) async throws -> Void) {
        self.item = item
        self.copying = copying
        self.usernames = usernames
        self.save = save
        _draft = State(initialValue: item.map(Draft.init) ?? start ?? Draft(kind: kind))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.name)
                }
                if draft.kind == .login {
                    Section {
                        TextField("Username", text: $draft.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($usernameFocused)
                        if usernameFocused {
                            UsernameRow(offered: Usernames.matching(draft.username, in: usernames)) { draft.username = $0 }
                        }
                        HStack {
                            Group {
                                if showing {
                                    TextField("Password", text: $draft.password)
                                } else {
                                    SecureField("Password", text: $draft.password)
                                }
                            }
                            .font(.body.monospaced())
                            .textContentType(.newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            Button(showing ? "Conceal" : "Reveal", systemImage: showing ? "eye.slash" : "eye") { showing.toggle() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            Button("Generator", systemImage: "wand.and.stars") { generating = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    Section("Websites") {
                        ForEach(draft.uris.indices, id: \.self) { index in
                            TextField("Website", text: $draft.uris[index])
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .onDelete { draft.uris.remove(atOffsets: $0) }
                        Button("Add Website", systemImage: "plus") { draft.uris.append("") }
                    }
                    Section("One-Time Code") {
                        TextField("Secret or otpauth:// address", text: $draft.totp)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                switch draft.kind {
                case .card: cardSections
                case .identity: identitySections
                case .sshKey: keySections
                default: EmptyView()
                }
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...12)
                }
                Section {
                    Toggle("Favorite", isOn: $draft.favorite)
                } footer: {
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(item == nil ? draft.kind.newTitle : String(localized: "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(draft != (item.map(Draft.init) ?? Draft(kind: draft.kind)))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: send).disabled(!savable)
                    }
                }
            }
            .sheet(isPresented: $generating) {
                GeneratorView(copying: copying) { draft.password = $0 }
            }
        }
    }

    private var savable: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return draft.kind != .sshKey || draft.values["privateKey"]?.isEmpty == false
    }

    private func value(_ key: String) -> Binding<String> {
        Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0 })
    }

    private func field(_ label: LocalizedStringKey, _ key: String, keyboard: UIKeyboardType = .default,
                       content: UITextContentType? = nil) -> some View {
        TextField(label, text: value(key))
            .keyboardType(keyboard)
            .textContentType(content)
    }

    // MARK: A card, as Bitwarden's apps write one

    static let brands = ["Visa", "Mastercard", "Amex", "Discover", "Diners Club", "JCB", "Maestro", "UnionPay", "RuPay", "Other"]

    @ViewBuilder private var cardSections: some View {
        Section {
            field("Cardholder Name", "cardholderName", content: .name)
            Picker("Brand", selection: value("brand")) {
                Text("None").tag("")
                ForEach(Self.brands, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            field("Number", "number", keyboard: .numberPad, content: .creditCardNumber)
                .font(.body.monospaced())
            Picker("Expiry Month", selection: value("expMonth")) {
                Text("None").tag("")
                ForEach(1...12, id: \.self) { month in
                    Text(Calendar.current.monthSymbols[month - 1]).tag("\(month)")
                }
            }
            field("Expiry Year", "expYear", keyboard: .numberPad, content: .creditCardExpirationYear)
            field("Security Code", "code", keyboard: .numberPad, content: .creditCardSecurityCode)
                .font(.body.monospaced())
        }
    }

    // MARK: An identity

    @ViewBuilder private var identitySections: some View {
        Section {
            Picker("Title", selection: value("title")) {
                Text("None").tag("")
                ForEach(["Mr", "Mrs", "Ms", "Mx", "Dr"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            field("First Name", "firstName", content: .givenName)
            field("Middle Name", "middleName", content: .middleName)
            field("Last Name", "lastName", content: .familyName)
            field("Username", "username", content: .username)
            field("Company", "company", content: .organizationName)
        }
        Section {
            field("Email", "email", keyboard: .emailAddress, content: .emailAddress)
            field("Phone", "phone", keyboard: .phonePad, content: .telephoneNumber)
        }
        Section("Address") {
            field("Address", "address1", content: .streetAddressLine1)
            field("Address 2", "address2", content: .streetAddressLine2)
            field("Address 3", "address3")
            field("City", "city", content: .addressCity)
            field("State", "state", content: .addressState)
            field("Postal Code", "postalCode", content: .postalCode)
            field("Country", "country", content: .countryName)
        }
        Section {
            field("Social Security Number", "ssn")
            field("Passport Number", "passportNumber")
            field("License Number", "licenseNumber")
        }
    }

    // MARK: An SSH key, made here or pasted in

    @ViewBuilder private var keySections: some View {
        Section {
            if let publicKey = draft.values["publicKey"], !publicKey.isEmpty {
                LabeledContent("Public Key") {
                    Text(publicKey).font(.footnote.monospaced()).lineLimit(2).truncationMode(.middle)
                }
                LabeledContent("Fingerprint") {
                    Text(draft.values["keyFingerprint"] ?? "").font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                }
            }
            Button(draft.values["privateKey"]?.isEmpty == false ? "Generate a New Key" : "Generate Key", systemImage: "key") {
                take(SSHKeys.generate())
            }
            PasteButton(payloadType: String.self) { pasted in
                guard let text = pasted.first else { return }
                do {
                    take(try PastedKey(pasted: text))
                } catch let refusal as PastedKey.Refusal {
                    failure = refusal.sentence
                } catch {}
            }
        } footer: {
            Text("Ed25519, or a private key in OpenSSH's format without a passphrase.")
        }
    }

    private func take(_ key: PastedKey) {
        failure = nil
        draft.values["privateKey"] = key.privateKey
        draft.values["publicKey"] = key.publicKey
        draft.values["keyFingerprint"] = key.fingerprint
    }

    private func send() {
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                try await save(draft)
                dismiss()
            } catch SaveFailure.outOfDate {
                failure = String(localized: "This item was changed somewhere else. It has been synced; try again.")
            } catch SaveFailure.refused(let said) {
                failure = said ?? String(localized: "The server did not take it.")
            } catch {
                failure = String(localized: "It could not be saved.")
            }
        }
    }
}

extension Item.Kind {
    var newTitle: String {
        switch self {
        case .login: String(localized: "New Login")
        case .note: String(localized: "New Note")
        case .card: String(localized: "New Card")
        case .identity: String(localized: "New Identity")
        case .sshKey: String(localized: "New SSH Key")
        case .unknown: String(localized: "New Item")
        }
    }
}

/// The usernames already used, a row of the system's bordered buttons under
/// the field, scrolled sideways; a tap fills the field. iOS offers nothing
/// for this.
struct UsernameRow: View {
    let offered: [String]
    let take: (String) -> Void

    var body: some View {
        if !offered.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(offered.prefix(20), id: \.self) { name in
                        Button(name) { take(name) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .accessibilityLabel("Usernames already used")
        }
    }
}
