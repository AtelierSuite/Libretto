import Foundation
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

@MainActor
@Suite("Character and paragraph formatting")
struct FormattingTests {
    private func makeController(text: String) -> (DocumentTextController, EditorState, () -> WordDocument?) {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: text))]
        let controller = DocumentTextController(document: document, scheme: .light)
        let state = EditorState()
        controller.state = state
        state.controller = controller
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, state, { latest })
    }

    private func firstParagraph(_ document: WordDocument?) -> Paragraph? {
        guard case .paragraph(let paragraph)? = document?.body.first else { return nil }
        return paragraph
    }

    private func xml(_ document: WordDocument) throws -> String {
        String(decoding: try ZipArchive.entries(in: DOCXWriter.data(from: document))["word/document.xml"]!, as: UTF8.self)
    }

    @Test("Underline kinds, effects, spacing and position are written and read back")
    func effects() throws {
        let (controller, state, latest) = makeController(text: "Fine print")
        controller.textView.selectedRange = NSRange(location: 0, length: 4)
        controller.setUnderline("double")
        controller.setEffect(\.smallCaps, true)
        controller.setEffect(\.isDoubleStruckThrough, true)
        controller.setEffect(\.outline, true)
        controller.setCharacterSpacing(30)
        controller.setPosition(-4)
        #expect(state.selectionFormat.underlineKind == "double")
        #expect(state.selectionFormat.smallCaps)

        let document = try #require(latest())
        let style = try #require(firstParagraph(document)?.inlines.first?.format.style)
        #expect(style.underline == true && style.underlineStyle == "double")
        let written = try xml(document)
        #expect(written.contains("<w:rPr><w:smallCaps/><w:dstrike/><w:outline/><w:spacing w:val=\"30\"/><w:position w:val=\"-4\"/><w:u w:val=\"double\"/></w:rPr>"))

        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(firstParagraph(reread)?.inlines.first?.format.style == style)

        controller.setUnderline("none")
        #expect(firstParagraph(latest())?.inlines.first?.format.style.underline == nil)
    }

    @Test("Page breaking settings, borders, shading and tab stops are written and read back")
    func paragraphSettings() throws {
        let (controller, state, latest) = makeController(text: "Total\t12.5")
        controller.setParagraphFlag(\.keepNext, true)
        controller.setParagraphFlag(\.widowControl, true)
        let line = BorderLine(style: "double", size: 6, colorHex: "FF0000", space: 4)
        controller.setBorders(ParagraphBorders(top: line, bottom: line))
        controller.setShading("FFEEEEEE")
        controller.setTabStops([TabStop(position: 4320, alignment: .decimal, leader: "dot")])
        #expect(state.selectionFormat.keepNext)
        #expect(state.selectionFormat.tabStops.first?.leader == "dot")

        let document = try #require(latest())
        let written = try xml(document)
        #expect(written.contains("<w:keepNext/><w:widowControl/><w:pBdr>"))
        #expect(written.contains("<w:top w:color=\"FF0000\" w:space=\"4\" w:sz=\"6\" w:val=\"double\"/>"))
        #expect(written.contains("<w:shd w:color=\"auto\" w:fill=\"EEEEEE\" w:val=\"clear\"/>"))
        #expect(written.contains("<w:tabs><w:tab w:leader=\"dot\" w:pos=\"4320\" w:val=\"decimal\"/></w:tabs>"))

        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(firstParagraph(reread)?.properties == firstParagraph(document)?.properties)
        let paragraphStyle = controller.textView.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        #expect(paragraphStyle?.tabStops.first?.location == 216)
    }

    @Test("Tabs past a paragraph's own stops fall at the document's default interval")
    func defaultTabStop() throws {
        let body = "<w:p><w:r><w:t xml:space=\"preserve\">a\tb\tc</w:t></w:r></w:p>"
        let document = try DOCXReader.document(fromParts: Fixtures.parts(body: body, settings: "<w:defaultTabStop w:val=\"567\"/>"))
        #expect(document.defaultTabStop == 567)
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let style = Typography.paragraphStyle(ParagraphProperties(), context: context, isListItem: false)
        #expect(abs(style.defaultTabInterval - 28.35) < 0.001)

        let plain = try DOCXReader.document(fromParts: Fixtures.parts(body: body))
        #expect(RenderContext(document: plain, scheme: .light, images: ImageStore()).defaultTabInterval == 36)
    }

    @Test("Paragraphs of a style with contextual spacing drop the space between each other")
    func contextualSpacing() throws {
        var document = WordDocument()
        document.body = [
            .paragraph(Paragraph(text: "Intro")),
            .paragraph(Paragraph(text: "One", styleID: "ListParagraph")),
            .paragraph(Paragraph(text: "Two", styleID: "ListParagraph")),
            .paragraph(Paragraph(text: "Three", styleID: "ListParagraph")),
            .paragraph(Paragraph(text: "After")),
        ]
        let resolved = document.styles.resolvedParagraphProperties(ParagraphProperties(styleID: "ListParagraph"))
        #expect(resolved.contextualSpacing == true)
        let after = CGFloat(resolved.spacingAfter ?? 0) / 20
        #expect(after > 0)

        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let storage = NSMutableAttributedString(attributedString: DocumentRenderer.render(document.body, context: context).string)
        func spacing(_ text: String) -> (before: CGFloat, after: CGFloat) {
            let location = (storage.string as NSString).range(of: text).location
            let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return (style?.paragraphSpacingBefore ?? -1, style?.paragraphSpacing ?? -1)
        }
        #expect(spacing("Intro").after == after)
        #expect(spacing("One").after == 0)
        #expect(spacing("Two").after == 0)
        #expect(spacing("Three").after == after)

        // Restyling the last item as body text gives the one before it its space back.
        let three = (storage.string as NSString).range(of: "Three")
        storage.addAttribute(.librettoParagraph, value: ParagraphBox(Paragraph(text: "Three")), range: NSRange(location: three.location, length: 6))
        DocumentRenderer.restyle(storage, paragraphsIn: three, finalParagraph: Paragraph(text: "After"), context: context)
        #expect(spacing("Two").after == after)
    }

    @Test("Contextual spacing is read and written back")
    func contextualSpacingRoundTrip() throws {
        var document = WordDocument()
        document.body = [.paragraph(Paragraph(text: "Item"))]
        guard case .paragraph(var paragraph) = document.body[0] else { return }
        paragraph.properties.contextualSpacing = true
        document.body[0] = .paragraph(paragraph)
        let reread = try DOCXReader.document(from: DOCXWriter.data(from: document))
        #expect(try xml(document).contains("<w:contextualSpacing/>"))
        guard case .paragraph(let read) = reread.body.first else { Issue.record("No paragraph"); return }
        #expect(read.properties.contextualSpacing == true)
    }

    @Test("Hidden text is read, kept, takes no room on the page and is left out of the word count")
    func hiddenText() throws {
        let body = """
            <w:p><w:r><w:t xml:space="preserve">Shown </w:t></w:r>\
            <w:r><w:rPr><w:vanish/></w:rPr><w:t xml:space="preserve">secret words here </w:t></w:r>\
            <w:r><w:t>end</w:t></w:r></w:p>
            """
        let document = try DOCXReader.document(fromParts: Fixtures.parts(body: body))
        guard case .paragraph(let paragraph) = document.body.first else { Issue.record("No paragraph"); return }
        #expect(paragraph.inlines.map(\.format.style.isHidden) == [nil, true, nil])
        #expect(document.wordCount == 2)

        let visible = try DOCXReader.document(fromParts: Fixtures.parts(
            body: "<w:p><w:r><w:t xml:space=\"preserve\">Shown end</w:t></w:r></w:p>"
        ))
        let laid = WordSpacingTests.layOut(document)
        let plain = WordSpacingTests.layOut(visible)
        func endX(_ laid: WordSpacingTests.Laid) -> CGFloat {
            let location = (laid.storage.string as NSString).range(of: "end").location
            return laid.layoutManager.location(forGlyphAt: laid.layoutManager.glyphIndexForCharacter(at: location)).x
        }
        #expect(abs(endX(laid) - endX(plain)) < 0.5)

        #expect(Fixtures.text(try Fixtures.written(document), "word/document.xml").contains("<w:vanish/>"))

        // In a table cell too.
        let cell = TableCell(blocks: [document.body[0]])
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        #expect(TableRenderer.cellText(cell, context: context).string == "Shown end")
    }

    @Test("A style's tab stop the paragraph does without is cleared")
    func clearsStyleTabs() {
        let style = ParagraphProperties(tabStops: [TabStop(position: 720), TabStop(position: 1440)])
        let own = ParagraphProperties(tabStops: [TabStop(position: 720, alignment: .clear), TabStop(position: 2160, alignment: .right)])
        #expect(style.merged(with: own).tabStops == [TabStop(position: 1440), TabStop(position: 2160, alignment: .right)])
    }

    @Test("A heading kept with the next paragraph goes over to the next page with it")
    func keepsWithNext() throws {
        func pages(filler count: Int, keep: Bool) -> (heading: Int, body: Int) {
            var document = WordDocument()
            var heading = Paragraph(text: "Heading")
            heading.properties.keepNext = keep
            document.body = (0..<count).map { Block.paragraph(Paragraph(text: "Line \($0)")) }
                + [.paragraph(heading), .paragraph(Paragraph(text: "Body after the heading."))]
            let controller = DocumentTextController(document: document, scheme: .light)
            let layout = controller.layoutManager
            let text = controller.textView.textStorage.string as NSString
            func page(of string: String) -> Int {
                let glyph = layout.glyphIndexForCharacter(at: text.range(of: string).location)
                return controller.geometry.page(containing: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).midY)
            }
            return (page(of: "Heading"), page(of: "Body after"))
        }
        // Enough lines that, left to itself, the heading ends the first page, alone.
        let count = try #require((20..<80).first { pages(filler: $0, keep: false) == (0, 1) })
        #expect(pages(filler: count, keep: true) == (1, 1))
    }

    @Test("A drop cap is a paragraph of its own, which the next one's first lines go around")
    func dropCap() throws {
        let long = String(repeating: "Once upon a time there was a story that ran on for line after line. ", count: 6)
        let (controller, state, latest) = makeController(text: long)
        controller.textView.selectedRange = NSRange(location: 10, length: 0)
        controller.setDropCap(DropCap(inMargin: false, lines: 3))
        #expect(state.selectionFormat.dropCap == nil)

        let document = try #require(latest())
        guard case .paragraph(let letter) = document.body[0], case .paragraph(let rest) = document.body[1] else {
            Issue.record("expected two paragraphs")
            return
        }
        #expect(letter.plainText == "O")
        #expect(letter.properties.dropCap == DropCap(inMargin: false, lines: 3))
        #expect(rest.plainText.hasPrefix("nce upon"))
        #expect(try xml(document).contains("<w:framePr w:dropCap=\"drop\" w:hAnchor=\"text\" w:lines=\"3\""))

        let layout = controller.layoutManager
        let cap = try #require(layout.dropCaps.first)
        let exclusion = try #require(cap.exclusion)
        // The first lines start past the letter; the fourth is back at the margin.
        let lines = (0..<4).map { index -> CGRect in
            var rects: [CGRect] = []
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, used, _, _, _ in
                if rect.height > 1 { rects.append(used) }
            }
            return rects[index]
        }
        #expect(lines[0].minX >= exclusion.maxX - 1)
        #expect(lines[2].minX >= exclusion.maxX - 1)
        #expect(lines[3].minX < 1)

        // Taking it away sets the letter back into its paragraph.
        controller.textView.selectedRange = NSRange(location: 5, length: 0)
        controller.setDropCap(nil)
        let restored = try #require(latest())
        #expect(restored.body.count == 1)
        guard case .paragraph(let whole) = restored.body[0] else { return }
        #expect(whole.plainText == long)
    }

    private func labels(_ document: WordDocument) -> [String] {
        var labeler = ListLabeler(context: RenderContext(document: document, scheme: .light, images: ImageStore()))
        return document.body.compactMap { block in
            guard case .paragraph(let paragraph) = block else { return nil }
            return labeler.label(for: paragraph.properties)?.text
        }
    }

    @Test("Lists take a preset's numbering, start over where asked, and carry on another list's")
    func lists() throws {
        var document = WordDocument()
        document.body = ["One", "Two", "Three", "Aside", "Four"].map { .paragraph(Paragraph(text: $0)) }
        let controller = DocumentTextController(document: document, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.textView.selectedRange = NSRange(location: 0, length: 13)
        controller.applyListPreset(.upperRoman)
        #expect(labels(try #require(latest)) == ["I.", "II.", "III."])

        controller.textView.selectedRange = NSRange(location: 8, length: 0)
        controller.restartNumbering(at: 5)
        #expect(labels(try #require(latest)) == ["I.", "II.", "V."])

        // "Four", in a list of its own, carries on the first.
        controller.textView.selectedRange = NSRange(location: 21, length: 0)
        controller.applyListPreset(.decimal)
        controller.continueNumbering()
        let continued = try #require(latest)
        #expect(labels(continued) == ["I.", "II.", "V.", "VI."])

        let parts = try ZipArchive.entries(in: DOCXWriter.data(from: continued))
        let numbering = String(decoding: try #require(parts["word/numbering.xml"]), as: UTF8.self)
        #expect(numbering.contains("<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"5\"/></w:lvlOverride>"))
        #expect(labels(try DOCXReader.document(fromParts: parts)) == ["I.", "II.", "V.", "VI."])
        #expect(ListPreset.legal.sample == "1.  1.1.  1.1.1.")
    }

    @Test("A changed style has only what changed patched into its definition")
    func modifiesStyle() throws {
        let document = try Fixtures.document()
        let controller = DocumentTextController(document: document, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        controller.modifyStyle("Heading1") { style in
            style.runStyle.colorHex = "C00000"
            style.runStyle.fontSize = 40
        }
        let changed = try #require(latest)
        let styles = String(decoding: try #require(try Fixtures.written(changed)["word/styles.xml"]), as: UTF8.self)
        #expect(styles.contains("<w:pPr><w:keepNext/><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"C00000\"/><w:sz w:val=\"40\"/><w:szCs w:val=\"40\"/></w:rPr>"))
        let reread = try DOCXReader.document(fromParts: try Fixtures.written(changed))
        #expect(reread.styles.resolvedRunStyle(RunStyle(), paragraphStyleID: "Heading1").colorHex == "C00000")
    }

    @Test("A style made from the selection takes on its formatting, and its paragraph goes in it")
    func createsStyle() throws {
        let (controller, _, latest) = makeController(text: "Pull quote")
        controller.setAlignment(.center)
        controller.textView.selectedRange = NSRange(location: 0, length: 10)
        controller.toggleItalic()
        controller.textView.selectedRange = NSRange(location: 3, length: 0)
        let id = controller.createStyleFromSelection(name: "Pull Quote")
        #expect(id == "PullQuote")

        let document = try #require(latest())
        let paragraph = try #require(firstParagraph(document))
        #expect(paragraph.properties.styleID == "PullQuote")
        #expect(paragraph.properties.alignment == nil)
        #expect(document.styles.resolvedParagraphProperties(paragraph.properties).alignment == .center)
        #expect(document.styles.styles["PullQuote"]?.runStyle.isItalic == true)

        let parts = try Fixtures.written(document)
        let styles = String(decoding: try #require(parts["word/styles.xml"]), as: UTF8.self)
        #expect(styles.contains("w:customStyle=\"1\" w:styleId=\"PullQuote\" w:type=\"paragraph\"><w:name w:val=\"Pull Quote\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:rPr><w:i/><w:iCs/></w:rPr>"))
        let reread = try DOCXReader.document(fromParts: parts)
        #expect(reread.styles.offeredParagraphStyles(using: []).contains { $0.id == "PullQuote" })
    }

    @Test("Text in capitals is drawn with capital glyphs, and keeps its letters")
    func allCaps() throws {
        let (controller, _, latest) = makeController(text: "abc")
        controller.textView.selectedRange = NSRange(location: 0, length: 3)
        controller.setEffect(\.allCaps, true)
        #expect(firstParagraph(latest())?.plainText == "abc")

        let layout = controller.layoutManager
        layout.ensureLayout(for: layout.textContainers[0])
        let font = try #require(controller.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        var capital: UniChar = 0x41
        var expected = CGGlyph()
        _ = CTFontGetGlyphsForCharacters(font as CTFont, &capital, &expected, 1)
        #expect(layout.cgGlyph(at: 0) == expected)
    }
}
