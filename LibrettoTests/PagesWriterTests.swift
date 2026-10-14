import Foundation
import Testing
@testable import Libretto

/// Saves edits to Pages documents back into them.
@Suite("Pages writing")
struct PagesWriterTests {
    static func data(_ name: String) -> Data {
        try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/\(name)"))
    }

    @Test("Reading a Pages document keeps it, with where the body's pictures, tables, notes and lists came from")
    func source() throws {
        let data = Self.data("Sample.pages")
        let document = try PagesReader.document(from: data)
        let source = try #require(document.pagesSource)
        let body = try #require(source.body)
        #expect(body.storage == 1_732_641)
        #expect(body.images.count == 1)
        #expect(body.tables.count == 1)
        #expect(body.notes.count == 1)
        #expect(!body.lists.isEmpty)
        #expect(body.original?.document.body == document.body)
        // Every file is kept, those the reader leaves unread among them.
        #expect(try source.files().keys.sorted() == PagesReader.unwrapped(ZipArchive.entries(in: data)).keys.sorted())
        // Whatever it holds, a source is the one it is.
        #expect(document.pagesSource == source)
        #expect(try PagesReader.document(from: data).pagesSource != source)
    }

    @Test("A page layout document, and one from Pages '09, keep their file but not where their text came from")
    func unwritable() throws {
        for name in ["Layout.pages", "Formats09.pages"] {
            let document = try PagesReader.document(from: Self.data(name))
            #expect(document.pagesSource != nil, "\(name)")
            #expect(document.pagesSource?.body == nil, "\(name)")
        }
    }
}
