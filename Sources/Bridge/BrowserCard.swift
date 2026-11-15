import AppKit
import SwiftUI

/// An origin the app has not seen, asked about once: which browser, which
/// origin, and the answer, which is the only way an origin gets in.
@MainActor
final class BrowserQuestion {
    let browser: String
    let origin: String
    private var answer: ((Bool) -> Void)?

    init(browser: String, origin: String, answer: @escaping (Bool) -> Void) {
        self.browser = browser
        self.origin = origin
        self.answer = answer
    }

    var statement: String { "Let an extension in \(browser) ask for logins?" }
    var sentence: String {
        "It can list the logins for the page it is on, and is given one when a row of its menu is chosen there. Allow it only if you installed it."
    }

    func allow() { finish(true) }
    func deny() { finish(false) }

    private func finish(_ allowed: Bool) {
        let answer = self.answer
        self.answer = nil
        answer?(allowed)
    }
}

/// The card: built as the password's is, with the origin under the sentence
/// and two buttons, neither of them on a key. It comes up by itself while he
/// is typing into a page, and a Return meant for that page lets nobody in.
struct BrowserCard: View {
    let question: BrowserQuestion

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
                Text(verbatim: question.statement)
                    .font(Fonts.statement)
                    .foregroundStyle(Palette.text)
                Text(verbatim: question.sentence)
                    .font(Fonts.sentence)
                    .foregroundStyle(Palette.secondText)
                Text(verbatim: question.origin)
                    .font(Fonts.code)
                    .foregroundStyle(Palette.secondText)
                    .textSelection(.enabled)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.gap) {
                Button("Deny", action: question.deny)
                    .buttonStyle(QuietButtonStyle())
                Button("Allow", action: question.allow)
                    .buttonStyle(FilledButtonStyle())
            }
        }
        .padding(Metrics.apart)
        .frame(width: Metrics.offerWidth)
        .background(shape.fill(Palette.content))
        .overlay(shape.strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
    }
}

/// Where the card is put. A test hands the door something that only
/// remembers.
@MainActor
protocol BrowserStage: AnyObject {
    func show(_ question: BrowserQuestion)
    func close()
}

/// The card in the middle of the screen, over every other window and every
/// Space, and without the keys, which stay in the page he was typing into.
/// It stays until it is answered or the vault shuts.
@MainActor
final class BrowserPanel: BrowserStage {
    private var panel: NSPanel?

    func show(_ question: BrowserQuestion) {
        close()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Metrics.windowSize)
        let panel = Self.make(question, within: screen)
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// The panel, sized to its card and centred in `frame`, and not shown.
    static func make(_ question: BrowserQuestion, within frame: NSRect) -> NSPanel {
        let card = FirstClickView(rootView: BrowserCard(question: question))
        let size = card.fittingSize
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = Palette.none
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.contentView = card
        return panel
    }

    /// A panel that never had the keys is a panel whose first click would
    /// otherwise only bring it forward.
    private final class FirstClickView: NSHostingView<BrowserCard> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

extension Surface {
    static let browserQuestion = Surface(name: "browser-question", size: Metrics.passwordCardShot, isBare: true) { _ in
        let question = BrowserQuestion(browser: Browser.orion.name,
                                       origin: "chrome-extension://kpmgpeopabaknoepkjmkmdcjkbmgjgkf/") { _ in }
        return AnyView(BrowserCard(question: question).padding(Metrics.loose))
    }
}
