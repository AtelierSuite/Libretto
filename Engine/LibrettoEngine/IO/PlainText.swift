import Foundation

/// Reads and writes plain text files: a paragraph for each line, and no
/// formatting kept.
public enum PlainText: Sendable {
    /// The font code is set in. Word sets code in Consolas, which shows here as Menlo.
    public static let codeFont = "Consolas"

    /// Runs set in the code font.
    public static var codeFormat: RunFormat {
        var style = RunStyle()
        style.fontName = codeFont
        return RunFormat(style: style)
    }

    /// The file's text, in the encoding its byte order mark names or else
    /// UTF-8, falling back to the older encodings, with every line ending made `\n`.
    public static func string(from data: Data) -> String {
        file(from: data).text
    }

    /// The file's text with every line ending made `\n`, and the encoding
    /// and line ending it was found to have, to save it back with.
    public static func file(from data: Data) -> (text: String, encoding: TextEncoding, lineEnding: LineEnding) {
        var (text, encoding) = TextEncoding.decode(data)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lineEnding = LineEnding.most(in: text)
        return (text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), encoding, lineEnding)
    }

    /// A document of the file's lines, all in `format`, keeping the file's
    /// encoding and line ending for when it is saved.
    public static func document(from data: Data, format: RunFormat = RunFormat()) -> WordDocument {
        var (text, encoding, lineEnding) = file(from: data)
        // The newline ending the last line does not start another.
        if text.hasSuffix("\n") { text.removeLast() }
        var document = WordDocument()
        document.body = body(from: text, format: format)
        document.textEncoding = encoding
        document.lineEnding = lineEnding
        return document
    }

    /// The document as a text file, in its encoding and with its line
    /// ending. Should the text have a character the encoding cannot write, it
    /// is saved in UTF-8 rather than with the character lost.
    public static func data(from document: WordDocument) -> Data {
        let text = text(of: document)
        let file = (text.isEmpty ? "" : text + "\n").replacingOccurrences(of: "\n", with: document.lineEnding.separator)
        return document.textEncoding.data(for: file) ?? Data(file.utf8)
    }

    /// The document's text, its paragraphs as lines.
    public static func text(of document: WordDocument) -> String {
        document.body.flatMap(lines(of:)).joined(separator: "\n")
    }

    /// A paragraph for each of the text's lines, all in `format`.
    public static func body(from text: String, format: RunFormat = RunFormat()) -> [Block] {
        text.components(separatedBy: "\n").map { line in
            // Lines follow one another as closely as they do in the file.
            .paragraph(Paragraph(inlines: inlines(line, format: format), properties: ParagraphProperties(spacingAfter: 0)))
        }
    }

    /// How many lines the text has: one more than its line breaks, as the
    /// empty line after a final line break is numbered too.
    public static func lineCount(of text: String) -> Int {
        var count = 1
        for unit in text.utf16 where unit == 0x0A { count += 1 }
        return count
    }

    /// Where line `number`, counting from 1, starts in the text, in UTF-16
    /// offsets. A number past either end is taken as the first or last line.
    public static func location(ofLine number: Int, in text: String) -> Int {
        guard number > 1 else { return 0 }
        var line = 1
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            line += 1
            if line == number { return offset + 1 }
        }
        // Past the last line: the start of the last.
        let string = text as NSString
        return string.lineRange(for: NSRange(location: string.length, length: 0)).location
    }

    private static func lines(of block: Block) -> [String] {
        switch block {
        case .paragraph(let paragraph):
            return [paragraph.plainText]
        case .table(let table):
            return table.rows.map { row in
                row.cells.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
            }
        case .preserved(let block):
            return [block.displayText]
        }
    }

    /// `text` as inlines in one format, with its tabs and line breaks as
    /// inlines of their own, as Word has them.
    public static func inlines(_ text: String, format: RunFormat = RunFormat(), hyperlink: Hyperlink? = nil) -> [Inline] {
        var result: [Inline] = []
        var run = ""
        func add(_ content: InlineContent) {
            result.append(Inline(content, format: format, hyperlink: hyperlink))
        }
        for character in text {
            switch character {
            case "\t", "\n":
                if !run.isEmpty { add(.text(run)) }
                run = ""
                add(character == "\t" ? .tab : .lineBreak)
            default:
                run.append(character)
            }
        }
        if !run.isEmpty { add(.text(run)) }
        return result
    }
}
