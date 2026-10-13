import Foundation
import Testing
@testable import Libretto

/// Reads `Sample.pages`, which Pages saved from a Word document with a
/// heading, mixed formatting, lists, a footnote, a table, a picture, a page
/// break, and a header and footer.
@Suite("Pages")
struct PagesTests {
    /// The test target copies no resources; the simulator reads the file from the source tree.
    private static let data = try! Data(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Sample.pages")
    )

    private static let document = try! PagesReader.document(from: data)

    private var paragraphs: [Paragraph] {
        Self.document.body.compactMap { if case .paragraph(let paragraph) = $0 { paragraph } else { nil } }
    }

    private func paragraph(startingWith prefix: String) -> Paragraph {
        paragraphs.first { $0.plainText.hasPrefix(prefix) }!
    }

    @Test("The body text reads paragraph by paragraph")
    func text() {
        #expect(Self.document.importedFormat == .pages)
        #expect(paragraphs.map(\.plainText) == [
            "Quarterly Report",
            "This is a bold word, an italic word, underlined text and struck text.",
            "Centred paragraph in red and large and Courier and H2O.",
            "Second Heading",
            "First bullet", "Nested bullet", "Second bullet",
            "Step one", "Step two",
            "Right aligned. Café — naïve 日本語 😀",
            "Indented, spaced paragraph with a footnote.",
            "Picture:  line\nafter break.",
            "",
            "Second page paragraph.",
            "Final paragraph.",
        ])
    }

    @Test("Character formatting comes across as direct formatting")
    func characters() {
        func style(of word: String, in paragraph: Paragraph) -> RunStyle? {
            paragraph.inlines.first { $0.plainText == word }?.format.style
        }
        let mixed = paragraph(startingWith: "This is")
        #expect(style(of: "bold", in: mixed)?.isBold == true)
        #expect(style(of: "italic", in: mixed)?.isItalic == true)
        #expect(style(of: "underlined", in: mixed)?.underline == true)
        #expect(style(of: "struck", in: mixed)?.isStruckThrough == true)
        #expect(style(of: " word, an ", in: mixed)?.isBold == nil)

        let centred = paragraph(startingWith: "Centred")
        #expect(style(of: "red", in: centred)?.colorHex == "FF0000")
        #expect(style(of: "large", in: centred)?.fontSize == 48)
        #expect(style(of: "Courier", in: centred)?.fontName == "Courier New")
        #expect(style(of: "2", in: centred)?.verticalAlignment == .subscript)
        #expect(style(of: "Centred paragraph in ", in: centred)?.fontName == "Helvetica")
    }

    @Test("A bold or italic typeface makes the text bold or italic")
    func typefaces() {
        var characters = PagesCharacterProperties()
        characters.fontName = "Helvetica-BoldOblique"
        #expect(characters.runStyle.fontName == "Helvetica")
        #expect(characters.runStyle.isBold == true)
        #expect(characters.runStyle.isItalic == true)
        characters.fontName = "NotInstalledSans-Italic"
        #expect(characters.runStyle.isBold == nil)
        #expect(characters.runStyle.isItalic == true)
        characters.fontName = "Helvetica"
        #expect(characters.runStyle.isBold == nil)
    }

    @Test("Paragraph formatting and headings come across")
    func paragraphFormatting() {
        #expect(paragraph(startingWith: "Quarterly").properties.styleID == "Heading1")
        #expect(paragraph(startingWith: "Second Heading").properties.styleID == "Heading2")
        #expect(paragraph(startingWith: "Centred").properties.alignment == .center)
        #expect(paragraph(startingWith: "Right aligned").properties.alignment == .trailing)

        let indented = paragraph(startingWith: "Indented").properties
        #expect(indented.indentLeft == 720)
        #expect(indented.indentFirstLine == 360)
        #expect(indented.spacingBefore == 240)
        #expect(indented.spacingAfter == 240)
        #expect(indented.lineSpacing == LineSpacing(line: 360, rule: .auto))
    }

    @Test("Lists keep their kind and levels")
    func lists() throws {
        let bullet = try #require(paragraph(startingWith: "First bullet").properties.list)
        let nested = try #require(paragraph(startingWith: "Nested").properties.list)
        let number = try #require(paragraph(startingWith: "Step two").properties.list)
        #expect(Self.document.numbering.kind(of: bullet.numberingID) == .bulleted)
        #expect(Self.document.numbering.kind(of: number.numberingID) == .numbered)
        #expect(nested.numberingID == bullet.numberingID)
        #expect(bullet.level == 0)
        #expect(nested.level == 1)
        #expect(Self.document.numbering.level(0, of: number.numberingID)?.text == "%1.")
        #expect(paragraph(startingWith: "Right aligned").properties.list == nil)
    }

    @Test("Tables keep their cells and column widths")
    func table() throws {
        let table = try #require(Self.document.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [["A1", "B1"], ["A2", "B2"]])
        #expect(table.gridColumns == [3000, 3000])
        #expect(table.rows[0].cells.map(\.shadingHex) == ["FFFF00", nil])
    }

    @Test("Pictures, footnotes and page breaks come across")
    func objects() throws {
        let picture = paragraph(startingWith: "Picture")
        guard case .image(let image) = try #require(picture.inlines.first { if case .image = $0.content { true } else { false } })?.content
        else { Issue.record("No picture"); return }
        #expect(image.width == 100)
        #expect(image.height == 50)
        #expect(Self.document.package.data(forRelationship: image.relationshipID)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        let footnoted = paragraph(startingWith: "Indented")
        #expect(footnoted.inlines.contains { $0.content == .note(NoteReference(kind: .footnote, id: "1")) })
        #expect(Self.document.notes.map(\.text) == ["The footnote text."])

        let breakIndex = paragraphs.firstIndex { $0.plainText.hasPrefix("Second page") }!
        #expect(paragraphs[breakIndex - 1].inlines.map(\.content) == [.pageBreak])
    }

    @Test("The page, header and footer come across")
    func page() {
        let setup = Self.document.pageSetup
        #expect(setup.width == 12240)
        #expect(setup.height == 15840)
        #expect(setup.marginLeft == 1080)
        #expect(setup.marginTop == 1440)
        #expect(Self.document.header?.text == "Header text")
        #expect(Self.document.footer?.text == "Footer text")
        #expect(Self.document.header?.alignment == .center)
        #expect(Self.document.footer?.alignment == .leading)
    }

    @Test("The body and heading styles take the document's own look")
    func styles() {
        let styles = Self.document.styles.styles
        #expect(styles["Normal"]?.runStyle.fontName == "Helvetica")
        #expect(styles["Normal"]?.runStyle.fontSize == 22)
        #expect(styles["Normal"]?.paragraphProperties.spacingAfter == 0)
        #expect(styles["Normal"]?.paragraphProperties.lineSpacing == LineSpacing(line: 240, rule: .auto))
        #expect(styles["Heading1"]?.runStyle.colorHex == "000000")
        #expect(styles["Heading1"]?.runStyle.fontSize == 36)
    }

    @Test("The document saves as a Word document that reads back the same")
    func savesAsWord() throws {
        let saved = try DOCXReader.document(from: DOCXWriter.data(from: Self.document))
        let texts = { (document: WordDocument) in document.allParagraphs.map(\.plainText) }
        #expect(texts(saved) == texts(Self.document))
        #expect(saved.header?.text == "Header text")
        #expect(saved.notes.map(\.text) == ["The footnote text."])
        let table = saved.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first
        #expect(table?.rows.first?.cells.first?.shadingHex == "FFFF00")
    }

    @Test("A package reads the same as a single file")
    func package() throws {
        let files = try ZipArchive.entries(in: Self.data)
        let document = try PagesReader.document(fromFiles: files)
        #expect(document.allParagraphs.map(\.plainText) == Self.document.allParagraphs.map(\.plainText))
    }

    @Test("A Pages 5 package, its archives zipped in Index.zip, and a package inside a folder read the same")
    func olderPackages() throws {
        let files = try ZipArchive.entries(in: Self.data)
        let texts = Self.document.allParagraphs.map(\.plainText)

        var zipped = files.filter { !$0.key.hasPrefix("Index/") }
        zipped["Index.zip"] = try ZipArchive.archive(entries: files.filter { $0.key.hasPrefix("Index/") }.map { ($0.key, $0.value) })
        #expect(try PagesReader.document(fromFiles: zipped).allParagraphs.map(\.plainText) == texts)

        var wrapped = Dictionary(uniqueKeysWithValues: files.map { ("Report.pages/" + $0.key, $0.value) })
        wrapped["Report.pages/"] = Data()
        #expect(try PagesReader.document(fromFiles: wrapped).allParagraphs.map(\.plainText) == texts)
    }

    /// `Fields.pages`: a link, a table with cells merged across and down,
    /// and a footer with the page number and count.
    private static let fields = try! PagesReader.document(from: Data(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Fields.pages")
    ))

    @Test("Links keep their address")
    func links() throws {
        let paragraph = try #require(Self.fields.allParagraphs.first)
        #expect(paragraph.plainText == "Visit the site today.")
        let linked = try #require(paragraph.inlines.first { $0.hyperlink != nil })
        #expect(linked.plainText == "the site")
        #expect(linked.hyperlink?.url == URL(string: "https://example.com/"))
        let id = try #require(linked.hyperlink?.relationshipID)
        #expect(Self.fields.package.addedLinks[id] == "https://example.com/")
        #expect(paragraph.inlines.filter { $0.hyperlink != nil }.count == 1)
    }

    @Test("Page numbers in a footer become its page number and count")
    func pageNumbers() {
        #expect(Self.fields.footer?.text == "Page {PAGE} of {NUMPAGES}")
    }

    /// `Formats.pages`: Pages made it from a Word document with a table and
    /// a footer numbering pages in capital roman numerals, then gave the
    /// table's columns number, currency and percentage formats and formulas,
    /// its header row a fill and white text, and one cell Georgia.
    private static let formats = try! PagesReader.document(from: Data(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Formats.pages")
    ))

    @Test("A page number's format becomes the section's")
    func pageNumberFormat() {
        #expect(Self.formats.footer?.text == "Page {PAGE}")
        #expect(Self.formats.pageSetup.pageNumberFormat == "upperRoman")
        #expect(Self.fields.pageSetup.pageNumberFormat == nil)
    }

    @Test("Numbers show in their cells' formats, formulas their results")
    func numberFormats() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [
            ["Item", "Number", "Currency", "Percent", "Sum"],
            ["A", "1234.5", "$1234.50", "25%", "2469"],
            ["B", "98765", "$99.00", "12.5%", "98864"],
            ["Total", "99999.5", "$1333.50", "37.5%", "101333"],
        ])
    }

    @Test("A header row's fill and white text come across")
    func headerRow() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows[0].isHeader)
        #expect(table.rows[0].cells.allSatisfy { $0.shadingHex == "4390B2" })
        #expect(table.rows[0].cells.allSatisfy { $0.blocks.first?.paragraphs.first?.inlines.first?.format.style.colorHex == "FFFFFF" })
        #expect(table.rows.dropFirst().allSatisfy { $0.cells.allSatisfy { $0.shadingHex == nil } })
    }

    @Test("Numbers are set in their cells' text style, as text is")
    func numberFonts() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        for cell in table.rows[1].cells.dropFirst() {
            let style = cell.blocks.first?.paragraphs.first?.inlines.first?.format.style
            #expect(style?.fontName == "Times New Roman")
            #expect(style?.fontSize == 24)
        }
    }

    @Test("Number formats give places, separators, currency and brackets as Pages does")
    func numberFormatText() {
        let locale = Locale(identifier: "en_US")
        let accounting = PagesNumberFormat(
            kind: .currency, decimalPlaces: 0, currencyCode: "USD", showsThousandsSeparator: true,
            bracketsNegatives: true, isAccounting: true
        )
        #expect(accounting.text(5500, locale: locale) == "$ 5,500")
        #expect(accounting.text(-90, locale: locale) == "($ 90)")
        #expect(PagesNumberFormat(kind: .currency, decimalPlaces: 2, currencyCode: "EUR").text(-3.5, locale: locale) == "-€3.50")
        #expect(PagesNumberFormat(kind: .number, decimalPlaces: 2, showsThousandsSeparator: true).text(1234, locale: locale) == "1,234.00")
        #expect(PagesNumberFormat(kind: .percentage, decimalPlaces: 1).text(0.125, locale: locale) == "12.5%")
        #expect(PagesNumberFormat(kind: .number, showsThousandsSeparator: true).text(1234.5, locale: Locale(identifier: "de_DE")) == "1.234,5")
        #expect(PagesNumberFormat(kind: .automatic).text(2.5, locale: locale) == "2.5")
    }

    @Test("Merged cells span their columns and rows")
    func mergedCells() throws {
        let table = try #require(Self.fields.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [["Wide", "C1"], ["Tall", "B2", "C2"], ["", "B3", "C3"]])
        #expect(table.rows[0].cells.map(\.gridSpan) == [2, 1])
        #expect(table.rows[1].cells[0].verticalMerge == .restart)
        #expect(table.rows[2].cells[0].verticalMerge == .continue)
        #expect(table.rows[2].cells[0].shadingHex == table.rows[1].cells[0].shadingHex)

        let saved = try DOCXReader.document(from: DOCXWriter.data(from: Self.fields))
        let savedTable = try #require(saved.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(savedTable.rows[0].cells.map(\.gridSpan) == [2, 1])
        #expect(savedTable.rows[2].cells[0].verticalMerge == .continue)
        #expect(saved.footer?.text == "Page {PAGE} of {NUMPAGES}")
    }

    @Test("Cells stored before 2019 keep their type, from the second byte in version 4")
    func oldCellStorage() throws {
        // A text cell as Pages 5 wrote it: version 4, type 3, a style and a string key.
        let bytes: [UInt8] = [4, 3, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0]
        let value = try #require(PagesConverter.CellValue(oldStorage: bytes[...]))
        #expect(value.type == 3)
        #expect(value.stringKey == 7)

        // A currency cell from a Pages 5 file: 100 as a double, then the key of its format.
        let money: [UInt8] = [4, 2, 0, 0, 0x24, 0, 0, 0, 0x12, 8, 8, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x59, 0x40, 3, 0, 0, 0]
        let amount = try #require(PagesConverter.CellValue(oldStorage: money[...]))
        #expect(amount.double == 100)
        #expect(amount.currencyFormatKey == 3)
        #expect(!amount.isNewStorage)
    }

    @Test("A page layout document's text boxes, shapes and pictures read down the page")
    func pageLayout() throws {
        let document = try PagesReader.document(from: Data(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Layout.pages")
        ))
        let paragraphs = document.allParagraphs
        #expect(paragraphs.map(\.plainText) == ["Top box text", "", "In a shape", "Lower box text"])
        guard case .image(let image) = paragraphs[1].inlines.first?.content else {
            Issue.record("No picture")
            return
        }
        #expect(image.width == 120)
        #expect(image.height == 60)
        #expect(document.unsupportedFeatures.isEmpty)
    }

    @Test("A page layout document's pages follow one another, a page break between them")
    func pageLayoutPages() throws {
        let document = try PagesReader.document(from: Data(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/TwoPages.pages")
        ))
        #expect(document.allParagraphs.map(\.plainText) == ["First page box", "Second page box"])
        #expect(document.allParagraphs[0].inlines.last?.content == .pageBreak)
    }

    @Test("A password-protected document is recognised")
    func passwordProtected() throws {
        // `Locked.pages`: a document Pages saved with a password.
        let data = try Data(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Locked.pages")
        )
        #expect {
            try PagesReader.document(from: data)
        } throws: { error in
            if case IWorkError.passwordProtected = error { true } else { false }
        }
    }

    @Test("Files that are not Pages documents are turned away")
    func rejects() throws {
        let docx = try ZipArchive.archive(entries: [(path: "word/document.xml", data: Data("<w:document/>".utf8))])
        #expect(throws: IWorkError.self) { try PagesReader.document(from: docx) }
        #expect(throws: (any Error).self) { try PagesReader.document(from: Data("not a zip".utf8)) }

        var damaged = try ZipArchive.entries(in: Self.data)
        damaged["Index/Document.iwa"] = Data([0, 9, 0, 0, 1, 2, 3])
        #expect(throws: IWorkError.self) { try PagesReader.document(fromFiles: damaged) }
    }

    @Test("Lengths too large for an integer are damage, not a crash")
    func hugeLengths() {
        // A ten-byte varint of 2^64 - 1, as an object's header length and as a field's.
        let huge: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
        var reader = ProtoReader(huge[...])
        #expect(throws: IWorkError.self) { try reader.length() }
        #expect(throws: IWorkError.self) { try ProtoMessage([0x0A] + huge[...]) }
        // A length that only overflows once added to the position.
        var short = ProtoReader([1, 2, 3][...])
        #expect(throws: IWorkError.self) { try short.take(Int.max) }
        // Snappy's preamble, giving the decompressed length.
        var output: [UInt8] = []
        #expect(throws: IWorkError.self) { try Snappy.decompress(huge[...], into: &output, name: "test") }
    }
}
