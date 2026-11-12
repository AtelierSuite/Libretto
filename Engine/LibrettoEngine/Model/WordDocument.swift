import Foundation

/// An entire word-processing document, as Libretto models it.
///
/// Only the parts Libretto can edit are modelled: paragraphs, their runs of
/// text, tables, inline pictures and the page setup. Everything else in the
/// file is carried as the XML it arrived as, either in place (inside the
/// paragraph or run it belongs to) or as a whole package part, so saving a
/// document writes back what Libretto did not touch byte for byte.
public struct WordDocument: Equatable, Sendable {
    public var body: [Block]
    public var pageSetup: PageSetup
    /// Style definitions, read once from `word/styles.xml`. Libretto applies
    /// styles but does not edit their definitions.
    public var styles: StyleSheet
    public var numbering: NumberingDefinitions
    /// The header and footer parts, by the relationship ID sections refer to
    /// them by, reduced to their text and drawn in the page margins.
    public var headerFooters: [String: HeaderFooterText] = [:]
    /// Whether even pages have headers and footers of their own, from the
    /// settings part, and whether they did when the file was read.
    public var evenAndOddHeaders = false
    public var originalEvenAndOddHeaders = false
    /// The comments, in the order the comments part lists them, and the IDs
    /// it had when read, to tell what was added and taken away.
    public var comments: [Comment] = []
    public var originalComments: [Comment] = []
    /// Whether changes are recorded as tracked changes, from the settings
    /// part's `w:trackRevisions`, and whether they were when the file was read.
    public var trackRevisions = false
    public var originalTrackRevisions = false
    /// Footnotes and endnotes, from their parts, separators left out; and as read.
    public var notes: [Note] = [] {
        didSet { noteIDs.update(for: notes) }
    }
    public var originalNotes: [Note] = []
    /// The highest note IDs in use, kept as notes are added rather than found afresh each time.
    private var noteIDs = NoteIDs()
    /// How footnotes and endnotes are numbered, from the settings' `w:footnotePr` and `w:endnotePr`.
    public var footnoteFormat = "decimal"
    public var endnoteFormat = "lowerRoman"
    /// Body-level elements after the last block, before the section properties.
    public var trailingXML: [String] = []
    /// The original package, part by part, for writing back what is not modelled.
    public var package: DocumentPackage
    public var unsupportedFeatures: UnsupportedFeatureReport
    /// The language of the file opened in the code editor, including plain
    /// text without syntax colouring. `nil` for word-processing documents.
    public var sourceLanguage: SourceLanguage?
    /// The encoding a text file is in, and how it ends its lines, as read,
    /// so it saves back as it came. Changing them changes how it is saved.
    public var textEncoding = TextEncoding.utf8
    public var lineEnding = LineEnding.lf
    /// The format the document was converted from, which Libretto reads but
    /// cannot save. `nil` for a document that saves back to its own file.
    public var importedFormat: ImportedFormat?
    /// The Pages document it was read from, kept to save edits back into it.
    public var pagesSource: PagesSource?

    /// Whether the file carries a VBA project. Libretto keeps it but never runs it.
    public var hasMacros: Bool { package.parts.keys.contains { $0.lowercased().hasSuffix("vbaproject.bin") } }

    public init(
        body: [Block], pageSetup: PageSetup, styles: StyleSheet, numbering: NumberingDefinitions,
        headerFooters: [String: HeaderFooterText] = [:],
        package: DocumentPackage, unsupportedFeatures: UnsupportedFeatureReport = UnsupportedFeatureReport()
    ) {
        self.body = body
        self.pageSetup = pageSetup
        self.styles = styles
        self.numbering = numbering
        self.headerFooters = headerFooters
        self.package = package
        self.unsupportedFeatures = unsupportedFeatures
    }

    /// A new, empty document on the default page.
    public init() {
        // The template is ours and always readable.
        // swiftlint:disable:next force_try
        self = try! DOCXReader.document(fromParts: DOCXTemplate.blankPackage())
    }

    /// Every paragraph in reading order, descending into table cells.
    public var allParagraphs: [Paragraph] {
        body.flatMap(\.paragraphs)
    }

    /// Whether the document is laid out on its pages rather than flowing: no
    /// text of its own, only objects fixed to its pages, as a Pages page
    /// layout document is.
    public var isLaidOutOnPages: Bool {
        var placed = false
        for block in body {
            guard case .paragraph(let paragraph) = block else { continue }
            for inline in paragraph.inlines {
                switch inline.content {
                case .image(let image) where image.page != nil: placed = true
                case .pageBreak: continue
                default: return false
                }
            }
        }
        return placed
    }

    /// The document's words, for the word count.
    public var wordCount: Int {
        allParagraphs.reduce(0) { total, paragraph in
            #if canImport(Darwin)
            var count = 0
            paragraph.plainText.enumerateSubstrings(
                in: paragraph.plainText.startIndex..., options: [.byWords, .substringNotRequired]
            ) { _, _, _, _ in count += 1 }
            return total + count
            #else
            return total + Self.wordCount(paragraph.plainText)
            #endif
        }
    }

    #if !canImport(Darwin)
    /// Words counted without the system's word breaking, which Foundation
    /// has only on Apple platforms: runs of letters and digits, with each
    /// character of a script written without spaces, Chinese or Japanese
    /// say, a word of its own.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value) {
                count += 1
                inWord = false
            } else if properties.isAlphabetic || properties.numericType != nil || scalar == "'" && inWord {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }
    #endif

    /// The default header and footer of the last section.
    public var header: HeaderFooterText? { headerFooter(.default, isFooter: false, in: pageSetup) }
    public var footer: HeaderFooterText? { headerFooter(.default, isFooter: true, in: pageSetup) }

    public func headerFooter(_ kind: HeaderFooterKind, isFooter: Bool, in setup: PageSetup) -> HeaderFooterText? {
        let references = isFooter ? setup.headerFooters.footers : setup.headerFooters.headers
        return references[kind].flatMap { headerFooters[$0] }
    }

    /// Which header or footer a page shows: the first page's, if the section
    /// has one of its own, an even page's, if the document does, or the default.
    public func headerFooterKind(forPage index: Int, in setup: PageSetup) -> HeaderFooterKind {
        if index == 0, setup.headerFooters.titlePage { return .first }
        if evenAndOddHeaders, index % 2 == 1 { return .even }
        return .default
    }

    /// A relationship ID for a new header or footer part.
    public func unusedHeaderFooterID(isFooter: Bool) -> String {
        let stem = isFooter ? "rIdLibrettoFooter" : "rIdLibrettoHeader"
        var index = 1
        while headerFooters["\(stem)\(index)"] != nil || package.relationships["\(stem)\(index)"] != nil { index += 1 }
        return "\(stem)\(index)"
    }

    public func block(withID id: Block.ID) -> Block? {
        body.first { $0.id == id }
    }

    public mutating func replaceBlock(_ block: Block) {
        guard let index = body.firstIndex(where: { $0.id == block.id }) else { return }
        body[index] = block
    }
}

/// A format Libretto converts documents from, but does not write.
public enum ImportedFormat: Sendable {
    case pages
}

// MARK: - Blocks

/// One body-level element: a paragraph, a table, or something Libretto keeps
/// but does not edit, such as a content control holding a table of contents.
public enum Block: Equatable, Sendable, Identifiable {
    case paragraph(Paragraph)
    case table(Table)
    case preserved(PreservedBlock)

    public var id: UUID {
        switch self {
        case .paragraph(let paragraph): return paragraph.id
        case .table(let table): return table.id
        case .preserved(let block): return block.id
        }
    }

    public var paragraphs: [Paragraph] {
        switch self {
        case .paragraph(let paragraph): return [paragraph]
        case .table(let table): return table.rows.flatMap { $0.cells.flatMap { $0.blocks.flatMap(\.paragraphs) } }
        case .preserved: return []
        }
    }

    public var leadingXML: [String] {
        switch self {
        case .paragraph(let paragraph): return paragraph.leadingXML
        case .table(let table): return table.leadingXML
        case .preserved(let block): return block.leadingXML
        }
    }
}

/// A body-level element kept exactly as it was read.
public struct PreservedBlock: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var xml: String
    /// What it reads as, shown in place of the element itself.
    public var displayText: String
    public var kind: Kind
    public var leadingXML: [String] = []
    /// What it holds, read as paragraphs and tables, only to be drawn as
    /// they look: `xml` is what is written back, untouched.
    public var content: [Block] = []

    public enum Kind: String, Sendable {
        case contentControl
        case other
    }

    public init(
        id: UUID = UUID(), xml: String, displayText: String, kind: Kind, leadingXML: [String] = [],
        content: [Block] = []
    ) {
        self.id = id
        self.xml = xml
        self.displayText = displayText
        self.kind = kind
        self.leadingXML = leadingXML
        self.content = content
    }

    /// The same block: what it holds is read from `xml`, so is not compared.
    public static func == (lhs: PreservedBlock, rhs: PreservedBlock) -> Bool {
        lhs.id == rhs.id && lhs.xml == rhs.xml && lhs.displayText == rhs.displayText && lhs.kind == rhs.kind
            && lhs.leadingXML == rhs.leadingXML
    }
}

// MARK: - Paragraphs

public struct Paragraph: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var inlines: [Inline] = []
    public var properties = ParagraphProperties()
    /// The properties as read, so an untouched paragraph's `w:pPr` is written
    /// back verbatim and a touched one only has the changed parts patched.
    public var originalProperties: ParagraphProperties?
    public var preservedPropertiesXML: String?
    /// Body-level elements such as bookmarks that came just before this paragraph.
    public var leadingXML: [String] = []
    /// The `w:p` element's own attributes as the file spelled them, such as
    /// the paragraph IDs comments are anchored by.
    public var attributesXML = ""
    /// The paragraph exactly as read, with the content it was read as. While
    /// the content still matches, the paragraph is written back verbatim.
    public var originalXML: String?
    public var originalInlines: [Inline]?
    /// A tracked insertion or deletion of the paragraph's mark, from its
    /// `w:pPr/w:rPr`, and what it was when read.
    public var markRevision: Revision?
    public var originalMarkRevision: Revision?
    /// The section this paragraph ends, from the `w:sectPr` in its properties.
    public var section: PageSetup?

    public init(
        id: UUID = UUID(), inlines: [Inline] = [], properties: ParagraphProperties = ParagraphProperties(),
        originalProperties: ParagraphProperties? = nil, preservedPropertiesXML: String? = nil,
        leadingXML: [String] = []
    ) {
        self.id = id
        self.inlines = inlines
        self.properties = properties
        self.originalProperties = originalProperties
        self.preservedPropertiesXML = preservedPropertiesXML
        self.leadingXML = leadingXML
    }

    /// A plain paragraph of text.
    public init(text: String, styleID: String? = nil) {
        self.init(
            inlines: text.isEmpty ? [] : [Inline(.text(text))],
            properties: ParagraphProperties(styleID: styleID)
        )
    }

    public var plainText: String {
        inlines.map(\.plainText).joined()
    }

    /// The paragraph that results from splitting this one: the same
    /// properties, but none of what belongs to the paragraph mark alone, such
    /// as a section break, which must stay with exactly one of the halves.
    public func splitCopy() -> Paragraph {
        var copy = self
        copy.id = UUID()
        copy.leadingXML = []
        copy.originalXML = nil
        copy.originalInlines = nil
        copy.originalMarkRevision = nil
        copy.section = nil
        // Paragraph IDs must be unique; Word assigns the copy fresh ones.
        copy.attributesXML = DOCXPatcher.removingParagraphIDs(fromAttributes: attributesXML)
        copy.preservedPropertiesXML = preservedPropertiesXML.flatMap { DOCXPatcher.removingSectionBreak(fromPPr: $0) }
        return copy
    }
}

public struct ParagraphProperties: Equatable, Hashable, Sendable {
    public var styleID: String?
    public var alignment: ParagraphAlignment?
    public var list: ListReference?
    /// Twentieths of a point, as OOXML measures them.
    public var spacingBefore: Int?
    public var spacingAfter: Int?
    public var lineSpacing: LineSpacing?
    public var indentLeft: Int?
    public var indentRight: Int?
    /// Positive for a first-line indent, negative for a hanging one.
    public var indentFirstLine: Int?
    public var pageBreakBefore: Bool?
    public var outlineLevel: Int?
    public var keepNext: Bool?
    public var keepLines: Bool?
    public var widowControl: Bool?
    /// Six-digit RGB behind the paragraph.
    public var shadingHex: String?
    public var borders: ParagraphBorders?
    /// Tab stops, in twips from the margin; a style's are added to, or cleared by, a paragraph's own.
    public var tabStops: [TabStop]?
    /// A large initial letter, from `w:framePr`'s drop cap: dropped into the text or set in the margin.
    public var dropCap: DropCap?

    /// Overlays `other`'s set values onto these, as a style inherits.
    public func merged(with other: ParagraphProperties) -> ParagraphProperties {
        var result = ParagraphProperties(
            styleID: other.styleID ?? styleID,
            alignment: other.alignment ?? alignment,
            list: other.list ?? list,
            spacingBefore: other.spacingBefore ?? spacingBefore,
            spacingAfter: other.spacingAfter ?? spacingAfter,
            lineSpacing: other.lineSpacing ?? lineSpacing,
            indentLeft: other.indentLeft ?? indentLeft,
            indentRight: other.indentRight ?? indentRight,
            indentFirstLine: other.indentFirstLine ?? indentFirstLine,
            pageBreakBefore: other.pageBreakBefore ?? pageBreakBefore,
            outlineLevel: other.outlineLevel ?? outlineLevel,
            keepNext: other.keepNext ?? keepNext,
            keepLines: other.keepLines ?? keepLines,
            widowControl: other.widowControl ?? widowControl,
            shadingHex: other.shadingHex ?? shadingHex,
            borders: other.borders ?? borders,
            tabStops: tabStops,
            dropCap: other.dropCap ?? dropCap
        )
        if let added = other.tabStops {
            var stops = tabStops ?? []
            for stop in added {
                stops.removeAll { $0.position == stop.position }
                if stop.alignment != .clear { stops.append(stop) }
            }
            result.tabStops = stops.sorted { $0.position < $1.position }
        }
        return result
    }

    public init(
        styleID: String? = nil,
        alignment: ParagraphAlignment? = nil,
        list: ListReference? = nil,
        spacingBefore: Int? = nil,
        spacingAfter: Int? = nil,
        lineSpacing: LineSpacing? = nil,
        indentLeft: Int? = nil,
        indentRight: Int? = nil,
        indentFirstLine: Int? = nil,
        pageBreakBefore: Bool? = nil,
        outlineLevel: Int? = nil,
        keepNext: Bool? = nil,
        keepLines: Bool? = nil,
        widowControl: Bool? = nil,
        shadingHex: String? = nil,
        borders: ParagraphBorders? = nil,
        tabStops: [TabStop]? = nil,
        dropCap: DropCap? = nil
    ) {
        self.styleID = styleID
        self.alignment = alignment
        self.list = list
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.lineSpacing = lineSpacing
        self.indentLeft = indentLeft
        self.indentRight = indentRight
        self.indentFirstLine = indentFirstLine
        self.pageBreakBefore = pageBreakBefore
        self.outlineLevel = outlineLevel
        self.keepNext = keepNext
        self.keepLines = keepLines
        self.widowControl = widowControl
        self.shadingHex = shadingHex
        self.borders = borders
        self.tabStops = tabStops
        self.dropCap = dropCap
    }
}

/// A paragraph's borders, side by side, and the one between it and a like paragraph.
public struct ParagraphBorders: Equatable, Hashable, Sendable {
    public var top: BorderLine?
    public var left: BorderLine?
    public var bottom: BorderLine?
    public var right: BorderLine?
    public var between: BorderLine?

    public var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil && between == nil }

    public init(
        top: BorderLine? = nil,
        left: BorderLine? = nil,
        bottom: BorderLine? = nil,
        right: BorderLine? = nil,
        between: BorderLine? = nil
    ) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
        self.between = between
    }
}

/// One border line, as `w:top` and its siblings spell it.
public struct BorderLine: Equatable, Hashable, Sendable {
    /// `w:val`: `single`, `double`, `dotted`, `dashed`, `thick` and the rest.
    public var style = "single"
    /// Eighths of a point.
    public var size = 4
    /// Six-digit RGB, or `nil` for automatic.
    public var colorHex: String?
    /// Points between the line and the text.
    public var space = 1

    public init(style: String = "single", size: Int = 4, colorHex: String? = nil, space: Int = 1) {
        self.style = style
        self.size = size
        self.colorHex = colorHex
        self.space = space
    }
}

public struct TabStop: Equatable, Hashable, Sendable {
    public enum Alignment: String, CaseIterable, Sendable {
        case left, center, right, decimal, bar, clear

        /// Reads `w:tab`'s `w:val`, which also spells left and right as start and end.
        public init?(ooxml value: String) {
            switch value {
            case "left", "start", "num": self = .left
            case "right", "end": self = .right
            default: self.init(rawValue: value)
            }
        }
    }

    /// Twips from the margin.
    public var position: Int
    public var alignment: Alignment = .left
    /// `w:leader`: `dot`, `hyphen`, `underscore`, `middleDot`, or `nil` for none.
    public var leader: String?

    public init(position: Int, alignment: Alignment = .left, leader: String? = nil) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }
}

public struct DropCap: Equatable, Hashable, Sendable {
    /// `drop` sets the letter in the text; `margin`, beside it.
    public var inMargin = false
    /// How many lines tall the letter is.
    public var lines = 3

    public init(inMargin: Bool = false, lines: Int = 3) {
        self.inMargin = inMargin
        self.lines = lines
    }
}

public enum ParagraphAlignment: String, CaseIterable, Sendable {
    case leading = "left"
    case center
    case trailing = "right"
    case justified = "both"

    /// Reads `w:jc`, which also spells the leading and trailing edges as start and end.
    public init?(ooxml value: String) {
        switch value {
        case "left", "start": self = .leading
        case "center": self = .center
        case "right", "end": self = .trailing
        case "both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute":
            self = .justified
        default: return nil
        }
    }

    public var symbolName: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        case .justified: return "text.justify"
        }
    }

    public var label: String {
        switch self {
        case .leading: return String(localized: "Alignment.Left", bundle: .engine)
        case .center: return String(localized: "Alignment.Center", bundle: .engine)
        case .trailing: return String(localized: "Alignment.Right", bundle: .engine)
        case .justified: return String(localized: "Alignment.Justified", bundle: .engine)
        }
    }
}

public struct LineSpacing: Equatable, Hashable, Sendable {
    public enum Rule: String, Sendable {
        /// `line` is in 240ths of a line.
        case auto
        /// `line` is in twentieths of a point.
        case exact
        case atLeast
    }

    public var line: Int
    public var rule: Rule

    /// The multiple of single spacing, for automatic spacing.
    public var multiple: Double? { rule == .auto ? Double(line) / 240 : nil }

    public init(line: Int, rule: Rule) {
        self.line = line
        self.rule = rule
    }
}

public struct ListReference: Equatable, Hashable, Sendable {
    /// `w:numId`; zero means "no list", which a paragraph uses to opt out of
    /// a list its style would otherwise put it in.
    public var numberingID: Int
    public var level: Int

    public init(numberingID: Int, level: Int) {
        self.numberingID = numberingID
        self.level = level
    }
}

// MARK: - Inlines

/// One piece of a paragraph's content, with the run formatting it carries.
public struct Inline: Equatable, Sendable {
    public var content: InlineContent
    public var format = RunFormat()
    public var hyperlink: Hyperlink?
    /// The tracked change it is part of, if any.
    public var revision: Revision?
    /// For a kept element shown as its text, the runs that text is made of,
    /// each in its own formatting, when they differ: a smart tag around words
    /// partly in bold, say. Only how it is drawn; the element is written back
    /// as it was. `nil` when it all looks like `format`.
    public var displayRuns: [DisplayRun]?

    public init(
        _ content: InlineContent, format: RunFormat = RunFormat(), hyperlink: Hyperlink? = nil,
        revision: Revision? = nil, displayRuns: [DisplayRun]? = nil
    ) {
        self.content = content
        self.format = format
        self.hyperlink = hyperlink
        self.revision = revision
        self.displayRuns = displayRuns
    }

    /// The pieces its display is drawn as: `displayRuns` when they make up
    /// exactly `display`, otherwise all of it in `format`.
    public func displayPieces(_ display: String) -> [DisplayRun] {
        if let displayRuns, displayRuns.map(\.text).joined() == display { return displayRuns }
        return [DisplayRun(text: display, format: format)]
    }

    public var plainText: String {
        switch content {
        case .text(let text): return text
        case .tab: return "\t"
        case .lineBreak: return "\n"
        case .pageBreak, .columnBreak: return ""
        case .image, .note: return ""
        case .runChild(_, let display), .paragraphChild(_, let display): return display ?? ""
        }
    }
}

/// Part of a kept element's text and the formatting of the run it is in.
public struct DisplayRun: Equatable, Sendable {
    public var text: String
    public var format: RunFormat

    public init(text: String, format: RunFormat) {
        self.text = text
        self.format = format
    }
}

public enum InlineContent: Equatable, Sendable {
    case text(String)
    case tab
    case lineBreak
    case pageBreak
    /// `w:br w:type="column"`, which ends a column, and in a single column, the page.
    case columnBreak
    case image(InlineImage)
    /// A child of `w:r` Libretto keeps as it is: a field character, a
    /// footnote reference. `display` is what it reads as, if anything; `nil`
    /// means it takes no room in the text at all.
    case runChild(xml: String, display: String?)
    /// A child of `w:p` that is not a run: a bookmark, a tracked change, an
    /// equation. Written back outside any run.
    case paragraphChild(xml: String, display: String?)
    /// A footnote or endnote's reference, shown as the note's number.
    case note(NoteReference)

    /// Whether this takes no room in the text, so it rides along on the
    /// character after it rather than standing in the text itself.
    public var isMarker: Bool {
        switch self {
        case .runChild(_, let display), .paragraphChild(_, let display):
            return display?.isEmpty ?? true
        default:
            return false
        }
    }
}

/// A picture in the flow of text.
public struct InlineImage: Equatable, Sendable {
    /// The relationship naming the image part.
    public var relationshipID: String
    /// Points.
    public var width: Double
    public var height: Double
    /// The `w:drawing` element, written back as it was. `nil` for a picture
    /// inserted in Libretto, whose drawing is generated.
    public var xml: String?
    /// Floating pictures are shown in line, which is the nearest a reflowing
    /// view can come to where they sit on the page.
    public var isFloating = false
    /// How text goes around it, if it floats.
    public var wrap: ImageWrap = .inline
    /// Where a floating picture sits: across, by alignment or an offset in points
    /// from the margin or the page; down, an offset in points from its paragraph or the page.
    public var alignment: ParagraphAlignment?
    public var horizontalOffset: Double = 0
    public var isHorizontalFromPage = false
    public var verticalOffset: Double = 0
    public var verticalAnchor: VerticalAnchor = .paragraph
    /// How far text keeps from a floating picture that it wraps around.
    public var wrapDistances = WrapDistances()
    /// Which sides of a picture wrapped square or tight text runs down.
    public var wrapSide: WrapSide = .both
    /// The page a floating picture is fixed to, counted from 0, whichever
    /// paragraph holds it: where Pages keeps an object that stays on its page.
    public var page: Int?
    /// The outline text keeps to when it wraps tight or through; `nil` for the picture's frame.
    public var wrapPolygon: WrapPolygon?

    /// What a floating picture's place down the page is measured from.
    public enum VerticalAnchor: String, Sendable {
        case paragraph, margin, page
    }
    /// What is cut off each edge, as a fraction of the picture: left, top, right, bottom.
    public var crop = ImageCrop()
    /// Changed in Libretto, so its drawing is written afresh around the picture it holds.
    public var isEdited = false
    /// What the drawing is, when it is not a picture from an image part: a
    /// shape or text box, a chart, or a SmartArt diagram, drawn from its description.
    public var object: DrawingObject?
    /// The picture the document keeps of an object Libretto cannot draw as Word
    /// does (an `mc:Fallback` picture, or an embedded object's cached preview),
    /// drawn in its place. It is written back as the object it stands in for,
    /// so it is not resized or cropped.
    public var isStandIn = false

    public init(
        relationshipID: String,
        width: Double,
        height: Double,
        xml: String? = nil,
        isFloating: Bool = false,
        wrap: ImageWrap = .inline,
        alignment: ParagraphAlignment? = nil,
        horizontalOffset: Double = 0,
        isHorizontalFromPage: Bool = false,
        verticalOffset: Double = 0,
        verticalAnchor: VerticalAnchor = .paragraph,
        wrapDistances: WrapDistances = WrapDistances(),
        wrapPolygon: WrapPolygon? = nil,
        crop: ImageCrop = ImageCrop(),
        isEdited: Bool = false,
        object: DrawingObject? = nil,
        page: Int? = nil
    ) {
        self.relationshipID = relationshipID
        self.width = width
        self.height = height
        self.xml = xml
        self.isFloating = isFloating
        self.wrap = wrap
        self.alignment = alignment
        self.horizontalOffset = horizontalOffset
        self.isHorizontalFromPage = isHorizontalFromPage
        self.verticalOffset = verticalOffset
        self.verticalAnchor = verticalAnchor
        self.wrapDistances = wrapDistances
        self.wrapPolygon = wrapPolygon
        self.crop = crop
        self.isEdited = isEdited
        self.object = object
        self.page = page
    }
}

/// What Libretto draws of an object, and what it draws as Word does.
///
/// - Shapes and text boxes: the preset outlines in `ShapeSpec.drawnGeometries`,
///   solid fills and lines, linear and circular gradient fills, Word's line,
///   grid, check and shade patterns (`ShapePattern.isForeground`), and text in
///   its paragraphs' formatting, across, or up or down, turned and flipped
///   with the shape. Text runs from one linked text box on into the next.
///   Gradients out to a rectangle or the shape's own path (drawn as circular
///   ones), other patterns (drawn as their two colours mixed), picture fills,
///   shadows, glows and other effects, 3-D, dashed lines and arrowheads,
///   stacked text and free-form outlines are drawn more simply.
/// - Charts: column, bar, line, area, pie, doughnut, scatter and radar charts,
///   and column, line and area charts combined, from their cached values, with
///   their title, categories, solid series and slice colours, stacking and a
///   legend at a side. 3-D, data labels, gradient fills, trend lines, error bars,
///   secondary axes, legends in a corner or over the plot, and bubble, stock and
///   bar-of-pie charts (drawn as scatter, line and pie charts) are drawn more simply.
/// - Groups: their shapes, groups within them too, as shapes are drawn, each
///   where the group sets it. A group turned or flipped as a whole is drawn
///   unturned, and pictures, charts and ink in a group are left out.
/// - SmartArt: the shapes Word last laid the diagram out as, as shapes are drawn.
///
/// Where the document keeps a picture of such an object, that picture is
/// drawn instead (`InlineImage.isStandIn`). Otherwise the open notice says
/// that objects are drawn more simply (`UnsupportedFeatureReport.Feature.simplifiedObjects`).
public enum DrawingObject: Equatable, Hashable, Sendable {
    case shape(ShapeSpec)
    case chart(ChartSpec)
    /// A diagram's shapes, each placed in the diagram's own frame, in points.
    case diagram([ShapeSpec])
    /// A group's shapes (`wpg:wgp`), each placed in the group's frame.
    case group(ShapeGroup)
}

/// The shapes of a group, each with its `frame` in points from the group's
/// top left corner, as large as they are in a group `width` by `height`.
public struct ShapeGroup: Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var shapes: [ShapeSpec]

    public init(width: Double, height: Double, shapes: [ShapeSpec]) {
        self.width = width
        self.height = height
        self.shapes = shapes
    }
}

/// A DrawingML shape: its outline's form, fill and line, and its text.
public struct ShapeSpec: Equatable, Hashable, Sendable {
    /// `a:prstGeom`'s `prst`: `rect`, `roundRect`, `ellipse`, `triangle`, `rightArrow` and the rest.
    public var geometry = "rect"
    /// The preset outlines drawn as Word draws them; any other is drawn as a rectangle.
    public static let drawnGeometries: Set<String> = [
        "rect", "roundRect", "flowChartAlternateProcess", "wedgeRoundRectCallout", "ellipse", "flowChartConnector",
        "donut", "cloud", "wedgeEllipseCallout", "triangle", "flowChartExtract", "rtTriangle", "diamond",
        "flowChartDecision", "parallelogram", "flowChartInputOutput", "trapezoid", "pentagon", "homePlate", "hexagon",
        "octagon", "chevron", "rightArrow", "leftArrow", "upArrow", "downArrow", "plus", "mathPlus", "star5", "line",
        "straightConnector1", "bentConnector3", "curvedConnector3", "flowChartProcess",
    ]
    /// Six-digit RGB, or `nil` for none.
    public var fillHex: String? = "4472C4"
    public var lineHex: String? = "2F528F"
    /// Points.
    public var lineWidth: Double = 1
    public var text = ""
    public var textColorHex: String?
    /// Points; `nil` for the document's body size.
    public var fontSize: Double?
    public var isTextBox = false
    /// Where it sits within a diagram or group, in points; `nil` for a shape of its own.
    public var frame: ShapeFrame?
    /// The text as read, to tell whether it has been edited.
    public var originalText: String?
    /// The text's paragraphs in their own formatting, as read, drawn while
    /// the text is as it was.
    public var paragraphs: [ShapeParagraph]?
    /// An outline of its own, drawn in place of the preset geometry's.
    public var outline: ShapeOutline?
    /// Where the text sits up and down: `wps:bodyPr`'s `anchor`. `nil` for
    /// Libretto's own: a text box's from the top, a shape's in its middle.
    public var textAnchor: TextAnchor?
    /// How far the text keeps in from each edge, in points: `wps:bodyPr`'s
    /// `lIns`, `tIns`, `rIns` and `bIns`. `nil` for Libretto's own.
    public var textInsets: ShapeInsets?
    /// The boxes the text runs through, when it is a text box linked to
    /// others: its `text` is all of theirs, and it shows its part of it.
    public var linkedText: LinkedText?
    /// Degrees clockwise it is turned about its middle, its text with it: `a:xfrm`'s `rot`.
    public var rotation: Double = 0
    /// Mirrored left to right, or top to bottom, before it is turned: `a:xfrm`'s `flipH`
    /// and `flipV`. Its text is not mirrored, but flipped top to bottom it is upside down.
    public var flipsHorizontally = false
    public var flipsVertically = false
    /// Which way its text runs: `wps:bodyPr`'s `vert`.
    public var textDirection: TextDirection = .horizontal
    /// A gradient it is filled with in place of `fillHex`, which holds its first colour.
    public var gradient: ShapeGradient?
    /// A pattern it is filled with in place of `fillHex`, which holds its background colour.
    public var pattern: ShapePattern?

    public enum TextDirection: String, Sendable {
        /// Across, as usual.
        case horizontal
        /// Top to bottom, turned a quarter clockwise: `vert` and `eaVert`.
        case down
        /// Bottom to top, turned a quarter the other way: `vert270`.
        case up
    }

    public enum TextAnchor: String, Sendable {
        case top = "t", middle = "ctr", bottom = "b"
    }

    /// The formatted paragraphs, while they still say what the text does.
    public var formattedParagraphs: [ShapeParagraph]? {
        guard let paragraphs, paragraphs.map(\.text).joined(separator: "\n") == text else { return nil }
        return paragraphs
    }

    public init(
        geometry: String = "rect",
        fillHex: String? = "4472C4",
        lineHex: String? = "2F528F",
        lineWidth: Double = 1,
        text: String = "",
        textColorHex: String? = nil,
        fontSize: Double? = nil,
        isTextBox: Bool = false,
        frame: ShapeFrame? = nil,
        originalText: String? = nil,
        paragraphs: [ShapeParagraph]? = nil,
        outline: ShapeOutline? = nil
    ) {
        self.geometry = geometry
        self.fillHex = fillHex
        self.lineHex = lineHex
        self.lineWidth = lineWidth
        self.text = text
        self.textColorHex = textColorHex
        self.fontSize = fontSize
        self.isTextBox = isTextBox
        self.frame = frame
        self.originalText = originalText
        self.paragraphs = paragraphs
        self.outline = outline
    }
}

/// A paragraph of a shape's text, in its own formatting.
public struct ShapeParagraph: Equatable, Hashable, Sendable {
    public var runs: [ShapeRun]
    public var alignment: ParagraphAlignment?
    /// Points.
    public var spaceBefore: Double
    public var spaceAfter: Double
    /// How many lines each line takes, if not one.
    public var lineHeightMultiple: Double?

    public var text: String { runs.map(\.text).joined() }

    public init(
        runs: [ShapeRun], alignment: ParagraphAlignment? = nil, spaceBefore: Double = 0, spaceAfter: Double = 0,
        lineHeightMultiple: Double? = nil
    ) {
        self.runs = runs
        self.alignment = alignment
        self.spaceBefore = spaceBefore
        self.spaceAfter = spaceAfter
        self.lineHeightMultiple = lineHeightMultiple
    }
}

public struct ShapeRun: Equatable, Hashable, Sendable {
    public var text: String
    public var style: RunStyle

    public init(text: String, style: RunStyle = RunStyle()) {
        self.text = text
        self.style = style
    }
}

/// A shape's outline as a path, drawn scaled from the size it was drawn at to the shape's.
public struct ShapeOutline: Equatable, Hashable, Sendable {
    public enum Element: Equatable, Hashable, Sendable {
        case move(ShapePoint)
        case line(ShapePoint)
        case quadCurve(ShapePoint, control: ShapePoint)
        case curve(ShapePoint, control1: ShapePoint, control2: ShapePoint)
        case close
    }

    public var width: Double
    public var height: Double
    public var elements: [Element]

    public init(width: Double, height: Double, elements: [Element]) {
        self.width = width
        self.height = height
        self.elements = elements
    }
}

/// A gradient fill: `a:gradFill`.
public struct ShapeGradient: Equatable, Hashable, Sendable {
    public struct Stop: Equatable, Hashable, Sendable {
        /// From 0 to 1 along the gradient.
        public var position: Double
        public var colorHex: String
        /// From 0, clear, to 1, solid.
        public var alpha: Double

        public init(position: Double, colorHex: String, alpha: Double = 1) {
            self.position = position
            self.colorHex = colorHex
            self.alpha = alpha
        }
    }

    public enum Kind: Equatable, Hashable, Sendable {
        /// Along a line at `angle` degrees clockwise from across (`a:lin`); `scaled`, at
        /// that angle in a square then stretched to the shape, as its `scaled` says.
        case linear(angle: Double, scaled: Bool)
        /// Out from `focus` (`a:path`'s `a:fillToRect`, as fractions in from the left, top,
        /// right and bottom) to the shape's corners; `isCircle` for `path="circle"`, else a
        /// rectangle's or the shape's own path, drawn as a circle's.
        case path(focus: ShapeInsets, isCircle: Bool)
    }

    public var stops: [Stop]
    public var kind: Kind
    /// Whether it turns with the shape: `rotWithShape`.
    public var turnsWithShape: Bool

    public init(stops: [Stop], kind: Kind, turnsWithShape: Bool = true) {
        self.stops = stops
        self.kind = kind
        self.turnsWithShape = turnsWithShape
    }
}

/// A pattern fill: `a:pattFill`, one of Word's preset 8 by 8 tiles in two colours.
public struct ShapePattern: Equatable, Hashable, Sendable {
    /// `prst`: `pct50`, `horz`, `wdDnDiag` and the rest.
    public var preset: String
    public var foregroundHex: String
    public var backgroundHex: String

    public init(preset: String, foregroundHex: String, backgroundHex: String) {
        self.preset = preset
        self.foregroundHex = foregroundHex
        self.backgroundHex = backgroundHex
    }

    /// Whether a tile pixel, `x` across and `y` down from 0 to 7, is in the foreground colour;
    /// `nil` for a preset not drawn as Word draws it.
    public static func isForeground(_ preset: String, x: Int, y: Int) -> Bool? {
        func lines(_ position: Int, period: Int, width: Int) -> Bool { position % period < width }
        switch preset {
        case "horz": return lines(y, period: 8, width: 1)
        case "vert": return lines(x, period: 8, width: 1)
        case "ltHorz": return lines(y, period: 4, width: 1)
        case "ltVert": return lines(x, period: 4, width: 1)
        case "narHorz": return lines(y, period: 2, width: 1)
        case "narVert": return lines(x, period: 2, width: 1)
        case "dkHorz": return lines(y, period: 4, width: 2)
        case "dkVert": return lines(x, period: 4, width: 2)
        // Down to the right, and up to the right.
        case "dnDiag": return lines(x - y + 8, period: 8, width: 1)
        case "upDiag": return lines(x + y, period: 8, width: 1)
        case "ltDnDiag": return lines(x - y + 8, period: 4, width: 1)
        case "ltUpDiag": return lines(x + y, period: 4, width: 1)
        case "dkDnDiag": return lines(x - y + 8, period: 4, width: 2)
        case "dkUpDiag": return lines(x + y, period: 4, width: 2)
        case "wdDnDiag": return lines(x - y + 8, period: 8, width: 3)
        case "wdUpDiag": return lines(x + y, period: 8, width: 3)
        case "cross", "lgGrid": return lines(x, period: 8, width: 1) || lines(y, period: 8, width: 1)
        case "smGrid": return lines(x, period: 4, width: 1) || lines(y, period: 4, width: 1)
        case "diagCross": return lines(x - y + 8, period: 8, width: 1) || lines(x + y, period: 8, width: 1)
        case "smCheck": return (x / 2 + y / 2) % 2 == 0
        case "lgCheck": return (x / 4 + y / 4) % 2 == 0
        default:
            // So much in a hundred, spread as evenly as an ordered dither spreads it.
            guard preset.hasPrefix("pct"), let percent = Int(preset.dropFirst(3)) else { return nil }
            let order = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38,
                         60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
                         15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]
            return order[(y % 8) * 8 + x % 8] < (percent * 64 + 50) / 100
        }
    }
}

/// Text that runs from one text box on into the next (`wps:txbx` and the
/// `wps:linkedTxbx` boxes after it): how large each box's text area is, in
/// points, in the order the text runs through them, and which this box is.
public struct LinkedText: Equatable, Hashable, Sendable {
    public var areas: [ShapeFrame]
    public var index: Int

    public init(areas: [ShapeFrame], index: Int) {
        self.areas = areas
        self.index = index
    }
}

public struct ShapeInsets: Equatable, Hashable, Sendable {
    public var left, top, right, bottom: Double

    /// Word's own: a tenth of an inch either side, a twentieth above and below.
    public static let word = ShapeInsets(left: 7.2, top: 3.6, right: 7.2, bottom: 3.6)

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

public struct ShapePoint: Equatable, Hashable, Sendable {
    public var x, y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ShapeFrame: Equatable, Hashable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A chart, from the values its chart part caches.
public struct ChartSpec: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case column, bar, line, area, pie, doughnut, scatter, radar
    }

    public struct Series: Equatable, Hashable, Sendable {
        public var name: String
        public var values: [Double]
        public var colorHex: String?
        /// In a combined chart, how this series is drawn when it differs from the
        /// chart's own kind: a line or area over columns, say.
        public var kind: Kind?
        /// Colours given to points one by one, by index: a pie's slices.
        public var pointColorsHex: [Int: String] = [:]

        public init(name: String, values: [Double], colorHex: String? = nil, kind: Kind? = nil, pointColorsHex: [Int: String] = [:]) {
            self.name = name
            self.values = values
            self.colorHex = colorHex
            self.kind = kind
            self.pointColorsHex = pointColorsHex
        }
    }

    /// Where the legend sits: `c:legendPos`'s values.
    public enum LegendPosition: String, Sendable {
        case bottom = "b", top = "t", left = "l", right = "r"
    }

    public var kind: Kind = .column
    public var title: String?
    public var categories: [String] = []
    public var series: [Series] = []
    public var isStacked = false
    /// `nil` for a chart without one.
    public var legend: LegendPosition? = .bottom

    public init(
        kind: Kind = .column,
        title: String? = nil,
        categories: [String] = [],
        series: [Series] = [],
        isStacked: Bool = false,
        legend: LegendPosition? = .bottom
    ) {
        self.kind = kind
        self.title = title
        self.categories = categories
        self.series = series
        self.isStacked = isStacked
        self.legend = legend
    }
}

public enum ImageWrap: String, CaseIterable, Sendable {
    case inline, square, tight, through, topAndBottom, behindText, inFrontOfText

    /// Whether text keeps clear of it beside it, or above and below it.
    public var excludesText: Bool { self == .square || followsOutline || self == .topAndBottom }

    /// Whether text keeps to the picture's wrap polygon rather than its frame:
    /// tight wrapping goes around its outline, through wrapping into its open parts too.
    public var followsOutline: Bool { self == .tight || self == .through }
}

/// Which sides of a floating picture text runs down: `wrapText`.
public enum WrapSide: String, Sendable {
    case both = "bothSides", left, right
    /// Only the side with more room.
    case largest
}

/// How far text keeps from each side of a floating picture, in points:
/// `wp:anchor`'s `distT`, `distB`, `distL` and `distR`. Word's own, for a
/// picture that doesn't say, are none above and below and 9 pt either side.
public struct WrapDistances: Equatable, Hashable, Sendable {
    public var top: Double = 0
    public var bottom: Double = 0
    public var left: Double = 9
    public var right: Double = 9

    public init(top: Double = 0, bottom: Double = 0, left: Double = 9, right: Double = 9) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

public struct ImageCrop: Equatable, Hashable, Sendable {
    public var left: Double = 0
    public var top: Double = 0
    public var right: Double = 0
    public var bottom: Double = 0

    public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// A tracked change: an insertion or deletion of text, or of a paragraph
/// mark, as `w:ins`, `w:del`, `w:moveTo` or `w:moveFrom` record it.
public struct Revision: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case insertion = "ins"
        case deletion = "del"
        case moveTo
        case moveFrom

        /// Whether accepting it keeps the text, as for an insertion.
        public var adds: Bool { self == .insertion || self == .moveTo }
    }

    public var kind: Kind
    public var author: String?
    /// As the file spells it, ISO 8601.
    public var date: String?
    /// The element's attributes as the file spelled them, `w:id` among them;
    /// empty for a change made in Libretto, which is given an ID when written.
    public var attributesXML = ""

    public init(kind: Kind, author: String? = nil, date: String? = nil, attributesXML: String = "") {
        self.kind = kind
        self.author = author
        self.date = date
        self.attributesXML = attributesXML
    }
}

/// A hyperlink wrapping some of a paragraph's runs.
public struct Hyperlink: Equatable, Hashable, Sendable {
    public var relationshipID: String?
    public var anchor: String?
    /// The resolved address, for opening in the mobile view.
    public var url: URL?
    /// The element's attributes as the file spelled them.
    public var attributesXML: String

    public init(relationshipID: String? = nil, anchor: String? = nil, url: URL? = nil, attributesXML: String) {
        self.relationshipID = relationshipID
        self.anchor = anchor
        self.url = url
        self.attributesXML = attributesXML
    }
}

/// The formatting of a run: what Libretto edits, plus what it keeps.
public struct RunFormat: Equatable, Hashable, Sendable {
    public var style = RunStyle()
    public var original: RunStyle?
    public var preservedPropertiesXML: String?

    public init(style: RunStyle = RunStyle(), original: RunStyle? = nil, preservedPropertiesXML: String? = nil) {
        self.style = style
        self.original = original
        self.preservedPropertiesXML = preservedPropertiesXML
    }
}

/// Character formatting Libretto understands. `nil` means "inherit".
public struct RunStyle: Equatable, Hashable, Sendable {
    public var characterStyleID: String?
    public var fontName: String?
    /// Half-points, as `w:sz` measures them.
    public var fontSize: Int?
    public var isBold: Bool?
    public var isItalic: Bool?
    public var underline: Bool?
    public var isStruckThrough: Bool?
    /// Six-digit RGB.
    public var colorHex: String?
    /// A `w:highlight` colour name.
    public var highlight: String?
    public var verticalAlignment: VerticalPosition?
    public var allCaps: Bool?
    /// `w:u`'s kind, when it is not a single line: `double`, `thick`,
    /// `dotted`, `dash`, `wave`, `words` and the rest.
    public var underlineStyle: String?
    public var isDoubleStruckThrough: Bool?
    public var smallCaps: Bool?
    /// Twentieths of a point added between characters, or taken away.
    public var characterSpacing: Int?
    /// Half-points the text is raised, or lowered.
    public var position: Int?
    public var outline: Bool?
    public var shadow: Bool?
    public var emboss: Bool?
    /// Engraved, as Word calls it.
    public var imprint: Bool?

    public enum VerticalPosition: String, Sendable {
        case superscript
        case `subscript`
        case baseline
    }

    /// Word's `w:highlight` names, and the colours they are.
    public static let highlightColors: [String: String] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF", "blue": "0000FF",
        "red": "FF0000", "darkBlue": "000080", "darkCyan": "008080", "darkGreen": "008000",
        "darkMagenta": "800080", "darkRed": "800000", "darkYellow": "808000", "darkGray": "808080",
        "lightGray": "C0C0C0", "black": "000000", "white": "FFFFFF",
    ]

    public func merged(with other: RunStyle) -> RunStyle {
        RunStyle(
            characterStyleID: other.characterStyleID ?? characterStyleID,
            fontName: other.fontName ?? fontName,
            fontSize: other.fontSize ?? fontSize,
            isBold: other.isBold ?? isBold,
            isItalic: other.isItalic ?? isItalic,
            underline: other.underline ?? underline,
            isStruckThrough: other.isStruckThrough ?? isStruckThrough,
            colorHex: other.colorHex ?? colorHex,
            highlight: other.highlight ?? highlight,
            verticalAlignment: other.verticalAlignment ?? verticalAlignment,
            allCaps: other.allCaps ?? allCaps,
            underlineStyle: other.underline != nil ? other.underlineStyle : underlineStyle,
            isDoubleStruckThrough: other.isDoubleStruckThrough ?? isDoubleStruckThrough,
            smallCaps: other.smallCaps ?? smallCaps,
            characterSpacing: other.characterSpacing ?? characterSpacing,
            position: other.position ?? position,
            outline: other.outline ?? outline,
            shadow: other.shadow ?? shadow,
            emboss: other.emboss ?? emboss,
            imprint: other.imprint ?? imprint
        )
    }

    public init(
        characterStyleID: String? = nil,
        fontName: String? = nil,
        fontSize: Int? = nil,
        isBold: Bool? = nil,
        isItalic: Bool? = nil,
        underline: Bool? = nil,
        isStruckThrough: Bool? = nil,
        colorHex: String? = nil,
        highlight: String? = nil,
        verticalAlignment: VerticalPosition? = nil,
        allCaps: Bool? = nil,
        underlineStyle: String? = nil,
        isDoubleStruckThrough: Bool? = nil,
        smallCaps: Bool? = nil,
        characterSpacing: Int? = nil,
        position: Int? = nil,
        outline: Bool? = nil,
        shadow: Bool? = nil,
        emboss: Bool? = nil,
        imprint: Bool? = nil
    ) {
        self.characterStyleID = characterStyleID
        self.fontName = fontName
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
        self.underline = underline
        self.isStruckThrough = isStruckThrough
        self.colorHex = colorHex
        self.highlight = highlight
        self.verticalAlignment = verticalAlignment
        self.allCaps = allCaps
        self.underlineStyle = underlineStyle
        self.isDoubleStruckThrough = isDoubleStruckThrough
        self.smallCaps = smallCaps
        self.characterSpacing = characterSpacing
        self.position = position
        self.outline = outline
        self.shadow = shadow
        self.emboss = emboss
        self.imprint = imprint
    }
}

// MARK: - Tables

public struct Table: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var rows: [TableRow]
    /// Column widths in twips, from `w:tblGrid`.
    public var gridColumns: [Int]
    public var preservedPropertiesXML: String?
    public var styleID: String?
    /// Whether the table draws its own borders, rather than relying on
    /// gridlines that only show on screen.
    public var hasBorders: Bool
    /// Six-digit RGB, if the borders have a colour of their own.
    public var borderColorHex: String?
    public var look = TableLook()
    public var leadingXML: [String] = []
    /// The table exactly as read, written back verbatim while its rows and
    /// columns are as they were.
    public var originalXML: String?
    public var originalRows: [TableRow]?
    public var originalGrid: [Int]?
    public var originalPropertiesXML: String?

    public var isUnchanged: Bool {
        originalXML != nil && originalRows == rows && originalGrid == gridColumns
            && originalPropertiesXML == preservedPropertiesXML
    }

    public var columnCount: Int {
        max(gridColumns.count, rows.map { $0.cells.reduce(0) { $0 + $1.gridSpan } }.max() ?? 0)
    }

    public init(
        id: UUID = UUID(),
        rows: [TableRow],
        gridColumns: [Int],
        preservedPropertiesXML: String? = nil,
        styleID: String? = nil,
        hasBorders: Bool,
        borderColorHex: String? = nil,
        look: TableLook = TableLook(),
        leadingXML: [String] = [],
        originalXML: String? = nil,
        originalRows: [TableRow]? = nil,
        originalGrid: [Int]? = nil,
        originalPropertiesXML: String? = nil
    ) {
        self.id = id
        self.rows = rows
        self.gridColumns = gridColumns
        self.preservedPropertiesXML = preservedPropertiesXML
        self.styleID = styleID
        self.hasBorders = hasBorders
        self.borderColorHex = borderColorHex
        self.look = look
        self.leadingXML = leadingXML
        self.originalXML = originalXML
        self.originalRows = originalRows
        self.originalGrid = originalGrid
        self.originalPropertiesXML = originalPropertiesXML
    }
}

public struct TableRow: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var cells: [TableCell]
    /// `w:tblPrEx`: table properties this row overrides.
    public var exceptionsXML: String?
    public var preservedPropertiesXML: String?
    public var isHeader = false

    public init(
        id: UUID = UUID(),
        cells: [TableCell],
        exceptionsXML: String? = nil,
        preservedPropertiesXML: String? = nil,
        isHeader: Bool = false
    ) {
        self.id = id
        self.cells = cells
        self.exceptionsXML = exceptionsXML
        self.preservedPropertiesXML = preservedPropertiesXML
        self.isHeader = isHeader
    }
}

public struct TableCell: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var blocks: [Block]
    public var preservedPropertiesXML: String?
    public var gridSpan = 1
    public var verticalMerge: VerticalMerge?
    /// Six-digit RGB background.
    public var shadingHex: String?

    public enum VerticalMerge: Sendable {
        case restart
        case `continue`
    }

    public var plainText: String {
        blocks.flatMap(\.paragraphs).map(\.plainText).joined(separator: "\n")
    }

    public init(
        id: UUID = UUID(),
        blocks: [Block],
        preservedPropertiesXML: String? = nil,
        gridSpan: Int = 1,
        verticalMerge: VerticalMerge? = nil,
        shadingHex: String? = nil
    ) {
        self.id = id
        self.blocks = blocks
        self.preservedPropertiesXML = preservedPropertiesXML
        self.gridSpan = gridSpan
        self.verticalMerge = verticalMerge
        self.shadingHex = shadingHex
    }
}

// MARK: - Page setup

/// The page size and margins of the document's last section, which is the one
/// Libretto lays every page out with.
public struct PageSetup: Equatable, Sendable {
    /// Twips.
    public var width = 11906
    public var height = 16838
    public var marginTop = 1440
    public var marginBottom = 1440
    public var marginLeft = 1440
    public var marginRight = 1440
    public var headerDistance = 708
    public var footerDistance = 708
    /// Which header and footer parts the section shows, and whether its first page has its own.
    public var headerFooters = HeaderFooterReferences()
    public var originalHeaderFooters: HeaderFooterReferences?
    /// How the section starts: on a new page, the same page, or the next even or odd page.
    public var start: SectionStart = .nextPage
    /// Text columns, and the space between them, in twips.
    public var columns = 1
    public var columnSpacing = 708
    /// Each column's own width and the space after it, in twips, when the
    /// columns differ (`w:cols w:equalWidth="0"`); empty when they are alike.
    /// Kept in the section's XML, so not written back from here.
    public var columnSizes: [ColumnSize] = []
    /// `w:pgNumType`'s format for the page numbers its headers and footers
    /// show, such as `lowerRoman`; `nil` for 1, 2, 3.
    public var pageNumberFormat: String?
    public var preservedXML: String?
    public var original: PageSetupValues?

    public var isLandscape: Bool { width > height }

    public struct PageSetupValues: Equatable, Sendable {
        public var width, height, marginTop, marginBottom, marginLeft, marginRight: Int
        public var start: SectionStart = .nextPage
        public var columns = 1
        public var columnSpacing = 708
        public var pageNumberFormat: String?

        public init(
            width: Int, height: Int, marginTop: Int, marginBottom: Int, marginLeft: Int, marginRight: Int,
            start: SectionStart = .nextPage,
            columns: Int = 1,
            columnSpacing: Int = 708,
            pageNumberFormat: String? = nil
        ) {
            self.width = width
            self.height = height
            self.marginTop = marginTop
            self.marginBottom = marginBottom
            self.marginLeft = marginLeft
            self.marginRight = marginRight
            self.start = start
            self.columns = columns
            self.columnSpacing = columnSpacing
            self.pageNumberFormat = pageNumberFormat
        }
    }

    public var values: PageSetupValues {
        PageSetupValues(
            width: width, height: height, marginTop: marginTop, marginBottom: marginBottom,
            marginLeft: marginLeft, marginRight: marginRight, start: start, columns: columns, columnSpacing: columnSpacing,
            pageNumberFormat: pageNumberFormat
        )
    }

    /// Whether anything differs from the section as read.
    public var isChanged: Bool {
        preservedXML == nil || original != values || headerFooters != (originalHeaderFooters ?? HeaderFooterReferences())
    }

    /// One text column: its width and the space after it, in twips.
    public struct ColumnSize: Equatable, Sendable {
        public var width: Int
        public var space: Int

        public init(width: Int, space: Int) {
            self.width = width
            self.space = space
        }
    }

    /// Where each text column is across text `width` points wide, from its
    /// left edge, and how wide, in points: one column for a section in one.
    /// Columns that would not fit are narrowed in proportion.
    public func columnFrames(width: Double) -> [(x: Double, width: Double)] {
        let sizes: [(width: Double, space: Double)]
        if columnSizes.count > 1 {
            sizes = columnSizes.map { (Double(max(0, $0.width)) / 20, Double(max(0, $0.space)) / 20) }
        } else if columns > 1 {
            let space = Double(max(0, columnSpacing)) / 20
            let each = (width - space * Double(columns - 1)) / Double(columns)
            sizes = Array(repeating: (each, space), count: columns)
        } else {
            return [(0, width)]
        }
        // The space after the last column is not part of the text.
        let total = sizes.dropLast().reduce(0) { $0 + $1.width + $1.space } + (sizes.last?.width ?? 0)
        let scale = total > width && total > 0 ? width / total : 1
        guard sizes.allSatisfy({ $0.width * scale >= 1 }) else { return [(0, width)] }
        var x = 0.0
        return sizes.map { size in
            defer { x += (size.width + size.space) * scale }
            return (x, size.width * scale)
        }
    }

    /// Whether the section's text is set in more than one column.
    public var hasColumns: Bool { columns > 1 || columnSizes.count > 1 }

    /// Points, the unit the page view lays out in.
    public var size: CGSize { CGSize(width: Double(width) / 20, height: Double(height) / 20) }
    public var contentWidth: Double { Double(width - marginLeft - marginRight) / 20 }
    public var contentHeight: Double { Double(height - marginTop - marginBottom) / 20 }

    public init(
        width: Int = 11906,
        height: Int = 16838,
        marginTop: Int = 1440,
        marginBottom: Int = 1440,
        marginLeft: Int = 1440,
        marginRight: Int = 1440,
        headerDistance: Int = 708,
        footerDistance: Int = 708,
        headerFooters: HeaderFooterReferences = HeaderFooterReferences(),
        originalHeaderFooters: HeaderFooterReferences? = nil,
        start: SectionStart = .nextPage,
        columns: Int = 1,
        columnSpacing: Int = 708,
        pageNumberFormat: String? = nil,
        preservedXML: String? = nil,
        original: PageSetupValues? = nil
    ) {
        self.width = width
        self.height = height
        self.marginTop = marginTop
        self.marginBottom = marginBottom
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.headerDistance = headerDistance
        self.footerDistance = footerDistance
        self.headerFooters = headerFooters
        self.originalHeaderFooters = originalHeaderFooters
        self.start = start
        self.columns = columns
        self.columnSpacing = columnSpacing
        self.pageNumberFormat = pageNumberFormat
        self.preservedXML = preservedXML
        self.original = original
    }
}

/// `w:sectPr/w:type`: where a section starts.
public enum SectionStart: String, CaseIterable, Sendable {
    case nextPage
    case continuous
    case evenPage
    case oddPage
    case nextColumn
}

/// The header and footer parts a section shows on each kind of page, by relationship ID.
public struct HeaderFooterReferences: Equatable, Sendable {
    public var headers: [HeaderFooterKind: String] = [:]
    public var footers: [HeaderFooterKind: String] = [:]
    /// `w:titlePg`: the first page has a header and footer of its own.
    public var titlePage = false

    public init(
        headers: [HeaderFooterKind: String] = [:],
        footers: [HeaderFooterKind: String] = [:],
        titlePage: Bool = false
    ) {
        self.headers = headers
        self.footers = footers
        self.titlePage = titlePage
    }
}

/// `w:headerReference`'s and `w:footerReference`'s types.
public enum HeaderFooterKind: String, CaseIterable, Sendable {
    case `default`
    case first
    case even
}

/// A header or footer, reduced to the text it shows. `{PAGE}` stands for the
/// page number field, which is filled in per page.
public struct HeaderFooterText: Equatable, Sendable {
    public var text: String
    public var alignment: ParagraphAlignment = .leading
    public var isFooter = false
    /// The part's first paragraph's and first run's properties, kept when the
    /// text is written afresh, so it keeps its style and font.
    public var paragraphPropertiesXML: String?
    public var runPropertiesXML: String?
    /// Whether the part holds more than its text, such as a picture or a
    /// table, which writing the text afresh does not keep.
    public var hasRichContent = false
    /// Changed in Libretto, so its part is written afresh from the text.
    public var isEdited = false

    public static let pageNumberPlaceholder = "{PAGE}"
    public static let pageCountPlaceholder = "{NUMPAGES}"

    /// The text page `page` shows, its number in a list format such as `lowerRoman`.
    public func resolved(page: Int, of count: Int, format: String? = nil) -> String {
        text.replacingOccurrences(of: Self.pageNumberPlaceholder, with: ListCounter.format(page, as: format ?? "decimal"))
            .replacingOccurrences(of: Self.pageCountPlaceholder, with: String(count))
    }

    public init(
        text: String,
        alignment: ParagraphAlignment = .leading,
        isFooter: Bool = false,
        paragraphPropertiesXML: String? = nil,
        runPropertiesXML: String? = nil,
        hasRichContent: Bool = false,
        isEdited: Bool = false
    ) {
        self.text = text
        self.alignment = alignment
        self.isFooter = isFooter
        self.paragraphPropertiesXML = paragraphPropertiesXML
        self.runPropertiesXML = runPropertiesXML
        self.hasRichContent = hasRichContent
        self.isEdited = isEdited
    }
}

// MARK: - Notes

public enum NoteKind: String, CaseIterable, Sendable {
    case footnote
    case endnote
}

/// Where a note is referred to: `w:footnoteReference` or `w:endnoteReference`.
public struct NoteReference: Equatable, Hashable, Sendable {
    public var kind: NoteKind
    public var id: String
    /// The reference element as read, or as made.
    public var xml: String

    public init(kind: NoteKind, id: String, xml: String? = nil) {
        self.kind = kind
        self.id = id
        self.xml = xml ?? "<w:\(kind.rawValue)Reference w:id=\"\(XMLLite.escape(id))\"/>"
    }
}

/// A footnote or endnote, reduced to its text.
public struct Note: Equatable, Sendable, Identifiable {
    public var kind: NoteKind
    /// `w:id`, which the reference carries.
    public var id: String
    public var text: String
    /// The note's first paragraph's and first run's properties, kept when the text is written afresh.
    public var paragraphPropertiesXML: String?
    public var runPropertiesXML: String?
    /// The `w:footnote` or `w:endnote` as read, written back while the text is unchanged.
    public var originalXML: String?
    public var originalText: String?

    public var key: String { "\(kind.rawValue):\(id)" }

    public init(
        kind: NoteKind,
        id: String,
        text: String,
        paragraphPropertiesXML: String? = nil,
        runPropertiesXML: String? = nil,
        originalXML: String? = nil,
        originalText: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.text = text
        self.paragraphPropertiesXML = paragraphPropertiesXML
        self.runPropertiesXML = runPropertiesXML
        self.originalXML = originalXML
        self.originalText = originalText
    }
}

extension WordDocument {
    /// A note ID of `kind` not yet in use.
    public func unusedNoteID(_ kind: NoteKind) -> String {
        String(noteIDs.highest[kind, default: 0] + 1)
    }
}

/// The highest numeric ID of each kind of note, counted once and then only
/// for the notes appended since. Not part of a document's equality.
private struct NoteIDs: Equatable, Sendable {
    private(set) var highest: [NoteKind: Int] = [:]
    private var count = 0
    private var lastKey: String?

    mutating func update(for notes: [Note]) {
        // Appending leaves the notes already counted where they were; anything else counts them all again.
        let appended = notes.count > count && (count == 0 || notes[count - 1].key == lastKey)
        if !appended { self = NoteIDs() }
        for note in notes[count...] {
            if let id = Int(note.id) { highest[note.kind] = max(highest[note.kind, default: 0], id) }
        }
        count = notes.count
        lastKey = notes.last?.key
    }

    static func == (_: NoteIDs, _: NoteIDs) -> Bool { true }
}

/// Numbers notes as Word does: footnotes and endnotes each counted from one,
/// in the order the text refers to them.
public enum NoteNumbering: Sendable {
    /// The references in reading order, tables' among them.
    public static func references(in blocks: [Block]) -> [NoteReference] {
        blocks.flatMap { block -> [NoteReference] in
            switch block {
            case .paragraph(let paragraph):
                return paragraph.inlines.compactMap { if case .note(let reference) = $0.content { return reference } else { return nil } }
            case .table(let table):
                return table.rows.flatMap { $0.cells.flatMap { references(in: $0.blocks) } }
            case .preserved:
                return []
            }
        }
    }

    /// Each reference's number, by `kind:id`, in the document's formats.
    public static func numbers(in document: WordDocument) -> [String: String] {
        var counts: [NoteKind: Int] = [:]
        var result: [String: String] = [:]
        for reference in references(in: document.body) {
            let key = "\(reference.kind.rawValue):\(reference.id)"
            guard result[key] == nil else { continue }
            counts[reference.kind, default: 0] += 1
            let format = reference.kind == .footnote ? document.footnoteFormat : document.endnoteFormat
            result[key] = ListCounter.format(counts[reference.kind]!, as: format)
        }
        return result
    }
}

// MARK: - Comments

/// A comment, from the comments part, with its resolved state and the
/// comment it replies to, from Word's comments extensions.
public struct Comment: Equatable, Sendable, Identifiable {
    /// `w:id`, which the comment's range and reference in the body carry.
    public var id: String
    public var author: String
    public var initials: String?
    /// As the file spells it, ISO 8601.
    public var date: String?
    /// The comment's paragraphs, a line each.
    public var text: String
    /// The `w14:paraId` of the comment's last paragraph, which resolving
    /// and replying refer to.
    public var paraID: String?
    public var isDone = false
    /// The `paraID` of the comment this one replies to.
    public var parentParaID: String?
    /// The `w:comment` element as read, written back while the text is unchanged.
    public var originalXML: String?
    public var originalText: String?

    public var dateValue: Date? {
        date.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    public init(
        id: String,
        author: String,
        initials: String? = nil,
        date: String? = nil,
        text: String,
        paraID: String? = nil,
        isDone: Bool = false,
        parentParaID: String? = nil,
        originalXML: String? = nil,
        originalText: String? = nil
    ) {
        self.id = id
        self.author = author
        self.initials = initials
        self.date = date
        self.text = text
        self.paraID = paraID
        self.isDone = isDone
        self.parentParaID = parentParaID
        self.originalXML = originalXML
        self.originalText = originalText
    }
}

extension WordDocument {
    /// A comment ID not yet in use.
    public func unusedCommentID() -> String {
        String((comments.compactMap { Int($0.id) }.max() ?? -1) + 1)
    }

    /// A paragraph ID for a new comment's paragraph: eight hex digits, below
    /// 0x80000000 as Word requires, and unlike any the comments use.
    public func unusedCommentParaID() -> String {
        let used = Set(comments.compactMap(\.paraID))
        while true {
            let candidate = String(format: "%08X", UInt32.random(in: 0x1000_0000..<0x7FFF_FFFF))
            if !used.contains(candidate) { return candidate }
        }
    }
}

// MARK: - Package

/// The parts of the original file, keyed by their path in the ZIP.
public struct DocumentPackage: Equatable, Sendable {
    public var parts: [String: Data]
    /// The main document part, usually `word/document.xml`.
    public var documentPath: String
    /// The main part's relationships, by ID.
    public var relationships: [String: Relationship]
    /// The main part's root element's attributes, namespace declarations
    /// included, so the rewritten part keeps them all.
    public var rootAttributesXML: String
    public var namespaces: [String: String]
    /// Pictures added in Libretto, by relationship ID, still to be written as parts.
    public var addedMedia: [String: AddedMedia] = [:]
    /// Addresses of links made in Libretto, by relationship ID, still to be
    /// written as relationships.
    public var addedLinks: [String: String] = [:]

    public struct Relationship: Equatable, Sendable {
        public var type: String
        public var target: String
        public var isExternal: Bool

        public init(type: String, target: String, isExternal: Bool) {
            self.type = type
            self.target = target
            self.isExternal = isExternal
        }
    }

    public struct AddedMedia: Equatable, Sendable {
        public var path: String
        public var data: Data
        public var fileExtension: String
        public var contentType: String

        public init(path: String, data: Data, fileExtension: String, contentType: String) {
            self.path = path
            self.data = data
            self.fileExtension = fileExtension
            self.contentType = contentType
        }
    }

    /// The bytes of the part a relationship of the main part points at.
    public func data(forRelationship id: String) -> Data? {
        if let added = addedMedia[id] { return added.data }
        guard let relationship = relationships[id], !relationship.isExternal else { return nil }
        return parts[DOCXPaths.resolve(relationship.target, relativeTo: documentPath)]
    }

    /// A relationship ID not yet in use.
    public func unusedRelationshipID() -> String {
        var index = relationships.count + addedMedia.count + addedLinks.count + 1
        while relationships["rId\(index)"] != nil || addedMedia["rId\(index)"] != nil
            || addedLinks["rId\(index)"] != nil { index += 1 }
        return "rId\(index)"
    }

    public init(
        parts: [String: Data],
        documentPath: String,
        relationships: [String: Relationship],
        rootAttributesXML: String,
        namespaces: [String: String],
        addedMedia: [String: AddedMedia] = [:],
        addedLinks: [String: String] = [:]
    ) {
        self.parts = parts
        self.documentPath = documentPath
        self.relationships = relationships
        self.rootAttributesXML = rootAttributesXML
        self.namespaces = namespaces
        self.addedMedia = addedMedia
        self.addedLinks = addedLinks
    }
}

extension WordDocument {
    /// Fonts the document's text and styles name, in alphabetical order.
    public var fontNames: [String] {
        var names: Set<String> = []
        for paragraph in allParagraphs {
            for inline in paragraph.inlines { if let name = inline.format.style.fontName { names.insert(name) } }
        }
        for style in styles.styles.values { if let name = style.runStyle.fontName { names.insert(name) } }
        if let name = styles.defaultRunStyle.fontName { names.insert(name) }
        names.remove(RunStyle.minorThemeFont)
        names.remove(RunStyle.majorThemeFont)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
