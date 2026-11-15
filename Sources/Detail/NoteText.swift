import Foundation

/// An item's notes, read as Markdown and taken apart into the blocks the
/// details draw one under another (`docs/look.md`, "Item details").
///
/// Foundation reads the Markdown. It hands HTML back as the characters that
/// were typed, so a `<script>` in a note is a word on the screen and nothing
/// else, and it gives a picture's caption and never asks for the picture.
/// Only an address that starts `http` or `https` is kept as a link.
struct NoteText: Equatable, Redacted {
    enum Kind: Equatable {
        case paragraph
        /// One is the largest.
        case heading(Int)
        /// How deep the list is nested, from one.
        case bullet(depth: Int)
        case numbered(Int, depth: Int)
        /// A paragraph of a list's row after its first, which stands under
        /// the row's text and has no mark of its own.
        case continued(depth: Int)
        case quote
        case code
    }

    struct Block: Equatable, Identifiable {
        let id: Int
        let kind: Kind
        /// With what Markdown said of each run, bold, italic, struck
        /// through, code or a link, and no colour or size.
        let text: AttributedString
    }

    let blocks: [Block]

    var isEmpty: Bool { blocks.isEmpty }
    var redactedLabel: String { "NoteText(\(blocks.count) blocks)" }

    /// The addresses that are drawn as links, in the order they come.
    var links: [URL] {
        blocks.flatMap { block in block.text.runs.compactMap(\.link) }
    }

    /// Every character drawn, a block to a line.
    var plain: String {
        blocks.map { String($0.text.characters) }.joined(separator: "\n")
    }

    init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let read = try? AttributedString(markdown: markdown, options: options) else {
            // What cannot be read as Markdown is still what he wrote.
            let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks = text.isEmpty ? [] : [Block(id: 0, kind: .paragraph, text: AttributedString(text))]
            return
        }

        var blocks: [Block] = []
        var open: (intent: PresentationIntent?, kind: Kind, text: AttributedString)?
        var marked: Set<Int> = []
        func close() {
            guard var done = open else { return }
            open = nil
            while done.text.characters.last?.isNewline == true {
                done.text.characters.removeLast()
            }
            guard !done.text.characters.isEmpty else { return }
            blocks.append(Block(id: blocks.count, kind: done.kind, text: done.text))
        }

        for run in read.runs {
            var piece = AttributedString(read[run.range])
            if let link = run.link, !Self.mayOpen(link) { piece.link = nil }
            // A line that ends inside a paragraph ends here too: a note is
            // more often lines than prose.
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                piece = AttributedString("\n")
            }
            if open == nil || open?.intent != run.presentationIntent {
                close()
                open = (run.presentationIntent, Self.kind(of: run.presentationIntent, marked: &marked), piece)
            } else {
                open?.text.append(piece)
            }
        }
        close()
        self.blocks = blocks
    }

    /// The one rule for what a click may open, for a note's link and for a
    /// website's row alike.
    static func mayOpen(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased(), link.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The intent lists what a run is inside, innermost first. `marked` is
    /// the list rows that have had their bullet.
    private static func kind(of intent: PresentationIntent?, marked: inout Set<Int>) -> Kind {
        guard let intent else { return .paragraph }
        let depth = intent.components.filter {
            if case .listItem = $0.kind { return true }
            return false
        }.count
        var isQuote = false
        for (place, component) in intent.components.enumerated() {
            switch component.kind {
            case .header(let level) where depth == 0:
                return .heading(level)
            case .codeBlock:
                return .code
            case .blockQuote:
                isQuote = true
            case .listItem(let ordinal):
                guard marked.insert(component.identity).inserted else { return .continued(depth: depth) }
                let list = intent.components.dropFirst(place + 1).first?.kind
                if case .orderedList = list { return .numbered(ordinal, depth: depth) }
                return .bullet(depth: depth)
            default:
                break
            }
        }
        return isQuote ? .quote : .paragraph
    }
}
