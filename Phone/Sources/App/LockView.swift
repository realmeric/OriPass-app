import SwiftUI

struct LockView: View {
    let model: AppModel
    let account: Account

    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Master Password", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(unlock)
                } header: {
                    Text(verbatim: account.email)
                } footer: {
                    if let sentence = model.lockSentence {
                        Text(sentence).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: unlock) {
                        HStack {
                            Text("Unlock")
                            Spacer()
                            if model.derivingKey { ProgressView() }
                        }
                    }
                    .disabled(password.isEmpty || model.unlocking)
                    if model.canUseFace {
                        Button {
                            Task { await model.unlockWithFace() }
                        } label: {
                            Label("Unlock with Face ID", systemImage: "faceid")
                        }
                        .disabled(model.unlocking)
                    }
                }
            }
            .navigationTitle("OriPass")
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let secret = SecretBytes(password)
        password = ""
        Task {
            await model.unlock(password: secret)
            secret.wipe()
        }
    }
}
