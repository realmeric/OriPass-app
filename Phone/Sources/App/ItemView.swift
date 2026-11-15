import LocalAuthentication
import SwiftUI

/// One item's details: every value it has as a row a tap copies, the
/// hidden ones as dots until shown, a code with its seconds, the sites it
/// opens, its notes, its fields, its history and its dates.
struct ItemView: View {
    let item: Item
    let server: Server?
    let copying: Copying
    var model: AppModel?

    @State private var editing = false
    @State private var shown: Set<String> = []
    @State private var large: String?
    /// An item that asks again (Bitwarden's reprompt) has been answered for.
    @State private var answered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ItemIcon(item: item, server: server).scaleEffect(1.3).frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(item.name).font(.title3.weight(.semibold))
                        Text(item.kind.plural).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
            }
            if case .unknown = item.kind {
                Section {
                    Label("OriPass shows this kind of item field by field.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            main
            if let login = item.login, !login.uris.isEmpty {
                Section("Websites") {
                    ForEach(Array(login.uris.enumerated()), id: \.offset) { _, uri in
                        Group {
                            if let url = openable(uri.uri) {
                                Button {
                                    Recents.used(item.id)
                                    openURL(url)
                                } label: {
                                    Text(uri.uri).foregroundStyle(Color(uiColor: .link)).lineLimit(1)
                                }
                            } else {
                                Text(uri.uri).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button("Copy Address", systemImage: "doc.on.doc") {
                                copying.copy(uri.uri, String(localized: "Address copied"), of: item)
                            }
                        }
                    }
                }
            }
            if !item.fields.isEmpty {
                Section("Fields") {
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { index, field in
                        if field.type == 2 {
                            LabeledContent(field.name ?? "", value: field.value == "true" ? String(localized: "On") : String(localized: "Off"))
                        } else {
                            row(field.name ?? "", field.value, key: "field\(index)", hidden: field.type == 1)
                        }
                    }
                }
            }
            if let notes = item.notes {
                Section("Notes") {
                    Text(notes).textSelection(.enabled)
                }
            }
            if !item.history.isEmpty {
                Section {
                    NavigationLink {
                        HistoryView(item: item, copying: copying)
                    } label: {
                        LabeledContent("Password History", value: "\(item.history.count)")
                    }
                }
            }
            Section {
                if let revised = item.revised {
                    LabeledContent("Modified", value: revised.formatted(date: .abbreviated, time: .shortened))
                }
                if let created = item.created {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .tint(.primary)
        .toolbar {
            if model != nil, item.kind.isKnown, !item.deleted {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            if let model {
                EditItemView(item: item, copying: copying, usernames: Usernames.ranked(model.items)) {
                    try await model.save($0, editing: item)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $large) { value in LargeTypeView(value: value) }
        .onAppear { Recents.used(item.id) }
    }

    @ViewBuilder private var main: some View {
        switch item.kind {
        case .login:
            Section {
                row(Item.usernameWord(item.login?.username), item.login?.username, key: "username")
                row(String(localized: "Password"), item.login?.password, key: "password", hidden: true)
                if let secret = item.login?.totp {
                    CodeRow(secret: secret) { code in copy(code, String(localized: "Code copied")) }
                }
            }
        case .note:
            EmptyView()
        default:
            Section {
                ForEach(item.values, id: \.key) { pair in
                    row(Item.label(for: pair.key), pair.value, key: pair.key, hidden: Item.hiddenKeys.contains(pair.key))
                }
            }
        }
    }

    /// One value: its label over it, a tap to copy, dots until shown when
    /// it is hidden, and Large Type from its menu.
    @ViewBuilder private func row(_ label: String, _ value: String?, key: String, hidden: Bool = false) -> some View {
        if let value, !value.isEmpty {
            let concealed = hidden && !shown.contains(key)
            Button {
                copy(value, String(localized: "\(label) copied"))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(concealed ? String(repeating: "•", count: 10) : value)
                            .font(hidden ? .body.monospaced() : .body)
                            .foregroundStyle(.primary)
                            .accessibilityLabel(concealed ? String(localized: "concealed") : value)
                    }
                    Spacer()
                    if hidden {
                        Button {
                            Task {
                                guard await askedAgain() else { return }
                                if shown.contains(key) { shown.remove(key) } else { shown.insert(key) }
                            }
                        } label: {
                            Image(systemName: concealed ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(concealed ? String(localized: "Reveal") : String(localized: "Conceal"))
                    }
                }
            }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copy(value, String(localized: "\(label) copied")) }
                if hidden {
                    Button("Show in Large Type", systemImage: "textformat.size") {
                        Task { if await askedAgain() { large = value } }
                    }
                }
            }
        }
    }

    private func copy(_ value: String, _ said: String) {
        Task { if await askedAgain() { copying.copy(value, said, of: item) } }
    }

    /// For an item that asks again, a face before the first reveal or copy
    /// while it is open.
    private func askedAgain() async -> Bool {
        guard item.asksAgain, !answered else { return true }
        let context = LAContext()
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                     localizedReason: String(localized: "Show this item"))) ?? false
        answered = ok
        return ok
    }

    private func openable(_ written: String) -> URL? {
        let full = written.contains("://") ? written : "https://" + written
        guard let url = URL(string: full), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }
}

/// A login's code, its seconds counting down in a ring, a tap to copy it.
struct CodeRow: View {
    let secret: String
    let copy: (String) -> Void

    var body: some View {
        if let totp = Totp(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = totp.code(at: context.date)
                Button { copy(code) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("One-Time Code").font(.caption).foregroundStyle(.secondary)
                            Text(Totp.grouped(code).joined(separator: " "))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Gauge(value: Double(totp.secondsLeft(at: context.date)), in: 0...Double(totp.period)) {
                            EmptyView()
                        } currentValueLabel: {
                            Text("\(totp.secondsLeft(at: context.date))").font(.caption2.monospacedDigit())
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .scaleEffect(0.6)
                        .frame(width: 32, height: 32)
                    }
                }
            }
        }
    }
}

/// A value large, a character to a cell with its place under it, digits
/// and symbols set apart by colour.
struct LargeTypeView: View {
    let value: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                    ForEach(Array(value.enumerated()), id: \.offset) { index, character in
                        VStack(spacing: 2) {
                            Text(String(character))
                                .font(.system(size: 40, weight: .medium, design: .monospaced))
                                .foregroundStyle(character.isNumber ? .blue : character.isLetter ? .primary : .red)
                            Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(.quaternary.opacity(index.isMultiple(of: 2) ? 0.6 : 0.3), in: .rect(cornerRadius: 8))
                    }
                }
                .padding()
            }
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// A login's earlier passwords, newest first, hidden, a tap to copy.
struct HistoryView: View {
    let item: Item
    let copying: Copying

    var body: some View {
        List {
            ForEach(Array(item.history.enumerated()), id: \.offset) { _, entry in
                Button {
                    copying.copy(entry.password, String(localized: "Password copied"), of: item)
                } label: {
                    VStack(alignment: .leading) {
                        Text(String(repeating: "•", count: 10)).font(.body.monospaced()).foregroundStyle(.primary)
                        if let used = entry.used {
                            Text(used.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Password History")
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

extension Item {
    static let hiddenKeys: Set<String> = ["number", "code", "ssn", "passportNumber", "licenseNumber", "privateKey"]

    /// "Email" when the username is one, as the Mac's `Login.word` has it.
    static func usernameWord(_ username: String?) -> String {
        guard let username, username.contains("@"), username.contains(".") else { return String(localized: "Username") }
        return String(localized: "Email")
    }

    static func label(for key: String) -> String {
        switch key {
        case "cardholderName": String(localized: "Cardholder Name")
        case "brand": String(localized: "Brand")
        case "number": String(localized: "Number")
        case "expMonth": String(localized: "Expiry Month")
        case "expYear": String(localized: "Expiry Year")
        case "code": String(localized: "Security Code")
        case "title": String(localized: "Title")
        case "firstName": String(localized: "First Name")
        case "middleName": String(localized: "Middle Name")
        case "lastName": String(localized: "Last Name")
        case "username": String(localized: "Username")
        case "company": String(localized: "Company")
        case "email": String(localized: "Email")
        case "phone": String(localized: "Phone")
        case "address1", "address2", "address3": String(localized: "Address")
        case "city": String(localized: "City")
        case "state": String(localized: "State")
        case "postalCode": String(localized: "Postal Code")
        case "country": String(localized: "Country")
        case "ssn": String(localized: "Social Security Number")
        case "passportNumber": String(localized: "Passport Number")
        case "licenseNumber": String(localized: "License Number")
        case "privateKey": String(localized: "Private Key")
        case "publicKey": String(localized: "Public Key")
        case "keyFingerprint": String(localized: "Fingerprint")
        default: key
        }
    }
}

extension Item.Kind {
    /// One of the five types the app can draw a form for.
    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}
