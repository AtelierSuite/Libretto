import Foundation
import Testing
import UIKit
@testable import LibrettoEngine

@MainActor
@Suite("Columns")
struct ColumnTests {
    private static let words = "The quick brown fox jumps over the lazy dog while the band plays on into the night."

    /// Paragraphs of words, enough to run over several pages in one column.
    private func paragraphs(_ count: Int, prefix: String = "P") -> [Block] {
        (0..<count).map { .paragraph(Paragraph(text: "\(prefix)\($0) " + Array(repeating: Self.words, count: 3).joined(separator: " "))) }
    }

    private struct Laid {
        let storage: NSTextStorage
        let layout: PageLayoutManager
        let container: PageTextContainer
        let pages: Int

        func line(of text: String) -> CGRect {
            let location = (storage.string as NSString).range(of: text).location
            precondition(location != NSNotFound, "\(text) is not in the text")
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
        }

        func page(of text: String) -> Int { layout.geometry.page(containing: line(of: text).midY) }
    }

    private func layOut(_ document: WordDocument) -> Laid {
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let storage = NSTextStorage(
            attributedString: DocumentRenderer.render(document.body, context: context, finalSection: document.pageSetup).string
        )
        let layout = PageLayoutManager(geometry: PageGeometry(setup: document.pageSetup, gap: 20))
        layout.styles = document.styles
        layout.sections = SectionLayout.spans(in: storage, final: document.pageSetup)
        let container = PageTextContainer()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let pages = layout.layOutPages(in: container, startingWith: 1)
        return Laid(storage: storage, layout: layout, container: container, pages: pages)
    }

    private func document(_ body: [Block], columns: Int, spacing: Int = 720) -> WordDocument {
        var document = WordDocument()
        document.body = body
        document.pageSetup.columns = columns
        document.pageSetup.columnSpacing = spacing
        return document
    }

    @Test("Equal columns share the text's width, the spacing between them")
    func equalFrames() {
        var setup = PageSetup()
        setup.columns = 2
        setup.columnSpacing = 720
        let frames = setup.columnFrames(width: 468)
        #expect(frames.count == 2)
        #expect(frames[0].x == 0 && frames[0].width == 216)
        #expect(frames[1].x == 252 && frames[1].width == 216)
        setup.columns = 1
        #expect(setup.columnFrames(width: 468).count == 1)
    }

    @Test("Columns of their own widths keep them, each with its own space after")
    func unequalFrames() {
        var setup = PageSetup()
        setup.columnSizes = [.init(width: 2880, space: 360), .init(width: 5760, space: 0)]
        setup.columns = 2
        let frames = setup.columnFrames(width: 468)
        #expect(frames.map(\.x) == [0, 162])
        #expect(frames.map(\.width) == [144, 288])
        // Too wide for the page: narrowed in proportion.
        let narrow = setup.columnFrames(width: 225)
        #expect(abs(narrow[1].x + narrow[1].width - 225) < 0.01)
    }

    @Test("Columns of their own widths are read from the section, and written back as they were")
    func readsUnequal() throws {
        let body = """
            <w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:cols w:num="2" w:space="720" w:equalWidth="0">\
            <w:col w:w="3000" w:space="500"/><w:col w:w="5140"/></w:cols></w:sectPr></w:pPr>\
            <w:r><w:t>Text</w:t></w:r></w:p>
            """
        let document = try DOCXReader.document(fromParts: Fixtures.parts(body: body))
        let section = try #require(document.allParagraphs.first?.section)
        #expect(section.columns == 2)
        #expect(section.columnSizes == [.init(width: 3000, space: 500), .init(width: 5140, space: 0)])
        let xml = Fixtures.text(try Fixtures.written(document), "word/document.xml")
        #expect(xml.contains("<w:col w:space=\"500\" w:w=\"3000\"/><w:col w:w=\"5140\"/>"))
    }

    @Test("Text in two columns runs down the first, then the second, at the column's width")
    func twoColumns() {
        let body = paragraphs(30)
        let single = layOut(document(body, columns: 1))
        let laid = layOut(document(body, columns: 2))
        let frames = laid.layout.columnFrames(section: 0, page: 0)
        #expect(frames.count == 2)
        #expect(abs(frames[1].minX - frames[0].maxX - 36) < 0.01)

        // The first paragraph starts the first column; text later on the page is in the second.
        let first = laid.line(of: "P0 ")
        #expect(abs(first.minX - frames[0].minX) < 0.5)
        #expect(abs(first.width - frames[0].width) < 0.5)
        var inSecond: CGRect?
        laid.layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: laid.layout.numberOfGlyphs)) { rect, _, _, _, stop in
            if laid.layout.geometry.page(containing: rect.midY) == 0, abs(rect.minX - frames[1].minX) < 0.5 {
                inSecond = rect
                stop.pointee = true
            }
        }
        let second = try? #require(inSecond)
        // The second column starts at the top of the page's text.
        #expect(second.map { abs($0.minY - laid.layout.geometry.textTop(0)) < 1 } == true)
        // Narrower columns hold the same text in about as many pages, not twice as many.
        #expect(single.pages > 2)
        #expect(laid.pages <= single.pages + 1)
    }

    @Test("A column break starts the next column, and after the last column the next page")
    func columnBreaks() {
        let body: [Block] = [
            .paragraph(Paragraph(inlines: [Inline(.text("Left")), Inline(.columnBreak), Inline(.text("Right"))])),
            .paragraph(Paragraph(inlines: [Inline(.text("More")), Inline(.columnBreak)])),
            .paragraph(Paragraph(text: "Over")),
        ]
        let laid = layOut(document(body, columns: 2))
        let frames = laid.layout.columnFrames(section: 0, page: 0)
        #expect(laid.page(of: "Left") == 0)
        #expect(abs(laid.line(of: "Left").minX - frames[0].minX) < 0.5)
        #expect(laid.page(of: "Right") == 0)
        #expect(abs(laid.line(of: "Right").minX - frames[1].minX) < 0.5)
        #expect(abs(laid.line(of: "Right").minY - laid.layout.geometry.textTop(0)) < 1)
        #expect(laid.page(of: "Over") == 1)
        #expect(abs(laid.line(of: "Over").minX - frames[0].minX) < 0.5)
        #expect(laid.pages == 2)
    }

    @Test("A column break in one column still ends the page")
    func columnBreakInOneColumn() {
        let body: [Block] = [
            .paragraph(Paragraph(inlines: [Inline(.text("Left")), Inline(.columnBreak), Inline(.text("Right"))])),
        ]
        let laid = layOut(document(body, columns: 1))
        #expect(laid.page(of: "Right") == 1)
    }

    @Test("Columns before a continuous section are balanced, and the next section starts below them")
    func balanced() {
        var heading = Paragraph(text: "Heading")
        var oneColumn = PageSetup()
        oneColumn.columns = 1
        heading.section = oneColumn
        var last = Paragraph(text: "LastOfColumns")
        var twoColumns = PageSetup()
        twoColumns.columns = 2
        twoColumns.start = .continuous
        last.section = twoColumns
        var after = PageSetup()
        after.start = .continuous
        var document = WordDocument()
        document.body = [.paragraph(heading)] + paragraphs(4) + [.paragraph(last), .paragraph(Paragraph(text: "Below"))]
        document.pageSetup = after
        let laid = layOut(document)

        #expect(laid.pages == 1)
        let frames = laid.layout.columnFrames(section: 1, page: 0)
        var bottoms: [CGFloat] = [0, 0]
        let start = (laid.storage.string as NSString).range(of: "P0 ").location
        let end = (laid.storage.string as NSString).range(of: "LastOfColumns").location
        let glyphs = laid.layout.glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
        laid.layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            let column = abs(rect.minX - frames[1].minX) < 0.5 ? 1 : 0
            bottoms[column] = max(bottoms[column], rect.maxY)
        }
        // Both columns hold text, ending within a couple of lines of each other, the first the longer.
        #expect(bottoms[0] > 0 && bottoms[1] > 0)
        #expect(bottoms[0] >= bottoms[1] && bottoms[0] - bottoms[1] < 48)
        // The heading above runs the page's width; the text after starts below both columns.
        #expect(laid.line(of: "Heading").width > frames[0].width * 1.5)
        let below = laid.line(of: "Below")
        #expect(below.minY >= max(bottoms[0], bottoms[1]) - 0.5)
        #expect(below.width > frames[0].width * 1.5)
    }

    @Test("A point in the second column finds the text there")
    func hitTesting() {
        let body: [Block] = [
            .paragraph(Paragraph(inlines: [Inline(.text("Left")), Inline(.columnBreak), Inline(.text("Right side"))])),
        ]
        let laid = layOut(document(body, columns: 2))
        let right = laid.line(of: "Right")
        let point = CGPoint(x: right.minX + 1, y: right.midY)
        let index = laid.layout.characterIndex(for: point, in: laid.container, fractionOfDistanceBetweenInsertionPoints: nil)
        #expect(index == (laid.storage.string as NSString).range(of: "Right").location)
        let left = laid.line(of: "Left")
        let leftIndex = laid.layout.characterIndex(
            for: CGPoint(x: left.minX + 1, y: left.midY), in: laid.container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        #expect(leftIndex == 0)
    }

    @Test("A picture in a column fits the column")
    func pictureWidth() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        var document = document([], columns: 2)
        let id = document.package.unusedRelationshipID()
        document.package.addedMedia[id] = DocumentPackage.AddedMedia(
            path: "word/media/picture.png", data: image, fileExtension: "png", contentType: "image/png"
        )
        document.body = [.paragraph(Paragraph(inlines: [Inline(.image(InlineImage(relationshipID: id, width: 400, height: 200)))]))]
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let string = DocumentRenderer.render(document.body, context: context, finalSection: document.pageSetup).string
        let attachment = try #require(string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let column = document.pageSetup.columnFrames(width: document.pageSetup.contentWidth)[0].width
        #expect(attachment.bounds.width <= CGFloat(column) + 0.5)
    }

    @Test("A PDF of text in two columns has about as many pages as in one")
    func pdf() throws {
        let body = paragraphs(30)
        func pages(_ columns: Int) throws -> Int {
            let data = PDFExporter.data(from: document(body, columns: columns))
            return try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!)).numberOfPages
        }
        let one = try pages(1)
        let two = try pages(2)
        #expect(one > 2)
        #expect(two <= one + 1)
    }
}
