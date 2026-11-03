import Foundation

/// An edit the code editor makes in place of the one typed.
public struct CodeEdit: Equatable, Sendable {
    /// UTF-16, as `NSString` counts, in the text before the edit.
    public var range: NSRange
    public var replacement: String
    /// Where the selection ends up, in the text after the edit.
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Whether the edit only moves the selection, changing no text.
    public var movesOnly: Bool { range.length == 0 && replacement.isEmpty }
}

/// The help a code editor gives with brackets and quotes as they are typed.
///
/// An opening bracket or quote brings its closer with it, and typing the
/// closer over one put in that way steps past it rather than adding another.
/// Deleting an opener just typed takes its closer with it. Return keeps the
/// line's indent, and between a pair of brackets opens an indented line
/// between them. Brackets and quotes in strings and comments, as the
/// highlighter's tokens find them, are left alone.
public struct CodeTyping: Sendable {
    public var language: SourceLanguage {
        didSet { if language != oldValue { closers = [] } }
    }
    /// Where the closers put in for an opener are, innermost last. They are
    /// forgotten once the caret leaves the stretch of line before them.
    public private(set) var closers: [Int] = []

    public init(language: SourceLanguage) {
        self.language = language
    }

    /// Forgets the closers put in, as when the text is replaced wholesale.
    public mutating func reset() {
        closers = []
    }

    /// What to do in place of replacing `range` of `text` with `typed`, or
    /// nil to let it stand. Either way the closers put in are moved along
    /// with the text, so the edit returned must be made.
    public mutating func edit(
        replacing range: NSRange, with typed: String, in text: NSString, tokens: [SyntaxToken]
    ) -> CodeEdit? {
        let edit = proposedEdit(replacing: range, with: typed, in: text, tokens: tokens)
        let made = edit ?? CodeEdit(range: range, replacement: typed, selection: NSRange(
            location: range.location + (typed as NSString).length, length: 0
        ))
        let change = (made.replacement as NSString).length - made.range.length
        closers = closers.compactMap { closer in
            if closer >= NSMaxRange(made.range) { return closer + change }
            return closer < made.range.location ? closer : nil
        }
        if made.movesOnly {
            // Stepping past a closer is its last use.
            closers.removeAll { $0 == made.range.location }
        } else if edit != nil, typed.utf16.count == 1, made.replacement.utf16.count == 2,
                  made.replacement.utf16.first == typed.utf16.first {
            // An opener typed, and its closer with it.
            closers.append(made.range.location + 1)
        }
        return edit
    }

    /// Forgets the closers the caret is no longer before on their line.
    public mutating func selectionDidChange(_ selection: NSRange, in text: NSString) {
        guard !closers.isEmpty else { return }
        let caret = selection.location
        closers.removeAll { closer in
            guard selection.length == 0, closer >= caret, closer < text.length else { return true }
            return (caret..<closer).contains { Self.isNewline(text.character(at: $0)) }
        }
    }

    private func proposedEdit(
        replacing range: NSRange, with typed: String, in text: NSString, tokens: [SyntaxToken]
    ) -> CodeEdit? {
        let units = Array(typed.utf16)
        let isCode = language != .plainText
        let before = range.location > 0 ? text.character(at: range.location - 1) : nil
        let after = NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : nil

        if typed == "\n" {
            let line = text.lineRange(for: NSRange(location: range.location, length: 0))
            let lead = text.substring(with: NSRange(location: line.location, length: range.location - line.location))
            let indent = String(lead.prefix { $0 == " " || $0 == "\t" })
            if isCode, let before, let after, Self.closer(for: before) == after,
               !Self.isLiteral(at: range.location - 1, in: text, tokens: tokens) {
                // Return between brackets: the closer goes down a line, and the caret onto an indented one between.
                let inner = indent + Self.indentUnit(in: text)
                let selection = NSRange(location: range.location + 1 + (inner as NSString).length, length: 0)
                return CodeEdit(range: range, replacement: "\n" + inner + "\n" + indent, selection: selection)
            }
            // A new line starts as indented as the one it breaks.
            guard !indent.isEmpty else { return nil }
            let replacement = "\n" + indent
            return CodeEdit(range: range, replacement: replacement, selection: NSRange(
                location: range.location + (replacement as NSString).length, length: 0
            ))
        }

        if units.isEmpty, range.length == 1, let after, closers.contains(range.location + 1),
           case let opener = text.character(at: range.location),
           Self.closer(for: opener) == after || (Self.isQuote(opener) && opener == after) {
            // Deleting an opener just typed takes its closer with it.
            return CodeEdit(range: NSRange(location: range.location, length: 2), replacement: "", selection: NSRange(
                location: range.location, length: 0
            ))
        }

        guard isCode, units.count == 1, range.length == 0, let unit = units.first else { return nil }
        let caret = range.location

        if after == unit, closers.contains(caret) {
            return CodeEdit(range: range, replacement: "", selection: NSRange(location: caret + 1, length: 0))
        }

        let quotes = SyntaxHighlighter.quotes(for: language)
        let opensPair = Self.closer(for: unit) != nil || quotes.contains(unit)
        guard opensPair, !Self.isInsideLiteral(caret, in: text, tokens: tokens) else { return nil }
        // Only before space, the line's end, a closer or punctuation, so typing before a word adds just the one.
        if let after, !Self.isSpace(after), !Self.closingUnits.contains(after), !",;:".utf16.contains(after) {
            return nil
        }
        let closer: UInt16
        if let bracket = Self.closer(for: unit) {
            closer = bracket
        } else {
            // Not after a word or another quote, as in `don't` or the third of `"""`.
            if let before, Self.isNamePart(before) || quotes.contains(before) { return nil }
            closer = unit
        }
        let replacement = String(utf16CodeUnits: [unit, closer], count: 2)
        return CodeEdit(range: range, replacement: replacement, selection: NSRange(location: caret + 1, length: 0))
    }

    // MARK: - Matching

    /// The bracket beside `caret` and the one it pairs with, the one before
    /// the caret first, as when it has just been typed. Brackets in strings
    /// and comments are passed over.
    public static func matchingBracket(
        at caret: Int, in text: NSString, tokens: [SyntaxToken]
    ) -> (bracket: Int, match: Int)? {
        let literals = tokens.filter { isLiteral($0, in: text) }.map(\.range)
        for position in [caret - 1, caret] where position >= 0 && position < text.length {
            let unit = text.character(at: position)
            guard closer(for: unit) != nil || opener(for: unit) != nil,
                  !literals.contains(where: { NSLocationInRange(position, $0) }) else { continue }
            if let match = match(for: position, in: text, skipping: literals) { return (position, match) }
        }
        return nil
    }

    /// Where the bracket at `position` is closed or opened, counting only
    /// brackets of its kind, as the brackets of a mistyped other kind should
    /// not throw it.
    private static func match(for position: Int, in text: NSString, skipping literals: [NSRange]) -> Int? {
        let unit = text.character(at: position)
        if let closer = closer(for: unit) {
            var depth = 0
            var index = position + 1
            var next = literals.firstIndex { NSMaxRange($0) > index } ?? literals.count
            while index < text.length {
                while next < literals.count, NSMaxRange(literals[next]) <= index { next += 1 }
                if next < literals.count, literals[next].location <= index {
                    index = NSMaxRange(literals[next])
                    continue
                }
                let current = text.character(at: index)
                if current == unit {
                    depth += 1
                } else if current == closer {
                    if depth == 0 { return index }
                    depth -= 1
                }
                index += 1
            }
        } else if let opener = opener(for: unit) {
            var depth = 0
            var index = position - 1
            var previous = (literals.lastIndex { $0.location <= index }) ?? -1
            while index >= 0 {
                while previous >= 0, literals[previous].location > index { previous -= 1 }
                if previous >= 0, NSMaxRange(literals[previous]) > index {
                    index = literals[previous].location - 1
                    continue
                }
                let current = text.character(at: index)
                if current == unit {
                    depth += 1
                } else if current == opener {
                    if depth == 0 { return index }
                    depth -= 1
                }
                index -= 1
            }
        }
        return nil
    }

    // MARK: - Characters

    private static let pairs: [(open: UInt16, close: UInt16)] = [(0x28, 0x29), (0x5B, 0x5D), (0x7B, 0x7D)]
    private static let closingUnits = Set(pairs.map(\.close))

    private static func closer(for unit: UInt16) -> UInt16? {
        pairs.first { $0.open == unit }?.close
    }

    private static func opener(for unit: UInt16) -> UInt16? {
        pairs.first { $0.close == unit }?.open
    }

    private static func isQuote(_ unit: UInt16) -> Bool {
        unit == 0x22 || unit == 0x27 || unit == 0x60
    }

    private static func isNewline(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == TextCharacters.lineBreakUnit
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || isNewline(unit)
    }

    private static func isNamePart(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit >= 0x80
    }

    // MARK: - Strings and comments

    /// Whether a token is a string or a comment. JSON's and YAML's keys are
    /// strings too, though coloured as properties.
    private static func isLiteral(_ token: SyntaxToken, in text: NSString) -> Bool {
        switch token.kind {
        case .string, .comment: return true
        case .property: return token.range.length > 0 && isQuote(text.character(at: token.range.location))
        default: return false
        }
    }

    private static func isLiteral(at position: Int, in text: NSString, tokens: [SyntaxToken]) -> Bool {
        tokens.contains { NSLocationInRange(position, $0.range) && isLiteral($0, in: text) }
    }

    /// Whether typing at `caret` would be typing in a string or a comment:
    /// within one, or at the end of one left open, such as a line comment
    /// or a string not yet closed.
    private static func isInsideLiteral(_ caret: Int, in text: NSString, tokens: [SyntaxToken]) -> Bool {
        tokens.contains { token in
            guard isLiteral(token, in: text), token.range.location < caret, caret <= NSMaxRange(token.range) else {
                return false
            }
            guard caret == NSMaxRange(token.range) else { return true }
            let literal = text.substring(with: token.range)
            if token.kind == .comment {
                return !(literal.hasPrefix("/*") && literal.hasSuffix("*/") && literal.count >= 4)
                    && !(literal.hasPrefix("<!--") && literal.hasSuffix("-->") && literal.count >= 7)
            }
            let units = Array(literal.utf16)
            let isClosed = units.count >= 2 && units.last == units.first
                && (units.count == 2 || units[units.count - 2] != 0x5C)
            return !isClosed
        }
    }

    // MARK: - Indent

    /// One step of indent, as the text's first indented line has it: a tab,
    /// or as many spaces, up to eight, and four where nothing is indented.
    static func indentUnit(in text: NSString) -> String {
        var lineStart = true
        var spaces = 0
        for index in 0..<text.length {
            let unit = text.character(at: index)
            if isNewline(unit) {
                lineStart = true
                spaces = 0
            } else if lineStart, unit == 0x09, spaces == 0 {
                return "\t"
            } else if lineStart, unit == 0x20 {
                spaces += 1
            } else if lineStart {
                if spaces > 0 { return String(repeating: " ", count: min(spaces, 8)) }
                lineStart = false
            }
        }
        return "    "
    }
}
