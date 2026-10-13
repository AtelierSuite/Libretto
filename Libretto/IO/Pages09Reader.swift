import CoreGraphics
import Foundation

/// Reads a document from Pages '09 and before, whose package holds the whole
/// document as `index.xml`, gzipped when the package is a folder.
///
/// The body text comes across with its paragraph and character formatting,
/// lists, links, inline pictures, tables and footnotes, and the page's size,
/// margins, headers and footers. A page layout document's text boxes,
/// pictures and tables are read in page order; objects placed on the pages
/// of a word-processing document are left out.
enum Pages09Reader {
    /// The document's XML, if the package is one of these.
    static func index(in files: [String: Data]) throws -> Data? {
        if let index = files["index.xml"] { return index }
        guard let compressed = files["index.xml.gz"] else { return nil }
        guard let index = gunzip(compressed) else { throw IWorkError.corrupt("index.xml.gz") }
        return index
    }

    static func document(fromIndex index: Data, files: [String: Data]) throws -> WordDocument {
        let root = try Node.parse(index)
        guard root.name == "document" else { throw IWorkError.notAnIWorkDocument }
        var converter = Pages09Converter(root: root, files: files)
        return converter.convert()
    }

    /// A gzip member: a ten-byte header, optional fields the flags name, raw
    /// DEFLATE, then the CRC and the length, modulo 2³², of what it inflates to.
    static func gunzip(_ data: Data) -> Data? {
        // Read in place, by offsets from the start, and inflate a slice of the input rather than a copy.
        let count = data.count
        func byte(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }
        guard count >= 18, byte(0) == 0x1F, byte(1) == 0x8B, byte(2) == 8 else { return nil }
        let flags = byte(3)
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= count else { return nil }
            offset += 2 + (Int(byte(offset)) | Int(byte(offset + 1)) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < count, byte(offset) != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < count - 8 else { return nil }
        let size = (count - 4..<count).reversed().reduce(0) { $0 << 8 | Int(byte($1)) }
        return ZipArchive.inflate(data[(data.startIndex + offset)..<(data.startIndex + count - 8)], expectedSize: size)
    }

    /// An element, its attributes by local name, and its text and elements in order.
    final class Node {
        enum Child {
            case element(Node)
            case text(String)
        }

        let name: String
        let attributes: [String: String]
        fileprivate(set) var children: [Child] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        var elements: [Node] {
            children.compactMap { if case .element(let node) = $0 { node } else { nil } }
        }

        func first(_ name: String) -> Node? {
            for case .element(let node) in children where node.name == name { return node }
            return nil
        }

        /// Every element below this one, depth first, in document order.
        func descendants(where include: (Node) -> Bool) -> [Node] {
            var result: [Node] = []
            var stack = Array(elements.reversed())
            while let node = stack.popLast() {
                if include(node) { result.append(node) }
                stack += node.elements.reversed()
            }
            return result
        }

        static func parse(_ data: Data) throws -> Node {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.delegate = builder
            guard parser.parse(), let root = builder.root else {
                throw IWorkError.corrupt(builder.failure ?? parser.parserError?.localizedDescription ?? "index.xml")
            }
            return root
        }

        private final class Builder: NSObject, XMLParserDelegate {
            var root: Node?
            var failure: String?
            private var stack: [Node] = []

            private func localName(_ qualified: String) -> String {
                guard let colon = qualified.lastIndex(of: ":") else { return qualified }
                return String(qualified[qualified.index(after: colon)...])
            }

            func parser(
                _ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
            ) {
                guard stack.count < XMLLite.maximumDepth else {
                    failure = "The document is nested too deeply to open."
                    parser.abortParsing()
                    return
                }
                var local: [String: String] = [:]
                for (key, value) in attributes { local[localName(key)] = value }
                let node = Node(name: localName(elementName), attributes: local)
                if let parent = stack.last {
                    parent.children.append(.element(node))
                } else {
                    root = node
                }
                stack.append(node)
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                guard let parent = stack.last else { return }
                if case .text(var previous) = parent.children.last {
                    // Emptied first, so the text is appended to in place rather than copied.
                    parent.children[parent.children.count - 1] = .text("")
                    previous += string
                    parent.children[parent.children.count - 1] = .text(previous)
                } else {
                    parent.children.append(.text(string))
                }
            }

            func parser(
                _ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?
            ) {
                stack.removeLast()
            }
        }
    }
}

private typealias Node = Pages09Reader.Node

// MARK: - Conversion

private struct Pages09Converter {
    let root: Node
    let files: [String: Data]
    var document: WordDocument = {
        var document = WordDocument()
        document.importedFormat = .pages
        return document
    }()

    /// Elements by `sfa:ID`, and styles by `sf:ident`, those of the body's own stylesheet first.
    private var byID: [String: Node] = [:]
    private var byIdent: [String: Node] = [:]
    private var paragraphStyles: [ObjectIdentifier: (PagesParagraphProperties, PagesCharacterProperties)] = [:]
    private var characterStyles: [ObjectIdentifier: PagesCharacterProperties] = [:]
    private var textEffectStyles: [ObjectIdentifier: TextEffects] = [:]
    private var lists: [ObjectIdentifier: Int?] = [:]
    /// The list style each paragraph style gives, and what each cell style says, worked out once.
    private var listStyles: [ObjectIdentifier: Node?] = [:]
    private var cellStyles: [ObjectIdentifier: CellStyle] = [:]
    private var bodyStyles = PagesStyleTally<ObjectIdentifier?>()
    private var headingStyles: [Int: (PagesParagraphProperties, PagesCharacterProperties)] = [:]
    /// The text of the body's footnotes, in order, and the next not yet referred to.
    private var footnotes: [String] = []
    private var nextFootnote = 0
    /// Tables set in the paragraph being read, which follow it.
    private var pendingTables: [Table] = []
    /// Formatters for the date formats cells are shown in, by format.
    private var dateFormatters: [String: DateFormatter] = [:]

    init(root: Node, files: [String: Data]) {
        self.root = root
        self.files = files
        for node in root.descendants(where: { $0.attributes["ID"] != nil }) {
            byID[node.attributes["ID"]!] = byID[node.attributes["ID"]!] ?? node
        }
        let body = root.first("text-storage")
        let ownSheet = body?.first("stylesheet-ref")?.attributes["IDREF"].flatMap { byID[$0] }
        let sheets = (ownSheet.map { [$0] } ?? []) + [root]
        for sheet in sheets {
            for style in sheet.descendants(where: { $0.attributes["ident"] != nil && $0.name.hasSuffix("style") }) {
                byIdent[style.attributes["ident"]!] = byIdent[style.attributes["ident"]!] ?? style
            }
        }
    }

    mutating func convert() -> WordDocument {
        readPageSetup()
        var blocks: [Block] = []
        if let notes = root.first("text-storage")?.first("footnotes")?.first("text-storage")?.first("text-body") {
            footnotes = footnoteTexts(notes)
        }
        if let body = root.first("text-storage")?.first("text-body") {
            blocks = self.blocks(in: body, recordsStyles: true)
        }
        let drawables = root.first("drawables")
        let pages = (drawables?.elements ?? []).filter { $0.name == "page-group" }
        if !pages.isEmpty, blocks.allSatisfy(Self.isBlank) {
            // A page layout document has no body text: its pages are what is placed on them.
            blocks = floatingBlocks(pages)
        } else if drawables?.descendants(where: { $0.name == "drawable-shape" || $0.name == "media" }).isEmpty == false {
            // Objects placed on a page of a word-processing document have no place in its text.
            document.unsupportedFeatures.insert(.shapes)
        }
        // A table cannot end the document; Word wants a paragraph after it.
        if blocks.isEmpty || { if case .table = blocks.last { true } else { false } }() {
            blocks.append(.paragraph(Paragraph()))
        }
        document.body = blocks
        document.adoptPagesStyles(
            body: bodyStyles.mostUsed ?? (PagesParagraphProperties(), Self.defaultCharacters), headings: headingStyles
        )
        readHeadersAndFooters()
        return document
    }

    /// What is placed on the pages, page by page, read down each page and
    /// across: text boxes' and shapes' text as paragraphs, pictures and
    /// tables as they are, and a page break between pages.
    private mutating func floatingBlocks(_ pages: [Node]) -> [Block] {
        var blocks: [Block] = []
        let ordered = pages.sorted { ($0.attributes["page"].flatMap(Int.init) ?? 0) < ($1.attributes["page"].flatMap(Int.init) ?? 0) }
        for (index, page) in ordered.enumerated() {
            if index > 0 {
                if case .paragraph(var last) = blocks.last {
                    last.inlines.append(Inline(.pageBreak))
                    blocks[blocks.count - 1] = .paragraph(last)
                } else {
                    blocks.append(.paragraph(Paragraph(inlines: [Inline(.pageBreak)])))
                }
            }
            let items = page.elements.map { item -> (node: Node, x: Double, y: Double) in
                let position = item.first("geometry")?.first("position")?.attributes
                return (item, position?["x"].flatMap(Self.measure) ?? 0, position?["y"].flatMap(Self.measure) ?? 0)
            }
            for item in items.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                switch item.node.name {
                case "drawable-shape":
                    let body = item.node.first("text")?.first("text-storage")?.first("text-body")
                    let content = body.map { self.blocks(in: $0, recordsStyles: true) } ?? []
                    if content.allSatisfy(Self.isBlank) {
                        // A shape with no text is a drawing Libretto cannot bring across.
                        document.unsupportedFeatures.insert(.shapes)
                    } else {
                        blocks += content
                    }
                case "tabular-info":
                    if let table = table(item.node) { blocks.append(.table(table)) }
                case "media":
                    if let image = image(in: item.node) {
                        blocks.append(.paragraph(Paragraph(inlines: [Inline(.image(image))])))
                    } else {
                        document.unsupportedFeatures.insert(.shapes)
                    }
                default:
                    document.unsupportedFeatures.insert(.shapes)
                }
            }
        }
        return blocks
    }

    /// Whether a block shows nothing: a paragraph with no text, or only breaks.
    private static func isBlank(_ block: Block) -> Bool {
        guard case .paragraph(let paragraph) = block else { return false }
        return paragraph.inlines.allSatisfy { $0.content == .pageBreak }
    }

    private mutating func readPageSetup() {
        guard let info = root.first("slprint-info") else { return }
        func twips(_ value: String?) -> Int? {
            value.flatMap(Self.measure).map { Int(($0 * 20).rounded()) }
        }
        var setup = document.pageSetup
        if let width = twips(info.attributes["page-width"]), let height = twips(info.attributes["page-height"]),
           width > 0, height > 0 {
            setup.width = width
            setup.height = height
        }
        if let margins = info.first("page-margins")?.attributes {
            setup.marginTop = twips(margins["top"]) ?? setup.marginTop
            setup.marginBottom = twips(margins["bottom"]) ?? setup.marginBottom
            setup.marginLeft = twips(margins["left"]) ?? setup.marginLeft
            setup.marginRight = twips(margins["right"]) ?? setup.marginRight
            setup.headerDistance = twips(margins["header"]) ?? setup.headerDistance
            setup.footerDistance = twips(margins["footer"]) ?? setup.footerDistance
        }
        document.pageSetup = setup
    }

    // MARK: Text

    /// The blocks of a text body, through its sections and layouts: its
    /// paragraphs, and the tables set in them. Paragraphs that name no
    /// style are in `baseStyle`, if there is one.
    private mutating func blocks(in container: Node, recordsStyles: Bool, baseStyle: Node? = nil) -> [Block] {
        var result: [Block] = []
        for node in container.elements {
            switch node.name {
            case "p":
                let paragraph = paragraph(node, recordsStyles: recordsStyles, baseStyle: baseStyle)
                let tables = pendingTables
                pendingTables = []
                // A paragraph that only held a table becomes the table.
                if tables.isEmpty || !paragraph.inlines.isEmpty { result.append(.paragraph(paragraph)) }
                result += tables.map(Block.table)
            case "section", "layout", "text-body": result += blocks(in: node, recordsStyles: recordsStyles, baseStyle: baseStyle)
            default: break
            }
        }
        return result
    }

    private mutating func paragraph(_ node: Node, recordsStyles: Bool, baseStyle: Node? = nil) -> Paragraph {
        let ownStyle = node.attributes["style"].flatMap(styleNode)
        let style = ownStyle ?? baseStyle
        var paragraphFormat = PagesParagraphProperties()
        var baseCharacters = Self.defaultCharacters
        if let style { (paragraphFormat, baseCharacters) = paragraphStyle(style) }
        // A table cell's style can come from a heading's, which its text is not.
        if ownStyle == nil, baseStyle != nil { paragraphFormat.outlineLevel = nil }
        var paragraph = Paragraph(properties: paragraphFormat.paragraphProperties)
        let listStyle = style.flatMap { listStyle(of: $0) }
        var numberingID = listStyle.flatMap { list(for: $0) }
        if let listStyle, let listID = numberingID {
            let level = min(node.attributes["list-level"].flatMap(Int.init).map { max($0, 1) - 1 } ?? 0, 8)
            // A list started over numbers from where the paragraph's style says, or else its level's first
            // number, and the paragraphs after it in the list carry on from there.
            if node.attributes["restart-list"] == "true" {
                var start = document.numbering.level(level, of: listID)?.start ?? 1
                if let style, case .number(let first) = inheritedValue("firstTopicNumber", from: style) {
                    start = min(max(Int(first), 0), 32767)
                }
                if let restarted = document.numbering.restartList(listID, level: level, at: start) {
                    lists[ObjectIdentifier(listStyle)] = restarted
                    numberingID = restarted
                }
            }
            paragraph.properties.list = ListReference(numberingID: numberingID ?? listID, level: level)
            paragraph.properties.indentLeft = nil
            paragraph.properties.indentFirstLine = nil
        }
        var runs = Runs()
        let effects = style.map { textEffects($0) } ?? TextEffects()
        appendContent(of: node, characters: baseCharacters, effects: effects, link: nil, to: &runs)
        paragraph.inlines = runs.inlines
        if recordsStyles {
            if let level = paragraphFormat.outlineLevel ?? nil {
                if headingStyles[level] == nil { headingStyles[level] = (paragraphFormat, baseCharacters) }
            } else if numberingID == nil, !paragraph.plainText.isEmpty {
                bodyStyles.add(style.map(ObjectIdentifier.init), (paragraphFormat, baseCharacters))
            }
        }
        return paragraph
    }

    /// Collects a paragraph's runs, merging text that looks alike.
    private struct Runs {
        var inlines: [Inline] = []

        mutating func append(_ inline: Inline) {
            let index = inlines.count - 1
            guard case .text(let text) = inline.content, index >= 0, inlines[index].format == inline.format,
                  inlines[index].hyperlink == inline.hyperlink, case .text(var previous) = inlines[index].content else {
                inlines.append(inline)
                return
            }
            // Emptied first, so the text is appended to in place rather than copied.
            inlines[index].content = .text("")
            previous += text
            inlines[index].content = .text(previous)
        }
    }

    /// Character formatting `PagesCharacterProperties` does not carry; `nil` inherits.
    private struct TextEffects {
        /// Text Pages does not show, which Libretto leaves out.
        var isHidden: Bool?

        func overlaid(with other: TextEffects) -> TextEffects {
            TextEffects(isHidden: other.isHidden ?? isHidden)
        }
    }

    private mutating func textEffects(_ style: Node) -> TextEffects {
        let key = ObjectIdentifier(style)
        if let cached = textEffectStyles[key] { return cached }
        let effects = chain(style).reduce(TextEffects()) { $0.overlaid(with: TextEffects(isHidden: flag("hidden", in: $1))) }
        textEffectStyles[key] = effects
        return effects
    }

    private mutating func appendContent(
        of node: Node, characters: PagesCharacterProperties, effects: TextEffects, link: Hyperlink?, to runs: inout Runs
    ) {
        let format = RunFormat(style: characters.runStyle)
        let isHidden = effects.isHidden == true
        for child in node.children {
            switch child {
            case .text(let text):
                if !isHidden { runs.append(Inline(.text(text), format: format, hyperlink: link)) }
            case .element(let element):
                switch element.name {
                case "span":
                    var inner = characters
                    var innerEffects = effects
                    if let style = element.attributes["style"].flatMap(styleNode) {
                        inner = characters.overlaid(with: characterStyle(style))
                        innerEffects = effects.overlaid(with: textEffects(style))
                    }
                    appendContent(of: element, characters: inner, effects: innerEffects, link: link, to: &runs)
                case "link":
                    appendContent(
                        of: element, characters: characters, effects: effects,
                        link: hyperlink(element.attributes["href"]) ?? link, to: &runs
                    )
                case "tab":
                    if !isHidden { runs.append(Inline(.tab, format: format, hyperlink: link)) }
                case "lnbr":
                    if !isHidden { runs.append(Inline(.lineBreak, format: format, hyperlink: link)) }
                case "pgbr", "sectbr":
                    runs.append(Inline(.pageBreak))
                case "crbr":
                    runs.append(Inline(.columnBreak))
                case "footnote":
                    // The text is the reference's own, or the next of the body's footnotes.
                    var text = plainText(element)
                    if text.isEmpty, nextFootnote < footnotes.count {
                        text = footnotes[nextFootnote]
                        nextFootnote += 1
                    }
                    guard !text.isEmpty else { continue }
                    let id = document.unusedNoteID(.footnote)
                    document.notes.append(Note(kind: .footnote, id: id, text: text))
                    var noteFormat = format
                    noteFormat.style.verticalAlignment = .superscript
                    runs.append(Inline(.note(NoteReference(kind: .footnote, id: id)), format: noteFormat))
                case "attachment-ref":
                    let attached = element.attributes["IDREF"].flatMap { byID[$0] }
                    if let attached, !attached.descendants(where: { $0.name == "tabular-model" }).isEmpty {
                        if let table = table(attached) { pendingTables.append(table) }
                    } else if let image = attached.flatMap({ image(in: $0) }) {
                        runs.append(Inline(.image(image), format: format))
                    } else {
                        document.unsupportedFeatures.insert(.shapes)
                    }
                default:
                    // Placeholder text, bookmarks, comments' ranges and fields
                    // wrap the text they show; `br` ends the paragraph the
                    // element itself ends, and the rest are empty markers.
                    appendContent(of: element, characters: characters, effects: effects, link: link, to: &runs)
                }
            }
        }
    }

    /// An element's text, its paragraphs a line each, with page numbers as
    /// the placeholders headers and footers fill in.
    private func plainText(_ node: Node) -> String {
        var lines: [String] = []
        var line = ""
        func walk(_ node: Node) {
            for child in node.children {
                switch child {
                case .text(let text): line += text
                case .element(let element):
                    switch element.name {
                    case "p":
                        walk(element)
                        lines.append(line)
                        line = ""
                    case "tab": line += "\t"
                    case "lnbr": line += "\n"
                    case "page-number": line += HeaderFooterText.pageNumberPlaceholder
                    case "page-count": line += HeaderFooterText.pageCountPlaceholder
                    case "br", "insertion-point", "selection-start", "selection-end", "container-hint", "page-start":
                        break
                    default: walk(element)
                    }
                }
            }
        }
        walk(node)
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// The footnotes' text, each from a paragraph that starts with its mark to the next.
    private func footnoteTexts(_ body: Node) -> [String] {
        var notes: [[String]] = []
        for paragraph in body.descendants(where: { $0.name == "p" }) {
            let line = plainText(paragraph)
            if paragraph.descendants(where: { $0.name == "footnote-mark" }).isEmpty, !notes.isEmpty {
                notes[notes.count - 1].append(line)
            } else {
                notes.append([line])
            }
        }
        return notes.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private mutating func hyperlink(_ address: String?) -> Hyperlink? {
        guard let address, !address.isEmpty else { return nil }
        let id = document.package.unusedRelationshipID()
        document.package.addedLinks[id] = address
        return Hyperlink(
            relationshipID: id, anchor: nil, url: URL(string: address),
            attributesXML: " r:id=\"\(id)\" w:history=\"1\""
        )
    }

    /// The first data file found in an element, as a picture at the size it is shown.
    private mutating func image(in node: Node) -> InlineImage? {
        let files = self.files
        let byID = self.byID
        // A picture placed again refers to the data its first placement holds.
        let data = node.descendants { $0.name == "data" || $0.name == "data-ref" }.lazy.compactMap { data -> Data? in
            let source = data.name == "data-ref" ? data.attributes["IDREF"].flatMap { byID[$0] } : data
            guard let path = source?.attributes["path"] else { return nil }
            return files[path] ?? files.first { $0.key.hasSuffix("/" + path) }?.value
        }.first
        guard let data, let (bytes, fileExtension, contentType) = PagesConverter.wordImage(data) else { return nil }
        let size = (node.descendants { $0.name == "geometry" }.first?.first("size")
            ?? node.descendants { $0.name == "size" || $0.name == "naturalSize" }.first)?.attributes
        let width = size?["w"].flatMap(Self.measure) ?? 100
        let height = size?["h"].flatMap(Self.measure) ?? 100
        let rid = document.package.unusedRelationshipID()
        document.package.addedMedia[rid] = DocumentPackage.AddedMedia(
            path: "word/media/pages-\(rid).\(fileExtension)", data: bytes,
            fileExtension: fileExtension, contentType: contentType
        )
        return InlineImage(relationshipID: rid, width: width, height: height, xml: nil)
    }

    // MARK: Tables

    /// The table an attachment or drawable holds, with each cell's content.
    private mutating func table(_ node: Node) -> Table? {
        guard let model = node.descendants(where: { $0.name == "tabular-model" }).first,
              let grid = model.first("grid"), let source = grid.first("datasource") else { return nil }
        let widths = (grid.first("columns")?.elements ?? []).filter { $0.name == "grid-column" }
            .map { max($0.attributes["width"].flatMap(Self.measure) ?? 100, 0) }
        let columnCount = widths.count
        let rowCount = (grid.first("rows")?.elements ?? []).filter { $0.name == "grid-row" }.count
        guard rowCount > 0, columnCount > 0 else { return nil }
        guard rowCount * columnCount <= 100_000 else {
            // Too large to bring across: left out, and the document says something is.
            document.unsupportedFeatures.insert(.embeddedObjects)
            return nil
        }

        // Cells come row by row. A merged cell gives its span; the cells it
        // covers are there to be skipped, unless the source leaves them out.
        let elements = source.elements
        let coveredAreListed = elements.count >= rowCount * columnCount
        var cells = Array(repeating: Array(repeating: TableCell(blocks: []), count: columnCount), count: rowCount)
        var spans = Array(repeating: Array(repeating: 1, count: columnCount), count: rowCount)
        var covered = Array(repeating: Array(repeating: false, count: columnCount), count: rowCount)
        var merges = Array(repeating: Array(repeating: TableCell.VerticalMerge?.none, count: columnCount), count: rowCount)
        var position = 0
        for element in elements {
            if !coveredAreListed {
                while position < rowCount * columnCount, covered[position / columnCount][position % columnCount] { position += 1 }
            }
            guard position < rowCount * columnCount else { break }
            let row = position / columnCount
            let column = position % columnCount
            position += 1
            guard !covered[row][column] else { continue }
            cells[row][column] = TableCell(
                blocks: cellBlocks(element), shadingHex: element.attributes["s"].flatMap(styleNode).flatMap { cellStyle($0).fill }
            )
            let columnSpan = min(max(element.attributes["col-span"].flatMap(Int.init) ?? 1, 1), columnCount - column)
            let rowSpan = min(max(element.attributes["row-span"].flatMap(Int.init) ?? 1, 1), rowCount - row)
            guard columnSpan * rowSpan > 1 else { continue }
            for spannedRow in row..<(row + rowSpan) {
                spans[spannedRow][column] = columnSpan
                if rowSpan > 1 { merges[spannedRow][column] = spannedRow == row ? .restart : .continue }
                for spannedColumn in column..<(column + columnSpan) where (spannedRow, spannedColumn) != (row, column) {
                    covered[spannedRow][spannedColumn] = true
                }
            }
        }

        let gridColumns = widths.map { Int(($0 * 20).rounded()) }
        let headerRows = model.attributes["num-header-rows"].flatMap(Int.init) ?? 0
        let rows = cells.enumerated().map { row, cellsInRow in
            TableRow(
                cells: cellsInRow.enumerated().compactMap { column, cell -> TableCell? in
                    // A cell merged down stays, as the continuation of the one above.
                    guard !covered[row][column] || merges[row][column] == .continue else { return nil }
                    var cell = cell
                    cell.gridSpan = spans[row][column]
                    cell.verticalMerge = merges[row][column]
                    if cell.verticalMerge == .continue {
                        // A cell merged into the one above shows that one's fill.
                        cell.blocks = []
                        let origin = (0..<row).last { merges[$0][column] == .restart }
                        cell.shadingHex = origin.flatMap { cells[$0][column].shadingHex }
                    }
                    if cell.blocks.isEmpty { cell.blocks = [.paragraph(Paragraph())] }
                    cell.preservedPropertiesXML = PagesConverter.cellPropertiesXML(
                        cell, width: gridColumns[column..<(column + cell.gridSpan)].reduce(0, +)
                    )
                    return cell
                },
                isHeader: row < headerRows
            )
        }
        return Table(rows: rows, gridColumns: gridColumns, preservedPropertiesXML: nil, styleID: nil, hasBorders: true)
    }

    /// What a cell shows: its text's paragraphs, or its value as text, in
    /// the paragraph style its cell style gives.
    private mutating func cellBlocks(_ cell: Node) -> [Block] {
        let style = cell.attributes["s"].flatMap(styleNode)
        let textStyle = style.flatMap { cellStyle($0).paragraphStyle }
        if let body = cell.descendants(where: { $0.name == "text-body" }).first {
            // Tables already set in the paragraph this table is in follow that paragraph, not a cell's.
            let outerTables = pendingTables
            pendingTables = []
            var blocks = self.blocks(in: body, recordsStyles: false, baseStyle: textStyle)
            pendingTables = outerTables
            // The text ends with an empty paragraph, which the cell does not show.
            while blocks.count > 1, case .paragraph(let last) = blocks.last, last.inlines.isEmpty { blocks.removeLast() }
            if !blocks.isEmpty { return blocks }
        }
        guard let text = value(of: cell, style: style), !text.isEmpty else { return [] }
        var (paragraphFormat, characters) = textStyle.map { paragraphStyle($0) } ?? (PagesParagraphProperties(), Self.defaultCharacters)
        paragraphFormat.outlineLevel = nil
        var paragraph = Paragraph(properties: paragraphFormat.paragraphProperties)
        paragraph.inlines = [Inline(.text(text), format: RunFormat(style: characters.runStyle))]
        return [.paragraph(paragraph)]
    }

    /// The value a cell shows, as text, in its style's formats.
    private mutating func value(of cell: Node, style: Node?) -> String? {
        let format = style.flatMap { cellStyle($0).numberFormat }
        func number(_ value: String) -> String? {
            Double(value).map { format?.text($0, locale: Self.locale) ?? PagesConverter.numberText($0) }
        }
        switch cell.name {
        case "t":
            return cell.first("ct")?.attributes["s"]
        case "n":
            return cell.attributes["v"].flatMap(number)
        case "b":
            return cell.attributes["v"].map { $0 == "1" || $0 == "true" ? "TRUE" : "FALSE" }
        case "d":
            return cell.attributes["cell-date"].map { value in Self.date(value).map { dateText($0, style: style) } ?? value }
        case "du":
            return cell.attributes["du"].flatMap(Self.measure).map { durationText($0, style: style) }
        case "pm":
            // A pop-up menu shows the choice its proxied cell refers to, among its menu's.
            if let chosen = cell.descendants(where: { $0.name == "proxied-cell-ref" }).first?.attributes["IDREF"]
                .flatMap({ byID[$0] }), chosen.name != "pm" {
                return value(of: chosen, style: style)
            }
            return cell.first("menu-choices")?.elements.first.flatMap { value(of: $0, style: style) }
        default:
            // A formula's result, or nothing, for a cell that is empty or covered.
            let result = cell.descendants { $0.attributes["v"] != nil || $0.attributes["s"] != nil }.first
            return result.flatMap { $0.attributes["v"].map { number($0) ?? $0 } ?? $0.attributes["s"] }
        }
    }

    /// A duration in seconds, in the units its cell style's duration format
    /// names, such as `hhh mmm sss`, each with its letter: `1h 30m 0s`.
    private func durationText(_ seconds: Double, style: Node?) -> String {
        var format = "hhh mmm sss"
        if let style, case .node(let node) = inheritedValue("SFTCellStylePropertyDurationFormat", from: style),
           let own = node.attributes["fmt"], !own.isEmpty {
            format = own
        }
        let units: [(Character, Double)] = [("w", 604_800), ("d", 86_400), ("h", 3_600), ("m", 60), ("s", 1)]
        let shown = units.filter { format.contains($0.0) }
        guard !shown.isEmpty else { return PagesConverter.numberText(seconds) }
        var remaining = abs(seconds).rounded()
        var parts: [String] = []
        for (index, (letter, length)) in shown.enumerated() {
            let isLast = index == shown.count - 1
            let count = isLast ? remaining / length : (remaining / length).rounded(.down)
            remaining -= count * length
            // Larger units with nothing in them are left out.
            if count == 0, parts.isEmpty, !isLast { continue }
            parts.append(PagesConverter.numberText(count) + String(letter))
        }
        return (seconds < 0 ? "-" : "") + parts.joined(separator: " ")
    }

    /// What a cell style says of its cells: the colour it fills them with, `nil` for none,
    /// the paragraph style it sets their text in, and the format it shows numbers in.
    private struct CellStyle {
        var fill: String?
        var paragraphStyle: Node?
        var numberFormat: PagesNumberFormat?
    }

    private mutating func cellStyle(_ style: Node) -> CellStyle {
        let key = ObjectIdentifier(style)
        if let cached = cellStyles[key] { return cached }
        var fill: String?
        if case .color(let hex) = inheritedValue("fill", from: style) { fill = hex }
        let result = CellStyle(fill: fill, paragraphStyle: cellParagraphStyle(style), numberFormat: numberFormat(style))
        cellStyles[key] = result
        return result
    }

    /// The list style a paragraph style puts its paragraphs in.
    private mutating func listStyle(of style: Node) -> Node? {
        let key = ObjectIdentifier(style)
        if let cached = listStyles[key] { return cached }
        var result: Node?
        if case .node(let node) = inheritedValue("listStyle", from: style) { result = node }
        listStyles[key] = .some(result)
        return result
    }

    /// The paragraph style a cell style sets text in: its own, or its layout
    /// style's, the nearest in the cell style's ancestry.
    private func cellParagraphStyle(_ cellStyle: Node) -> Node? {
        for node in chain(cellStyle).reversed() {
            if case .node(let style) = value("SFTCellStylePropertyParagraphStyle", in: node) { return style }
            if case .node(let layout) = value("SFTCellStylePropertyLayoutStyle", in: node),
               case .node(let style) = inheritedValue("layoutParagraphStyle", from: layout) { return style }
        }
        return nil
    }

    /// Pages '09 keeps no language for the document; numbers are written as in the US.
    private static let locale = Locale(identifier: "en_US")

    /// The date and time a cell holds, as written, whether or not a time
    /// zone follows: the time on the clock, wherever the document is opened.
    private static func date(_ value: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        for (length, format) in [(19, "yyyy-MM-dd'T'HH:mm:ss"), (16, "yyyy-MM-dd'T'HH:mm"), (10, "yyyy-MM-dd")] {
            parser.dateFormat = format
            if value.count >= length, let date = parser.date(from: String(value.prefix(length))) { return date }
        }
        return nil
    }

    /// A date as a cell style's date format shows it, in the locale numbers are in.
    private mutating func dateText(_ date: Date, style: Node?) -> String {
        var format = "M/d/yy"
        if let style, case .node(let node) = inheritedValue("SFTCellStylePropertyDateTimeFormat", from: style),
           let own = node.attributes["fmt"], !own.isEmpty {
            format = own
        }
        if dateFormatters[format] == nil {
            let formatter = DateFormatter()
            formatter.locale = Self.locale
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            dateFormatters[format] = formatter
        }
        return dateFormatters[format]!.string(from: date)
    }

    /// The format a cell style shows numbers in, which Pages applies with
    /// the places it gives; `nil` for none.
    private func numberFormat(_ style: Node) -> PagesNumberFormat? {
        guard case .number(let type) = inheritedValue("SFTCellStylePropertyFormatType", from: style) else { return nil }
        var format = PagesNumberFormat(kind: PagesNumberFormat.kind(Int(type)))
        guard format.kind != .automatic else { return nil }
        if case .node(let node) = inheritedValue("SFTCellStylePropertyNumberFormat", from: style) {
            let attributes = node.attributes
            format.decimalPlaces = attributes["format-decimal-places"].flatMap(Int.init)
            format.currencyCode = attributes["format-currency-code"]
            format.showsThousandsSeparator = attributes["format-show-thousands-separator"] == "true"
            format.bracketsNegatives = ["2", "3"].contains(attributes["format-negative-style"])
            format.isAccounting = attributes["format-use-accounting-style"] == "true"
        }
        return format
    }

    // MARK: Styles

    /// A style by the name a paragraph or span gives it: an `sfa:ID`, or a
    /// named style's `sf:ident`.
    private func styleNode(_ key: String) -> Node? {
        resolved(byID[key] ?? byIdent[key])
    }

    /// The element a `…-ref` points at, or the element itself.
    private func resolved(_ node: Node?) -> Node? {
        guard let node else { return nil }
        if node.name.hasSuffix("-ref") { return node.attributes["IDREF"].flatMap { byID[$0] } }
        return node
    }

    /// A style and its ancestors, root first.
    private func chain(_ style: Node) -> [Node] {
        var result: [Node] = []
        var current: Node? = style
        while let node = current, result.count < 32 {
            result.insert(node, at: 0)
            current = node.attributes["parent-ident"].flatMap { byIdent[$0] }.flatMap(resolved)
        }
        return result
    }

    private enum Value {
        case null
        case number(Double)
        case string(String)
        case color(String?)
        case lineSpacing(LineSpacing?)
        case node(Node)
    }

    /// A property of a style's own property map; `nil` if it inherits.
    private func value(_ name: String, in style: Node) -> Value? {
        guard let property = style.first("property-map")?.first(name), let content = property.elements.first else { return nil }
        switch content.name {
        case "null": return .null
        case "number": return content.attributes["number"].flatMap(Self.measure).map(Value.number)
        case "string": return .string(content.attributes["string"] ?? "")
        case "color": return .color(color(content))
        case "linespacing":
            // Pages writes the amount as `sf:amt`.
            guard let amount = (content.attributes["amt"] ?? content.attributes["amount"]).flatMap(Self.measure) else {
                return .lineSpacing(nil)
            }
            switch content.attributes["mode"] ?? "relative" {
            case "relative": return .lineSpacing(LineSpacing(line: Int((amount * 240).rounded()), rule: .auto))
            case "exact": return .lineSpacing(LineSpacing(line: Int((amount * 20).rounded()), rule: .exact))
            default: return .lineSpacing(LineSpacing(line: Int((amount * 20).rounded()), rule: .atLeast))
            }
        default: return resolved(content).map(Value.node)
        }
    }

    private func inheritedValue(_ name: String, from style: Node) -> Value? {
        chain(style).reversed().lazy.compactMap { self.value(name, in: $0) }.first
    }

    /// A number from the XML, if it is one that measures something: finite,
    /// and small enough to convert to twips and the like without overflowing.
    static func measure(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, abs(value) <= 1_000_000_000 else { return nil }
        return value
    }

    /// What Pages sets text in when no style says: 12-point Helvetica.
    private static let defaultCharacters = {
        var characters = PagesCharacterProperties()
        characters.fontName = "Helvetica"
        characters.fontSize = 12
        return characters
    }()

    private mutating func paragraphStyle(_ style: Node) -> (PagesParagraphProperties, PagesCharacterProperties) {
        let key = ObjectIdentifier(style)
        if let cached = paragraphStyles[key] { return cached }
        var paragraph = PagesParagraphProperties()
        var characters = Self.defaultCharacters
        for node in chain(style) {
            paragraph = paragraph.overlaid(with: paragraphProperties(node))
            characters = characters.overlaid(with: characterProperties(node))
        }
        paragraph.outlineLevel = .some(headingLevel(style))
        paragraphStyles[key] = (paragraph, characters)
        return (paragraph, characters)
    }

    private mutating func characterStyle(_ style: Node) -> PagesCharacterProperties {
        let key = ObjectIdentifier(style)
        if let cached = characterStyles[key] { return cached }
        let properties = chain(style).reduce(PagesCharacterProperties()) { $0.overlaid(with: characterProperties($1)) }
        characterStyles[key] = properties
        return properties
    }

    private func number(_ name: String, in style: Node) -> Double? {
        if case .number(let number) = value(name, in: style) { return number }
        return nil
    }

    private func flag(_ name: String, in style: Node) -> Bool? {
        number(name, in: style).map { $0 != 0 }
    }

    private func characterProperties(_ style: Node) -> PagesCharacterProperties {
        var properties = PagesCharacterProperties()
        properties.isBold = flag("bold", in: style)
        properties.isItalic = flag("italic", in: style)
        properties.fontSize = number("fontSize", in: style)
        if case .string(let name) = value("fontName", in: style), !name.isEmpty { properties.fontName = name }
        switch value("fontColor", in: style) {
        case .some(.color(let hex)): properties.colorHex = .some(hex)
        case .some(.null): properties.colorHex = .some(nil)
        default: break
        }
        properties.verticalPosition = number("superscript", in: style).map { Int($0) }
        properties.underline = number("underline", in: style).map { Int($0) }
        properties.strikethrough = number("strikethru", in: style).map { Int($0) }
        properties.capitalization = number("capitalization", in: style).map { Int($0) }
        properties.baselineShift = number("baselineShift", in: style)
        return properties
    }

    private func paragraphProperties(_ style: Node) -> PagesParagraphProperties {
        var properties = PagesParagraphProperties()
        properties.alignment = number("alignment", in: style).map { Int($0) }
        properties.firstLineIndent = number("firstLineIndent", in: style)
        properties.leftIndent = number("leftIndent", in: style)
        properties.rightIndent = number("rightIndent", in: style)
        properties.spaceBefore = number("spaceBefore", in: style)
        properties.spaceAfter = number("spaceAfter", in: style)
        if case .lineSpacing(let spacing) = value("lineSpacing", in: style) { properties.lineSpacing = spacing }
        properties.keepLinesTogether = flag("keepLinesTogether", in: style)
        properties.keepWithNext = flag("keepWithNext", in: style)
        properties.pageBreakBefore = flag("pageBreakBefore", in: style)
        properties.widowControl = flag("widowControl", in: style)
        switch value("paragraphFill", in: style) {
        case .some(.color(let hex)): properties.fillHex = .some(hex)
        case .some(.null): properties.fillHex = .some(nil)
        default: break
        }
        return properties
    }

    /// The heading level a paragraph style sets text at, zero for the top;
    /// `nil` for text that is not a heading. Pages '09 gives captions,
    /// labels and table cells an outline level too, and its own headings
    /// levels that need not match their names, so a heading is a style named
    /// "Heading" and a number, or first so named, or one with an outline style.
    private func headingLevel(_ style: Node) -> Int? {
        for node in chain(style).reversed() {
            for label in [node.attributes["name"], node.attributes["ident"]].compactMap({ $0 }) {
                guard let last = label.last, let number = last.wholeNumberValue, (1...9).contains(number),
                      label.dropLast().hasSuffix("Heading ") else { continue }
                return number - 1
            }
        }
        guard case .number(let type) = inheritedValue("outlineStyleType", from: style), type != 0,
              case .number(let level) = inheritedValue("outlineLevel", from: style), level >= 0, level < 9 else { return nil }
        return Int(level)
    }

    /// Colours already converted, by their attributes.
    private final class ColorCache {
        var hexes: [String: String?] = [:]
    }

    private let colors = ColorCache()

    /// `hex(_:)` for an `sf:color`, converted once for each colour the document uses.
    private func color(_ node: Node) -> String? {
        let key = ["type", "r", "g", "b", "w", "a"].map { node.attributes[$0] ?? "" }.joined(separator: " ")
        if let known = colors.hexes[key] { return known }
        let hex = Self.hex(node)
        colors.hexes[key] = .some(hex)
        return hex
    }

    /// Six-digit sRGB for an `sf:color`, RGB or grey; `nil` for one that is transparent.
    private static func hex(_ color: Node) -> String? {
        let attributes = color.attributes
        if let alpha = attributes["a"].flatMap(Self.measure), alpha == 0 { return nil }
        let white = attributes["w"].flatMap(Self.measure)
        var components = white.map { [$0] } ?? ["r", "g", "b"].map { attributes[$0].flatMap(Self.measure) ?? 0 }
        // Calibrated colours are in Apple's generic profiles, which Word's sRGB shows darker.
        if attributes["type"]?.contains("calibrated") == true,
           let space = white == nil ? genericRGB : genericGray, let sRGB,
           let converted = CGColor(colorSpace: space, components: components.map { CGFloat($0) } + [1])?
               .converted(to: sRGB, intent: .defaultIntent, options: nil)?.components {
            components = converted.prefix(3).map { Double($0) }
        }
        if components.count == 1 { components = Array(repeating: components[0], count: 3) }
        return components.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }

    private static let genericRGB = CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString)
    private static let genericGray = CGColorSpace(name: "kCGColorSpaceGenericGray" as CFString)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    // MARK: Lists

    /// The list an `sf:liststyle` becomes, made the first time it is met; `nil` if it labels nothing.
    private mutating func list(for style: Node) -> Int? {
        let key = ObjectIdentifier(style)
        if let known = lists[key] { return known }
        let labels = chain(style).reversed().compactMap { node -> [Node]? in
            guard case .node(let array) = value("listLabelTypes", in: node) else { return nil }
            return array.elements.filter { $0.name == "list-label-typeinfo" }
        }.first ?? []
        guard let first = labels.first, first.attributes["type"] != "none" else {
            lists[key] = .some(nil)
            return nil
        }
        let numbered = ["decimal", "upper-roman", "lower-roman", "upper-alpha", "lower-alpha"]
        let formats = ["decimal", "upperRoman", "lowerRoman", "upperLetter", "lowerLetter"]
        let standardBullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        func isNumbered(_ label: Node?) -> Bool {
            label?.first("text-label").map { numbered.contains($0.attributes["type"] ?? "") } ?? false
        }
        let levels = Dictionary(uniqueKeysWithValues: (0..<9).map { level -> (Int, NumberingDefinitions.ListLevel) in
            let label = labels.isEmpty ? nil : labels[min(level, labels.count - 1)]
            let indent = 720 * (level + 1)
            if isNumbered(label), let text = label?.first("text-label") {
                let format = formats[numbered.firstIndex(of: text.attributes["type"]!)!]
                let pattern = (text.attributes["format"] ?? "%L.").replacingOccurrences(of: "%L", with: "%\(level + 1)")
                var listLevel = NumberingDefinitions.ListLevel(format: format, text: pattern, indentLeft: indent, hanging: 360)
                if let first = text.attributes["first"].flatMap(Int.init), (0...32767).contains(first) { listLevel.start = first }
                return (level, listLevel)
            }
            let bullet = label?.first("text-label")?.attributes["format"].flatMap { $0.isEmpty || $0.contains("%") ? nil : $0 }
                ?? standardBullets[level % 3]
            return (level, NumberingDefinitions.ListLevel(format: "bullet", text: bullet, indentLeft: indent, hanging: 360))
        })
        let numberingID = document.numbering.addList(levels: levels, kind: isNumbered(first) ? .numbered : .bulleted)
        lists[key] = numberingID
        return numberingID
    }

    // MARK: Headers and footers

    /// The headers and footers of the body's first section, from the page
    /// masters its section style gives for its first, odd and even pages.
    private mutating func readHeadersAndFooters() {
        var parts: [Bool: [String: Node]] = [:]
        for isFooter in [false, true] {
            for part in root.first(isFooter ? "footers" : "headers")?.elements ?? [] {
                guard let name = part.attributes["name"], parts[isFooter]?[name] == nil else { continue }
                parts[isFooter, default: [:]][name] = part
            }
        }
        let section = root.first("text-storage")?.first("text-body")?.descendants { $0.name == "section" }.first
        guard let style = section?.attributes["style"].flatMap(styleNode) else {
            // With no section style, the document's own odd-page parts are every page's.
            for isFooter in [false, true] {
                let name = isFooter ? "SFWPDefaultOddFooterIdentifier" : "SFWPDefaultOddHeaderIdentifier"
                if let part = parts[isFooter]?[name] { addHeaderFooter(part, kind: .default, isFooter: isFooter) }
            }
            return
        }
        func differs(_ name: String) -> Bool {
            if case .number(let number) = inheritedValue(name, from: style) { number != 0 } else { false }
        }
        let firstPageDiffers = differs("pageMasterFirstPageDifferent")
        let evenPagesDiffer = differs("pageMasterLeftRightPagesDifferent")
        let masters: [(HeaderFooterKind, String)] = [(.default, "oddPageMaster"), (.first, "firstPageMaster"), (.even, "evenPageMaster")]
        for (kind, property) in masters {
            if kind == .first, !firstPageDiffers { continue }
            if kind == .even, !evenPagesDiffer { continue }
            guard case .node(let master) = inheritedValue(property, from: style) else { continue }
            for isFooter in [false, true] {
                guard let name = master.attributes[isFooter ? "footer" : "header"],
                      let part = parts[isFooter]?[name] else { continue }
                addHeaderFooter(part, kind: kind, isFooter: isFooter)
            }
        }
        document.pageSetup.headerFooters.titlePage = firstPageDiffers
        document.evenAndOddHeaders = evenPagesDiffer
    }

    /// A header or footer part's text, shown on the pages of `kind`; nothing if it is empty.
    private mutating func addHeaderFooter(_ part: Node, kind: HeaderFooterKind, isFooter: Bool) {
        guard let storage = part.first("text-storage") else { return }
        let text = plainText(storage)
        guard !text.isEmpty else { return }
        for number in storage.descendants(where: { $0.name == "page-number" }) {
            guard let format = number.attributes["format"].flatMap(PagesConverter.pageNumberFormat) else { continue }
            document.pageSetup.pageNumberFormat = format
        }
        let firstParagraph = storage.descendants { $0.name == "p" }.first
        var alignment: Int?
        if let style = firstParagraph?.attributes["style"].flatMap(styleNode) { alignment = paragraphStyle(style).0.alignment }
        var headerFooter = HeaderFooterText(text: text, isFooter: isFooter)
        switch alignment {
        case 1: headerFooter.alignment = .trailing
        case 2: headerFooter.alignment = .center
        default: break
        }
        headerFooter.isEdited = true
        let id = document.unusedHeaderFooterID(isFooter: isFooter)
        document.headerFooters[id] = headerFooter
        if isFooter {
            document.pageSetup.headerFooters.footers[kind] = id
        } else {
            document.pageSetup.headerFooters.headers[kind] = id
        }
    }
}
