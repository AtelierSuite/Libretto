import Foundation

/// The document's style definitions, from `word/styles.xml`.
public struct StyleSheet: Equatable, Sendable {
    public var styles: [String: Style] = [:]
    public var defaultParagraphProperties = ParagraphProperties()
    public var defaultRunStyle = RunStyle()
    /// The paragraph style a paragraph with no `w:pStyle` uses, usually "Normal".
    public var defaultParagraphStyleID: String?
    public var defaultCharacterStyleID: String?
    /// The body and heading fonts the theme names, which runs refer to by role.
    public var minorFont: String?
    public var majorFont: String?
    /// Built-in styles Libretto added because the document used one it did
    /// not define, to be written into the styles part on save.
    public var added: [ParagraphStyleChoice] = []
    public var addedTableStyles: [BuiltInTableStyle] = []

    public struct Style: Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: Kind
        public var basedOn: String?
        public var next: String?
        public var paragraphProperties = ParagraphProperties()
        public var runStyle = RunStyle()
        /// Whether the table style draws borders.
        public var hasTableBorders = false
        /// Six-digit RGB of the table style's borders.
        public var tableBorderColorHex: String?
        /// A table style's formatting for parts of the table, by `w:tblStylePr`
        /// type, with what the style says of the whole table as `wholeTable`.
        public var tableConditions: [TableCondition.Kind: TableCondition] = [:]
        /// `w:qFormat`: offered among the quick styles. `w:semiHidden`: not offered at all.
        public var isQuick = false
        public var isHidden = false
        /// The style's properties as read, and their elements, so a changed
        /// style has only what changed patched. `nil` for a style made in Libretto.
        public var originalParagraphProperties: ParagraphProperties?
        public var originalRunStyle: RunStyle?
        public var paragraphPropertiesXML: String?
        public var runPropertiesXML: String?
        /// Made in Libretto, to be added to the styles part on save.
        public var isCreated = false

        /// Whether it differs from the definition it was read with.
        public var isModified: Bool {
            !isCreated && (paragraphProperties != (originalParagraphProperties ?? ParagraphProperties())
                || runStyle != (originalRunStyle ?? RunStyle()))
        }

        public enum Kind: String, Sendable {
            case paragraph, character, table, numbering
        }

        public init(
            id: String,
            name: String,
            kind: Kind,
            basedOn: String? = nil,
            next: String? = nil,
            paragraphProperties: ParagraphProperties = ParagraphProperties(),
            runStyle: RunStyle = RunStyle(),
            hasTableBorders: Bool = false,
            tableBorderColorHex: String? = nil,
            tableConditions: [TableCondition.Kind: TableCondition] = [:],
            isQuick: Bool = false,
            isHidden: Bool = false,
            originalParagraphProperties: ParagraphProperties? = nil,
            originalRunStyle: RunStyle? = nil,
            paragraphPropertiesXML: String? = nil,
            runPropertiesXML: String? = nil,
            isCreated: Bool = false
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.basedOn = basedOn
            self.next = next
            self.paragraphProperties = paragraphProperties
            self.runStyle = runStyle
            self.hasTableBorders = hasTableBorders
            self.tableBorderColorHex = tableBorderColorHex
            self.tableConditions = tableConditions
            self.isQuick = isQuick
            self.isHidden = isHidden
            self.originalParagraphProperties = originalParagraphProperties
            self.originalRunStyle = originalRunStyle
            self.paragraphPropertiesXML = paragraphPropertiesXML
            self.runPropertiesXML = runPropertiesXML
            self.isCreated = isCreated
        }
    }

    // MARK: - Resolution

    /// Paragraph properties a paragraph ends up with: document defaults, then
    /// its style and everything that style is based on, then its own.
    public func resolvedParagraphProperties(_ direct: ParagraphProperties) -> ParagraphProperties {
        var result = defaultParagraphProperties
        for style in chain(from: direct.styleID ?? defaultParagraphStyleID) {
            result = result.merged(with: style.paragraphProperties)
        }
        return result.merged(with: direct)
    }

    /// Character formatting a run ends up with, in the same order Word
    /// applies it: defaults, paragraph style, character style, direct.
    public func resolvedRunStyle(_ direct: RunStyle, paragraphStyleID: String?) -> RunStyle {
        var result = defaultRunStyle
        for style in chain(from: paragraphStyleID ?? defaultParagraphStyleID) {
            result = result.merged(with: style.runStyle)
        }
        for style in chain(from: direct.characterStyleID ?? defaultCharacterStyleID) {
            result = result.merged(with: style.runStyle)
        }
        var own = direct
        own.characterStyleID = nil
        return result.merged(with: own)
    }

    /// A style and its ancestors, root first.
    private func chain(from id: String?) -> [Style] {
        var result: [Style] = []
        var seen: Set<String> = []
        var current = id
        while let key = current, !seen.contains(key), let style = styles[key] {
            seen.insert(key)
            result.insert(style, at: 0)
            current = style.basedOn
        }
        return result
    }

    public func tableHasBorders(styleID: String?) -> Bool {
        chain(from: styleID).contains { $0.hasTableBorders }
    }

    public func tableBorderColor(styleID: String?) -> String? {
        chain(from: styleID).reversed().lazy.compactMap(\.tableBorderColorHex).first
    }

    /// A table style's conditional formatting, with what a style inherits
    /// from the one it is based on.
    public func tableConditions(styleID: String?) -> [TableCondition.Kind: TableCondition] {
        var result: [TableCondition.Kind: TableCondition] = [:]
        for style in chain(from: styleID) {
            for (kind, condition) in style.tableConditions {
                result[kind] = result[kind].map { $0.merged(with: condition) } ?? condition
            }
        }
        return result
    }

    // MARK: - Choosing styles

    /// The heading level a paragraph style stands for, if it is a heading.
    public func headingLevel(ofStyle id: String?) -> Int? {
        guard let id else { return nil }
        let resolved = resolvedParagraphProperties(ParagraphProperties(styleID: id))
        if let level = resolved.outlineLevel, level < 9 { return level + 1 }
        let name = (styles[id]?.name ?? id).lowercased()
        guard name.hasPrefix("heading") else { return nil }
        return Int(String(name.dropFirst("heading".count)).trimmed)
    }

    /// The style ID for one of the paragraph styles the style menu offers,
    /// matched by Word's built-in names, which do not change with the language
    /// Word runs in, whatever the file chose to call the IDs.
    public func styleID(for choice: ParagraphStyleChoice) -> String? {
        let wanted = choice.builtInName.lowercased()
        if let match = styles.values.first(where: { $0.kind == .paragraph && $0.name.lowercased() == wanted }) {
            return match.id
        }
        let compact = wanted.replacingOccurrences(of: " ", with: "")
        return styles.values.first { $0.kind == .paragraph && $0.id.lowercased() == compact }?.id
    }

    /// The style ID for a menu choice, adding the built-in definition first
    /// if the document has none.
    public mutating func ensureStyle(_ choice: ParagraphStyleChoice) -> String {
        if let existing = styleID(for: choice) { return existing }
        var id = choice.defaultID
        while styles[id] != nil { id += "1" }
        guard var style = BuiltInStyles.style(for: choice) else { return id }
        style.id = id
        if style.basedOn.map({ styles[$0] == nil }) ?? false {
            style.basedOn = defaultParagraphStyleID
        }
        styles[id] = style
        added.append(choice)
        return id
    }

    /// Paragraph styles to offer: the quick styles, those the document uses,
    /// and those made in Libretto, by name.
    public func offeredParagraphStyles(using used: Set<String>) -> [Style] {
        styles.values.filter { style in
            style.kind == .paragraph && !style.isHidden && (style.isQuick || used.contains(style.id) || style.isCreated)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new paragraph style, returning its ID: one made from its name, unlike any other.
    public mutating func createParagraphStyle(
        name: String, basedOn: String?, paragraph: ParagraphProperties, run: RunStyle
    ) -> String {
        let stem = name.filter { $0.isLetter || $0.isNumber }
        var id = stem.isEmpty ? "Style" : stem
        var number = 1
        while styles[id] != nil {
            number += 1
            id = (stem.isEmpty ? "Style" : stem) + String(number)
        }
        var properties = paragraph
        properties.styleID = nil
        var runStyle = run
        runStyle.characterStyleID = nil
        var style = Style(id: id, name: name, kind: .paragraph, basedOn: basedOn, next: nil)
        style.paragraphProperties = properties
        style.runStyle = runStyle
        style.isQuick = true
        style.isCreated = true
        styles[id] = style
        return id
    }

    /// Table styles to offer: the document's own, then Word's that it lacks.
    public var tableStyles: [(id: String, name: String)] {
        let own = styles.values.filter { $0.kind == .table && !$0.isHidden && $0.id != defaultTableStyleID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (id: $0.id, name: $0.name) }
        let names = Set(own.map { $0.name.lowercased() })
        return own + BuiltInTableStyle.allCases.filter { !names.contains($0.name.lowercased()) && styles[$0.rawValue] == nil }
            .map { (id: $0.rawValue, name: $0.name) }
    }

    /// The table style a table without one uses, usually "Normal Table".
    public var defaultTableStyleID: String? {
        styles.values.first { $0.kind == .table && $0.name.lowercased() == "normal table" }?.id
    }

    /// The ID of a table style to put a table in, adding Word's definition first if the document lacks it.
    public mutating func ensureTableStyle(_ id: String) -> String {
        guard styles[id] == nil, let builtIn = BuiltInTableStyle(rawValue: id), var style = builtIn.style else { return id }
        if style.basedOn.map({ styles[$0] == nil }) ?? false { style.basedOn = nil }
        styles[id] = style
        addedTableStyles.append(builtIn)
        return id
    }

    /// A table of contents' style for a heading level, Word's `toc 1` to `toc 9`,
    /// added if the document lacks it: indented by level, its page number at a dotted right tab.
    public mutating func ensureContentsStyle(level: Int, width: Int) -> String {
        let name = "toc \(level)"
        if let existing = styles.values.first(where: { $0.kind == .paragraph && $0.name.lowercased() == name }) {
            return existing.id
        }
        let id = "TOC\(level)"
        var style = Style(id: id, name: name, kind: .paragraph, basedOn: defaultParagraphStyleID, next: defaultParagraphStyleID)
        style.paragraphProperties = ParagraphProperties(
            spacingAfter: 100, indentLeft: (level - 1) * 220,
            tabStops: [TabStop(position: max(1440, width), alignment: .right, leader: "dot")]
        )
        style.isCreated = true
        styles[id] = style
        return id
    }

    /// Which of the menu's styles a paragraph is in.
    public func choice(forStyle id: String?) -> ParagraphStyleChoice? {
        let resolvedID = id ?? defaultParagraphStyleID
        return ParagraphStyleChoice.allCases.first { styleID(for: $0) == resolvedID }
    }

    public init(
        styles: [String: Style] = [:],
        defaultParagraphProperties: ParagraphProperties = ParagraphProperties(),
        defaultRunStyle: RunStyle = RunStyle(),
        defaultParagraphStyleID: String? = nil,
        defaultCharacterStyleID: String? = nil,
        minorFont: String? = nil,
        majorFont: String? = nil,
        added: [ParagraphStyleChoice] = [],
        addedTableStyles: [BuiltInTableStyle] = []
    ) {
        self.styles = styles
        self.defaultParagraphProperties = defaultParagraphProperties
        self.defaultRunStyle = defaultRunStyle
        self.defaultParagraphStyleID = defaultParagraphStyleID
        self.defaultCharacterStyleID = defaultCharacterStyleID
        self.minorFont = minorFont
        self.majorFont = majorFont
        self.added = added
        self.addedTableStyles = addedTableStyles
    }
}

/// The paragraph styles the style menu offers. Every document Word makes can
/// use these, and Libretto adds their definitions to any that lacks one.
public enum ParagraphStyleChoice: String, CaseIterable, Identifiable, Sendable {
    case title
    case subtitle
    case heading1
    case heading2
    case heading3
    case body
    case quote

    public var id: String { rawValue }

    public var builtInName: String {
        switch self {
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .heading1: return "heading 1"
        case .heading2: return "heading 2"
        case .heading3: return "heading 3"
        case .body: return "Normal"
        case .quote: return "Quote"
        }
    }

    /// The ID Libretto gives the style when it has to add it.
    public var defaultID: String {
        switch self {
        case .title: return "Title"
        case .subtitle: return "Subtitle"
        case .heading1: return "Heading1"
        case .heading2: return "Heading2"
        case .heading3: return "Heading3"
        case .body: return "Normal"
        case .quote: return "Quote"
        }
    }

    public var label: String {
        switch self {
        case .title: return String(localized: "Style.Title", bundle: .engine)
        case .subtitle: return String(localized: "Style.Subtitle", bundle: .engine)
        case .heading1: return String(localized: "Style.Heading1", bundle: .engine)
        case .heading2: return String(localized: "Style.Heading2", bundle: .engine)
        case .heading3: return String(localized: "Style.Heading3", bundle: .engine)
        case .body: return String(localized: "Style.Body", bundle: .engine)
        case .quote: return String(localized: "Style.Quote", bundle: .engine)
        }
    }
}

// MARK: - Table styles

/// What a table style does to one part of a table: its header row, its
/// banded rows, its first column and so on.
public struct TableCondition: Equatable, Sendable {
    public var runStyle = RunStyle()
    public var paragraphProperties = ParagraphProperties()
    /// Six-digit RGB cell shading.
    public var fillHex: String?

    /// `w:tblStylePr` types, in the order Word applies them, each over the
    /// ones before it.
    public enum Kind: String, CaseIterable, Sendable {
        case wholeTable
        case band1Vert, band2Vert, band1Horz, band2Horz
        case firstCol, lastCol, firstRow, lastRow
        case neCell, nwCell, seCell, swCell
    }

    public func merged(with other: TableCondition) -> TableCondition {
        TableCondition(
            runStyle: runStyle.merged(with: other.runStyle),
            paragraphProperties: paragraphProperties.merged(with: other.paragraphProperties),
            fillHex: other.fillHex ?? fillHex
        )
    }

    public init(
        runStyle: RunStyle = RunStyle(),
        paragraphProperties: ParagraphProperties = ParagraphProperties(),
        fillHex: String? = nil
    ) {
        self.runStyle = runStyle
        self.paragraphProperties = paragraphProperties
        self.fillHex = fillHex
    }
}

/// Which of its style's conditional formats a table turns on, from `w:tblLook`.
public struct TableLook: Equatable, Sendable {
    public var firstRow = true
    public var lastRow = false
    public var firstColumn = true
    public var lastColumn = false
    public var bandedRows = true
    public var bandedColumns = false

    public init(
        firstRow: Bool = true,
        lastRow: Bool = false,
        firstColumn: Bool = true,
        lastColumn: Bool = false,
        bandedRows: Bool = true,
        bandedColumns: Bool = false
    ) {
        self.firstRow = firstRow
        self.lastRow = lastRow
        self.firstColumn = firstColumn
        self.lastColumn = lastColumn
        self.bandedRows = bandedRows
        self.bandedColumns = bandedColumns
    }
}

// MARK: - Numbering

/// List definitions, from `word/numbering.xml`.
public struct NumberingDefinitions: Equatable, Sendable {
    /// `w:num` instances: numbering ID to the abstract definition it uses.
    public var instances: [Int: Int] = [:]
    public var abstracts: [Int: [Int: ListLevel]] = [:]
    /// Where an instance starts its levels over, from `w:lvlOverride/w:startOverride`:
    /// numbering ID to level to the number it starts at.
    public var overrides: [Int: [Int: Int]] = [:]
    /// Lists Libretto created, to be added to the numbering part on save.
    public var added: [AddedList] = []

    public struct ListLevel: Equatable, Sendable {
        public var format: String
        /// `%1.` and the like.
        public var text: String
        public var start = 1
        /// Twips.
        public var indentLeft: Int?
        public var hanging: Int?

        public init(format: String, text: String, start: Int = 1, indentLeft: Int? = nil, hanging: Int? = nil) {
            self.format = format
            self.text = text
            self.start = start
            self.indentLeft = indentLeft
            self.hanging = hanging
        }
    }

    public struct AddedList: Equatable, Sendable {
        public var numberingID: Int
        public var abstractID: Int
        public var kind: ListKind
        /// Whether the abstract definition is new too, rather than one this
        /// instance numbers afresh.
        public var isNewDefinition = true

        public init(numberingID: Int, abstractID: Int, kind: ListKind, isNewDefinition: Bool = true) {
            self.numberingID = numberingID
            self.abstractID = abstractID
            self.kind = kind
            self.isNewDefinition = isNewDefinition
        }
    }

    public func level(_ level: Int, of numberingID: Int) -> ListLevel? {
        guard let abstract = instances[numberingID] else { return nil }
        return abstracts[abstract]?[level]
    }

    public func kind(of numberingID: Int) -> ListKind? {
        guard let level = level(0, of: numberingID) else { return nil }
        return level.format == "bullet" ? .bulleted : .numbered
    }

    /// A list of `kind` to put paragraphs in: one Libretto already made, or a new one.
    public mutating func numberingID(for kind: ListKind) -> Int {
        if let existing = added.first(where: { $0.kind == kind }) { return existing.numberingID }
        return addList(kind)
    }

    /// A new list of `kind`, numbered from its own start.
    public mutating func addList(_ kind: ListKind) -> Int {
        addList(levels: Self.levels(for: kind), kind: kind)
    }

    /// A new list with its own definition.
    public mutating func addList(levels: [Int: ListLevel], kind: ListKind) -> Int {
        let numberingID = (instances.keys.max() ?? 0) + 1
        let abstractID = (abstracts.keys.max() ?? -1) + 1
        instances[numberingID] = abstractID
        abstracts[abstractID] = levels
        added.append(AddedList(numberingID: numberingID, abstractID: abstractID, kind: kind))
        return numberingID
    }

    /// A new instance of an existing list's definition, starting `level` over at `start`.
    public mutating func restartList(_ numberingID: Int, level: Int, at start: Int) -> Int? {
        guard let abstractID = instances[numberingID], let kind = kind(of: numberingID) else { return nil }
        let restarted = (instances.keys.max() ?? 0) + 1
        instances[restarted] = abstractID
        overrides[restarted] = [level: start]
        added.append(AddedList(numberingID: restarted, abstractID: abstractID, kind: kind, isNewDefinition: false))
        return restarted
    }

    public static func levels(for kind: ListKind) -> [Int: ListLevel] {
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let formats = ["decimal", "lowerLetter", "lowerRoman"]
        return Dictionary(uniqueKeysWithValues: (0..<9).map { level in
            let left = 720 * (level + 1)
            switch kind {
            case .bulleted:
                return (level, ListLevel(
                    format: "bullet", text: bullets[level % bullets.count], indentLeft: left, hanging: 360
                ))
            case .numbered:
                return (level, ListLevel(
                    format: formats[level % formats.count], text: "%\(level + 1).", indentLeft: left, hanging: 360
                ))
            }
        })
    }

    public init(
        instances: [Int: Int] = [:],
        abstracts: [Int: [Int: ListLevel]] = [:],
        overrides: [Int: [Int: Int]] = [:],
        added: [AddedList] = []
    ) {
        self.instances = instances
        self.abstracts = abstracts
        self.overrides = overrides
        self.added = added
    }
}

public enum ListKind: String, Sendable {
    case bulleted
    case numbered
}

// MARK: - Unsupported features

/// What an opened file uses that Libretto shows or keeps, but cannot edit.
public struct UnsupportedFeatureReport: Equatable, Sendable {
    public var features: Set<Feature> = []

    public enum Feature: String, CaseIterable, Sendable {
        case macros
        case shapes
        case contentControls
        case embeddedObjects

        public var label: String {
            switch self {
            case .macros: return String(localized: "Unsupported.Macros", bundle: .engine)
            case .shapes: return String(localized: "Unsupported.Shapes", bundle: .engine)
            case .contentControls: return String(localized: "Unsupported.ContentControls", bundle: .engine)
            case .embeddedObjects: return String(localized: "Unsupported.EmbeddedObjects", bundle: .engine)
            }
        }
    }

    public var isEmpty: Bool { features.isEmpty }

    public mutating func insert(_ feature: Feature) {
        features.insert(feature)
    }

    public var orderedFeatures: [Feature] {
        Feature.allCases.filter(features.contains)
    }

    public init(features: Set<Feature> = []) {
        self.features = features
    }
}
