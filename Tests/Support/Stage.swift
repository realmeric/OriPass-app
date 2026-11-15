import AppKit
import Foundation
@testable import OriPass

/// Large Type's panel for a test: it remembers what it was asked to show and
/// puts nothing on the screen.
@MainActor
final class RememberingStage: LargeTypeStage {
    private(set) var showing: LargeType?
    private(set) var shows = 0
    private var closed: (() -> Void)?

    func show(_ value: LargeType, closed: @escaping () -> Void) {
        close()
        showing = value
        shows += 1
        self.closed = closed
    }

    /// As Esc and a click do it: the panel goes and says so.
    func close() {
        guard showing != nil else { return }
        showing = nil
        let closed = self.closed
        self.closed = nil
        closed?()
    }
}

/// The card over the browser for a test: it remembers what it was asked and
/// puts nothing on the screen.
@MainActor
final class RememberingBrowserStage: BrowserStage {
    private(set) var showing: BrowserQuestion?
    private(set) var shows = 0

    func show(_ question: BrowserQuestion) {
        showing = question
        shows += 1
    }

    func close() {
        showing = nil
    }
}

/// Quick Look for a test: it remembers the file it was asked to show and
/// puts nothing on the screen.
@MainActor
final class RememberingPreview: PreviewStage {
    private(set) var showing: URL?
    private(set) var title: String?
    private(set) var shows = 0
    /// What the file held when it was shown.
    private(set) var read: Data?
    private var closed: (() -> Void)?

    func show(_ file: URL, named name: String, closed: @escaping () -> Void) {
        close()
        showing = file
        title = name
        read = try? Data(contentsOf: file)
        shows += 1
        self.closed = closed
    }

    /// As the red button does it: the panel goes and says so.
    func close() {
        guard showing != nil else { return }
        showing = nil
        title = nil
        let closed = self.closed
        self.closed = nil
        closed?()
    }
}

/// The Finder's two questions, answered by the test. One that `waits` is
/// left up, as a panel nobody has answered is, until it is dismissed.
@MainActor
final class AnsweringPanels: FilePanels {
    var saveTo: URL?
    var attach: URL?
    var waits = false
    private(set) var asked: [String] = []
    private(set) var dismissals = 0
    private var up: [CheckedContinuation<Void, Never>] = []

    var isUp: Bool { !up.isEmpty }

    func destination(named name: String) async -> URL? {
        asked.append("save \(name)")
        return await answer(saveTo)
    }

    func fileToAttach() async -> URL? {
        asked.append("attach")
        return await answer(attach)
    }

    func dismiss() {
        dismissals += up.count
        let up = self.up
        self.up = []
        up.forEach { $0.resume() }
    }

    private func answer(_ file: URL?) async -> URL? {
        guard waits else { return file }
        await withCheckedContinuation { up.append($0) }
        return nil
    }
}

/// The panel the master password is asked for in, for a test: it remembers
/// the question and puts nothing on the screen.
@MainActor
final class RememberingQuestion: PasswordStage {
    private(set) var showing: PasswordQuestion?
    private(set) var shows = 0

    func show(_ question: PasswordQuestion) {
        showing = question
        shows += 1
    }

    func close() {
        showing = nil
    }
}

/// The voice for a test: it keeps what it was told to say.
@MainActor
final class RememberingVoice: Voice {
    private(set) var said: [String] = []

    func say(_ words: String, in window: NSWindow?) { said.append(words) }
}
