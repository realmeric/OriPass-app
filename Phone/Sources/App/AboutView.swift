import SwiftUI

/// The vault in counts, for the notes: nothing here is a value.
struct AboutView: View {
    let census: Census
    let account: Account
    let opened: Duration?

    var body: some View {
        Form {
                Section("Items") {
                    ForEach(census.items.sorted { $0.key < $1.key }, id: \.key) { LabeledContent($0.key, value: "\($0.value)") }
                    LabeledContent("With their own key", value: "\(census.withOwnKey)")
                    LabeledContent("With a code", value: "\(census.withCode)")
                    LabeledContent("With a passkey", value: "\(census.withPasskey)")
                    LabeledContent("In an organisation", value: "\(census.inOrganisations)")
                    LabeledContent("In the trash", value: "\(census.inTrash)")
                }
                Section("Encrypted Strings") {
                    ForEach(census.strings.sorted { $0.key < $1.key }, id: \.key) {
                        LabeledContent("Type \($0.key)", value: "\($0.value)")
                    }
                }
                if !census.unread.isEmpty {
                    Section("Not Opened") {
                        ForEach(census.unread.sorted { $0.key < $1.key }, id: \.key) { LabeledContent($0.key, value: "\($0.value)") }
                    }
                }
                Section("Unlock") {
                    LabeledContent("Key derivation", value: "\(account.kdf)")
                    if let opened {
                        LabeledContent("Face to vault", value: opened.formatted(.units(allowed: [.milliseconds])))
                    }
                }
                Section("Credits") {
                    Text("Passphrases use the EFF long word list, by the Electronic Frontier Foundation, under CC BY 3.0 US.")
                    Text("Sites are told apart with the Public Suffix List, by Mozilla, under the MPL 2.0.")
                }
            }
        .navigationTitle("About This Vault")
        .navigationBarTitleDisplayMode(.inline)
    }
}
