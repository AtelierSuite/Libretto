import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Smart tags, custom XML, simple fields and inline content controls: kept
/// whole to write back, and drawn run by run, each in its own formatting.
@Suite("Kept inline elements")
struct KeptInlineTests {
    static let smartTag = """
        <w:smartTag w:uri="urn:schemas-microsoft-com:office:smarttags" w:element="place">\
        <w:r><w:t xml:space="preserve">New </w:t></w:r>\
        <w:r><w:rPr><w:b/></w:rPr><w:t>York</w:t></w:r>\
        <w:r><w:rPr><w:color w:val="FF0000"/></w:rPr><w:t xml:space="preserve"> City</w:t></w:r>\
        </w:smartTag>
        """
    static let field = """
        <w:fldSimple w:instr=" AUTHOR "><w:r><w:rPr><w:i/></w:rPr><w:t xml:space="preserve">Jane </w:t></w:r>\
        <w:r><w:rPr><w:i/></w:rPr><w:t>Doe</w:t></w:r></w:fldSimple>
        """
    static let body = """
        <w:p><w:r><w:t xml:space="preserve">In </w:t></w:r>\(smartTag)<w:r><w:t xml:space="preserve"> by </w:t></w:r>\(field)</w:p>
        """

    private func document() throws -> WordDocument {
        try DOCXReader.document(fromParts: Fixtures.parts(body: Self.body))
    }

    private func kept(_ document: WordDocument) throws -> (smartTag: Inline, field: Inline) {
        let inlines = try #require(document.allParagraphs.first?.inlines)
        let tokens = inlines.filter { if case .paragraphChild = $0.content { return true } else { return false } }
        try #require(tokens.count == 2)
        return (tokens[0], tokens[1])
    }

    private func render(_ document: WordDocument) -> RenderedText {
        DocumentRenderer.render(document.body, context: RenderContext(document: document, scheme: .light, images: ImageStore()))
    }

    @Test("Each run inside is read with its own formatting; alike runs need none")
    func reading() throws {
        let (smartTag, field) = try kept(try document())
        let runs = try #require(smartTag.displayRuns)
        #expect(runs.map(\.text) == ["New ", "York", " City"])
        #expect(runs.map(\.format.style.isBold) == [nil, true, nil])
        #expect(runs.map(\.format.style.colorHex) == [nil, nil, "FF0000"])
        #expect(smartTag.plainText == "New York City")
        // All in italics: drawn in its format, as before.
        #expect(field.displayRuns == nil)
        #expect(field.format.style.isItalic == true)
        #expect(field.plainText == "Jane Doe")
    }

    @Test("Each run is drawn in its own formatting, and the element reads back whole")
    func drawing() throws {
        let document = try document()
        let rendered = render(document)
        let text = rendered.string
        let string = text.string as NSString

        func font(at word: String) -> UIFont? {
            text.attribute(.font, at: string.range(of: word).location, effectiveRange: nil) as? UIFont
        }
        func color(at word: String) -> UIColor? {
            text.attribute(.foregroundColor, at: string.range(of: word).location, effectiveRange: nil) as? UIColor
        }
        #expect(font(at: "York")?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font(at: "New")?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
        #expect(color(at: "City") != color(at: "York"))
        var red: CGFloat = 0
        color(at: "City")?.getRed(&red, green: nil, blue: nil, alpha: nil)
        #expect(red > 0.9)

        // One element, whichever part of it is looked at.
        let first = text.attribute(.librettoToken, at: string.range(of: "New").location, effectiveRange: nil) as? InlineBox
        let last = text.attribute(.librettoToken, at: string.range(of: "City").location, effectiveRange: nil) as? InlineBox
        #expect(first != nil && first === last)

        let read = AttributedReader.blocks(
            from: text, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        #expect(read.blocks == document.body)
        #expect(!read.needsRender)
    }

    @Test("Edited, what is left is text in the formatting it was drawn in")
    func editing() throws {
        let document = try document()
        let rendered = render(document)
        let text = NSMutableAttributedString(attributedString: rendered.string)
        let location = (text.string as NSString).range(of: "New ").location
        text.deleteCharacters(in: NSRange(location: location, length: 4))

        let read = AttributedReader.blocks(
            from: text, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        guard case .paragraph(let paragraph) = read.blocks.first else {
            Issue.record("no paragraph")
            return
        }
        #expect(paragraph.plainText == "In York City by Jane Doe")
        let york = paragraph.inlines.first { $0.plainText == "York" }
        #expect(york?.format.style.isBold == true)
        let city = paragraph.inlines.first { $0.plainText == " City" }
        #expect(city?.format.style.colorHex == "FF0000")
    }

    @Test("Saved, the elements are written back exactly as they were")
    func saving() throws {
        let document = try document()
        let written = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        // The paragraph and each element, byte for byte as they were read.
        let paragraph = try #require(document.allParagraphs.first)
        #expect(written.contains(try #require(paragraph.originalXML)))
        let (smartTag, field) = try kept(document)
        for token in [smartTag, field] {
            guard case .paragraphChild(let xml, _) = token.content else { continue }
            #expect(written.contains(xml))
        }
        #expect(written.contains("<w:b/></w:rPr><w:t>York</w:t>"))

        // How they are drawn has no part in what is written.
        var plain = document
        plain.body = document.body.map { block in
            guard case .paragraph(var paragraph) = block else { return block }
            for index in paragraph.inlines.indices { paragraph.inlines[index].displayRuns = nil }
            paragraph.originalInlines = paragraph.originalInlines.map { $0.map { var inline = $0; inline.displayRuns = nil; return inline } }
            return .paragraph(paragraph)
        }
        #expect(Fixtures.text(try Fixtures.written(plain), "word/document.xml") == written)

        // Read back and saved again, the paragraph is the same again, and still drawn run by run.
        let reread = try DOCXReader.document(fromParts: Fixtures.written(document))
        let again = Fixtures.text(try Fixtures.written(reread), "word/document.xml")
        #expect(again.contains(try #require(paragraph.originalXML)))
        #expect(try kept(reread).smartTag.displayRuns == smartTag.displayRuns)

        // And again, after a trip through the editor's text.
        let rendered = render(document)
        let read = AttributedReader.blocks(
            from: rendered.string, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        var edited = document
        edited.body = read.blocks
        #expect(Fixtures.text(try Fixtures.written(edited), "word/document.xml") == written)
    }

    @Test("Runs in an inline content control are drawn in their own formatting")
    func contentControl() throws {
        let body = """
            <w:p><w:sdt><w:sdtPr><w:alias w:val="Name"/></w:sdtPr><w:sdtContent>\
            <w:r><w:t xml:space="preserve">Plain </w:t></w:r><w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>underlined</w:t></w:r>\
            </w:sdtContent></w:sdt></w:p>
            """
        let document = try DOCXReader.document(fromParts: Fixtures.parts(body: body))
        let token = try #require(document.allParagraphs.first?.inlines.first)
        #expect(token.displayRuns?.map(\.text) == ["Plain ", "underlined"])
        #expect(token.displayRuns?.last?.format.style.underline == true)
    }
}
