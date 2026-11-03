import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What a stretch of source code is, for colouring.
public enum SyntaxKind: Sendable {
    case keyword
    case type
    case string
    case comment
    case number
    /// Swift attributes, Python decorators, CSS classes and IDs.
    case attribute
    /// HTML tags and CSS element selectors.
    case tag
    /// HTML attribute names and CSS properties.
    case property
    /// Shell variables.
    case variable
}

public struct SyntaxToken: Equatable, Sendable {
    /// UTF-16, as `NSString` counts.
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Finds the keywords, strings, comments and the rest in source code.
///
/// It reads the text in one pass, without parsing it, which is enough to
/// colour code as an editor does and quick enough to run on every keystroke.
/// Line separators count as line ends, so it reads the editor's text as well
/// as a file's.
public enum SyntaxHighlighter: Sendable {
    public static func tokens(in text: String, language: SourceLanguage) -> [SyntaxToken] {
        SyntaxHighlights(text, language: language).tokens
    }

    /// The quotes that start a string in `language`: the first character of
    /// each of its string delimiters. Plain text has none.
    public static func quotes(for language: SourceLanguage) -> Set<UInt16> {
        switch language {
        case .plainText: return []
        case .html, .xml, .css, .scss, .less: return [0x22, 0x27]
        default: return Set(CodeRules(language).strings.compactMap { $0.delimiter.utf16.first })
        }
    }

    /// Colours `text` by its syntax, and what is not syntax in `plainColor`.
    /// Only what changes colour is touched, so the layout of the rest stands.
    public static func apply(
        _ language: SourceLanguage, to text: NSMutableAttributedString, scheme: ColorScheme, plainColor: PlatformColor
    ) {
        let highlights = SyntaxHighlights(text.string, language: language)
        color(
            text, with: highlights.tokens[...], in: NSRange(location: 0, length: text.length),
            scheme: scheme, plainColor: plainColor
        )
    }

    /// Colours `range` of `text` by `tokens`, which lie within it, and the
    /// rest of it in `plainColor`.
    fileprivate static func color(
        _ text: NSMutableAttributedString, with tokens: ArraySlice<SyntaxToken>, in range: NSRange,
        scheme: ColorScheme, plainColor: PlatformColor
    ) {
        var colors: [SyntaxKind: PlatformColor] = [:]
        var segments: [(range: NSRange, color: PlatformColor)] = []
        var location = range.location
        let end = NSMaxRange(range)
        for token in tokens where NSMaxRange(token.range) > location {
            let start = max(location, token.range.location)
            if start > location { segments.append((NSRange(location: location, length: start - location), plainColor)) }
            let color = colors[token.kind] ?? color(for: token.kind, scheme: scheme)
            colors[token.kind] = color
            segments.append((NSRange(location: start, length: NSMaxRange(token.range) - start), color))
            location = NSMaxRange(token.range)
        }
        if location < end { segments.append((NSRange(location: location, length: end - location), plainColor)) }

        text.beginEditing()
        for segment in segments {
            var effective = NSRange()
            let current = text.attribute(
                .foregroundColor, at: segment.range.location, longestEffectiveRange: &effective, in: segment.range
            ) as? PlatformColor
            if current != segment.color || effective != segment.range {
                text.addAttribute(.foregroundColor, value: segment.color, range: segment.range)
            }
        }
        text.endEditing()
    }

    /// Xcode's default colours, light and dark, darkened or lightened in
    /// their own hue where they fell short of a contrast of 7.5:1 against
    /// white, or 10:1 against black.
    public static func color(for kind: SyntaxKind, scheme: ColorScheme) -> PlatformColor {
        let dark = scheme == .dark
        let hex: UInt32
        switch kind {
        case .keyword: hex = dark ? 0xFF91BF : 0x912189
        case .type: hex = dark ? 0xDABAFF : 0x3900A0
        case .string: hex = dark ? 0xFF978A : 0xA81613
        case .comment: hex = dark ? 0xACB5BC : 0x4A5660
        case .number: hex = dark ? 0xD9C97C : 0x1C00CF
        case .attribute: hex = dark ? 0xD6AB85 : 0x6D5003
        case .tag: hex = dark ? 0x5DD8FF : 0x0D5786
        case .property: hex = dark ? 0x7CC1B0 : 0x2A5B60
        case .variable: hex = dark ? 0xC8A7F0 : 0x6C36A9
        }
        return PlatformColor.sRGB(
            red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

/// What a scan of a text found, kept so that after an edit the scan can
/// start again a little before it and stop a little after it, rather than
/// read the whole text again.
public struct SyntaxHighlights: Sendable {
    public let language: SourceLanguage
    public fileprivate(set) var tokens: [SyntaxToken]
    /// UTF-16 units, as `NSString` counts.
    public fileprivate(set) var length: Int
    /// Where the scan was at the start of each line it reached outside
    /// anything that spans lines, in order: the points it can start from
    /// again, and stop at.
    fileprivate var checkpoints: [Checkpoint]

    public init(_ text: String, language: SourceLanguage) {
        self.language = language
        var scanner = Scanner(units: Scanner.units(of: text))
        length = scanner.units.count
        if language != .plainText { scanner.scan(language) }
        tokens = scanner.tokens
        checkpoints = scanner.checkpoints
    }

    /// Scans `text` again after an edit to the text these were found in:
    /// `range` is what the edit left, in `text`, and `delta` how much longer
    /// it made it. Only the lines around the edit are read, from where the
    /// scan last read nothing the edit changed to where it is back where it
    /// was before; the rest of the tokens stand, moved along by the edit.
    ///
    /// Returns which tokens were found again, and the part of `text` they
    /// lie in, which is all that may be coloured differently.
    public mutating func update(
        _ text: String, edited range: NSRange, changeInLength delta: Int
    ) -> (tokens: Range<Int>, text: NSRange) {
        let units = Scanner.units(of: text)
        precondition(units.count == length + delta && NSMaxRange(range) <= units.count, "The edit is not to this text")
        let oldLength = length
        length = units.count
        guard language != .plainText else { return (0..<0, range) }

        // The last line start at or before the edit that the scan reached
        // reading nothing from the edit on. Running into the end of the text
        // counts as reading past it, as text added there could change it.
        let start = range.location
        var restart = checkpoints.count(atOrBefore: start) - 1
        while restart >= 0, checkpoints[restart].reach >= min(start, oldLength - 1) { restart -= 1 }
        let from = restart >= 0 ? checkpoints[restart] : Checkpoint(index: 0, reach: -1, tokenCount: 0)

        var scanner = Scanner(units: units)
        scanner.units.reach = from.reach
        scanner.tokenBase = from.tokenCount
        // It can stop only past the edit. The line's end before each
        // checkpoint is read there, but any line's end reads the same.
        scanner.resume = Scanner.Resume(
            checkpoints: checkpoints, cursor: max(restart, 0), delta: delta, after: NSMaxRange(range)
        )
        scanner.scan(language, from: from)
        let resumed = scanner.resume?.resumed
        let found = scanner.tokens
        let marked = scanner.checkpoints
        let reach = scanner.units.reach
        scanner = Scanner(units: [])

        // The earlier scan's tokens and checkpoints from where this one
        // caught up with it, moved along by the edit.
        let oldTokenEnd = resumed.map { checkpoints[$0].tokenCount } ?? tokens.count
        let textEnd = resumed.map { checkpoints[$0].index + delta } ?? units.count
        let tokenShift = found.count - (oldTokenEnd - from.tokenCount)
        tokens.replaceSubrange(from.tokenCount..<oldTokenEnd, with: found)
        for index in (from.tokenCount + found.count)..<tokens.count { tokens[index].range.location += delta }
        let firstMarked = max(restart, 0)
        checkpoints.replaceSubrange(firstMarked..<(resumed ?? checkpoints.count), with: marked)
        for index in (firstMarked + marked.count)..<checkpoints.count {
            checkpoints[index].index += delta
            checkpoints[index].reach = max(reach, checkpoints[index].reach + delta)
            checkpoints[index].tokenCount += tokenShift
        }
        return (from.tokenCount..<(from.tokenCount + found.count), NSRange(location: from.index, length: textEnd - from.index))
    }
}

/// A text's colouring by its syntax, kept from one edit to the next so
/// that each scans again only the lines around it.
///
/// Tell it of each edit as the text storage reports it, and colour the text
/// once the edits are done.
public struct SyntaxColoring: Sendable {
    private var highlights: SyntaxHighlights?
    private var scheme: ColorScheme?
    /// What the edits since the last colouring left, in the text as it is
    /// now, and how much longer they made it.
    private var edit: (range: NSRange, changeInLength: Int)?

    public init() {}

    /// What the text was last coloured by, which is nothing before it is first coloured.
    public var tokens: [SyntaxToken] { highlights?.tokens ?? [] }

    /// Notes an edit to the text's characters: `range` is what it left, and
    /// `delta` how much longer it made the text.
    public mutating func noteEdit(_ range: NSRange, changeInLength delta: Int) {
        guard let edit else {
            self.edit = (range, delta)
            return
        }
        // The edits so far, moved along by this one, and this one.
        let replacedEnd = NSMaxRange(range) - delta
        let start = min(edit.range.location, range.location)
        let end = max(NSMaxRange(edit.range) >= replacedEnd ? NSMaxRange(edit.range) + delta : 0, NSMaxRange(range))
        self.edit = (NSRange(location: start, length: end - start), edit.changeInLength + delta)
    }

    /// Colours `text` as `SyntaxHighlighter.apply` does, scanning only
    /// around the edits since it was last coloured when it can: when the
    /// language and scheme are the same, and the edits are all accounted for.
    public mutating func apply(
        _ language: SourceLanguage, to text: NSMutableAttributedString, scheme: ColorScheme, plainColor: PlatformColor
    ) {
        let edit = self.edit
        self.edit = nil
        if let edit, var highlights, highlights.language == language, self.scheme == scheme,
           highlights.length + edit.changeInLength == text.length, NSMaxRange(edit.range) <= text.length {
            // Held only here while it changes, so it changes in place.
            self.highlights = nil
            let changed = highlights.update(text.string, edited: edit.range, changeInLength: edit.changeInLength)
            SyntaxHighlighter.color(
                text, with: highlights.tokens[changed.tokens], in: changed.text, scheme: scheme, plainColor: plainColor
            )
            self.highlights = highlights
        } else {
            let highlights = SyntaxHighlights(text.string, language: language)
            SyntaxHighlighter.color(
                text, with: highlights.tokens[...], in: NSRange(location: 0, length: text.length),
                scheme: scheme, plainColor: plainColor
            )
            self.highlights = highlights
            self.scheme = scheme
        }
    }
}

/// A point the scan reached at the start of a line.
fileprivate struct Checkpoint: Sendable {
    var index: Int
    /// The furthest unit read on the way here, past which what was found
    /// so far depends on nothing.
    var reach: Int
    /// How many tokens were found before here.
    var tokenCount: Int
    var state = ScanState()
}

fileprivate extension [Checkpoint] {
    /// How many are at `index` or before it.
    func count(atOrBefore index: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].index <= index { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// What the scan holds besides where it is: for CSS, how deep in blocks it
/// is and whether the statement is a selector.
fileprivate struct ScanState: Equatable, Sendable {
    var depth = 0
    var isSelector: Bool?
}

// MARK: - Languages

/// How a language marks a comment: a line comment where it has one, and
/// otherwise, as in HTML and CSS, a block comment.
public struct CommentMarkers: Equatable, Sendable {
    /// Every marker that starts a line comment, the one to write first.
    public var line: [String]
    public var blockOpen: String?
    public var blockClose: String?
}

extension SourceLanguage {
    /// Nothing for plain text, which has no comments.
    public var commentMarkers: CommentMarkers? {
        let rules = CodeRules(self)
        guard !rules.lineComments.isEmpty || rules.blockComment != nil else { return nil }
        return CommentMarkers(
            line: rules.lineComments, blockOpen: rules.blockComment?.open, blockClose: rules.blockComment?.close
        )
    }
}

private struct CodeRules {
    struct StringRule {
        public var delimiter: String
        public var spansLines: Bool
        public var escapes = true
    }

    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    /// Longest delimiters first, so `"""` is not taken for an empty string.
    var strings: [StringRule]
    var keywords: Set<String>
    /// Names of built-in types that are not capitalised, like C's `int`.
    var types: Set<String> = []
    /// Capitalised names are types, as they are by convention.
    var capitalisedTypes = true
    /// SQL: keywords in any case, held here in lower case.
    var ignoresCase = false
    /// Characters that make the name after them an attribute: `@` for Swift
    /// attributes and decorators.
    var attributePrefix: Character?
    /// Characters that make the name after them a keyword: `#` for Swift's
    /// compiler directives and C's preprocessor.
    var directivePrefix: Character?
    /// The character that starts a variable: `$` in shell scripts, PHP and Ruby.
    var variablePrefix: Character?
    /// Shell and YAML: a comment only starts at the start of a word, and words run on through hyphens.
    var commentsStartWords = false
    /// Shell: `$?`, `$@` and the like are variables too.
    var isShell = false
    /// JSON and YAML: a string or name before a colon is a key, coloured as a property.
    var colonsMarkKeys = false

    init(_ language: SourceLanguage) {
        let quoted = [StringRule(delimiter: "\"", spansLines: false), StringRule(delimiter: "'", spansLines: false)]
        let cStyle = (open: "/*", close: "*/")
        switch language {
        case .swift:
            lineComments = ["//"]
            blockComment = cStyle
            strings = [StringRule(delimiter: "\"\"\"", spansLines: true), quoted[0]]
            keywords = Self.swift
            attributePrefix = "@"
            directivePrefix = "#"
        case .python:
            lineComments = ["#"]
            strings = [
                StringRule(delimiter: "\"\"\"", spansLines: true), StringRule(delimiter: "'''", spansLines: true),
            ] + quoted
            keywords = Self.python
            attributePrefix = "@"
        case .javaScript, .typeScript:
            lineComments = ["//"]
            blockComment = cStyle
            strings = quoted + [StringRule(delimiter: "`", spansLines: true)]
            keywords = language == .typeScript ? Self.javaScript.union(Self.typeScript) : Self.javaScript
            attributePrefix = language == .typeScript ? "@" : nil
        case .shell:
            lineComments = ["#"]
            strings = [
                StringRule(delimiter: "\"", spansLines: true),
                StringRule(delimiter: "'", spansLines: true, escapes: false),
            ]
            keywords = Self.shell
            capitalisedTypes = false
            variablePrefix = "$"
            commentsStartWords = true
            isShell = true
        case .c, .cPlusPlus, .objectiveC:
            lineComments = ["//"]
            blockComment = cStyle
            strings = quoted
            keywords = switch language {
            case .cPlusPlus: Self.c.union(Self.cPlusPlus)
            case .objectiveC: Self.c.union(Self.objectiveC)
            default: Self.c
            }
            types = Self.cTypes
            directivePrefix = "#"
            // Objective-C's `@interface`, `@property` and the rest.
            attributePrefix = language == .objectiveC ? "@" : nil
        case .cSharp:
            lineComments = ["//"]
            blockComment = cStyle
            strings = [StringRule(delimiter: "\"\"\"", spansLines: true)] + quoted
            keywords = Self.cSharp
            types = Self.cSharpTypes
            directivePrefix = "#"
        case .java, .kotlin:
            lineComments = ["//"]
            blockComment = cStyle
            strings = [StringRule(delimiter: "\"\"\"", spansLines: true, escapes: language == .java)] + quoted
            keywords = language == .java ? Self.java : Self.kotlin
            types = language == .java ? Self.javaTypes : []
            attributePrefix = "@"
        case .go:
            lineComments = ["//"]
            blockComment = cStyle
            strings = quoted + [StringRule(delimiter: "`", spansLines: true, escapes: false)]
            keywords = Self.go
            types = Self.goTypes
            // Capitals mark what a package exports, not its types.
            capitalisedTypes = false
        case .rust:
            lineComments = ["//"]
            blockComment = cStyle
            // `'` starts lifetimes as well as characters, so only double quotes make strings.
            strings = [StringRule(delimiter: "\"", spansLines: true)]
            keywords = Self.rust
            types = Self.rustTypes
        case .ruby:
            lineComments = ["#"]
            strings = quoted
            keywords = Self.ruby
            // Instance variables, coloured as attributes are elsewhere.
            attributePrefix = "@"
            variablePrefix = "$"
        case .php:
            lineComments = ["//", "#"]
            blockComment = cStyle
            strings = [
                StringRule(delimiter: "\"", spansLines: true),
                StringRule(delimiter: "'", spansLines: true),
            ]
            keywords = Self.php
            variablePrefix = "$"
        case .sql:
            lineComments = ["--"]
            blockComment = cStyle
            strings = quoted
            keywords = Self.sql
            capitalisedTypes = false
            ignoresCase = true
        case .json:
            // Comments, and JSON5's single quotes, for `tsconfig.json`, VS Code's settings, `.jsonc` and `.json5`.
            lineComments = ["//"]
            blockComment = cStyle
            strings = quoted
            keywords = ["true", "false", "null"]
            capitalisedTypes = false
            colonsMarkKeys = true
        case .yaml:
            lineComments = ["#"]
            strings = [quoted[0], StringRule(delimiter: "'", spansLines: false, escapes: false)]
            keywords = ["true", "false", "null", "yes", "no", "on", "off"]
            capitalisedTypes = false
            commentsStartWords = true
            colonsMarkKeys = true
        case .plainText, .html, .css, .less, .scss, .xml:
            // HTML, XML and CSS and its dialects are scanned on their own; their comments are here for commenting
            // lines out, with SCSS's and Less's `//`.
            lineComments = language == .scss || language == .less ? ["//"] : []
            blockComment = switch language {
            case .html, .xml: (open: "<!--", close: "-->")
            case .css, .scss, .less: cStyle
            default: nil
            }
            strings = quoted
            keywords = []
        }
    }

    static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "consume",
        "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "each", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import",
        "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating",
        "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "postfix",
        "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
        "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
    ]
    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None",
        "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    static let javaScript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "import",
        "in", "instanceof", "let", "new", "null", "of", "return", "set", "static", "super", "switch", "this",
        "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]
    static let typeScript: Set<String> = [
        "abstract", "any", "as", "asserts", "bigint", "boolean", "declare", "enum", "implements", "infer",
        "interface", "is", "keyof", "module", "namespace", "never", "number", "object", "override", "private",
        "protected", "public", "readonly", "satisfies", "string", "symbol", "type", "unique", "unknown",
    ]
    static let shell: Set<String> = [
        "alias", "break", "case", "cd", "continue", "declare", "do", "done", "echo", "elif", "else", "esac", "eval",
        "exec", "exit", "export", "false", "fi", "for", "function", "if", "in", "local", "printf", "read",
        "readonly", "return", "select", "set", "shift", "source", "then", "time", "trap", "true", "typeset",
        "unset", "until", "while",
    ]
    static let c: Set<String> = [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "false", "for",
        "goto", "if", "inline", "NULL", "register", "restrict", "return", "sizeof", "static", "struct", "switch",
        "true", "typedef", "union", "volatile", "while",
    ]
    static let cTypes: Set<String> = [
        "bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "size_t",
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    ]
    static let cPlusPlus: Set<String> = [
        "alignas", "alignof", "catch", "class", "constexpr", "consteval", "constinit", "const_cast", "co_await",
        "co_return", "co_yield", "decltype", "delete", "dynamic_cast", "explicit", "export", "final", "friend",
        "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "override", "private", "protected",
        "public", "reinterpret_cast", "static_assert", "static_cast", "template", "this", "throw", "try",
        "typename", "using", "virtual",
    ]
    static let objectiveC: Set<String> = [
        "id", "instancetype", "nil", "Nil", "self", "super", "YES", "NO", "BOOL", "SEL", "IMP",
        "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable", "nonnull",
    ]
    static let cSharp: Set<String> = [
        "abstract", "as", "async", "await", "base", "break", "case", "catch", "checked", "class", "const",
        "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "false", "finally",
        "fixed", "for", "foreach", "get", "goto", "if", "implicit", "in", "init", "interface", "internal", "is",
        "lock", "namespace", "new", "null", "operator", "out", "override", "params", "partial", "private",
        "protected", "public", "readonly", "record", "ref", "return", "sealed", "set", "sizeof", "stackalloc",
        "static", "struct", "switch", "this", "throw", "true", "try", "typeof", "unchecked", "unsafe", "using",
        "value", "var", "virtual", "volatile", "when", "where", "while", "yield",
    ]
    static let cSharpTypes: Set<String> = [
        "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "object", "sbyte", "short",
        "string", "uint", "ulong", "ushort", "void",
    ]
    static let java: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else",
        "enum", "extends", "false", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof",
        "interface", "native", "new", "null", "package", "permits", "private", "protected", "public", "record",
        "return", "sealed", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws",
        "transient", "true", "try", "var", "volatile", "while", "yield",
    ]
    static let javaTypes: Set<String> = ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void"]
    static let kotlin: Set<String> = [
        "abstract", "annotation", "as", "break", "by", "catch", "class", "companion", "const", "constructor",
        "continue", "crossinline", "data", "do", "else", "enum", "external", "false", "final", "finally", "for",
        "fun", "get", "if", "import", "in", "infix", "init", "inline", "inner", "interface", "internal", "is",
        "lateinit", "noinline", "null", "object", "open", "operator", "out", "override", "package", "private",
        "protected", "public", "reified", "return", "sealed", "set", "super", "suspend", "this", "throw", "true",
        "try", "typealias", "val", "value", "var", "vararg", "when", "where", "while",
    ]
    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return",
        "select", "struct", "switch", "true", "type", "var",
    ]
    static let goTypes: Set<String> = [
        "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
        "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
    ]
    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    static let rustTypes: Set<String> = [
        "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16", "u32", "u64",
        "u128", "usize",
    ]
    static let ruby: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end",
        "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "require", "rescue",
        "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
    ]
    static let php: Set<String> = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const",
        "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "false",
        "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include",
        "include_once", "instanceof", "interface", "isset", "list", "match", "namespace", "new", "null", "or",
        "php", "print", "private", "protected", "public", "readonly", "require", "require_once", "return",
        "static", "switch", "throw", "trait", "true", "try", "unset", "use", "var", "while", "yield",
    ]
    static let sql: Set<String> = [
        "add", "all", "alter", "and", "as", "asc", "between", "by", "case", "check", "column", "constraint",
        "create", "cross", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
        "false", "foreign", "from", "full", "group", "having", "if", "in", "index", "inner", "insert", "into", "is",
        "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary",
        "references", "right", "select", "set", "table", "then", "true", "union", "unique", "update", "values",
        "view", "when", "where", "with",
        "bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "double", "float", "int", "integer",
        "numeric", "real", "smallint", "text", "time", "timestamp", "varchar",
    ]
}

// MARK: - Scanning

private struct Scanner {
    /// The text, noting how far into it the scan has read.
    struct Units {
        let storage: [UInt16]
        /// The furthest unit read, or looked for past the end.
        var reach = -1

        var count: Int { storage.count }

        subscript(index: Int) -> UInt16 {
            mutating get {
                reach = max(reach, index)
                return storage[index]
            }
        }

        subscript(range: Range<Int>) -> ArraySlice<UInt16> {
            mutating get {
                reach = max(reach, range.upperBound - 1)
                return storage[range]
            }
        }
    }

    /// Where an earlier scan of the text before an edit can be taken up
    /// again: at a checkpoint past the edit where that scan held what this
    /// one does.
    struct Resume {
        let checkpoints: [Checkpoint]
        var cursor: Int
        /// How much longer the edit made the text.
        let delta: Int
        /// The first point, in the edited text, it may be taken up at.
        let after: Int
        /// The checkpoint it was taken up at.
        var resumed: Int?
    }

    var units: Units
    var tokens: [SyntaxToken] = []
    /// How many tokens were found before this scan started.
    var tokenBase = 0
    var checkpoints: [Checkpoint] = []
    var resume: Resume?

    init(units: [UInt16]) {
        self.units = Units(storage: units)
    }

    static func units(of text: String) -> [UInt16] {
        // Through `NSString`, which copies a text storage's characters in one go.
        let string = text as NSString
        var units = [UInt16](repeating: 0, count: string.length)
        string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
        return units
    }

    /// Scans the text as `language`, from its start or from a checkpoint.
    mutating func scan(_ language: SourceLanguage, from start: Checkpoint? = nil) {
        let all = 0..<units.count
        switch language {
        case .html: scanHTML(all, from: start?.index ?? 0)
        case .xml: scanHTML(all, isXML: true, from: start?.index ?? 0)
        case .css, .scss, .less:
            let dialect: CSSDialect = language == .scss ? .scss : language == .less ? .less : .css
            scanCSS(all, dialect: dialect, from: start ?? Checkpoint(index: 0, reach: -1, tokenCount: 0))
        default: scanCode(all, rules: CodeRules(language), from: start?.index ?? 0)
        }
    }

    private mutating func add(_ range: Range<Int>, _ kind: SyntaxKind) {
        guard !range.isEmpty else { return }
        tokens.append(SyntaxToken(range: NSRange(location: range.lowerBound, length: range.count), kind: kind))
    }

    /// At the start of a line, at the top level of the text, notes where
    /// the scan is for a later one to start from; or, after an edit, stops
    /// it if the earlier scan was here too, holding the same, to take that
    /// up from here instead. Whether to stop.
    private mutating func checkpoint(_ index: Int, _ state: ScanState = ScanState()) -> Bool {
        // Looking back for the line's start reads nothing the scan goes by.
        guard index == 0 || isNewline(units.storage[index - 1]) else { return false }
        if var resume, index >= resume.after {
            let target = index - resume.delta
            while resume.cursor < resume.checkpoints.count, resume.checkpoints[resume.cursor].index < target {
                resume.cursor += 1
            }
            if resume.cursor < resume.checkpoints.count, resume.checkpoints[resume.cursor].index == target,
               resume.checkpoints[resume.cursor].state == state {
                resume.resumed = resume.cursor
                self.resume = resume
                return true
            }
            self.resume = resume
        }
        checkpoints.append(Checkpoint(index: index, reach: units.reach, tokenCount: tokenBase + tokens.count, state: state))
        return false
    }

    // MARK: Characters

    private mutating func unit(_ index: Int) -> UInt16? {
        units.reach = max(units.reach, index)
        return index >= 0 && index < units.count ? units.storage[index] : nil
    }

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue!)
    }

    private func isNewline(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == TextCharacters.lineBreakUnit
    }

    private func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || isNewline(unit)
    }

    private func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
            // Beyond ASCII, anything not a separator or a stand-in for a picture.
            || (unit >= 0x80 && unit != TextCharacters.lineBreakUnit && unit != TextCharacters.attachmentUnit)
    }

    private func isNamePart(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit)
    }

    private mutating func matches(_ text: String, at index: Int, ignoringCase: Bool = false) -> Bool {
        var position = index
        for expected in text.utf16 {
            guard let actual = unit(position) else { return false }
            if ignoringCase ? lowercased(actual) != lowercased(expected) : actual != expected { return false }
            position += 1
        }
        return true
    }

    private func lowercased(_ unit: UInt16) -> UInt16 {
        unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
    }

    private mutating func first(_ text: String, from index: Int, before end: Int, ignoringCase: Bool = false) -> Int? {
        var position = index
        while position < end {
            if matches(text, at: position, ignoringCase: ignoringCase) { return position }
            position += 1
        }
        return nil
    }

    private mutating func lineEnd(from index: Int, before end: Int) -> Int {
        var position = index
        while position < end, !isNewline(units[position]) { position += 1 }
        return position
    }

    private mutating func nameEnd(from index: Int, before end: Int, extra: Set<UInt16> = []) -> Int {
        var position = index
        while position < end, isNamePart(units[position]) || extra.contains(units[position]) { position += 1 }
        return position
    }

    private mutating func word(_ range: Range<Int>) -> String {
        String(utf16CodeUnits: Array(units[range]), count: range.count)
    }

    /// A number from `index`: digits, with the letters of hex, exponents and
    /// suffixes, and a point only where a digit follows it.
    private mutating func numberEnd(from index: Int, before end: Int) -> Int {
        var position = index
        while position < end {
            let current = units[position]
            if isNamePart(current) {
                position += 1
            } else if current == Self.ascii("."), let next = unit(position + 1), isDigit(next) {
                position += 1
            } else {
                break
            }
        }
        return min(position, end)
    }

    /// A quoted string from `index`, which is its opening delimiter.
    private mutating func stringEnd(_ rule: CodeRules.StringRule, from index: Int, before end: Int) -> Int {
        let delimiter = rule.delimiter
        var position = index + delimiter.utf16.count
        while position < end {
            let current = units[position]
            if rule.escapes, current == Self.ascii("\\") {
                // What is escaped matters only in that it is there.
                units.reach = max(units.reach, position + 1)
                position += 2
                continue
            }
            if matches(delimiter, at: position) { return position + delimiter.utf16.count }
            if !rule.spansLines, isNewline(current) { return position }
            position += 1
        }
        return end
    }

    // MARK: Code

    /// Scans `range` as code, from `start` if this is the whole text, where
    /// it marks checkpoints.
    mutating func scanCode(_ range: Range<Int>, rules: CodeRules, from start: Int? = nil) {
        let end = range.upperBound
        var index = start ?? range.lowerBound
        scanning: while index < end {
            if start != nil, checkpoint(index) { return }
            let current = units[index]
            let previous = index > range.lowerBound ? units[index - 1] : 0x20

            if let (open, close) = rules.blockComment, matches(open, at: index) {
                let closing = first(close, from: index + open.utf16.count, before: end).map { $0 + close.utf16.count }
                let stop = min(closing ?? end, end)
                add(index..<stop, .comment)
                index = stop
                continue
            }
            for comment in rules.lineComments where matches(comment, at: index)
                && (!rules.commentsStartWords || isSpace(previous) || index == range.lowerBound) {
                let stop = lineEnd(from: index, before: end)
                add(index..<stop, .comment)
                index = stop
                continue scanning
            }
            for rule in rules.strings where matches(rule.delimiter, at: index) {
                let stop = stringEnd(rule, from: index, before: end)
                let marksKey = rules.colonsMarkKeys && isKey(endingAt: stop, before: end, spaced: true)
                add(index..<stop, marksKey ? .property : .string)
                index = stop
                continue scanning
            }
            if isDigit(current), !isNamePart(previous) {
                let stop = numberEnd(from: index, before: end)
                add(index..<stop, .number)
                index = stop
                continue
            }
            if let prefix = rules.variablePrefix, current == Self.ascii(prefix), let next = unit(index + 1),
               index + 1 < end, rules.isShell || isLetter(next) || next == Self.ascii("{") {
                let stop: Int
                if next == Self.ascii("{") {
                    stop = min((first("}", from: index + 2, before: end) ?? end - 1) + 1, end)
                } else if isNamePart(next) {
                    stop = nameEnd(from: index + 1, before: end)
                } else {
                    // `$?`, `$@`, `$#` and the like.
                    stop = isSpace(next) ? index + 1 : index + 2
                }
                add(index..<stop, .variable)
                index = max(stop, index + 1)
                continue
            }
            let prefix = current < 0x80 ? Character(UnicodeScalar(UInt8(current))) : nil
            if let prefix, prefix == rules.attributePrefix || prefix == rules.directivePrefix,
               let next = unit(index + 1), isLetter(next), !isNamePart(previous) {
                let stop = nameEnd(from: index + 1, before: end, extra: [Self.ascii(".")])
                add(index..<stop, prefix == rules.attributePrefix ? .attribute : .keyword)
                index = stop
                continue
            }
            if isLetter(current), !isNamePart(previous) {
                // Shell words run on through hyphens, as in `set -e` or `my-script`.
                let stop = nameEnd(from: index, before: end, extra: rules.commentsStartWords ? [Self.ascii("-")] : [])
                let name = word(index..<stop)
                if rules.colonsMarkKeys, isKey(endingAt: stop, before: end, spaced: false) {
                    add(index..<stop, .property)
                } else if rules.keywords.contains(rules.ignoresCase ? name.lowercased() : name),
                          previous != Self.ascii(".") {
                    add(index..<stop, .keyword)
                } else if rules.types.contains(name) {
                    add(index..<stop, .type)
                } else if rules.capitalisedTypes, let first = name.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    add(index..<stop, .type)
                }
                index = stop
                continue
            }
            index += 1
        }
    }

    /// Whether a colon follows `index`, making what ends there a key. A
    /// string may have spaces before its colon; a bare name, as in YAML,
    /// needs a space or the line's end after it, so `http://` is no key.
    private mutating func isKey(endingAt index: Int, before end: Int, spaced: Bool) -> Bool {
        var position = index
        if spaced {
            while position < end, units[position] == 0x20 || units[position] == 0x09 { position += 1 }
        }
        guard position < end, units[position] == Self.ascii(":") else { return false }
        return spaced || position + 1 >= end || isSpace(units[position + 1])
    }

    // MARK: HTML

    /// Scans `range` as HTML, or XML, which has CDATA sections but no script
    /// or style of its own, from `start`. Checkpoints are only outside tags,
    /// and so outside scripts and styles too.
    mutating func scanHTML(_ range: Range<Int>, isXML: Bool = false, from start: Int) {
        let end = range.upperBound
        var index = start
        while index < end {
            if checkpoint(index) { return }
            if matches("<!--", at: index) {
                let stop = min((first("-->", from: index + 4, before: end) ?? end - 3) + 3, end)
                add(index..<stop, .comment)
                index = stop
            } else if isXML, matches("<![CDATA[", at: index) {
                let stop = min((first("]]>", from: index + 9, before: end) ?? end - 3) + 3, end)
                add(index..<stop, .string)
                index = stop
            } else if matches("<!", at: index) || matches("<?", at: index) {
                let stop = min((first(">", from: index, before: end) ?? end - 1) + 1, end)
                add(index..<stop, .keyword)
                index = stop
            } else if units[index] == Self.ascii("<"), let next = unit(index + 1), index + 1 < end,
                      isLetter(next) || next == Self.ascii("/") {
                index = scanTag(from: index, before: end, isXML: isXML)
            } else if units[index] == Self.ascii("&") {
                let stop = nameEnd(from: index + 1, before: end, extra: [Self.ascii("#")])
                if stop > index + 1, unit(stop) == Self.ascii(";"), stop < end {
                    add(index..<(stop + 1), .number)
                    index = stop + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    /// A tag from its `<`, with its attributes, and the script or style it opens.
    private mutating func scanTag(from start: Int, before end: Int, isXML: Bool) -> Int {
        let isClosing = units[start + 1] == Self.ascii("/")
        let nameStart = start + (isClosing ? 2 : 1)
        // XML's names may have points in them too, as in `<dict.entry>`.
        let nameStop = nameEnd(from: nameStart, before: end, extra: [Self.ascii("-"), Self.ascii(":"), Self.ascii(".")])
        add(start..<nameStop, .tag)
        let name = word(nameStart..<nameStop).lowercased()

        var index = nameStop
        while index < end {
            let current = units[index]
            if current == Self.ascii(">") || matches("/>", at: index) {
                let stop = current == Self.ascii(">") ? index + 1 : index + 2
                add(index..<stop, .tag)
                index = stop
                break
            } else if current == Self.ascii("\"") || current == Self.ascii("'") {
                let stop = stringEnd(CodeRules.StringRule(delimiter: current == 0x22 ? "\"" : "'", spansLines: true, escapes: false),
                                     from: index, before: end)
                add(index..<stop, .string)
                index = stop
            } else if isSpace(current) || current == Self.ascii("=") {
                index += 1
            } else {
                var stop = index
                while stop < end, !isSpace(units[stop]), !"=>\"'".utf16.contains(units[stop]), !matches("/>", at: stop) {
                    stop += 1
                }
                // A value without quotes follows its `=`.
                let isValue = index > nameStop && units[index - 1] == Self.ascii("=")
                add(index..<max(stop, index + 1), isValue ? .string : .property)
                index = max(stop, index + 1)
            }
        }

        // What a script or style element holds is code of its own, in HTML.
        guard !isXML, !isClosing, name == "script" || name == "style" else { return index }
        let closing = first("</\(name)", from: index, before: end, ignoringCase: true) ?? end
        if name == "script" {
            scanCode(index..<closing, rules: CodeRules(.javaScript))
        } else {
            scanCSS(index..<closing)
        }
        return closing
    }

    // MARK: CSS

    /// CSS, or one of the languages that add to it.
    enum CSSDialect {
        case css
        /// SCSS: `//` comments, `$variables`, `#{…}` and `%placeholders`.
        case scss
        /// Less: `//` comments, and `@variables` among its at-rules.
        case less
    }

    /// The at-rules Less has, so that every other name after an `@` is a variable.
    private static let lessAtRules: Set<String> = [
        "charset", "container", "counter-style", "document", "font-face", "font-feature-values", "import",
        "keyframes", "layer", "media", "namespace", "page", "plugin", "property", "scope", "starting-style",
        "supports", "viewport",
    ]

    /// Scans `range` as CSS, or a dialect of it, from `start` if this is the
    /// whole text, where it marks checkpoints.
    mutating func scanCSS(_ range: Range<Int>, dialect: CSSDialect = .css, from start: Checkpoint? = nil) {
        let end = range.upperBound
        var index = start?.index ?? range.lowerBound
        var depth = start?.state.depth ?? 0
        // Whether the current statement is a selector, worked out from
        // whether a block or the end of a declaration comes first.
        var isSelector = start?.state.isSelector
        let nameExtra: Set<UInt16> = [Self.ascii("-")]
        while index < end {
            if start != nil, checkpoint(index, ScanState(depth: depth, isSelector: isSelector)) { return }
            let current = units[index]
            let previous = index > range.lowerBound ? units[index - 1] : 0x20
            if matches("/*", at: index) {
                let stop = min((first("*/", from: index + 2, before: end) ?? end - 2) + 2, end)
                add(index..<stop, .comment)
                index = stop
            } else if dialect != .css, matches("//", at: index), previous != Self.ascii(":") {
                // Not the `//` of a URL, as in `url(http://…)`.
                let stop = lineEnd(from: index, before: end)
                add(index..<stop, .comment)
                index = stop
            } else if dialect != .css, matches(dialect == .scss ? "#{" : "@{", at: index) {
                // A variable's value written into a selector or a name.
                let stop = min((first("}", from: index + 2, before: end) ?? end - 1) + 1, end)
                add(index..<stop, .variable)
                index = stop
            } else if dialect == .scss, current == Self.ascii("$"), let next = unit(index + 1), isLetter(next) {
                let stop = nameEnd(from: index + 1, before: end, extra: nameExtra)
                add(index..<stop, .variable)
                index = stop
            } else if dialect == .less, current == Self.ascii("@"), let next = unit(index + 1), isLetter(next),
                      case let stop = nameEnd(from: index + 1, before: end, extra: nameExtra),
                      !Self.lessAtRules.contains(word((index + 1)..<stop)) {
                add(index..<stop, .variable)
                index = stop
            } else if current == Self.ascii("\"") || current == Self.ascii("'") {
                let rule = CodeRules.StringRule(delimiter: current == 0x22 ? "\"" : "'", spansLines: false)
                let stop = stringEnd(rule, from: index, before: end)
                add(index..<stop, .string)
                index = stop
            } else if current == Self.ascii("{") || current == Self.ascii("}") || current == Self.ascii(";") {
                if current != Self.ascii(";") { depth = max(0, depth + (current == Self.ascii("{") ? 1 : -1)) }
                isSelector = nil
                index += 1
            } else if current == Self.ascii("@") || (current == Self.ascii("!") && matches("!important", at: index)) {
                let stop = nameEnd(from: index + 1, before: end, extra: nameExtra)
                add(index..<stop, .keyword)
                index = stop
            } else if isSelector ?? opensBlock(from: index, before: end, orAtTopLevel: depth == 0) {
                isSelector = true
                // SCSS's `%placeholder` selectors are classes of a kind.
                let marksClass = current == Self.ascii(".") || current == Self.ascii("#")
                    || (dialect == .scss && current == Self.ascii("%"))
                if marksClass, let next = unit(index + 1), isLetter(next) {
                    let stop = nameEnd(from: index + 1, before: end, extra: nameExtra)
                    add(index..<stop, .attribute)
                    index = stop
                } else if dialect != .css, current == Self.ascii("&") {
                    // The selector a nested one is written within.
                    add(index..<(index + 1), .keyword)
                    index += 1
                } else if current == Self.ascii(":") {
                    let start = unit(index + 1) == Self.ascii(":") ? index + 2 : index + 1
                    let stop = nameEnd(from: start, before: end, extra: nameExtra)
                    add(index..<stop, .keyword)
                    index = max(stop, index + 1)
                } else if isLetter(current), !isNamePart(previous) {
                    let stop = nameEnd(from: index, before: end, extra: nameExtra)
                    add(index..<stop, .tag)
                    index = stop
                } else {
                    index += 1
                }
            } else {
                isSelector = false
                if current == Self.ascii("#"), let next = unit(index + 1), isNamePart(next) {
                    let stop = nameEnd(from: index + 1, before: end)
                    add(index..<stop, .number)
                    index = stop
                } else if (isDigit(current) || (current == Self.ascii(".") && unit(index + 1).map(isDigit) == true)),
                          !isNamePart(previous) {
                    var stop = numberEnd(from: index, before: end)
                    if unit(stop) == Self.ascii("%"), stop < end { stop += 1 }
                    add(index..<stop, .number)
                    index = stop
                } else if isLetter(current) || (current == Self.ascii("-") && unit(index + 1).map(isLetter) == true),
                          !isNamePart(previous), previous != Self.ascii("-") {
                    let stop = nameEnd(from: index, before: end, extra: nameExtra)
                    var after = stop
                    while after < end, units[after] == 0x20 || units[after] == 0x09 { after += 1 }
                    if unit(after) == Self.ascii(":") { add(index..<stop, .property) }
                    index = max(stop, index + 1)
                } else {
                    index += 1
                }
            }
        }
    }

    /// Whether a block opens before the statement from `index` ends, as it
    /// does after a selector. Text running to the end is a selector only
    /// outside every block.
    private mutating func opensBlock(from index: Int, before end: Int, orAtTopLevel topLevel: Bool) -> Bool {
        var position = index
        while position < end {
            switch units[position] {
            case Self.ascii("{"): return true
            case Self.ascii(";"), Self.ascii("}"): return false
            default: position += 1
            }
        }
        return topLevel
    }
}
