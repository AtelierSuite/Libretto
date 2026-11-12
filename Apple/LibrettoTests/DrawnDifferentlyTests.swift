import Foundation
import Testing
@testable import LibrettoEngine

@Suite("Features drawn differently from Word or Pages")
struct DrawnDifferentlyTests {
    private static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"

    /// The fixture package with a body of its own, and the drawing prefixes it uses.
    private func document(body: String) throws -> WordDocument {
        var parts = Fixtures.parts(body: body)
        var xml = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        let declarations = [
            "xmlns:wp=\"\(OOXML.drawingNamespace)\"", "xmlns:a=\"\(OOXML.drawingMainNamespace)\"",
            "xmlns:wps=\"\(Self.wps)\"",
        ].joined(separator: " ")
        xml = xml.replacingOccurrences(of: "<w:document ", with: "<w:document \(declarations) ")
        parts["word/document.xml"] = Data(xml.utf8)
        return try DOCXReader.document(fromParts: parts)
    }

    private func floatingShape(wrap: String) -> String {
        """
        <w:p><w:r><w:drawing><wp:anchor behindDoc="0">\
        <wp:positionH relativeFrom="margin"><wp:align>left</wp:align></wp:positionH>\
        <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>\
        <wp:extent cx="1270000" cy="635000"/>\(wrap)<wp:docPr id="3" name="Rectangle 3"/>\
        <a:graphic><a:graphicData uri="\(Self.wps)"><wps:wsp><wps:spPr><a:prstGeom prst="rect"/></wps:spPr>\
        <wps:bodyPr/></wps:wsp></a:graphicData></a:graphic>\
        </wp:anchor></w:drawing></w:r><w:r><w:t>Words beside it.</w:t></w:r></w:p>
        """
    }

    @Test("A document using neither says nothing")
    func plain() throws {
        let document = try Fixtures.document()
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
    }

    @Test("A section in two columns is not noticed: it is drawn in two")
    func columns() throws {
        let section = """
            <w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:cols w:num="2" w:space="720"/></w:sectPr></w:pPr>\
            <w:r><w:t>In two columns</w:t></w:r></w:p>
            """
        let document = try document(body: section)
        #expect(document.unsupportedFeatures.isEmpty)
    }

    @Test("Tight, through and square wrapping are drawn as Word does, so none is noticed", arguments: [
        "<wp:wrapTight wrapText=\"bothSides\"><wp:wrapPolygon edited=\"0\"><wp:start x=\"0\" y=\"0\"/></wp:wrapPolygon></wp:wrapTight>",
        "<wp:wrapThrough wrapText=\"bothSides\"><wp:wrapPolygon edited=\"0\"><wp:start x=\"0\" y=\"0\"/></wp:wrapPolygon></wp:wrapThrough>",
        "<wp:wrapSquare wrapText=\"bothSides\"/>",
    ])
    func wrapping(wrap: String) throws {
        let document = try document(body: floatingShape(wrap: wrap))
        let floats = document.allParagraphs.flatMap(\.inlines).contains {
            if case .image(let image) = $0.content { return image.isFloating } else { return false }
        }
        #expect(floats)
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
    }

    @Test("What is drawn differently is told apart from what is read-only, each in order")
    func split() {
        let report = UnsupportedFeatureReport(features: [.simplifiedObjects, .macros, .shapes])
        #expect(report.readOnlyFeatures == [.macros, .shapes])
        #expect(report.drawnDifferentlyFeatures == [.simplifiedObjects])
        #expect(!report.isEmpty)
        for feature in UnsupportedFeatureReport.Feature.allCases {
            #expect(!feature.label.hasPrefix("Unsupported."), "\(feature) has no words of its own")
        }
    }

    @Test("Shape properties drawn more simply are told apart from those drawn as Word does", arguments: [
        ("<wps:spPr><a:prstGeom prst=\"rect\"/><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></wps:spPr><wps:bodyPr/>", false),
        ("<wps:spPr><a:prstGeom prst=\"rect\"/><a:effectLst/></wps:spPr><wps:bodyPr/>", false),
        ("<wps:spPr><a:xfrm rot=\"5400000\"/><a:prstGeom prst=\"rect\"/></wps:spPr><wps:bodyPr/>", true),
        ("<wps:spPr><a:prstGeom prst=\"heart\"/></wps:spPr><wps:bodyPr/>", true),
        ("<wps:spPr><a:prstGeom prst=\"line\"/><a:ln><a:tailEnd type=\"triangle\"/></a:ln></wps:spPr><wps:bodyPr/>", true),
        ("<wps:spPr><a:prstGeom prst=\"rect\"/><a:ln><a:prstDash val=\"dash\"/></a:ln></wps:spPr><wps:bodyPr/>", true),
        ("<wps:spPr><a:prstGeom prst=\"rect\"/></wps:spPr><wps:bodyPr vert=\"vert270\"/>", true),
        ("<wps:spPr><a:prstGeom prst=\"rect\"/></wps:spPr><wps:linkedTxbx id=\"1\" seq=\"1\"/><wps:bodyPr/>", false),
    ])
    func simplifiedShapes(content: String, simplified: Bool) throws {
        let shape = try XMLLite.parse(Data("<wps:wsp xmlns:wps=\"\(Self.wps)\" xmlns:a=\"\(OOXML.drawingMainNamespace)\">\(content)</wps:wsp>".utf8))
        #expect(DrawingObjectReader.isSimplified(shape: shape) == simplified)
    }
}
