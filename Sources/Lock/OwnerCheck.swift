import AppKit
import LocalAuthentication
import SwiftUI

/// The real authoriser: a finger when the password is sealed for one, and
/// the master password, typed, when it is not (D7). The finger opens the
/// seal, since a key under `biometryCurrentSet` answers only to a finger
/// that was enrolled when the password was typed, which a plain check of
/// any finger would not say. What comes out is the password, and it is
/// wiped unread and sent nowhere. A typed one is handed to the engine,
/// which says whether it is the one (`VaultStore.confirm`), and is not
/// kept.
///
/// A finger that is cancelled is a no, and the password is not offered in
/// its place: with a seal on this Mac the password is asked for at the
/// lock screen and nowhere else. The password stands in for a finger only
/// when there is none to be had, the lid shut over the sensor among them.
@MainActor
final class OwnerCheck: Authoriser {
    static let unasked = "The engine could not be asked."

    private let store: VaultStore
    private let seal: PasswordSeal?
    private let stage: PasswordStage?
    /// The card, while it is up.
    private(set) var question: PasswordQuestion?

    /// Without a stage there is nowhere to type a password, and the answer
    /// is no.
    init(store: VaultStore, seal: PasswordSeal?, stage: PasswordStage?) {
        self.store = store
        self.seal = seal
        self.stage = stage
    }

    var hasFinger: Bool { seal?.standing == .ready && seal?.canSeal == true }

    func authorise(_ act: GuardedAct, for name: String, on context: LAContext?) async -> Bool {
        guard store.state == .unlocked else { return false }
        guard hasFinger, let seal else { return await askForPassword(act, name) }
        do {
            let password = try await Task.detached { try seal.unseal(reason: act.reason, on: context) }.value
            password.wipe()
            return store.state == .unlocked
        } catch {
            Log.app.info("the finger did not answer for an item: \((error as NSError).code)")
            return false
        }
    }

    func withdraw() {
        seal?.withdraw()
        question?.cancel()
    }

    private func askForPassword(_ act: GuardedAct, _ name: String) async -> Bool {
        guard let stage, question == nil else { return false }
        let isHis = await withCheckedContinuation { (answer: CheckedContinuation<Bool, Never>) in
            let question = PasswordQuestion(act: act, name: name, check: { [weak self] password in
                guard let self else {
                    password.wipe()
                    return Self.unasked
                }
                return await self.check(password)
            }, answer: { answer.resume(returning: $0) })
            self.question = question
            stage.show(question)
        }
        question = nil
        stage.close()
        return isHis
    }

    /// Nil when the engine took the password, and otherwise what to say.
    private func check(_ password: SecretBytes) async -> String? {
        do {
            try await store.confirm(password: password)
            return nil
        } catch VaultError.refused(let sentence) {
            return VaultStore.said(ofAPassword: sentence)
        } catch {
            return Self.unasked
        }
    }
}

/// The master password asked for again, for one act on one item: what the
/// card says, what the engine said of the last try, and the answer. It
/// holds no password. What is typed is in the field until it is handed to
/// the engine, and is wiped there.
@MainActor
final class PasswordQuestion: ObservableObject {
    let act: GuardedAct
    /// The item's name, which goes with the card at the lock.
    let name: String
    @Published private(set) var refusal: String?
    @Published private(set) var isChecking = false
    let typed = TypedSecret()
    /// The try the engine is being asked about, for a test to wait on.
    private(set) var checking: Task<Void, Never>?

    private let check: (SecretBytes) async -> String?
    private var answer: ((Bool) -> Void)?

    /// `refusal` is for a shot of a card that has already said no.
    init(act: GuardedAct, name: String, refusal: String? = nil,
         check: @escaping (SecretBytes) async -> String?, answer: @escaping (Bool) -> Void) {
        self.act = act
        self.name = name
        self.refusal = refusal
        self.check = check
        self.answer = answer
    }

    var statement: String { "“\(name)” asks for the master password" }
    var sentence: String {
        "It is set to ask again before \(act.wanted). The password is checked and is not kept."
    }

    /// Return in the field. A wrong password leaves the card up.
    func submit(_ password: SecretBytes) {
        guard !isChecking, answer != nil else {
            password.wipe()
            return
        }
        isChecking = true
        refusal = nil
        checking = Task { [weak self, check] in
            let said = await check(password)
            guard let self else { return }
            self.isChecking = false
            if let said { self.refusal = said } else { self.finish(true) }
        }
    }

    /// The button, which is as good as Return.
    func submitTyped() {
        if let password = typed.take() { submit(password) }
    }

    /// Esc, Cancel, a click on another window, and the lock.
    func cancel() {
        typed.take()?.wipe()
        finish(false)
    }

    private func finish(_ isHis: Bool) {
        let answer = self.answer
        self.answer = nil
        answer?(isHis)
    }
}

// MARK: - Drawn

/// The card the password is typed into: a lock, the item's name in the
/// statement, what it is being asked for, the field, and two buttons. It
/// stands in a panel of its own in the middle of the screen, where the
/// system puts its sheet for a finger, so the window, a window of one item
/// and Quick Access are all asked in one place.
struct PasswordCard: View {
    @ObservedObject var question: PasswordQuestion
    @State private var isFocused = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        VStack(spacing: Metrics.loose) {
            Glyph.lock.image
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.offerGlyph, height: Metrics.offerGlyph)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(spacing: Metrics.close) {
                Text(question.statement)
                    .font(Fonts.statement)
                    .foregroundStyle(Palette.text)
                Text(question.sentence)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Metrics.close) {
                field
                if let refusal = question.refusal {
                    Text(refusal)
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Metrics.gap) {
                Button("Cancel", action: question.cancel)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: question.submitTyped)
                    .buttonStyle(FilledButtonStyle())
                    .disabled(question.isChecking)
            }
        }
        .padding(Metrics.apart)
        .frame(width: Metrics.offerWidth)
        .background(shape.fill(Palette.content))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
        return PasswordField(placeholder: "Master password", isEnabled: !question.isChecking,
                             typed: question.typed, isFocused: $isFocused, submit: question.submit)
            .padding(.horizontal, Metrics.gap)
            .frame(height: Metrics.lockField.height)
            .frame(maxWidth: .infinity)
            .background(shape.fill(Palette.well))
            .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.lockFieldRadius + Metrics.focusRing, style: .continuous)
                    .strokeBorder(Palette.focusRing, lineWidth: Metrics.focusRing)
                    .padding(-Metrics.focusRing)
                    .opacity(isFocused ? 1 : 0)
            )
            .opacity(question.isChecking ? Palette.disabled : 1)
    }
}

/// Where the card is put. A test hands the check something that only
/// remembers.
@MainActor
protocol PasswordStage: AnyObject {
    func show(_ question: PasswordQuestion)
    func close()
}

/// The card as a panel in the middle of the screen, over every other
/// window, with the keys. Esc, Cancel and the panel losing the keys are
/// each a no, and so is the lock.
@MainActor
final class PasswordPanel: PasswordStage {
    private var panel: Panel?

    var isUp: Bool { panel?.isVisible == true }

    func show(_ question: PasswordQuestion) {
        close()
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.underPointer ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: Metrics.windowSize)
        let panel = Self.make(question, within: screen)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel else { return }
        // Before it is ordered out: losing the keys comes back here.
        self.panel = nil
        panel.dismiss = nil
        panel.orderOut(nil)
        // The item's name and the field go with the view.
        panel.contentView = nil
    }

    /// The panel, sized to its card and centred in `frame`, and not shown.
    static func make(_ question: PasswordQuestion, within frame: NSRect) -> Panel {
        let card = NSHostingView(rootView: PasswordCard(question: question))
        let size = card.fittingSize
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.dismiss = { [weak question] in question?.cancel() }
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = Palette.none
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = card
        return panel
    }

    final class Panel: NSPanel {
        var dismiss: (() -> Void)?

        override var canBecomeKey: Bool { true }

        override func cancelOperation(_ sender: Any?) {
            dismiss?()
        }

        override func resignKey() {
            super.resignKey()
            dismiss?()
        }
    }
}

extension Surface {
    private static func asking(_ name: String, _ act: GuardedAct, refusal: Bool = false) -> Surface {
        Surface(name: name, size: Metrics.passwordCardShot, isBare: true) { _ in
            let question = PasswordQuestion(act: act, name: "GitHub",
                                            refusal: refusal ? VaultStore.notThePassword : nil,
                                            check: { $0.wipe(); return VaultStore.notThePassword },
                                            answer: { _ in })
            return AnyView(PasswordCard(question: question).padding(Metrics.loose))
        }
    }

    /// The master password asked for again: before a copy, and after a
    /// password the engine did not take.
    static let passwordQuestions: [Surface] = [
        asking("reprompt-password", .copy),
        asking("reprompt-refused", .reveal, refusal: true),
    ]
}
