import AppKit
import Combine
import SwiftUI

/// The windows that hold one item's details each (⌘O). They are the panes'
/// that opened them, so they go when those go: `Panes.end` closes every one
/// before the door drops the panes, and a locked app has none (D6). One
/// whose item has been deleted for good closes by itself.
///
/// Each has panes of its own, pinned to its item, so what is revealed in one
/// window is not revealed in another.
@MainActor
final class ItemWindows: NSObject, NSWindowDelegate {
    private var open: [(window: NSWindow, panes: Panes)] = []
    private let present: ((NSWindow) -> Void)?
    private var watching: AnyCancellable?

    /// Without `present` a window is made and never shown, which is what a
    /// test wants.
    init(present: ((NSWindow) -> Void)?) {
        self.present = present
    }

    var windows: [NSWindow] { open.map(\.window) }

    /// The panes of the window that has the keys, when it is one of these.
    var inFront: Panes? {
        open.first { $0.window.isKeyWindow }?.panes
    }

    func panes(showing id: String) -> Panes? {
        open.first { $0.panes.pinned == id }?.panes
    }

    /// A second ⌘O on an item brings its window forward.
    @discardableResult
    func open(_ id: String, from parent: Panes) -> NSWindow? {
        if let standing = open.first(where: { $0.panes.pinned == id }) {
            present?(standing.window)
            return standing.window
        }
        guard let item = parent.store.entry(id: id)?.item else { return nil }
        let panes = parent.pinned(to: id)
        let window = Self.frame()
        window.title = item.name
        window.contentView = NSHostingView(rootView: ItemWindowView(panes: panes))
        window.delegate = self
        window.center()
        open.append((window, panes))
        if watching == nil {
            // After the change, when the store holds what it now holds.
            watching = parent.store.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.closeGone()
            }
        }
        present?(window)
        return window
    }

    func closeAll() {
        watching = nil
        let closing = open
        open = []
        closing.forEach(put(away:))
    }

    private func closeGone() {
        let gone = open.filter { $0.panes.selectedItem == nil }
        open.removeAll { $0.panes.selectedItem == nil }
        gone.forEach(put(away:))
        if open.isEmpty { watching = nil }
    }

    /// Nothing of the item stays in a window that is no longer shown: not
    /// its views, and not its name in the Window menu.
    private func put(away closing: (window: NSWindow, panes: Panes)) {
        closing.panes.end()
        closing.window.delegate = nil
        closing.window.contentView = nil
        closing.window.title = ""
        NSApp.removeWindowsItem(closing.window)
        closing.window.close()
    }

    /// He closed it.
    func windowWillClose(_ notification: Notification) {
        guard let place = open.firstIndex(where: { $0.window === notification.object as? NSWindow }) else { return }
        let closing = open.remove(at: place)
        closing.panes.end()
        closing.window.delegate = nil
        closing.window.contentView = nil
        closing.window.title = ""
        if open.isEmpty { watching = nil }
    }

    /// The window before anything is put in it: the main one's title bar
    /// without its toolbar, the size of a details column, and nothing of it
    /// restored or remembered.
    static func frame() -> NSWindow {
        let window = VaultWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.itemWindow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = CGSize(width: Metrics.detailMinimum, height: Metrics.windowMinimum.height)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        return window
    }
}

/// One item's details, with the same menus over them as the main window's.
struct ItemWindowView: View {
    @ObservedObject var panes: Panes
    @ObservedObject private var store: VaultStore
    /// Moves with the zoom and the density, so the window is drawn again
    /// at the new size.
    @State private var drawn = 0

    init(panes: Panes) {
        self.panes = panes
        store = panes.store
    }

    var body: some View {
        Group {
            if let editor = panes.editor {
                EditorView(panes: panes, editor: editor)
            } else if let detail = panes.detail {
                ItemDetailView(panes: panes, detail: detail, strength: panes.strength,
                               banners: panes.banners)
            } else {
                EmptyState(sentence: "No item selected", showsMark: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.content.ignoresSafeArea())
        .modifier(ItemLayers(panes: panes))
        .id(drawn)
        .onReceive(NotificationCenter.default.publisher(for: Zoom.didChange)) { _ in drawn += 1 }
        .onReceive(NotificationCenter.default.publisher(for: Density.didChange)) { _ in drawn += 1 }
    }
}
