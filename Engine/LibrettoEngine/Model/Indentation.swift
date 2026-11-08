import Foundation

/// What a code file's lines are indented with: a tab, or a number of spaces, for each level.
public enum IndentUnit: Hashable, Sendable, Identifiable {
    case tab
    case spaces(Int)

    /// The units a menu of them offers.
    public static let choices: [IndentUnit] = [.tab, .spaces(2), .spaces(4), .spaces(8)]

    /// The unit for a file whose lines say nothing of their own.
    public static let standard: IndentUnit = .spaces(4)

    /// The columns a tab moves to the next multiple of, as the editors set it.
    public static let tabWidth = 4

    /// No spaces for a tab, and otherwise how many, which is unique to each unit.
    public var id: Int {
        switch self {
        case .tab: return 0
        case .spaces(let count): return count
        }
    }

    public init?(id: Int) {
        switch id {
        case 0: self = .tab
        case 1...16: self = .spaces(id)
        default: return nil
        }
    }

    /// One level of indent.
    public var text: String {
        switch self {
        case .tab: return "\t"
        case .spaces(let count): return String(repeating: " ", count: count)
        }
    }

    /// The unit's name, as a menu of them shows it.
    public var displayName: String {
        switch self {
        case .tab: return String(localized: "Indent.Tabs", bundle: .engine)
        case .spaces(let count): return String(format: String(localized: "Indent.Spaces", bundle: .engine), count)
        }
    }

    /// The units a menu offers when this one is chosen: the usual ones, and this among them.
    public var choices: [IndentUnit] {
        Self.choices.contains(self) ? Self.choices : (Self.choices + [self]).sorted { $0.id < $1.id }
    }

    // MARK: - Detecting

    /// The unit the text's lines are indented with, or nil where none are.
    ///
    /// Tabs, if more lines start with one than with spaces. Otherwise the
    /// step most lines go in by from the line before, which is one level
    /// where a line opens a block, though not where a line is aligned with
    /// something on the one before.
    public static func detect(in text: String) -> IndentUnit? {
        var tabbed = 0
        var spaced = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        text.enumerateLines { line, _ in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(leading.count)
            // A blank line says nothing about its indent.
            guard !rest.isEmpty else { return }
            if leading.first == "\t" {
                tabbed += 1
                return
            }
            let width = leading.prefix { $0 == " " }.count
            if width > 0 { spaced += 1 }
            // The space before each `*` in a block comment lines it up, rather than indenting it.
            if rest.first == "*", width % 2 == 1 { return }
            if width > previous { steps[width - previous, default: 0] += 1 }
            previous = width
        }
        guard tabbed + spaced > 0 else { return nil }
        if tabbed >= spaced { return .tab }
        // The commonest step, the larger of any tied, as a line lined up with the one before
        // goes in by less than a level; one space is too little to be a level at all.
        let step = steps.filter { (2...8).contains($0.key) }
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key
        return .spaces(step ?? standard.id)
    }

    // MARK: - Editing

    /// Whether Tab indents the selected lines rather than typing over the selection:
    /// when the selection runs onto another line.
    public static func selectsLines(_ selection: NSRange, in text: NSString) -> Bool {
        selection.length > 0 && text.range(of: "\n", options: .literal, range: selection).location != NSNotFound
    }

    /// What Tab types at the selection: a tab, or the spaces to the next level.
    public func insertion(in text: NSString, at selection: NSRange) -> IndentEdit {
        var inserted = self.text
        if case .spaces(let count) = self {
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let column = Self.columns(of: text.substring(with: NSRange(location: line.location, length: selection.location - line.location)))
            inserted = String(repeating: " ", count: count - column % count)
        }
        let length = (inserted as NSString).length
        return IndentEdit(range: selection, replacement: inserted, selection: NSRange(location: selection.location + length, length: 0))
    }

    /// Puts a level of indent before each line the selection is on. Blank lines
    /// among several are left as they are, as they would only gain spaces at the end.
    public func indent(_ text: NSString, selection: NSRange) -> IndentEdit? {
        let block = Self.lines(of: selection, in: text)
        let isOneLine = !Self.selectsLines(selection, in: text)
        return shift(text, block: block, selection: selection) { line in
            isOneLine || !line.allSatisfy(\.isWhitespace) ? (self.text as NSString).length : 0
        }
    }

    /// Takes a level of indent from the front of each line the selection is on:
    /// a tab, or up to a level's worth of spaces.
    public func outdent(_ text: NSString, selection: NSRange) -> IndentEdit? {
        let block = Self.lines(of: selection, in: text)
        let levelWidth = if case .spaces(let count) = self { count } else { Self.tabWidth }
        return shift(text, block: block, selection: selection) { line in
            if line.first == "\t" { return -1 }
            return -line.prefix(levelWidth).prefix { $0 == " " }.count
        }
    }

    /// Changes the indent of each line in `block` by the number of characters
    /// `change` gives for it: added if positive, taken from the front if
    /// negative. Nil if no line changes.
    private func shift(_ text: NSString, block: NSRange, selection: NSRange, change: (Substring) -> Int) -> IndentEdit? {
        var replacement = ""
        var changes: [(start: Int, count: Int)] = []
        var location = block.location
        // Once round at least, for the empty line at the end of the text.
        repeat {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: range)
            let count = change(Substring(line).prefix { !$0.isNewline })
            if count > 0 {
                replacement += self.text + line
            } else {
                replacement += (line as NSString).substring(from: -count)
            }
            if count != 0 { changes.append((range.location, count)) }
            location = NSMaxRange(range)
        } while location < NSMaxRange(block)
        guard !changes.isEmpty else { return nil }

        // The selection keeps to the same characters. Its start, at the front
        // of a line, takes in the indent put there; a caret moves with the text.
        func moved(_ position: Int, keepsLineStart: Bool) -> Int {
            changes.reduce(position) { moved, change in
                if change.count > 0 {
                    return position > change.start || (position == change.start && !keepsLineStart) ? moved + change.count : moved
                }
                return moved - min(-change.count, max(0, position - change.start))
            }
        }
        let start = moved(selection.location, keepsLineStart: selection.length > 0)
        let end = moved(NSMaxRange(selection), keepsLineStart: false)
        return IndentEdit(range: block, replacement: replacement, selection: NSRange(location: start, length: end - start))
    }

    /// The lines the selection is on. A selection ending at the start of a
    /// line, just after the line break before it, is not on that line.
    static func lines(of selection: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        return text.lineRange(for: NSRange(location: selection.location, length: end - selection.location))
    }

    /// The columns `text` takes up, with tabs moving on to the next tab stop.
    static func columns(of text: String) -> Int {
        text.reduce(0) { column, character in
            character == "\t" ? column + tabWidth - column % tabWidth : column + 1
        }
    }
}

/// An edit to a text: the characters it replaces, what it puts in their
/// place, and the selection afterwards.
public struct IndentEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
}
