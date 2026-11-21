import Foundation
import Testing
@testable import Libretto
@testable import LibrettoEngine

@Suite("Headers and footers")
struct HeaderFooterTests {
    @Test("An edited header is written over its part, its page number a field")
    func editsHeader() throws {
        var document = try Fixtures.document()
        let id = try #require(document.pageSetup.headerFooters.headers[.default])
        document.headerFooters[id]?.text = "Draft\tPage {PAGE} of {NUMPAGES}"
        document.headerFooters[id]?.alignment = .center
        document.headerFooters[id]?.isEdited = true

        let parts = try Fixtures.written(document)
        let header = Fixtures.text(parts, "word/header1.xml")
        #expect(header.contains("<w:jc w:val=\"center\"/>"))
        #expect(header.contains("<w:fldSimple w:instr=\" PAGE \">"))
        #expect(header.contains("<w:fldSimple w:instr=\" NUMPAGES \">"))
        #expect(header.contains("<w:tab/>"))
        #expect(!header.contains(">7<"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.header?.resolved(page: 2, of: 5) == "Draft\tPage 2 of 5")
        #expect(reread.header?.alignment == .center)
    }

    @Test("Page numbers keep the section's format, read and written as w:pgNumType")
    func pageNumberFormat() throws {
        var document = try Fixtures.document()
        document.pageSetup.pageNumberFormat = "upperRoman"
        let parts = try Fixtures.written(document)
        #expect(Fixtures.text(parts, "word/document.xml").contains("<w:pgNumType w:fmt=\"upperRoman\"/>"))

        var reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.pageSetup.pageNumberFormat == "upperRoman")
        let texts = WordDocumentHeaderFooter(document: reread)
        #expect(texts.section(forPage: 3).pageNumberFormat == "upperRoman")
        #expect(texts.header(forPage: 3)?.resolved(page: 4, of: 9, format: "upperRoman") == "Page IV")

        reread.pageSetup.pageNumberFormat = nil
        #expect(!Fixtures.text(try Fixtures.written(reread), "word/document.xml").contains("pgNumType"))
    }

    @Test("A section that starts its page numbers over is numbered from its start")
    func pageNumberRestart() throws {
        let body = Fixtures.body.replacingOccurrences(
            of: "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/></w:sectPr>",
            with: "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgNumType w:fmt=\"lowerRoman\"/></w:sectPr>"
        )
        var parts = Fixtures.parts(body: body)
        let main = Fixtures.text(parts, "word/document.xml")
            .replacingOccurrences(of: "<w:cols w:space=\"720\"/>", with: "<w:pgNumType w:start=\"1\"/><w:cols w:space=\"720\"/>")
        parts["word/document.xml"] = Data(main.utf8)
        let document = try DOCXReader.document(fromParts: parts)
        #expect(document.pageSetup.pageNumberStart == 1)
        let front = try #require(document.body.compactMap { block -> PageSetup? in
            if case .paragraph(let paragraph) = block { return paragraph.section } else { return nil }
        }.first)
        #expect(front.pageNumberStart == nil)

        // Three pages of front matter, then the body starting over at 1.
        let texts = WordDocumentHeaderFooter(document: document, sections: [front, document.pageSetup], pageSections: [0, 0, 0, 1, 1])
        #expect((0..<5).map(texts.pageNumber(forPage:)) == [1, 2, 3, 1, 2])
        #expect(texts.pageNumbers(count: 5) == [1, 2, 3, 1, 2])
        #expect(texts.header(forPage: 3).map {
            HeaderFooterDrawing.attributed($0, number: texts.pageNumber(forPage: 3), of: 5, color: .black).string
        } == "Page 1")
        #expect(texts.section(forPage: 2).pageNumberFormat == "lowerRoman")
        #expect(document.header.map {
            HeaderFooterDrawing.attributed($0, number: texts.pageNumber(forPage: 2), of: 5, format: "lowerRoman", color: .black).string
        } == "Page iii")

        let rewritten = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(rewritten.contains("w:start=\"1\""))
    }

    @Test("A first section with a start of its own numbers its first page from it")
    func firstSectionStart() {
        var setup = PageSetup()
        setup.pageNumberStart = 5
        let texts = WordDocumentHeaderFooter(document: WordDocument(), sections: [setup], pageSections: [0, 0])
        #expect(texts.pageNumber(forPage: 0) == 5)
        #expect(texts.pageNumber(forPage: 1) == 6)
    }

    @Test("A first-page footer gets a part, a relationship and a reference of its own")
    func addsFirstPageFooter() throws {
        var document = try Fixtures.document()
        let id = document.unusedHeaderFooterID(isFooter: true)
        document.headerFooters[id] = HeaderFooterText(text: "Confidential", isFooter: true, isEdited: true)
        document.pageSetup.headerFooters.footers[.first] = id
        document.pageSetup.headerFooters.titlePage = true

        let parts = try Fixtures.written(document)
        #expect(Fixtures.text(parts, "word/footer1.xml").contains("<w:ftr"))
        #expect(Fixtures.text(parts, "word/_rels/document.xml.rels").contains("Target=\"footer1.xml\""))
        #expect(Fixtures.text(parts, "[Content_Types].xml").contains("/word/footer1.xml"))
        let xml = Fixtures.text(parts, "word/document.xml")
        #expect(xml.contains("<w:footerReference r:id=\"\(id)\" w:type=\"first\"/>"))
        #expect(xml.contains("<w:titlePg/>"))
        // The header the section had is still referred to.
        #expect(xml.contains("<w:headerReference r:id=\"rIdHeader\" w:type=\"default\"/>"))

        let reread = try DOCXReader.document(fromParts: parts)
        let texts = WordDocumentHeaderFooter(document: reread)
        #expect(texts.footer(forPage: 0)?.text == "Confidential")
        #expect(texts.footer(forPage: 1) == nil)
        // The first page has its own header, which it has not been given.
        #expect(texts.header(forPage: 0) == nil)
        #expect(texts.header(forPage: 1)?.resolved(page: 2, of: 2) == "Page 2")
    }

    @Test("Odd and even headers are a setting of the whole document")
    func evenAndOdd() throws {
        var document = try Fixtures.document()
        document.evenAndOddHeaders = true
        let parts = try Fixtures.written(document)
        #expect(Fixtures.text(parts, "word/settings.xml").contains("<w:evenAndOddHeaders/>"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.evenAndOddHeaders)
        // Even pages have no header of their own yet.
        #expect(WordDocumentHeaderFooter(document: reread).header(forPage: 1) == nil)
        #expect(WordDocumentHeaderFooter(document: reread).header(forPage: 2) != nil)
    }
}
