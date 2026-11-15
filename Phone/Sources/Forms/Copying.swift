import SwiftUI

/// A copy from anywhere in the app: the value to the pasteboard, a tap
/// felt, and "Copied" said for a moment over the screen.
@MainActor @Observable
final class Copying {
    private(set) var said: String?
    private(set) var count = 0

    func copy(_ value: String?, _ what: String, of item: Item? = nil) {
        guard let value, !value.isEmpty else { return }
        Pasteboard.copy(value)
        if let item { Recents.used(item.id) }
        count += 1
        said = what
        let now = count
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if count == now { said = nil }
        }
    }
}

/// "Copied", and what, in a capsule of the system's material at the
/// bottom, with the haptic iOS gives a success.
struct CopiedNotice: ViewModifier {
    let copying: Copying

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let said = copying.said {
                    Label(said, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: copying.said)
            .sensoryFeedback(.success, trigger: copying.count)
    }
}
