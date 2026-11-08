import Foundation
import LibrettoEngine

/// A place in the text: a paragraph, and how far into it, in UTF-16 units as
/// the page counts them. A tab, a break or a picture is one unit; a field or
/// a note reference is as long as what it shows; markers take no room.
struct TextPosition: Equatable {
    var paragraph: UUID
    var offset: Int
}

/// The document being edited, its undo history, and the edits the web app
/// makes: the web's counterpart of the Apple apps' text controller, working
/// on the model directly rather than on attributed text.
final class WebSession {
    var file: WebDocument
    var document: WordDocument {
        get { file.document }
        set { file.document = newValue }
    }

    /// The inlines the last render showed, by reference, which the page's
    /// edits name.
    private var references: [Inline] = []
    /// Each list paragraph's label at the last render, to tell the page which have changed.
    private var labels: [UUID: String] = [:]

    private var undoStack: [WordDocument] = []
    private var redoStack: [WordDocument] = []
    /// When typing last added an undo step, so that a run of typing undoes as one.
    private var lastTypingStep: Date?

    /// Counts edits, so the page knows to draw again and to autosave.
    private(set) var contentVersion = 0
    private(set) var savedVersion = 0

    var isEdited: Bool { contentVersion != savedVersion }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(file: WebDocument) {
        self.file = file
        if document.body.isEmpty { document.body = [.paragraph(Paragraph())] }
    }

    func markSaved() {
        savedVersion = contentVersion
    }

    // MARK: - Rendering

    func render() -> [String: Any] {
        var renderer = WebRenderer(document: document)
        let output = renderer.render()
        references = renderer.references
        labels = currentLabels()
        return output
    }

    /// The labels of list paragraphs that changed since they were drawn, which
    /// splitting, joining or deleting list items moves on.
    func changedLabels() -> [String: String] {
        let current = currentLabels()
        var changed: [String: String] = [:]
        for (id, label) in current where labels[id] != label { changed[id.uuidString] = label }
        for id in labels.keys where current[id] == nil { changed[id.uuidString] = "" }
        labels = current
        return changed
    }

    private func currentLabels() -> [UUID: String] {
        var counter = ListCounter(styles: document.styles, numbering: document.numbering)
        var result: [UUID: String] = [:]
        Self.forEachParagraph(in: document.body) { paragraph in
            if let label = counter.label(for: paragraph.properties) { result[paragraph.id] = label }
        }
        return result
    }

    // MARK: - Undo

    /// Keeps the document as it is, to come back to. Typing within a couple of
    /// seconds of the last typing joins its step.
    private func recordUndo(typing: Bool = false) {
        let now = Date()
        if typing, let last = lastTypingStep, now.timeIntervalSince(last) < 2, !undoStack.isEmpty {
            lastTypingStep = now
            return
        }
        lastTypingStep = typing ? now : nil
        undoStack.append(document)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func changed() {
        contentVersion += 1
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        lastTypingStep = nil
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        lastTypingStep = nil
        changed()
    }

    // MARK: - Reading the page's edits

    /// Takes the page's text back: blocks it left alone come back as `{id}`,
    /// the rest as what the page shows of them, naming the inlines they were
    /// drawn from.
    ///
    /// Typing joins the undo step of the typing before it, unless `newStep`
    /// says this edit starts one: the page says so after a Return, a paste or
    /// a move of the caret elsewhere.
    func edit(_ blocks: [[String: Any]], newStep: Bool = false) {
        var originals: [UUID: Block] = [:]
        var rows: [UUID: TableRow] = [:]
        var cells: [UUID: TableCell] = [:]
        Self.index(document.body, blocks: &originals, rows: &rows, cells: &cells)
        var reader = Reader(references: references, originals: originals, rows: rows, cells: cells)
        var body = reader.blocks(blocks)
        if body.isEmpty { body = [.paragraph(Paragraph())] }
        // A table must be followed by a paragraph, which Word insists on.
        if case .paragraph = body.last {} else { body.append(.paragraph(Paragraph())) }
        guard body != document.body else { return }
        if newStep { lastTypingStep = nil }
        recordUndo(typing: true)
        document.body = body
        changed()
    }

    private static func index(
        _ blocks: [Block], blocks originals: inout [UUID: Block], rows: inout [UUID: TableRow], cells: inout [UUID: TableCell]
    ) {
        for block in blocks {
            originals[block.id] = block
            guard case .table(let table) = block else { continue }
            for row in table.rows {
                rows[row.id] = row
                for cell in row.cells {
                    cells[cell.id] = cell
                    index(cell.blocks, blocks: &originals, rows: &rows, cells: &cells)
                }
            }
        }
    }

    /// Reads the page's blocks, as `AttributedReader` reads attributed text.
    struct Reader {
        let references: [Inline]
        let originals: [UUID: Block]
        let rows: [UUID: TableRow]
        let cells: [UUID: TableCell]
        /// Markers already placed: a run the browser split carries its markers twice.
        var placedMarkers: Set<Int> = []

        mutating func blocks(_ list: [[String: Any]]) -> [Block] {
            Self.uniquing(list.compactMap { block($0) })
        }

        private mutating func block(_ json: [String: Any]) -> Block? {
            let id = (json["id"] as? String).flatMap(UUID.init(uuidString:))
            switch json["k"] as? String {
            case nil:
                // Untouched since it was drawn.
                return id.flatMap { originals[$0] }
            case "t":
                guard let id, case .table(var table) = originals[id] else { return nil }
                let rowsJSON = json["rows"] as? [[String: Any]] ?? []
                table.rows = rowsJSON.compactMap { rowJSON -> TableRow? in
                    guard let rowID = (rowJSON["id"] as? String).flatMap(UUID.init(uuidString:)),
                          var row = rows[rowID] else { return nil }
                    let byID = Dictionary((rowJSON["c"] as? [[String: Any]] ?? []).compactMap { cellJSON -> (UUID, [[String: Any]])? in
                        guard let cellID = (cellJSON["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
                        return (cellID, cellJSON["b"] as? [[String: Any]] ?? [])
                    }, uniquingKeysWith: { first, _ in first })
                    row.cells = row.cells.map { cell in
                        guard let blocksJSON = byID[cell.id] else { return cell }
                        var cell = cell
                        let blocks = self.blocks(blocksJSON)
                        cell.blocks = blocks.isEmpty ? [.paragraph(Paragraph())] : blocks
                        return cell
                    }
                    return row
                }
                return table.rows.isEmpty ? nil : .table(table)
            case "x":
                return id.flatMap { originals[$0] }
            default:
                return .paragraph(paragraph(json, id: id))
            }
        }

        private mutating func paragraph(_ json: [String: Any], id: UUID?) -> Paragraph {
            var paragraph: Paragraph
            if let id, case .paragraph(let original) = originals[id] {
                paragraph = original
            } else {
                paragraph = Paragraph()
            }
            var inlines: [Inline] = []
            var last: Inline?
            for run in json["r"] as? [[String: Any]] ?? [] {
                for marker in run["m"] as? [Int] ?? [] where references.indices.contains(marker) {
                    if placedMarkers.insert(marker).inserted { inlines.append(references[marker]) }
                }
                let reference = (run["r"] as? Int).flatMap { references.indices.contains($0) ? references[$0] : nil }
                var template = reference ?? last ?? Inline(.text(""))
                if let patch = run["p"] as? [String: Any] { Self.apply(patch, to: &template.format.style) }
                let kind = run["k"] as? String
                let text = run["t"] as? String ?? ""
                switch kind {
                case "tab": inlines.append(Inline(.tab, format: template.format, hyperlink: template.hyperlink, revision: template.revision))
                case "br": inlines.append(Inline(.lineBreak, format: template.format, hyperlink: template.hyperlink, revision: template.revision))
                case "page": inlines.append(Inline(.pageBreak, format: template.format, hyperlink: nil, revision: template.revision))
                case "col": inlines.append(Inline(.columnBreak, format: template.format, hyperlink: nil, revision: template.revision))
                case "img":
                    if let reference, case .image = reference.content { inlines.append(reference) }
                case "tok":
                    guard let reference else {
                        inlines += Self.textInlines(text, like: template)
                        break
                    }
                    if text == WebRenderer.display(of: reference, noteNumbers: [:]) || run["same"] as? Bool == true {
                        inlines.append(reference)
                    } else if !text.isEmpty {
                        // Edited: what it was is gone, and what is left is plain text.
                        inlines += Self.textInlines(text, like: template)
                    }
                default:
                    inlines += Self.textInlines(text, like: template)
                }
                last = template
            }
            for marker in json["m"] as? [Int] ?? [] where references.indices.contains(marker) {
                if placedMarkers.insert(marker).inserted { inlines.append(references[marker]) }
            }
            paragraph.inlines = InlineNormalizer.normalized(inlines)
            return paragraph
        }

        /// Text typed or kept, its line breaks as breaks, in the look of the run it was typed in.
        private static func textInlines(_ text: String, like template: Inline) -> [Inline] {
            var result: [Inline] = []
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\r" })
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    result.append(Inline(.lineBreak, format: template.format, hyperlink: template.hyperlink, revision: template.revision))
                }
                if !line.isEmpty {
                    result.append(Inline(.text(String(line)), format: template.format, hyperlink: template.hyperlink,
                                         revision: template.revision))
                }
            }
            return result
        }

        /// Splitting a paragraph leaves two with the same ID. The last keeps
        /// what belongs to the paragraph mark, as in Word; the others get copies.
        static func uniquing(_ blocks: [Block]) -> [Block] {
            var remaining: [UUID: Int] = [:]
            for block in blocks { remaining[block.id, default: 0] += 1 }
            guard remaining.values.contains(where: { $0 > 1 }) else { return blocks }
            return blocks.map { block in
                let id = block.id
                remaining[id, default: 1] -= 1
                guard remaining[id, default: 0] > 0 else { return block }
                switch block {
                case .paragraph(let paragraph): return .paragraph(paragraph.splitCopy())
                case .table(var table):
                    table.id = UUID()
                    table.originalXML = nil
                    return .table(table)
                case .preserved(var preserved):
                    preserved.id = UUID()
                    return .preserved(preserved)
                }
            }
        }

        /// Run formatting the page set on text as it was typed, such as bold
        /// turned on with nothing selected.
        static func apply(_ patch: [String: Any], to style: inout RunStyle) {
            for (key, value) in patch {
                let flag = value as? Bool
                switch key {
                case "b": style.isBold = flag
                case "i": style.isItalic = flag
                case "u": style.underline = flag
                case "x": style.isStruckThrough = flag
                case "v": style.verticalAlignment = (value as? String).flatMap(RunStyle.VerticalPosition.init(rawValue:))
                case "f": style.fontName = value as? String
                case "z": style.fontSize = value as? Int
                case "c": style.colorHex = value as? String
                case "hl": style.highlight = value as? String
                default: break
                }
            }
        }
    }

    // MARK: - Positions

    static func forEachParagraph(in blocks: [Block], _ body: (Paragraph) -> Void) {
        for block in blocks {
            switch block {
            case .paragraph(let paragraph): body(paragraph)
            case .table(let table):
                for row in table.rows { for cell in row.cells { forEachParagraph(in: cell.blocks, body) } }
            case .preserved: break
            }
        }
    }

    static func mapParagraphs(in blocks: inout [Block], _ change: (inout Paragraph) -> Void) {
        for index in blocks.indices {
            switch blocks[index] {
            case .paragraph(var paragraph):
                change(&paragraph)
                blocks[index] = .paragraph(paragraph)
            case .table(var table):
                for row in table.rows.indices {
                    for cell in table.rows[row].cells.indices {
                        mapParagraphs(in: &table.rows[row].cells[cell].blocks, change)
                    }
                }
                blocks[index] = .table(table)
            case .preserved: break
            }
        }
    }

    /// The paragraphs from `start`'s to `end`'s, in reading order, with the
    /// stretch of each that is selected.
    private func selectedRanges(from start: TextPosition, to end: TextPosition) -> [UUID: Range<Int>] {
        var order: [Paragraph] = []
        Self.forEachParagraph(in: document.body) { order.append($0) }
        guard var first = order.firstIndex(where: { $0.id == start.paragraph }),
              var last = order.firstIndex(where: { $0.id == end.paragraph }) else { return [:] }
        var (startOffset, endOffset) = (start.offset, end.offset)
        if first > last || (first == last && startOffset > endOffset) {
            swap(&first, &last)
            swap(&startOffset, &endOffset)
        }
        var result: [UUID: Range<Int>] = [:]
        for index in first...last {
            let length = length(of: order[index])
            let lower = index == first ? min(startOffset, length) : 0
            let upper = index == last ? min(endOffset, length) : length
            result[order[index].id] = lower..<max(lower, upper)
        }
        return result
    }

    private func length(of paragraph: Paragraph) -> Int {
        paragraph.inlines.reduce(0) { $0 + length(of: $1) }
    }

    private func length(of inline: Inline) -> Int {
        switch inline.content {
        case .text(let text): return text.utf16.count
        case .tab, .lineBreak, .pageBreak, .columnBreak, .image: return 1
        default:
            if inline.content.isMarker { return 0 }
            return WebRenderer.display(of: inline, noteNumbers: NoteNumbering.numbers(in: document))?.utf16.count ?? 0
        }
    }

    /// The paragraph's inlines with the stretch `range` split off from the rest,
    /// and the indices of the inlines it now covers.
    private func split(_ inlines: [Inline], at range: Range<Int>) -> (inlines: [Inline], selected: Range<Int>) {
        var result: [Inline] = []
        var location = 0
        var first: Int?
        var last = 0
        for inline in inlines {
            let length = length(of: inline)
            let start = location
            let end = location + length
            location = end
            guard case .text(let text) = inline.content, length > 0 else {
                let overlaps = length > 0 ? start < range.upperBound && end > range.lowerBound
                    : range.isEmpty ? false : start > range.lowerBound && start < range.upperBound
                if overlaps {
                    if first == nil { first = result.count }
                    last = result.count + 1
                }
                result.append(inline)
                continue
            }
            let utf16 = Array(text.utf16)
            let cuts = [start, max(start, min(end, range.lowerBound)), max(start, min(end, range.upperBound)), end]
            for piece in 0..<3 where cuts[piece + 1] > cuts[piece] {
                var part = inline
                let slice = utf16[(cuts[piece] - start)..<(cuts[piece + 1] - start)]
                part.content = .text(String(decoding: slice, as: UTF16.self))
                if piece == 1 {
                    if first == nil { first = result.count }
                    last = result.count + 1
                }
                result.append(part)
            }
        }
        return (result, (first ?? result.count)..<max(first ?? result.count, last))
    }

    // MARK: - Character formatting

    /// Changes the run formatting of the selected text.
    func editRuns(from start: TextPosition, to end: TextPosition, _ change: (inout RunStyle, _ paragraphStyleID: String?) -> Void) {
        let ranges = selectedRanges(from: start, to: end)
        guard !ranges.isEmpty else { return }
        recordUndo()
        Self.mapParagraphs(in: &document.body) { paragraph in
            guard let range = ranges[paragraph.id], !range.isEmpty else { return }
            var (inlines, selected) = split(paragraph.inlines, at: range)
            for index in selected where !inlines[index].content.isMarker {
                change(&inlines[index].format.style, paragraph.properties.styleID)
            }
            paragraph.inlines = InlineNormalizer.normalized(inlines)
        }
        changed()
    }

    /// The selection's look, resolved, at its start: what the toolbar shows.
    func resolvedStyle(at position: TextPosition) -> RunStyle {
        var found: RunStyle?
        Self.forEachParagraph(in: document.body) { paragraph in
            guard found == nil, paragraph.id == position.paragraph else { return }
            var location = 0
            var style = paragraph.inlines.first?.format.style ?? RunStyle()
            for inline in paragraph.inlines where !inline.content.isMarker {
                if location >= position.offset, location > 0 { break }
                style = inline.format.style
                location += length(of: inline)
            }
            found = document.styles.resolvedRunStyle(
                style, paragraphStyleID: paragraph.properties.styleID ?? document.styles.defaultParagraphStyleID
            )
        }
        return found ?? RunStyle()
    }

    /// Sets an on/off property, leaving it to the style where the style already says the same.
    func setFlag(_ key: WritableKeyPath<RunStyle, Bool?>, to value: Bool, from start: TextPosition, to end: TextPosition) {
        let styles = document.styles
        editRuns(from: start, to: end) { style, paragraphStyleID in
            var probe = style
            probe[keyPath: key] = nil
            let inherited = styles.resolvedRunStyle(probe, paragraphStyleID: paragraphStyleID ?? styles.defaultParagraphStyleID)[keyPath: key] ?? false
            style[keyPath: key] = inherited == value ? nil : value
        }
    }

    // MARK: - Paragraph formatting

    /// Changes the properties of every paragraph the selection touches.
    func editParagraphs(from start: TextPosition, to end: TextPosition, _ change: (inout ParagraphProperties) -> Void) {
        let ranges = selectedRanges(from: start, to: end)
        guard !ranges.isEmpty else { return }
        recordUndo()
        Self.mapParagraphs(in: &document.body) { paragraph in
            if ranges[paragraph.id] != nil { change(&paragraph.properties) }
        }
        changed()
    }

    func applyParagraphStyle(_ id: String, from start: TextPosition, to end: TextPosition) {
        let isDefault = id == document.styles.defaultParagraphStyleID
        editParagraphs(from: start, to: end) { $0.styleID = isDefault ? nil : id }
    }

    func applyParagraphStyle(_ choice: ParagraphStyleChoice, from start: TextPosition, to end: TextPosition) {
        let before = document
        let id = document.styles.ensureStyle(choice)
        applyParagraphStyle(id, from: start, to: end)
        // The style added is undone with the paragraphs put in it.
        if undoStack.last != before, let index = undoStack.indices.last { undoStack[index] = before }
    }

    func toggleList(_ kind: ListKind, from start: TextPosition, to end: TextPosition) {
        let before = document
        let styles = document.styles
        let isOn = listKind(at: start) == kind
        let numberingID = isOn ? 0 : neighbouringList(of: kind, before: start.paragraph) ?? document.numbering.numberingID(for: kind)
        editParagraphs(from: start, to: end) { properties in
            if isOn {
                var probe = properties
                probe.list = nil
                let styleHasList = ListCounter.listReference(styles.resolvedParagraphProperties(probe)) != nil
                properties.list = styleHasList ? ListReference(numberingID: 0, level: 0) : nil
            } else {
                properties.list = ListReference(numberingID: numberingID, level: properties.list?.level ?? 0)
            }
        }
        if let index = undoStack.indices.last, undoStack[index] != before { undoStack[index] = before }
    }

    /// The kind of list the paragraph at `position` is in, if any.
    func listKind(at position: TextPosition) -> ListKind? {
        var kind: ListKind?
        Self.forEachParagraph(in: document.body) { paragraph in
            guard paragraph.id == position.paragraph,
                  let list = ListCounter.listReference(document.styles.resolvedParagraphProperties(paragraph.properties))
            else { return }
            kind = document.numbering.kind(of: list.numberingID)
        }
        return kind
    }

    /// The list just before the paragraph, if it is of the kind wanted, so a
    /// list carries on rather than starting over.
    private func neighbouringList(of kind: ListKind, before id: UUID) -> Int? {
        var previous: ListReference?
        var found: ListReference?
        var done = false
        Self.forEachParagraph(in: document.body) { paragraph in
            guard !done else { return }
            if paragraph.id == id {
                found = previous
                done = true
                return
            }
            previous = ListCounter.listReference(document.styles.resolvedParagraphProperties(paragraph.properties))
        }
        guard let found, document.numbering.kind(of: found.numberingID) == kind else { return nil }
        return found.numberingID
    }

    func indent(by step: Int, from start: TextPosition, to end: TextPosition) {
        let styles = document.styles
        editParagraphs(from: start, to: end) { properties in
            let resolved = styles.resolvedParagraphProperties(properties)
            if let list = ListCounter.listReference(resolved) {
                properties.list = ListReference(numberingID: list.numberingID, level: min(8, max(0, list.level + step)))
            } else {
                properties.indentLeft = max(0, (properties.indentLeft ?? resolved.indentLeft ?? 0) + step * 720)
            }
        }
    }

    // MARK: - Inserting

    /// Puts a block in after the paragraph `id`, or in its place if it is empty.
    private func insertBlock(_ block: Block, after id: UUID) {
        recordUndo()
        func insert(into blocks: inout [Block]) -> Bool {
            for index in blocks.indices {
                switch blocks[index] {
                case .paragraph(let paragraph) where paragraph.id == id:
                    let isEmpty = paragraph.inlines.allSatisfy { $0.content.isMarker }
                    if isEmpty, paragraph.section == nil {
                        blocks.insert(block, at: index)
                    } else {
                        blocks.insert(block, at: index + 1)
                    }
                    if index + 2 > blocks.count - 1 || { if case .paragraph = blocks[min(blocks.count - 1, index + (isEmpty ? 1 : 2))] { return false } else { return true } }() {
                        blocks.insert(.paragraph(Paragraph()), at: index + (isEmpty && paragraph.section == nil ? 1 : 2))
                    }
                    return true
                case .table(var table):
                    for row in table.rows.indices {
                        for cell in table.rows[row].cells.indices where insert(into: &table.rows[row].cells[cell].blocks) {
                            blocks[index] = .table(table)
                            return true
                        }
                    }
                default:
                    continue
                }
            }
            return false
        }
        if !insert(into: &document.body) { document.body.append(block) }
        changed()
    }

    func insertTable(rows: Int, columns: Int, after id: UUID) {
        let setup = document.pageSetup
        let columnWidth = (setup.width - setup.marginLeft - setup.marginRight) / max(1, columns)
        let table = Table(
            rows: (0..<max(1, rows)).map { _ in
                TableRow(cells: (0..<max(1, columns)).map { _ in TableCell(blocks: [.paragraph(Paragraph())]) })
            },
            gridColumns: Array(repeating: columnWidth, count: max(1, columns)), preservedPropertiesXML: nil,
            styleID: nil, hasBorders: true
        )
        insertBlock(.table(table), after: id)
    }

    /// Puts a picture in at `position`, no wider than the text.
    func insertImage(_ data: Data, at position: TextPosition, width: Double, height: Double) throws {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isGIF = data.starts(with: Array("GIF8".utf8))
        guard isPNG || isJPEG || isGIF else { throw WebDocument.Failure(errorDescription: "Unsupported picture.") }
        let fileExtension = isPNG ? "png" : isJPEG ? "jpeg" : "gif"
        let id = document.package.unusedRelationshipID()
        document.package.addedMedia[id] = DocumentPackage.AddedMedia(
            path: "word/media/\(id).\(fileExtension)", data: data, fileExtension: fileExtension,
            contentType: "image/\(fileExtension)"
        )
        let scale = min(1, document.pageSetup.contentWidth / max(1, width))
        let image = InlineImage(relationshipID: id, width: width * scale, height: height * scale, xml: nil)
        recordUndo()
        Self.mapParagraphs(in: &document.body) { paragraph in
            guard paragraph.id == position.paragraph else { return }
            var (inlines, selected) = split(paragraph.inlines, at: position.offset..<position.offset)
            let format = (selected.lowerBound > 0 ? inlines[selected.lowerBound - 1].format : inlines.first?.format) ?? RunFormat()
            inlines.insert(Inline(.image(image), format: format), at: selected.lowerBound)
            paragraph.inlines = InlineNormalizer.normalized(inlines)
        }
        changed()
    }

    // MARK: - Tables

    /// Changes the table holding the cell `id`, given the cell's row and grid column.
    func editTable(containing cellID: UUID, _ change: (inout Table, _ row: Int, _ column: Int) -> Void) {
        func edit(_ blocks: inout [Block]) -> Bool {
            for index in blocks.indices {
                guard case .table(var table) = blocks[index] else { continue }
                for (rowIndex, row) in table.rows.enumerated() {
                    if let cellIndex = row.cells.firstIndex(where: { $0.id == cellID }) {
                        let column = TableEditing.gridStarts(of: row)[cellIndex]
                        change(&table, rowIndex, column)
                        blocks[index] = table.rows.isEmpty ? .paragraph(Paragraph()) : .table(table)
                        return true
                    }
                    for cellIndex in row.cells.indices where edit(&table.rows[rowIndex].cells[cellIndex].blocks) {
                        blocks[index] = .table(table)
                        return true
                    }
                }
            }
            return false
        }
        recordUndo()
        var body = document.body
        guard edit(&body) else {
            undoStack.removeLast()
            return
        }
        document.body = body
        changed()
    }

    func deleteTable(containing cellID: UUID) {
        editTable(containing: cellID) { table, _, _ in table.rows = [] }
    }

    // MARK: - Document

    func acceptAllRevisions(_ accept: Bool) {
        recordUndo()
        document.body = Revisions.resolve(document.body, accept: accept)
        changed()
    }

    func setTrackRevisions(_ isOn: Bool) {
        document.trackRevisions = isOn
        changed()
    }

    func setPageSetup(_ change: (inout PageSetup) -> Void) {
        recordUndo()
        change(&document.pageSetup)
        changed()
    }

    // MARK: - Text documents

    /// The whole text of a plain text or source file.
    var text: String { PlainText.text(of: document) }

    /// Replaces the text of a plain text or source file.
    func setText(_ text: String) {
        guard text != self.text else { return }
        recordUndo(typing: true)
        let format = document.sourceLanguage != nil ? PlainText.codeFormat : RunFormat()
        document.body = PlainText.body(from: text, format: format)
        changed()
    }
}
