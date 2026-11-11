import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

/// Line heights and paragraph spacing laid out in pages as Word lays them out.
@Suite("Spacing as Word spaces lines")
struct WordSpacingTests {
    /// A document laid out in pages, as the page view and PDF lay it out.
    struct Laid {
        var storage: NSTextStorage
        var layoutManager: PageLayoutManager
        var container: NSTextContainer
        var pages: Int

        /// Where the line holding `text` is: its page, its line fragment, and its first glyph's baseline.
        func line(of text: String) -> (page: Int, rect: CGRect, used: CGRect, baseline: CGFloat) {
            let location = (storage.string as NSString).range(of: text).location
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            var used = CGRect.zero
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: glyph, length: 1)) { _, usedRect, _, _, stop in
                used = usedRect
                stop.pointee = true
            }
            let baseline = layoutManager.location(forGlyphAt: glyph).y
            return (layoutManager.geometry.page(containing: used.midY), rect, used, baseline)
        }

        /// The page each paragraph starts on, by its index.
        func pages(ofParagraphs count: Int) -> [Int] {
            (0..<count).map { line(of: "Paragraph \($0)" + ($0 < count - 1 ? "\n" : "")).page }
        }
    }

    static func layOut(_ document: WordDocument) -> Laid {
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let storage = NSTextStorage(attributedString: DocumentRenderer.render(document.body, context: context).string)
        let layoutManager = PageLayoutManager(geometry: PageGeometry(setup: document.pageSetup, gap: 20))
        layoutManager.styles = document.styles
        layoutManager.sections = SectionLayout.spans(in: storage, final: document.pageSetup)
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pages = layoutManager.layOutPages(in: container, startingWith: 1)
        return Laid(storage: storage, layoutManager: layoutManager, container: container, pages: pages)
    }

    /// One-line paragraphs of exact height, on pages with `textHeight` points of text each.
    static func document(
        count: Int, line: Int, before: Int = 0, after: Int = 0, textHeight: Int, rule: LineSpacing.Rule = .exact,
        widowControl: Bool? = nil
    ) -> WordDocument {
        var document = WordDocument()
        document.pageSetup.width = 8000
        document.pageSetup.height = textHeight * 20 + 1440
        document.pageSetup.marginTop = 720
        document.pageSetup.marginBottom = 720
        document.body = (0..<count).map { index in
            var properties = ParagraphProperties()
            properties.spacingBefore = before * 20
            properties.spacingAfter = after * 20
            properties.lineSpacing = LineSpacing(line: line * 20, rule: rule)
            properties.widowControl = widowControl
            return .paragraph(Paragraph(inlines: [Inline(.text("Paragraph \(index)"))], properties: properties))
        }
        return document
    }

    /// The page each paragraph starts on in Word, for one-line paragraphs of
    /// exact height: a line goes on the page if it and the space before it
    /// fit; the space after it may run off the page's foot; and a page the
    /// text flows on to starts without the space before its first paragraph.
    static func wordPages(count: Int, line: Int, before: Int, after: Int, textHeight: Int) -> [Int] {
        var page = 0
        var y = 0
        return (0..<count).map { _ in
            if y + before + line > textHeight {
                page += 1
                y = line + after
            } else {
                y += before + line + after
            }
            return page
        }
    }

    /// Layouts Word's pagination is measured against: line, space before and
    /// after, in points, and each page's height of text.
    static let measured: [(line: Int, before: Int, after: Int, textHeight: Int)] = [
        (20, 0, 10, 110), (14, 12, 0, 200), (14, 6, 8, 500), (14, 0, 8, 698), (12, 12, 12, 698), (18, 0, 6, 400),
    ]

    /// One-line paragraphs, so widow control, which keeps two lines together, changes nothing in Word.
    @Test("Paragraphs start the same pages Word starts them on", arguments: measured.indices, [false, true])
    func pagination(_ index: Int, widowControl: Bool) {
        let (line, before, after, textHeight) = Self.measured[index]
        let count = 150
        let laid = Self.layOut(Self.document(
            count: count, line: line, before: before, after: after, textHeight: textHeight, widowControl: widowControl
        ))
        let pages = laid.pages(ofParagraphs: count)
        let word = Self.wordPages(count: count, line: line, before: before, after: after, textHeight: textHeight)
        let drifted = zip(pages, word).filter { $0 != $1 }.count
        print("PAGINATION widow control \(widowControl) line \(line) before \(before) after \(after) height \(textHeight): "
            + "Word \(word.last! + 1) pages, Libretto \(pages.last! + 1); \(drifted) of \(count) paragraphs on another page")
        #expect(pages == word)
    }

    @Test("The space after a paragraph runs off the foot of the page")
    func spaceAfterAtFoot() {
        // Three lines and their space after take 90 points; the fourth line fits in the 20 left, its space after does not.
        let laid = Self.layOut(Self.document(count: 5, line: 20, after: 10, textHeight: 110))
        #expect(laid.line(of: "Paragraph 3").page == 0)
        #expect(laid.line(of: "Paragraph 4").page == 1)
        #expect(abs(laid.line(of: "Paragraph 4").used.minY - laid.layoutManager.geometry.textTop(1)) < 0.5)
    }

    @Test("A page the text flows on to starts without the space before its first paragraph")
    func spaceBeforeAtTop() throws {
        let laid = Self.layOut(Self.document(count: 12, line: 14, before: 12, textHeight: 200))
        let geometry = laid.layoutManager.geometry
        // The first page keeps it.
        #expect(abs(laid.line(of: "Paragraph 0").used.minY - geometry.textTop(0) - 12) < 0.5)
        let first = (0..<12).first { laid.line(of: "Paragraph \($0)\n").page == 1 }
        let top = laid.line(of: "Paragraph \(try #require(first))\n")
        #expect(abs(top.used.minY - geometry.textTop(1)) < 0.5)
        #expect(abs(top.baseline - top.used.height * 0.8) < 0.5)
    }

    @Test("A page break keeps the space before the paragraph after it")
    func spaceBeforeAfterPageBreak() throws {
        var document = Self.document(count: 3, line: 14, before: 12, textHeight: 200)
        document.body.insert(.paragraph(Paragraph(inlines: [Inline(.pageBreak)])), at: 1)
        let laid = Self.layOut(document)
        let line = laid.line(of: "Paragraph 1")
        #expect(line.page == 1)
        #expect(abs(line.used.minY - laid.layoutManager.geometry.textTop(1) - 12) < 0.5)
    }

    @Test("A line of exact height has its baseline four fifths of the way down")
    func exactBaseline() {
        for height in [8, 14, 30] {
            let laid = Self.layOut(Self.document(count: 2, line: height, textHeight: 400))
            let line = laid.line(of: "Paragraph 1")
            #expect(abs(line.used.height - CGFloat(height)) < 0.01)
            #expect(abs(line.baseline - CGFloat(height) * 0.8) < 0.01, "exactly \(height) points")
        }
    }

    @Test("A line at least so high is that high, or as high as its text if that is higher")
    func atLeast() {
        let tall = Self.layOut(Self.document(count: 2, line: 30, textHeight: 400, rule: .atLeast)).line(of: "Paragraph 1")
        #expect(abs(tall.used.height - 30) < 0.01)
        let short = Self.layOut(Self.document(count: 2, line: 4, textHeight: 400, rule: .atLeast)).line(of: "Paragraph 1")
        #expect(short.used.height > 10)
    }
}
