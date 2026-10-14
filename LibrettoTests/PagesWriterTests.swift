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

/// Saves edits back into Pages documents, and reads them again.
@Suite("Pages saving")
struct PagesSavingTests {
    /// Word processing documents, and last, a page layout one.
    static let fixtures = ["Sample.pages", "Fields.pages", "Formats.pages", "TwoPages.pages"]

    /// Where documents are written for checking in Pages itself, when the folder exists.
    static let checks = URL(fileURLWithPath: "/tmp/pagescheck/written")

    static func saved(_ document: WordDocument, as name: String? = nil) throws -> WordDocument {
        let data = try PagesWriter.data(for: document)
        if let name, FileManager.default.fileExists(atPath: checks.path) {
            try data.write(to: checks.appending(path: name))
        }
        return try PagesReader.document(from: data)
    }

    static func paragraphs(_ document: WordDocument) -> [Paragraph] {
        document.body.compactMap { if case .paragraph(let paragraph) = $0 { paragraph } else { nil } }
    }

    /// The document with the first paragraph that starts with a prefix changed.
    static func editing(
        _ document: WordDocument, startingWith prefix: String, _ edit: (inout Paragraph) -> Void
    ) -> WordDocument {
        var document = document
        let index = document.body.firstIndex {
            if case .paragraph(let paragraph) = $0 { paragraph.plainText.hasPrefix(prefix) } else { false }
        }!
        guard case .paragraph(var paragraph) = document.body[index] else { return document }
        edit(&paragraph)
        document.body[index] = .paragraph(paragraph)
        return document
    }

    @Test("A document saved unedited is the file it was", arguments: fixtures)
    func unedited(name: String) throws {
        let document = try PagesReader.document(from: PagesWriterTests.data(name))
        let files = try document.pagesSource!.files()
        #expect(try PagesWriter.files(for: document) == files)
        _ = try Self.saved(document, as: "Unedited-" + name)
    }

    @Test("Every document takes text typed at its start and a paragraph taken from its end", arguments: fixtures.dropLast())
    func edits(name: String) throws {
        var document = try PagesReader.document(from: PagesWriterTests.data(name))
        let before = Self.paragraphs(document).map(\.plainText)
        let first = document.body.firstIndex { if case .paragraph = $0 { true } else { false } }!
        guard case .paragraph(var paragraph) = document.body[first] else { return }
        paragraph.inlines.insert(Inline(.text("Edited. "), format: paragraph.inlines.first?.format ?? RunFormat()), at: 0)
        document.body[first] = .paragraph(paragraph)
        let last = document.body.lastIndex { if case .paragraph(let p) = $0 { !p.plainText.isEmpty } else { false } }!
        let removed = Self.paragraphs(document).filter { !$0.plainText.isEmpty }.last!.plainText
        document.body.remove(at: last)
        let saved = try Self.saved(document, as: "Edited-" + name)
        var expected = before
        expected[0] = "Edited. " + expected[0]
        expected.remove(at: expected.lastIndex(of: removed)!)
        #expect(Self.paragraphs(saved).map(\.plainText).filter { !$0.isEmpty } == expected.filter { !$0.isEmpty })
    }

    @Test("Text typed into a paragraph is saved, and the rest keeps its formatting")
    func typing() throws {
        let document = try PagesReader.document(from: PagesWriterTests.data("Sample.pages"))
        let edited = Self.editing(document, startingWith: "This is a bold word") { paragraph in
            guard case .text(let text) = paragraph.inlines[0].content else { return }
            paragraph.inlines[0].content = .text("Typed. " + text)
        }
        let saved = try Self.saved(edited, as: "Typing.pages")
        let before = Self.paragraphs(document)
        let after = Self.paragraphs(saved)
        #expect(after.map(\.plainText) == before.map(\.plainText).map {
            $0.hasPrefix("This is a bold word") ? "Typed. " + $0 : $0
        })
        for (old, new) in zip(before, after) {
            #expect(old.properties == new.properties, "\(old.plainText)")
            #expect(old.inlines.map(\.format) == new.inlines.map(\.format) || old.plainText.hasPrefix("This"), "\(old.plainText)")
        }
        // The bold word is still bold, after the typing.
        let bold = after[1].inlines.first { if case .text(let text) = $0.content { text == "bold" } else { false } }
        #expect(bold?.format.style.isBold == true)
        // The picture, table and footnote are still there.
        #expect(saved.body.contains { if case .table = $0 { true } else { false } })
        #expect(after.contains { $0.inlines.contains { if case .image = $0.content { true } else { false } } })
        #expect(saved.notes.map(\.text) == document.notes.map(\.text))
    }

    @Test("Formatting made in Libretto is saved as a style Pages has, or one made for it")
    func formatting() throws {
        let document = try PagesReader.document(from: PagesWriterTests.data("Sample.pages"))
        var edited = Self.editing(document, startingWith: "Final paragraph") { paragraph in
            guard case .text(let text) = paragraph.inlines[0].content else { return }
            var bold = paragraph.inlines[0]
            bold.content = .text("Final")
            bold.format.style.isBold = true
            var red = paragraph.inlines[0]
            red.content = .text(String(text.dropFirst(5)))
            red.format.style.colorHex = "FF0000"
            red.format.style.isItalic = true
            paragraph.inlines = [bold, red]
            paragraph.properties.alignment = .center
        }
        edited = Self.editing(edited, startingWith: "Second page paragraph") { paragraph in
            paragraph.properties.styleID = ParagraphStyleChoice.heading1.defaultID
            paragraph.properties.outlineLevel = 0
        }
        let saved = try Self.saved(edited, as: "Formatting.pages")
        let final = Self.paragraphs(saved).first { $0.plainText.hasPrefix("Final") }!
        #expect(final.plainText == "Final paragraph.")
        #expect(final.properties.alignment == .center)
        #expect(final.inlines.first?.format.style.isBold == true)
        #expect(final.inlines.last?.format.style.colorHex == "FF0000")
        #expect(final.inlines.last?.format.style.isItalic == true)
        #expect(final.inlines.last?.format.style.isBold == nil)
        let heading = Self.paragraphs(saved).first { $0.plainText.hasPrefix("Second page") }!
        #expect(heading.properties.styleID == ParagraphStyleChoice.heading1.defaultID)
        // What was not changed is as it was.
        let quarterly = Self.paragraphs(saved).first { $0.plainText.hasPrefix("Quarterly") }!
        #expect(quarterly.properties == Self.paragraphs(document).first!.properties)
        // Saving again makes no more styles.
        let again = try PagesWriter.files(for: saved)
        #expect(again == (try saved.pagesSource!.files()))
    }

    @Test("Paragraphs added, split and taken away are saved, with their lists")
    func paragraphs() throws {
        let document = try PagesReader.document(from: PagesWriterTests.data("Sample.pages"))
        var edited = document
        // A new bullet after the second, as pressing Return at its end makes.
        let second = edited.body.firstIndex { if case .paragraph(let p) = $0 { p.plainText == "Second bullet" } else { false } }!
        guard case .paragraph(let bullet) = edited.body[second] else { return }
        var added = bullet.splitCopy()
        added.inlines = [Inline(.text("Third bullet"), format: bullet.inlines[0].format)]
        edited.body.insert(.paragraph(added), at: second + 1)
        // The right-aligned paragraph taken away.
        edited.body.removeAll { if case .paragraph(let p) = $0 { p.plainText.hasPrefix("Right aligned") } else { false } }
        let saved = try Self.saved(edited, as: "Paragraphs.pages")
        let texts = Self.paragraphs(saved).map(\.plainText)
        #expect(texts.contains("Third bullet"))
        #expect(!texts.contains { $0.hasPrefix("Right aligned") })
        let third = Self.paragraphs(saved).first { $0.plainText == "Third bullet" }!
        let original = Self.paragraphs(saved).first { $0.plainText == "Second bullet" }!
        #expect(third.properties.list?.numberingID == original.properties.list?.numberingID)
        #expect(third.properties.list?.level == 0)
        #expect(Self.paragraphs(saved).first { $0.plainText == "Nested bullet" }?.properties.list?.level == 1)
    }

    @Test("A link stays a link, and one taken away is gone")
    func links() throws {
        let document = try PagesReader.document(from: PagesWriterTests.data("Fields.pages"))
        let linked = Self.paragraphs(document).first { $0.inlines.contains { $0.hyperlink != nil } }!
        let kept = try Self.saved(Self.editing(document, startingWith: linked.plainText) { paragraph in
            paragraph.inlines.insert(Inline(.text("Before. ")), at: 0)
        })
        let keptParagraph = Self.paragraphs(kept).first { $0.plainText.hasPrefix("Before. ") }!
        #expect(keptParagraph.inlines.filter { $0.hyperlink != nil }.map(\.plainText)
            == linked.inlines.filter { $0.hyperlink != nil }.map(\.plainText))
        let unlinked = try Self.saved(Self.editing(document, startingWith: linked.plainText) { paragraph in
            for index in paragraph.inlines.indices { paragraph.inlines[index].hyperlink = nil }
        })
        #expect(!Self.paragraphs(unlinked).contains { $0.inlines.contains { $0.hyperlink != nil } })
    }

    @Test("The page's size and margins are saved")
    func pageSetup() throws {
        var document = try PagesReader.document(from: PagesWriterTests.data("Sample.pages"))
        document.pageSetup.marginLeft = 2000
        document.pageSetup.marginTop = 1800
        let saved = try Self.saved(document)
        #expect(saved.pageSetup.marginLeft == 2000)
        #expect(saved.pageSetup.marginTop == 1800)
    }

    @Test("A page layout document is saved as it was read")
    func pageLayout() throws {
        var document = try PagesReader.document(from: PagesWriterTests.data("Layout.pages"))
        document.body.append(.paragraph(Paragraph(text: "Not saved")))
        #expect(try PagesWriter.files(for: document) == document.pagesSource!.files())
    }

    @Test("Text aligns with the text it was edited from")
    func alignment() {
        let old = Array("one\ntwo\nthree".utf16).map(Int.init)
        let new = Array("one\nTWO two\nthree!".utf16).map(Int.init)
        let matches = PagesTextAlignment.matches(old: old, new: new, isBreak: { $0 == 0x0A })
        #expect(matches.compactMap { $0 }.map { old[$0] } == old)
        #expect(matches.count == new.count)
        let kept = matches.compactMap { $0 }
        #expect(kept == kept.sorted())
    }
}
