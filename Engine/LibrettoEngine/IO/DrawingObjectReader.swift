import Foundation

/// Reads the drawings that are not pictures — shapes and text boxes, charts,
/// SmartArt diagrams — into descriptions Libretto can draw.
public enum DrawingObjectReader: Sendable {
    public static let shapeURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    public static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    public static let diagramURI = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    public static let diagramDrawingType = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"

    /// The parts a drawing may refer to: charts' and diagrams'.
    public struct Package: Sendable {
        public var parts: [String: Data]
        public var relationships: [String: DocumentPackage.Relationship]
        public var documentPath: String

        public func part(_ id: String) -> XMLElement? {
            guard let relationship = relationships[id], !relationship.isExternal,
                  let data = parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)] else { return nil }
            return try? XMLLite.parse(data)
        }

        public init(parts: [String: Data], relationships: [String: DocumentPackage.Relationship], documentPath: String) {
            self.parts = parts
            self.relationships = relationships
            self.documentPath = documentPath
        }
    }

    /// The object an `wp:inline` or `wp:anchor` holds, if it is one Libretto can draw.
    public static func object(in container: XMLElement, package: Package) -> DrawingObject? {
        guard let data = descendant("graphicData", in: container) else { return nil }
        switch data.attribute("uri") {
        case shapeURI?:
            return data.firstChild(named: "wsp").map { .shape(shape($0)) }
        case chartURI?:
            guard let id = data.firstChild(named: "chart")?.attribute("id"), let chart = package.part(id) else { return nil }
            return self.chart(chart).map { .chart($0) }
        case diagramURI?:
            // The diagram's data part names the drawing Word last made of it, which is what is drawn.
            guard let model = data.firstChild(named: "relIds")?.attribute("dm"), let dataPart = package.part(model),
                  let drawingID = descendant("dataModelExt", in: dataPart)?.attribute("relId"),
                  let drawing = package.part(drawingID) else { return nil }
            let shapes = descendants("sp", in: drawing).map(diagramShape)
            return shapes.isEmpty ? nil : .diagram(shapes)
        default:
            return nil
        }
    }

    // MARK: - Shapes

    public static func shape(_ wsp: XMLElement) -> ShapeSpec {
        var shape = ShapeSpec()
        let properties = wsp.firstChild(named: "spPr")
        let style = wsp.firstChild(named: "style")
        read(properties: properties, style: style, into: &shape)
        if let content = descendant("txbxContent", in: wsp) {
            shape.isTextBox = true
            shape.text = content.children(named: "p").map { HeaderFooterReader.plainText(of: $0) }.joined(separator: "\n")
            if let rPr = descendant("rPr", in: content) {
                shape.textColorHex = rPr.firstChild(named: "color")?.attribute("val").flatMap { $0 == "auto" ? nil : $0.uppercased() }
                shape.fontSize = rPr.firstChild(named: "sz")?.attribute("val").flatMap(Double.init).map { $0 / 2 }
            }
        }
        shape.originalText = shape.text
        return shape
    }

    private static func diagramShape(_ sp: XMLElement) -> ShapeSpec {
        var shape = ShapeSpec()
        let properties = sp.firstChild(named: "spPr")
        read(properties: properties, style: sp.firstChild(named: "style"), into: &shape)
        if let transform = properties?.firstChild(named: "xfrm"),
           let offset = transform.firstChild(named: "off"), let extent = transform.firstChild(named: "ext") {
            func points(_ element: XMLElement, _ name: String) -> Double { (Double(element.attribute(name) ?? "") ?? 0) / 12_700 }
            shape.frame = ShapeFrame(
                x: points(offset, "x"), y: points(offset, "y"), width: points(extent, "cx"), height: points(extent, "cy")
            )
        }
        if let body = sp.firstChild(named: "txBody") {
            shape.text = body.children(named: "p").map { paragraph in
                descendants("t", in: paragraph).map(\.text).joined()
            }.joined(separator: "\n")
            if let run = descendant("rPr", in: body) {
                shape.fontSize = run.attribute("sz").flatMap(Double.init).map { $0 / 100 }
                shape.textColorHex = color(in: run.firstChild(named: "solidFill"))
            }
        }
        shape.textColorHex = shape.textColorHex ?? (shape.fillHex == nil ? "000000" : "FFFFFF")
        shape.originalText = shape.text
        return shape
    }

    /// Fill and line, from the shape's own properties, else its style's theme references.
    private static func read(properties: XMLElement?, style: XMLElement?, into shape: inout ShapeSpec) {
        shape.geometry = properties?.firstChild(named: "prstGeom")?.attribute("prst") ?? "rect"
        if properties?.firstChild(named: "noFill") != nil {
            shape.fillHex = nil
        } else if let fill = properties?.firstChild(named: "solidFill") {
            shape.fillHex = color(in: fill)
        } else if let reference = style?.firstChild(named: "fillRef") {
            shape.fillHex = color(in: reference)
        }
        if let line = properties?.firstChild(named: "ln") {
            if let width = line.attribute("w").flatMap(Double.init) { shape.lineWidth = width / 12_700 }
            if line.firstChild(named: "noFill") != nil {
                shape.lineHex = nil
            } else if let fill = line.firstChild(named: "solidFill") {
                shape.lineHex = color(in: fill)
            } else if let reference = style?.firstChild(named: "lnRef") {
                shape.lineHex = color(in: reference)
            }
        } else if let reference = style?.firstChild(named: "lnRef") {
            shape.lineHex = color(in: reference)
        }
        if let font = style?.firstChild(named: "fontRef") { shape.textColorHex = color(in: font) }
    }

    /// The Office theme's colours, which shapes refer to by role.
    public static let themeColors: [String: String] = [
        "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5", "accent4": "FFC000", "accent5": "5B9BD5",
        "accent6": "70AD47", "dk1": "000000", "lt1": "FFFFFF", "dk2": "44546A", "lt2": "E7E6E6", "tx1": "000000",
        "bg1": "FFFFFF", "tx2": "44546A", "bg2": "E7E6E6", "hlink": "0563C1", "folHlink": "954F72",
    ]

    /// The colour a fill or reference holds: an RGB value, a theme colour, or a system colour, with any shading applied.
    public static func color(in element: XMLElement?) -> String? {
        guard let element else { return nil }
        for child in element.children {
            var base: String?
            switch child.name {
            case "srgbClr": base = child.attribute("val")
            case "schemeClr": base = child.attribute("val").flatMap { themeColors[$0] }
            case "sysClr": base = child.attribute("lastClr")
            case "prstClr": base = ["black": "000000", "white": "FFFFFF", "red": "FF0000", "blue": "0000FF", "green": "00FF00"][child.attribute("val") ?? ""]
            default: continue
            }
            guard let hex = base?.uppercased() else { continue }
            return adjusted(hex, by: child)
        }
        return nil
    }

    /// `a:lumMod` and `a:lumOff`, `a:tint` and `a:shade`, as near as RGB comes.
    private static func adjusted(_ hex: String, by element: XMLElement) -> String {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return hex }
        var red = Double((value >> 16) & 0xFF) / 255
        var green = Double((value >> 8) & 0xFF) / 255
        var blue = Double(value & 0xFF) / 255
        func percent(_ name: String) -> Double? {
            element.firstChild(named: name)?.attribute("val").flatMap(Double.init).map { $0 / 100_000 }
        }
        let modulation = percent("lumMod") ?? 1
        let offset = percent("lumOff") ?? 0
        red = red * modulation + offset
        green = green * modulation + offset
        blue = blue * modulation + offset
        if let tint = percent("tint") {
            red += (1 - red) * (1 - tint)
            green += (1 - green) * (1 - tint)
            blue += (1 - blue) * (1 - tint)
        }
        if let shade = percent("shade") {
            red *= shade
            green *= shade
            blue *= shade
        }
        func byte(_ component: Double) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    // MARK: - Charts

    /// The chart groups Libretto draws, and what each is drawn as.
    private static let chartKinds: [(String, ChartSpec.Kind)] = [
        ("barChart", .column), ("bar3DChart", .column), ("lineChart", .line), ("line3DChart", .line),
        ("areaChart", .area), ("area3DChart", .area), ("pieChart", .pie), ("pie3DChart", .pie),
        ("doughnutChart", .doughnut), ("scatterChart", .scatter), ("radarChart", .radar),
        ("bubbleChart", .scatter), ("stockChart", .line), ("ofPieChart", .pie),
    ]

    /// The groups drawn only roughly: in 3-D, or as the nearest kind Libretto draws.
    private static let roughChartGroups: Set<String> = [
        "bar3DChart", "line3DChart", "area3DChart", "pie3DChart", "bubbleChart", "stockChart", "ofPieChart",
        "surfaceChart", "surface3DChart",
    ]

    public static func chart(_ root: XMLElement) -> ChartSpec? {
        guard let plot = descendant("plotArea", in: root) else { return nil }
        let groups = plot.children.compactMap { element in
            chartKinds.first { $0.0 == element.name }.map { (element, $0.1) }
        }
        guard let (element, kind) = groups.first else { return nil }
        var chart = ChartSpec(kind: kind)
        if kind == .column, element.firstChild(named: "barDir")?.attribute("val") == "bar" { chart.kind = .bar }
        let grouping = element.firstChild(named: "grouping")?.attribute("val") ?? ""
        chart.isStacked = grouping == "stacked" || grouping == "percentStacked"
        if let title = descendant("title", in: root) {
            let text = descendants("t", in: title).map(\.text).joined()
            chart.title = text.isEmpty ? nil : text
        }
        if let legend = descendant("legend", in: root) {
            let position = legend.firstChild(named: "legendPos")?.attribute("val") ?? "r"
            chart.legend = ChartSpec.LegendPosition(rawValue: position) ?? .bottom
        } else {
            chart.legend = nil
        }
        // A combined chart: lines or areas over columns. Groups of round or radar kinds don't combine.
        let combinable: Set<ChartSpec.Kind> = [.column, .line, .area]
        for (index, (group, groupKind)) in groups.enumerated() {
            if index > 0 && (!combinable.contains(chart.kind) || !combinable.contains(groupKind)) {
                continue
            }
            for series in group.children(named: "ser") {
                let name = series.firstChild(named: "tx").map { descendants("v", in: $0).map(\.text).joined() } ?? ""
                let values = points(in: series.firstChild(named: "val") ?? series.firstChild(named: "yVal"))
                    .map { Double($0) ?? 0 }
                let properties = series.firstChild(named: "spPr")
                // A line's colour is its line's; a column's or area's, its fill's.
                let seriesColor = groupKind == .line || groupKind == .radar || groupKind == .scatter
                    ? properties?.firstChild(named: "ln").flatMap { color(in: $0.firstChild(named: "solidFill")) }
                        ?? properties.flatMap { color(in: $0.firstChild(named: "solidFill")) }
                    : properties.flatMap { color(in: $0.firstChild(named: "solidFill")) }
                var read = ChartSpec.Series(
                    name: name, values: values, colorHex: seriesColor, kind: index > 0 && groupKind != chart.kind ? groupKind : nil
                )
                for point in series.children(named: "dPt") {
                    guard let index = point.firstChild(named: "idx")?.attribute("val").flatMap({ Int($0) }),
                          let fill = point.firstChild(named: "spPr").flatMap({ Self.color(in: $0.firstChild(named: "solidFill")) })
                    else { continue }
                    read.pointColorsHex[index] = fill
                }
                chart.series.append(read)
                if chart.categories.isEmpty {
                    chart.categories = points(in: series.firstChild(named: "cat") ?? series.firstChild(named: "xVal"))
                }
            }
        }
        return chart.series.isEmpty ? nil : chart
    }

    // MARK: - What is drawn more simply

    /// Whether the object a `wp:inline` or `wp:anchor` holds uses anything
    /// Libretto draws more simply than Word does (see `DrawingObject`).
    public static func isDrawnSimplified(_ container: XMLElement, package: Package) -> Bool {
        guard let data = descendant("graphicData", in: container) else { return false }
        switch data.attribute("uri") {
        case shapeURI?:
            return data.firstChild(named: "wsp").map(isSimplified(shape:)) ?? false
        case chartURI?:
            guard let id = data.firstChild(named: "chart")?.attribute("id"), let chart = package.part(id) else { return false }
            return isSimplified(chart: chart)
        case diagramURI?:
            guard let model = data.firstChild(named: "relIds")?.attribute("dm"), let dataPart = package.part(model),
                  let drawingID = descendant("dataModelExt", in: dataPart)?.attribute("relId"),
                  let drawing = package.part(drawingID) else { return false }
            return descendants("sp", in: drawing).contains(where: isSimplified(shape:))
        default:
            return false
        }
    }

    /// A shape's fills, effects, outline and text that Libretto draws more simply.
    static func isSimplified(shape: XMLElement) -> Bool {
        if let properties = shape.firstChild(named: "spPr") {
            let effects: Set<String> = ["gradFill", "pattFill", "blipFill", "grpFill", "custGeom", "scene3d", "sp3d"]
            if properties.children.contains(where: { effects.contains($0.name) }) { return true }
            if let list = properties.firstChild(named: "effectLst"), !list.children.isEmpty { return true }
            if properties.firstChild(named: "effectDag") != nil { return true }
            if let geometry = properties.firstChild(named: "prstGeom")?.attribute("prst"),
               !ShapeSpec.drawnGeometries.contains(geometry) { return true }
            if let transform = properties.firstChild(named: "xfrm"),
               (Int(transform.attribute("rot") ?? "") ?? 0) != 0
                || ["1", "true"].contains(transform.attribute("flipH") ?? "")
                || ["1", "true"].contains(transform.attribute("flipV") ?? "") { return true }
            if let line = properties.firstChild(named: "ln") {
                if line.firstChild(named: "gradFill") != nil || line.firstChild(named: "pattFill") != nil { return true }
                if let dash = line.firstChild(named: "prstDash")?.attribute("val"), dash != "solid" { return true }
                if line.firstChild(named: "custDash") != nil { return true }
                for end in ["headEnd", "tailEnd"] {
                    if let type = line.firstChild(named: end)?.attribute("type"), type != "none" { return true }
                }
            }
        }
        // Text set sideways or turned, and text flowing from one linked box into the next.
        if let body = shape.firstChild(named: "bodyPr") {
            if (Int(body.attribute("rot") ?? "") ?? 0) != 0 { return true }
            if let vertical = body.attribute("vert"), vertical != "horz" { return true }
        }
        if shape.firstChild(named: "linkedTxbx") != nil { return true }
        if shape.firstChild(named: "txbx")?.attribute("id") != nil { return true }
        return false
    }

    /// A chart's kinds, 3-D, labels, fills, lines and legend that Libretto draws more simply.
    static func isSimplified(chart root: XMLElement) -> Bool {
        guard let plot = descendant("plotArea", in: root) else { return false }
        let groups = plot.children.filter { element in
            chartKinds.contains { $0.0 == element.name } || roughChartGroups.contains(element.name)
        }
        if groups.contains(where: { roughChartGroups.contains($0.name) }) { return true }
        // More than one group is drawn only as columns with lines or areas over them.
        if groups.count > 1 {
            let combinable: Set<String> = ["barChart", "lineChart", "areaChart"]
            if !groups.allSatisfy({ combinable.contains($0.name) }) { return true }
            if groups.first?.firstChild(named: "barDir")?.attribute("val") == "bar" { return true }
            // On a second value axis.
            let axes = Set(groups.flatMap { $0.children(named: "axId").compactMap { $0.attribute("val") } })
            if axes.count > 2 { return true }
        }
        for group in groups {
            if group.firstChild(named: "varyColors")?.attribute("val") == "1", !["pieChart", "doughnutChart"].contains(group.name) {
                return true
            }
            for series in group.children(named: "ser") {
                if series.firstChild(named: "trendline") != nil || series.firstChild(named: "errBars") != nil { return true }
                // Points coloured one by one are drawn so only in a pie or doughnut.
                if series.firstChild(named: "dPt") != nil, !["pieChart", "doughnutChart"].contains(group.name) { return true }
                if let properties = series.firstChild(named: "spPr"),
                   properties.children.contains(where: { ["gradFill", "pattFill", "blipFill", "effectLst"].contains($0.name) && !$0.children.isEmpty }) {
                    return true
                }
            }
            for labels in descendants("dLbls", in: group) where labels.firstChild(named: "delete")?.attribute("val") != "1" {
                let shown = ["showVal", "showPercent", "showCatName", "showSerName", "showBubbleSize"]
                if shown.contains(where: { labels.firstChild(named: $0).map { ["1", "true"].contains($0.attribute("val") ?? "1") } ?? false }) {
                    return true
                }
            }
        }
        // A legend in a corner, or laid over the plot.
        if let legend = descendant("legend", in: root) {
            if legend.firstChild(named: "legendPos")?.attribute("val") == "tr" { return true }
            if legend.firstChild(named: "overlay")?.attribute("val") == "1" { return true }
        }
        return false
    }

    /// A cache's points, in their order, gaps left empty.
    private static func points(in element: XMLElement?) -> [String] {
        guard let element, let cache = descendant("numCache", in: element) ?? descendant("strCache", in: element) else { return [] }
        let count = cache.firstChild(named: "ptCount")?.attribute("val").flatMap { Int($0) } ?? 0
        var result = Array(repeating: "", count: count)
        for point in cache.children(named: "pt") {
            guard let index = point.attribute("idx").flatMap({ Int($0) }) else { continue }
            let value = point.firstChild(named: "v")?.text ?? ""
            if index < result.count { result[index] = value } else { result.append(value) }
        }
        return result
    }

    // MARK: - Helpers

    public static func descendant(_ name: String, in element: XMLElement) -> XMLElement? {
        for child in element.children {
            if child.name == name { return child }
            if let found = descendant(name, in: child) { return found }
        }
        return nil
    }

    public static func descendants(_ name: String, in element: XMLElement) -> [XMLElement] {
        element.children.flatMap { child in (child.name == name ? [child] : []) + descendants(name, in: child) }
    }
}
