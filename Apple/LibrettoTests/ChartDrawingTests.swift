import Foundation
import Testing
import UIKit
@testable import LibrettoEngine

/// Charts read from their parts' cached values and drawn: the kinds, combined
/// kinds, legends and colours Libretto draws as Word does.
@Suite("Chart kinds and styling")
struct ChartDrawingTests {
    private static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    private static let chartType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"

    private func document(body: String, extra: [String: Data], relationships: String) throws -> WordDocument {
        var parts = Fixtures.parts(body: body)
        for (path, data) in extra { parts[path] = data }
        var rels = String(decoding: parts["word/_rels/document.xml.rels"]!, as: UTF8.self)
        rels = rels.replacingOccurrences(of: "</Relationships>", with: relationships + "</Relationships>")
        parts["word/_rels/document.xml.rels"] = Data(rels.utf8)
        var xml = String(decoding: parts["word/document.xml"]!, as: UTF8.self)
        let declarations = [
            "xmlns:wp=\"\(OOXML.drawingNamespace)\"", "xmlns:a=\"\(OOXML.drawingMainNamespace)\"",
            "xmlns:c=\"\(Self.chartURI)\"",
        ].joined(separator: " ")
        xml = xml.replacingOccurrences(of: "<w:document ", with: "<w:document \(declarations) ")
        parts["word/document.xml"] = Data(xml.utf8)
        return try DOCXReader.document(fromParts: parts)
    }

    private func images(_ document: WordDocument) -> [InlineImage] {
        document.allParagraphs.flatMap(\.inlines).compactMap {
            if case .image(let image) = $0.content { return image } else { return nil }
        }
    }

    private func chartDocument(_ plot: String, legend: String = "") throws -> WordDocument {
        let chart = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <c:chartSpace xmlns:c="\(Self.chartURI)" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <c:chart><c:plotArea>\(plot)</c:plotArea>\(legend)</c:chart></c:chartSpace>
            """
        let body = """
            <w:p><w:r><w:drawing><wp:inline><wp:extent cx="3810000" cy="2540000"/><wp:docPr id="7" name="Chart 7"/>\
            <a:graphic><a:graphicData uri="\(Self.chartURI)"><c:chart r:id="rIdChart"/></a:graphicData></a:graphic>\
            </wp:inline></w:drawing></w:r></w:p>
            """
        return try document(
            body: body, extra: ["word/charts/chart1.xml": Data(chart.utf8)],
            relationships: "<Relationship Id=\"rIdChart\" Type=\"\(Self.chartType)\" Target=\"charts/chart1.xml\"/>"
        )
    }

    private func series(_ name: String, _ values: [Double], extra: String = "") -> String {
        let points = values.enumerated().map { "<c:pt idx=\"\($0)\"><c:v>\($1)</c:v></c:pt>" }.joined()
        let categories = ["Speed", "Range", "Comfort", "Price"].prefix(values.count).enumerated()
            .map { "<c:pt idx=\"\($0)\"><c:v>\($1)</c:v></c:pt>" }.joined()
        return """
            <c:ser><c:tx><c:strRef><c:strCache><c:pt idx="0"><c:v>\(name)</c:v></c:pt></c:strCache></c:strRef></c:tx>\(extra)\
            <c:cat><c:strRef><c:strCache><c:ptCount val="\(values.count)"/>\(categories)</c:strCache></c:strRef></c:cat>\
            <c:val><c:numRef><c:numCache><c:ptCount val="\(values.count)"/>\(points)</c:numCache></c:numRef></c:val></c:ser>
            """
    }

    private func chart(_ document: WordDocument) -> (InlineImage, ChartSpec)? {
        for image in images(document) {
            if case .chart(let chart)? = image.object { return (image, chart) }
        }
        return nil
    }

    @Test("A radar chart is read and drawn, its legend where the document puts it")
    func radar() throws {
        let document = try chartDocument(
            "<c:radarChart><c:radarStyle val=\"marker\"/>\(series("A", [4, 3, 5, 2]))\(series("B", [2, 5, 3, 4]))</c:radarChart>",
            legend: "<c:legend><c:legendPos val=\"r\"/><c:overlay val=\"0\"/></c:legend>"
        )
        let (image, chart) = try #require(chart(document))
        #expect(chart.kind == .radar)
        #expect(chart.series.map(\.name) == ["A", "B"])
        #expect(chart.categories == ["Speed", "Range", "Comfort", "Price"])
        #expect(chart.legend == .right)
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
        let drawn = try #require(ImageStore().image(for: image, in: document.package))
        #expect(drawn.size == CGSize(width: 300, height: 200))
    }

    @Test("A combined chart draws its line over its columns")
    func combined() throws {
        let document = try chartDocument("""
            <c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>\(series("Sales", [4, 7, 2]))\
            <c:axId val="1"/><c:axId val="2"/></c:barChart>\
            <c:lineChart><c:grouping val="standard"/>\(series("Target", [5, 5, 5], extra: "<c:spPr><a:ln><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></a:ln></c:spPr>"))\
            <c:axId val="1"/><c:axId val="2"/></c:lineChart>
            """)
        let (image, chart) = try #require(chart(document))
        #expect(chart.kind == .column)
        #expect(chart.series.map(\.kind) == [nil, .line])
        #expect(chart.series[1].colorHex == "FF0000")
        // No legend element, no legend.
        #expect(chart.legend == nil)
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
        #expect(ImageStore().image(for: image, in: document.package) != nil)
    }

    @Test("A pie's slices keep their own colours")
    func pieColours() throws {
        let slices = """
            <c:dPt><c:idx val="0"/><c:spPr><a:solidFill><a:srgbClr val="112233"/></a:solidFill></c:spPr></c:dPt>\
            <c:dPt><c:idx val="2"/><c:spPr><a:solidFill><a:srgbClr val="445566"/></a:solidFill></c:spPr></c:dPt>
            """
        let document = try chartDocument("<c:pieChart><c:varyColors val=\"1\"/>\(series("Share", [1, 2, 3], extra: slices))</c:pieChart>")
        let (_, chart) = try #require(chart(document))
        #expect(chart.series[0].pointColorsHex == [0: "112233", 2: "445566"])
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures.isEmpty)
    }

    @Test("What a chart has that is drawn more simply is noticed", arguments: [
        "<c:bar3DChart><c:barDir val=\"col\"/>SERIES</c:bar3DChart>",
        "<c:barChart><c:barDir val=\"col\"/>SERIES<c:dLbls><c:showVal val=\"1\"/></c:dLbls></c:barChart>",
        "<c:bubbleChart>SERIES</c:bubbleChart>",
        "<c:lineChart>SERIES_TREND</c:lineChart>",
    ])
    func simplifiedCharts(plot: String) throws {
        let plot = plot
            .replacingOccurrences(of: "SERIES_TREND", with: series("A", [1, 2, 3], extra: "<c:trendline><c:trendlineType val=\"linear\"/></c:trendline>"))
            .replacingOccurrences(of: "SERIES", with: series("A", [1, 2, 3]))
        let document = try chartDocument(plot)
        #expect(chart(document) != nil)
        #expect(document.unsupportedFeatures.drawnDifferentlyFeatures == [.simplifiedObjects])
    }
}
