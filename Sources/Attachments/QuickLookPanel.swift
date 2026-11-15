import AppKit
import Quartz

/// Where an attachment's copy is shown. The panes ask for it and are told
/// when it has gone, which is when the copy is deleted; a test hands them
/// something that only remembers.
@MainActor
protocol PreviewStage: AnyObject {
    func show(_ file: URL, named name: String, closed: @escaping () -> Void)
    func close()
}

/// Quick Look on one file, in a panel of this app's own with Quick Look's
/// view in it. Not the system's shared panel: that one belongs to whoever
/// is in the responder chain when it comes up and says nothing reliable
/// about when it went, and the moment it goes is the moment the copy has to
/// be deleted. The red button, Esc, Space, and whoever asked for it each
/// put it away: another item, the lock (D6).
@MainActor
final class QuickLookPanel: NSObject, PreviewStage, NSWindowDelegate {
    private var panel: Panel?
    private var closed: (() -> Void)?
    /// False for the tour, whose windows stay behind whatever is on screen.
    var takesKeys = true

    var isUp: Bool { panel?.isVisible == true }
    /// The file being shown, for the tour to read.
    private(set) var showing: URL?

    /// Whether Quick Look's own view was handed `file`, which is as far
    /// as this process can see into what it draws.
    func isPreviewing(_ file: URL) -> Bool {
        (panel?.contentView as? QLPreviewView)?.previewItem?.previewItemURL == file
    }

    func show(_ file: URL, named name: String, closed: @escaping () -> Void) {
        close()
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(origin: .zero, size: Metrics.windowSize)
        let panel = Self.make(file, named: name, within: screen)
        panel.dismiss = { [weak self] in self?.close() }
        panel.delegate = self
        self.panel = panel
        self.closed = closed
        showing = file
        if takesKeys { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
    }

    func close() {
        guard let panel else { return }
        // Before it is ordered out: the window closing comes back here.
        self.panel = nil
        showing = nil
        let closed = self.closed
        self.closed = nil
        panel.dismiss = nil
        panel.delegate = nil
        // Quick Look lets go of the file before the file goes.
        (panel.contentView as? QLPreviewView)?.close()
        panel.orderOut(nil)
        panel.contentView = nil
        closed?()
    }

    /// The red button.
    func windowWillClose(_ notification: Notification) {
        close()
    }

    /// The panel, titled as the file is and centred in `frame`, and not
    /// shown.
    static func make(_ file: URL, named name: String, within frame: NSRect) -> Panel {
        let size = CGSize(width: min(Metrics.previewSize.width, frame.width),
                          height: min(Metrics.previewSize.height, frame.height))
        let origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = Panel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = name
        panel.isReleasedWhenClosed = false
        // What it shows is decrypted, and is in no saved state (D6).
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.minSize = Metrics.previewMinimum
        if let view = QLPreviewView(frame: NSRect(origin: .zero, size: size), style: .normal) {
            // Closed by `close`, before the file is deleted, and not
            // whenever the window gets round to it.
            view.shouldCloseWithWindow = false
            view.autostarts = false
            view.previewItem = file as NSURL
            panel.contentView = view
        }
        return panel
    }

    final class Panel: NSPanel {
        var dismiss: (() -> Void)?

        override var canBecomeKey: Bool { true }

        /// Space puts a preview away as it does in the Finder.
        override func keyDown(with event: NSEvent) {
            if event.keyCode == Self.space || event.keyCode == Self.escape {
                dismiss?()
            } else {
                super.keyDown(with: event)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            dismiss?()
        }

        private static let space: UInt16 = 49
        private static let escape: UInt16 = 53
    }
}

/// The two questions an attachment asks of the Finder: where to save one,
/// and which file to add. A test answers them itself.
@MainActor
protocol FilePanels: AnyObject {
    /// Save As. Nil when he thought better of it.
    func destination(named name: String) async -> URL?
    func fileToAttach() async -> URL?
    /// Whichever of the two is up is taken down, and answers as if he had
    /// thought better of it. A Save As has a file's name from the vault in
    /// it, and is not left on the screen over a vault that has shut (D6).
    func dismiss()
}

@MainActor
final class SystemFilePanels: FilePanels {
    private var asking: Set<NSSavePanel> = []

    func destination(named name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = OpenCopies.safe(name)
        panel.canCreateDirectories = true
        return await answer(of: panel)
    }

    func fileToAttach() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        return await answer(of: panel)
    }

    func dismiss() {
        for panel in asking { panel.cancel(nil) }
    }

    private func answer(of panel: NSSavePanel) async -> URL? {
        asking.insert(panel)
        let response = await panel.begin()
        asking.remove(panel)
        return response == .OK ? panel.url : nil
    }
}
