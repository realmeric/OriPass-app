import SwiftUI

/// An app with a sign-in form and nothing else, so that the UI tests can
/// fill one that is not a web page.
@main
struct FormsApp: App {
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                    Text(verbatim: "username \(username.count) password \(password.count)")
                        .accessibilityIdentifier("counts")
                }
                .navigationTitle("Forms")
            }
        }
    }
}
