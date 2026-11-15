import AuthenticationServices
import SwiftUI

final class CredentialProviderViewController: ASCredentialProviderViewController {
    private var started = ContinuousClock.now
    /// Face ID asks only once the view is on screen, so what was asked for
    /// before then waits here.
    private var onScreen = false
    private var whenOnScreen: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onScreen = true
        Trace.note("on screen \(Self.milliseconds(since: started)) ms after the ask")
        whenOnScreen?()
        whenOnScreen = nil
    }

    private func once(onScreen work: @escaping () -> Void) {
        if onScreen { work() } else { whenOnScreen = work }
    }

    private lazy var host = UIHostingController(rootView: AnyView(OpeningView()))

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // MARK: A suggestion picked above the keyboard

    /// With no interface: a login or a code from a grace the person chose,
    /// and otherwise the interface is asked for, where a face is.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        started = .now
        Trace.note("asked without an interface, type \(credentialRequest.type.rawValue)")
        if credentialRequest.type == .password || credentialRequest.type == .oneTimeCode,
           let record = credentialRequest.credentialIdentity.recordIdentifier,
           let vault = Unlocking.openInGrace(), let item = try? vault.item(id: record),
           let answer = credentialRequest.type == .oneTimeCode ? Answer.code(item) : Answer.login(item) {
            Trace.note("answered without a face, in grace")
            return complete(answer, refreshing: vault)
        }
        extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        started = .now
        Trace.note("asked with an interface, type \(credentialRequest.type.rawValue)")
        guard let record = credentialRequest.credentialIdentity.recordIdentifier else {
            Trace.note("the identity has no record")
            return fail(.credentialIdentityNotFound)
        }
        once(onScreen: { Task { @MainActor in await self.answer(credentialRequest, record: record) } })
    }

    /// The one item the identity names, opened under a face, and what the
    /// request asked of it: a login into both fields at once (I5), a code,
    /// or a passkey's assertion.
    private func answer(_ request: any ASCredentialRequest, record: String) async {
        do {
            let vault = try await Unlocking.open(reason: String(localized: "Fill a password"))
            let faced = ContinuousClock.now
            let item = try vault.item(id: record)
            let answer: Answer? = switch request.type {
            case .oneTimeCode: Answer.code(item)
            case .passkeyAssertion:
                (request as? ASPasskeyCredentialRequest).flatMap { passkey in
                    Answer.passkey(item, credentialID: (passkey.credentialIdentity as? ASPasskeyCredentialIdentity)?.credentialID,
                                   clientDataHash: passkey.clientDataHash)
                }
            default: Answer.login(item)
            }
            guard let answer else { return fail(.credentialIdentityNotFound) }
            complete(answer, refreshing: vault)
            Trace.note("answered type \(request.type.rawValue) \(Self.milliseconds(since: faced)) ms after the face")
        } catch Unlocking.Failure.face(.cancelled) {
            fail(.userCanceled)
        } catch {
            Trace.note("could not answer: \(error)")
            fail(.failed)
        }
    }

    /// The answer handed back, and the identity store written again from
    /// the vault that was opened for it (I6).
    func complete(_ answer: Answer, refreshing vault: Vault?) {
        let refresh: @Sendable (Bool) -> Void = { _ in
            if let vault { Task { await IdentityStore.replace(with: vault.summaries()) } }
        }
        switch answer {
        case .password(let credential):
            extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: refresh)
        case .code(let code):
            extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code), completionHandler: refresh)
        case .passkey(let credential):
            extensionContext.completeAssertionRequest(using: credential, completionHandler: refresh)
        case .registered(let credential):
            extensionContext.completeRegistrationRequest(using: credential, completionHandler: refresh)
        case .refused(let code):
            fail(code)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%.1f", start.duration(to: .now) / .milliseconds(1))
    }

    // MARK: The list, and the configuration

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        showList(for: serviceIdentifiers, purpose: .login)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        showList(for: serviceIdentifiers, purpose: .passkey(requestParameters))
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        showList(for: serviceIdentifiers, purpose: .code)
    }

    private func showList(for services: [ASCredentialServiceIdentifier], purpose: ListModel.Purpose) {
        Trace.note("asked for the list of \(services.count) services")
        let model = ListModel(services: services, purpose: purpose) { [weak self] answer, vault in
            self?.complete(answer, refreshing: vault)
        }
        host.rootView = AnyView(ListView(model: model) { [weak self] in self?.fail(.userCanceled) })
        once(onScreen: { Task { await model.openWithFace() } })
    }

    // MARK: A new passkey

    /// A site asking for a passkey, after iOS's own sheet has said which
    /// and asked to go on. Only ES256 is made here.
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        started = .now
        Trace.note("asked to make a passkey")
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              request.credentialIdentity is ASPasskeyCredentialIdentity,
              request.supportedAlgorithms.contains(.ES256) else {
            Trace.note("no passkey this app can make")
            return fail(.failed)
        }
        showList(for: [], purpose: .register(request))
    }

    // MARK: iOS 26.2's save and generate

    @available(iOS 26.2, *)
    override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        Trace.note("asked to save without an interface, event \(savePasswordRequest.event.rawValue)")
        fail(.userInteractionRequired)
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        Trace.note("asked to save with an interface")
        let model = SaveModel(request: savePasswordRequest) { [weak self] in
            self?.extensionContext.completeSavePasswordRequest(completionHandler: nil)
        }
        host.rootView = AnyView(SaveView(model: model) { [weak self] in self?.fail(.userCanceled) })
    }

    /// The strong password the keyboard offers on a sign-up form, made here
    /// under the page's rules.
    @available(iOS 26.2, *)
    override func performWithoutUserInteraction(generatePasswordsRequest: ASGeneratePasswordsRequest) {
        let written = generatePasswordsRequest.passwordFieldPasswordRules ?? generatePasswordsRequest.passwordRulesFromQuirks
        Trace.note("asked for a password, \(written == nil ? "no rules" : "with rules")")
        let made = ASGeneratedPassword(kind: .strong, value: PasswordRules(written).password())
        extensionContext.completeGeneratePasswordRequest(results: [made], completionHandler: nil)
    }

    /// Called as OriPass is switched on in Settings: the vault opened once
    /// so that the keyboard's suggestions are there from the first page.
    override func prepareInterfaceForExtensionConfiguration() {
        Trace.note("asked to configure")
        once(onScreen: {
            Task { @MainActor in
                if let vault = try? await Unlocking.open(reason: String(localized: "Turn on AutoFill")) {
                    await IdentityStore.replace(with: vault.summaries())
                    Trace.note("configured with the vault")
                }
                self.extensionContext.completeExtensionConfigurationRequest()
            }
        })
    }

    private func fail(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: ASExtensionError(code))
    }
}

/// What shows for the moment between iOS's sheet and the fill.
struct OpeningView: View {
    var body: some View {
        Image(systemName: "faceid")
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}
