import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads a Pages document into a new word-processing document, which saves
/// as `.docx`. Nothing of the Pages file is kept to be written back.
///
/// The body text comes across with its paragraph and character formatting,
/// lists, links, inline pictures, tables, footnotes, and the page's size,
/// margins, headers and footers. A page layout document's text boxes and
/// pictures are read in page order; objects placed on the pages of a
/// word-processing document are left out.
///
/// Documents from Pages '09 and before, which are XML, are read by `Pages09Reader`.
enum PagesReader {
    /// Reads a document saved as a single file, which is a ZIP of the package.
    static func document(from data: Data) throws -> WordDocument {
        try document(fromFiles: ZipArchive.entries(in: data))
    }

    /// Reads a document saved as a package, by its files' paths within it.
    static func document(fromFiles files: [String: Data]) throws -> WordDocument {
        if let index = try Pages09Reader.index(in: files) {
            return try Pages09Reader.document(fromIndex: index, files: files)
        }
        return try document(from: IWorkArchive(files: files))
    }

    static func document(from archive: IWorkArchive) throws -> WordDocument {
        guard let root = archive.objects(ofType: Types.document).first?.object.message else {
            throw IWorkError.notAnIWorkDocument
        }
        var converter = PagesConverter(archive: archive)
        return converter.convert(root)
    }

    /// The message types the reader knows, by their registry numbers.
    enum Types {
        static let document: UInt32 = 10000
        static let pageMaster: UInt32 = 10143
        static let section: UInt32 = 10011
        static let storage: UInt32 = 2001
        static let drawableAttachment: UInt32 = 2003
        static let footnoteAttachment: UInt32 = 2008
        static let hyperlink: UInt32 = 2032
        static let pageNumber: UInt32 = 2043
        static let characterStyle: UInt32 = 2021
        static let paragraphStyle: UInt32 = 2022
        static let listStyle: UInt32 = 2023
        static let image: UInt32 = 3005
        static let shapeInfo: UInt32 = 2011
        static let tableInfo: UInt32 = 6000
        static let tableModel: UInt32 = 6001
    }
}

// MARK: - Styles

/// Character formatting from a `TSWP.CharacterStylePropertiesArchive`; `nil` inherits.
struct PagesCharacterProperties {
    var isBold: Bool?
    var isItalic: Bool?
    var fontSize: Double?
    var fontName: String?
    /// `.some(nil)` is the automatic colour.
    var colorHex: String??
    var verticalPosition: Int?
    var underline: Int?
    var strikethrough: Int?
    var capitalization: Int?
    var baselineShift: Double?

    init() {}

    init(_ message: ProtoMessage) {
        isBold = message.bool(1)
        isItalic = message.bool(2)
        fontSize = message.float(3)
        if message.bool(4) != true { fontName = message.string(5).flatMap { $0.isEmpty ? nil : $0 } }
        if message.bool(6) == true {
            colorHex = .some(nil)
        } else if let color = message.message(7) {
            colorHex = .some(PagesConverter.hex(color))
        }
        verticalPosition = message.optionalUInt(10).map(Int.init)
        underline = message.optionalUInt(11).map(Int.init)
        strikethrough = message.optionalUInt(12).map(Int.init)
        capitalization = message.optionalUInt(13).map(Int.init)
        baselineShift = message.float(14)
    }

    func overlaid(with other: PagesCharacterProperties) -> PagesCharacterProperties {
        var result = self
        result.isBold = other.isBold ?? isBold
        result.isItalic = other.isItalic ?? isItalic
        result.fontSize = other.fontSize ?? fontSize
        result.fontName = other.fontName ?? fontName
        result.colorHex = other.colorHex ?? colorHex
        result.verticalPosition = other.verticalPosition ?? verticalPosition
        result.underline = other.underline ?? underline
        result.strikethrough = other.strikethrough ?? strikethrough
        result.capitalization = other.capitalization ?? capitalization
        result.baselineShift = other.baselineShift ?? baselineShift
        return result
    }

    var runStyle: RunStyle {
        var style = RunStyle()
        style.fontName = fontName.map(PagesConverter.familyName)
        style.fontSize = fontSize.map { Int(($0 * 2).rounded()) }
        style.isBold = isBold == true ? true : nil
        style.isItalic = isItalic == true ? true : nil
        if let colorHex, let hex = colorHex, hex != "000000" { style.colorHex = hex }
        switch verticalPosition {
        case 1: style.verticalAlignment = .superscript
        case 2: style.verticalAlignment = .subscript
        default: break
        }
        switch underline {
        case 1: style.underline = true
        case 2: style.underline = true; style.underlineStyle = "double"
        case 3: style.underline = true; style.underlineStyle = "wave"
        default: break
        }
        switch strikethrough {
        case 1: style.isStruckThrough = true
        case 2, 3: style.isDoubleStruckThrough = true
        default: break
        }
        switch capitalization {
        case 1: style.allCaps = true
        case 2: style.smallCaps = true
        default: break
        }
        if let baselineShift, baselineShift != 0, style.verticalAlignment == nil {
            style.position = Int((baselineShift * 2).rounded())
        }
        return style
    }
}

/// Paragraph formatting from a `TSWP.ParagraphStylePropertiesArchive`, in points; `nil` inherits.
struct PagesParagraphProperties {
    var alignment: Int?
    var firstLineIndent: Double?
    var leftIndent: Double?
    var rightIndent: Double?
    var spaceBefore: Double?
    var spaceAfter: Double?
    var lineSpacing: LineSpacing?
    var keepLinesTogether: Bool?
    var keepWithNext: Bool?
    var pageBreakBefore: Bool?
    var widowControl: Bool?
    /// `.some(nil)` is no fill.
    var fillHex: String??
    /// Zero for the top level; `nil` for body text.
    var outlineLevel: Int??

    init() {}

    init(_ message: ProtoMessage) {
        alignment = message.optionalUInt(1).map(Int.init)
        if message.bool(5) == true {
            fillHex = .some(nil)
        } else if let fill = message.message(6) {
            fillHex = .some(fill.float(6) == 0 ? nil : PagesConverter.hex(fill))
        }
        firstLineIndent = message.float(7)
        keepLinesTogether = message.bool(9)
        keepWithNext = message.bool(10)
        leftIndent = message.float(11)
        if let spacing = message.message(13), let amount = spacing.float(2) {
            switch spacing.uint(1) {
            case 0: lineSpacing = LineSpacing(line: Int((amount * 240).rounded()), rule: .auto)
            case 1, 4: lineSpacing = LineSpacing(line: Int((amount * 20).rounded()), rule: .atLeast)
            case 2: lineSpacing = LineSpacing(line: Int((amount * 20).rounded()), rule: .exact)
            default: break
            }
        }
        pageBreakBefore = message.bool(14)
        rightIndent = message.float(19)
        spaceAfter = message.float(20)
        spaceBefore = message.float(21)
        widowControl = message.bool(26)
        if let level = message.optionalUInt(27) {
            outlineLevel = .some(level < 9 ? Int(level) : nil)
        }
    }

    func overlaid(with other: PagesParagraphProperties) -> PagesParagraphProperties {
        var result = self
        result.alignment = other.alignment ?? alignment
        result.firstLineIndent = other.firstLineIndent ?? firstLineIndent
        result.leftIndent = other.leftIndent ?? leftIndent
        result.rightIndent = other.rightIndent ?? rightIndent
        result.spaceBefore = other.spaceBefore ?? spaceBefore
        result.spaceAfter = other.spaceAfter ?? spaceAfter
        result.lineSpacing = other.lineSpacing ?? lineSpacing
        result.keepLinesTogether = other.keepLinesTogether ?? keepLinesTogether
        result.keepWithNext = other.keepWithNext ?? keepWithNext
        result.pageBreakBefore = other.pageBreakBefore ?? pageBreakBefore
        result.widowControl = other.widowControl ?? widowControl
        result.fillHex = other.fillHex ?? fillHex
        result.outlineLevel = other.outlineLevel ?? outlineLevel
        return result
    }

    var paragraphProperties: ParagraphProperties {
        var properties = ParagraphProperties()
        switch alignment {
        case 1: properties.alignment = .trailing
        case 2: properties.alignment = .center
        case 3: properties.alignment = .justified
        default: break
        }
        func twips(_ points: Double?) -> Int? {
            points.map { Int(($0 * 20).rounded()) }
        }
        let left = leftIndent ?? 0
        if left != 0 { properties.indentLeft = twips(left) }
        if let rightIndent, rightIndent != 0 { properties.indentRight = twips(rightIndent) }
        // Pages measures the first line from the margin; Word, from the other lines.
        if let firstLineIndent, firstLineIndent != left { properties.indentFirstLine = twips(firstLineIndent - left) }
        properties.spacingBefore = twips(spaceBefore)
        properties.spacingAfter = twips(spaceAfter)
        properties.lineSpacing = lineSpacing
        properties.keepLines = keepLinesTogether == true ? true : nil
        properties.keepNext = keepWithNext == true ? true : nil
        properties.pageBreakBefore = pageBreakBefore == true ? true : nil
        if let fillHex, let hex = fillHex { properties.shadingHex = hex }
        if let outlineLevel, let level = outlineLevel {
            properties.outlineLevel = level
            let headings: [ParagraphStyleChoice] = [.heading1, .heading2, .heading3]
            if headings.indices.contains(level) { properties.styleID = headings[level].defaultID }
        }
        return properties
    }
}

// MARK: - Conversion

struct PagesConverter {
    let archive: IWorkArchive
    var document: WordDocument = {
        var document = WordDocument()
        document.importedFormat = .pages
        return document
    }()

    private var paragraphStyles: [UInt64: (PagesParagraphProperties, PagesCharacterProperties)] = [:]
    private var characterStyles: [UInt64: PagesCharacterProperties] = [:]
    /// The list each list style became, by the list style's identifier; `nil` for no list.
    private var lists: [UInt64: Int?] = [:]
    /// The link each hyperlink field became, by its identifier; `nil` for none.
    private var links: [UInt64: Hyperlink?] = [:]
    /// How deep in text storages the conversion is: one in the body, more in its tables.
    private var storageDepth = 0
    /// The formatting of the body's first plain paragraph, and of its first
    /// heading of each level, which become the Normal and heading styles.
    private var bodyStyle: (PagesParagraphProperties, PagesCharacterProperties)?
    private var headingStyles: [Int: (PagesParagraphProperties, PagesCharacterProperties)] = [:]

    init(archive: IWorkArchive) {
        self.archive = archive
    }

    mutating func convert(_ root: ProtoMessage) -> WordDocument {
        readPageSetup(root)
        let storage = archive[root.reference(4)].flatMap { $0.type == PagesReader.Types.storage ? $0.message : nil }
        var blocks = storage.map { self.blocks(from: $0) } ?? []
        let floating = archive[root.reference(3)]?.message.messages(1).filter { !$0.messages(4).isEmpty } ?? []
        if !floating.isEmpty {
            if blocks.allSatisfy(Self.isBlank) {
                // A page layout document has no body text, only a break between each page and the
                // next: its pages are what is placed on them.
                blocks = floatingBlocks(floating)
            } else {
                // Objects placed on a page of a word-processing document have no place in its text.
                document.unsupportedFeatures.insert(.shapes)
            }
        }
        // A table cannot end the document; Word wants a paragraph after it.
        if blocks.isEmpty || { if case .table = blocks.last { true } else { false } }() {
            blocks.append(.paragraph(Paragraph()))
        }
        document.body = blocks
        adoptStyles()
        if let storage { readHeadersAndFooters(storage) }
        return document
    }

    /// What is placed on the pages, page by page, read down each page and
    /// across: text boxes' and shapes' text as paragraphs, pictures and
    /// tables as they are, and a page break between pages.
    private mutating func floatingBlocks(_ pages: [ProtoMessage]) -> [Block] {
        var blocks: [Block] = []
        for (index, page) in pages.sorted(by: { $0.uint(1) < $1.uint(1) }).enumerated() {
            if index > 0 {
                if case .paragraph(var last) = blocks.last {
                    last.inlines.append(Inline(.pageBreak))
                    blocks[blocks.count - 1] = .paragraph(last)
                } else {
                    blocks.append(.paragraph(Paragraph(inlines: [Inline(.pageBreak)])))
                }
            }
            let objects = page.messages(4).compactMap { entry -> (object: IWorkArchive.Object, x: Double, y: Double)? in
                guard let object = archive[entry.reference(1)] else { return nil }
                let position = Self.geometry(of: object)?.message(1)
                return (object, position?.float(1) ?? 0, position?.float(2) ?? 0)
            }
            for item in objects.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
                switch item.object.type {
                case PagesReader.Types.shapeInfo:
                    guard let text = archive[item.object.message.reference(2)], text.type == PagesReader.Types.storage
                    else { continue }
                    let content = self.blocks(from: text.message)
                    if content.allSatisfy(Self.isBlank) {
                        // A shape with no text is a drawing Libretto cannot bring across.
                        document.unsupportedFeatures.insert(.shapes)
                    } else {
                        blocks += content
                    }
                case PagesReader.Types.image:
                    if let image = image(item.object.message) {
                        blocks.append(.paragraph(Paragraph(inlines: [Inline(.image(image))])))
                    }
                case PagesReader.Types.tableInfo:
                    if let table = table(item.object.message) { blocks.append(.table(table)) }
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

    /// A drawable's `TSD.GeometryArchive`, from its `TSD.DrawableArchive`
    /// or from the shape that one is the super of.
    private static func geometry(of object: IWorkArchive.Object) -> ProtoMessage? {
        let drawable = object.type == PagesReader.Types.shapeInfo
            ? object.message.message(1)?.message(1) : object.message.message(1)
        return drawable?.message(1)
    }

    private mutating func readPageSetup(_ root: ProtoMessage) {
        func twips(_ field: Int) -> Int? {
            root.float(field).map { Int(($0 * 20).rounded()) }
        }
        var setup = document.pageSetup
        if let width = twips(30), let height = twips(31), width > 0, height > 0 {
            setup.width = width
            setup.height = height
        }
        setup.marginLeft = twips(32) ?? setup.marginLeft
        setup.marginRight = twips(33) ?? setup.marginRight
        setup.marginTop = twips(34) ?? setup.marginTop
        setup.marginBottom = twips(35) ?? setup.marginBottom
        setup.headerDistance = twips(36) ?? setup.headerDistance
        setup.footerDistance = twips(37) ?? setup.footerDistance
        document.pageSetup = setup
    }

    private mutating func adoptStyles() {
        document.adoptPagesStyles(body: bodyStyle, headings: headingStyles)
    }

    // MARK: Text

    /// The blocks a text storage holds: its paragraphs, and the tables set in them.
    mutating func blocks(from storage: ProtoMessage) -> [Block] {
        storageDepth += 1
        defer { storageDepth -= 1 }
        let text = Array(storage.strings(3).joined().utf16)
        let paragraphStyles = AttributeTable(storage.message(5))
        let paragraphData = storage.message(6)?.messages(1).map { (index: Int($0.uint(1)), level: Int($0.uint(2))) } ?? []
        let listStyles = AttributeTable(storage.message(7))
        let characterStyles = AttributeTable(storage.message(8))
        let attachments = AttributeTable(storage.message(9))
        let footnotes = AttributeTable(storage.message(16))
        let smartFields = AttributeTable(storage.message(11))

        var blocks: [Block] = []
        var start = 0
        while start <= text.count {
            var end = start
            while end < text.count, !Self.paragraphTerminators.contains(text[end]) { end += 1 }

            let styleID = paragraphStyles.inheritedObject(at: start)
            var paragraphFormat = PagesParagraphProperties()
            var baseCharacters = PagesCharacterProperties()
            if let styleID { (paragraphFormat, baseCharacters) = paragraphStyle(styleID) }
            var paragraph = Paragraph(properties: paragraphFormat.paragraphProperties)
            let listNumberingID = listStyles.inheritedObject(at: start).flatMap { list(for: $0) }
            if storageDepth == 1 {
                if let level = paragraphFormat.outlineLevel ?? nil {
                    if headingStyles[level] == nil { headingStyles[level] = (paragraphFormat, baseCharacters) }
                } else if bodyStyle == nil, listNumberingID == nil, start < end {
                    bodyStyle = (paragraphFormat, baseCharacters)
                }
            }
            if let numberingID = listNumberingID {
                let level = paragraphData.last { $0.index <= start }?.level ?? 0
                paragraph.properties.list = ListReference(numberingID: numberingID, level: min(level, 8))
                // The list's own indents apply, as they do in Pages.
                paragraph.properties.indentLeft = nil
                paragraph.properties.indentFirstLine = nil
            }

            var tables: [Block] = []
            var pending: [UInt16] = []
            var pendingFormat = RunFormat()
            var pendingLink: Hyperlink?
            func flush() {
                guard !pending.isEmpty else { return }
                paragraph.inlines.append(Inline(
                    .text(String(decoding: pending, as: UTF16.self)), format: pendingFormat, hyperlink: pendingLink
                ))
                pending = []
            }
            for index in start..<end {
                let unit = text[index]
                var characters = PagesCharacterProperties()
                if let styleID = characterStyles.object(at: index) { characters = characterStyle(styleID) }
                let format = RunFormat(style: baseCharacters.overlaid(with: characters).runStyle)
                let link = smartFields.object(at: index).flatMap { hyperlink($0) }
                if format != pendingFormat || link != pendingLink { flush(); pendingFormat = format; pendingLink = link }
                switch unit {
                case 0x09:
                    flush()
                    paragraph.inlines.append(Inline(.tab, format: format, hyperlink: link))
                case 0x2028:
                    flush()
                    paragraph.inlines.append(Inline(.lineBreak, format: format, hyperlink: link))
                case 0x000E:
                    flush()
                    if let reference = footnote(footnotes.object(at: index)) {
                        var noteFormat = format
                        noteFormat.style.verticalAlignment = .superscript
                        paragraph.inlines.append(Inline(.note(reference), format: noteFormat))
                    }
                case 0xFFFC:
                    flush()
                    switch attachment(attachments.object(at: index)) {
                    case .image(let image): paragraph.inlines.append(Inline(.image(image), format: format))
                    case .table(let table): tables.append(.table(table))
                    case nil: break
                    }
                case 0x00..<0x20:
                    // Other markers, such as for comments and fields, take no room.
                    break
                default:
                    pending.append(unit)
                }
            }
            flush()
            if end < text.count, text[end] == 0x05 || text[end] == 0x04 {
                paragraph.inlines.append(Inline(.pageBreak))
            }
            // A paragraph that only held a table becomes the table.
            if tables.isEmpty || !paragraph.inlines.isEmpty { blocks.append(.paragraph(paragraph)) }
            blocks += tables
            start = end + 1
        }
        return blocks
    }

    /// Paragraph breaks, and the page and section breaks that also end a paragraph.
    private static let paragraphTerminators: Set<UInt16> = [0x0A, 0x2029, 0x04, 0x05]

    /// The plain text of a storage, its paragraphs a line each, with page
    /// numbers as the placeholders headers and footers fill in.
    func plainText(of storage: ProtoMessage) -> String {
        let text = Array(storage.strings(3).joined().utf16)
        let attachments = AttributeTable(storage.message(9))
        var result: [UInt16] = []
        for (index, unit) in text.enumerated() {
            switch unit {
            case 0x0A, 0x2029, 0x2028:
                result.append(0x0A)
            case 0x09:
                result.append(unit)
            case 0xFFFC:
                guard let field = archive[attachments.object(at: index)], field.type == PagesReader.Types.pageNumber
                else { continue }
                let placeholder = field.message.message(1)?.uint(2) == 1
                    ? HeaderFooterText.pageCountPlaceholder : HeaderFooterText.pageNumberPlaceholder
                result += placeholder.utf16
            case 0x00..<0x20:
                continue
            default:
                result.append(unit)
            }
        }
        return String(decoding: result, as: UTF16.self).trimmingCharacters(in: .newlines)
    }

    /// A link to the address a `TSWP.HyperlinkFieldArchive` holds, made the first time it is met.
    private mutating func hyperlink(_ identifier: UInt64) -> Hyperlink? {
        if let known = links[identifier] { return known }
        guard let field = archive[identifier], field.type == PagesReader.Types.hyperlink,
              let address = field.message.string(2), !address.isEmpty else {
            links[identifier] = .some(nil)
            return nil
        }
        let id = document.package.unusedRelationshipID()
        document.package.addedLinks[id] = address
        let link = Hyperlink(
            relationshipID: id, anchor: nil, url: URL(string: address),
            attributesXML: " r:id=\"\(id)\" w:history=\"1\""
        )
        links[identifier] = link
        return link
    }

    private mutating func paragraphStyle(_ identifier: UInt64) -> (PagesParagraphProperties, PagesCharacterProperties) {
        if let cached = paragraphStyles[identifier] { return cached }
        var chain: [ProtoMessage] = []
        var next: UInt64? = identifier
        while let current = next, let object = archive[current], object.type == PagesReader.Types.paragraphStyle,
              chain.count < 32 {
            chain.append(object.message)
            next = object.message.message(1)?.reference(3)
        }
        var paragraph = PagesParagraphProperties()
        var characters = PagesCharacterProperties()
        for style in chain.reversed() {
            if let properties = style.message(12) { paragraph = paragraph.overlaid(with: PagesParagraphProperties(properties)) }
            if let properties = style.message(11) { characters = characters.overlaid(with: PagesCharacterProperties(properties)) }
        }
        paragraphStyles[identifier] = (paragraph, characters)
        return (paragraph, characters)
    }

    private mutating func characterStyle(_ identifier: UInt64) -> PagesCharacterProperties {
        if let cached = characterStyles[identifier] { return cached }
        var chain: [ProtoMessage] = []
        var next: UInt64? = identifier
        while let current = next, let object = archive[current], object.type == PagesReader.Types.characterStyle,
              chain.count < 32 {
            chain.append(object.message)
            next = object.message.message(1)?.reference(3)
        }
        let properties = chain.reversed().reduce(PagesCharacterProperties()) { result, style in
            style.message(11).map { result.overlaid(with: PagesCharacterProperties($0)) } ?? result
        }
        characterStyles[identifier] = properties
        return properties
    }

    // MARK: Lists

    /// The list a `TSWP.ListStyleArchive` becomes, made the first time it is
    /// met; `nil` if it labels nothing.
    private mutating func list(for identifier: UInt64) -> Int? {
        if let known = lists[identifier] { return known }
        guard let style = archive[identifier], style.type == PagesReader.Types.listStyle else { return nil }
        let labelTypes = style.message.uints(11)
        let numberTypes = style.message.uints(15)
        let bullets = style.message.strings(16)
        func value<T>(_ values: [T], _ level: Int) -> T? {
            values.isEmpty ? nil : values[min(level, values.count - 1)]
        }
        guard let first = labelTypes.first, first != 0 else {
            lists[identifier] = .some(nil)
            return nil
        }
        let standardBullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let levels = Dictionary(uniqueKeysWithValues: (0..<9).map { level -> (Int, NumberingDefinitions.ListLevel) in
            let indent = 720 * (level + 1)
            if value(labelTypes, level) == 3 {
                let (format, pattern) = Self.numberFormat(value(numberTypes, level) ?? 0)
                return (level, NumberingDefinitions.ListLevel(
                    format: format, text: pattern.replacingOccurrences(of: "%", with: "%\(level + 1)"),
                    indentLeft: indent, hanging: 360
                ))
            }
            let bullet = value(bullets, level).flatMap { $0.isEmpty ? nil : $0 } ?? standardBullets[level % 3]
            return (level, NumberingDefinitions.ListLevel(format: "bullet", text: bullet, indentLeft: indent, hanging: 360))
        })
        let numberingID = document.numbering.addList(levels: levels, kind: first == 3 ? .numbered : .bulleted)
        lists[identifier] = numberingID
        return numberingID
    }

    /// `w:numFmt` and `w:lvlText`, with `%` for the number, for a `TSWP.ListStyleArchive.NumberType`.
    private static func numberFormat(_ type: UInt64) -> (String, String) {
        let formats = ["decimal", "upperRoman", "lowerRoman", "upperLetter", "lowerLetter"]
        guard type < 15 else { return ("decimal", "%.") }
        let patterns = ["%.", "(%)", "%)"]
        return (formats[Int(type) / 3], patterns[Int(type) % 3])
    }

    // MARK: Attachments

    private enum Attachment {
        case image(InlineImage)
        case table(Table)
    }

    private mutating func attachment(_ identifier: UInt64?) -> Attachment? {
        guard let attachment = archive[identifier], attachment.type == PagesReader.Types.drawableAttachment,
              let drawable = archive[attachment.message.reference(1)] else { return nil }
        switch drawable.type {
        case PagesReader.Types.image:
            if let image = image(drawable.message) { return .image(image) }
        case PagesReader.Types.tableInfo:
            if let table = table(drawable.message) { return .table(table) }
        default:
            break
        }
        document.unsupportedFeatures.insert(.shapes)
        return nil
    }

    /// A `TSD.ImageArchive`, at the size it is shown.
    private mutating func image(_ message: ProtoMessage) -> InlineImage? {
        guard let identifier = message.reference(11), let file = archive.dataFile(identifier),
              let (data, fileExtension, contentType) = Self.wordImage(file.data) else { return nil }
        let size = message.message(1)?.message(1)?.message(2)
        let natural = message.message(4) ?? message.message(9)
        let width = size?.float(1) ?? natural?.float(1) ?? 100
        let height = size?.float(2) ?? natural?.float(2) ?? 100
        let id = document.package.unusedRelationshipID()
        document.package.addedMedia[id] = DocumentPackage.AddedMedia(
            path: "word/media/pages-\(identifier).\(fileExtension)", data: data,
            fileExtension: fileExtension, contentType: contentType
        )
        return InlineImage(relationshipID: id, width: width, height: height, xml: nil)
    }

    /// An image as Word reads it: PNG and JPEG as they are, anything else as PNG.
    static func wordImage(_ data: Data) -> (Data, String, String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return nil }
        if type.conforms(to: .png) { return (data, "png", "image/png") }
        if type.conforms(to: .jpeg) { return (data, "jpeg", "image/jpeg") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "png", "image/png")
    }

    // MARK: Footnotes

    private mutating func footnote(_ identifier: UInt64?) -> NoteReference? {
        guard let attachment = archive[identifier], attachment.type == PagesReader.Types.footnoteAttachment,
              let storage = archive[attachment.message.reference(2)], storage.type == PagesReader.Types.storage
        else { return nil }
        let id = document.unusedNoteID(.footnote)
        document.notes.append(Note(kind: .footnote, id: id, text: plainText(of: storage.message)))
        return NoteReference(kind: .footnote, id: id)
    }

    // MARK: Tables

    /// A `TST.TableInfoArchive`'s table, with each cell's text.
    private mutating func table(_ info: ProtoMessage) -> Table? {
        guard let model = archive[info.reference(2)], model.type == PagesReader.Types.tableModel else { return nil }
        let rowCount = Int(model.message.uint(6))
        let columnCount = Int(model.message.uint(7))
        guard rowCount > 0, columnCount > 0, rowCount * columnCount <= 100_000,
              let store = model.message.message(4) else { return nil }

        let defaultWidth = model.message.float(17) ?? 100
        var widths = Array(repeating: defaultWidth, count: columnCount)
        for header in archive[store.reference(2)]?.message.messages(2) ?? [] {
            let index = Int(header.uint(1))
            if widths.indices.contains(index), let size = header.float(2), size > 0 { widths[index] = size }
        }

        let lists = CellLists(
            strings: dataList(store.reference(4)), richText: dataList(store.reference(17)),
            styles: dataList(store.reference(5))
        )
        var cells = Array(repeating: Array(repeating: TableCell(blocks: []), count: columnCount), count: rowCount)
        let tileStorage = store.message(3)
        let tileSize = Int(tileStorage?.optionalUInt(2) ?? 256)
        for tileEntry in tileStorage?.messages(1) ?? [] {
            guard let tile = archive[tileEntry.reference(2)]?.message else { continue }
            let firstRow = Int(tileEntry.uint(1)) * tileSize
            for rowInfo in tile.messages(5) {
                let row = firstRow + Int(rowInfo.uint(1))
                // Pages has written both formats since 2019; older files have only the first.
                let isNew = rowInfo.has(7)
                guard row < rowCount, let buffer = rowInfo.bytes(isNew ? 6 : 3), let offsets = rowInfo.bytes(isNew ? 7 : 4)
                else { continue }
                // Wide rows count their offsets in fours.
                let scale = rowInfo.bool(8) == true ? 4 : 1
                for column in 0..<min(columnCount, offsets.count / 2) {
                    let at = offsets.startIndex + column * 2
                    let offset = Int(offsets[at]) | Int(offsets[at + 1]) << 8
                    guard offset != 0xFFFF, buffer.startIndex + offset * scale < buffer.endIndex else { continue }
                    let bytes = buffer[(buffer.startIndex + offset * scale)...]
                    let value = isNew ? CellValue(newStorage: bytes) : CellValue(oldStorage: bytes)
                    if let value { cells[row][column] = cell(value, lists: lists) }
                }
            }
        }

        let grid = widths.map { Int(($0 * 20).rounded()) }
        var spans = Array(repeating: Array(repeating: 1, count: columnCount), count: rowCount)
        var covered = Array(repeating: Array(repeating: false, count: columnCount), count: rowCount)
        var merges = Array(repeating: Array(repeating: TableCell.VerticalMerge?.none, count: columnCount), count: rowCount)
        for region in mergedRegions(model.message, store: store) {
            let rows = region.rows.clamped(to: 0..<rowCount)
            let columns = region.columns.clamped(to: 0..<columnCount)
            guard let top = rows.first, let left = columns.first, rows.count * columns.count > 1 else { continue }
            for row in rows {
                spans[row][left] = columns.count
                if rows.count > 1 { merges[row][left] = row == top ? .restart : .continue }
                for column in columns.dropFirst() { covered[row][column] = true }
            }
        }

        let headerRows = Int(model.message.uint(9))
        let rows = cells.enumerated().map { row, cellsInRow in
            TableRow(
                cells: cellsInRow.enumerated().compactMap { column, cell -> TableCell? in
                    guard !covered[row][column] else { return nil }
                    var cell = cell
                    cell.gridSpan = spans[row][column]
                    cell.verticalMerge = merges[row][column]
                    if cell.verticalMerge == .continue { cell.blocks = [] }
                    if cell.blocks.isEmpty { cell.blocks = [.paragraph(Paragraph())] }
                    cell.preservedPropertiesXML = Self.cellPropertiesXML(cell, width: grid[column..<(column + cell.gridSpan)].reduce(0, +))
                    return cell
                },
                isHeader: row < headerRows
            )
        }
        return Table(
            rows: rows, gridColumns: grid,
            preservedPropertiesXML: nil, styleID: nil, hasBorders: true
        )
    }

    /// `w:tcPr` for a cell, since the writer gives a cell only its width
    /// unless it has properties of its own.
    private static func cellPropertiesXML(_ cell: TableCell, width: Int) -> String? {
        guard cell.gridSpan > 1 || cell.verticalMerge != nil || cell.shadingHex != nil else { return nil }
        var xml = "<w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if cell.gridSpan > 1 { xml += "<w:gridSpan w:val=\"\(cell.gridSpan)\"/>" }
        switch cell.verticalMerge {
        case .restart: xml += "<w:vMerge w:val=\"restart\"/>"
        case .continue: xml += "<w:vMerge/>"
        case nil: break
        }
        if let fill = cell.shadingHex { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        return xml + "</w:tcPr>"
    }

    /// The table's merged cells, as row and column ranges.
    private func mergedRegions(_ model: ProtoMessage, store: ProtoMessage) -> [(rows: Range<Int>, columns: Range<Int>)] {
        // Since 2019, each merge is a range reference among the table's formulas.
        var regions: [(rows: Range<Int>, columns: Range<Int>)] = []
        for formula in model.message(47)?.message(2)?.messages(3) ?? [] {
            for node in formula.message(2)?.message(1)?.messages(1) ?? [] {
                guard let range = node.message(40), let columns = range.message(3), let rows = range.message(4) else { continue }
                func span(_ message: ProtoMessage) -> Range<Int> {
                    let first = Int(message.uint(1))
                    return first..<(Int(message.optionalUInt(2) ?? UInt64(first)) + 1)
                }
                regions.append((span(rows), span(columns)))
            }
        }
        // Before, a map of ranges, each corner and size packed as row and column halves.
        if regions.isEmpty, let map = archive[store.reference(13)]?.message {
            for range in map.messages(1) {
                guard let origin = range.message(1)?.optionalUInt(1), let size = range.message(2)?.optionalUInt(1) else { continue }
                let row = Int(origin & 0xFFFF)
                let column = Int(origin >> 16 & 0xFFFF)
                regions.append((row..<(row + Int(size & 0xFFFF)), column..<(column + Int(size >> 16 & 0xFFFF))))
            }
        }
        return regions
    }

    /// A `TST.TableDataList`'s entries by key: their text, or the rich text they refer to.
    private func dataList(_ identifier: UInt64?) -> [UInt64: ProtoMessage] {
        Dictionary(
            (archive[identifier]?.message.messages(3) ?? []).map { ($0.uint(1), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The lists a table's cells refer to by key.
    private struct CellLists {
        var strings: [UInt64: ProtoMessage]
        var richText: [UInt64: ProtoMessage]
        var styles: [UInt64: ProtoMessage]
    }

    /// What a cell's storage holds.
    struct CellValue {
        var type: UInt8
        var decimal: Double?
        var double: Double?
        var seconds: Double?
        var stringKey: UInt64?
        var richKey: UInt64?
        var styleKey: UInt64?

        /// The format Pages has written since 2019: a version byte, the
        /// value's type, flags at the eighth byte saying which values follow
        /// from the twelfth, in a fixed order.
        init?(newStorage bytes: ArraySlice<UInt8>) {
            guard bytes.count >= 12, bytes[bytes.startIndex] >= 5 else { return nil }
            type = bytes[bytes.startIndex + 1]
            let flags = Self.read(bytes, 4, at: 8) ?? 0
            var offset = 12
            if flags & 0x1 != 0 { decimal = Self.decimal128(bytes, at: bytes.startIndex + offset); offset += 16 }
            if flags & 0x2 != 0 { double = Self.read(bytes, 8, at: offset).map { Double(bitPattern: $0) }; offset += 8 }
            if flags & 0x4 != 0 { seconds = Self.read(bytes, 8, at: offset).map { Double(bitPattern: $0) }; offset += 8 }
            if flags & 0x8 != 0 { stringKey = Self.read(bytes, 4, at: offset); offset += 4 }
            if flags & 0x10 != 0 { richKey = Self.read(bytes, 4, at: offset); offset += 4 }
            if flags & 0x20 != 0 { styleKey = Self.read(bytes, 4, at: offset) }
        }

        /// The format before: the version, then the type, at the second byte
        /// from version 4 and the third before it, flags at the fifth, and the
        /// values after the keys the flags ask for.
        init?(oldStorage bytes: ArraySlice<UInt8>) {
            guard bytes.count >= 8 else { return nil }
            let version = bytes[bytes.startIndex]
            guard (1...4).contains(version) else { return nil }
            type = bytes[bytes.startIndex + (version >= 4 ? 1 : 2)]
            let flags = Self.read(bytes, 4, at: 4) ?? 0
            var offset = (version > 1 ? 12 : 8) + (flags & (version > 1 ? 0x0D8E : 0x018E)).nonzeroBitCount * 4
            if flags & 0x200 != 0 { richKey = Self.read(bytes, 4, at: offset); offset += 4 }
            offset += (flags & (version > 1 ? 0x3000 : 0x1000)).nonzeroBitCount * 4
            if flags & 0x10 != 0 { stringKey = Self.read(bytes, 4, at: offset); offset += 4 }
            if flags & 0x20 != 0 { double = Self.read(bytes, 8, at: offset).map { Double(bitPattern: $0) }; offset += 8 }
            if flags & 0x40 != 0 { seconds = Self.read(bytes, 8, at: offset).map { Double(bitPattern: $0) } }
        }

        private static func read(_ bytes: ArraySlice<UInt8>, _ count: Int, at offset: Int) -> UInt64? {
            let start = bytes.startIndex + offset
            guard start + count <= bytes.endIndex else { return nil }
            return bytes[start..<(start + count)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// An IEEE 754 decimal128 in binary integer form, as cells store numbers.
        private static func decimal128(_ bytes: ArraySlice<UInt8>, at start: Int) -> Double? {
            guard start + 16 <= bytes.endIndex else { return nil }
            let exponent = (Int(bytes[start + 15] & 0x7F) << 7 | Int(bytes[start + 14]) >> 1) - 0x1820
            var mantissa = Double(bytes[start + 14] & 1)
            for index in stride(from: 13, through: 0, by: -1) { mantissa = mantissa * 256 + Double(bytes[start + index]) }
            let value = mantissa * pow(10, Double(exponent))
            return bytes[start + 15] & 0x80 != 0 ? -value : value
        }
    }

    private mutating func cell(_ value: CellValue, lists: CellLists) -> TableCell {
        let shading = value.styleKey.flatMap { lists.styles[$0]?.reference(4) }.flatMap(cellFill)
        let text: String?
        switch value.type {
        case 3:
            text = value.stringKey.flatMap { lists.strings[$0]?.string(3) }
        case 9:
            if let payload = archive[value.richKey.flatMap { lists.richText[$0]?.reference(9) }],
               let storage = archive[payload.message.reference(1)], storage.type == PagesReader.Types.storage {
                return TableCell(blocks: blocks(from: storage.message), shadingHex: shading)
            }
            text = nil
        case 2, 10:
            text = (value.decimal ?? value.double).map(Self.numberText)
        case 5:
            text = value.seconds.map { Date(timeIntervalSinceReferenceDate: $0).formatted(date: .numeric, time: .omitted) }
        case 6:
            text = (value.double ?? value.decimal).map { $0 != 0 ? "TRUE" : "FALSE" }
        default:
            text = nil
        }
        return TableCell(blocks: text.map { [.paragraph(Paragraph(text: $0))] } ?? [], shadingHex: shading)
    }

    /// The fill of a `TST.CellStyleArchive`, or of the style it is a variation of.
    private func cellFill(_ identifier: UInt64) -> String? {
        var next: UInt64? = identifier
        var depth = 0
        while let current = next, let style = archive[current], depth < 32 {
            // An empty fill takes away the one the style it varies has.
            if let fill = style.message.message(11)?.message(1) {
                guard let color = fill.message(1), color.float(6) != 0 else { return nil }
                return Self.hex(color)
            }
            next = style.message.message(1)?.reference(3)
            depth += 1
        }
        return nil
    }

    private static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    // MARK: Headers and footers

    /// The headers and footers of the body's first section, from its page masters.
    private mutating func readHeadersAndFooters(_ body: ProtoMessage) {
        guard let sectionID = AttributeTable(body.message(17)).object(at: 0),
              let section = archive[sectionID], section.type == PagesReader.Types.section else { return }
        let masters: [(HeaderFooterKind, Int)] = [(.default, 25), (.first, 23), (.even, 24)]
        let firstPageDiffers = section.message.bool(18) == true
        let evenPagesDiffer = section.message.bool(19) == true
        for (kind, field) in masters {
            if kind == .first, !firstPageDiffers { continue }
            if kind == .even, !evenPagesDiffer { continue }
            guard let master = archive[section.message.reference(field)], master.type == PagesReader.Types.pageMaster
            else { continue }
            for isFooter in [false, true] {
                let slots = master.message.messages(isFooter ? 2 : 1).compactMap { $0.optionalUInt(1) }
                guard let text = headerFooter(slots: slots, isFooter: isFooter) else { continue }
                let id = document.unusedHeaderFooterID(isFooter: isFooter)
                document.headerFooters[id] = text
                if isFooter {
                    document.pageSetup.headerFooters.footers[kind] = id
                } else {
                    document.pageSetup.headerFooters.headers[kind] = id
                }
            }
        }
        document.pageSetup.headerFooters.titlePage = firstPageDiffers
        document.evenAndOddHeaders = evenPagesDiffer
    }

    /// A header or footer from its left, centre and right parts, each aligned
    /// as its text is, or else as where it sits.
    private mutating func headerFooter(slots: [UInt64], isFooter: Bool) -> HeaderFooterText? {
        let alignments: [ParagraphAlignment] = [.leading, .center, .trailing]
        var parts: [(ParagraphAlignment, String)] = []
        for (index, identifier) in slots.prefix(3).enumerated() {
            guard let storage = archive[identifier], storage.type == PagesReader.Types.storage else { continue }
            let text = plainText(of: storage.message)
            guard !text.isEmpty else { continue }
            let styleID = AttributeTable(storage.message.message(5)).inheritedObject(at: 0)
            let own = styleID.flatMap { paragraphStyle($0).0.alignment }
            switch own {
            case 0, 3: parts.append((.leading, text))
            case 1: parts.append((.trailing, text))
            case 2: parts.append((.center, text))
            default: parts.append((alignments[index], text))
            }
        }
        guard !parts.isEmpty else { return nil }
        let alignment = parts.count == 1 ? parts[0].0 : .leading
        var text = HeaderFooterText(
            text: parts.map(\.1).joined(separator: "\t"), alignment: alignment, isFooter: isFooter
        )
        text.isEdited = true
        return text
    }

    // MARK: Helpers

    /// Six-digit RGB for a `TSP.Color`.
    static func hex(_ color: ProtoMessage) -> String? {
        let components: [Double]
        switch color.uint(1) {
        case 1:
            components = [color.float(3) ?? 0, color.float(4) ?? 0, color.float(5) ?? 0]
        case 2:
            let black = color.float(10) ?? 0
            components = [7, 8, 9].map { (1 - (color.float($0) ?? 0)) * (1 - black) }
        case 3:
            let white = color.float(11) ?? 0
            components = [white, white, white]
        default:
            return nil
        }
        return components.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }

    /// A font's family name, as Word names fonts, from the PostScript name Pages records.
    static func familyName(_ postScriptName: String) -> String {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        if CTFontCopyPostScriptName(font) as String == postScriptName {
            return CTFontCopyFamilyName(font) as String
        }
        // Not installed: take the name apart as PostScript names are usually put together.
        var family = postScriptName.split(separator: "-").first.map(String.init) ?? postScriptName
        for suffix in ["PSMT", "MT", "PS"] where family.hasSuffix(suffix) && family.count > suffix.count {
            family.removeLast(suffix.count)
            break
        }
        var spaced = ""
        for (index, character) in family.enumerated() {
            if index > 0, character.isUppercase, let previous = spaced.last, previous.isLowercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced
    }
}

/// A `TSWP.ObjectAttributeTable`: objects that apply from a character index on.
private struct AttributeTable {
    private let entries: [(index: Int, object: UInt64?)]

    init(_ message: ProtoMessage?) {
        entries = (message?.messages(1) ?? []).map { (Int($0.uint(1)), $0.reference(2)) }
    }

    /// The object in effect at `index`; an entry with none means none.
    func object(at index: Int) -> UInt64? {
        entry(at: index).flatMap { entries[$0].object }
    }

    /// The object in effect at `index`, where an entry with none carries on the one before.
    func inheritedObject(at index: Int) -> UInt64? {
        guard let last = entry(at: index) else { return nil }
        return entries[...last].reversed().lazy.compactMap(\.object).first
    }

    private func entry(at index: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].index <= index { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}

extension WordDocument {
    /// Makes the Normal and heading styles look as a Pages document's own
    /// do, so what takes its formatting from them, such as headers,
    /// footnotes and list numbers, looks as it did in Pages.
    mutating func adoptPagesStyles(
        body: (PagesParagraphProperties, PagesCharacterProperties)?,
        headings: [Int: (PagesParagraphProperties, PagesCharacterProperties)]
    ) {
        if let (paragraph, characters) = body {
            adopt(paragraph, characters, into: styles.defaultParagraphStyleID ?? "Normal", isHeading: false)
        }
        let choices: [ParagraphStyleChoice] = [.heading1, .heading2, .heading3]
        for (level, (paragraph, characters)) in headings where choices.indices.contains(level) {
            adopt(paragraph, characters, into: choices[level].defaultID, isHeading: true)
        }
    }

    private mutating func adopt(
        _ paragraph: PagesParagraphProperties, _ characters: PagesCharacterProperties, into id: String, isHeading: Bool
    ) {
        guard var style = styles.styles[id] else { return }
        let run = characters.runStyle
        style.runStyle.fontName = run.fontName ?? style.runStyle.fontName
        style.runStyle.fontSize = run.fontSize ?? style.runStyle.fontSize
        // A heading's own colour is replaced even by black, which the body leaves automatic.
        if let colorHex = run.colorHex ?? (isHeading ? "000000" : nil) { style.runStyle.colorHex = colorHex }
        // Pages leaves out spacing it has none of.
        style.paragraphProperties.spacingBefore = Int(((paragraph.spaceBefore ?? 0) * 20).rounded())
        style.paragraphProperties.spacingAfter = Int(((paragraph.spaceAfter ?? 0) * 20).rounded())
        style.paragraphProperties.lineSpacing = paragraph.lineSpacing ?? LineSpacing(line: 240, rule: .auto)
        styles.styles[id] = style
    }
}
