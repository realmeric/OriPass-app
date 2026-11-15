import AppKit

/// What opening, saving and adding an attachment need of the Mac: the
/// directory a copy is written to, the panel that shows it, and the Finder's
/// two questions. One for the app, as the pasteboard is, and the door's: it
/// is ended at the lock after the panes have gone. Without one, which is
/// every shot and most tests, a row is drawn and opens nothing.
@MainActor
final class AttachmentDesk {
    let copies: OpenCopies
    let stage: PreviewStage
    /// Nil where nobody is there to answer: the tour.
    let panels: FilePanels?

    init(copies: OpenCopies, stage: PreviewStage, panels: FilePanels? = nil) {
        self.copies = copies
        self.stage = stage
        self.panels = panels
    }

    /// The preview down, the Finder's question with it, and every copy
    /// gone (D6).
    func end() {
        stage.close()
        panels?.dismiss()
        copies.removeAll()
    }
}

/// A file on its way into the item, or one the engine would not take: the
/// row under the attachments that says which.
struct Adding: Equatable {
    let name: String
    /// The engine's sentence, when it refused.
    var sentence: String?

    static let underWay = "Adding…"
}

extension ItemDetail {
    /// One attachment as its row draws it.
    struct File: Identifiable, Equatable {
        /// The row's name among the item's rows.
        let id: String
        let attachment: Attachment
        let name: String
        /// Nil when the item does not say.
        let size: String?

        init(place: Int, attachment: Attachment) {
            id = "attachment-\(place)"
            self.attachment = attachment
            name = attachment.fileName.isEmpty ? "attachment" : attachment.fileName
            if let bytes = attachment.size {
                size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            } else {
                size = attachment.sizeName.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
    }

    func file(at row: String) -> File? {
        attachments.first { $0.id == row }
    }
}

extension Panes {
    static let fetching = "Fetching…"

    // MARK: Quick Look

    /// A click on an attachment's row: the engine decrypts it into a folder
    /// of its own and Quick Look opens on the copy, which is deleted when
    /// the preview closes. One at a time, so the one before it is put away
    /// first. A refusal is the row's second line, in the engine's sentence.
    @discardableResult
    func openAttachment(_ row: String) -> Task<Void, Never>? {
        guard let desk, let detail, let file = detail.file(at: row) else { return nil }
        reading.menu = nil
        // A file is no less the item's than a field is.
        guard !isHeldBack else {
            guarded(.reveal) { $0.openAttachment(row) }
            return nil
        }
        fetch?.cancel()
        desk.stage.close()
        reading.unfetched[row] = nil
        let copies = desk.copies
        guard let copy = try? copies.place(for: file.name) else {
            reading.unfetched[row] = Self.unwritten
            return nil
        }
        reading.fetching = [row]
        let id = detail.id
        let task = Task { [weak self, store] in
            do {
                try await store.fetch(file.attachment, of: id, to: copy)
            } catch {
                copies.remove(copy)
                guard let self, !Task.isCancelled else { return }
                self.reading.fetching.remove(row)
                self.reading.unfetched[row] = Self.sentence(for: error, or: Self.unwritten)
                return
            }
            // Another item, another attachment or the lock came first.
            guard let self, !Task.isCancelled, self.detail?.id == id else {
                copies.remove(copy)
                return
            }
            self.reading.fetching.remove(row)
            desk.stage.show(copy, named: file.name) { copies.remove(copy) }
        }
        fetch = task
        return task
    }

    // MARK: Save As

    /// The engine writes the file where he says and nowhere else. That copy
    /// is his: nothing here deletes it.
    @discardableResult
    func saveAttachment(_ row: String) -> Task<Void, Never>? {
        guard let panels = desk?.panels, let detail, let file = detail.file(at: row) else { return nil }
        reading.menu = nil
        guard !isHeldBack else {
            guarded(.copy) { $0.saveAttachment(row) }
            return nil
        }
        reading.unfetched[row] = nil
        let id = detail.id
        return working { [weak self, store] in
            guard let destination = await panels.destination(named: file.name),
                  let self, !Task.isCancelled else { return }
            let isShown = { [weak self] in self?.detail?.id == id }
            if isShown() { self.reading.fetching.insert(row) }
            do {
                try await store.fetch(file.attachment, of: id, to: destination)
                if isShown() { self.reading.fetching.remove(row) }
            } catch {
                guard !Task.isCancelled, isShown() else { return }
                self.reading.fetching.remove(row)
                self.reading.unfetched[row] = Self.sentence(for: error, or: Self.unwritten)
            }
        }
    }

    // MARK: Adding

    /// Attach a File in the item's menu: the file he chooses goes to the
    /// engine, and the item comes back with one attachment more. A refusal
    /// is a row of its own, the file's name over the engine's sentence.
    @discardableResult
    func attachFile() -> Task<Void, Never>? {
        guard let panels = desk?.panels, let id = selectedItem?.id, itemActs.joined().contains(.attach) else {
            return nil
        }
        detailMenu = nil
        return working { [weak self, store] in
            guard let file = await panels.fileToAttach(), let self, !Task.isCancelled else { return }
            let isShown = { [weak self] in self?.selectedItem?.id == id }
            let name = file.lastPathComponent
            if isShown() { self.reading.adding = Adding(name: name) }
            do {
                try await store.apply(.attach(file), to: id)
                if isShown() { self.reading.adding = nil }
            } catch {
                guard !Task.isCancelled, isShown() else { return }
                self.reading.adding = Adding(name: name, sentence: Self.sentence(for: error, or: Self.unread))
            }
        }
    }

    /// Among the changes the lock stops (`end`), and not among what another
    /// item puts away: a file he asked to be saved or added is saved or
    /// added though he has looked elsewhere meanwhile.
    private func working(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        writesBegun += 1
        let number = writesBegun
        let task = Task { [weak self] in
            await work()
            self?.writes[number] = nil
        }
        writes[number] = task
        writing = task
        return task
    }

    /// What `putAway` does for the attachments: the fetch for a preview
    /// stopped, the preview down and its copy with it, and every row back
    /// to its name and its size.
    func putAwayAttachments() {
        fetch?.cancel()
        fetch = nil
        if !reading.fetching.isEmpty { reading.fetching = [] }
        if !reading.unfetched.isEmpty { reading.unfetched = [:] }
        if reading.adding != nil { reading.adding = nil }
        desk?.stage.close()
    }

    static let unwritten = "The file could not be written."
    static let unread = "The file could not be read."

    /// The engine's sentence, or `words` for a failure that was the disk's
    /// and not the engine's. Nil for a vault that locked meanwhile.
    static func sentence(for error: Error, or words: String) -> String? {
        error is VaultError ? sentence(for: error) : words
    }
}
