import Foundation
import LibrettoEngine

/// Turns a document into what the page draws and edits: the web's counterpart
/// of `DocumentRenderer` and `Typography`, making the same decisions about
/// styles, fonts, colours, list labels and table looks, but describing them as
/// JSON for the browser to lay out rather than as attributed text.
///
/// Paragraphs become runs of text, each naming the inline it was rendered from
/// (its *reference*), so that reading the page's edits back keeps what the text
/// does not show: formatting, links, tracked changes, fields and the XML they
/// came from, as the attributed text's boxes keep them on Apple platforms.
/// Markers, such as bookmarks and comment ranges, ride on the run after them.
///
/// Run and paragraph looks are shared through tables, as most text in a
/// document looks like the text around it.
struct WebRenderer {
    let document: WordDocument
    /// Each run's inline, by reference.
    private(set) var references: [Inline] = []
    /// Run looks, by index, and the index of each.
    private var runStyles: [[String: Any]] = []
    private var runStyleIndex: [String: Int] = [:]
    /// The pictures the document shows, by relationship ID.
    private(set) var pictures: Set<String> = []
    private var counter: ListCounter
    private let noteNumbers: [String: String]

    init(document: WordDocument) {
        self.document = document
        counter = ListCounter(styles: document.styles, numbering: document.numbering)
        noteNumbers = NoteNumbering.numbers(in: document)
    }

    /// The whole document: its blocks, the run looks they use, and its sections.
    mutating func render() -> [String: Any] {
        let blocks = document.body.map { self.block($0) }
        let defaults = defaults()
        return [
            "blocks": blocks,
            "runStyles": runStyles,
            "sections": sections(),
            "evenAndOdd": document.evenAndOddHeaders,
            "defaults": defaults,
        ]
    }

    // MARK: - Blocks

    private mutating func block(_ block: Block, cell: CellAppearance? = nil) -> [String: Any] {
        switch block {
        case .paragraph(let paragraph):
            return self.paragraph(paragraph, cell: cell)
        case .table(let table):
            return self.table(table)
        case .preserved(let preserved):
            return [
                "k": "x", "id": preserved.id.uuidString,
                "t": preserved.displayText.isEmpty
                    ? String(localized: "Block.Preserved.Placeholder", bundle: .engine) : preserved.displayText,
            ]
        }
    }

    private mutating func paragraph(_ paragraph: Paragraph, cell: CellAppearance? = nil) -> [String: Any] {
        var styles = document.styles
        if let cell {
            // A table style's formatting sits above the document's defaults and below its styles.
            styles.defaultRunStyle = styles.defaultRunStyle.merged(with: cell.condition.runStyle)
            styles.defaultParagraphProperties = styles.defaultParagraphProperties.merged(with: cell.condition.paragraphProperties)
        }
        let direct = paragraph.properties
        let resolved = styles.resolvedParagraphProperties(direct)
        var output: [String: Any] = ["k": "p", "id": paragraph.id.uuidString]
        let label = counter.label(for: direct)
        output["s"] = paragraphLook(direct: direct, resolved: resolved, isListItem: label != nil)
        if let label {
            output["l"] = label
            output["ls"] = runStyle(
                paragraph.inlines.first(where: { !$0.content.isMarker })?.format.style ?? RunStyle(),
                paragraphStyleID: direct.styleID, styles: styles, background: cell?.fillHex
            )
        }
        if let styleID = direct.styleID ?? document.styles.defaultParagraphStyleID { output["st"] = styleID }
        if let level = document.styles.headingLevel(ofStyle: direct.styleID) { output["h"] = level }
        if resolved.pageBreakBefore == true { output["pb"] = true }
        if resolved.keepNext == true { output["kn"] = true }
        if let section = paragraph.section { output["sb"] = section.start.rawValue }

        var runs: [[String: Any]] = []
        var markers: [Int] = []
        let background = resolved.shadingHex ?? cell?.fillHex
        for inline in paragraph.inlines {
            let reference = references.count
            references.append(inline)
            if inline.content.isMarker {
                markers.append(reference)
                continue
            }
            var run: [String: Any] = [
                "r": reference,
                "s": runStyle(inline.format.style, paragraphStyleID: direct.styleID, styles: styles,
                              hyperlink: inline.hyperlink, background: background),
            ]
            if !markers.isEmpty {
                run["m"] = markers
                markers = []
            }
            switch inline.content {
            case .text(let text):
                run["t"] = text.replacingOccurrences(of: "\n", with: TextCharacters.lineBreak)
            case .tab:
                run["k"] = "tab"
            case .lineBreak:
                run["k"] = "br"
            case .pageBreak:
                run["k"] = "page"
            case .columnBreak:
                run["k"] = "col"
            case .image(let image):
                run["k"] = "img"
                run.merge(picture(image)) { _, new in new }
            case .note:
                run["k"] = "tok"
                run["note"] = true
                run["t"] = Self.display(of: inline, noteNumbers: noteNumbers)
            case .paragraphChild(let xml, _) where Self.isEquation(xml):
                // An equation reads as its linear form, as the equation panel edits it.
                run["k"] = "tok"
                run["eq"] = true
                run["t"] = Self.display(of: inline, noteNumbers: noteNumbers)
            case .runChild, .paragraphChild:
                run["k"] = "tok"
                run["t"] = Self.display(of: inline, noteNumbers: noteNumbers)
            }
            if let hyperlink = inline.hyperlink {
                if let url = hyperlink.url ?? hyperlink.relationshipID.flatMap(linkTarget) {
                    run["href"] = url.absoluteString
                } else if let anchor = hyperlink.anchor {
                    run["href"] = "#" + anchor
                }
            }
            if let revision = inline.revision {
                run["rev"] = ["k": revision.kind.adds ? "ins" : "del", "a": revision.author ?? ""]
            }
            runs.append(run)
        }
        output["r"] = runs
        if !markers.isEmpty { output["m"] = markers }
        if let revision = paragraph.markRevision {
            output["rev"] = ["k": revision.kind.adds ? "ins" : "del", "a": revision.author ?? ""]
        }
        return output
    }

    nonisolated(unsafe) private static let equationPattern = #/^<(?:[\w.\-]+:)?oMath(?:Para)?\b/#

    /// Whether a kept element is an equation.
    static func isEquation(_ xml: String) -> Bool { xml.firstMatch(of: equationPattern) != nil }

    /// What a run that is not text shows, and so how long it is on the page: a
    /// note's number, an equation's linear form, a field's result. `nil` for text.
    static func display(of inline: Inline, noteNumbers: [String: String]) -> String? {
        switch inline.content {
        case .note(let note):
            return noteNumbers["\(note.kind.rawValue):\(note.id)"] ?? "*"
        case .paragraphChild(let xml, let display) where isEquation(xml):
            return display ?? LinearMath.linear(fromXML: xml)
        case .runChild(_, let display), .paragraphChild(_, let display):
            return display ?? ""
        default:
            return nil
        }
    }

    private func linkTarget(_ relationshipID: String) -> URL? {
        if let target = document.package.addedLinks[relationshipID] { return URL(string: target) }
        guard let relationship = document.package.relationships[relationshipID], relationship.isExternal else { return nil }
        return URL(string: relationship.target)
    }

    private mutating func picture(_ image: InlineImage) -> [String: Any] {
        var output: [String: Any] = ["w": image.width, "h": image.height]
        if let object = image.object {
            switch object {
            case .shape(let shape):
                output["obj"] = "shape"
                output["text"] = shape.text
                if let fill = shape.fillHex { output["fill"] = colors(fill, isText: false) }
                if let line = shape.lineHex { output["line"] = colors(line, isText: false) }
            case .chart(let chart):
                output["obj"] = "chart"
                output["text"] = chart.title ?? ""
            case .diagram(let shapes):
                output["obj"] = "diagram"
                output["text"] = shapes.map(\.text).filter { !$0.isEmpty }.joined(separator: " · ")
            }
        } else {
            pictures.insert(image.relationshipID)
            output["id"] = image.relationshipID
            if !image.crop.isEmpty {
                output["crop"] = [image.crop.left, image.crop.top, image.crop.right, image.crop.bottom]
            }
        }
        if image.isFloating {
            output["wrap"] = image.wrap.rawValue
            if let alignment = image.alignment { output["align"] = alignment.rawValue }
        }
        return output
    }

    private mutating func table(_ table: Table) -> [String: Any] {
        let appearances = TableStyling.appearances(of: table, styles: document.styles)
        let hasBorders = table.hasBorders || document.styles.tableHasBorders(styleID: table.styleID)
        var output: [String: Any] = [
            "k": "t", "id": table.id.uuidString,
            "w": table.gridColumns.map { Double($0) / 20 },
            "b": hasBorders,
        ]
        if let color = table.borderColorHex ?? document.styles.tableBorderColor(styleID: table.styleID) {
            output["bc"] = colors(color, isText: false)
        }
        output["rows"] = table.rows.enumerated().map { rowIndex, row -> [String: Any] in
            var rowOutput: [String: Any] = ["id": row.id.uuidString]
            if row.isHeader { rowOutput["hd"] = true }
            rowOutput["c"] = row.cells.enumerated().map { cellIndex, cell -> [String: Any] in
                let appearance = appearances[rowIndex][cellIndex]
                var cellOutput: [String: Any] = [
                    "id": cell.id.uuidString,
                    "b": cell.blocks.map { self.block($0, cell: appearance) },
                ]
                if cell.gridSpan > 1 { cellOutput["span"] = cell.gridSpan }
                switch cell.verticalMerge {
                case .restart: cellOutput["vm"] = "r"
                case .continue: cellOutput["vm"] = "c"
                case nil: break
                }
                if let fill = appearance.fillHex { cellOutput["bg"] = colors(fill, isText: false) }
                return cellOutput
            }
            return rowOutput
        }
        return output
    }

    // MARK: - Looks

    /// Points, from twentieths of a point.
    private func points(_ twips: Int?) -> Double? {
        twips.map { Double($0) / 20 }
    }

    private func paragraphLook(direct: ParagraphProperties, resolved: ParagraphProperties, isListItem: Bool) -> [String: Any] {
        var look: [String: Any] = [:]
        switch resolved.alignment ?? .leading {
        case .leading: break
        case .center: look["a"] = "center"
        case .trailing: look["a"] = "right"
        case .justified: look["a"] = "justify"
        }
        // A list level's indentation sits between the style's and the paragraph's own.
        let level = ListCounter.listReference(resolved).flatMap { document.numbering.level($0.level, of: $0.numberingID) }
        let left = direct.indentLeft ?? level?.indentLeft ?? resolved.indentLeft ?? 0
        let firstLine = direct.indentFirstLine ?? level.flatMap { $0.hanging.map { -$0 } } ?? resolved.indentFirstLine ?? 0
        if left != 0 { look["il"] = Double(max(0, left)) / 20 }
        if let right = resolved.indentRight, right != 0 { look["ir"] = Double(max(0, right)) / 20 }
        if firstLine != 0 { look["fi"] = Double(firstLine) / 20 }
        if isListItem { look["li"] = true }
        look["sb"] = points(resolved.spacingBefore) ?? 0
        look["sa"] = points(resolved.spacingAfter) ?? 0
        if let spacing = resolved.lineSpacing {
            switch spacing.rule {
            case .auto: look["lm"] = Double(spacing.line) / 240
            case .exact: look["le"] = Double(spacing.line) / 20
            case .atLeast: look["ll"] = Double(spacing.line) / 20
            }
        }
        if let shading = resolved.shadingHex { look["bg"] = colors(shading, isText: false) }
        if let borders = resolved.borders, !borders.isEmpty {
            var edges: [String: Any] = [:]
            for (key, line) in [("t", borders.top), ("l", borders.left), ("b", borders.bottom), ("r", borders.right)] {
                guard let line, line.style != "none", line.style != "nil" else { continue }
                edges[key] = [
                    "w": max(0.5, Double(line.size) / 8), "s": line.style == "double" ? "double"
                        : line.style.contains("dash") ? "dashed" : line.style.contains("dot") ? "dotted" : "solid",
                    "c": colors(line.colorHex ?? "000000", isText: true), "p": Double(line.space),
                ]
            }
            if !edges.isEmpty { look["bd"] = edges }
        }
        if let stops = resolved.tabStops?.filter({ $0.alignment != .clear && $0.alignment != .bar }), !stops.isEmpty {
            look["tabs"] = stops.map { ["p": Double($0.position) / 20, "a": $0.alignment.rawValue] }
        }
        if let dropCap = resolved.dropCap { look["dc"] = dropCap.lines }
        return look
    }

    /// The index of a run look in the shared table.
    private mutating func runStyle(
        _ direct: RunStyle, paragraphStyleID: String?, styles: StyleSheet, hyperlink: Hyperlink? = nil, background: String?
    ) -> Int {
        var style = styles.resolvedRunStyle(direct, paragraphStyleID: paragraphStyleID ?? styles.defaultParagraphStyleID)
        if hyperlink != nil, style.colorHex == nil {
            // A link the document gave no colour of its own still reads as one.
            style.colorHex = "0563C1"
            style.underline = style.underline ?? true
        }
        var look: [String: Any] = [:]
        if let family = fontFamily(style.fontName, styles: styles) { look["f"] = family }
        look["z"] = Double(style.fontSize ?? 22) / 2
        if style.isBold == true { look["b"] = true }
        if style.isItalic == true { look["i"] = true }
        if style.underline == true { look["u"] = style.underlineStyle ?? "single" }
        if style.isDoubleStruckThrough == true {
            look["x"] = 2
        } else if style.isStruckThrough == true {
            look["x"] = 1
        }
        let highlight = style.highlight.flatMap { RunStyle.highlightColors[$0] }
        if let highlight { look["hl"] = colors(highlight, isText: false) }
        let behind = highlight ?? background
        if let text = style.colorHex ?? (behind != nil ? "000000" : nil) {
            look["c"] = textColors(text, on: behind)
        }
        switch style.verticalAlignment {
        case .superscript: look["v"] = "super"
        case .subscript: look["v"] = "sub"
        default: break
        }
        if let position = style.position, position != 0 { look["pos"] = Double(position) / 2 }
        if style.allCaps == true { look["caps"] = true }
        if style.smallCaps == true { look["sc"] = true }
        if let spacing = style.characterSpacing, spacing != 0 { look["ls"] = Double(spacing) / 20 }
        if style.outline == true { look["o"] = true }
        if style.shadow == true { look["sh"] = true }
        if style.emboss == true || style.imprint == true { look["em"] = style.emboss == true ? "emboss" : "imprint" }

        let key = Self.key(look)
        if let index = runStyleIndex[key] { return index }
        runStyles.append(look)
        runStyleIndex[key] = runStyles.count - 1
        return runStyles.count - 1
    }

    private static func key(_ look: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: look, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Fonts Word documents name that are seldom installed, and ones like them that often are.
    private static let substitutes: [String: [String]] = [
        "Calibri": ["Carlito"], "Cambria": ["Caladea", "Georgia"], "Constantia": ["Georgia"],
        "Book Antiqua": ["Palatino", "Palatino Linotype"], "Garamond": ["EB Garamond", "Baskerville"],
        "Century": ["Georgia"], "Consolas": ["Menlo", "Monaco"], "Lucida Console": ["Menlo", "Monaco"],
        "Times New Roman": ["Times", "Liberation Serif"], "Arial": ["Helvetica", "Liberation Sans"],
        "Courier New": ["Courier", "Liberation Mono"],
        "MS Mincho": ["Hiragino Mincho ProN", "Yu Mincho"], "ＭＳ 明朝": ["Hiragino Mincho ProN", "Yu Mincho"],
        "Yu Mincho": ["Hiragino Mincho ProN"], "游明朝": ["Hiragino Mincho ProN"],
        "MS Gothic": ["Hiragino Sans", "Yu Gothic"], "ＭＳ ゴシック": ["Hiragino Sans", "Yu Gothic"],
        "Yu Gothic": ["Hiragino Sans"], "游ゴシック": ["Hiragino Sans"], "Meiryo": ["Hiragino Sans"],
        "メイリオ": ["Hiragino Sans"], "SimSun": ["PingFang SC"], "宋体": ["PingFang SC"],
        "Microsoft YaHei": ["PingFang SC"], "PMingLiU": ["PingFang TC"], "Microsoft JhengHei": ["PingFang TC"],
        "Malgun Gothic": ["Apple SD Gothic Neo"], "Batang": ["Apple SD Gothic Neo"], "맑은 고딕": ["Apple SD Gothic Neo"],
    ]

    private static let monospaced: Set = ["Consolas", "Courier New", "Courier", "Menlo", "Monaco", "Lucida Console", "SF Mono"]
    private static let serif: Set = [
        "Times New Roman", "Times", "Georgia", "Cambria", "Constantia", "Garamond", "Book Antiqua", "Palatino",
        "Baskerville", "Century", "Hoefler Text", "MS Mincho", "ＭＳ 明朝", "Yu Mincho", "游明朝", "SimSun", "宋体",
        "PMingLiU", "Batang", "Hiragino Mincho ProN",
    ]

    /// A CSS font stack for a family: the family, what stands in for it, then a
    /// generic family like it. `nil` for the system font, as the Apple apps
    /// set text with no font of its own.
    private func fontFamily(_ name: String?, styles: StyleSheet) -> String? {
        var family = name
        if family == RunStyle.minorThemeFont { family = styles.minorFont }
        if family == RunStyle.majorThemeFont { family = styles.majorFont }
        guard let family, !family.isEmpty else { return nil }
        let generic = Self.monospaced.contains(family) ? "monospace"
            : Self.serif.contains(family) ? "serif" : "system-ui, sans-serif"
        let stack = ([family] + (Self.substitutes[family] ?? [])).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        return (stack + [generic]).joined(separator: ", ")
    }

    /// A colour as `#RRGGBB` in light appearance, and as adapted for dark.
    private func colors(_ hex: String, isText: Bool) -> [String] {
        let light = Self.css(hex)
        let dark = AdaptiveColor.resolve(hex: hex, for: .dark, isText: isText)?.argbHex.map(Self.css) ?? light
        return [light, dark]
    }

    private func textColors(_ hex: String, on background: String?) -> [String] {
        let light = Self.css(hex)
        let dark = AdaptiveColor.resolveText(hex: hex, on: background, for: .dark)?.argbHex.map(Self.css) ?? light
        return [light, dark]
    }

    /// `#RRGGBB` from OOXML's `RRGGBB` or `AARRGGBB`.
    private static func css(_ hex: String) -> String {
        "#" + String(hex.trimmingCharacters(in: .whitespaces).suffix(6)).lowercased()
    }

    // MARK: - Sections

    /// Each section's page size, margins, columns, and headers and footers, in order.
    private func sections() -> [[String: Any]] {
        let setups = document.body.compactMap { block -> PageSetup? in
            if case .paragraph(let paragraph) = block { return paragraph.section }
            return nil
        } + [document.pageSetup]
        let layout = WordDocumentHeaderFooter(document: document, sections: setups)
        return zip(setups, layout.sections).map { setup, section in
            var output: [String: Any] = [
                "w": Double(setup.width) / 20, "h": Double(setup.height) / 20,
                "mt": Double(setup.marginTop) / 20, "mb": Double(setup.marginBottom) / 20,
                "ml": Double(setup.marginLeft) / 20, "mr": Double(setup.marginRight) / 20,
                "hd": Double(section.headerDistance), "fd": Double(section.footerDistance),
                "start": setup.start.rawValue, "cols": setup.columns,
                "title": section.titlePage,
            ]
            if let format = section.pageNumberFormat { output["nf"] = format }
            func texts(_ parts: [HeaderFooterKind: HeaderFooterText]) -> [String: Any] {
                parts.reduce(into: [:]) { result, entry in
                    guard !entry.value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    result[entry.key.rawValue] = ["t": entry.value.text, "a": entry.value.alignment.rawValue]
                }
            }
            output["head"] = texts(section.headers)
            output["foot"] = texts(section.footers)
            return output
        }
    }

    /// The document's default look, for text typed where there is none.
    private mutating func defaults() -> [String: Any] {
        let styles = document.styles
        let resolved = styles.resolvedParagraphProperties(ParagraphProperties())
        return [
            "s": paragraphLook(direct: ParagraphProperties(), resolved: resolved, isListItem: false),
            "r": runStyle(RunStyle(), paragraphStyleID: nil, styles: styles, background: nil),
        ]
    }
}
