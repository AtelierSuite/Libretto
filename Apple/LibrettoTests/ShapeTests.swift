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

    /// The objects a document's body holds, in order.
    static func objects(_ document: WordDocument) -> [DrawingObject] {
        document.allParagraphs.flatMap(\.inlines).compactMap { inline in
            if case .image(let image) = inline.content { image.object } else { nil }
        }
    }

    static func shapeSpec(_ document: WordDocument) throws -> ShapeSpec {
        guard case .shape(let shape)? = objects(document).first else { throw ShapeError.none }
        return shape
    }

    enum ShapeError: Error { case none }

    // MARK: - Text

    @Test("A shape's text is read in its paragraphs' formatting, and set where its body says")
    func textInItsFormatting() throws {
        let content = """
            <wps:txbx><w:txbxContent><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr>\
            <w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:color w:val="FFFFFF"/><w:sz w:val="20"/></w:rPr>\
            <w:t>Centred</w:t></w:r></w:p><w:p><w:r><w:t>Plain</w:t></w:r></w:p></w:txbxContent></wps:txbx>\
            <wps:bodyPr lIns="0" tIns="25400" anchor="b"/>
            """
        let graphic = Self.shape(properties: "<a:solidFill><a:srgbClr val=\"70AD47\"/></a:solidFill>", body: content)
        let shape = try Self.shapeSpec(try Self.document(body: Self.anchored(graphic)))
        #expect(shape.text == "Centred\nPlain")
        #expect(shape.textAnchor == .bottom)
        #expect(shape.textInsets == ShapeInsets(left: 0, top: 2, right: 7.2, bottom: 3.6))
        let paragraphs = try #require(shape.formattedParagraphs)
        #expect(paragraphs.map(\.alignment) == [.center, .leading])
        let run = try #require(paragraphs.first?.runs.first)
        #expect(run.style.fontName == "Arial")
        #expect(run.style.fontSize == 20)
        #expect(run.style.colorHex == "FFFFFF")
        // The second paragraph's runs have the document's own size.
        #expect(paragraphs[1].runs.first?.style.fontSize != nil)

        // Set at the foot, in from the edges by the insets.
        let area = ObjectRenderer.textArea(for: shape, in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(area == CGRect(x: 0, y: 2, width: 92.8, height: 44.4))
    }

    @Test("A shape whose body says nothing keeps Libretto's own insets and anchor")
    func textDefaults() throws {
        let shape = try Self.shapeSpec(try Self.document(body: Self.anchored(Self.shape(text: "Hi"))))
        #expect(shape.textAnchor == nil)
        #expect(shape.textInsets == nil)
    }

    /// The colour of a picture at a point, in points from its top left corner, on white.
    static func color(_ image: UIImage, at point: CGPoint) -> (red: Int, green: Int, blue: Int) {
        guard let cgImage = image.cgImage else { return (-1, -1, -1) }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = PageSnapshots.pixels(cgImage)
        let x = min(cgImage.width - 1, max(0, Int(point.x * scale)))
        let y = min(cgImage.height - 1, max(0, Int(point.y * scale)))
        let at = (y * cgImage.width + x) * 4
        return (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
    }

    /// Whether a colour is within a few steps of a six-digit hex one.
    static func isNear(_ color: (red: Int, green: Int, blue: Int), _ hex: String, by tolerance: Int = 12) -> Bool {
        let value = Int(hex, radix: 16) ?? 0
        return abs(color.red - (value >> 16 & 0xFF)) <= tolerance && abs(color.green - (value >> 8 & 0xFF)) <= tolerance
            && abs(color.blue - (value & 0xFF)) <= tolerance
    }

    // MARK: - Groups

    static func groupShape(_ geometry: String, x: Int, y: Int, width: Int, height: Int, fill: String, text: String? = nil) -> String {
        let box = text.map { "<wps:txbx><w:txbxContent><w:p><w:r><w:t>\($0)</w:t></w:r></w:p></w:txbxContent></wps:txbx>" } ?? ""
        return """
            <wps:wsp><wps:cNvSpPr/><wps:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm>\
            <a:prstGeom prst="\(geometry)"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(fill)"/></a:solidFill>\
            </wps:spPr>\(box)<wps:bodyPr/></wps:wsp>
            """
    }

    /// A group 200 by 100 points whose children are set in units twice as small, holding an
    /// ellipse on its right half and, in a group of its own, a rectangle at its top left.
    static let group = """
        <a:graphicData uri="\(wpg)"><wpg:wgp><wpg:cNvGrpSpPr/><wpg:grpSpPr><a:xfrm><a:off x="0" y="0"/>\
        <a:ext cx="2540000" cy="1270000"/><a:chOff x="1000" y="2000"/><a:chExt cx="5080000" cy="2540000"/></a:xfrm>\
        </wpg:grpSpPr>\(groupShape("ellipse", x: 2_541_000, y: 2000, width: 2_540_000, height: 2_540_000, fill: "4472C4", text: "1"))\
        <wpg:grpSp><wpg:grpSpPr><a:xfrm><a:off x="1000" y="2000"/><a:ext cx="2540000" cy="1270000"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="2540000" cy="1270000"/></a:xfrm></wpg:grpSpPr>\
        \(groupShape("rect", x: 0, y: 0, width: 1_270_000, height: 635_000, fill: "ED7D31"))</wpg:grpSp></wpg:wgp></a:graphicData>
        """

    @Test("A group's shapes are read, each framed by its children's offset and extent, groups within it too")
    func readsGroup() throws {
        let document = try Self.document(body: Self.anchored(Self.group, width: 2_540_000, height: 1_270_000))
        guard case .group(let group)? = Self.objects(document).first else { Issue.record("no group"); return }
        #expect(group.width == 200 && group.height == 100)
        #expect(group.shapes.map(\.geometry) == ["ellipse", "rect"])
        #expect(group.shapes.map(\.frame) == [
            ShapeFrame(x: 100, y: 0, width: 100, height: 100), ShapeFrame(x: 0, y: 0, width: 50, height: 25),
        ])
        #expect(group.shapes.first?.text == "1")
        // Drawn as it is, so neither a placeholder nor drawn more simply.
        #expect(!document.unsupportedFeatures.features.contains(.shapes))
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))
    }

    @Test("A group's shapes are drawn where they are in it")
    func drawsGroup() throws {
        let document = try Self.document(body: Self.anchored(Self.group, width: 2_540_000, height: 1_270_000))
        let object = try #require(Self.objects(document).first)
        let image = ObjectRenderer.image(for: object, size: CGSize(width: 200, height: 100))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 150, y: 20)), "4472C4"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 20, y: 12)), "ED7D31"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 70, y: 70)), "FFFFFF"))
    }

    @Test("A group turned as a whole, or holding a picture, is drawn more simply")
    func groupSimplified() throws {
        let turned = Self.group.replacingOccurrences(of: "<a:xfrm><a:off x=\"0\" y=\"0\"/>", with: "<a:xfrm rot=\"5400000\"><a:off x=\"0\" y=\"0\"/>")
        let document = try Self.document(body: Self.anchored(turned, width: 2_540_000, height: 1_270_000))
        #expect(document.unsupportedFeatures.features.contains(.simplifiedObjects))
    }

    // MARK: - Linked text boxes

    /// How many pixels of a picture are dark: its text, on a white box.
    static func darkPixels(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let pixels = PageSnapshots.pixels(cgImage)
        return stride(from: 0, to: pixels.count, by: 4).filter { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) < 300 }.count
    }

    /// Two text boxes 150 by 50 points side by side, the text of the first running on into the second.
    static func linkedBoxes(lines: Int) -> String {
        let paragraphs = (1...lines).map { "<w:p><w:r><w:rPr><w:sz w:val=\"20\"/></w:rPr><w:t>Line \($0) of the run</w:t></w:r></w:p>" }
        let first = """
            <a:graphicData uri="\(wps)"><wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/>\
            <a:ext cx="1905000" cy="635000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln>\
            </wps:spPr><wps:txbx id="1"><w:txbxContent>\(paragraphs.joined())</w:txbxContent></wps:txbx>\
            <wps:bodyPr lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"/></wps:wsp></a:graphicData>
            """
        let second = """
            <a:graphicData uri="\(wps)"><wps:wsp><wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/>\
            <a:ext cx="1905000" cy="635000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln>\
            </wps:spPr><wps:linkedTxbx id="1" seq="1"/><wps:bodyPr lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"/></wps:wsp></a:graphicData>
            """
        let wrap = "<wp:wrapSquare wrapText=\"bothSides\"/>"
        return anchored(first, width: 1_905_000, height: 635_000, wrap: wrap, align: "left")
            + anchored(second, width: 1_905_000, height: 635_000, wrap: wrap, align: "right")
    }

    @Test("Linked text boxes each hold the text that runs through them, and know which of the run they are")
    func readsLinkedBoxes() throws {
        let document = try Self.document(body: Self.linkedBoxes(lines: 8))
        let shapes = Self.objects(document).compactMap { object -> ShapeSpec? in
            if case .shape(let shape) = object { shape } else { nil }
        }
        try #require(shapes.count == 2)
        let areas = [ShapeFrame(x: 0, y: 0, width: 150, height: 50), ShapeFrame(x: 0, y: 0, width: 150, height: 50)]
        #expect(shapes.map(\.linkedText) == [LinkedText(areas: areas, index: 0), LinkedText(areas: areas, index: 1)])
        #expect(shapes[1].text == shapes[0].text)
        #expect(shapes[1].text.hasSuffix("Line 8 of the run"))
        #expect(shapes[1].isTextBox)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))
    }

    @Test("Text that overflows the first linked box is drawn in the next, and only there")
    func drawsLinkedBoxes() throws {
        let shapes = Self.objects(try Self.document(body: Self.linkedBoxes(lines: 8)))
        try #require(shapes.count == 2)
        let size = CGSize(width: 150, height: 50)
        let first = ObjectRenderer.image(for: shapes[0], size: size)
        let second = ObjectRenderer.image(for: shapes[1], size: size)
        #expect(Self.darkPixels(first) > 50)
        #expect(Self.darkPixels(second) > 50)
        // The second box's part starts at its top.
        #expect(Self.darkPixels(Self.crop(second, CGRect(x: 0, y: 0, width: 150, height: 10))) > 0)

        // With little enough text to fit the first box, the second is empty.
        let short = Self.objects(try Self.document(body: Self.linkedBoxes(lines: 2)))
        #expect(Self.darkPixels(ObjectRenderer.image(for: short[1], size: size)) == 0)
    }

    static func crop(_ image: UIImage, _ rect: CGRect) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return cgImage.cropping(to: pixels).map { UIImage(cgImage: $0, scale: scale, orientation: .up) } ?? image
    }

    // MARK: - Turned and flipped

    static let green = "<a:solidFill><a:srgbClr val=\"70AD47\"/></a:solidFill><a:ln><a:noFill/></a:ln>"

    @Test("A turned shape is read, drawn turned about its middle, and reaches past its frame by its corners")
    func turned() throws {
        let graphic = Self.shape(properties: Self.green, transform: " rot=\"5400000\"", width: 1_270_000, height: 254_000)
        let document = try Self.document(body: Self.anchored(graphic, width: 1_270_000, height: 254_000))
        let shape = try Self.shapeSpec(document)
        #expect(shape.rotation == 90)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // 100 by 20 points, turned a quarter: 20 wide and 100 tall about the same middle.
        let object = DrawingObject.shape(shape)
        let size = CGSize(width: 100, height: 20)
        #expect(ObjectRenderer.overhang(for: object, size: size) == ObjectRenderer.Overhang(top: 40, bottom: 40))
        let image = ObjectRenderer.image(for: object, size: size)
        #expect(image.size == CGSize(width: 100, height: 100))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 5)), "70AD47"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 5, y: 50)), "FFFFFF"))
    }

    @Test("A turned shape kept above and below text has room for its turned corners, and is drawn past its frame")
    func turnedKeepsRoom() throws {
        let graphic = Self.shape(properties: Self.green, transform: " rot=\"5400000\"", width: 1_270_000, height: 254_000)
        let body = Self.paragraph("Caption") + Self.anchored(graphic, width: 1_270_000, height: 254_000) + Self.paragraph("After")
        let controller = DocumentTextController(document: try Self.document(body: body), scheme: .light)
        let layout = controller.layoutManager
        let float = try #require(layout.placedFloats.first)
        let lines = Self.lines(layout)
        let caption = try #require(lines.first { $0.text.hasPrefix("Caption") }).rect
        let after = try #require(lines.first { $0.text.hasPrefix("After") }).rect
        #expect(float.frame.size == CGSize(width: 100, height: 100))
        #expect(abs(float.frame.minY - caption.maxY) < 0.5)
        #expect(after.minY >= float.frame.maxY)
    }

    @Test("A shape flipped left to right is read and drawn mirrored, and stays within its frame")
    func flipped() throws {
        let graphic = Self.shape("rightArrow", properties: Self.green, transform: " flipH=\"1\" flipV=\"0\"")
        let document = try Self.document(body: Self.anchored(graphic))
        let shape = try Self.shapeSpec(document)
        #expect(shape.flipsHorizontally && !shape.flipsVertically)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // 100 by 50 points: the arrow's head, at the right unflipped, is at the left; its shaft at the right.
        let size = CGSize(width: 100, height: 50)
        let flipped = ObjectRenderer.image(for: .shape(shape), size: size)
        #expect(flipped.size == size)
        var plain = shape
        plain.flipsHorizontally = false
        let unflipped = ObjectRenderer.image(for: .shape(plain), size: size)
        #expect(Self.isNear(Self.color(unflipped, at: CGPoint(x: 5, y: 15)), "70AD47"))
        #expect(Self.isNear(Self.color(flipped, at: CGPoint(x: 5, y: 15)), "FFFFFF"))
        #expect(Self.isNear(Self.color(flipped, at: CGPoint(x: 95, y: 15)), "70AD47"))
        #expect(Self.isNear(Self.color(flipped, at: CGPoint(x: 5, y: 25)), "70AD47"))
    }

    /// Where a picture's dark pixels are, in points.
    static func inkBounds(_ image: UIImage) -> CGRect {
        guard let cgImage = image.cgImage else { return .null }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = PageSnapshots.pixels(cgImage)
        var bounds = CGRect.null
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let at = (y * cgImage.width + x) * 4
                if Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2]) < 300 {
                    bounds = bounds.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
                }
            }
        }
        return bounds
    }

    @Test("Text set running up or down is read and drawn a quarter turned, along the shape's height")
    func verticalText() throws {
        for (vertical, direction) in [("vert270", ShapeSpec.TextDirection.up), ("vert", .down), ("eaVert", .down)] {
            let body = "<wps:bodyPr vert=\"\(vertical)\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"ctr\"/>"
            let graphic = Self.shape(properties: "<a:noFill/><a:ln><a:noFill/></a:ln>", text: "Sideways", body: body)
            let document = try Self.document(body: Self.anchored(graphic))
            let shape = try Self.shapeSpec(document)
            #expect(shape.textDirection == direction)
            #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

            // In a box 30 points wide and 150 tall, the word runs along its height in one line.
            let ink = Self.inkBounds(ObjectRenderer.image(for: .shape(shape), size: CGSize(width: 30, height: 150)))
            #expect(ink.width < 18, "\(vertical): \(ink)")
            #expect(ink.height > 30, "\(vertical): \(ink)")
        }
    }

    // MARK: - Fills

    static let threeStops = """
        <a:gsLst><a:gs pos="0"><a:srgbClr val="1F4E79"/></a:gs><a:gs pos="50000"><a:srgbClr val="5B9BD5"/></a:gs>\
        <a:gs pos="100000"><a:srgbClr val="DEEBF7"><a:alpha val="80000"/></a:srgbClr></a:gs></a:gsLst>
        """

    @Test("A linear gradient is read with its stops and angle, and drawn from edge to edge along it")
    func linearGradient() throws {
        let fill = "<a:gradFill rotWithShape=\"1\">\(Self.threeStops)<a:lin ang=\"5400000\" scaled=\"0\"/></a:gradFill><a:ln><a:noFill/></a:ln>"
        let document = try Self.document(body: Self.anchored(Self.shape(properties: fill)))
        let shape = try Self.shapeSpec(document)
        let gradient = try #require(shape.gradient)
        #expect(gradient.stops == [
            .init(position: 0, colorHex: "1F4E79"), .init(position: 0.5, colorHex: "5B9BD5"),
            .init(position: 1, colorHex: "DEEBF7", alpha: 0.8),
        ])
        #expect(gradient.kind == .linear(angle: 90, scaled: false))
        #expect(shape.fillHex == "1F4E79")
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // Down the shape: dark at the top, the middle stop halfway, light at the foot.
        let image = ObjectRenderer.image(for: .shape(shape), size: CGSize(width: 100, height: 100))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 2)), "1F4E79", by: 16))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 50)), "5B9BD5", by: 16))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 97)), "E5EFF9", by: 16))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 3, y: 50)), "5B9BD5", by: 16))
    }

    @Test("A gradient out from the middle is read with its focus, and drawn from the first colour there to the last at the corners")
    func radialGradient() throws {
        let fill = """
            <a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FFD966"/></a:gs><a:gs pos="100000"><a:srgbClr val="C55A11"/></a:gs>\
            </a:gsLst><a:path path="circle"><a:fillToRect l="50000" t="50000" r="50000" b="50000"/></a:path></a:gradFill>
            """
        let document = try Self.document(body: Self.anchored(Self.shape("ellipse", properties: fill)))
        let shape = try Self.shapeSpec(document)
        let half = ShapeInsets(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5)
        #expect(shape.gradient?.kind == .path(focus: half, isCircle: true))
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        var square = shape
        square.geometry = "rect"
        square.lineHex = nil
        let image = ObjectRenderer.image(for: .shape(square), size: CGSize(width: 100, height: 100))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 50)), "FFD966", by: 16))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 2, y: 2)), "C55A11", by: 24))
    }

    @Test("Word's preset patterns are tiles of lines, grids, checks and shades, and others are not drawn as Word draws them")
    func patternTiles() {
        // Wide stripes down to the right: three pixels in eight, a pixel further right each row.
        #expect((0..<8).filter { ShapePattern.isForeground("wdDnDiag", x: $0, y: 0) == true } == [0, 1, 2])
        #expect((0..<8).filter { ShapePattern.isForeground("wdDnDiag", x: $0, y: 1) == true } == [1, 2, 3])
        #expect((0..<8).filter { ShapePattern.isForeground("ltUpDiag", x: $0, y: 1) == true } == [3, 7])
        #expect((0..<8).filter { ShapePattern.isForeground("dkHorz", x: 0, y: $0) == true } == [0, 1, 4, 5])
        func share(_ preset: String) -> Int {
            (0..<64).filter { ShapePattern.isForeground(preset, x: $0 % 8, y: $0 / 8) == true }.count
        }
        #expect(share("pct5") == 3)
        #expect(share("pct50") == 32)
        #expect(share("pct90") == 58)
        #expect(ShapePattern.isForeground("weave", x: 0, y: 0) == nil)
    }

    @Test("A pattern fill is read with its colours and drawn as its tile, over and over")
    func patternFill() throws {
        let fill = """
            <a:pattFill prst="wdDnDiag"><a:fgClr><a:srgbClr val="C00000"/></a:fgClr><a:bgClr><a:srgbClr val="FFF2CC"/></a:bgClr>\
            </a:pattFill><a:ln><a:noFill/></a:ln>
            """
        let document = try Self.document(body: Self.anchored(Self.shape(properties: fill)))
        let shape = try Self.shapeSpec(document)
        #expect(shape.pattern == ShapePattern(preset: "wdDnDiag", foregroundHex: "C00000", backgroundHex: "FFF2CC"))
        #expect(shape.fillHex == "FFF2CC")
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // Each tile pixel three quarters of a point: the third row's third pixel is in the stripe, its seventh not;
        // and so on, a tile (six points) further on.
        let image = ObjectRenderer.image(for: .shape(shape), size: CGSize(width: 48, height: 48))
        for offset in [0.0, 6, 12] {
            #expect(Self.isNear(Self.color(image, at: CGPoint(x: 1.9 + offset, y: 1.9 + offset)), "C00000", by: 20))
            #expect(Self.isNear(Self.color(image, at: CGPoint(x: 4.9 + offset, y: 1.9 + offset)), "FFF2CC", by: 20))
        }

        let other = try Self.document(body: Self.anchored(Self.shape(properties: fill.replacingOccurrences(of: "wdDnDiag", with: "weave"))))
        #expect(other.unsupportedFeatures.features.contains(.simplifiedObjects))
    }

    @Test("A fill or line partly see-through is read and drawn so, the page showing through")
    func transparency() throws {
        let fill = """
            <a:solidFill><a:srgbClr val="70AD47"><a:alpha val="50000"/></a:srgbClr></a:solidFill>\
            <a:ln w="76200"><a:solidFill><a:srgbClr val="2F528F"><a:alpha val="25000"/></a:srgbClr></a:solidFill></a:ln>
            """
        let shape = try Self.shapeSpec(try Self.document(body: Self.anchored(Self.shape(properties: fill))))
        #expect(shape.fillAlpha == 0.5)
        #expect(shape.lineAlpha == 0.25)
        let image = ObjectRenderer.image(for: .shape(shape), size: CGSize(width: 100, height: 50))
        // Half the green on white in the middle; a quarter of the blue over it at the 6-point line's edge.
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 50, y: 25)), "B7D6A3", by: 8))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 1, y: 25)), "CBD4E3", by: 10))
    }

    // MARK: - Effects

    @Test("An outer shadow is read, and cast down and to the right as its direction says, past the shape's frame")
    func outerShadow() throws {
        let effects = """
            <a:solidFill><a:srgbClr val="70AD47"/></a:solidFill><a:ln><a:noFill/></a:ln><a:effectLst>\
            <a:outerShdw blurRad="0" dist="127000" dir="2700000" algn="tl" rotWithShape="0"><a:srgbClr val="000000"/>\
            </a:outerShdw></a:effectLst>
            """
        let document = try Self.document(body: Self.anchored(Self.shape(properties: effects)))
        let shape = try Self.shapeSpec(document)
        let shadow = try #require(shape.shadow)
        #expect(shadow.distance == 10 && shadow.direction == 45 && shadow.blur == 0)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // 60 by 40 points; the shadow 7.07 points right and down.
        let size = CGSize(width: 60, height: 40)
        #expect(ObjectRenderer.overhang(for: .shape(shape), size: size) == ObjectRenderer.Overhang(bottom: 7.25, right: 7.25))
        #expect(ObjectRenderer.overhang(for: .shape(shape), size: size, effects: false) == .zero)
        let image = ObjectRenderer.image(for: .shape(shape), size: size)
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 30, y: 20)), "70AD47"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 65, y: 44)), "000000", by: 30))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 3, y: 44)), "FFFFFF"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 65, y: 3)), "FFFFFF"))

        // Turned, the shadow still falls down and to the right on the page.
        var turned = shape
        turned.rotation = 180
        let turnedImage = ObjectRenderer.image(for: .shape(turned), size: size)
        #expect(Self.isNear(Self.color(turnedImage, at: CGPoint(x: 65, y: 44)), "000000", by: 30))
        #expect(Self.isNear(Self.color(turnedImage, at: CGPoint(x: 3, y: 44)), "FFFFFF"))

        // Set off as far as it says, not as far on the screen's pixels: 10 points straight down.
        var down = shape
        down.shadow?.direction = 90
        let below = ObjectRenderer.image(for: .shape(down), size: CGSize(width: 60, height: 20))
        #expect(below.size == CGSize(width: 60, height: 30))
        #expect(Self.isNear(Self.color(below, at: CGPoint(x: 30, y: 26)), "000000", by: 30))
        #expect(Self.isNear(Self.color(below, at: CGPoint(x: 30, y: 15)), "70AD47"))
        // Blurred as much as it says: a soft edge a few points wide, not a wide haze.
        down.shadow?.blur = 4
        let soft = ObjectRenderer.image(for: .shape(down), size: CGSize(width: 60, height: 20))
        #expect(Self.isNear(Self.color(soft, at: CGPoint(x: 30, y: 26)), "000000", by: 90))

        let stretched = effects.replacingOccurrences(of: "rotWithShape=\"0\"", with: "sx=\"90000\"")
        #expect(try Self.document(body: Self.anchored(Self.shape(properties: stretched))).unsupportedFeatures.features
            .contains(.simplifiedObjects))
    }

    @Test("A glow is read, and drawn softly around the shape's outline, as far out as its radius")
    func glow() throws {
        let effects = """
            <a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:ln><a:noFill/></a:ln><a:effectLst>\
            <a:glow rad="127000"><a:srgbClr val="FF0000"><a:alpha val="60000"/></a:srgbClr></a:glow></a:effectLst>
            """
        let document = try Self.document(body: Self.anchored(Self.shape(properties: effects)))
        let shape = try Self.shapeSpec(document)
        #expect(shape.glow == ShapeGlow(radius: 10, colorHex: "FF0000", alpha: 0.6))
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        let size = CGSize(width: 40, height: 40)
        #expect(ObjectRenderer.overhang(for: .shape(shape), size: size) == ObjectRenderer.Overhang(top: 10, left: 10, bottom: 10, right: 10))
        let image = ObjectRenderer.image(for: .shape(shape), size: size)
        #expect(image.size == CGSize(width: 60, height: 60))
        // Red just outside the outline, fading out; the shape itself as it is.
        let near = Self.color(image, at: CGPoint(x: 30, y: 9))
        #expect(near.red > 240 && near.green < 230 && near.blue < 230, "\(near)")
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 30, y: 30)), "FFFFFF"))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 1, y: 1)), "FFFFFF", by: 20))
    }

    // MARK: - Lines

    @Test("A dashed line is read as its dashes and gaps in widths of the line, Word's presets and its own")
    func readsDashes() throws {
        func dashes(_ line: String) throws -> [Double]? {
            let properties = "<a:noFill/><a:ln w=\"25400\"><a:solidFill><a:srgbClr val=\"C00000\"/></a:solidFill>\(line)</a:ln>"
            return try Self.shapeSpec(try Self.document(body: Self.anchored(Self.shape(properties: properties)))).lineDashes
        }
        #expect(try dashes("<a:prstDash val=\"dash\"/>") == [4, 3])
        #expect(try dashes("<a:prstDash val=\"sysDashDot\"/>") == [3, 1, 1, 1])
        #expect(try dashes("<a:prstDash val=\"solid\"/>") == nil)
        #expect(try dashes("<a:custDash><a:ds d=\"200000\" sp=\"100000\"/></a:custDash>") == [2, 1])
        #expect(try dashes("") == nil)
    }

    @Test("A dashed outline is drawn in dashes and gaps as long as its width says")
    func drawsDashes() throws {
        let properties = """
            <a:noFill/><a:ln w="25400"><a:solidFill><a:srgbClr val="C00000"/></a:solidFill><a:prstDash val="dash"/></a:ln>
            """
        let document = try Self.document(body: Self.anchored(Self.shape(properties: properties)))
        let shape = try Self.shapeSpec(document)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))
        // A 2-point line: dashes 8 points long, gaps 6, along the top from the top left corner.
        let image = ObjectRenderer.image(for: .shape(shape), size: CGSize(width: 100, height: 40))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 5.5, y: 1.5)), "C00000", by: 20))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 12.5, y: 1.5)), "FFFFFF", by: 20))
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 19.5, y: 1.5)), "C00000", by: 20))
    }

    @Test("A line's heads are read with their sizes, and drawn at its ends, reaching past its frame")
    func arrowheads() throws {
        let properties = """
            <a:ln w="25400"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:headEnd type="triangle"/>\
            <a:tailEnd type="arrow" w="lg" len="sm"/></a:ln>
            """
        let graphic = Self.shape("straightConnector1", properties: properties, width: 1_270_000, height: 0)
        let document = try Self.document(body: Self.anchored(graphic, width: 1_270_000, height: 12_700))
        let shape = try Self.shapeSpec(document)
        #expect(shape.lineStart == ShapeLineEnd(kind: .triangle))
        #expect(shape.lineEnd == ShapeLineEnd(kind: .arrow, width: 5, length: 2))
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))

        // A 2-point line 100 points long: the heads reach five widths' half, and the line's width, past it.
        let size = CGSize(width: 100, height: 1)
        let past = ObjectRenderer.overhang(for: .shape(shape), size: size)
        #expect(past == ObjectRenderer.Overhang(top: 7, left: 7, bottom: 7, right: 7))
        let image = ObjectRenderer.image(for: .shape(shape), size: size)
        func dark(_ rect: CGRect) -> Int { Self.darkPixels(Self.crop(image, rect)) }
        // Above the line, only at its ends; the filled triangle solid near its base.
        let above = { (x: CGFloat) in CGRect(x: x, y: 3, width: 8, height: 3.5) }
        #expect(dark(above(10)) > 0)
        #expect(dark(above(98)) > 0)
        #expect(dark(above(50)) == 0)
        #expect(Self.isNear(Self.color(image, at: CGPoint(x: 13, y: 6)), "000000", by: 40))
    }
}
