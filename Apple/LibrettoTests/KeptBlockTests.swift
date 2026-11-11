import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Block-level content controls and tables Libretto cannot edit: written back
/// exactly as read, and drawn as what they hold looks.
@Suite("Kept blocks")
struct KeptBlockTests {
    static let contentControl = """
        <w:sdt><w:sdtPr><w:alias w:val="Cover"/><w:id w:val="12"/></w:sdtPr><w:sdtContent>\
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Quarterly Review</w:t></w:r></w:p>\
        <w:p><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="FF0000"/></w:pPr>\
        <w:r><w:rPr><w:b/></w:rPr><w:t>Shaded</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Plain words</w:t></w:r></w:p>\
        </w:sdtContent></w:sdt>
        """
    /// A table whose second row is inside a content control, so the table model cannot hold it.
    static let keptTable = """
        <w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/></w:tblPr>\
        <w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>\
        <w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="0000FF"/></w:tcPr>\
        <w:p><w:r><w:t>Region</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Total</w:t></w:r></w:p></w:tc></w:tr>\
        <w:sdt><w:sdtPr><w:id w:val="13"/></w:sdtPr><w:sdtContent>\
        <w:tr><w:tc><w:p><w:r><w:t>North</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>1,200</w:t></w:r></w:p></w:tc></w:tr>\
        </w:sdtContent></w:sdt></w:tbl>
        """
    static let body = "<w:p><w:r><w:t>Before</w:t></w:r></w:p>\(contentControl)\(keptTable)<w:p><w:r><w:t>After</w:t></w:r></w:p>"

    private func document() throws -> WordDocument {
        try DOCXReader.document(fromParts: Fixtures.parts(body: Self.body))
    }

    private func kept(_ document: WordDocument) -> [PreservedBlock] {
        document.body.compactMap { if case .preserved(let block) = $0 { return block } else { return nil } }
    }

    private func context(_ document: WordDocument) -> RenderContext {
        RenderContext(document: document, scheme: .light, images: ImageStore())
    }

    @Test("A content control's paragraphs are read, with their styles and formatting, to be drawn")
    func contentControlContent() throws {
        let blocks = kept(try document())
        try #require(blocks.count == 2)
        #expect(blocks[0].kind == .contentControl)
        let paragraphs = blocks[0].content.flatMap(\.paragraphs)
        #expect(paragraphs.map(\.plainText) == ["Quarterly Review", "Shaded", "Plain words"])
        #expect(paragraphs[0].properties.styleID == "Heading1")
        #expect(paragraphs[1].inlines.first?.format.style.isBold == true)
        #expect(blocks[0].displayText == "Quarterly Review\nShaded\nPlain words")
    }

    @Test("A table with rows inside a content control is read whole, every row, to be drawn")
    func keptTableContent() throws {
        let blocks = kept(try document())
        try #require(blocks.count == 2)
        guard case .table(let table) = blocks[1].content.first else {
            Issue.record("No table read")
            return
        }
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [["Region", "Total"], ["North", "1,200"]])
        #expect(table.rows[0].cells[0].shadingHex == "0000FF")
    }

    @Test("Kept blocks are written back exactly as read, after being drawn and read back from the text")
    func writtenBackUntouched() throws {
        let document = try document()
        let rendered = DocumentRenderer.render(document.body, context: context(document))
        let read = AttributedReader.blocks(
            from: rendered.string, finalParagraph: rendered.finalParagraph, trailingMarkers: rendered.trailingMarkers
        )
        var edited = document
        edited.body = read.blocks
        let xml = Fixtures.text(try Fixtures.written(edited), "word/document.xml")
        let original = kept(document).map(\.xml)
        try #require(original.count == 2)
        #expect(xml.contains(original[0]))
        #expect(xml.contains(original[1]))
    }

    @Test("A content control is drawn a line at a time, as its paragraphs look, not as a grey box of text")
    func contentControlDrawn() throws {
        let document = try document()
        let context = context(document)
        let block = kept(document)[0]
        let images = PreservedRenderer.images(block, context: context)
        // One picture per line, at the text's width.
        #expect(images.count == 3)
        #expect(images.allSatisfy { abs($0.size.width - context.contentWidth) < 1 })
        // The heading is drawn larger than plain text.
        #expect(images[0].size.height > images[2].size.height)
        // The shaded paragraph is red behind its text; nothing else is grey.
        let shaded = try #require(Self.color(of: images[1], at: CGPoint(x: images[1].size.width - 4, y: images[1].size.height / 2)))
        #expect(shaded.red > 0.9 && shaded.green < 0.1 && shaded.blue < 0.1)
        let plain = try #require(Self.color(of: images[2], at: CGPoint(x: images[2].size.width - 4, y: images[2].size.height / 2)))
        #expect(plain.alpha < 0.01)
    }

    @Test("A kept table is drawn row by row, with its cells' shading")
    func keptTableDrawn() throws {
        let document = try document()
        let images = PreservedRenderer.images(kept(document)[1], context: context(document))
        #expect(images.count == 2)
        let cell = try #require(Self.color(of: images[0], at: CGPoint(x: 180, y: images[0].size.height / 2)))
        #expect(cell.blue > 0.9 && cell.red < 0.1)
    }

    @Test("A kept block has no spacing of its own after it: its pictures hold its paragraphs' spacing")
    func noBlockSpacing() throws {
        let document = try document()
        let block = Block.preserved(kept(document)[0])
        let text = DocumentRenderer.renderBlock(block, context: context(document))
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.paragraphSpacing == 0)
    }

    @Test("A kept block in a table cell reads as its paragraphs do")
    func keptBlockInCell() throws {
        let cell = TableCell(blocks: [
            .preserved(PreservedBlock(xml: "", displayText: "", kind: .contentControl, content: [
                .paragraph(Paragraph(inlines: [Inline(.text("Inside"), format: Self.bold)])),
            ])),
            .paragraph(Paragraph(inlines: [Inline(.text("After"))])),
        ])
        let document = try document()
        let text = TableRenderer.cellText(cell, context: context(document))
        #expect(text.string == "Inside\nAfter")
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test("What a kept block holds does not make it a different block")
    func equality() {
        let id = UUID()
        let bare = PreservedBlock(id: id, xml: "<w:sdt/>", displayText: "x", kind: .contentControl)
        var read = bare
        read.content = [.paragraph(Paragraph())]
        #expect(bare == read)
    }

    static var bold: RunFormat {
        var style = RunStyle()
        style.isBold = true
        return RunFormat(style: style)
    }

    /// The colour of one point of a picture.
    static func color(of image: UIImage, at point: CGPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cgImage = image.cgImage,
              let bitmap = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let scale = image.scale
        bitmap.draw(cgImage, in: CGRect(
            x: -point.x * scale, y: -(image.size.height - point.y) * scale,
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return (CGFloat(pixel[0]) / 255 / alpha, CGFloat(pixel[1]) / 255 / alpha, CGFloat(pixel[2]) / 255 / alpha, alpha)
    }
}
