import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Shapes as Word places and draws them: on the page, in groups, with text
/// running between linked boxes, and with their fills, lines and effects.
@MainActor
@Suite("Shapes")
struct ShapeTests {
    static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    static let wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"

    /// A package whose body is `body`, with the drawing prefixes it uses declared.
    static func parts(body: String) -> [String: Data] {
        var parts = Fixtures.parts(body: body)
        var document = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        let declarations = [
            "xmlns:wp=\"\(OOXML.drawingNamespace)\"", "xmlns:a=\"\(OOXML.drawingMainNamespace)\"",
            "xmlns:wps=\"\(wps)\"", "xmlns:wpg=\"\(wpg)\"",
        ].joined(separator: " ")
        document = document.replacingOccurrences(of: "<w:document ", with: "<w:document \(declarations) ")
        parts["word/document.xml"] = Data(document.utf8)
        return parts
    }

    static func document(body: String) throws -> WordDocument {
        try DOCXReader.document(fromParts: parts(body: body))
    }

    /// A paragraph holding one floating drawing, placed as Word places a shape put under a line of text.
    static func anchored(
        _ graphic: String, width: Int = 1_270_000, height: Int = 635_000, wrap: String = "<wp:wrapTopAndBottom/>",
        align: String = "center"
    ) -> String {
        """
        <w:p><w:r><w:drawing><wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" \
        relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>\
        <wp:positionH relativeFrom="column"><wp:align>\(align)</wp:align></wp:positionH>\
        <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>\
        <wp:extent cx="\(width)" cy="\(height)"/><wp:effectExtent l="0" t="0" r="0" b="0"/>\(wrap)\
        <wp:docPr id="1" name="Shape"/><a:graphic>\(graphic)</a:graphic></wp:anchor></w:drawing></w:r></w:p>
        """
    }

    /// A shape's graphic, of a preset outline, with `properties` after its outline and `body` its text's properties.
    static func shape(
        _ geometry: String = "rect", properties: String = "", transform: String = "", text: String? = nil,
        body: String = "<wps:bodyPr/>", width: Int = 1_270_000, height: Int = 635_000
    ) -> String {
        let box = text.map { "<wps:txbx><w:txbxContent><w:p><w:r><w:t>\($0)</w:t></w:r></w:p></w:txbxContent></wps:txbx>" } ?? ""
        return """
            <a:graphicData uri="\(wps)"><wps:wsp><wps:cNvSpPr/><wps:spPr><a:xfrm\(transform)><a:off x="0" y="0"/>\
            <a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="\(geometry)"><a:avLst/></a:prstGeom>\
            \(properties)</wps:spPr>\(box)\(body)</wps:wsp></a:graphicData>
            """
    }

    static func paragraph(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    /// Each line's rectangle, in order, with the text it holds.
    static func lines(_ layout: PageLayoutManager) -> [(rect: CGRect, text: String)] {
        guard let storage = layout.textStorage else { return [] }
        var result: [(CGRect, String)] = []
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            result.append((rect, (storage.string as NSString).substring(with: characters)))
            glyph = NSMaxRange(range)
        }
        return result
    }

    // MARK: - Placement

    @Test("A paragraph holding only a floating shape keeps a line of its own, as tall as one of text")
    func floatingShapeKeepsItsLine() throws {
        let body = Self.paragraph("Before") + Self.anchored(Self.shape(), wrap: "<wp:wrapNone/>") + Self.paragraph("After")
        let controller = DocumentTextController(document: try Self.document(body: body), scheme: .light)
        let lines = Self.lines(controller.layoutManager)
        try #require(lines.count == 3)
        #expect(lines[1].text.hasPrefix(TextCharacters.attachment))
        #expect(abs(lines[1].rect.height - lines[0].rect.height) < 0.5)
        #expect(lines[2].rect.minY >= lines[0].rect.maxY + lines[0].rect.height - 0.5)
    }

    @Test("Shapes kept above and below text, each in an empty paragraph under its caption, stack down the page")
    func topAndBottomUnderCaptions() throws {
        let body = [
            Self.paragraph("First caption"), Self.anchored(Self.shape()),
            Self.paragraph("Second caption"), Self.anchored(Self.shape("ellipse"), height: 1_016_000),
            Self.paragraph("After"),
        ].joined()
        let controller = DocumentTextController(document: try Self.document(body: body), scheme: .light)
        let layout = controller.layoutManager
        let lines = Self.lines(layout)
        func line(_ text: String) throws -> CGRect { try #require(lines.first { $0.text.hasPrefix(text) }).rect }
        let floats = layout.placedFloats.sorted { $0.frame.minY < $1.frame.minY }
        try #require(floats.count == 2)

        // Each shape is under its caption, and the text after it under the shape and its paragraph's own line.
        #expect(abs(floats[0].frame.minY - (try line("First caption")).maxY) < 0.5)
        #expect(floats[0].frame.size == CGSize(width: 100, height: 50))
        #expect((try line("Second caption")).minY >= floats[0].frame.maxY + 6)
        #expect(abs(floats[1].frame.minY - (try line("Second caption")).maxY) < 0.5)
        #expect((try line("After")).minY >= floats[1].frame.maxY + 6)
        // Centred across the text.
        #expect(abs(floats[0].frame.midX - controller.geometry.contentWidth / 2) < 0.5)
        // Settled: laid out again, nothing moves.
        let before = floats.map(\.frame)
        layout.layOutPages(in: controller.textView.textContainer, startingWith: 1)
        #expect(layout.placedFloats.sorted { $0.frame.minY < $1.frame.minY }.map(\.frame) == before)
    }

    @Test("A shape kept above and below text that doesn't fit at the foot of a page starts the next one")
    func topAndBottomOnToNextPage() throws {
        let filler = (0..<10).map { Self.paragraph("Line \($0)") }.joined()
        let body = filler + Self.anchored(Self.shape(), height: 6_350_000) + Self.paragraph("After")
        let controller = DocumentTextController(document: try Self.document(body: body), scheme: .light)
        let layout = controller.layoutManager
        let geometry = controller.geometry
        let float = try #require(layout.placedFloats.first)
        let last = try #require(Self.lines(layout).first { $0.text.hasPrefix("Line 9") }).rect
        #expect(geometry.page(containing: last.midY) == 0)
        #expect(float.page == 1)
        #expect(abs(float.frame.minY - geometry.textTop(1)) < 0.5)
        let after = try #require(Self.lines(layout).first { $0.text.hasPrefix("After") }).rect
        #expect(after.minY >= float.frame.maxY)
    }
}
