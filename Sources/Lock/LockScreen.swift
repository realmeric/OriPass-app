import AppKit
import SwiftUI

/// What the window shows whenever the vault is not open (`docs/look.md`, "The
/// lock screen"). Locked, it is the mark, the account under it and the field
/// in the middle of the window. The other states have nothing to type into,
/// and are a sentence and one button each.
///
/// It is handed values and closures and reads no store, so every state can be
/// drawn for a shot without a vault being put into that state first.
struct LockScreen: View {
    let state: VaultStore.State
    var email: String?
    /// The engine's sentence for the password it last refused.
    var refusal: String?
    /// Whether the password is sealed for a finger to open (OP-16). The
    /// fingerprint is drawn only then.
    var hasSeal = false
    var unlock: (SecretBytes) -> Void = { $0.wipe() }
    var askForFinger: () -> Void = {}
    var tryAgain: () -> Void = {}
    /// Raises the sign-in sheet (`SignInSheet`), which is drawn over this.
    var signIn: () -> Void = {}
    /// The sheet is up, and Return is its to take.
    var isSigningIn = false
    /// How many passes stand (`AgentPasses`), which a lock leaves running.
    var passes = 0
    var copy: (String) -> Void = LockScreen.copyToPasteboard

    static let install = "brew install bitwarden-cli"

    /// True from the start: the field takes the keys as soon as it is in a
    /// window, and says so here if it could not.
    @State private var isFocused = true
    @State private var shaken: CGFloat = 0
    @State private var isBreathing = false
    @State private var hasCopied = false

    private var isUnlocking: Bool { state == .unlocking || state == .unlocked }

    var body: some View {
        ZStack {
            Palette.lockGround.ignoresSafeArea()
            switch state {
            case .locked, .unlocking, .unlocked:
                door
            case .noCLI:
                notice("\(AppInfo.name) needs Bitwarden's command line tool",
                       "Install it with Homebrew, then come back to this window.") {
                    command(Self.install)
                }
            case .loggedOut:
                notice("Nobody is signed in",
                       "Sign in to the account whose vault this Mac should open.") {
                    Button("Sign In…", action: signIn)
                        .buttonStyle(FilledButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSigningIn)
                }
            case .failed(let reason):
                notice("The vault did not open", reason) {
                    Button("Try Again", action: tryAgain)
                        .buttonStyle(FilledButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let line = AgentPasses.running(passes) {
                Text(verbatim: line)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
                    .padding(Metrics.loose)
            }
        }
        // The title bar is this window's to draw under: the middle is the
        // window's, not what is left below the traffic lights.
        .ignoresSafeArea()
    }

    // MARK: Locked

    /// The field is what sits in the middle. The mark hangs above it and the
    /// refusal below, so neither moves it when it comes or goes.
    private var door: some View {
        field
            .modifier(Shake(travel: Metrics.shake, turns: CGFloat(Motion.shakes), progress: shaken))
            .overlay(alignment: .top) {
                VStack(spacing: Metrics.wide) {
                    mark
                    Text(email ?? " ")
                        .font(Fonts.sentence)
                        .foregroundStyle(Palette.secondText)
                }
                .fixedSize()
                .alignmentGuide(.top) { $0[.bottom] + Metrics.loose }
            }
            .overlay(alignment: .bottom) {
                Text(refusal ?? "")
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.bottom) { $0[.top] - Metrics.gap }
            }
            .onChange(of: refusal) { _, sentence in
                guard sentence != nil else { return }
                shaken = 0
                withAnimation(Motion.shaking()) { shaken = 1 }
            }
    }

    private var mark: some View {
        Circle()
            .fill(Palette.lit)
            .frame(width: Metrics.lockMark, height: Metrics.lockMark)
            .overlay(
                AppMark()
                    .fill(Palette.onColour, style: AppMark.fill)
                    .frame(width: Metrics.lockMark * Metrics.lockMarkShare,
                           height: Metrics.lockMark * Metrics.lockMarkShare)
            )
            .scaleEffect(isBreathing ? Motion.breathDepth() : 1)
            .animation(isBreathing ? Motion.breathing() : Motion.animation(Motion.quick), value: isBreathing)
            .onAppear { isBreathing = isUnlocking }
            .onChange(of: isUnlocking) { _, unlocking in isBreathing = unlocking }
            .accessibilityHidden(true)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
        return HStack(spacing: 0) {
            PasswordField(placeholder: "Master password", isEnabled: state == .locked,
                          isFocused: $isFocused, submit: unlock)
                .padding(.horizontal, Metrics.gap)
            if hasSeal {
                Rectangle()
                    .fill(Palette.outline)
                    .frame(width: Metrics.hairline)
                    .padding(.vertical, Metrics.close)
                Button(action: askForFinger) {
                    Glyph.fingerprint.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: Metrics.lockFinger, height: Metrics.lockFinger)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, Metrics.close)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isUnlocking)
                .accessibilityLabel("Unlock with Touch ID")
            }
        }
        .frame(width: Metrics.lockField.width, height: Metrics.lockField.height)
        .background(shape.fill(Palette.lockField))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.lockFieldRadius + Metrics.focusRing, style: .continuous)
                .strokeBorder(Palette.focusRing, lineWidth: Metrics.focusRing)
                .padding(-Metrics.focusRing)
                .opacity(isFocused && state == .locked ? 1 : 0)
        )
        .opacity(isUnlocking ? Palette.disabled : 1)
    }

    // MARK: Nothing to type into

    private func notice<Act: View>(_ statement: String, _ more: String,
                                   @ViewBuilder act: () -> Act) -> some View {
        VStack(spacing: Metrics.loose) {
            mark
            VStack(spacing: Metrics.close) {
                Text(statement)
                    .font(Fonts.statement)
                    .foregroundStyle(Palette.text)
                Text(more)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: Metrics.lockSentence)
            .fixedSize(horizontal: false, vertical: true)
            act()
        }
        .padding(Metrics.apart)
    }

    /// A line for a terminal, and the one button that takes it there.
    private func command(_ line: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.lockFieldRadius, style: .continuous)
        return HStack(spacing: Metrics.gap) {
            Text(line)
                .font(Fonts.code)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Rectangle()
                .fill(Palette.outline)
                .frame(width: Metrics.hairline)
                .padding(.vertical, Metrics.close)
            Button(hasCopied ? "Copied" : "Copy") {
                copy(line)
                hasCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Motion.acknowledged * 1_000_000_000))
                    hasCopied = false
                }
            }
            .buttonStyle(.plain)
            .font(Fonts.action)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Metrics.gap)
        .frame(height: Metrics.lockField.height)
        .background(shape.fill(Palette.lockField))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }

    /// A command to paste into a terminal is no secret, so it goes to the
    /// pasteboard as it is, history and all.
    static func copyToPasteboard(_ line: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }
}

/// Side to side and back to where it was: `turns` whole swings as `progress`
/// goes from nought to one.
private struct Shake: GeometryEffect {
    let travel: CGFloat
    let turns: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(progress * turns * 2 * .pi), y: 0))
    }
}

extension Surface {
    private static func lock(_ name: String, _ screen: LockScreen) -> Surface {
        Surface(name: name, size: Metrics.windowSize) { _ in AnyView(screen) }
    }

    private static let demoEmail = "demo@oripass.invalid"

    static let lockScreens: [Surface] = [
        lock("lock", LockScreen(state: .locked, email: demoEmail)),
        lock("lock-finger", LockScreen(state: .locked, email: demoEmail, hasSeal: true)),
        lock("lock-unlocking", LockScreen(state: .unlocking, email: demoEmail, hasSeal: true)),
        lock("lock-refused", LockScreen(state: .locked, email: demoEmail,
                                        refusal: VaultStore.notThePassword, hasSeal: true)),
        // After a finger, when the password it kept has been changed
        // somewhere else: the seal is gone, so there is no fingerprint.
        lock("lock-kept-refused", LockScreen(state: .locked, email: demoEmail,
                                             refusal: VaultStore.keptPasswordRefused)),
        lock("lock-passes", LockScreen(state: .locked, email: demoEmail, hasSeal: true, passes: 2)),
        lock("lock-no-cli", LockScreen(state: .noCLI)),
        lock("lock-logged-out", LockScreen(state: .loggedOut)),
        lock("lock-failed", LockScreen(state: .failed("The engine took too long to answer."))),
    ]
}
