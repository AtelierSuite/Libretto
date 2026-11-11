import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

@MainActor
@Suite("Pictures")
struct PictureTests {
    private func makeController() -> (DocumentTextController, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: String(repeating: "Words flow around the picture beside them. ", count: 12)))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    private func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("A picture floats where it is put, cropped and sized, with text going round it")
    func floats() throws {
        let (controller, latest) = makeController()
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertImage(png(width: 200, height: 100))
        controller.textView.selectedRange = NSRange(location: 0, length: 1)
        #expect(controller.selectedImage != nil)
        controller.updateSelectedImage { picture in
            picture.wrap = .square
            picture.alignment = .trailing
            picture.width = 100
            picture.height = 50
            picture.crop.left = 0.2
        }

        let document = try #require(latest())
        guard case .image(let picture)? = document.allParagraphs.first?.inlines.first?.content else {
            Issue.record("the picture went missing")
            return
        }
        #expect(picture.isEdited)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<wp:anchor "))
        #expect(xml.contains("<wp:positionH relativeFrom=\"margin\"><wp:align>right</wp:align></wp:positionH>"))
        #expect(xml.contains("<wp:wrapSquare wrapText=\"bothSides\"/>"))
        #expect(xml.contains("<a:srcRect l=\"20000\"/>"))
        #expect(xml.contains("<wp:extent cx=\"1270000\" cy=\"635000\"/>"))

        let reread = try DOCXReader.document(fromParts: try Fixtures.written(document))
        guard case .image(let back)? = reread.allParagraphs.first?.inlines.first?.content else { return }
        #expect(back.wrap == .square)
        #expect(back.alignment == .trailing)
        #expect(abs(back.crop.left - 0.2) < 0.001)

        // Set at the right margin, and the first lines stop short of it.
        let layout = controller.layoutManager
        let placed = try #require(layout.placedFloats.first)
        #expect(abs(placed.frame.maxX - controller.geometry.contentWidth) < 1)
        let firstLine = layout.lineFragmentUsedRect(forGlyphAt: 1, effectiveRange: nil)
        #expect(firstLine.maxX <= placed.frame.minX)
    }

    @Test("A picture in line keeps to the line, and goes back in line from floating")
    func backInLine() throws {
        let (controller, latest) = makeController()
        controller.insertImage(png(width: 40, height: 40))
        controller.textView.selectedRange = NSRange(location: controller.textView.selectedRange.location - 1, length: 1)
        controller.updateSelectedImage { $0.wrap = .behindText }
        controller.updateSelectedImage { $0.wrap = .inline }
        let xml = Fixtures.text(try Fixtures.written(try #require(latest())), "word/document.xml")
        #expect(xml.contains("<wp:inline "))
        #expect(controller.layoutManager.placedFloats.isEmpty)
    }

    private func anchor(_ attributes: String, wrap: String) throws -> XMLElement {
        try XMLLite.parse(Data("""
            <wp:anchor xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            behindDoc="0"\(attributes)><wp:extent cx="1270000" cy="635000"/>\(wrap)</wp:anchor>
            """.utf8))
    }

    @Test("Wrap distances come from the anchor, else the wrapping, else Word's own")
    func readsWrapDistances() throws {
        var image = InlineImage(relationshipID: "rId1", width: 100, height: 50, isFloating: true)
        DrawingReader.readPlacement(
            of: try anchor(#" distT="25400" distB="50800" distL="228600" distR="0""#, wrap: "<wp:wrapSquare wrapText=\"bothSides\"/>"),
            into: &image
        )
        #expect(image.wrapDistances == WrapDistances(top: 2, bottom: 4, left: 18, right: 0))

        DrawingReader.readPlacement(
            of: try anchor("", wrap: #"<wp:wrapTight wrapText="bothSides" distL="38100" distR="38100"/>"#), into: &image
        )
        #expect(image.wrapDistances == WrapDistances(top: 0, bottom: 0, left: 3, right: 3))

        DrawingReader.readPlacement(of: try anchor("", wrap: "<wp:wrapTopAndBottom/>"), into: &image)
        #expect(image.wrapDistances == WrapDistances(top: 0, bottom: 0, left: 9, right: 9))
    }

    @Test("Wrap distances are written back as they were read")
    func writesWrapDistances() throws {
        let distances = WrapDistances(top: 2, bottom: 4, left: 18, right: 0)
        let image = InlineImage(
            relationshipID: "rId1", width: 100, height: 50, isFloating: true, wrap: .tight, wrapDistances: distances
        )
        let xml = DrawingWriter.xml(for: image, id: 1)
        #expect(xml.contains(#"distT="25400" distB="50800" distL="228600" distR="0""#))

        let drawing = try XMLLite.parse(Data(xml.replacingOccurrences(
            of: "<w:drawing>", with: #"<w:drawing xmlns:w="w" xmlns:wp="wp" xmlns:a="a" xmlns:pic="pic" xmlns:r="r">"#
        ).utf8))
        var back = InlineImage(relationshipID: "rId1", width: 100, height: 50, isFloating: true)
        DrawingReader.readPlacement(of: try #require(drawing.firstChild(named: "anchor")), into: &back)
        #expect(back.wrapDistances == distances)
        #expect(back.wrap == .tight)

        let plain = InlineImage(relationshipID: "rId1", width: 100, height: 50, isFloating: true, wrap: .square)
        #expect(DrawingWriter.xml(for: plain, id: 1).contains(#"distT="0" distB="0" distL="114300" distR="114300""#))
    }

    @Test("Through wrapping is read and written as through, not tight")
    func readsAndWritesThroughWrapping() throws {
        var image = InlineImage(relationshipID: "rId1", width: 100, height: 50, isFloating: true)
        DrawingReader.readPlacement(of: try anchor("", wrap: #"<wp:wrapThrough wrapText="bothSides"/>"#), into: &image)
        #expect(image.wrap == .through)
        DrawingReader.readPlacement(of: try anchor("", wrap: #"<wp:wrapTight wrapText="bothSides"/>"#), into: &image)
        #expect(image.wrap == .tight)

        image.wrap = .through
        let xml = DrawingWriter.xml(for: image, id: 1)
        #expect(xml.contains("<wp:wrapThrough "))
        #expect(!xml.contains("wrapTight"))
    }

    @Test("Text keeps to a floating picture's wrap distances")
    func keepsToWrapDistances() throws {
        for (wrap, left) in [(ImageWrap.square, 36.0), (.tight, 0), (.square, 9)] {
            let (controller, _) = makeController()
            controller.textView.selectedRange = NSRange(location: 0, length: 0)
            controller.insertImage(png(width: 200, height: 100))
            controller.textView.selectedRange = NSRange(location: 0, length: 1)
            controller.updateSelectedImage { picture in
                picture.wrap = wrap
                picture.alignment = .trailing
                picture.width = 100
                picture.height = 50
                picture.wrapDistances.left = left
            }
            let layout = controller.layoutManager
            let placed = try #require(layout.placedFloats.first)
            let firstLine = layout.lineFragmentRect(forGlyphAt: 1, effectiveRange: nil)
            #expect(firstLine.maxX <= placed.frame.minX - left + 0.5, "\(wrap) \(left)")
            #expect(firstLine.maxX >= placed.frame.minX - left - 0.5, "\(wrap) \(left)")
        }

        // Above and below: the text below starts the bottom distance under the picture.
        let (controller, _) = makeController()
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertImage(png(width: 200, height: 100))
        controller.textView.selectedRange = NSRange(location: 0, length: 1)
        controller.updateSelectedImage { picture in
            picture.wrap = .topAndBottom
            picture.width = 100
            picture.height = 50
            picture.wrapDistances.bottom = 24
        }
        let layout = controller.layoutManager
        let placed = try #require(layout.placedFloats.first)
        let below = (1..<layout.numberOfGlyphs).lazy
            .map { layout.lineFragmentRect(forGlyphAt: $0, effectiveRange: nil) }
            .first { $0.minY >= placed.frame.minY }
        #expect(try #require(below).minY >= placed.frame.maxY + 24 - 0.5)
    }

    private static let diamond = WrapPolygon(points: [
        .init(x: 0.5, y: 0), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1), .init(x: 0, y: 0.5), .init(x: 0.5, y: 0),
    ])

    @Test("The wrap polygon is read in fractions of the picture and written back in Word's units")
    func readsAndWritesWrapPolygon() throws {
        var image = InlineImage(relationshipID: "rId1", width: 100, height: 50, isFloating: true)
        DrawingReader.readPlacement(of: try anchor("", wrap: """
            <wp:wrapTight wrapText="bothSides"><wp:wrapPolygon edited="1"><wp:start x="10800" y="0"/>\
            <wp:lineTo x="21600" y="10800"/><wp:lineTo x="10800" y="21600"/><wp:lineTo x="0" y="10800"/>\
            <wp:lineTo x="10800" y="0"/></wp:wrapPolygon></wp:wrapTight>
            """), into: &image)
        #expect(image.wrapPolygon == WrapPolygon(points: Self.diamond.points, isEdited: true))

        let xml = DrawingWriter.xml(for: image, id: 1)
        #expect(xml.contains(#"<wp:wrapPolygon edited="1"><wp:start x="10800" y="0"/><wp:lineTo x="21600" y="10800"/>"#))

        DrawingReader.readPlacement(of: try anchor("", wrap: "<wp:wrapSquare wrapText=\"bothSides\"/>"), into: &image)
        #expect(image.wrapPolygon == nil)
    }

    @Test("Tight wrapping keeps clear of the whole outline across each band, through wrapping fills its open parts")
    func wrapPolygonBands() {
        // A U, open at the top: two arms 0–0.25 and 0.75–1 across, joined below halfway.
        let cup = WrapPolygon(points: [
            .init(x: 0, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 0),
            .init(x: 0.75, y: 0), .init(x: 0.75, y: 0.5), .init(x: 0.25, y: 0.5), .init(x: 0.25, y: 0),
        ])
        let tight = cup.exclusions(x: 100, y: 0, width: 100, height: 100, left: 5, right: 3, through: false, step: 10)
        #expect(tight.allSatisfy { $0.minX == 95 && $0.maxX == 203 })
        #expect(tight.count == 1)
        #expect(tight.first?.minY == 0 && tight.first?.maxY == 100)

        let through = cup.exclusions(x: 100, y: 0, width: 100, height: 100, left: 5, right: 3, through: true, step: 10)
        let upper = through.filter { $0.maxY <= 50 }
        #expect(Set(upper.map(\.minX)) == [95, 170])
        #expect(Set(upper.map(\.maxX)) == [128, 203])
        #expect(through.filter { $0.minY >= 50 }.allSatisfy { $0.minX == 95 && $0.maxX == 203 })

        // Each band of a diamond is as wide as the diamond is at that band's widest; the two across its middle are one.
        let bands = Self.diamond.exclusions(x: 0, y: 0, width: 100, height: 100, left: 0, right: 0, through: false, step: 10)
        #expect(bands.count == 9)
        #expect(bands[0] == WrapPolygon.Band(minX: 40, minY: 0, maxX: 60, maxY: 10))
        #expect(bands[4] == WrapPolygon.Band(minX: 0, minY: 40, maxX: 100, maxY: 60))
        #expect(bands[8] == WrapPolygon.Band(minX: 40, minY: 90, maxX: 60, maxY: 100))
    }

    @Test("Text wrapped tight follows the picture's outline line by line")
    func followsWrapPolygon() throws {
        let (controller, _) = makeController()
        controller.textView.selectedRange = NSRange(location: 0, length: 0)
        controller.insertImage(png(width: 200, height: 100))
        controller.textView.selectedRange = NSRange(location: 0, length: 1)
        controller.updateSelectedImage { picture in
            picture.wrap = .tight
            picture.alignment = .trailing
            picture.width = 120
            picture.height = 120
            picture.wrapDistances.left = 0
            picture.wrapPolygon = Self.diamond
        }
        let layout = controller.layoutManager
        let placed = try #require(layout.placedFloats.first)
        var lines: [CGRect] = []
        var glyph = 1
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            lines.append(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range))
            glyph = max(glyph + 1, NSMaxRange(range))
        }
        let beside = lines.filter { $0.minY >= placed.frame.minY - 0.5 && $0.maxY <= placed.frame.maxY + 0.5 }
        #expect(beside.count >= 4)
        // The first line runs into the corner the diamond leaves free; the one across its middle stops at its point.
        let first = try #require(beside.first)
        let middle = try #require(beside.first { $0.minY <= placed.frame.midY && $0.maxY >= placed.frame.midY })
        #expect(first.maxX > placed.frame.minX + 20)
        #expect(middle.maxX <= placed.frame.minX + 0.5)
        #expect(first.maxX > middle.maxX + 20)
    }
}
