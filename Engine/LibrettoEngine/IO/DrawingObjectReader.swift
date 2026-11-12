import Foundation

/// Reads the drawings that are not pictures — shapes and text boxes, charts,
/// SmartArt diagrams — into descriptions Libretto can draw.
public enum DrawingObjectReader: Sendable {
    public static let shapeURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    public static let groupURI = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
    public static let chartURI = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    public static let diagramURI = "http://schemas.openxmlformats.org/drawingml/2006/diagram"
    public static let diagramDrawingType = "http://schemas.microsoft.com/office/2007/relationships/diagramDrawing"

    /// The parts a drawing may refer to: charts' and diagrams'.
    public struct Package: Sendable {
        public var parts: [String: Data]
        public var relationships: [String: DocumentPackage.Relationship]
        public var documentPath: String

        public func part(_ id: String) -> XMLElement? {
            part(data: id).flatMap { try? XMLLite.parse($0) }
        }

        public func part(data id: String) -> Data? {
            guard let relationship = relationships[id], !relationship.isExternal else { return nil }
            return parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)]
        }

        public init(parts: [String: Data], relationships: [String: DocumentPackage.Relationship], documentPath: String) {
            self.parts = parts
            self.relationships = relationships
            self.documentPath = documentPath
        }
    }

    /// How a shape's text is read: a text box's `w:txbxContent` into paragraphs
    /// in their formatting, and the text a linked box shows, with the boxes it runs through.
    public struct TextReader {
        public var paragraphs: (XMLElement) -> [ShapeParagraph]
        public var linked: (XMLElement) -> (content: XMLElement, flow: LinkedText)?

        public init(
            paragraphs: @escaping (XMLElement) -> [ShapeParagraph],
            linked: @escaping (XMLElement) -> (content: XMLElement, flow: LinkedText)? = { _ in nil }
        ) {
            self.paragraphs = paragraphs
            self.linked = linked
        }
    }

    /// A document's linked text boxes, by the `id` their `wps:txbx` and `wps:linkedTxbx` share:
    /// the text that runs through them, and each box's text area, by its place (`seq`) in the run.
    public static func textBoxChains(in root: XMLElement) -> [String: (content: XMLElement?, areas: [Int: ShapeFrame])] {
        var chains: [String: (content: XMLElement?, areas: [Int: ShapeFrame])] = [:]
        for wsp in descendants("wsp", in: root) {
            if let box = wsp.firstChild(named: "txbx"), let id = box.attribute("id") {
                chains[id, default: (nil, [:])].content = box.firstChild(named: "txbxContent")
                chains[id, default: (nil, [:])].areas[0] = textArea(of: wsp)
            } else if let link = wsp.firstChild(named: "linkedTxbx"), let id = link.attribute("id"),
                      let place = link.attribute("seq").flatMap({ Int($0) }) {
                chains[id, default: (nil, [:])].areas[place] = textArea(of: wsp)
            }
        }
        return chains
    }

    /// How large a shape's text area is, in points: its frame, or its drawing's, less its insets.
    static func textArea(of wsp: XMLElement) -> ShapeFrame {
        var width = 0.0, height = 0.0
        if let transform = wsp.firstChild(named: "spPr")?.firstChild(named: "xfrm") {
            (_, _, width, height) = frame(transform)
        }
        var ancestor = wsp.parent
        while width <= 0 || height <= 0, let container = ancestor {
            if container.name == "anchor" || container.name == "inline", let extent = container.firstChild(named: "extent") {
                width = Double(extent.attribute("cx") ?? "") ?? 0
                height = Double(extent.attribute("cy") ?? "") ?? 0
                break
            }
            ancestor = container.parent
        }
        var shape = ShapeSpec()
        if let body = wsp.firstChild(named: "bodyPr") { readBody(body, into: &shape) }
        let insets = shape.textInsets ?? .word
        return ShapeFrame(
            x: 0, y: 0, width: max(1, width / 12_700 - insets.left - insets.right),
            height: max(1, height / 12_700 - insets.top - insets.bottom)
        )
    }

    /// The object an `wp:inline` or `wp:anchor` holds, if it is one Libretto can draw;
    /// its shapes' text in its formatting, if there is a `text` reader to read it.
    public static func object(in container: XMLElement, package: Package, text: TextReader? = nil) -> DrawingObject? {
        guard let data = descendant("graphicData", in: container) else { return nil }
        switch data.attribute("uri") {
        case shapeURI?:
            return data.firstChild(named: "wsp").map { .shape(shape($0, text: text)) }
        case groupURI?:
            return data.firstChild(named: "wgp").flatMap { group($0, text: text) }.map { .group($0) }
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

    public static func shape(_ wsp: XMLElement, text: TextReader? = nil) -> ShapeSpec {
        var shape = ShapeSpec()
        let properties = wsp.firstChild(named: "spPr")
        let style = wsp.firstChild(named: "style")
        read(properties: properties, style: style, into: &shape)
        // A linked box shows its part of the text that runs through the boxes it is linked to.
        let linked = text?.linked(wsp)
        shape.linkedText = linked?.flow
        if let content = linked?.content ?? descendant("txbxContent", in: wsp) {
            shape.isTextBox = true
            shape.text = content.children(named: "p").map { HeaderFooterReader.plainText(of: $0) }.joined(separator: "\n")
            if let rPr = descendant("rPr", in: content) {
                shape.textColorHex = rPr.firstChild(named: "color")?.attribute("val").flatMap { $0 == "auto" ? nil : $0.uppercased() }
                shape.fontSize = rPr.firstChild(named: "sz")?.attribute("val").flatMap(Double.init).map { $0 / 2 }
            }
            // In its own formatting, where its paragraphs read as the text does.
            if let paragraphs = text?.paragraphs(content), !paragraphs.isEmpty,
               paragraphs.map(\.text).joined(separator: "\n") == shape.text {
                shape.paragraphs = paragraphs
            }
        }
        if let body = wsp.firstChild(named: "bodyPr") { readBody(body, into: &shape) }
        shape.originalText = shape.text
        return shape
    }

    /// Where a shape's text sits, and how far in from its edges.
    static func readBody(_ body: XMLElement, into shape: inout ShapeSpec) {
        shape.textAnchor = body.attribute("anchor").flatMap(ShapeSpec.TextAnchor.init(rawValue:))
        switch body.attribute("vert") {
        case "vert"?, "eaVert"?: shape.textDirection = .down
        case "vert270"?: shape.textDirection = .up
        default: shape.textDirection = .horizontal
        }
        let names = ["lIns", "tIns", "rIns", "bIns"]
        if names.contains(where: { body.attribute($0) != nil }) {
            let word = ShapeInsets.word
            let defaults = [word.left, word.top, word.right, word.bottom]
            let values = zip(names, defaults).map { name, fallback in
                body.attribute(name).flatMap(Double.init).map { max(0, $0) / 12_700 } ?? fallback
            }
            shape.textInsets = ShapeInsets(left: values[0], top: values[1], right: values[2], bottom: values[3])
        }
    }

    // MARK: - Groups

    /// A point in a group's own units and where it is in its parent's: `x' = scale × x + offset`.
    struct GroupMapping {
        var scaleX = 1.0, offsetX = 0.0, scaleY = 1.0, offsetY = 0.0

        /// A frame in this group's units, in its parent's.
        func frame(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
            (scaleX * x + offsetX, scaleY * y + offsetY, scaleX * width, scaleY * height)
        }

        /// A group within this one, whose `a:xfrm` sets its children's units (`chOff`, `chExt`)
        /// into the frame it has in this one's (`off`, `ext`).
        func child(_ transform: XMLElement?) -> GroupMapping {
            guard let transform else { return self }
            let (x, y, width, height) = DrawingObjectReader.frame(transform)
            let childX = number(transform.firstChild(named: "chOff"), "x") ?? x
            let childY = number(transform.firstChild(named: "chOff"), "y") ?? y
            let childWidth = number(transform.firstChild(named: "chExt"), "cx") ?? width
            let childHeight = number(transform.firstChild(named: "chExt"), "cy") ?? height
            let inner = GroupMapping(
                scaleX: childWidth > 0 ? width / childWidth : 1, offsetX: x - childX * (childWidth > 0 ? width / childWidth : 1),
                scaleY: childHeight > 0 ? height / childHeight : 1, offsetY: y - childY * (childHeight > 0 ? height / childHeight : 1)
            )
            return GroupMapping(
                scaleX: scaleX * inner.scaleX, offsetX: scaleX * inner.offsetX + offsetX,
                scaleY: scaleY * inner.scaleY, offsetY: scaleY * inner.offsetY + offsetY
            )
        }

        private func number(_ element: XMLElement?, _ name: String) -> Double? {
            element?.attribute(name).flatMap(Double.init)
        }
    }

    /// An `a:xfrm`'s offset and extent, in EMUs.
    static func frame(_ transform: XMLElement) -> (x: Double, y: Double, width: Double, height: Double) {
        func value(_ element: XMLElement?, _ name: String) -> Double { element?.attribute(name).flatMap(Double.init) ?? 0 }
        let offset = transform.firstChild(named: "off")
        let extent = transform.firstChild(named: "ext")
        return (value(offset, "x"), value(offset, "y"), value(extent, "cx"), value(extent, "cy"))
    }

    /// A `wpg:wgp`'s shapes, those of the groups within it too, each framed in points
    /// from the group's corner by its children's offset and extent (`chOff`, `chExt`).
    public static func group(_ wgp: XMLElement, text: TextReader? = nil) -> ShapeGroup? {
        guard let transform = wgp.firstChild(named: "grpSpPr")?.firstChild(named: "xfrm") else { return nil }
        let (_, _, width, height) = frame(transform)
        guard width > 0, height > 0 else { return nil }
        // The group's own frame from its corner; its children's units into it.
        var mapping = GroupMapping().child(transform)
        let (x, y, _, _) = frame(transform)
        mapping.offsetX -= x
        mapping.offsetY -= y
        var shapes: [ShapeSpec] = []
        func collect(_ group: XMLElement, _ mapping: GroupMapping) {
            for child in group.children {
                switch child.name {
                case "wsp":
                    var shape = shape(child, text: text)
                    guard let transform = child.firstChild(named: "spPr")?.firstChild(named: "xfrm") else { continue }
                    let (x, y, width, height) = frame(transform)
                    let placed = mapping.frame(x: x, y: y, width: width, height: height)
                    shape.frame = ShapeFrame(
                        x: placed.x / 12_700, y: placed.y / 12_700, width: placed.width / 12_700, height: placed.height / 12_700
                    )
                    shapes.append(shape)
                case "grpSp":
                    collect(child, mapping.child(child.firstChild(named: "grpSpPr")?.firstChild(named: "xfrm")))
                default:
                    continue
                }
            }
        }
        collect(wgp, mapping)
        return shapes.isEmpty ? nil : ShapeGroup(width: width / 12_700, height: height / 12_700, shapes: shapes)
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
        if let transform = properties?.firstChild(named: "xfrm") {
            shape.rotation = (Double(transform.attribute("rot") ?? "") ?? 0) / 60_000
            shape.flipsHorizontally = ["1", "true"].contains(transform.attribute("flipH") ?? "")
            shape.flipsVertically = ["1", "true"].contains(transform.attribute("flipV") ?? "")
        }
        if properties?.firstChild(named: "noFill") != nil {
            shape.fillHex = nil
        } else if let fill = properties?.firstChild(named: "solidFill") {
            shape.fillHex = color(in: fill)
        } else if let fill = properties?.firstChild(named: "gradFill"), let read = gradient(fill) {
            shape.gradient = read
            shape.fillHex = read.stops.first?.colorHex
        } else if let fill = properties?.firstChild(named: "pattFill") {
            // Word's own colours, black on white, where it gives none.
            let foreground = color(in: fill.firstChild(named: "fgClr")) ?? "000000"
            let background = color(in: fill.firstChild(named: "bgClr")) ?? "FFFFFF"
            shape.pattern = ShapePattern(
                preset: fill.attribute("prst") ?? "pct5", foregroundHex: foreground, backgroundHex: background
            )
            shape.fillHex = background
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

    /// An `a:gradFill`'s stops, in order, and which way it runs.
    static func gradient(_ fill: XMLElement) -> ShapeGradient? {
        let stops = fill.firstChild(named: "gsLst")?.children(named: "gs").compactMap { stop -> ShapeGradient.Stop? in
            guard let hex = color(in: stop) else { return nil }
            let position = (Double(stop.attribute("pos") ?? "") ?? 0) / 100_000
            return ShapeGradient.Stop(position: min(1, max(0, position)), colorHex: hex, alpha: alpha(in: stop))
        }.sorted { $0.position < $1.position } ?? []
        guard !stops.isEmpty else { return nil }
        let kind: ShapeGradient.Kind
        if let path = fill.firstChild(named: "path") {
            let rect = path.firstChild(named: "fillToRect")
            func fraction(_ name: String) -> Double { (Double(rect?.attribute(name) ?? "") ?? 0) / 100_000 }
            kind = .path(
                focus: ShapeInsets(left: fraction("l"), top: fraction("t"), right: fraction("r"), bottom: fraction("b")),
                isCircle: path.attribute("path") == "circle"
            )
        } else {
            let line = fill.firstChild(named: "lin")
            kind = .linear(
                angle: (Double(line?.attribute("ang") ?? "") ?? 0) / 60_000,
                scaled: ["1", "true"].contains(line?.attribute("scaled") ?? "")
            )
        }
        let turns = !["0", "false"].contains(fill.attribute("rotWithShape") ?? "1")
        return ShapeGradient(stops: stops, kind: kind, turnsWithShape: turns)
    }

    /// How solid the colour an element holds is: its `a:alpha`, from 0 to 1.
    public static func alpha(in element: XMLElement?) -> Double {
        guard let element else { return 1 }
        for child in element.children where ["srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr", "hslClr"].contains(child.name) {
            guard let value = child.firstChild(named: "alpha")?.attribute("val").flatMap(Double.init) else { return 1 }
            return min(1, max(0, value / 100_000))
        }
        return 1
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
        case groupURI?:
            return data.firstChild(named: "wgp").map(isSimplified(group:)) ?? false
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
            let effects: Set<String> = ["blipFill", "grpFill", "custGeom", "scene3d", "sp3d"]
            if properties.children.contains(where: { effects.contains($0.name) }) { return true }
            if let pattern = properties.firstChild(named: "pattFill"),
               ShapePattern.isForeground(pattern.attribute("prst") ?? "pct5", x: 0, y: 0) == nil { return true }
            // A gradient out to a rectangle or the shape's own path is drawn as one out to a circle.
            if let path = properties.firstChild(named: "gradFill")?.firstChild(named: "path"),
               path.attribute("path") != "circle" { return true }
            if let list = properties.firstChild(named: "effectLst"), !list.children.isEmpty { return true }
            if properties.firstChild(named: "effectDag") != nil { return true }
            if let geometry = properties.firstChild(named: "prstGeom")?.attribute("prst"),
               !ShapeSpec.drawnGeometries.contains(geometry) { return true }
            if let line = properties.firstChild(named: "ln") {
                if line.firstChild(named: "gradFill") != nil || line.firstChild(named: "pattFill") != nil { return true }
                if let dash = line.firstChild(named: "prstDash")?.attribute("val"), dash != "solid" { return true }
                if line.firstChild(named: "custDash") != nil { return true }
                for end in ["headEnd", "tailEnd"] {
                    if let type = line.firstChild(named: end)?.attribute("type"), type != "none" { return true }
                }
            }
        }
        // Text set sideways or turned.
        if let body = shape.firstChild(named: "bodyPr") {
            if (Int(body.attribute("rot") ?? "") ?? 0) != 0 { return true }
            if let vertical = body.attribute("vert"), !["horz", "vert", "vert270", "eaVert"].contains(vertical) { return true }
        }
        return false
    }

    /// A group's shapes drawn more simply, and what it holds that is not drawn: pictures, charts,
    /// ink. A group turned or flipped as a whole is drawn unturned.
    static func isSimplified(group: XMLElement) -> Bool {
        for child in group.children {
            switch child.name {
            case "wsp":
                if isSimplified(shape: child) { return true }
            case "grpSp":
                if isSimplified(group: child) { return true }
            case "grpSpPr", "cNvGrpSpPr", "cNvPr", "nvGrpSpPr":
                if let transform = child.firstChild(named: "xfrm"), isTurned(transform) { return true }
            default:
                return true
            }
        }
        return false
    }

    /// Whether an `a:xfrm` turns or flips what it frames.
    static func isTurned(_ transform: XMLElement) -> Bool {
        (Int(transform.attribute("rot") ?? "") ?? 0) != 0
            || ["1", "true"].contains(transform.attribute("flipH") ?? "")
            || ["1", "true"].contains(transform.attribute("flipV") ?? "")
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

    /// Whether data is a picture every platform decodes: PNG, JPEG, GIF, BMP or TIFF, but not EMF or WMF.
    public static func isRasterPicture(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4 else { return false }
        return bytes == [0x89, 0x50, 0x4E, 0x47] || bytes.starts(with: [0xFF, 0xD8]) || bytes.starts(with: [0x47, 0x49, 0x46])
            || bytes.starts(with: [0x42, 0x4D]) || bytes == [0x49, 0x49, 0x2A, 0x00] || bytes == [0x4D, 0x4D, 0x00, 0x2A]
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
