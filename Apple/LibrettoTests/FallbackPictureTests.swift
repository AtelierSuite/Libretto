import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Objects Libretto can't draw as Word does: drawn from the picture the
/// document keeps of them where there is one, and otherwise named in the open notice.
@MainActor
@Suite("Fallback pictures and objects drawn more simply")
struct FallbackPictureTests {
    private static let wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    private static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    private static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    private static let chartType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"

    /// A small red PNG.
    private static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    }

    /// An EMF's first bytes, which not every platform draws.
    private static let emf = Data([0x01, 0x00, 0x00, 0x00, 0x6C, 0x00, 0x00, 0x00])

    /// The fixture package with a body of its own, extra parts, and relationships to them.
    private func document(body: String, extra: [String: Data] = [:], relationships: String = "") throws -> WordDocument {
        var parts = Fixtures.parts(body: body)
        for (path, data) in extra { parts[path] = data }
        var rels = String(decoding: parts["word/_rels/document.xml.rels"]!, as: UTF8.self)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: relationships + "</Relationships>")
        parts["word/_rels/document.xml.rels"] = Data(rels.utf8)
        var xml = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        let declarations = [
            "xmlns:wp=\"\(OOXML.drawingNamespace)\"", "xmlns:a=\"\(OOXML.drawingMainNamespace)\"",
            "xmlns:wps=\"\(Self.wps)\"", "xmlns:c=\"\(Self.chartURI)\"",
            "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"",
            "xmlns:cx=\"http://schemas.microsoft.com/office/drawing/2014/chartex\"",
            "xmlns:v=\"urn:schemas-microsoft-com:vml\"", "xmlns:o=\"urn:schemas-microsoft-com:office:office\"",
        ].joined(separator: " ")
        xml = xml.replacingOccurrences(of: "<w:document ", with: "<w:document \(declarations) ")
        parts["word/document.xml"] = Data(xml.utf8)
        return try DOCXReader.document(fromParts: parts)
    }

    private func pictureRelationship(_ id: String, target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(Self.imageType)\" Target=\"\(target)\"/>"
    }

    private func images(_ document: WordDocument) -> [InlineImage] {
        document.allParagraphs.flatMap(\.inlines).compactMap {
            if case .image(let image) = $0.content { return image } else { return nil }
        }
    }

    /// A picture drawing, as Word writes a fallback.
    private func pictureDrawing(_ id: String, cx: Int = 1_905_000, cy: Int = 1_270_000) -> String {
        """
        <w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="9" name="Picture 9"/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:blipFill><a:blip r:embed="\(id)"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
    }

    /// A shape with a gradient fill and a shadow, floating, centred.
    private let fancyShape = """
        <w:drawing><wp:anchor behindDoc="0"><wp:positionH relativeFrom="margin"><wp:align>center</wp:align></wp:positionH>\
        <wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV>\
        <wp:extent cx="2540000" cy="1270000"/><wp:wrapSquare wrapText="bothSides"/><wp:docPr id="3" name="Rectangle 3"/>\
        <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp><wps:spPr>\
        <a:prstGeom prst="rect"/><a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs>\
        <a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst></a:gradFill>\
        <a:effectLst><a:outerShdw blurRad="50800" dist="38100"><a:srgbClr val="000000"/></a:outerShdw></a:effectLst>\
        </wps:spPr><wps:bodyPr/></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing>
        """

    @Test("A chart Libretto can't read is drawn from the picture its fallback keeps, and written back whole")
    func chartExFallback() throws {
        let body = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="cx1"><w:drawing><wp:inline>\
            <wp:extent cx="2540000" cy="1905000"/><wp:docPr id="4" name="Chart 4"/><a:graphic>\
            <a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex"><cx:chart r:id="rIdChartEx"/>\
            </a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice><mc:Fallback>\(pictureDrawing("rIdFallback"))\
            </mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        let document = try document(
            body: body, extra: ["word/media/image1.png": Self.png],
            relationships: pictureRelationship("rIdFallback", target: "media/image1.png")
        )
        let picture = try #require(images(document).first)
        #expect(picture.isStandIn)
        #expect(picture.object == nil)
        #expect(picture.relationshipID == "rIdFallback")
        // The size is the chart's.
        #expect(picture.width == 200 && picture.height == 150)
        #expect(!document.unsupportedFeatures.features.contains(.shapes))
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))
        #expect(ImageStore().image(for: picture, in: document.package) != nil)

        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<cx:chart r:id=\"rIdChartEx\"/>"))
        #expect(xml.contains("<mc:Fallback>"))
    }

    @Test("A stand-in is written back as the object even when marked edited, and can't be resized")
    func standInKept() throws {
        let body = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="cx1"><w:drawing><wp:inline>\
            <wp:extent cx="2540000" cy="1905000"/><wp:docPr id="4" name="Chart 4"/><a:graphic>\
            <a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex"><cx:chart r:id="rIdChartEx"/>\
            </a:graphicData></a:graphic></wp:inline></w:drawing></mc:Choice><mc:Fallback>\(pictureDrawing("rIdFallback"))\
            </mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        var document = try document(
            body: body, extra: ["word/media/image1.png": Self.png],
            relationships: pictureRelationship("rIdFallback", target: "media/image1.png")
        )
        guard case .paragraph(var paragraph) = document.body[0], case .image(var picture) = paragraph.inlines[0].content else {
            Issue.record("no picture")
            return
        }
        picture.width = 50
        picture.isEdited = true
        paragraph.inlines[0].content = .image(picture)
        document.body[0] = .paragraph(paragraph)
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<mc:AlternateContent>"))
        #expect(xml.contains("cx=\"2540000\""))

        let controller = DocumentTextController(document: try self.document(
            body: body, extra: ["word/media/image1.png": Self.png],
            relationships: pictureRelationship("rIdFallback", target: "media/image1.png")
        ), scheme: .light)
        var changed = false
        controller.onChange = { _ in changed = true }
        let attachment = (0..<controller.storage.length).first {
            controller.storage.attribute(.attachment, at: $0, effectiveRange: nil) is ImageAttachment
        }
        controller.textView.selectedRange = NSRange(location: try #require(attachment), length: 1)
        #expect(controller.selectedImage?.image.isStandIn == true)
        controller.updateSelectedImage { $0.width = 20 }
        #expect(controller.selectedImage?.image.width == 200)
        #expect(!changed)
    }

    @Test("A shape with a gradient and shadow is drawn from its fallback picture, placed as the shape is")
    func shapeFallbackPicture() throws {
        let body = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps">\(fancyShape)</mc:Choice><mc:Fallback>\
            <w:pict><v:rect style="width:200pt;height:100pt"><v:imagedata r:id="rIdVML" o:title=""/></v:rect></w:pict>\
            </mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        let document = try document(
            body: body, extra: ["word/media/image2.png": Self.png],
            relationships: pictureRelationship("rIdVML", target: "media/image2.png")
        )
        let picture = try #require(images(document).first)
        #expect(picture.isStandIn)
        #expect(picture.relationshipID == "rIdVML")
        #expect(picture.isFloating)
        #expect(picture.wrap == .square)
        #expect(picture.alignment == .center)
        #expect(picture.width == 200 && picture.height == 100)
        #expect(!document.unsupportedFeatures.features.contains(.simplifiedObjects))
    }

    @Test("Without a picture to draw instead, the shape is drawn and the notice says it is drawn more simply")
    func shapeWithoutFallbackPicture() throws {
        let body = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps">\(fancyShape)</mc:Choice><mc:Fallback>\
            <w:pict><v:rect style="width:200pt;height:100pt"/></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        let document = try document(body: body)
        let picture = try #require(images(document).first)
        #expect(!picture.isStandIn)
        guard case .shape = picture.object else { Issue.record("not a shape"); return }
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures == [.simplifiedObjects])
    }

    @Test("A plain shape with a fallback picture is still drawn as a shape, and its text can change")
    func plainShapeKeepsShape() throws {
        let body = """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:inline>\
            <wp:extent cx="1270000" cy="635000"/><wp:docPr id="3" name="Oval 3"/><a:graphic>\
            <a:graphicData uri="\(Self.wps)"><wps:wsp><wps:spPr><a:prstGeom prst="ellipse"/>\
            <a:solidFill><a:srgbClr val="70AD47"/></a:solidFill></wps:spPr><wps:bodyPr/></wps:wsp></a:graphicData></a:graphic>\
            </wp:inline></w:drawing></mc:Choice><mc:Fallback>\
            <w:pict><v:oval style="width:100pt;height:50pt"><v:imagedata r:id="rIdVML"/></v:oval></w:pict>\
            </mc:Fallback></mc:AlternateContent></w:r></w:p>
            """
        let document = try document(
            body: body, extra: ["word/media/image2.png": Self.png],
            relationships: pictureRelationship("rIdVML", target: "media/image2.png")
        )
        let picture = try #require(images(document).first)
        #expect(!picture.isStandIn)
        #expect(picture.object != nil)
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
    }

    @Test("An embedded object is drawn from its preview when that is a picture every platform draws", arguments: [true, false])
    func embeddedObjectPreview(isPNG: Bool) throws {
        let body = """
            <w:p><w:r><w:object w:dxaOrig="2880" w:dyaOrig="1440"><v:shape style="width:2in;height:1in">\
            <v:imagedata r:id="rIdPreview" o:title=""/></v:shape>\
            <o:OLEObject Type="Embed" ProgID="Excel.Sheet.12" ShapeID="_x0000_i1025" r:id="rIdOle"/></w:object></w:r></w:p>
            """
        let document = try document(
            body: body, extra: ["word/media/image3.\(isPNG ? "png" : "emf")": isPNG ? Self.png : Self.emf],
            relationships: pictureRelationship("rIdPreview", target: "media/image3.\(isPNG ? "png" : "emf")")
        )
        #expect(document.unsupportedFeatures.features.contains(.embeddedObjects))
        if isPNG {
            let picture = try #require(images(document).first)
            #expect(picture.isStandIn)
            #expect(picture.width == 144 && picture.height == 72)
            #expect(!picture.isFloating)
        } else {
            #expect(images(document).isEmpty)
        }
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("ProgID=\"Excel.Sheet.12\""))
    }

    @Test("Only pictures every platform draws stand in")
    func rasterPictures() {
        #expect(DrawingObjectReader.isRasterPicture(Self.png))
        #expect(DrawingObjectReader.isRasterPicture(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(!DrawingObjectReader.isRasterPicture(Self.emf))
        #expect(!DrawingObjectReader.isRasterPicture(Data()))
    }
}
