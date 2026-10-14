import CoreText
import Foundation

/// Saves edits to a Pages document back into the Pages file it was read
/// from, leaving the rest of the file as it was.
///
/// The body's text is written afresh from the document. What Pages keeps
/// alongside the text, character by character, follows it as it moved:
/// paragraph and character styles, lists, links, comments, tracked changes
/// and the rest stay with the text they were on, and new or changed
/// formatting takes a style Pages already has, or a variation of one made
/// for it, as Pages itself makes them.
///
/// Edits to what is set in the body, such as tables, pictures and notes,
/// and to headers and footers, are not written; `hasUnsavableChanges` tells
/// whether a document has any. A document Libretto cannot write back, such
/// as a page layout one, is saved as it was read.
enum PagesWriter {
    /// The package's files with the document's edits saved into them.
    static func files(for document: WordDocument) throws -> [String: Data] {
        guard let source = document.pagesSource else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let files = try source.files()
        guard let body = source.body else { return files }
        var writer = try PagesBodyWriter(files: files, document: document, body: body)
        return try writer.write()
    }

    /// The document saved as a single file: a ZIP of the package, its entries stored, as Pages writes it.
    static func data(for document: WordDocument) throws -> Data {
        try ZipArchive.archive(entries: ordered(files(for: document)), compressing: false)
    }

    /// The document saved as a package, or as a single file.
    static func fileWrapper(for document: WordDocument, asPackage: Bool) throws -> FileWrapper {
        guard asPackage else { return FileWrapper(regularFileWithContents: try data(for: document)) }
        return directory(try files(for: document))
    }

    /// The files with the document's own first, as Pages lists them.
    private static func ordered(_ files: [String: Data]) -> [(path: String, data: Data)] {
        files.sorted { ($0.key == "Index/Document.iwa" ? 0 : 1, $0.key) < ($1.key == "Index/Document.iwa" ? 0 : 1, $1.key) }
            .map { ($0.key, $0.value) }
    }

    private static func directory(_ files: [String: Data]) -> FileWrapper {
        var folders: [String: [String: Data]] = [:]
        var children: [String: FileWrapper] = [:]
        for (path, data) in files {
            if let slash = path.firstIndex(of: "/") {
                folders[String(path[..<slash]), default: [:]][String(path[path.index(after: slash)...])] = data
            } else {
                children[path] = FileWrapper(regularFileWithContents: data)
            }
        }
        for (name, contents) in folders { children[name] = directory(contents) }
        for (name, child) in children { child.preferredFilename = name }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    /// Whether a file is one of the package's previews, which show the document as it was.
    static func isPreview(_ path: String) -> Bool {
        (!path.contains("/") && path.hasPrefix("preview")) || path.hasPrefix("QuickLook/")
    }
}

// MARK: - Text alignment

/// Which units of a text were kept in another, made from it by editing.
enum PagesTextAlignment {
    /// For each of `new`'s units, the index in `old` of the one it is, if it
    /// was kept. Lines are matched first, then units within the lines
    /// between them, so a long text with a few edits is aligned quickly.
    static func matches(old: [Int], new: [Int], isBreak: (Int) -> Bool) -> [Int?] {
        var result = [Int?](repeating: nil, count: new.count)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            result[prefix] = prefix
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            result[new.count - 1 - suffix] = old.count - 1 - suffix
            suffix += 1
        }
        let oldLines = lines(old, in: prefix..<(old.count - suffix), isBreak: isBreak)
        let newLines = lines(new, in: prefix..<(new.count - suffix), isBreak: isBreak)
        var oldStart = prefix
        var newStart = prefix
        func matchUnits(upTo oldEnd: Int, _ newEnd: Int) {
            let oldGap = Array(old[oldStart..<oldEnd])
            let newGap = Array(new[newStart..<newEnd])
            // A wholesale rewrite keeps nothing rather than take long to say so.
            guard !oldGap.isEmpty, !newGap.isEmpty, oldGap.count * newGap.count <= 25_000_000 else { return }
            for (oldIndex, newIndex) in pairs(oldGap, newGap) { result[newStart + newIndex] = oldStart + oldIndex }
        }
        for (oldLine, newLine) in pairs(oldLines.map { Array(old[$0]) }, newLines.map { Array(new[$0]) }) {
            matchUnits(upTo: oldLines[oldLine].lowerBound, newLines[newLine].lowerBound)
            for offset in 0..<oldLines[oldLine].count {
                result[newLines[newLine].lowerBound + offset] = oldLines[oldLine].lowerBound + offset
            }
            oldStart = oldLines[oldLine].upperBound
            newStart = newLines[newLine].upperBound
        }
        matchUnits(upTo: old.count - suffix, new.count - suffix)
        return result
    }

    /// The ranges of a text's lines, each with the break that ends it.
    private static func lines(_ text: [Int], in range: Range<Int>, isBreak: (Int) -> Bool) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = range.lowerBound
        for index in range where isBreak(text[index]) {
            lines.append(start..<(index + 1))
            start = index + 1
        }
        if start < range.upperBound { lines.append(start..<range.upperBound) }
        return lines
    }

    /// The elements two sequences have in common, in order, by their indices.
    private static func pairs<Element: Hashable>(_ old: [Element], _ new: [Element]) -> [(Int, Int)] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [(Int, Int)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if removed.contains(oldIndex) {
                oldIndex += 1
            } else if inserted.contains(newIndex) {
                newIndex += 1
            } else {
                pairs.append((oldIndex, newIndex))
                oldIndex += 1
                newIndex += 1
            }
        }
        return pairs
    }
}

// MARK: - Attribute tables

/// A `TSWP.ObjectAttributeTable`'s entries: objects that apply from a character index on.
private struct ObjectEntries {
    var entries: [(index: Int, object: UInt64?)]

    init(_ message: ProtoMessage?) {
        entries = (message?.messages(1) ?? []).map { (Int(clamping: $0.uint(1)), $0.reference(2)) }
    }

    init(_ entries: [(index: Int, object: UInt64?)]) {
        self.entries = entries
    }

    var objects: [UInt64] { entries.compactMap(\.object) }

    /// The object of the entry in effect at `index`; an entry with none means none.
    func object(at index: Int) -> UInt64? {
        entry(at: index).flatMap { entries[$0].object }
    }

    /// The object in effect at `index`, where an entry with none carries on the one before.
    func inheritedObject(at index: Int) -> UInt64? {
        guard let last = entry(at: index) else { return nil }
        return entries[...last].reversed().lazy.compactMap(\.object).first
    }

    func entry(at index: Int) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].index <= index { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    var message: ProtoMessage {
        var table = ProtoMessage()
        for entry in entries {
            var attribute = ProtoMessage()
            attribute.append(1, .varint(UInt64(entry.index)))
            if let object = entry.object { attribute.append(2, message: .reference(object)) }
            table.append(1, message: attribute)
        }
        return table
    }
}

/// The entries of a table whose values are not objects: a
/// `TSWP.ParaDataAttributeTable`'s pairs, or a `TSWP.StringAttributeTable`'s strings.
private struct ValueEntries<Value: Equatable> {
    var entries: [(index: Int, value: Value)]

    func value(at index: Int) -> Value? {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].index <= index { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : entries[low - 1].value
    }
}

/// The entries for values, one for each unit of text: one at the start,
/// then one wherever the value changes.
private func runs<Value: Equatable>(_ values: [Value]) -> [(index: Int, object: Value)] {
    var result: [(index: Int, object: Value)] = []
    for (index, value) in values.enumerated() where index == 0 || result.last?.object != value {
        result.append((index, value))
    }
    return result
}

// MARK: - Writing the body

private struct PagesBodyWriter {
    private var files: [String: Data]
    private let document: WordDocument
    private let body: PagesBody
    private let archive: IWorkArchive
    /// Reads styles as the reader does, to tell what text in them looks like.
    private var converter: PagesConverter
    /// The archives being changed, by their path.
    private var archives: [String: IWorkArchiveFile] = [:]
    private var lastIdentifier: UInt64
    private let stylesheet: UInt64?

    /// Styles made for this save: their type, message, and the style each is a variation of.
    private var madeStyles: [(identifier: UInt64, type: UInt32, message: ProtoMessage, parent: UInt64)] = []
    private var madeParagraphStyles: [[UInt8]: UInt64] = [:]
    private var madeCharacterStyles: [[UInt8]: UInt64] = [:]
    /// What a paragraph in each made paragraph style looks like, and the style it varies.
    private var madeParagraphLooks: [UInt64: (parent: UInt64, properties: ParagraphProperties)] = [:]
    /// The properties each made character style sets.
    private var madeCharacterProperties: [UInt64: PagesCharacterProperties] = [:]
    /// The style found for text that is to look a way, in a paragraph style.
    private var foundCharacterStyles: [CharacterKey: UInt64?] = [:]
    private var foundParagraphStyles: [ParagraphKey: UInt64?] = [:]

    private struct CharacterKey: Hashable {
        var paragraphStyle: UInt64?
        var style: RunStyle
    }

    private struct ParagraphKey: Hashable {
        var properties: ParagraphProperties
        var isListed: Bool
    }

    init(files: [String: Data], document: WordDocument, body: PagesBody) throws {
        self.files = files
        self.document = document
        self.body = body
        archive = try IWorkArchive(files: files)
        converter = PagesConverter(archive: archive)
        guard let storage = archive[body.storage], storage.type == PagesReader.Types.storage else {
            throw IWorkError.notAnIWorkDocument
        }
        stylesheet = storage.message.reference(2)
        let metadata = archive.objects(ofType: Self.packageMetadataType).first?.object.message.uint(1) ?? 0
        lastIdentifier = max(metadata, archive.objects.keys.max() ?? 0)
    }

    private static let packageMetadataType: UInt32 = 11006

    /// The package's files with the document's edits saved into them; as
    /// they were, if there are none to save.
    mutating func write() throws -> [String: Data] {
        guard let storage = archive[body.storage]?.message else { return files }
        let written = writeStorage(storage)
        let pageSetupChanged = try writePageSetup()
        guard written.encoded != storage.encoded || pageSetupChanged else { return files }
        try replace(body.storage, with: written, references: references(of: written, replacing: storage))
        try registerMadeStyles()
        for (path, file) in archives { files[path] = file.data }
        return files.filter { !PagesWriter.isPreview($0.key) }
    }

    // MARK: Archives

    private mutating func file(at path: String) throws -> IWorkArchiveFile {
        if let file = archives[path] { return file }
        guard let data = files[path] else { throw IWorkError.corrupt(path) }
        let file = try IWorkArchiveFile(data, name: path)
        archives[path] = file
        return file
    }

    private mutating func replace(_ identifier: UInt64, with message: ProtoMessage, references: [UInt64]) throws {
        guard let path = archive.locations[identifier] else { throw IWorkError.corrupt("object \(identifier)") }
        var file = try file(at: path)
        file.replace(identifier, with: message, references: references)
        archives[path] = file
    }

    /// The objects a rewritten storage refers to: those it did, less those
    /// only its tables did and no longer do, and those its tables now do.
    private func references(of written: ProtoMessage, replacing storage: ProtoMessage) throws -> [UInt64] {
        guard let path = archive.locations[body.storage], let data = files[path] else { return [] }
        let original = try archives[path]?.references(body.storage) ?? IWorkArchiveFile(data, name: path).references(body.storage)
        let before = Set(Self.tableReferences(storage))
        let after = Self.tableReferences(written)
        let kept = original.filter { !before.contains($0) || after.contains($0) }
        var seen = Set(kept)
        return kept + after.filter { seen.insert($0).inserted }
    }

    private static func tableReferences(_ storage: ProtoMessage) -> [UInt64] {
        var references: [UInt64] = []
        for number in 5...28 {
            for entry in storage.message(number)?.messages(1) ?? [] {
                if let object = entry.reference(2) { references.append(object) }
            }
        }
        return references
    }

    // MARK: The text

    /// One UTF-16 unit of the body's text as the document now has it.
    private struct Unit {
        var code: UInt16
        /// What it is told apart by: the unit, or what it stands for.
        var key: Int
        /// The Pages paragraph it is in.
        var paragraph: Int
        /// The inline it comes from, among the text's; `nil` for a
        /// paragraph's end, and for a table.
        var inline: Int?
        /// The object an attachment or a footnote stands for.
        var object: UInt64?
    }

    private struct NewText {
        var units: [Unit] = []
        var inlines: [Inline] = []
        /// The paragraph each Pages paragraph is written from; `nil` for one that only holds a table.
        var paragraphs: [Paragraph?] = []
    }

    private static func attachmentKey(_ object: UInt64) -> Int { 1 << 40 | Int(truncatingIfNeeded: object) }
    private static func noteKey(_ object: UInt64) -> Int { 2 << 40 | Int(truncatingIfNeeded: object) }
    private static func fieldKey(countsPages: Bool) -> Int { 3 << 40 | (countsPages ? 1 : 0) }
    private static func isBreak(_ key: Int) -> Bool { key == 0x0A || key == 0x04 || key == 0x05 }

    /// The body's text from the document, as Pages keeps it: paragraphs
    /// ended by a break, pictures and tables as attachments, notes as their marks.
    private func newText() -> NewText {
        var text = NewText()
        var owed: UInt16?
        for block in document.body {
            switch block {
            case .preserved: continue
            case .table(let table) where body.tables[table.id] == nil: continue
            case .paragraph(let paragraph) where body.additions.contains(paragraph.id) && paragraph.inlines.isEmpty: continue
            default: break
            }
            let paragraph: Paragraph? = if case .paragraph(let paragraph) = block { paragraph } else { nil }
            if body.continuations.contains(block.id), !text.paragraphs.isEmpty {
                // The text after a table set in a paragraph is that paragraph's.
                if text.paragraphs[text.paragraphs.count - 1] == nil { text.paragraphs[text.paragraphs.count - 1] = paragraph }
            } else {
                if let owed {
                    text.units.append(Unit(code: owed, key: Int(owed), paragraph: text.paragraphs.count - 1))
                }
                text.paragraphs.append(paragraph)
            }
            owed = 0x0A
            switch block {
            case .table(let table):
                let object = body.tables[table.id]!
                text.units.append(Unit(
                    code: 0xFFFC, key: Self.attachmentKey(object), paragraph: text.paragraphs.count - 1, object: object
                ))
            case .paragraph(let paragraph):
                owed = append(paragraph, to: &text)
            case .preserved:
                break
            }
        }
        return text
    }

    /// Adds a paragraph's content to the text, and gives the break that ends it.
    private func append(_ paragraph: Paragraph, to text: inout NewText) -> UInt16 {
        let lastContent = paragraph.inlines.lastIndex { !$0.content.isMarker }
        var endsWithPageBreak = false
        var fieldDepth = 0
        var fieldCode = ""
        for (position, inline) in paragraph.inlines.enumerated() {
            let index = text.inlines.count
            text.inlines.append(inline)
            func emit(_ code: UInt16, key: Int? = nil, object: UInt64? = nil) {
                text.units.append(Unit(
                    code: code, key: key ?? Int(code), paragraph: text.paragraphs.count - 1, inline: index, object: object
                ))
            }
            if case .runChild(let xml, _) = inline.content, xml.contains("fldChar") {
                if xml.contains("\"begin\"") {
                    if fieldDepth == 0 { fieldCode = "" }
                    fieldDepth += 1
                } else if xml.contains("\"end\""), fieldDepth > 0 {
                    fieldDepth -= 1
                    // A page number or count is one attachment; other fields have no place in Pages.
                    let code = fieldCode.trimmingCharacters(in: .whitespaces).uppercased()
                    if fieldDepth == 0, code.hasPrefix("PAGE") || code.hasPrefix("NUMPAGES") {
                        emit(0xFFFC, key: Self.fieldKey(countsPages: code.hasPrefix("NUMPAGES")))
                    }
                }
                continue
            }
            if fieldDepth > 0 {
                if case .runChild(let xml, _) = inline.content, xml.contains("instrText") {
                    fieldCode += XMLLite.unescape(xml.replacing(#/<[^>]*>/#, with: ""))
                }
                continue
            }
            switch inline.content {
            case .text(let string):
                for unit in string.utf16 { emit(unit) }
            case .tab:
                emit(0x09)
            case .lineBreak:
                emit(0x2028)
            case .pageBreak, .columnBreak:
                if position == lastContent {
                    endsWithPageBreak = true
                } else {
                    // A break within the paragraph ends it there, and the rest is a paragraph like it.
                    text.units.append(Unit(code: 0x05, key: 0x05, paragraph: text.paragraphs.count - 1))
                    text.paragraphs.append(paragraph)
                }
            case .image(let image):
                if let object = body.images[image.relationshipID] {
                    emit(0xFFFC, key: Self.attachmentKey(object), object: object)
                }
            case .note(let reference):
                if let object = body.notes[reference.id] {
                    emit(0x0E, key: Self.noteKey(object), object: object)
                }
            case .runChild, .paragraphChild:
                break
            }
        }
        if paragraph.section != nil { return 0x04 }
        return endsWithPageBreak ? 0x05 : 0x0A
    }

    /// The text as read: each unit, and the key of each the reader turned into the document's content.
    private struct OldText {
        var codes: [UInt16]
        /// The index of each unit the document has, in order, and its key.
        var visible: [Int] = []
        var keys: [Int] = []
        /// The paragraph each unit is in, and where each paragraph starts.
        var paragraphs: [Int] = []
        var starts: [Int] = [0]
    }

    private func oldText(_ storage: ProtoMessage) -> OldText {
        var text = OldText(codes: Array(storage.strings(3).joined().utf16))
        let attachments = ObjectEntries(storage.message(9))
        let footnotes = ObjectEntries(storage.message(16))
        let shown = Set(body.images.values).union(body.tables.values)
        let notes = Set(body.notes.values)
        text.paragraphs.reserveCapacity(text.codes.count)
        for (index, code) in text.codes.enumerated() {
            text.paragraphs.append(text.starts.count - 1)
            var key: Int?
            switch code {
            case 0x0A, 0x2029:
                key = 0x0A
            case 0x04, 0x05, 0x09, 0x2028:
                key = Int(code)
            case 0xFFFC:
                if let object = attachments.object(at: index) {
                    if shown.contains(object) {
                        key = Self.attachmentKey(object)
                    } else if let field = archive[object], field.type == PagesReader.Types.pageNumber {
                        key = Self.fieldKey(countsPages: field.message.message(1)?.uint(2) == 1)
                    }
                }
            case 0x0E:
                if let object = footnotes.object(at: index), notes.contains(object) { key = Self.noteKey(object) }
            case 0x00..<0x20:
                key = nil
            default:
                key = Int(code)
            }
            if let key {
                text.visible.append(index)
                text.keys.append(key)
            }
            if [0x0A, 0x2029, 0x04, 0x05].contains(code) { text.starts.append(index + 1) }
        }
        return text
    }

    /// One unit of the text as written: kept from the text as read, or new.
    private struct Final {
        var code: UInt16
        var old: Int?
        var new: Int?
    }

    /// The text to write: the new text, with the old's units kept where
    /// they were, and those the document does not show, such as markers
    /// for objects Libretto leaves out, put back beside what they were by.
    private func merged(old: OldText, new: NewText) -> [Final] {
        let newKeys = new.units.map(\.key)
        var matches = PagesTextAlignment.matches(old: old.keys, new: newKeys, isBreak: Self.isBreak)
            .map { $0.map { old.visible[$0] } }
        // A character is kept whole, or not at all.
        for index in matches.indices {
            guard let match = matches[index] else { continue }
            let code = new.units[index].code
            if UTF16.isLeadSurrogate(code), index + 1 >= matches.count || matches[index + 1] != match + 1 {
                matches[index] = nil
            } else if UTF16.isTrailSurrogate(code), index == 0 || matches[index - 1] != match - 1 {
                matches[index] = nil
            }
        }
        var newIndexOfOld: [Int: Int] = [:]
        for (index, match) in matches.enumerated() {
            if let match { newIndexOfOld[match] = index }
        }
        // Each hidden unit goes before the next kept unit, or else after the last.
        var before: [Int: [Int]] = [:]
        var after: [Int] = []
        var pending: [Int] = []
        let shown = Set(old.visible)
        var lastKept: Int?
        for index in old.codes.indices {
            if let newIndex = newIndexOfOld[index] {
                before[newIndex, default: []] += pending
                pending = []
                lastKept = newIndex
            } else if !shown.contains(index) {
                pending.append(index)
            }
        }
        if lastKept != nil { after = pending }
        var result: [Final] = []
        result.reserveCapacity(new.units.count + old.codes.count - old.visible.count)
        for (index, unit) in new.units.enumerated() {
            for hidden in before[index] ?? [] { result.append(Final(code: old.codes[hidden], old: hidden)) }
            if let match = matches[index] {
                result.append(Final(code: old.codes[match], old: match, new: index))
            } else {
                result.append(Final(code: unit.code, new: index))
            }
            if index == lastKept { for hidden in after { result.append(Final(code: old.codes[hidden], old: hidden)) } }
        }
        return result
    }

    // MARK: The storage

    private mutating func writeStorage(_ storage: ProtoMessage) -> ProtoMessage {
        let old = oldText(storage)
        let new = newText()
        let text = merged(old: old, new: new)
        var written = storage

        // Paragraphs: where each starts in the text written, and the one as read it most is.
        var starts = [0]
        for (index, unit) in text.enumerated() where [0x0A, 0x2029, 0x04, 0x05].contains(unit.code) {
            starts.append(index + 1)
        }
        let paragraphCount = starts.count
        var candidates: [Int?] = []
        for paragraph in 0..<paragraphCount {
            let end = paragraph + 1 < paragraphCount ? starts[paragraph + 1] : text.count
            let kept = text[starts[paragraph]..<end].first { $0.old != nil }?.old
            candidates.append(kept.map { old.paragraphs[$0] })
        }
        // A paragraph as read is carried on by the first written from it; any others are new.
        var claimed = Set<Int>()
        let firstUses = candidates.map { candidate in candidate.map { claimed.insert($0).inserted } ?? false }

        let oldStyles = ObjectEntries(storage.message(5))
        let oldLists = ObjectEntries(storage.message(7))
        let oldData = ValueEntries(entries: Self.paragraphData(storage.message(6)))
        let oldStarts = ValueEntries(entries: Self.paragraphData(storage.message(14)))
        var styles: [UInt64?] = []
        var lists: [UInt64?] = []
        var data: [[UInt64]] = []
        var listStarts: [[UInt64]] = []
        for paragraph in 0..<paragraphCount {
            let model = paragraph < new.paragraphs.count ? new.paragraphs[paragraph] : nil
            let oldStart = candidates[paragraph].map { old.starts[$0] }
            let candidateStyle: UInt64? = oldStart.map { oldStyles.inheritedObject(at: $0) }
                ?? (styles.last ?? oldStyles.inheritedObject(at: 0))
            let candidateList: UInt64? = oldStart.map { oldLists.inheritedObject(at: $0) }
                ?? (lists.last ?? oldLists.inheritedObject(at: 0))
            let list = model?.properties.list.flatMap { $0.numberingID == 0 ? nil : $0 }
            let style = paragraphStyle(for: model, candidate: candidateStyle, isListed: list != nil)
            styles.append(style)
            let listStyle = self.listStyle(for: list, model: model, candidate: candidateList, paragraphStyle: style)
            lists.append(listStyle)
            let firstUse = firstUses[paragraph] && listStyle == candidateList
            let oldValue = oldStart.flatMap { oldData.value(at: $0) } ?? [0, 0]
            let exact = oldStart.map { start in oldData.entries.contains { $0.index == start } } ?? false
            if let list {
                data.append([UInt64(list.level), firstUse && exact ? oldValue[1] : 0])
            } else {
                data.append([0, 0])
            }
            listStarts.append(firstUse ? (oldStart.flatMap { oldStarts.value(at: $0) } ?? [0, 0]) : [0, 0])
        }

        // Paragraph styles: an entry at every paragraph, naming its style where it changes.
        var styleEntries: [(index: Int, object: UInt64?)] = []
        for (paragraph, style) in styles.enumerated() {
            styleEntries.append((starts[paragraph], paragraph > 0 && styles[paragraph - 1] == style ? nil : style))
        }
        written.set(5, message: ObjectEntries(styleEntries).message)
        written.set(7, message: ObjectEntries(Self.paragraphRuns(lists, starts: starts)).message)
        written.set(6, message: Self.paragraphDataMessage(Self.paragraphRuns(data, starts: starts)))
        if storage.has(14) || listStarts.contains(where: { $0 != [0, 0] }) {
            written.set(14, message: Self.paragraphDataMessage(Self.paragraphRuns(listStarts, starts: starts)))
        }

        // Each unit's paragraph, and the inline it was written from.
        var paragraphOfUnit: [Int] = []
        paragraphOfUnit.reserveCapacity(text.count)
        var paragraph = 0
        for unit in text {
            paragraphOfUnit.append(paragraph)
            if [0x0A, 0x2029, 0x04, 0x05].contains(unit.code) { paragraph += 1 }
        }
        func inline(_ unit: Final) -> Inline? {
            unit.new.flatMap { new.units[$0].inline }.map { new.inlines[$0] }
        }
        func isBreak(_ unit: Final) -> Bool { [0x0A, 0x2029, 0x04, 0x05].contains(unit.code) }

        // Character styles.
        let oldCharacters = ObjectEntries(storage.message(8))
        var characters: [UInt64?] = []
        characters.reserveCapacity(text.count)
        for (index, unit) in text.enumerated() {
            let candidate = unit.old.map { oldCharacters.object(at: $0) }
            if isBreak(unit) {
                // Paragraph breaks have no style; Pages gives page breaks the text's.
                characters.append(candidate ?? nil)
            } else if let inline = inline(unit) {
                characters.append(characterStyle(
                    for: inline, paragraphStyle: styles[paragraphOfUnit[index]], candidate: candidate,
                    known: oldCharacters.objects
                ))
            } else {
                characters.append(candidate ?? nil)
            }
        }
        written.set(8, message: ObjectEntries(runs(characters)).message)

        // Attachments and footnotes, at their own units only.
        let oldAttachments = ObjectEntries(storage.message(9))
        let oldFootnotes = ObjectEntries(storage.message(16))
        var attachments: [(index: Int, object: UInt64?)] = []
        var footnotes: [(index: Int, object: UInt64?)] = []
        var dropped = Set<Int>()
        for (index, unit) in text.enumerated() where unit.code == 0xFFFC || unit.code == 0x0E {
            let entries = unit.code == 0xFFFC ? oldAttachments : oldFootnotes
            let object = unit.old.map { entries.object(at: $0) } ?? unit.new.flatMap { new.units[$0].object }
            guard let object else {
                dropped.insert(index)
                continue
            }
            if unit.code == 0xFFFC { attachments.append((index, object)) } else { footnotes.append((index, object)) }
        }

        // Tables Libretto does not model follow the text they were on.
        func remapped<Value: Equatable>(_ value: (Int) -> Value, empty: Value) -> [Value] {
            var values: [Value] = []
            values.reserveCapacity(text.count)
            for unit in text {
                if let old = unit.old {
                    values.append(value(old))
                } else {
                    values.append(values.last ?? (old.codes.isEmpty ? empty : value(0)))
                }
            }
            return values
        }
        func objectTable(_ number: Int, adjust: (Int, Final, UInt64?) -> UInt64? = { $2 }) {
            guard storage.has(number) else { return }
            let entries = ObjectEntries(storage.message(number))
            var values = remapped({ entries.object(at: $0) }, empty: nil)
            for index in values.indices { values[index] = adjust(index, text[index], values[index]) }
            written.set(number, message: ObjectEntries(runs(values)).message)
        }
        for number in [12, 15, 17, 18, 27, 28] { objectTable(number) }

        // Links follow the document: a link it has is set, and one it took away is cleared.
        let linkObjects = Set(body.links.values)
        objectTable(11) { _, unit, value in
            if isBreak(unit) { return value.flatMap { linkObjects.contains($0) ? nil : $0 } }
            guard let inline = inline(unit) else { return value }
            if let id = inline.hyperlink?.relationshipID, let link = body.links[id] { return link }
            return value.flatMap { linkObjects.contains($0) ? nil : $0 }
        }
        // Tracked changes stay where the document still tracks them; new text is not tracked.
        for (number, kind) in [(21, Revision.Kind.insertion), (22, .deletion)] where storage.has(number) {
            let entries = ObjectEntries(storage.message(number))
            let values = text.enumerated().map { index, unit -> UInt64? in
                guard let old = unit.old, let object = entries.object(at: old) else { return nil }
                if isBreak(unit) {
                    let model = paragraphOfUnit[index] < new.paragraphs.count ? new.paragraphs[paragraphOfUnit[index]] : nil
                    return model?.markRevision?.kind == kind ? object : nil
                }
                guard let inline = inline(unit) else { return object }
                return inline.revision?.kind == kind ? object : nil
            }
            written.set(number, message: ObjectEntries(runs(values)).message)
        }
        // A comment taken away takes its highlight with it.
        let commentIDs = Set(document.comments.map(\.id))
        objectTable(23) { _, _, value in
            guard let value, let id = body.comments[value] else { return value }
            return commentIDs.contains(id) ? value : nil
        }
        for number in [19, 20] where storage.has(number) {
            let entries = ValueEntries(entries: (storage.message(number)?.messages(1) ?? []).map {
                (Int(clamping: $0.uint(1)), $0.string(2))
            })
            let values = remapped({ entries.value(at: $0) ?? nil }, empty: nil)
            var table = ProtoMessage()
            for run in runs(values) {
                var entry = ProtoMessage()
                entry.append(1, .varint(UInt64(run.index)))
                if let string = run.object { entry.append(2, .bytes(Array(string.utf8)[...])) }
                table.append(1, message: entry)
            }
            written.set(number, message: table)
        }
        if storage.has(24) {
            let entries = ValueEntries(entries: Self.paragraphData(storage.message(24)))
            let values = remapped({ entries.value(at: $0) ?? [0, 0] }, empty: [0, 0])
            written.set(24, message: Self.paragraphDataMessage(runs(values)))
        }
        var finalIndex: [Int: Int] = [:]
        for (index, unit) in text.enumerated() {
            if let old = unit.old { finalIndex[old] = index }
        }
        for number in [25, 26] where storage.has(number) {
            var table = ProtoMessage()
            for entry in storage.message(number)?.messages(1) ?? [] {
                guard let range = entry.message(1) else { continue }
                let location = Int(clamping: range.uint(1))
                let kept = (location..<(location + Int(clamping: range.uint(2)))).compactMap { finalIndex[$0] }
                guard let first = kept.min(), let last = kept.max() else { continue }
                var moved = entry
                var newRange = ProtoMessage()
                newRange.append(1, .varint(UInt64(first)))
                newRange.append(2, .varint(UInt64(last - first + 1)))
                moved.set(1, message: newRange)
                table.append(1, message: moved)
            }
            written.set(number, message: table)
        }

        // Attachments with nothing to stand for are left out, and everything after them moves back.
        if !dropped.isEmpty {
            written = Self.removing(dropped, from: written, count: text.count)
            attachments = attachments.map { (Self.shifted($0.index, past: dropped), $0.object) }
            footnotes = footnotes.map { (Self.shifted($0.index, past: dropped), $0.object) }
        }
        if storage.has(9) || !attachments.isEmpty { written.set(9, message: ObjectEntries(attachments).message) }
        if storage.has(16) || !footnotes.isEmpty { written.set(16, message: ObjectEntries(footnotes).message) }
        let codes = text.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element.code }
        written.replace(3, with: [.bytes(Array(String(decoding: codes, as: UTF16.self).utf8)[...])])
        return written
    }

    /// The values for each paragraph, as entries at the paragraphs where they change.
    private static func paragraphRuns<Value: Equatable>(_ values: [Value], starts: [Int]) -> [(index: Int, object: Value)] {
        var result: [(index: Int, object: Value)] = []
        for (paragraph, value) in values.enumerated() where paragraph == 0 || result.last?.object != value {
            result.append((starts[paragraph], value))
        }
        return result
    }

    private static func paragraphData(_ message: ProtoMessage?) -> [(index: Int, value: [UInt64])] {
        (message?.messages(1) ?? []).map { (Int(clamping: $0.uint(1)), [$0.uint(2), $0.uint(3)]) }
    }

    private static func paragraphDataMessage(_ entries: [(index: Int, object: [UInt64])]) -> ProtoMessage {
        var table = ProtoMessage()
        for entry in entries {
            var attribute = ProtoMessage()
            attribute.append(1, .varint(UInt64(entry.index)))
            attribute.append(2, .varint(entry.object.first ?? 0))
            attribute.append(3, .varint(entry.object.last ?? 0))
            table.append(1, message: attribute)
        }
        return table
    }

    private static func shifted(_ index: Int, past dropped: Set<Int>) -> Int {
        index - dropped.count { $0 < index }
    }

    /// A storage's tables with units taken out of the text they index.
    private static func removing(_ dropped: Set<Int>, from storage: ProtoMessage, count: Int) -> ProtoMessage {
        var storage = storage
        for number in 5...28 where ![9, 16, 25, 26].contains(number) {
            guard var table = storage.message(number) else { continue }
            var entries: [ProtoMessage] = []
            for var entry in table.messages(1) {
                // An entry at a unit taken out applies from the unit after it, unless another does.
                entry.set(1, .varint(UInt64(shifted(Int(clamping: entry.uint(1)), past: dropped))))
                if let last = entries.last, last.uint(1) == entry.uint(1) { entries.removeLast() }
                entries.append(entry)
            }
            table.replace(1, withMessages: entries)
            storage.set(number, message: table)
        }
        return storage
    }

    // MARK: Paragraph styles

    /// What a paragraph in a style looks like, made or not.
    private mutating func paragraphLook(_ style: UInt64?) -> ParagraphProperties {
        if let style, let made = madeParagraphLooks[style] { return made.properties }
        return converter.paragraphProperties(of: style)
    }

    /// What a paragraph looks like, in the terms both Pages and the document have.
    private static func comparable(_ properties: ParagraphProperties, isListed: Bool) -> ParagraphProperties {
        func nonzero(_ value: Int?) -> Int? { value == 0 ? nil : value }
        var result = ParagraphProperties()
        let headings: [ParagraphStyleChoice] = [.heading1, .heading2, .heading3]
        if let level = headings.firstIndex(where: { $0.defaultID == properties.styleID }) {
            result.outlineLevel = level
        } else if properties.styleID == nil {
            result.outlineLevel = properties.outlineLevel
        }
        result.alignment = properties.alignment == .leading ? nil : properties.alignment
        result.spacingBefore = nonzero(properties.spacingBefore)
        result.spacingAfter = nonzero(properties.spacingAfter)
        result.lineSpacing = properties.lineSpacing == LineSpacing(line: 240, rule: .auto) ? nil : properties.lineSpacing
        if !isListed {
            result.indentLeft = nonzero(properties.indentLeft)
            result.indentFirstLine = nonzero(properties.indentFirstLine)
        }
        result.indentRight = nonzero(properties.indentRight)
        result.keepNext = properties.keepNext == true ? true : nil
        result.keepLines = properties.keepLines == true ? true : nil
        result.pageBreakBefore = properties.pageBreakBefore == true ? true : nil
        result.widowControl = properties.widowControl == false ? false : nil
        result.shadingHex = properties.shadingHex?.uppercased()
        result.tabStops = properties.tabStops?.isEmpty == false ? properties.tabStops : nil
        return result
    }

    /// The paragraph style for a paragraph: the one it had, if it still
    /// looks as that does, or one that does, made if Pages has none.
    private mutating func paragraphStyle(for paragraph: Paragraph?, candidate: UInt64?, isListed: Bool) -> UInt64? {
        guard let paragraph else { return candidate }
        let wanted = Self.comparable(paragraph.properties, isListed: isListed)
        if Self.comparable(paragraphLook(candidate), isListed: isListed) == wanted { return candidate }
        let key = ParagraphKey(properties: wanted, isListed: isListed)
        if let found = foundParagraphStyles[key] { return found }
        let known = knownParagraphStyles
        var found = known.first { Self.comparable(paragraphLook($0), isListed: isListed) == wanted }
        if found == nil { found = makeParagraphStyle(wanted, isListed: isListed, candidate: candidate) ?? candidate }
        foundParagraphStyles[key] = .some(found)
        return found
    }

    /// The paragraph styles the body uses, and those made for it.
    private var knownParagraphStyles: [UInt64] {
        var seen = Set<UInt64>()
        let used = ObjectEntries(archive[body.storage]?.message.message(5)).objects.filter { seen.insert($0).inserted }
        return used + madeStyles.filter { $0.type == PagesReader.Types.paragraphStyle }.map(\.identifier)
    }

    /// The style a style is a variation of, or the style itself.
    private func namedStyle(_ style: UInt64) -> UInt64 {
        var current = style
        for _ in 0..<32 {
            guard let message = archive[current]?.message, let base = message.message(1), base.bool(4) == true,
                  let parent = base.reference(3) else { return current }
            current = parent
        }
        return current
    }

    /// A variation of a named style that looks as wanted: of the
    /// candidate's, if it is the right kind of paragraph, or of one that is.
    private mutating func makeParagraphStyle(_ wanted: ParagraphProperties, isListed: Bool, candidate: UInt64?) -> UInt64? {
        guard let stylesheet else { return nil }
        let level = wanted.outlineLevel
        var parent = candidate.map(namedStyle)
        if parent == nil || Self.comparable(paragraphLook(parent), isListed: isListed).outlineLevel != level {
            var seen = Set<UInt64>()
            let named = knownParagraphStyles.filter { madeParagraphLooks[$0] == nil }.map(namedStyle)
                + archive.objects(ofType: PagesReader.Types.paragraphStyle).map(\.identifier).filter {
                    archive[$0]?.message.message(1)?.bool(4) != true && archive.locations[$0] == archive.locations[stylesheet]
                }
            parent = named.filter { seen.insert($0).inserted }.first {
                Self.comparable(paragraphLook($0), isListed: isListed).outlineLevel == level
            } ?? parent
        }
        guard let parent else { return nil }
        let base = Self.comparable(paragraphLook(parent), isListed: isListed)
        var properties = ProtoMessage()
        func points(_ twips: Int?) -> ProtoMessage.Value { .fixed32(Float(Double(twips ?? 0) / 20).bitPattern) }
        func flag(_ value: Bool) -> ProtoMessage.Value { .varint(value ? 1 : 0) }
        if wanted.alignment != base.alignment {
            let codes: [ParagraphAlignment: UInt64] = [.leading: 0, .trailing: 1, .center: 2, .justified: 3]
            properties.append(1, .varint(codes[wanted.alignment ?? .leading] ?? 0))
        }
        if wanted.shadingHex != base.shadingHex {
            if let hex = wanted.shadingHex {
                properties.append(6, message: Self.color(hex))
            } else {
                properties.append(5, flag(true))
            }
        }
        if !isListed, wanted.indentLeft != base.indentLeft || wanted.indentFirstLine != base.indentFirstLine {
            // Pages measures the first line from the margin; Word, from the other lines.
            properties.append(7, points((wanted.indentLeft ?? 0) + (wanted.indentFirstLine ?? 0)))
            properties.append(11, points(wanted.indentLeft))
        }
        if wanted.keepLines != base.keepLines { properties.append(9, flag(wanted.keepLines == true)) }
        if wanted.keepNext != base.keepNext { properties.append(10, flag(wanted.keepNext == true)) }
        if wanted.lineSpacing != base.lineSpacing {
            var spacing = ProtoMessage()
            let line = wanted.lineSpacing ?? LineSpacing(line: 240, rule: .auto)
            switch line.rule {
            case .auto:
                spacing.append(1, .varint(0))
                spacing.append(2, .fixed32(Float(Double(line.line) / 240).bitPattern))
            case .atLeast:
                spacing.append(1, .varint(1))
                spacing.append(2, points(line.line))
            case .exact:
                spacing.append(1, .varint(2))
                spacing.append(2, points(line.line))
            }
            properties.append(13, message: spacing)
        }
        if wanted.pageBreakBefore != base.pageBreakBefore { properties.append(14, flag(wanted.pageBreakBefore == true)) }
        if wanted.indentRight != base.indentRight { properties.append(19, points(wanted.indentRight)) }
        if wanted.spacingAfter != base.spacingAfter { properties.append(20, points(wanted.spacingAfter)) }
        if wanted.spacingBefore != base.spacingBefore { properties.append(21, points(wanted.spacingBefore)) }
        if wanted.tabStops != base.tabStops {
            var tabs = ProtoMessage()
            let alignments: [TabStop.Alignment: UInt64] = [.left: 0, .center: 1, .right: 2, .decimal: 3]
            let leaders = ["dot": ".", "hyphen": "-", "underscore": "_", "middleDot": "\u{00B7}"]
            for stop in wanted.tabStops ?? [] where stop.alignment != .clear && stop.alignment != .bar {
                var tab = ProtoMessage()
                tab.append(1, points(stop.position))
                tab.append(2, .varint(alignments[stop.alignment] ?? 0))
                if let leader = stop.leader.flatMap({ leaders[$0] }) { tab.append(3, .bytes(Array(leader.utf8)[...])) }
                tabs.append(1, message: tab)
            }
            properties.append(25, message: tabs)
        }
        if wanted.widowControl != base.widowControl { properties.append(26, flag(wanted.widowControl != false)) }
        if wanted.outlineLevel != base.outlineLevel, let level = wanted.outlineLevel {
            properties.append(27, .varint(UInt64(level)))
        }
        guard !properties.fields.isEmpty else { return parent }

        let key = ProtoMessage.reference(parent).encoded + properties.encoded
        if let made = madeParagraphStyles[key] { return made }
        var style = ProtoMessage()
        style.append(1, message: Self.variation(of: parent, in: stylesheet))
        style.append(10, .varint(UInt64(properties.fields.count)))
        style.append(11, message: ProtoMessage())
        style.append(12, message: properties)
        let identifier = nextIdentifier()
        madeStyles.append((identifier, PagesReader.Types.paragraphStyle, style, parent))
        madeParagraphStyles[key] = identifier
        let (format, characters) = converter.paragraphStyle(parent)
        let overlaid = format.overlaid(with: PagesParagraphProperties(properties))
        var look = overlaid.paragraphProperties
        look.lineSpacing = overlaid.lineSpacing(fontSize: characters.fontSize)
        madeParagraphLooks[identifier] = (parent, look)
        return identifier
    }

    /// A `TSS.StyleArchive` for a variation of a style.
    private static func variation(of parent: UInt64, in stylesheet: UInt64) -> ProtoMessage {
        var base = ProtoMessage()
        base.append(3, message: .reference(parent))
        base.append(4, .varint(1))
        base.append(5, message: .reference(stylesheet))
        return base
    }

    /// A `TSP.Color` in sRGB.
    private static func color(_ hex: String) -> ProtoMessage {
        let value = UInt32(hex.prefix(6), radix: 16) ?? 0
        var color = ProtoMessage()
        color.append(1, .varint(1))
        for (field, shift) in [(3, 16), (4, 8), (5, 0)] {
            color.append(field, .fixed32(Float(Double(value >> UInt32(shift) & 0xFF) / 255).bitPattern))
        }
        color.append(6, .fixed32(Float(1).bitPattern))
        color.append(12, .varint(1))
        color.append(13, .fixed32(Float(1).bitPattern))
        return color
    }

    // MARK: Lists

    /// The list style for a paragraph: none, the one its list came from, or
    /// for a list made in Libretto, one of Pages' of the same kind.
    private mutating func listStyle(
        for list: ListReference?, model: Paragraph?, candidate: UInt64?, paragraphStyle: UInt64?
    ) -> UInt64? {
        guard model != nil else { return candidate }
        guard let list else {
            if let candidate, isUnlabelled(candidate) { return candidate }
            let known = ObjectEntries(archive[body.storage]?.message.message(7)).objects
            return known.first(where: isUnlabelled) ?? paragraphStyle.flatMap(listStyle(of:)).flatMap { isUnlabelled($0) ? $0 : nil }
                ?? candidate
        }
        if let style = body.lists[list.numberingID] { return style }
        let numbered = document.numbering.kind(of: list.numberingID) == .numbered
        let match = body.lists.sorted { $0.key < $1.key }.first { _, style in
            (archive[style]?.message.uints(11).first == 3) == numbered
        }
        return match?.value ?? candidate
    }

    /// Whether a list style labels nothing, as a paragraph in no list is in.
    private func isUnlabelled(_ style: UInt64) -> Bool {
        guard let object = archive[style], object.type == PagesReader.Types.listStyle else { return false }
        return (object.message.uints(11).first ?? 0) == 0
    }

    /// The list style a paragraph style puts its paragraphs in.
    private func listStyle(of paragraphStyle: UInt64) -> UInt64? {
        var current: UInt64? = madeParagraphLooks[paragraphStyle]?.parent ?? paragraphStyle
        for _ in 0..<32 {
            guard let style = current, let message = archive[style]?.message else { return nil }
            if let list = message.message(12)?.reference(40) { return list }
            current = message.message(1)?.reference(3)
        }
        return nil
    }

    // MARK: Character styles

    /// What text looks like, in the terms both Pages and the document have.
    private static func comparable(_ style: RunStyle) -> RunStyle {
        var result = RunStyle()
        result.fontName = style.fontName
        result.fontSize = style.fontSize
        result.isBold = style.isBold == true ? true : nil
        result.isItalic = style.isItalic == true ? true : nil
        if style.underline == true {
            result.underline = true
            result.underlineStyle = ["double", "wave"].contains(style.underlineStyle) ? style.underlineStyle : nil
        }
        if style.isDoubleStruckThrough == true {
            result.isDoubleStruckThrough = true
        } else if style.isStruckThrough == true {
            result.isStruckThrough = true
        }
        // Black is how Pages shows text of no colour.
        result.colorHex = style.colorHex.map { $0.uppercased() }.flatMap { $0 == "000000" ? nil : $0 }
        result.verticalAlignment = style.verticalAlignment == .baseline ? nil : style.verticalAlignment
        result.allCaps = style.allCaps == true ? true : nil
        result.smallCaps = result.allCaps == nil && style.smallCaps == true ? true : nil
        result.position = style.position == 0 || result.verticalAlignment != nil ? nil : style.position
        return result
    }

    /// What text in a paragraph style and a character style looks like, made or not.
    private mutating func runLook(_ paragraphStyle: UInt64?, _ characterStyle: UInt64?) -> RunStyle {
        let paragraphStyle = paragraphStyle.map { madeParagraphLooks[$0]?.parent ?? $0 }
        if let characterStyle, let made = madeCharacterProperties[characterStyle] {
            let base = paragraphStyle.map { converter.paragraphStyle($0).1 } ?? PagesCharacterProperties()
            return Self.comparable(base.overlaid(with: made).runStyle)
        }
        return Self.comparable(converter.runFormat(paragraphStyle: paragraphStyle, characterStyle: characterStyle).style)
    }

    /// The character style for text: the one it had, if it still looks as
    /// that does, or one that does, made if Pages has none.
    private mutating func characterStyle(
        for inline: Inline, paragraphStyle: UInt64?, candidate: UInt64??, known: [UInt64]
    ) -> UInt64? {
        var wanted = Self.comparable(inline.format.style)
        // A note's mark is raised however its text is set.
        let isNote = if case .note = inline.content { true } else { false }
        if isNote { wanted.verticalAlignment = nil }
        func looks(_ style: UInt64?) -> Bool {
            var look = runLook(paragraphStyle, style)
            if isNote { look.verticalAlignment = nil }
            // Text the document leaves to its paragraph takes the paragraph's font and size.
            if wanted.fontName == nil { look.fontName = nil }
            if wanted.fontSize == nil { look.fontSize = nil }
            return look == wanted
        }
        if let candidate, looks(candidate) { return candidate }
        let key = CharacterKey(paragraphStyle: paragraphStyle, style: wanted)
        if let found = foundCharacterStyles[key] { return found }
        var seen = Set<UInt64>()
        let styles: [UInt64?] = [nil] + (known + madeStyles.filter { $0.type == PagesReader.Types.characterStyle }.map(\.identifier))
            .filter { seen.insert($0).inserted }
        let found: UInt64?
        if let match = styles.first(where: looks) {
            found = match
        } else if let made = makeCharacterStyle(wanted, paragraphStyle: paragraphStyle, known: known) {
            found = made
        } else {
            found = candidate ?? nil
        }
        foundCharacterStyles[key] = .some(found)
        return found
    }

    /// The style character styles are variations of: Pages' style of no formatting.
    private func characterRoot(known: [UInt64]) -> UInt64? {
        if let style = known.first { return namedStyle(style) }
        return archive.objects(ofType: PagesReader.Types.characterStyle).first {
            $0.object.message.message(1)?.bool(4) != true
                && $0.object.message.message(1)?.string(2)?.contains("character-style-null") == true
        }?.identifier
    }

    /// A variation of Pages' style of no formatting that sets what the
    /// text has that its paragraph does not.
    private mutating func makeCharacterStyle(_ wanted: RunStyle, paragraphStyle: UInt64?, known: [UInt64]) -> UInt64? {
        guard let stylesheet, let parent = characterRoot(known: known) else { return nil }
        let baseCharacters = paragraphStyle.map { converter.paragraphStyle(madeParagraphLooks[$0]?.parent ?? $0).1 }
            ?? PagesCharacterProperties()
        let base = Self.comparable(baseCharacters.runStyle)
        var properties = ProtoMessage()
        func flag(_ value: Bool) -> ProtoMessage.Value { .varint(value ? 1 : 0) }
        let family = wanted.fontName ?? base.fontName
        if family != base.fontName || wanted.isBold != base.isBold || wanted.isItalic != base.isItalic {
            properties.append(1, flag(wanted.isBold == true))
            properties.append(2, flag(wanted.isItalic == true))
            let name = family.flatMap { Self.postScriptName(family: $0, bold: wanted.isBold == true, italic: wanted.isItalic == true) }
                ?? baseCharacters.fontName ?? family
            if let name { properties.append(5, .bytes(Array(name.utf8)[...])) }
        }
        if let size = wanted.fontSize, size != base.fontSize {
            properties.append(3, .fixed32(Float(Double(size) / 2).bitPattern))
        }
        if wanted.colorHex != base.colorHex {
            // Pages colours text with its fill, and keeps the colour as well for older versions.
            let color = Self.color(wanted.colorHex ?? "000000")
            var fill = ProtoMessage()
            fill.append(1, message: color)
            properties.append(7, message: color)
            properties.append(46, message: fill)
        }
        if wanted.verticalAlignment != base.verticalAlignment {
            properties.append(10, .varint(wanted.verticalAlignment == .superscript ? 1 : wanted.verticalAlignment == .subscript ? 2 : 0))
        }
        if wanted.underline != base.underline || wanted.underlineStyle != base.underlineStyle {
            let kind: UInt64 = wanted.underline != true ? 0 : wanted.underlineStyle == "double" ? 2 : wanted.underlineStyle == "wave" ? 3 : 1
            properties.append(11, .varint(kind))
        }
        if wanted.isStruckThrough != base.isStruckThrough || wanted.isDoubleStruckThrough != base.isDoubleStruckThrough {
            properties.append(12, .varint(wanted.isDoubleStruckThrough == true ? 2 : wanted.isStruckThrough == true ? 1 : 0))
        }
        if wanted.allCaps != base.allCaps || wanted.smallCaps != base.smallCaps {
            properties.append(13, .varint(wanted.allCaps == true ? 1 : wanted.smallCaps == true ? 2 : 0))
        }
        if wanted.position != base.position {
            properties.append(14, .fixed32(Float(Double(wanted.position ?? 0) / 2).bitPattern))
        }
        guard !properties.fields.isEmpty else { return nil }

        let key = ProtoMessage.reference(parent).encoded + properties.encoded
        if let made = madeCharacterStyles[key] { return made }
        var style = ProtoMessage()
        style.append(1, message: Self.variation(of: parent, in: stylesheet))
        style.append(10, .varint(UInt64(properties.fields.count)))
        style.append(11, message: properties)
        let identifier = nextIdentifier()
        madeStyles.append((identifier, PagesReader.Types.characterStyle, style, parent))
        madeCharacterStyles[key] = identifier
        madeCharacterProperties[identifier] = PagesCharacterProperties(properties)
        return identifier
    }

    /// The PostScript name of a family's face, bold or italic as asked, if it is installed.
    private static func postScriptName(family: String, bold: Bool, italic: Bool) -> String? {
        let font = CTFontCreateWithName(family as CFString, 12, nil)
        guard (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame else { return nil }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let face = traits.isEmpty ? font : CTFontCreateCopyWithSymbolicTraits(font, 12, nil, traits, [.traitBold, .traitItalic]) ?? font
        return CTFontCopyPostScriptName(face) as String
    }

    // MARK: Made styles

    private mutating func nextIdentifier() -> UInt64 {
        lastIdentifier += 1
        return lastIdentifier
    }

    /// Adds the styles made to the stylesheet, which lists every style and
    /// the variations of each, and tells the package about them.
    private mutating func registerMadeStyles() throws {
        guard !madeStyles.isEmpty, let stylesheet, let path = archive.locations[stylesheet] else { return }
        var file = try file(at: path)
        for made in madeStyles {
            file.append(
                made.identifier, type: UInt64(made.type), version: file.version(ofType: UInt64(made.type)) ?? [1, 0, 5],
                message: made.message, references: [made.parent]
            )
        }
        guard var sheet = file.message(stylesheet) else { throw IWorkError.corrupt("stylesheet") }
        sheet.replace(1, withMessages: sheet.messages(1) + madeStyles.map { ProtoMessage.reference($0.identifier) })
        var families = sheet.messages(5)
        for made in madeStyles {
            if let index = families.firstIndex(where: { $0.reference(1) == made.parent }) {
                families[index].append(2, message: .reference(made.identifier))
            } else {
                var family = ProtoMessage()
                family.append(1, message: .reference(made.parent))
                family.append(2, message: .reference(made.identifier))
                families.append(family)
            }
        }
        sheet.replace(5, withMessages: families)
        file.replace(stylesheet, with: sheet, references: file.references(stylesheet) + madeStyles.map(\.identifier))
        archives[path] = file
        try updateMetadata(addedTo: path)
    }

    /// Tells the package's metadata of the objects added: the last
    /// identifier in use, and that the body's component refers to them in another.
    private mutating func updateMetadata(addedTo path: String) throws {
        guard let identifier = archive.objects(ofType: Self.packageMetadataType).first?.identifier,
              var metadata = archive[identifier]?.message else { return }
        metadata.set(1, .varint(lastIdentifier))
        let bodyPath = archive.locations[body.storage]
        func componentPath(_ component: ProtoMessage) -> String? {
            (component.string(3) ?? component.string(2)).map { "Index/\($0).iwa" }
        }
        var components = metadata.messages(3)
        let target = components.first { componentPath($0) == path }?.uint(1)
        if let target, bodyPath != path, let index = components.firstIndex(where: { componentPath($0) == bodyPath }) {
            for made in madeStyles {
                var reference = ProtoMessage()
                reference.append(1, .varint(target))
                reference.append(2, .varint(made.identifier))
                components[index].append(6, message: reference)
            }
            metadata.replace(3, withMessages: components)
        }
        guard let metadataPath = archive.locations[identifier] else { return }
        var file = try file(at: metadataPath)
        file.replace(identifier, with: metadata, references: file.references(identifier))
        archives[metadataPath] = file
    }

    // MARK: Page setup

    /// Writes the page's size and margins, if they changed.
    private mutating func writePageSetup() throws -> Bool {
        guard let original = body.original?.document.pageSetup,
              let (identifier, object) = archive.objects(ofType: PagesReader.Types.document).first.map({ ($0.identifier, $0.object) })
        else { return false }
        let setup = document.pageSetup
        let fields: [(Int, Int, Int)] = [
            (30, setup.width, original.width), (31, setup.height, original.height),
            (32, setup.marginLeft, original.marginLeft), (33, setup.marginRight, original.marginRight),
            (34, setup.marginTop, original.marginTop), (35, setup.marginBottom, original.marginBottom),
            (36, setup.headerDistance, original.headerDistance), (37, setup.footerDistance, original.footerDistance),
        ]
        guard fields.contains(where: { $0.1 != $0.2 }) else { return false }
        var root = object.message
        for (field, value, was) in fields where value != was {
            root.set(field, .fixed32(Float(Double(value) / 20).bitPattern))
        }
        guard let path = archive.locations[identifier] else { return false }
        var file = try file(at: path)
        file.replace(identifier, with: root, references: file.references(identifier))
        archives[path] = file
        return true
    }
}
