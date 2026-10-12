import Foundation
import Testing
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
        <sf:text-body><sf:page-start sf:page-index="0"/><sf:container-hint sf:page-index="0"/>\
        <sf:section sf:name="Text Page"><sf:layout>\
        <sf:p sf:style="paragraph-style-35">Annual Report<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-32">Plain, <sf:span sf:style="character-style-1">emphasised</sf:span>, and \
        <sf:link href="https://example.com/"><sf:span sf:style="SFWPCharacterStyle-7">linked</sf:span></sf:link>.<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-41">One<sf:lnbr/>two<sf:tab/>three<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-40">First point<sf:br/></sf:p>\
        <sf:p sf:style="paragraph-style-40">Second point<sf:pgbr/></sf:p>\
        <sf:p sf:style="paragraph-style-32"><sf:ghost-text>Type here</sf:ghost-text></sf:p>\
        </sf:layout></sf:section><sf:insertion-point/></sf:text-body></sf:text-storage>\
        </sl:document>
        """

    private static let document = try! PagesReader.document(
        from: ZipArchive.archive(entries: [(path: "index.xml", data: Data(index.utf8))])
    )

    private var paragraphs: [Paragraph] { Self.document.allParagraphs }

    @Test("Paragraphs read in order, breaks and tabs among them")
    func text() {
        #expect(paragraphs.map(\.plainText) == [
            "Annual Report", "Plain, emphasised, and linked.", "One\ntwo\tthree", "First point", "Second point", "Type here",
        ])
        #expect(paragraphs[4].inlines.last?.content == .pageBreak)
        #expect(Self.document.importedFormat == .pages)
    }

    @Test("Styles inherit, and spans and links keep their formatting")
    func formatting() throws {
        let heading = paragraphs[0]
        #expect(heading.properties.styleID == "Heading1")
        #expect(heading.inlines.first?.format.style.isBold == true)
        #expect(heading.inlines.first?.format.style.fontSize == 48)
        #expect(heading.inlines.first?.format.style.colorHex == "336699")
        #expect(heading.inlines.first?.format.style.fontName == "Georgia")

        let body = paragraphs[1]
        #expect(body.properties.spacingAfter == 120)
        let emphasised = try #require(body.inlines.first { $0.plainText == "emphasised" })
        #expect(emphasised.format.style.isItalic == true)
        let linked = try #require(body.inlines.first { $0.plainText == "linked" })
        #expect(linked.format.style.isItalic == true)
        #expect(linked.format.style.underline == true)
        #expect(linked.format.style.colorHex == "808080")
        #expect(linked.hyperlink?.url == URL(string: "https://example.com/"))
        #expect(body.inlines.filter { $0.hyperlink != nil }.count == 1)

        let centred = paragraphs[2].properties
        #expect(centred.alignment == .center)
        #expect(centred.lineSpacing == LineSpacing(line: 360, rule: .auto))
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
    func page() {
        let setup = Self.document.pageSetup
        #expect(setup.width == 11900)
        #expect(setup.height == 16840)
        #expect(setup.marginLeft == 1440)
        #expect(setup.marginTop == 1130)
        #expect(Self.document.header?.text == "Page {PAGE} of {NUMPAGES}")
        #expect(Self.document.header?.alignment == .center)
        #expect(Self.document.styles.styles["Normal"]?.runStyle.fontName == "Georgia")
    }

    @Test("A package's gzipped index reads the same")
    func package() throws {
        let document = try PagesReader.document(fromFiles: ["index.xml.gz": Self.gzip(Data(Self.index.utf8))])
        #expect(document.allParagraphs.map(\.plainText) == paragraphs.map(\.plainText))
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
