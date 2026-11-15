import SwiftUI

struct ListView: View {
    @Bindable var model: ListModel
    let cancel: () -> Void

    @State private var password = ""
    @State private var adding = false
    @State private var copying = Copying()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("OriPass")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                    if model.state == .open, case .login = model.purpose {
                        ToolbarItem(placement: .primaryAction) {
                            Button("New Login", systemImage: "plus") { adding = true }
                        }
                    }
                }
                .sheet(isPresented: $adding) {
                    EditItemView(item: nil, start: model.newLogin, copying: copying, usernames: model.usernames) {
                        try await model.add($0)
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .opening:
            Image(systemName: "faceid")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .password(let sentence):
            Form {
                Section {
                    SecureField("Master Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(unlock)
                } footer: {
                    if let sentence { Text(sentence).foregroundStyle(.red) }
                }
                Section {
                    Button("Unlock", action: unlock).disabled(password.isEmpty)
                }
            }
        case .open:
            if case .register = model.purpose { homes } else { list }
        }
    }

    /// Where a new passkey goes: a login of the site's, or a new one.
    private var homes: some View {
        List {
            Section {
                ForEach(model.homes) { summary in
                    home(summary.name, summary.username, on: summary)
                }
                home(String(localized: "New Login"), model.registeringUser, on: nil)
            } header: {
                Text("Save Passkey To")
            } footer: {
                if let failure = model.failure { Text(failure).foregroundStyle(.red) }
            }
        }
        .tint(.primary)
        .disabled(model.registering)
        .overlay { if model.registering { ProgressView() } }
    }

    private func home(_ name: String, _ username: String?, on summary: Summary?) -> some View {
        Button { Task { await model.register(on: summary) } } label: {
            VStack(alignment: .leading) {
                Text(name).foregroundStyle(.primary)
                if let username, !username.isEmpty {
                    Text(username).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var list: some View {
        List {
            if !model.passkeys.isEmpty {
                Section("Passkeys") {
                    ForEach(model.passkeys) { summary in
                        Button { model.signIn(with: summary) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(summary.name)
                                    if let user = summary.passkeys.first?.userName {
                                        Text(user).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "person.badge.key")
                            }
                        }
                    }
                }
            }
            if !model.suggested.isEmpty {
                Section("Suggested") { rows(model.suggested) }
            }
            Section(model.suggested.isEmpty ? "Logins" : "All Logins") { rows(model.others) }
        }
        .tint(.primary)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always))
    }

    private func rows(_ summaries: [Summary]) -> some View {
        ForEach(summaries) { summary in
            Button { model.fill(summary) } label: {
                VStack(alignment: .leading) {
                    Text(summary.name).foregroundStyle(.primary)
                    if let username = summary.username {
                        Text(username).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                if summary.username != nil {
                    Button("Copy Username", systemImage: "person") { model.copy(.username, of: summary) }
                }
                if summary.hasPassword {
                    Button("Copy Password", systemImage: "key") { model.copy(.password, of: summary) }
                }
                if summary.hasTotp {
                    Button("Copy Code", systemImage: "clock") { model.copy(.code, of: summary) }
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let secret = SecretBytes(password)
        password = ""
        Task {
            await model.open(password: secret)
            secret.wipe()
        }
    }
}
