import Foundation

/// What a Pages document was read from, kept to save edits back into it.
public struct PagesSource: Equatable, Sendable {
    public enum Original: Sendable {
        /// A document saved as a single file: the ZIP it was.
        case archive(Data)
        /// A package: its files, by their paths within it.
        case files([String: Data])
    }

    public var original: Original
    /// Where the body's content came from, if Libretto can write it back:
    /// not for a page layout document, nor for one from Pages '09.
    public var body: PagesBody?
    /// Told apart by identity, as what was read never changes.
    private let identity = UUID()

    public init(original: Original, body: PagesBody? = nil) {
        self.original = original
        self.body = body
    }

    public static func == (lhs: PagesSource, rhs: PagesSource) -> Bool {
        lhs.identity == rhs.identity
    }

    /// The package's files, every one of them, as the readers lay them out.
    public func files() throws -> [String: Data] {
        switch original {
        case .archive(let data): try PagesReader.unwrapped(ZipArchive.entries(in: data))
        case .files(let files): try PagesReader.unwrapped(files)
        }
    }
}

/// Where a Pages document's body text, and what is set in it, came from.
public struct PagesBody: Sendable {
    /// The body's `TSWP.StorageArchive`.
    public var storage: UInt64 = 0
    /// The attachment each picture came from, by its relationship ID.
    public var images: [String: UInt64] = [:]
    /// The attachment each table came from, by the table's ID.
    public var tables: [UUID: UInt64] = [:]
    /// The footnote attachment each note came from, by the note's ID.
    public var notes: [String: UInt64] = [:]
    /// The hyperlink field each link came from, by its relationship ID.
    public var links: [String: UInt64] = [:]
    /// The list style each list came from, by its numbering ID.
    public var lists: [Int: UInt64] = [:]
    /// The comment each highlight became, by the highlight's identifier.
    public var comments: [UInt64: String] = [:]
    /// The paragraphs and tables that carry on the Pages paragraph before
    /// them, as the text after a table set in a paragraph does.
    public var continuations: Set<UUID> = []
    /// Paragraphs added for Word's sake, which stand for no text in Pages.
    public var additions: Set<UUID> = []
    /// The document as read, to tell what has changed since.
    public var original: PagesOriginal?

    public init(
        storage: UInt64 = 0,
        images: [String: UInt64] = [:],
        tables: [UUID: UInt64] = [:],
        notes: [String: UInt64] = [:],
        links: [String: UInt64] = [:],
        lists: [Int: UInt64] = [:],
        comments: [UInt64: String] = [:],
        continuations: Set<UUID> = [],
        additions: Set<UUID> = [],
        original: PagesOriginal? = nil
    ) {
        self.storage = storage
        self.images = images
        self.tables = tables
        self.notes = notes
        self.links = links
        self.lists = lists
        self.comments = comments
        self.continuations = continuations
        self.additions = additions
        self.original = original
    }
}

/// A document as it was read, kept whole.
public final class PagesOriginal: Sendable {
    public let document: WordDocument

    public init(_ document: WordDocument) {
        self.document = document
    }
}
