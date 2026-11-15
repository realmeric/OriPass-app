import SwiftUI

/// The account, how it locks, AutoFill, site icons, the vault in counts,
/// and signing out.
struct SettingsView: View {
    @Bindable var model: AppModel
    let account: Account

    @State private var signingOut = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Email", value: account.email)
                    LabeledContent("Server", value: account.server.name)
                    Link(destination: account.server.webVault) {
                        Label("Open Web Vault", systemImage: "safari")
                    }
                } header: {
                    Text("Account")
                }

                Section {
                    if FaceKey.available {
                        Toggle("Unlock with Face ID", isOn: $model.choices.faceID)
                    }
                    Picker("Lock", selection: $model.choices.lockAfter) {
                        Text("Immediately").tag(0)
                        Text("After 1 Minute").tag(60)
                        Text("After 5 Minutes").tag(300)
                        Text("After 15 Minutes").tag(900)
                    }
                    Picker("Fill Without Face ID", selection: $model.choices.grace) {
                        Text("Never").tag(0)
                        Text("For 1 Minute").tag(1)
                        Text("For 2 Minutes").tag(2)
                        Text("For 5 Minutes").tag(5)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("The vault also locks when the iPhone locks. Filling without Face ID keeps a copy of the vault's key on this iPhone for those minutes, which anyone holding it unlocked could fill with.")
                }

                Section {
                    if model.autoFillOn {
                        LabeledContent("AutoFill", value: String(localized: "On"))
                    } else {
                        Button("Turn On AutoFill", systemImage: "key.viewfinder") { Task { await model.turnOnAutoFill() } }
                    }
                } header: {
                    Text("AutoFill")
                }

                Section {
                    Toggle("Site Icons", isOn: $model.choices.siteIcons)
                } footer: {
                    Text("Icons come from your Bitwarden server, which learns which sites you have logins for.")
                }

                if let census = model.census {
                    Section {
                        NavigationLink("About This Vault") {
                            AboutView(census: census, account: account, opened: model.faceToVault)
                        }
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) { signingOut = true }
                        .confirmationDialog("Sign out of \(account.email)?", isPresented: $signingOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) {
                                Task {
                                    dismiss()
                                    await model.signOut()
                                }
                            }
                        } message: {
                            Text("The vault, its key and its suggestions are removed from this iPhone.")
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension Server {
    var name: String {
        switch self {
        case .us: "bitwarden.com"
        case .eu: "bitwarden.eu"
        case .own(let url): url.host() ?? url.absoluteString
        }
    }
}
