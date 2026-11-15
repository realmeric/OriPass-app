import AuthenticationServices
import SwiftUI

/// iOS's "save this password?" handed to OriPass: the site, the username,
/// a title, and Save under a face. A login already there for the site and
/// the username takes the new password; otherwise a new login is made.
@available(iOS 26.2, *)
@MainActor @Observable
final class SaveModel {
    let request: ASSavePasswordRequest
    var title: String
    private(set) var saving = false
    private(set) var failure: String?
    private let finish: () -> Void

    init(request: ASSavePasswordRequest, finish: @escaping () -> Void) {
        self.request = request
        self.finish = finish
        title = request.title ?? Matching.page(request.serviceIdentifier).host ?? request.serviceIdentifier.identifier
    }

    var host: String { Matching.page(request.serviceIdentifier).host ?? request.serviceIdentifier.identifier }

    func save() async {
        saving = true
        defer { saving = false }
        do {
            guard let account = Account.stored(), let tokens = Tokens.stored() else { throw SaveFailure.notOpen }
            let vault = try await Unlocking.open(reason: String(localized: "Save a password"))
            let api = Api(client: Client(server: account.server), tokens: tokens)
            let username = request.credential.user
            let existing = Saving.existing(host: host, username: username, in: vault)
            var draft = existing.map(Draft.init) ?? Draft()
            if existing == nil {
                draft.name = title
                draft.username = username
                draft.uris = ["https://" + host]
            }
            draft.password = request.credential.password
            let data = try await Saving.save(draft, editing: existing, in: vault, with: api)
            if let opened = try? Vault(data: data, userKey: vault.userKey) { await IdentityStore.replace(with: opened.summaries()) }
            Trace.note(existing == nil ? "saved a new login" : "saved a new password to a login")
            finish()
        } catch Unlocking.Failure.face(.cancelled) {
            failure = nil
        } catch {
            Trace.note("could not save: \(error)")
            failure = String(localized: "It could not be saved.")
        }
    }
}

@available(iOS 26.2, *)
struct SaveView: View {
    @Bindable var model: SaveModel
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title)
                    LabeledContent("Website", value: model.host)
                    LabeledContent("Username", value: model.request.credential.user)
                    LabeledContent("Password", value: String(repeating: "•", count: 10))
                } footer: {
                    if let failure = model.failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Save to OriPass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel, action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving { ProgressView() } else { Button("Save") { Task { await model.save() } } }
                }
            }
        }
    }
}
