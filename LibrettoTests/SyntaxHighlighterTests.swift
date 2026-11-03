import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Libretto
@testable import LibrettoEngine

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    /// Each token's text and kind.
    private func tokens(_ text: String, _ language: SourceLanguage) -> [String: SyntaxKind] {
        let string = text as NSString
        var result: [String: SyntaxKind] = [:]
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result[string.substring(with: token.range)] = token.kind
        }
        return result
    }

    @Test("Swift keywords, types, strings, comments, numbers and attributes")
    func swift() {
        let found = tokens("""
            @MainActor final class View { // note
                let name: String = "a \\"b\\""
                /* block
                   comment */ var count = 42
            #if DEBUG
            }
            """, .swift)
        #expect(found["@MainActor"] == .attribute)
        #expect(found["final"] == .keyword)
        #expect(found["View"] == .type)
        #expect(found["String"] == .type)
        #expect(found["// note"] == .comment)
        #expect(found["\"a \\\"b\\\"\""] == .string)
        #expect(found.first { $0.key.hasPrefix("/* block\n") && $0.key.hasSuffix("comment */") }?.value == .comment)
        #expect(found["42"] == .number)
        #expect(found["#if"] == .keyword)
        #expect(found["name"] == nil)
    }

    @Test("Python strings and comments, and keywords only where they are words")
    func python() {
        let found = tokens("def f(x):\n    '''doc\n    string'''\n    return x.def  # done\n", .python)
        #expect(found["def"] == .keyword)
        #expect(found["'''doc\n    string'''"] == .string)
        #expect(found["return"] == .keyword)
        #expect(found["# done"] == .comment)
        #expect(tokens("x.def", .python)["def"] == nil)
    }

    @Test("TypeScript has its own keywords and keeps template strings whole")
    func scripts() {
        let found = tokens("interface A { b: number }\nconst s = `x\ny`", .typeScript)
        #expect(found["interface"] == .keyword)
        #expect(found["number"] == .keyword)
        #expect(found["`x\ny`"] == .string)
        #expect(tokens("interface A {}", .javaScript)["interface"] == nil)
    }

    @Test("Shell variables, and # only as a comment at the start of a word")
    func shell() {
        let found = tokens("if [ -n \"$HOME\" ]; then echo ${#ARR} $1 # done\nfi", .shell)
        #expect(found["if"] == .keyword)
        #expect(found["\"$HOME\""] == .string)
        #expect(found["${#ARR}"] == .variable)
        #expect(found["$1"] == .variable)
        #expect(found["# done"] == .comment)
        #expect(found["fi"] == .keyword)
    }

    @Test("HTML tags and attributes, with the script and style inside them")
    func html() {
        let found = tokens("""
            <!-- c --><a href="x" hidden>&amp;</a>
            <script>let n = 1</script><style>p { color: red }</style>
            """, .html)
        #expect(found["<!-- c -->"] == .comment)
        #expect(found["<a"] == .tag)
        #expect(found["href"] == .property)
        #expect(found["\"x\""] == .string)
        #expect(found["hidden"] == .property)
        #expect(found["&amp;"] == .number)
        #expect(found["</a"] == .tag)
        #expect(found["let"] == .keyword)
        #expect(found["p"] == .tag)
        #expect(found["color"] == .property)
    }

    @Test("CSS selectors, properties, numbers and at-rules")
    func css() {
        let found = tokens("@media screen { .card > h1:hover { margin: -4px 1.5em; color: #fff !important; } }", .css)
        #expect(found["@media"] == .keyword)
        #expect(found[".card"] == .attribute)
        #expect(found["h1"] == .tag)
        #expect(found[":hover"] == .keyword)
        #expect(found["margin"] == .property)
        #expect(found["4px"] == .number)
        #expect(found["1.5em"] == .number)
        #expect(found["#fff"] == .number)
        #expect(found["!important"] == .keyword)
    }

    @Test("C's preprocessor and built-in types, and C++'s own keywords")
    func cFamily() {
        let found = tokens("#include <stdio.h>\nstatic int count = 0; // c\nnamespace a {}", .cPlusPlus)
        #expect(found["#include"] == .keyword)
        #expect(found["static"] == .keyword)
        #expect(found["int"] == .type)
        #expect(found["0"] == .number)
        #expect(found["// c"] == .comment)
        #expect(found["namespace"] == .keyword)
        #expect(tokens("namespace a {}", .c)["namespace"] == nil)
        #expect(tokens("@interface View : NSObject", .objectiveC)["@interface"] == .attribute)
    }

    @Test("Go's raw strings, and capitals that mark exports rather than types")
    func go() {
        let found = tokens("func Run(n int) string {\n\treturn `a\nb`\n}", .go)
        #expect(found["func"] == .keyword)
        #expect(found["Run"] == nil)
        #expect(found["int"] == .type)
        #expect(found["`a\nb`"] == .string)
    }

    @Test("Rust lifetimes are not strings")
    func rust() {
        let found = tokens("fn first<'a>(s: &'a str) -> Option<u8> { None }", .rust)
        #expect(found["fn"] == .keyword)
        #expect(found["str"] == .type)
        #expect(found["Option"] == .type)
        #expect(found.keys.contains { $0.hasPrefix("'") } == false)
    }

    @Test("PHP variables, and both its line comments")
    func php() {
        let found = tokens("<?php\n$name = 'a'; // one\n# two\necho $name;", .php)
        #expect(found["$name"] == .variable)
        #expect(found["'a'"] == .string)
        #expect(found["// one"] == .comment)
        #expect(found["# two"] == .comment)
        #expect(found["echo"] == .keyword)
    }

    @Test("SQL keywords in any case")
    func sql() {
        let found = tokens("SELECT name FROM users where id = 1 -- first", .sql)
        #expect(found["SELECT"] == .keyword)
        #expect(found["where"] == .keyword)
        #expect(found["users"] == nil)
        #expect(found["-- first"] == .comment)
    }

    @Test("JSON and YAML keys apart from their values")
    func data() {
        let json = tokens("{\"name\" : \"Libretto\", \"open\": true, \"count\": 3}", .json)
        #expect(json["\"name\""] == .property)
        #expect(json["\"Libretto\""] == .string)
        #expect(json["true"] == .keyword)
        #expect(json["3"] == .number)
        let yaml = tokens("name: Libretto # app\nurl: http://example.com\nshared: yes\n", .yaml)
        #expect(yaml["name"] == .property)
        #expect(yaml["# app"] == .comment)
        #expect(yaml["http"] == nil)
        #expect(yaml["yes"] == .keyword)
    }

    @Test("JSX and TSX open as JavaScript and TypeScript")
    func jsx() {
        #expect(SourceLanguage(contentType: .plainText, filename: "App.jsx") == .javaScript)
        #expect(SourceLanguage(contentType: .plainText, filename: "App.tsx") == .typeScript)
        #expect(SourceLanguage(contentType: .jsxSource, filename: nil) == .javaScript)
        let found = tokens("export const App = () => <div className=\"app\">{count}</div>", .javaScript)
        #expect(found["export"] == .keyword)
        #expect(found["\"app\""] == .string)
    }

    @Test("JSON with comments, as tsconfig.json and VS Code's settings have them")
    func jsonComments() {
        let found = tokens("{\n  // strict\n  \"strict\": true, /* all */\n  'quoted': 1\n}", .json)
        #expect(found["// strict"] == .comment)
        #expect(found["/* all */"] == .comment)
        #expect(found["\"strict\""] == .property)
        #expect(found["'quoted'"] == .property)
        #expect(SourceLanguage(contentType: .plainText, filename: "settings.jsonc") == .json)
        #expect(SourceLanguage(contentType: .plainText, filename: "config.json5") == .json)
        #expect(SourceLanguage(contentType: .jsonWithComments, filename: nil) == .json)
    }

    @Test("The less common extensions of the languages already coloured")
    func moreExtensions() {
        let expected: [String: SourceLanguage] = [
            "types.pyi": .python, "app.pyw": .python, "build.rake": .ruby, "libretto.gemspec": .ruby,
            "config.ru": .ruby, "setup.ksh": .shell, "list.h++": .cPlusPlus, "list.ipp": .cPlusPlus,
            "page.phtml": .php,
        ]
        for (filename, language) in expected {
            #expect(SourceLanguage(contentType: .plainText, filename: filename) == language)
        }
    }

    @Test("Files known by their name rather than their extension")
    func filenames() {
        #expect(SourceLanguage(contentType: .data, filename: "Gemfile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: "Podfile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: "Rakefile") == .ruby)
        #expect(SourceLanguage(contentType: .data, filename: ".zshrc") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: "/Users/me/.bashrc") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: ".profile") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: ".gitignore") == .shell)
        #expect(SourceLanguage(contentType: .data, filename: "Gemfile.lock") == nil)
        #expect(SourceLanguage(contentType: .data, filename: "notes") == nil)
    }

    @Test("Every language has a name for the menu")
    func names() {
        #expect(SourceLanguage.allCases.first == .plainText)
        #expect(SourceLanguage.cPlusPlus.displayName == "C++")
        #expect(SourceLanguage.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("A file's language comes from its name, or its type")
    func languages() {
        #expect(SourceLanguage(contentType: .plainText, filename: "main.cpp") == .cPlusPlus)
        #expect(SourceLanguage(contentType: .plainText, filename: "View.m") == .objectiveC)
        #expect(SourceLanguage(contentType: .plainText, filename: "config.yml") == .yaml)
        #expect(SourceLanguage(contentType: .json, filename: nil) == .json)
        #expect(SourceLanguage(contentType: .cHeader, filename: nil) == .c)
        #expect(SourceLanguage(contentType: .goSource, filename: nil) == .go)
        #expect(SourceLanguage(contentType: .mpeg2TransportStream, filename: "app.ts") == .typeScript)
        #expect(SourceLanguage(contentType: .plainText, filename: "run.sh") == .shell)
        #expect(SourceLanguage(contentType: .pythonScript, filename: nil) == .python)
        #expect(SourceLanguage(contentType: .plainText, filename: "notes.txt") == .plainText)
        #expect(SourceLanguage(contentType: .plainText, filename: "NOTES.TXT") == .plainText)
        #expect(SourceLanguage(contentType: .plainText, filename: nil) == .plainText)
        #expect(SourceLanguage(contentType: .markdownDocument, filename: "README.md") == nil)
        #expect(SourceLanguage(contentType: .markdownDocument, filename: nil) == nil)
        #expect(SourceLanguage(contentType: .openXMLDocument, filename: nil) == nil)
    }

    @Test("Colouring changes only colours, so the text reads back the same")
    func applying() {
        let text = NSMutableAttributedString(string: "let x = 1 // c", attributes: [.foregroundColor: UIColor.black])
        SyntaxHighlighter.apply(.swift, to: text, scheme: .light, plainColor: .black)
        let keyword = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let plain = text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
        #expect(plain == .black)
        #expect(text.string == "let x = 1 // c")

        SyntaxHighlighter.apply(.plainText, to: text, scheme: .light, plainColor: .black)
        #expect(SyntaxHighlighter.tokens(in: text.string, language: .plainText).isEmpty)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, _, _ in
            #expect(color as? UIColor == .black)
        }
        #expect(text.string == "let x = 1 // c")
    }

    // MARK: - Edits

    /// A little of each language, with what spans lines in it.
    private static let samples: [SourceLanguage: String] = [
        .swift: """
            @MainActor final class View { // note
                let name: String = "a \\"b\\""
                /* block
                   comment */ var count = 42
                let text = \"""
                    many \\(name)
                    lines
                    \"""
            #if DEBUG
            }
            """,
        .python: "def f(x):\n    '''doc\n    string'''\n    s = \"\"\"a\nb\"\"\"\n    return x.def  # done\n@decorator\nclass A: pass\n",
        .javaScript: "/* a\n b */ const s = `x\n${y}`\nfunction f() { return 'q' // c\n}\n",
        .typeScript: "interface A { b: number }\nconst s = `x\ny` /* c\n */ @dec class B {}\n",
        .shell: "if [ -n \"$HOME\n\" ]; then echo ${#ARR} $1 # done\nfi\nx='a\nb' set -e\n",
        .c: "#include <stdio.h>\n/* multi\n line */ static int count = 0; // c\nchar *s = \"a\\\"b\";\n",
        .cPlusPlus: "namespace a {\n/* c */ template <typename T> class B {};\n}\n",
        .objectiveC: "@interface View : NSObject\n@property (nonatomic) BOOL on; /* x\n */\n@end\n",
        .cSharp: "var s = \"\"\"\nraw\n\"\"\"; // c\n#region A\nclass B { int c; }\n",
        .java: "@Override public void f() { String s = \"\"\"\n  text\n  \"\"\"; /* c */ }\n",
        .kotlin: "fun f(): Int { val s = \"\"\"\nraw\\\n\"\"\" // c\nreturn 1 }\n",
        .go: "func Run(n int) string {\n\treturn `a\nb` /* c\n */\n}\n",
        .rust: "fn first<'a>(s: &'a str) -> Option<u8> { let t = \"a\nb\"; /* c */ None }\n",
        .ruby: "def f\n  @name = $global # c\n  'a'\nend\n",
        .php: "<?php\n$name = 'a\nb'; // one\n# two\n/* three\n */ echo \"$name\";\n",
        .sql: "SELECT name FROM users /* a\n b */ where id = 1 -- first\nINSERT INTO t VALUES ('x');\n",
        .json: "{\"name\" : \"Libretto\", // c\n \"open\": true, /* x\n */\n 'count': 3}\n",
        .yaml: "name: Libretto # app\nurl: http://example.com\nshared: yes\nlist:\n  - 'a'\n",
        .html: """
            <!-- c
             d --><a href="x
            y" hidden>&amp;</a>
            <script>let n = 1 /* x
            */ let s = `a
            b`</script><style>p {
             color: red }</style>
            <p class=x>text</p>
            """,
        .css: "@media screen {\n  .card > h1:hover,\n  a { margin: -4px 1.5em; /* c\n */ color: #fff !important; }\n}\np\n{ content: \"a\" }\n",
    ]

    /// Pieces that open and close what spans lines, and the rest.
    private static let fragments = [
        "/*", "*/", "\"", "\"\"\"", "'''", "'", "`", "\n", "\n", "\r\n", "\u{2028}", "\\", "#", "//", "--", "<!--", "-->",
        "<script>", "</script>", "<style>", "</style>", "<", ">", "{", "}", ";", ":", "$", "${", "@", "&amp;", "=",
        "let", "class", "x", "42", " ", "\t", "é", "", "", "",
    ]

    /// Edits `text` at random, checking after each edit that what was found
    /// again around it is what a scan of the whole text finds.
    private func checkEdits(_ text: String, _ language: SourceLanguage, count: Int, seed: UInt64) {
        var random = SeededRandom(seed)
        let text = NSMutableString(string: text)
        var highlights = SyntaxHighlights(text as String, language: language)
        for step in 0..<count {
            // Now and then at the end, which what runs to the end depends on.
            let atEnd = Int.random(in: 0..<10, using: &random) == 0
            let location = atEnd ? text.length : Int.random(in: 0...text.length, using: &random)
            let longest = Int.random(in: 0..<8, using: &random) == 0 ? 40 : 3
            let removed = min(Int.random(in: 0...longest, using: &random), text.length - location)
            let inserted = Self.fragments.randomElement(using: &random)!
            let before = text.substring(with: NSRange(location: location, length: removed))
            text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
            let length = (inserted as NSString).length
            _ = highlights.update(
                text as String, edited: NSRange(location: location, length: length), changeInLength: length - removed
            )
            let expected = SyntaxHighlights(text as String, language: language).tokens
            #expect(
                highlights.tokens == expected,
                "\(language), edit \(step): \(before.debugDescription) at \(location) became \(inserted.debugDescription)"
            )
            guard highlights.tokens == expected else { return }
        }
    }

    @Test("Scanning again around an edit finds what scanning the whole text does", arguments: SourceLanguage.allCases)
    func edits(language: SourceLanguage) {
        let sample = Self.samples[language] ?? "plain text\nand more"
        // Many lines, so that edits fall far from each end.
        let text = Array(repeating: sample, count: 6).joined(separator: "\n")
        for seed in 1...8 {
            checkEdits(text, language, count: 150, seed: UInt64(seed * 7919 + language.rawValue.utf16.count))
        }
    }

    @Test("Opening and closing block comments and strings that span lines")
    func spanningEdits() {
        let cases: [(SourceLanguage, String, [(String, String)])] = [
            (.swift, "let a = 1\nlet b = \"x\"\nlet c = 3\nlet d = 4\n", [
                ("let b", "/* let b"), ("let d", "*/ let d"), ("/* ", ""), ("*/ ", ""),
                ("let b", "\"\"\"\nlet b"), ("let d", "\"\"\"\nlet d"), ("\"\"\"\nlet b", "let b"),
            ]),
            (.python, "x = 1\ny = 'a'\nz = 2\n", [("y", "'''y"), ("z = 2", "z = 2'''"), ("'''y", "y")]),
            (.javaScript, "let a = 1\nlet b = 2\nlet c = 3\n", [("let b", "`let b"), ("let c", "`let c"), ("`let b", "let b")]),
            (.html, "<p>a</p>\n<p>b</p>\n<p>c</p>\n<p>d</p>\n", [
                ("<p>b</p>", "<script>let x = 1\n"), ("<p>d</p>", "</script><p>d</p>"),
                ("<script>", "<style>"), ("</script>", "</style>"), ("let x", "/* let x"), ("<style>", ""),
                ("<p>a", "<!-- <p>a"), ("<p>c", "--> <p>c"),
            ]),
            (.css, "a { color: red }\nb { color: blue }\nc { margin: 0 }\n", [
                ("b {", "b"), ("c {", "/* c {"), ("margin", "*/ margin"), ("b", "b {"),
            ]),
        ]
        for (language, start, edits) in cases {
            let text = NSMutableString(string: start)
            var highlights = SyntaxHighlights(start, language: language)
            for (old, new) in edits {
                let range = text.range(of: old)
                #expect(range.location != NSNotFound)
                text.replaceCharacters(in: range, with: new)
                let length = (new as NSString).length
                let changed = highlights.update(
                    text as String, edited: NSRange(location: range.location, length: length),
                    changeInLength: length - range.length
                )
                #expect(changed.text.location <= range.location && NSMaxRange(changed.text) >= range.location + length)
                #expect(
                    highlights.tokens == SyntaxHighlights(text as String, language: language).tokens,
                    "\(language): \(old.debugDescription) became \(new.debugDescription)"
                )
            }
        }
    }

    @Test("Text added at the end changes what ran to the end, across lines")
    func editsAtTheEnd() {
        // A selector with no block after it is one only until a declaration's end follows.
        let cases: [(SourceLanguage, String, String)] = [
            (.css, "a\nb", ";"), (.css, "a\nb", " {"), (.css, "a {\n b\n c", ": red"), (.yaml, "a:\nname:", "x"),
            (.swift, "let a = 1\n/* b\nc", " */"), (.html, "<p>\n<script>\nlet a", "</script>"),
        ]
        for (language, start, added) in cases {
            let text = NSMutableString(string: start)
            var highlights = SyntaxHighlights(start, language: language)
            let length = (added as NSString).length
            text.append(added)
            _ = highlights.update(text as String, edited: NSRange(location: text.length - length, length: length), changeInLength: length)
            #expect(highlights.tokens == SyntaxHighlights(text as String, language: language).tokens, "\(language): \(added)")
            text.deleteCharacters(in: NSRange(location: text.length - length, length: length))
            _ = highlights.update(text as String, edited: NSRange(location: text.length, length: 0), changeInLength: -length)
            #expect(highlights.tokens == SyntaxHighlights(text as String, language: language).tokens, "\(language): \(added)")
        }
    }

    @Test("An edit is scanned again only as far as the lines around it")
    func editsStayLocal() {
        let lines = (0..<2000).map { "let value\($0) = \"\($0)\" // \($0)" }
        let text = NSMutableString(string: lines.joined(separator: "\n"))
        var highlights = SyntaxHighlights(text as String, language: .swift)
        let location = text.range(of: "value1000").location
        text.insert("x", at: location)
        let changed = highlights.update(text as String, edited: NSRange(location: location, length: 1), changeInLength: 1)
        #expect(changed.text.length < 200)
        #expect(changed.tokens.count < 10)
        #expect(highlights.tokens == SyntaxHighlights(text as String, language: .swift).tokens)

        // Opening a comment colours the rest of the text, and closing it colours the rest back.
        text.insert("/*", at: location)
        let opened = highlights.update(text as String, edited: NSRange(location: location, length: 2), changeInLength: 2)
        #expect(NSMaxRange(opened.text) == text.length)
        let end = text.range(of: "value1001").location
        text.insert("*/", at: end)
        let closed = highlights.update(text as String, edited: NSRange(location: end, length: 2), changeInLength: 2)
        #expect(NSMaxRange(closed.text) == text.length)
        #expect(highlights.tokens == SyntaxHighlights(text as String, language: .swift).tokens)
    }

    @Test("Colouring after edits colours the text as colouring it whole does")
    func coloringEdits() {
        for language in [SourceLanguage.swift, .html, .css, .python] {
            let sample = Array(repeating: Self.samples[language]!, count: 4).joined(separator: "\n")
            let text = NSMutableAttributedString(string: sample, attributes: [.foregroundColor: UIColor.black])
            var coloring = SyntaxColoring()
            coloring.apply(language, to: text, scheme: .light, plainColor: .black)
            var random = SeededRandom(UInt64(sample.utf16.count))
            for step in 0..<120 {
                // Sometimes two edits between colourings, as a replacement makes.
                for _ in 0..<(step % 5 == 0 ? 2 : 1) {
                    let location = Int.random(in: 0...text.length, using: &random)
                    let removed = min(Int.random(in: 0...3, using: &random), text.length - location)
                    let inserted = Self.fragments.randomElement(using: &random)!
                    text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
                    let length = (inserted as NSString).length
                    coloring.noteEdit(NSRange(location: location, length: length), changeInLength: length - removed)
                }
                coloring.apply(language, to: text, scheme: .light, plainColor: .black)
                let whole = NSMutableAttributedString(attributedString: text)
                SyntaxHighlighter.apply(language, to: whole, scheme: .light, plainColor: .black)
                #expect(colors(of: text) == colors(of: whole), "\(language), edit \(step)")
            }
            // A new scheme colours the whole text again.
            coloring.noteEdit(NSRange(location: 0, length: 0), changeInLength: 0)
            coloring.apply(language, to: text, scheme: .dark, plainColor: .white)
            let whole = NSMutableAttributedString(attributedString: text)
            SyntaxHighlighter.apply(language, to: whole, scheme: .dark, plainColor: .white)
            #expect(colors(of: text) == colors(of: whole))
        }
    }

    /// The text's colours, run by run.
    private func colors(of text: NSAttributedString) -> [String] {
        var runs: [String] = []
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { color, range, _ in
            runs.append("\(range.location) \(range.length) \((color as? UIColor)?.description ?? "none")")
        }
        return runs
    }

    @Test("Typing in a large file scans a few lines, not the whole file")
    func largeFile() {
        let chunk = """
            /// A view of the document, as the reader sees it.
            @MainActor final class DocumentView<Content: View>: UIView {
                private var pages: [Page] = []
                let title = "Libretto \\(version)"
                /* The margins, in points,
                   around each page. */
                var margins = UIEdgeInsets(top: 72, left: 54, bottom: 72, right: 54)

                func layout(_ width: CGFloat) -> CGFloat {
                    let help = \"""
                        Pinch to zoom.
                        \"""
                    return pages.reduce(0) { $0 + $1.height(for: width) } // total
                }
            }

            """
        let source = String(repeating: chunk, count: 1500)
        let storage = NSTextStorage(string: source, attributes: [.foregroundColor: UIColor.label])
        let clock = ContinuousClock()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count

        var coloring = SyntaxColoring()
        coloring.apply(.swift, to: storage, scheme: .light, plainColor: .label)
        var random = SeededRandom(28)
        var full = Duration.zero
        var incremental = Duration.zero
        let keystrokes = 20
        for _ in 0..<keystrokes {
            let location = Int.random(in: 0...storage.length, using: &random)
            storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "a")
            coloring.noteEdit(NSRange(location: location, length: 1), changeInLength: 1)
            incremental += clock.measure {
                coloring.apply(.swift, to: storage, scheme: .light, plainColor: .label)
            }
            let whole = NSTextStorage(attributedString: storage)
            SyntaxHighlighter.apply(.swift, to: whole, scheme: .light, plainColor: .label)
            #expect(colors(of: storage) == colors(of: whole))
            // As the editor coloured before: the whole file again, though little of it changes colour.
            full += clock.measure {
                SyntaxHighlighter.apply(.swift, to: storage, scheme: .light, plainColor: .label)
            }
        }
        let fullTime = full / keystrokes
        let incrementalTime = incremental / keystrokes
        print("Colouring \(lines) lines (\(storage.length) units) per keystroke: whole file \(fullTime), around the edit \(incrementalTime)")
        #expect(incrementalTime * 4 < fullTime)
    }
}

/// The same numbers every run, so a failing edit can be found again.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
