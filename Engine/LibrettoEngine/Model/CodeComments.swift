import Foundation

/// Comments lines of source code out, and back in, as ⌘/ does in a code
/// editor: with the language's line comment, each line commented at the
/// indent of the least indented, or where the language has none, as in HTML
/// and CSS, with a block comment around the lot.
public enum CodeComments {
    /// A change to the text: what to replace, with what, and what to select afterwards.
    public struct Edit: Equatable, Sendable {
        /// In the text as it was, UTF-16, as `NSString` counts.
        public var range: NSRange
        public var replacement: String
        /// In the text as it is after the change.
        public var selection: NSRange
    }

    /// Comments out the lines `selection` touches, or uncomments them where
    /// every one is commented already. Nothing for a language without
    /// comments, or where there is nothing to wrap in a block comment.
    public static func toggle(in text: String, selection: NSRange, language: SourceLanguage) -> Edit? {
        guard let markers = language.commentMarkers else { return nil }
        let string = text as NSString
        let lines = lines(of: string, touchedBy: selection)
        let changes: [Change]
        if let marker = markers.line.first {
            changes = toggleLines(lines, in: string, marker: marker, markers: markers.line)
        } else if let open = markers.blockOpen, let close = markers.blockClose {
            changes = toggleBlock(lines, in: string, open: open, close: close)
        } else {
            return nil
        }
        guard let first = changes.first, let last = changes.last else { return nil }

        let range = NSRange(location: first.location, length: last.location + last.length - first.location)
        var replacement = ""
        var location = range.location
        for change in changes {
            replacement += string.substring(with: NSRange(location: location, length: change.location - location))
            replacement += change.insertion
            location = change.location + change.length
        }

        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: map(selection.location, through: changes, staysBefore: false), length: 0)
        } else {
            let start = map(selection.location, through: changes, staysBefore: true)
            let end = map(NSMaxRange(selection), through: changes, staysBefore: false)
            newSelection = NSRange(location: start, length: max(0, end - start))
        }
        return Edit(range: range, replacement: replacement, selection: newSelection)
    }

    // MARK: - Lines

    /// A line of the text, without its line break.
    private struct Line {
        var start: Int
        var end: Int
        /// Where the line's text starts after its spaces and tabs.
        var textStart: Int
        var isBlank: Bool { textStart == end }
    }

    /// Something removed from the text, and what goes in its place, in the text as it was.
    private struct Change {
        var location: Int
        var length: Int
        var insertion: String
    }

    private static func lines(of string: NSString, touchedBy selection: NSRange) -> [Line] {
        var touched = selection
        // Lines selected whole end at the start of the next, which is not taken in with them.
        if touched.length > 0, isLineBreak(string.character(at: NSMaxRange(touched) - 1)) {
            touched.length -= 1
        }
        let lineRange = string.lineRange(for: touched)
        var lines: [Line] = []
        var location = lineRange.location
        repeat {
            var start = 0, next = 0, end = 0
            string.getLineStart(&start, end: &next, contentsEnd: &end, for: NSRange(location: location, length: 0))
            var textStart = start
            while textStart < end, isIndent(string.character(at: textStart)) { textStart += 1 }
            lines.append(Line(start: start, end: end, textStart: textStart))
            location = next
        } while location < NSMaxRange(lineRange)
        return lines
    }

    private static func toggleLines(_ lines: [Line], in string: NSString, marker: String, markers: [String]) -> [Change] {
        // Blank lines are left as they are, unless they are all there is.
        let written = lines.filter { !$0.isBlank }
        let targets = written.isEmpty ? lines : written
        let found = written.isEmpty ? [] : targets.map { line in
            markers.first { string.hasText($0, at: line.textStart, before: line.end) }
        }
        if !found.isEmpty, found.allSatisfy({ $0 != nil }) {
            return zip(targets, found).map { line, marker in
                var length = (marker! as NSString).length
                // The space a comment is written with goes with it.
                if string.hasText(" ", at: line.textStart + length, before: line.end) { length += 1 }
                return Change(location: line.textStart, length: length, insertion: "")
            }
        }
        let indent = targets.map { $0.textStart - $0.start }.min() ?? 0
        return targets.map { Change(location: $0.start + indent, length: 0, insertion: marker + " ") }
    }

    private static func toggleBlock(_ lines: [Line], in string: NSString, open: String, close: String) -> [Change] {
        guard let first = lines.first(where: { !$0.isBlank }), let last = lines.last(where: { !$0.isBlank }) else {
            return []
        }
        let start = first.textStart
        var end = last.end
        while end > last.textStart, isIndent(string.character(at: end - 1)) { end -= 1 }
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length
        if end - start >= openLength + closeLength, string.hasText(open, at: start, before: end),
           string.hasText(close, at: end - closeLength, before: end) {
            var opening = openLength
            var closing = closeLength
            if string.hasText(" ", at: start + opening, before: end - closing) { opening += 1 }
            if string.hasText(" ", at: end - closing - 1, before: end - closing), end - closing - 1 >= start + opening {
                closing += 1
            }
            return [
                Change(location: start, length: opening, insertion: ""),
                Change(location: end - closing, length: closing, insertion: ""),
            ]
        }
        return [
            Change(location: start, length: 0, insertion: open + " "),
            Change(location: end, length: 0, insertion: " " + close),
        ]
    }

    /// Where `point` ends up once `changes` are made. A point where something
    /// is put in stays before it if `staysBefore`, as the start of a
    /// selection does, and otherwise moves past it.
    private static func map(_ point: Int, through changes: [Change], staysBefore: Bool) -> Int {
        var shift = 0
        for change in changes {
            let end = change.location + change.length
            let inserted = (change.insertion as NSString).length
            if point > end || (point == end && !(change.length == 0 && staysBefore)) {
                shift += inserted - change.length
            } else if point > change.location {
                // Inside what was taken out.
                shift += change.location - point
            }
        }
        return point + shift
    }

    private static func isIndent(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}

private extension NSString {
    /// Whether `text` is at `location`, ending by `limit`.
    func hasText(_ text: String, at location: Int, before limit: Int) -> Bool {
        let count = (text as NSString).length
        guard location >= 0, location + count <= limit else { return false }
        return substring(with: NSRange(location: location, length: count)) == text
    }
}
