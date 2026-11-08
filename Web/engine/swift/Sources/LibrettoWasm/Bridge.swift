import Foundation
import LibrettoEngine

/// Turns JSON requests from the page into session calls, and the session's
/// state back into JSON.
///
/// Every response carries the session's state: a `version` that counts edits
/// (the page draws again when an edit it didn't make itself moves it on), and
/// whether the document is edited and can be undone or redone.
final class Bridge {
    nonisolated(unsafe) static let shared = Bridge()

    private var session = WebSession(file: WebDocument(fileName: "Untitled.docx"))

    struct Failure: Error {
        var message: String
    }

    func handle(_ data: Data, payload: Data?) -> (json: Data, payload: Data?) {
        var output: Data?
        var body: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = request["cmd"] as? String else { throw Failure(message: "Malformed request.") }
            let result = try perform(command, request, payload: payload, output: &output)
            body = ["ok": true, "state": state()]
            if let result { body["result"] = result }
        } catch let failure as Failure {
            body = ["ok": false, "error": failure.message, "state": state()]
        } catch {
            body = ["ok": false, "error": error.localizedDescription, "state": state()]
        }
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"ok":false,"error":"Unencodable response."}"#.utf8)
        return (json, output)
    }

    // MARK: - Commands

    private func perform(_ command: String, _ r: [String: Any], payload: Data?, output: inout Data?) throws -> Any? {
        switch command {
        case "init":
            if let strings = r["strings"] as? [String: String] { PortableStrings.load(strings) }
            if let locale = r["locale"] as? String {
                PortableStrings.localeIdentifier = locale.replacingOccurrences(of: "-", with: "_")
            }
            return nil
        case "new":
            let name = r["name"] as? String ?? "Untitled.docx"
            var document = WordDocument()
            if let format = DocumentFile.Format(filename: name), format.isText {
                // A new text file opens in the code editor, as one opened would.
                document.body = PlainText.body(from: "")
                if case .source(let language) = format { document.sourceLanguage = language }
                var file = WebDocument(document: document, fileName: name)
                file.format = format
                session = WebSession(file: file)
            } else {
                session = WebSession(file: WebDocument(document: document, fileName: name))
            }
            return info()
        case "open":
            guard let payload else { throw Failure(message: "No file was given.") }
            let name = r["name"] as? String ?? "Untitled"
            session = WebSession(file: try WebDocument(data: payload, fileName: name))
            return info()
        case "save":
            let format = (r["format"] as? String).flatMap(DocumentFile.Format.init(key:)) ?? session.file.defaultSaveFormat
            output = try session.file.data(as: format)
            if r["keep"] as? Bool != true { session.markSaved() }
            return ["fileName": session.file.fileName(for: format), "format": format.key, "mime": format.mimeType]
        case "rename":
            if let name = r["name"] as? String { session.file.fileName = name }
            return info()
        case "info":
            return info()
        case "environment":
            return ["locale": PortableStrings.localeIdentifier, "timeZone": TimeZone.current.identifier]
        case "render":
            return session.render()
        case "media":
            guard let id = r["id"] as? String, let data = session.document.package.data(forRelationship: id) else {
                throw Failure(message: "No such picture.")
            }
            output = data
            return ["mime": Self.mimeType(of: data, name: session.document.package.relationships[id]?.target ?? "")]

        // Editing the text
        case "edit":
            session.edit(r["blocks"] as? [[String: Any]] ?? [], newStep: r["step"] as? Bool ?? false)
            return ["labels": session.changedLabels()]
        case "undo":
            session.undo()
        case "redo":
            session.redo()

        // Character formatting
        case "format":
            let (start, end) = try selection(r)
            try format(r["set"] as? [String: Any] ?? [:], from: start, to: end)
        case "look":
            // The resolved look of the text at a place, for the inspector.
            let style = session.resolvedStyle(at: try position(r["at"]))
            var look: [String: Any] = ["size": Double(style.fontSize ?? 22) / 2]
            if let font = style.fontName { look["font"] = font }
            if let color = style.colorHex { look["color"] = color }
            if let highlight = style.highlight { look["highlight"] = highlight }
            return look

        // Paragraph formatting
        case "paragraph":
            let (start, end) = try selection(r)
            paragraph(r["set"] as? [String: Any] ?? [:], from: start, to: end)
        case "style":
            let (start, end) = try selection(r)
            if let choice = (r["choice"] as? String).flatMap(ParagraphStyleChoice.init(rawValue:)) {
                session.applyParagraphStyle(choice, from: start, to: end)
            } else if let id = r["id"] as? String {
                session.applyParagraphStyle(id, from: start, to: end)
            }
        case "list":
            let (start, end) = try selection(r)
            let kind: ListKind = r["kind"] as? String == "numbered" ? .numbered : .bulleted
            session.toggleList(kind, from: start, to: end)
        case "indent":
            let (start, end) = try selection(r)
            session.indent(by: r["step"] as? Int ?? 1, from: start, to: end)

        // Inserting
        case "insertTable":
            let at = try position(r["at"])
            session.insertTable(rows: r["rows"] as? Int ?? 2, columns: r["columns"] as? Int ?? 2, after: at.paragraph)
        case "insertImage":
            guard let payload else { throw Failure(message: "No picture was given.") }
            try session.insertImage(
                payload, at: try position(r["at"]),
                width: r["width"] as? Double ?? 200, height: r["height"] as? Double ?? 150
            )
        case "table":
            guard let cell = (r["cell"] as? String).flatMap(UUID.init(uuidString:)) else { throw Failure(message: "No cell.") }
            table(r["op"] as? String ?? "", cell: cell)

        // The document
        case "revisions":
            session.acceptAllRevisions(r["accept"] as? Bool ?? true)
        case "trackChanges":
            session.setTrackRevisions(r["on"] as? Bool ?? false)
        case "pageSetup":
            session.setPageSetup { setup in
                if let width = r["width"] as? Double { setup.width = Int(width * 20) }
                if let height = r["height"] as? Double { setup.height = Int(height * 20) }
                if let margin = r["top"] as? Double { setup.marginTop = Int(margin * 20) }
                if let margin = r["bottom"] as? Double { setup.marginBottom = Int(margin * 20) }
                if let margin = r["left"] as? Double { setup.marginLeft = Int(margin * 20) }
                if let margin = r["right"] as? Double { setup.marginRight = Int(margin * 20) }
            }

        // Plain text and source code
        case "text":
            var result: [String: Any] = ["text": session.text]
            if let language = session.document.sourceLanguage { result["language"] = language.rawValue }
            return result
        case "setText":
            session.setText(r["text"] as? String ?? "")
        case "highlight":
            let text = r["text"] as? String ?? session.text
            guard let language = (r["language"] as? String).flatMap(SourceLanguage.init(rawValue:))
                ?? session.document.sourceLanguage else { return [] }
            let dark = r["dark"] as? Bool ?? false
            return SyntaxHighlighter.tokens(in: text, language: language).map { token -> [Any] in
                [token.range.location, token.range.length, String(format: "#%06X", SyntaxHighlighter.rgb(for: token.kind, isDark: dark))]
            }
        case "setLanguage":
            let language = (r["language"] as? String).flatMap(SourceLanguage.init(rawValue:))
            session.document.sourceLanguage = language == .plainText ? nil : language
            return info()

        default:
            throw Failure(message: "Unknown command \(command).")
        }
        return nil
    }

    // MARK: - Selections

    private func position(_ value: Any?) throws -> TextPosition {
        guard let json = value as? [String: Any], let id = (json["p"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw Failure(message: "No place in the text was given.")
        }
        return TextPosition(paragraph: id, offset: json["o"] as? Int ?? 0)
    }

    private func selection(_ r: [String: Any]) throws -> (TextPosition, TextPosition) {
        let anchor = try position(r["a"])
        let focus = (try? position(r["f"])) ?? anchor
        return (anchor, focus)
    }

    private func format(_ set: [String: Any], from start: TextPosition, to end: TextPosition) throws {
        let flags: [String: WritableKeyPath<RunStyle, Bool?>] = [
            "b": \.isBold, "i": \.isItalic, "u": \.underline, "x": \.isStruckThrough,
            "caps": \.allCaps, "sc": \.smallCaps,
        ]
        let styles = session.document.styles
        for (key, value) in set {
            if let path = flags[key], let isOn = value as? Bool {
                session.setFlag(path, to: isOn, from: start, to: end)
                continue
            }
            switch key {
            case "v":
                let position = (value as? String).flatMap(RunStyle.VerticalPosition.init(rawValue:))
                session.editRuns(from: start, to: end) { style, _ in style.verticalAlignment = position }
            case "f":
                session.editRuns(from: start, to: end) { style, _ in style.fontName = value as? String }
            case "z":
                // Points.
                guard let points = value as? Double else { break }
                session.editRuns(from: start, to: end) { style, _ in style.fontSize = min(384, max(2, Int(points * 2))) }
            case "zStep":
                let step = value as? Int ?? 1
                session.editRuns(from: start, to: end) { style, paragraphStyleID in
                    let current = styles.resolvedRunStyle(style, paragraphStyleID: paragraphStyleID ?? styles.defaultParagraphStyleID).fontSize ?? 22
                    style.fontSize = min(384, max(2, current + step * 2))
                }
            case "c":
                let hex = (value as? String).map { String($0.replacingOccurrences(of: "#", with: "").suffix(6)).uppercased() }
                session.editRuns(from: start, to: end) { style, _ in style.colorHex = hex }
            case "hl":
                session.editRuns(from: start, to: end) { style, _ in style.highlight = value as? String }
            case "clear":
                session.editRuns(from: start, to: end) { style, _ in style = RunStyle() }
            default:
                throw Failure(message: "Unknown format \(key).")
            }
        }
    }

    private func paragraph(_ set: [String: Any], from start: TextPosition, to end: TextPosition) {
        session.editParagraphs(from: start, to: end) { properties in
            for (key, value) in set {
                switch key {
                case "align":
                    properties.alignment = (value as? String).flatMap(ParagraphAlignment.init(rawValue:))
                case "before":
                    properties.spacingBefore = (value as? Double).map { Int($0 * 20) }
                case "after":
                    properties.spacingAfter = (value as? Double).map { Int($0 * 20) }
                case "line":
                    properties.lineSpacing = (value as? Double).map { LineSpacing(line: Int($0 * 240), rule: .auto) }
                case "left":
                    properties.indentLeft = (value as? Double).map { Int($0 * 20) }
                case "right":
                    properties.indentRight = (value as? Double).map { Int($0 * 20) }
                case "first":
                    properties.indentFirstLine = (value as? Double).map { Int($0 * 20) }
                case "keepNext":
                    properties.keepNext = value as? Bool
                case "keepLines":
                    properties.keepLines = value as? Bool
                case "pageBreakBefore":
                    properties.pageBreakBefore = value as? Bool
                case "shading":
                    properties.shadingHex = (value as? String).map { String($0.replacingOccurrences(of: "#", with: "").suffix(6)).uppercased() }
                default:
                    break
                }
            }
        }
    }

    private func table(_ operation: String, cell: UUID) {
        if operation == "deleteTable" {
            session.deleteTable(containing: cell)
            return
        }
        session.editTable(containing: cell) { table, row, column in
            switch operation {
            case "rowAbove": TableEditing.insertRow(in: &table, at: row, below: false)
            case "rowBelow": TableEditing.insertRow(in: &table, at: row, below: true)
            case "columnBefore": TableEditing.insertColumn(in: &table, at: column, after: false)
            case "columnAfter": TableEditing.insertColumn(in: &table, at: column, after: true)
            case "deleteRow": TableEditing.deleteRow(in: &table, at: row)
            case "deleteColumn":
                if table.columnCount <= 1 {
                    table.rows = []
                } else {
                    TableEditing.deleteColumn(in: &table, at: column)
                }
            case "headerRow": TableEditing.setHeader(in: &table, row: row, !table.rows[row].isHeader)
            default: break
            }
        }
    }

    // MARK: - State

    private func state() -> [String: Any] {
        [
            "version": session.contentVersion,
            "edited": session.isEdited,
            "canUndo": session.canUndo,
            "canRedo": session.canRedo,
        ]
    }

    private func info() -> [String: Any] {
        let file = session.file
        let document = session.document
        var used = Set<String>()
        WebSession.forEachParagraph(in: document.body) { paragraph in
            if let id = paragraph.properties.styleID { used.insert(id) }
        }
        var result: [String: Any] = [
            "fileName": file.fileName,
            "format": (file.format ?? .word).key,
            "saveFormats": file.saveFormats.map { format -> [String: Any] in
                ["key": format.key, "extension": format.fileExtension, "mime": format.mimeType, "fileName": file.fileName(for: format)]
            },
            "isText": file.isText,
            "hasMacros": document.hasMacros,
            "trackRevisions": document.trackRevisions,
            "hasRevisions": Revisions.contains(document.body),
            "wordCount": document.wordCount,
            "paragraphStyles": document.styles.offeredParagraphStyles(using: used).map { ["id": $0.id, "name": $0.name] },
            "defaultStyle": document.styles.defaultParagraphStyleID ?? "",
            "styleChoices": ParagraphStyleChoice.allCases.map { choice -> [String: Any] in
                ["choice": choice.rawValue, "label": choice.label, "id": document.styles.styleID(for: choice) ?? ""]
            },
            "fonts": document.fontNames,
            "comments": document.comments.map { comment -> [String: Any] in
                ["id": comment.id, "author": comment.author, "date": comment.date ?? "", "text": comment.text, "done": comment.isDone]
            },
            "notes": document.notes.map { ["kind": $0.kind.rawValue, "id": $0.id, "text": $0.text] },
            "unsupported": document.unsupportedFeatures.features.map(\.label).sorted(),
            "pageSetup": [
                "width": Double(document.pageSetup.width) / 20, "height": Double(document.pageSetup.height) / 20,
                "top": Double(document.pageSetup.marginTop) / 20, "bottom": Double(document.pageSetup.marginBottom) / 20,
                "left": Double(document.pageSetup.marginLeft) / 20, "right": Double(document.pageSetup.marginRight) / 20,
            ],
        ]
        if file.isText {
            result["language"] = document.sourceLanguage?.rawValue ?? SourceLanguage.plainText.rawValue
            result["languages"] = SourceLanguage.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }
            result["encoding"] = document.textEncoding.name
            result["lineEnding"] = document.lineEnding.rawValue
        }
        return result
    }

    private static func mimeType(of data: Data, name: String) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if data.starts(with: Array("RIFF".utf8)) { return "image/webp" }
        if data.starts(with: Array("BM".utf8)) { return "image/bmp" }
        let lower = name.lowercased()
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        if lower.hasSuffix(".tif") || lower.hasSuffix(".tiff") { return "image/tiff" }
        if lower.hasSuffix(".emf") { return "image/emf" }
        if lower.hasSuffix(".wmf") { return "image/wmf" }
        return "application/octet-stream"
    }
}
