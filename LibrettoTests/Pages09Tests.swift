import Foundation
import Testing
import UIKit
@testable import Libretto

/// Reads a document in the XML Pages '09 saved, built here in the shape of
/// one Pages wrote: named styles inheriting from one another, anonymous ones
/// referred to by ID, and a body of sections, layouts and paragraphs.
@Suite("Pages '09")
struct Pages09Tests {
    static let index = """
        <?xml version="1.0"?>
        <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
        xmlns:sf="http://developer.apple.com/namespaces/sf" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:sl="http://developer.apple.com/namespaces/sl">\
        <sl:slprint-info sl:page-width="595" sl:page-height="842" sl:page-scale="1">\
        <sf:page-margins sf:top="56.5" sf:left="72" sf:bottom="56.5" sf:right="72" sf:header="36" sf:footer="36"/>\
        </sl:slprint-info>\
        <sl:stylesheet sfa:ID="SFSStylesheet-2"><sf:styles>\
        <sf:liststyle sf:name="None" sf:ident="list-style-default" sfa:ID="SFWPListStyle-0"><sf:property-map>\
        <sf:listLabelTypes><sf:array><sf:list-label-typeinfo sf:type="none"/></sf:array></sf:listLabelTypes>\
        </sf:property-map></sf:liststyle>\
        <sf:liststyle sf:name="Numbered" sf:ident="list-style-numbered" sfa:ID="SFWPListStyle-1"><sf:property-map>\
        <sf:listLabelTypes><sf:array><sf:list-label-typeinfo sf:type="text">\
        <sf:text-label sf:type="upper-roman" sf:format="%L." sf:first="1"/></sf:list-label-typeinfo></sf:array>\
        </sf:listLabelTypes></sf:property-map></sf:liststyle>\
        <sf:paragraphstyle sf:name="Free Form" sf:ident="paragraph-style-default" sfa:ID="SFWPParagraphStyle-18">\
        <sf:property-map><sf:fontName><sf:string sfa:string="Georgia"/></sf:fontName>\
        <sf:fontSize><sf:number sfa:number="12" sfa:type="f"/></sf:fontSize><sf:outlineLevel/>\
        <sf:listStyle><sf:liststyle-ref sfa:IDREF="SFWPListStyle-0"/></sf:listStyle></sf:property-map></sf:paragraphstyle>\
        <sf:paragraphstyle sf:name="Body" sf:ident="paragraph-style-32" sf:parent-ident="paragraph-style-default" \
        sfa:ID="SFWPParagraphStyle-10"><sf:property-map><sf:spaceAfter><sf:number sfa:number="6" sfa:type="f"/>\
        </sf:spaceAfter><sf:fontName/><sf:alignment/></sf:property-map></sf:paragraphstyle>\
        <sf:paragraphstyle sf:name="Heading 1" sf:ident="paragraph-style-35" sf:parent-ident="paragraph-style-32">\
        <sf:property-map><sf:bold><sf:number sfa:number="1" sfa:type="c"/></sf:bold>\
        <sf:fontSize><sf:number sfa:number="24" sfa:type="f"/></sf:fontSize>\
        <sf:fontColor><sf:color xsi:type="sfa:calibrated-rgb-color-type" sfa:r="0.2" sfa:g="0.4" sfa:b="0.6" sfa:a="1"/>\
        </sf:fontColor><sf:outlineLevel><sf:number sfa:number="0" sfa:type="i"/></sf:outlineLevel>\
        </sf:property-map></sf:paragraphstyle>\
        <sf:paragraphstyle sf:name="Numbered" sf:ident="paragraph-style-40" sf:parent-ident="paragraph-style-32">\
        <sf:property-map><sf:listStyle><sf:liststyle-ref sfa:IDREF="SFWPListStyle-1"/></sf:listStyle>\
        </sf:property-map></sf:paragraphstyle>\
        <sf:paragraphstyle sf:name="Centred" sf:ident="paragraph-style-41" sf:parent-ident="paragraph-style-32">\
        <sf:property-map><sf:alignment><sf:number sfa:number="2" sfa:type="i"/></sf:alignment>\
        <sf:lineSpacing><sf:linespacing sfa:mode="relative" sfa:amount="1.5"/></sf:lineSpacing>\
        </sf:property-map></sf:paragraphstyle>\
        <sf:characterstyle sf:name="Emphasis" sf:ident="character-style-1"><sf:property-map>\
        <sf:italic><sf:number sfa:number="1" sfa:type="c"/></sf:italic></sf:property-map></sf:characterstyle>\
        </sf:styles><sf:anon-styles>\
        <sf:characterstyle sf:parent-ident="character-style-1" sfa:ID="SFWPCharacterStyle-7"><sf:property-map>\
        <sf:fontColor><sf:color xsi:type="sfa:calibrated-white-color-type" sfa:w="0.5" sfa:a="1"/></sf:fontColor>\
        <sf:underline><sf:number sfa:number="1" sfa:type="i"/></sf:underline></sf:property-map></sf:characterstyle>\
        </sf:anon-styles></sl:stylesheet>\
        <sf:headers><sf:header sf:name="SFWPDefaultOddHeaderIdentifier"><sf:text-storage sf:kind="header">\
        <sf:stylesheet-ref sfa:IDREF="SFSStylesheet-2"/><sf:text-body><sf:p sf:style="paragraph-style-41">Page \
        <sf:page-number sf:format="arabic"/> of <sf:page-count/></sf:p></sf:text-body></sf:text-storage></sf:header>\
        </sf:headers>\
        <sf:text-storage sf:kind="body" sfa:ID="SFWPStorage-8"><sf:stylesheet-ref sfa:IDREF="SFSStylesheet-2"/>\
        <sf:footnotes><sf:text-storage sf:kind="footnote"><sf:text-body>\
        <sf:p><sf:span><sf:footnote-mark sf:mark="1"/></sf:span> The first note.<sf:footnotebr/></sf:p>\
        <sf:p><sf:span><sf:footnote-mark sf:mark="2"/></sf:span> The second note,<sf:br/></sf:p>\
        <sf:p>over two paragraphs.<sf:footnotebr/></sf:p></sf:text-body></sf:text-storage></sf:footnotes>\
        <sf:attachments><sf:attachment sf:kind="tabular-attachment" sfa:ID="SFTTableAttachment-0"><sf:tabular-info>\
        <sf:tabular-model sf:num-header-rows="1"><sf:grid sf:numcols="3" sf:numrows="3"><sf:columns>\
        <sf:grid-column sf:width="120"/><sf:grid-column sf:width="60"/><sf:grid-column sf:width="60"/></sf:columns>\
        <sf:rows><sf:grid-row/><sf:grid-row/><sf:grid-row/></sf:rows><sf:datasource>\
        <sf:t><sf:ct sfa:s="Item"/></sf:t><sf:t sf:col-span="2"><sf:ct sfa:s="Figures"/></sf:t><sf:s/>\
        <sf:t sf:row-span="2"><sf:ct sfa:s="Fruit"/></sf:t><sf:n sf:v="3"/><sf:b sf:v="1"/>\
        <sf:s/><sf:n sf:v="2.5"/><sf:e/>\
        </sf:datasource></sf:grid></sf:tabular-model></sf:tabular-info></sf:attachment></sf:attachments>\
        <sf:text-body><sf:page-start sf:page-index="0"/><sf:container-hint sf:page-index="0"/>\
        <sf:section sf:name="Text Page"><sf:layout>\
        <sf:p sf:style="paragraph-style-35">Annual Report<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-32">Plain, <sf:annotation-field sf:ranged="true" sfa:ID="SFWPAnnotatedField-1">\
        <sf:span sf:style="character-style-1">emphasised</sf:span></sf:annotation-field>, and \
        <sf:link href="https://example.com/"><sf:span sf:style="SFWPCharacterStyle-7">linked</sf:span></sf:link><sf:footnote sf:index="0" sf:autonumber="1"/>.<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-41">One<sf:lnbr/>two<sf:tab/>three<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-40">First point<sf:span><sf:footnote sf:index="0" sf:autonumber="2"/></sf:span><sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-40">Second point<sf:pgbr/></sf:p>\
        <sf:p sf:style="paragraph-style-32"><sf:attachment-ref sfa:IDREF="SFTTableAttachment-0" sf:kind="tabular-ref"/><sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-32"><sf:ghost-text>Type here</sf:ghost-text></sf:p>\
        </sf:layout></sf:section><sf:insertion-point/></sf:text-body></sf:text-storage>\
        </sl:document>
        """

    private static let document = try! PagesReader.document(
        from: ZipArchive.archive(entries: [(path: "index.xml", data: Data(index.utf8))])
    )

    private var paragraphs: [Paragraph] {
        Self.document.body.compactMap { if case .paragraph(let paragraph) = $0 { paragraph } else { nil } }
    }

    @Test("Paragraphs read in order, breaks and tabs among them")
    func text() {
        #expect(paragraphs.map(\.plainText) == [
            "Annual Report", "Plain, emphasised, and linked.", "One\ntwo\tthree", "First point", "Second point", "Type here",
        ])
        #expect(paragraphs[4].inlines.last?.content == .pageBreak)
        #expect(Self.document.importedFormat == .pages)
    }

    @Test("Styles inherit, and spans, links and commented text keep their formatting")
    func formatting() throws {
        let heading = paragraphs[0]
        #expect(heading.properties.styleID == "Heading1")
        #expect(heading.inlines.first?.format.style.isBold == true)
        #expect(heading.inlines.first?.format.style.fontSize == 48)
        #expect(heading.inlines.first?.format.style.colorHex == "407AAA")
        #expect(heading.inlines.first?.format.style.fontName == "Georgia")

        let body = paragraphs[1]
        #expect(body.properties.spacingAfter == 120)
        let emphasised = try #require(body.inlines.first { $0.plainText == "emphasised" })
        #expect(emphasised.format.style.isItalic == true)
        let linked = try #require(body.inlines.first { $0.plainText == "linked" })
        #expect(linked.format.style.isItalic == true)
        #expect(linked.format.style.underline == true)
        #expect(linked.format.style.colorHex == "929292")
        #expect(linked.hyperlink?.url == URL(string: "https://example.com/"))
        #expect(body.inlines.filter { $0.hyperlink != nil }.count == 1)

        let centred = paragraphs[2].properties
        #expect(centred.alignment == .center)
        #expect(centred.lineSpacing == LineSpacing(line: 360, rule: .auto))
    }

    @Test("Footnotes take their text from the body's footnotes, in order")
    func footnotes() {
        #expect(Self.document.notes.map(\.text) == ["The first note.", "The second note,\nover two paragraphs."])
        let references = paragraphs.flatMap(\.inlines).compactMap { if case .note(let note) = $0.content { note.id } else { nil } }
        #expect(references == Self.document.notes.map(\.id))
    }

    @Test("Tables keep their cells, merges and column widths")
    func table() throws {
        let table = try #require(Self.document.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [["Item", "Figures"], ["Fruit", "3", "TRUE"], ["", "2.5", ""]])
        #expect(table.gridColumns == [2400, 1200, 1200])
        #expect(table.rows[0].cells.map(\.gridSpan) == [1, 2])
        #expect(table.rows[0].isHeader)
        #expect(table.rows[1].cells[0].verticalMerge == .restart)
        #expect(table.rows[2].cells[0].verticalMerge == .continue)
    }

    @Test("Lists keep their numbering")
    func lists() throws {
        let first = try #require(paragraphs[3].properties.list)
        #expect(paragraphs[4].properties.list == first)
        #expect(Self.document.numbering.kind(of: first.numberingID) == .numbered)
        #expect(Self.document.numbering.level(0, of: first.numberingID)?.format == "upperRoman")
        #expect(paragraphs[1].properties.list == nil)
    }

    @Test("The page and header come across")
    func page() throws {
        let setup = Self.document.pageSetup
        #expect(setup.width == 11900)
        #expect(setup.height == 16840)
        #expect(setup.marginLeft == 1440)
        #expect(setup.marginTop == 1130)
        #expect(Self.document.header?.text == "Page {PAGE} of {NUMPAGES}")
        #expect(Self.document.header?.alignment == .center)
        // Set in its style's font, which Word gives the header's runs.
        #expect(Self.document.header?.runPropertiesXML?.contains("w:ascii=\"Georgia\"") == true)
        #expect(Self.document.header?.runPropertiesXML?.contains("<w:sz w:val=\"24\"/>") == true)
        #expect(Self.document.styles.styles["Normal"]?.runStyle.fontName == "Georgia")
        // A style that names no font is in Pages' own, 12-point Helvetica.
        let unstyled = try PagesReader.document(fromFiles: ["index.xml": Data("""
            <sl:document xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:p>Plain</sf:p></sf:text-body></sf:text-storage></sl:document>
            """.utf8)])
        #expect(unstyled.styles.styles["Normal"]?.runStyle.fontName == "Helvetica")
        #expect(unstyled.styles.styles["Normal"]?.runStyle.fontSize == 24)
    }

    /// `Formats09.pages`: `Formats.pages` as Pages exported it for Pages '09.
    private static let formats = try! PagesReader.document(from: Data(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Formats09.pages")
    ))

    @Test("A page number's format becomes the section's")
    func pageNumberFormat() {
        #expect(Self.formats.footer?.text == "Page {PAGE}")
        #expect(Self.formats.pageSetup.pageNumberFormat == "upperRoman")
        #expect(Self.document.pageSetup.pageNumberFormat == nil)
    }

    @Test("Headers and footers come from the page masters of the section's style, and only those")
    func pageMasters() throws {
        // `Formats09.pages` has a footer only on its odd page master, and empty parts besides.
        #expect(Self.formats.headerFooters.values.map(\.text) == ["Page {PAGE}"])
        #expect(Self.formats.pageSetup.headerFooters.titlePage == false)
        #expect(Self.formats.evenAndOddHeaders == false)

        func part(_ kind: String, _ name: String, _ text: String) -> String {
            """
            <sf:\(kind) sf:name="\(name)"><sf:text-storage sf:kind="header"><sf:text-body>\
            <sf:p>\(text)</sf:p></sf:text-body></sf:text-storage></sf:\(kind)>
            """
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:sectionstyle sf:ident="section-style-0"><sf:property-map>\
            <sf:pageMasterFirstPageDifferent><sf:number sfa:number="1"/></sf:pageMasterFirstPageDifferent>\
            <sf:pageMasterLeftRightPagesDifferent><sf:number sfa:number="0"/></sf:pageMasterLeftRightPagesDifferent>\
            <sf:firstPageMaster><sf:pagemaster sl:header="s-first-page-header" sl:footer="s-first-page-footer"/></sf:firstPageMaster>\
            <sf:oddPageMaster><sf:pagemaster sl:header="s-odd-header" sl:footer="s-odd-footer"/></sf:oddPageMaster>\
            <sf:evenPageMaster><sf:pagemaster sl:header="s-even-header" sl:footer="s-even-footer"/></sf:evenPageMaster>\
            </sf:property-map></sf:sectionstyle></sf:styles></sl:stylesheet>\
            <sf:headers>\(part("header", "s-first-page-header", "Title page"))\(part("header", "s-odd-header", "Odd"))\
            \(part("header", "s-even-header", "Even"))</sf:headers>\
            <sf:footers>\(part("footer", "s-odd-footer", "Footer"))</sf:footers>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:section sf:style="section-style-0"><sf:layout>\
            <sf:p>Text</sf:p></sf:layout></sf:section></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        let setup = document.pageSetup
        #expect(document.header?.text == "Odd")
        #expect(document.headerFooter(.first, isFooter: false, in: setup)?.text == "Title page")
        #expect(document.headerFooter(.even, isFooter: false, in: setup) == nil)
        #expect(document.footer?.text == "Footer")
        #expect(setup.headerFooters.titlePage)
        #expect(!document.evenAndOddHeaders)
        #expect(document.headerFooters.count == 3)
    }

    @Test("Headings are the styles named so, whatever outline level Pages gives them or captions")
    func headings() throws {
        // As in `Formats09.pages`: a caption at outline level 0, Heading 3 at 0 too, and Heading 1 renamed.
        func style(_ ident: String, _ name: String, level: Int?, outlined: Bool = false) -> String {
            let outline = level.map { "<sf:outlineLevel><sf:number sfa:number=\"\($0)\"/></sf:outlineLevel>" } ?? ""
            let type = outlined ? "<sf:outlineStyleType><sf:number sfa:number=\"2\"/></sf:outlineStyleType>" : ""
            return """
                <sf:paragraphstyle sf:ident="\(ident)" sf:name="\(name)"><sf:property-map>\(outline)\(type)\
                </sf:property-map></sf:paragraphstyle>
                """
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles>\(style("text-25-paragraphstyle", "Caption", level: 0))\
            \(style("text-11-paragraphstyle-Heading 1", "Heading", level: 0, outlined: true))\
            \(style("text-13-paragraphstyle-Heading 3", "Heading 3", level: 0, outlined: true))\
            \(style("custom", "Chapter", level: 1, outlined: true))</sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:p sf:style="text-25-paragraphstyle">Figure 1</sf:p>\
            <sf:p sf:style="text-11-paragraphstyle-Heading 1">Title</sf:p>\
            <sf:p sf:style="text-13-paragraphstyle-Heading 3">Detail</sf:p>\
            <sf:p sf:style="custom">Chapter</sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.map(\.properties.outlineLevel) == [nil, 0, 2, 1])
        #expect(document.allParagraphs.map(\.properties.styleID) == [nil, "Heading1", "Heading3", "Heading2"])
    }

    @Test("Two tables in one paragraph both follow it, neither inside the other")
    func tablesInOneParagraph() throws {
        func table(_ id: String, _ text: String) -> String {
            """
            <sf:attachment sfa:ID="\(id)"><sf:tabular-info><sf:tabular-model><sf:grid><sf:columns>\
            <sf:grid-column sf:width="100"/></sf:columns><sf:rows><sf:grid-row/></sf:rows><sf:datasource>\
            <sf:t><sf:text-body><sf:p>\(text)</sf:p></sf:text-body></sf:t></sf:datasource></sf:grid></sf:tabular-model>\
            </sf:tabular-info></sf:attachment>
            """
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sf:text-storage sf:kind="body"><sf:attachments>\(table("A", "First"))\(table("B", "Second"))</sf:attachments>\
            <sf:text-body><sf:p><sf:attachment-ref sfa:IDREF="A"/><sf:attachment-ref sfa:IDREF="B"/></sf:p>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        let tables = document.body.compactMap { if case .table(let table) = $0 { table } else { nil } }
        #expect(tables.map { $0.rows.flatMap(\.cells).map(\.blocks.count) } == [[1], [1]])
        #expect(tables.map { $0.rows.flatMap(\.cells).map(\.plainText) } == [["First"], ["Second"]])
    }

    @Test("Numbers that are not finite, or too large to measure with, are left out rather than trapping")
    func outlandishNumbers() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:slprint-info sl:page-width="inf" sl:page-height="1e300"><sf:page-margins sf:top="nan"/></sl:slprint-info>\
            <sl:stylesheet><sf:styles><sf:paragraphstyle sf:ident="odd"><sf:property-map>\
            <sf:fontSize><sf:number sfa:number="1e300"/></sf:fontSize>\
            <sf:superscript><sf:number sfa:number="1e30"/></sf:superscript>\
            <sf:alignment><sf:number sfa:number="nan"/></sf:alignment>\
            <sf:lineSpacing><sf:linespacing sfa:mode="exact" sfa:amount="-inf"/></sf:lineSpacing>\
            <sf:fontColor><sf:color sfa:r="nan" sfa:g="inf" sfa:b="0" sfa:a="1"/></sf:fontColor>\
            </sf:property-map></sf:paragraphstyle></sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:attachments><sf:attachment sfa:ID="T"><sf:tabular-info><sf:tabular-model>\
            <sf:grid><sf:columns><sf:grid-column sf:width="1e308"/><sf:grid-column sf:width="1e308"/></sf:columns>\
            <sf:rows><sf:grid-row/></sf:rows><sf:datasource><sf:t sf:col-span="2"><sf:ct sfa:s="Wide"/></sf:t><sf:s/>\
            </sf:datasource></sf:grid></sf:tabular-model></sf:tabular-info></sf:attachment></sf:attachments>\
            <sf:text-body><sf:p sf:style="odd" sf:list-level="-9223372036854775808">Text<sf:attachment-ref sfa:IDREF="T"/></sf:p>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.map(\.plainText) == ["Text", "Wide", ""])
        #expect(document.pageSetup.width == WordDocument().pageSetup.width)
    }

    /// A one-row table of `cells`, its cell styles from `styles`, as a document.
    private static func tableDocument(_ cells: [String], styles: String = "") throws -> WordDocument {
        let columns = String(repeating: "<sf:grid-column sf:width=\"100\"/>", count: cells.count)
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles>\(styles)</sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:attachments><sf:attachment sfa:ID="T"><sf:tabular-info><sf:tabular-model>\
            <sf:grid><sf:columns>\(columns)</sf:columns><sf:rows><sf:grid-row/></sf:rows><sf:datasource>\
            \(cells.joined())</sf:datasource></sf:grid></sf:tabular-model></sf:tabular-info></sf:attachment></sf:attachments>\
            <sf:text-body><sf:p><sf:attachment-ref sfa:IDREF="T"/></sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        return try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
    }

    private static func cellTexts(_ document: WordDocument) -> [String] {
        document.body.compactMap { if case .table(let table) = $0 { table } else { nil } }.first?.rows.first?.cells.map(\.plainText) ?? []
    }

    @Test("Dates show as written, with a time zone or without, in their cell style's format")
    func dates() throws {
        let styles = """
            <sf:cell-style sf:ident="dated"><sf:property-map><sf:SFTCellStylePropertyDateTimeFormat>\
            <sf:date-format sf:fmt="MMM d, y h:mm a"/></sf:SFTCellStylePropertyDateTimeFormat></sf:property-map></sf:cell-style>
            """
        let document = try Self.tableDocument([
            "<sf:d sf:cell-date=\"2010-05-12T23:30:00\"/>",
            "<sf:d sf:s=\"dated\" sf:cell-date=\"2010-05-12T23:30:00+0000\"/>",
            "<sf:d sf:cell-date=\"2009-12-31T00:00:00Z\"/>",
        ], styles: styles)
        #expect(Self.cellTexts(document) == ["5/12/10", "May 12, 2010 11:30 PM", "12/31/09"])
    }

    @Test("Durations show in their units, and a pop-up menu its chosen item")
    func durationsAndMenus() throws {
        let styles = """
            <sf:cell-style sf:ident="minutes"><sf:property-map><sf:SFTCellStylePropertyDurationFormat>\
            <sf:duration-format sf:fmt="mmm sss"/></sf:SFTCellStylePropertyDurationFormat></sf:property-map></sf:cell-style>
            """
        let menu = """
            <sf:pm><sf:menu-choices><sf:t sfa:ID="first"><sf:ct sfa:s="Low"/></sf:t>\
            <sf:t sfa:ID="second"><sf:ct sfa:s="High"/></sf:t></sf:menu-choices>\
            <sf:proxied-cell-ref sfa:IDREF="second"/></sf:pm>
            """
        let document = try Self.tableDocument(
            ["<sf:du sf:du=\"5400\"/>", "<sf:du sf:s=\"minutes\" sf:du=\"3725\"/>", menu], styles: styles
        )
        #expect(Self.cellTexts(document) == ["1h 30m 0s", "62m 5s", "High"])
    }

    @Test("A picture placed twice shows both times, the second referring to the first's data")
    func reusedPicture() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sf:text-storage sf:kind="body"><sf:attachments>\
            <sf:attachment sfa:ID="A"><sf:media><sf:data sfa:ID="D" sf:path="red.png"/></sf:media></sf:attachment>\
            <sf:attachment sfa:ID="B"><sf:media><sf:data-ref sfa:IDREF="D"/></sf:media></sf:attachment></sf:attachments>\
            <sf:text-body><sf:p>One<sf:attachment-ref sfa:IDREF="A"/></sf:p><sf:p>Two<sf:attachment-ref sfa:IDREF="B"/></sf:p>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8), "red.png": png])
        let images = document.allParagraphs.map { $0.inlines.filter { if case .image = $0.content { true } else { false } }.count }
        #expect(images == [1, 1])
        #expect(!document.unsupportedFeatures.features.contains(.shapes))
    }

    @Test("A list numbers from its first number, and starts over where a paragraph restarts it")
    func listStart() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles>\
            <sf:liststyle sf:ident="numbered" sfa:ID="L"><sf:property-map><sf:listLabelTypes><sf:array>\
            <sf:list-label-typeinfo sf:type="text"><sf:text-label sf:type="decimal" sf:format="%L." sf:first="5"/>\
            </sf:list-label-typeinfo></sf:array></sf:listLabelTypes></sf:property-map></sf:liststyle>\
            <sf:paragraphstyle sf:ident="item"><sf:property-map><sf:listStyle><sf:liststyle-ref sfa:IDREF="L"/></sf:listStyle>\
            </sf:property-map></sf:paragraphstyle>\
            <sf:paragraphstyle sf:ident="from-three" sf:parent-ident="item"><sf:property-map>\
            <sf:firstTopicNumber><sf:number sfa:number="3"/></sf:firstTopicNumber></sf:property-map></sf:paragraphstyle>\
            </sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:p sf:style="item">One</sf:p><sf:p sf:style="item">Two</sf:p>\
            <sf:p sf:style="from-three" sf:restart-list="true">Three</sf:p><sf:p sf:style="item">Four</sf:p>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        let ids = document.allParagraphs.compactMap(\.properties.list?.numberingID)
        #expect(ids.count == 4)
        #expect(document.numbering.level(0, of: ids[0])?.start == 5)
        #expect(ids[0] == ids[1])
        #expect(ids[2] != ids[1])
        #expect(ids[3] == ids[2])
        #expect(document.numbering.overrides[ids[2]] == [0: 3])
    }

    @Test("Line spacing takes the amount Pages writes as sf:amt")
    func lineSpacingAmount() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:paragraphstyle sf:ident="spaced"><sf:property-map><sf:lineSpacing>\
            <sf:linespacing sf:amt="1.2" sf:mode="relative"/></sf:lineSpacing></sf:property-map></sf:paragraphstyle>\
            </sf:styles></sl:stylesheet><sf:text-storage sf:kind="body"><sf:text-body>\
            <sf:p sf:style="spaced">Text</sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.first?.properties.lineSpacing == LineSpacing(line: 288, rule: .auto))
    }

    @Test("A table too large to bring across is reported as left out, not as a shape")
    func tooLargeTable() throws {
        let rows = String(repeating: "<sf:grid-row/>", count: 50_001)
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sf:text-storage sf:kind="body"><sf:attachments><sf:attachment sfa:ID="T"><sf:tabular-info><sf:tabular-model>\
            <sf:grid><sf:columns><sf:grid-column/><sf:grid-column/></sf:columns><sf:rows>\(rows)</sf:rows>\
            <sf:datasource/></sf:grid></sf:tabular-model></sf:tabular-info></sf:attachment></sf:attachments>\
            <sf:text-body><sf:p>Text<sf:attachment-ref sfa:IDREF="T"/></sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.unsupportedFeatures.features == [.embeddedObjects])
    }

    @Test("Hidden text is left out, as Pages does not show it")
    func hiddenText() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles>\
            <sf:characterstyle sf:ident="hidden"><sf:property-map><sf:hidden><sf:number sfa:number="1"/></sf:hidden>\
            </sf:property-map></sf:characterstyle>\
            <sf:characterstyle sf:ident="shown"><sf:property-map><sf:hidden><sf:number sfa:number="0"/></sf:hidden>\
            </sf:property-map></sf:characterstyle>\
            <sf:paragraphstyle sf:ident="secret"><sf:property-map><sf:hidden><sf:number sfa:number="1"/></sf:hidden>\
            </sf:property-map></sf:paragraphstyle></sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:text-body>\
            <sf:p>Shown<sf:span sf:style="hidden"> and hidden<sf:tab/></sf:span>.</sf:p>\
            <sf:p sf:style="secret">Secret<sf:span sf:style="shown"> but this</sf:span></sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.map(\.plainText) == ["Shown.", " but this"])
    }

    @Test("A colour behind text becomes the nearest highlight Word has")
    func highlight() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:characterstyle sf:ident="marked"><sf:property-map><sf:textBackground>\
            <sf:color sfa:r="1" sfa:g="0.95" sfa:b="0.1" sfa:a="1"/></sf:textBackground></sf:property-map></sf:characterstyle>\
            </sf:styles></sl:stylesheet><sf:text-storage sf:kind="body"><sf:text-body>\
            <sf:p>Plain <sf:span sf:style="marked">marked</sf:span></sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.first?.inlines.map(\.format.style.highlight) == [nil, "yellow"])
    }

    @Test("A style's tab stops come across, with their alignment and leaders")
    func tabStops() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:paragraphstyle sf:ident="tabbed"><sf:property-map><sf:tabs><sf:tabs>\
            <sf:tabstop sf:pos="57.5" sf:align="left" sf:leader=" "/><sf:tabstop sf:pos="451" sf:align="right" sf:leader="."/>\
            </sf:tabs></sf:tabs></sf:property-map></sf:paragraphstyle></sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:p sf:style="tabbed">Name<sf:tab/>Page</sf:p>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.first?.properties.tabStops == [
            TabStop(position: 1150, alignment: .left), TabStop(position: 9020, alignment: .right, leader: "dot"),
        ])
    }

    @Test("A style's rule becomes a paragraph border, and a stroke with no pattern none")
    func paragraphBorders() throws {
        func style(_ ident: String, type: Int, pattern: String) -> String {
            """
            <sf:paragraphstyle sf:ident="\(ident)"><sf:property-map>\
            <sf:paragraphBorderType><sf:number sfa:number="\(type)"/></sf:paragraphBorderType><sf:paragraphStroke>\
            <sf:stroke sf:width="0.5"><sf:pattern sf:type="\(pattern)"/><sf:color sfa:r="1" sfa:g="0" sfa:b="0" sfa:a="1"/>\
            </sf:stroke></sf:paragraphStroke></sf:property-map></sf:paragraphstyle>
            """
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles>\(style("ruled", type: 1, pattern: "solid"))\(style("unruled", type: 1, pattern: "empty"))\
            </sf:styles></sl:stylesheet><sf:text-storage sf:kind="body"><sf:text-body>\
            <sf:p sf:style="ruled">Ruled</sf:p><sf:p sf:style="unruled">Plain</sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        let line = BorderLine(style: "single", size: 4, colorHex: "FF0000")
        #expect(document.allParagraphs.map(\.properties.borders) == [ParagraphBorders(top: line), nil])
    }

    @Test("The body's layout sets the page's text columns")
    func columns() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:layoutstyle sf:ident="two"><sf:property-map><sf:columns>\
            <sf:columns sf:equal-columns="true"><sf:column sf:index="0" sf:width="200" sf:spacing="18"/>\
            <sf:column sf:index="1" sf:width="200"/></sf:columns></sf:columns></sf:property-map></sf:layoutstyle>\
            </sf:styles></sl:stylesheet><sf:text-storage sf:kind="body"><sf:text-body><sf:section><sf:layout sf:style="two">\
            <sf:p>Text</sf:p></sf:layout></sf:section></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.pageSetup.columns == 2)
        #expect(document.pageSetup.columnSpacing == 360)
        #expect(Self.formats.pageSetup.columns == 1)
    }

    @Test("A cell's text leaves out the empty paragraph it ends with")
    func cellText() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(table.rows[0].cells.map(\.plainText) == ["Item", "Number", "Currency", "Percent", "Sum"])
        #expect(table.rows[0].cells.allSatisfy { $0.blocks.count == 1 })
    }

    @Test("Numbers show in their cells' formats, formulas their results")
    func numberFormats() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        // Pages shows a Pages '09 format with the places it gives, as here.
        #expect(table.rows.map { $0.cells.map(\.plainText) } == [
            ["Item", "Number", "Currency", "Percent", "Sum"],
            ["A", "1234.5", "$1234.50", "25.00%", "2469.0"],
            ["B", "98765.0", "$99.00", "12.50%", "98864.0"],
            ["Total", "99999.5", "$1333.50", "37.50%", "101333.0"],
        ])
    }

    @Test("Cells' text is in the font and colour of their cell styles")
    func cellFonts() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        func style(_ row: Int, _ column: Int) -> RunStyle? {
            table.rows[row].cells[column].blocks.first?.paragraphs.first?.inlines.first?.format.style
        }
        #expect(style(0, 0)?.fontName == "Times New Roman")
        #expect(style(0, 0)?.colorHex == "FFFFFF")
        #expect(style(1, 0)?.fontName == "Georgia")
        #expect(style(1, 0)?.fontSize == 28)
        #expect(style(1, 2)?.fontName == "Times New Roman")
        #expect(style(1, 2)?.colorHex == nil)
        // The cell styles' paragraph styles carry an outline level, as headings' do, but cells are not headings.
        let properties = table.rows.flatMap(\.cells).flatMap(\.blocks).flatMap(\.paragraphs).map(\.properties)
        #expect(properties.allSatisfy { $0.styleID == nil && $0.outlineLevel == nil })
    }

    @Test("Cells are filled as their cell styles say, a style with no fill taking away its parent's")
    func cellFills() throws {
        let table = try #require(Self.formats.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        // In sRGB, as Pages itself keeps the colour in `Formats.pages`.
        #expect(table.rows[0].cells.allSatisfy { $0.shadingHex == "4390B2" })
        #expect(table.rows.dropFirst().allSatisfy { $0.cells.allSatisfy { $0.shadingHex == nil } })
        let saved = try DOCXReader.document(from: DOCXWriter.data(from: Self.formats))
        let savedTable = try #require(saved.body.lazy.compactMap { if case .table(let table) = $0 { table } else { nil } }.first)
        #expect(savedTable.rows[0].cells.first?.shadingHex == "4390B2")
    }

    @Test("A package's gzipped index reads the same")
    func package() throws {
        let document = try PagesReader.document(fromFiles: ["index.xml.gz": Self.gzip(Data(Self.index.utf8))])
        #expect(document.allParagraphs.map(\.plainText) == Self.document.allParagraphs.map(\.plainText))
    }

    @Test("A page layout document's text boxes and tables read down each page, a page break between pages")
    func pageLayout() throws {
        func box(_ text: String, x: Int, y: Int) -> String {
            """
            <sf:drawable-shape><sf:geometry><sf:position sfa:x="\(x)" sfa:y="\(y)"/></sf:geometry><sf:text>\
            <sf:text-storage sf:kind="textbox"><sf:text-body><sf:p>\(text)<sf:br/></sf:p></sf:text-body></sf:text-storage>\
            </sf:text></sf:drawable-shape>
            """
        }
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:drawables><sl:page-group sl:page="2">\(box("Second page", x: 40, y: 40))</sl:page-group>\
            <sl:page-group sl:page="1">\(box("Lower", x: 20, y: 300))\(box("Right", x: 300, y: 50))\(box("Left", x: 20, y: 50))\
            <sf:drawable-shape><sf:geometry><sf:position sfa:x="0" sfa:y="0"/></sf:geometry></sf:drawable-shape>\
            <sf:tabular-info><sf:geometry><sf:position sfa:x="20" sfa:y="200"/></sf:geometry><sf:tabular-model><sf:grid>\
            <sf:columns><sf:grid-column sf:width="100"/></sf:columns><sf:rows><sf:grid-row/></sf:rows>\
            <sf:datasource><sf:t><sf:ct sfa:s="Cell"/></sf:t></sf:datasource></sf:grid></sf:tabular-model></sf:tabular-info>\
            </sl:page-group></sl:drawables>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:section><sf:layout><sf:p><sf:br/></sf:p></sf:layout></sf:section>\
            </sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.allParagraphs.map(\.plainText) == ["Left", "Right", "Cell", "Lower", "Second page"])
        #expect(document.allParagraphs[3].inlines.last?.content == .pageBreak)
        #expect(document.unsupportedFeatures.features == [.shapes])
    }

    @Test("Normal takes the style most of the text is in, not a title before it")
    func normalStyle() throws {
        let index = """
            <sl:document xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
            xmlns:sf="http://developer.apple.com/namespaces/sf" xmlns:sl="http://developer.apple.com/namespaces/sl">\
            <sl:stylesheet><sf:styles><sf:paragraphstyle sf:ident="title"><sf:property-map>\
            <sf:fontSize><sf:number sfa:number="28"/></sf:fontSize></sf:property-map></sf:paragraphstyle>\
            <sf:paragraphstyle sf:ident="body"><sf:property-map><sf:fontSize><sf:number sfa:number="11"/></sf:fontSize>\
            </sf:property-map></sf:paragraphstyle></sf:styles></sl:stylesheet>\
            <sf:text-storage sf:kind="body"><sf:text-body><sf:p sf:style="title">Proposal</sf:p>\
            <sf:p sf:style="body">One</sf:p><sf:p sf:style="body">Two</sf:p></sf:text-body></sf:text-storage></sl:document>
            """
        let document = try PagesReader.document(fromFiles: ["index.xml": Data(index.utf8)])
        #expect(document.styles.styles["Normal"]?.runStyle.fontSize == 22)
    }

    @Test("A damaged index is turned away")
    func damaged() {
        #expect(throws: IWorkError.self) {
            try PagesReader.document(fromFiles: ["index.xml": Data("<sl:document><sf:p>".utf8)])
        }
        #expect(throws: IWorkError.self) {
            try PagesReader.document(fromFiles: ["index.xml.gz": Data("not gzip at all, really".utf8)])
        }
    }

    @Test("A password-protected document is recognised")
    func passwordProtected() throws {
        // `Locked09.pages`: a document Pages exported for Pages '09 with a password,
        // which marks its encrypted entries with compression methods of its own.
        let data = try Data(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Locked09.pages")
        )
        #expect {
            try PagesReader.document(from: data)
        } throws: { error in
            if case IWorkError.passwordProtected = error { true } else { false }
        }
    }

    @Test("A password-protected package saved as a folder is recognised by its encrypted files")
    func passwordProtectedFolder() {
        // As the ZIP `Locked09.pages` holds them, but in a folder, where nothing marks them encrypted.
        let encrypted = Data((0..<256).map { UInt8(($0 * 167 + 89) & 0xFF) })
        #expect {
            try PagesReader.document(fromFiles: ["index.xml.gz": encrypted, "buildVersionHistory.plist": Data(encrypted.reversed())])
        } throws: { error in
            if case IWorkError.passwordProtected = error { true } else { false }
        }
        // A damaged index beside a readable history is damaged, not protected.
        #expect {
            try PagesReader.document(fromFiles: ["index.xml.gz": encrypted, "buildVersionHistory.plist": Data("<?xml".utf8)])
        } throws: { error in
            if case IWorkError.corrupt = error { true } else { false }
        }
    }

    /// A gzip member holding `data` in one stored DEFLATE block.
    private static func gzip(_ data: Data) -> Data {
        var output = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF, 0x01])
        let length = UInt16(data.count)
        output.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
        output.append(data)
        for value in [ZipArchive.crc32(data), UInt32(data.count)] {
            output.append(contentsOf: (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) })
        }
        return output
    }
}
