import AppKit
import SwiftUI

/// A one-time code in the details (`docs/look.md`, "Item details"): its
/// digits in two groups with a dot between them, and after them a ring that
/// empties as the code runs out, with the seconds it has left.
///
/// The code is a different one every half minute, so something has to draw
/// it again, and nothing should for a code nobody is looking at (D18). The
/// row draws the code once, as it stands, and holds a `TimelineView` only
/// while the place it is laid in can be seen: in a window that is on the
/// screen and not wholly covered, and inside the part of the details that is
/// scrolled into view. Each one that ticks says so in `Instruments`.
struct CodeRow: View {
    /// The moment every code is drawn at in place of the present one. A
    /// run of shots sets it, so two runs draw the same digits; in the app
    /// it is nil.
    static var still: Date?

    /// 16 seconds into nothing in particular: the moment the shots are of,
    /// with as long left as the overview still has.
    static let shotMoment = Date(timeIntervalSince1970: 1_800_000_014)

    let totp: Totp
    let label: String
    /// The row is filled, and what stands on it takes the next shade.
    var isLit = false

    @State private var isInWindow = false
    @State private var isScrolledIn = true

    var body: some View {
        Group {
            if let still = Self.still {
                CodeFace(totp: totp, moment: still, label: label, isLit: isLit)
            } else if isInWindow && isScrolledIn {
                TickingCode(totp: totp, label: label, isLit: isLit)
            } else {
                CodeFace(totp: totp, moment: Date(), label: label, isLit: isLit)
            }
        }
        .background(Seen { isInWindow = $0 })
        .onScrollVisibilityChange(threshold: Self.inView) { isScrolledIn = $0 }
    }

    /// Any part of the row in view counts as the row in view.
    private static let inView = 0.01
}

/// The code drawn again at each whole second, for as long as it is in the
/// tree and no longer.
private struct TickingCode: View {
    /// What `Instruments` is told for as long as this is drawn.
    private final class Token: ObservableObject {
        let registration = Instruments.register(CodeRow.ticking.name, kind: .timer, owner: CodeRow.ticking.owner)
    }

    let totp: Totp
    let label: String
    let isLit: Bool
    @StateObject private var token = Token()

    var body: some View {
        // From the start of a second, so the number changes when a clock's
        // would.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                               by: 1)) { context in
            CodeFace(totp: totp, moment: context.date, label: label, isLit: isLit)
        }
    }
}

extension CodeRow {
    /// A ticking code's entry in the registry.
    static let ticking = (name: "code", owner: "Totp")
    /// The entry of a row that is waiting to hear whether it can be seen.
    static let watching = (name: "seen", owner: "Totp")
}

/// A code as it stands at one moment, drawn from values.
struct CodeFace: View {
    let totp: Totp
    let moment: Date
    var label = "one-time code"
    var isLit = false

    var body: some View {
        let code = totp.code(at: moment)
        let groups = Totp.grouped(code)
        let left = totp.secondsLeft(at: moment)
        let isLast = left <= Metrics.codeLastSeconds
        HStack(spacing: Metrics.close) {
            HStack(spacing: Metrics.tight + Metrics.hair) {
                ForEach(Array(groups.enumerated()), id: \.offset) { place, group in
                    if place > 0 {
                        Circle().fill(Palette.faintText).frame(width: Metrics.codeDot, height: Metrics.codeDot)
                    }
                    Text(group)
                        .font(Fonts.codeDigits)
                        .foregroundStyle(Palette.text)
                }
            }
            HStack(spacing: Metrics.tight) {
                ring(share: totp.share(at: moment), colour: isLast ? Palette.red : Palette.codeRing)
                Text(String(left))
                    .font(Fonts.codeSeconds)
                    .foregroundStyle(isLast ? Palette.red : Palette.secondText)
            }
            .padding(.leading, Metrics.tight)
            .padding(.trailing, Metrics.close)
            .padding(.vertical, Metrics.hair)
            // The row's two grounds the other way round, so the seconds are
            // on the lighter of them whichever the row is on.
            .background(Capsule().fill(isLit ? Palette.content : Palette.rowHover))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(groups.joined(separator: " "))
        .accessibilityAddTraits(.isStaticText)
    }

    /// A faint whole circle, and over it what is left of the period, which
    /// goes back anticlockwise to the top as the seconds do.
    private func ring(share: Double, colour: Color) -> some View {
        ZStack {
            Circle().stroke(Palette.outline, lineWidth: Metrics.codeRingLine)
            Circle()
                .trim(from: 0, to: share)
                .stroke(colour, style: StrokeStyle(lineWidth: Metrics.codeRingLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(Metrics.codeRingLine / 2)
        .frame(width: Metrics.codeRing, height: Metrics.codeRing)
        .accessibilityHidden(true)
    }
}

/// Whether the place this is laid in is in a window that can be seen, told
/// when it changes: the window going onto the screen and off it, behind
/// another and out again, into the Dock and back.
private struct Seen: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(changed: changed) }

    func updateNSView(_ view: Watcher, context: Context) { view.changed = changed }

    final class Watcher: NSView {
        var changed: (Bool) -> Void
        private var observer: NSObjectProtocol?
        private var registration: Instruments.Registration?
        private var said: Bool?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            registration = nil
            if let window {
                registration = Instruments.register(CodeRow.watching.name, kind: .observer,
                                                    owner: CodeRow.watching.owner)
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tell() }
                }
            }
            tell()
        }

        /// At the next turn, since this is called while the views are
        /// being laid out, when nothing of theirs may be changed.
        private func tell() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let isSeen = self.window?.occlusionState.contains(.visible) == true
                guard isSeen != self.said else { return }
                self.said = isSeen
                self.changed(isSeen)
            }
        }
    }
}

extension Surface {
    /// A code with sixteen seconds left, as the overview still has it, and
    /// under it the others a secret can make: one in its last seconds, one
    /// of eight digits that stands for a minute, and Steam's five letters.
    static let codeRows: [Surface] = [
        Surface(name: "code-rows",
                size: CGSize(width: Metrics.windowSize.width - Metrics.sidebarWidth - Metrics.listWidth,
                             height: Metrics.fieldRow * CGFloat(codeFaces.count) + Metrics.toolbarHeight
                                 + Metrics.toolbarHeight)) { _ in
            AnyView(
                Outlined {
                    ForEach(Array(codeFaces.enumerated()), id: \.offset) { place, face in
                        if place > 0 { Hairline(.horizontal) }
                        VStack(alignment: .leading, spacing: Metrics.hair) {
                            FieldLabel("one-time code")
                            if let totp = Totp(face.secret) {
                                CodeFace(totp: totp, moment: face.moment)
                            } else {
                                InvalidCode()
                            }
                        }
                        .padding(.horizontal, Metrics.wide)
                        .frame(maxWidth: .infinity, minHeight: Metrics.fieldRow, alignment: .leading)
                    }
                }
                .padding(Metrics.wide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.content)
            )
        },
    ]

    private static var codeFaces: [(secret: String, moment: Date)] {
        let secret = DemoVault.totpSecrets[0]
        return [
            (secret, CodeRow.shotMoment),
            (secret, CodeRow.shotMoment.addingTimeInterval(13)),
            ("otpauth://totp/Banka?secret=\(secret)&period=60&digits=8&algorithm=SHA256", CodeRow.shotMoment),
            ("steam://\(secret)", CodeRow.shotMoment),
            ("not a secret at all!", CodeRow.shotMoment),
        ]
    }
}

/// What a row says for a secret no code can be made from.
struct InvalidCode: View {
    var body: some View {
        Text(Totp.invalid)
            .font(Fonts.body)
            .foregroundStyle(Palette.secondText)
    }
}
