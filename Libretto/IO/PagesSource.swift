import Foundation

/// What a Pages document was read from, kept to save edits back into it.
struct PagesSource: Equatable, Sendable {
    enum Original: Sendable {
        /// A document saved as a single file: the ZIP it was.
        case archive(Data)
        /// A package: its files, by their paths within it.
        case files([String: Data])
    }

    var original: Original
    /// Where the body's content came from, if Libretto can write it back:
    /// not for a page layout document, nor for one from Pages '09.
    var body: PagesBody?
    /// Told apart by identity, as what was read never changes.
    private let identity = UUID()

    init(original: Original, body: PagesBody? = nil) {
        self.original = original
        self.body = body
    }

    static func == (lhs: PagesSource, rhs: PagesSource) -> Bool {
        lhs.identity == rhs.identity
    }

    /// The package's files, every one of them, as the readers lay them out.
    func files() throws -> [String: Data] {
        switch original {
        case .archive(let data): try PagesReader.unwrapped(ZipArchive.entries(in: data))
        case .files(let files): try PagesReader.unwrapped(files)
        }
    }
}

/// Where a Pages document's body text, and what is set in it, came from.
struct PagesBody: Sendable {
    /// The body's `TSWP.StorageArchive`.
    var storage: UInt64 = 0
    /// The attachment each picture came from, by its relationship ID.
    var images: [String: UInt64] = [:]
    /// The attachment each table came from, by the table's ID.
    var tables: [UUID: UInt64] = [:]
    /// The footnote attachment each note came from, by the note's ID.
    var notes: [String: UInt64] = [:]
    /// The hyperlink field each link came from, by its relationship ID.
    var links: [String: UInt64] = [:]
    /// The list style each list came from, by its numbering ID.
    var lists: [Int: UInt64] = [:]
    /// The comment each highlight became, by the highlight's identifier.
    var comments: [UInt64: String] = [:]
    /// The paragraphs and tables that carry on the Pages paragraph before
    /// them, as the text after a table set in a paragraph does.
    var continuations: Set<UUID> = []
    /// Paragraphs added for Word's sake, which stand for no text in Pages.
    var additions: Set<UUID> = []
    /// The document as read, to tell what has changed since.
    var original: PagesOriginal?
}

/// A document as it was read, kept whole.
final class PagesOriginal: Sendable {
    let document: WordDocument

    init(_ document: WordDocument) {
        self.document = document
    }
}
