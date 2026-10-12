import Foundation

/// Reads a document from Pages '09 and before, whose package holds the whole
/// document as `index.xml`, gzipped when the package is a folder.
///
/// The body text comes across with its paragraph and character formatting,
/// lists, links, inline pictures and footnotes, and the page's size, margins,
/// headers and footers. Tables and objects placed on the page do not.
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
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        let size = bytes[(bytes.count - 4)...].reversed().reduce(0) { $0 << 8 | Int($1) }
        return ZipArchive.inflate(Data(bytes[offset..<(bytes.count - 8)]), expectedSize: size)
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
            elements.first { $0.name == name }
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
                if case .text(let previous) = parent.children.last {
                    parent.children[parent.children.count - 1] = .text(previous + string)
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
    private var lists: [ObjectIdentifier: Int?] = [:]
    private var bodyStyle: (PagesParagraphProperties, PagesCharacterProperties)?
    private var headingStyles: [Int: (PagesParagraphProperties, PagesCharacterProperties)] = [:]
    /// The text of the body's footnotes not yet referred to, in order.
    private var footnotes: [String] = []

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
            blocks = paragraphs(in: body, recordsStyles: true).map(Block.paragraph)
        }
        if blocks.isEmpty { blocks = [.paragraph(Paragraph())] }
        document.body = blocks
        document.adoptPagesStyles(body: bodyStyle, headings: headingStyles)
        readHeadersAndFooters()
        if root.first("drawables")?.descendants(where: { $0.name == "drawable-shape" || $0.name == "media" }).isEmpty == false {
            document.unsupportedFeatures.insert(.shapes)
        }
        return document
    }

    private mutating func readPageSetup() {
        guard let info = root.first("slprint-info") else { return }
        func twips(_ value: String?) -> Int? {
            value.flatMap(Double.init).map { Int(($0 * 20).rounded()) }
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

    /// The paragraphs of a text body, through its sections and layouts.
    private mutating func paragraphs(in container: Node, recordsStyles: Bool) -> [Paragraph] {
        var result: [Paragraph] = []
        for node in container.elements {
            switch node.name {
            case "p": result.append(paragraph(node, recordsStyles: recordsStyles))
            case "section", "layout", "text-body": result += paragraphs(in: node, recordsStyles: recordsStyles)
            default: break
            }
        }
        return result
    }

    private mutating func paragraph(_ node: Node, recordsStyles: Bool) -> Paragraph {
        let style = node.attributes["style"].flatMap(styleNode)
        var paragraphFormat = PagesParagraphProperties()
        var baseCharacters = PagesCharacterProperties()
        if let style { (paragraphFormat, baseCharacters) = paragraphStyle(style) }
        var paragraph = Paragraph(properties: paragraphFormat.paragraphProperties)
        let listStyle = style.flatMap { inheritedValue("listStyle", from: $0) }.flatMap { value -> Node? in
            if case .node(let node) = value { node } else { nil }
        }
        let numberingID = listStyle.flatMap { list(for: $0) }
        if let numberingID {
            let level = node.attributes["list-level"].flatMap(Int.init).map { max($0 - 1, 0) } ?? 0
            paragraph.properties.list = ListReference(numberingID: numberingID, level: min(level, 8))
            paragraph.properties.indentLeft = nil
            paragraph.properties.indentFirstLine = nil
        }
        if recordsStyles {
            if let level = paragraphFormat.outlineLevel ?? nil {
                if headingStyles[level] == nil { headingStyles[level] = (paragraphFormat, baseCharacters) }
            } else if bodyStyle == nil, numberingID == nil {
                bodyStyle = (paragraphFormat, baseCharacters)
            }
        }
        var runs = Runs()
        appendContent(of: node, characters: baseCharacters, link: nil, to: &runs)
        paragraph.inlines = runs.inlines
        return paragraph
    }

    /// Collects a paragraph's runs, merging text that looks alike.
    private struct Runs {
        var inlines: [Inline] = []

        mutating func append(_ inline: Inline) {
            if case .text(let text) = inline.content, let last = inlines.last, case .text(let previous) = last.content,
               last.format == inline.format, last.hyperlink == inline.hyperlink {
                inlines[inlines.count - 1].content = .text(previous + text)
            } else {
                inlines.append(inline)
            }
        }
    }

    private mutating func appendContent(
        of node: Node, characters: PagesCharacterProperties, link: Hyperlink?, to runs: inout Runs
    ) {
        let format = RunFormat(style: characters.runStyle)
        for child in node.children {
            switch child {
            case .text(let text):
                runs.append(Inline(.text(text), format: format, hyperlink: link))
            case .element(let element):
                switch element.name {
                case "span":
                    var inner = characters
                    if let style = element.attributes["style"].flatMap(styleNode) {
                        inner = characters.overlaid(with: characterStyle(style))
                    }
                    appendContent(of: element, characters: inner, link: link, to: &runs)
                case "link":
                    appendContent(of: element, characters: characters, link: hyperlink(element.attributes["href"]) ?? link, to: &runs)
                case "tab":
                    runs.append(Inline(.tab, format: format, hyperlink: link))
                case "lnbr":
                    runs.append(Inline(.lineBreak, format: format, hyperlink: link))
                case "pgbr", "sectbr":
                    runs.append(Inline(.pageBreak))
                case "crbr":
                    runs.append(Inline(.columnBreak))
                case "footnote":
                    // The text is the reference's own, or the next of the body's footnotes.
                    var text = plainText(element)
                    if text.isEmpty, !footnotes.isEmpty { text = footnotes.removeFirst() }
                    guard !text.isEmpty else { continue }
                    let id = document.unusedNoteID(.footnote)
                    document.notes.append(Note(kind: .footnote, id: id, text: text))
                    var noteFormat = format
                    noteFormat.style.verticalAlignment = .superscript
                    runs.append(Inline(.note(NoteReference(kind: .footnote, id: id)), format: noteFormat))
                case "attachment-ref":
                    if let image = attachment(element.attributes["IDREF"]) {
                        runs.append(Inline(.image(image), format: format))
                    } else {
                        document.unsupportedFeatures.insert(.shapes)
                    }
                default:
                    // Placeholder text, bookmarks, comments' ranges and fields
                    // wrap the text they show; `br` ends the paragraph the
                    // element itself ends, and the rest are empty markers.
                    appendContent(of: element, characters: characters, link: link, to: &runs)
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

    /// A picture an attachment holds: the first data file found in it, at the size it is shown.
    private mutating func attachment(_ id: String?) -> InlineImage? {
        guard let node = id.flatMap({ byID[$0] }) else { return nil }
        let files = self.files
        let data = node.descendants { $0.name == "data" && $0.attributes["path"] != nil }.lazy.compactMap { data -> Data? in
            let path = data.attributes["path"]!
            return files[path] ?? files.first { $0.key.hasSuffix("/" + path) }?.value
        }.first
        guard let data, let (bytes, fileExtension, contentType) = PagesConverter.wordImage(data) else { return nil }
        let size = (node.descendants { $0.name == "geometry" }.first?.first("size")
            ?? node.descendants { $0.name == "size" || $0.name == "naturalSize" }.first)?.attributes
        let width = size?["w"].flatMap(Double.init) ?? 100
        let height = size?["h"].flatMap(Double.init) ?? 100
        let rid = document.package.unusedRelationshipID()
        document.package.addedMedia[rid] = DocumentPackage.AddedMedia(
            path: "word/media/pages-\(rid).\(fileExtension)", data: bytes,
            fileExtension: fileExtension, contentType: contentType
        )
        return InlineImage(relationshipID: rid, width: width, height: height, xml: nil)
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
        case "number": return content.attributes["number"].flatMap(Double.init).map(Value.number)
        case "string": return .string(content.attributes["string"] ?? "")
        case "color": return .color(Self.hex(content))
        case "linespacing":
            guard let amount = content.attributes["amount"].flatMap(Double.init) else { return .lineSpacing(nil) }
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

    private mutating func paragraphStyle(_ style: Node) -> (PagesParagraphProperties, PagesCharacterProperties) {
        let key = ObjectIdentifier(style)
        if let cached = paragraphStyles[key] { return cached }
        var paragraph = PagesParagraphProperties()
        var characters = PagesCharacterProperties()
        for node in chain(style) {
            paragraph = paragraph.overlaid(with: paragraphProperties(node))
            characters = characters.overlaid(with: characterProperties(node))
        }
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
        if let level = number("outlineLevel", in: style) {
            properties.outlineLevel = .some(level >= 0 && level < 9 ? Int(level) : nil)
        }
        return properties
    }

    /// Six-digit RGB for an `sf:color`, calibrated RGB or grey; `nil` for one that is transparent.
    private static func hex(_ color: Node) -> String? {
        let attributes = color.attributes
        if let alpha = attributes["a"].flatMap(Double.init), alpha == 0 { return nil }
        let components: [Double]
        if let white = attributes["w"].flatMap(Double.init) {
            components = [white, white, white]
        } else {
            components = ["r", "g", "b"].map { attributes[$0].flatMap(Double.init) ?? 0 }
        }
        return components.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }

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
                return (level, NumberingDefinitions.ListLevel(format: format, text: pattern, indentLeft: indent, hanging: 360))
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

    private mutating func readHeadersAndFooters() {
        for isFooter in [false, true] {
            let group = root.first(isFooter ? "footers" : "headers")
            for part in group?.elements ?? [] {
                let name = part.attributes["name"] ?? ""
                let kind: HeaderFooterKind = name.contains("First") ? .first : name.contains("Even") ? .even : .default
                guard kind == .default, let storage = part.first("text-storage") else { continue }
                let text = plainText(storage)
                guard !text.isEmpty else { continue }
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
                    document.pageSetup.headerFooters.footers[.default] = id
                } else {
                    document.pageSetup.headerFooters.headers[.default] = id
                }
            }
        }
    }
}
