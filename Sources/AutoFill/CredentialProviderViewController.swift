import AppKit
import AuthenticationServices
import SwiftUI

/// What the system starts when OriPass is picked from its Passwords menu or
/// for a page's passkey or code, in `OriPassAutoFill.appex`, sandboxed. It is a client
/// of the door like the browser's, so D4 stands: it holds no vault, decrypts
/// nothing and signs nothing. It is compiled into the app as well, as
/// Safari's handler is, where nothing makes one.
///
/// It writes nothing to the system's list of identities (D6). The app does,
/// and only passkeys, with `PrivacyChoices.passkeysInSystemList` on, so a
/// passkey is the one identity that can come back here to be answered.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var sheet: AutoFillSheet?

    override func loadView() {
        view = host
        preferredContentSize = Metrics.autoFillSheet
    }

    /// The system may name nothing here, in a browser as well.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        show(serviceIdentifiers.compactMap(AutoFillService.init), looksInFront: true)
    }

    /// The services are left out: a passkey is its relying party's, and the
    /// list holds nothing else.
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        show(service(requestParameters.relyingPartyIdentifier, allowed: requestParameters.allowedCredentials,
                     hash: requestParameters.clientDataHash))
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        show(serviceIdentifiers.compactMap(AutoFillService.init), isForCodes: true, looksInFront: true)
    }

    private func service(_ relyingParty: String, allowed: [Data], hash: Data) -> [AutoFillService] {
        relyingParty.isEmpty ? [] : [.passkey(relyingParty: relyingParty, allowed: allowed, clientDataHash: hash)]
    }

    private func show(_ services: [AutoFillService], isForCodes: Bool = false, takingALoneRow: Bool = false,
                      looksInFront: Bool = false) {
        let sheet = AutoFillSheet(services: services, door: BridgeSheetDoor(), isForCodes: isForCodes,
                                  looksInFront: looksInFront) { [weak self] credential in
            self?.extensionContext.completeRequest(
                withSelectedCredential: ASPasswordCredential(user: credential.username, password: credential.password))
        } assert: { [weak self] assertion in
            guard case .passkey(let relyingParty, _, let hash)? = services.first else { return }
            self?.extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
                userHandle: assertion.userHandle, relyingParty: relyingParty, signature: assertion.signature,
                clientDataHash: hash, authenticatorData: assertion.authenticatorData, credentialID: assertion.credential))
        } code: { [weak self] code in
            self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code.code))
        } dismiss: { [weak self] in
            self?.leave(.userCanceled)
        }
        self.sheet = sheet
        host.rootView = AnyView(AutoFillSheetView(sheet: sheet))
        sheet.begin(takingALoneRow: takingALoneRow)
    }

    /// Every assertion takes a finger and a code may, and either needs the
    /// sheet up. No password is on the system's list to be answered.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        leave(credentialRequest.type == .password ? .credentialIdentityNotFound : .userInteractionRequired)
    }

    /// A passkey picked from the system's list, which is the one identity
    /// that list holds. The door hears it as an ask for that id alone.
    ///
    /// Nothing here writes a code's identity (D6), so that request comes
    /// only if the system makes one by itself, and it names just a service.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        if credentialRequest is ASOneTimeCodeCredentialRequest {
            let named = AutoFillService(credentialRequest.credentialIdentity.serviceIdentifier)
            return show(named.map { [$0] } ?? [], isForCodes: true, takingALoneRow: true)
        }
        guard let request = credentialRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else { return leave(.credentialIdentityNotFound) }
        show(service(identity.relyingPartyIdentifier, allowed: [identity.credentialID], hash: request.clientDataHash),
             takingALoneRow: true)
    }

    /// `ProvidesPasskeys` also offers OriPass to a page making one, and the
    /// header does not say what the base class does then. The door can make
    /// one, but nothing here asks it to until `scripts/spike-passkey.py` has
    /// said on the real engine that a key sent to it stays encrypted (OP-76).
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        leave(.failed)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sheet?.end()
    }

    private func leave(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: ASExtensionError(code))
    }
}
