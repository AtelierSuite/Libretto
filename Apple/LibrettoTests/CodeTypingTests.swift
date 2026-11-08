import Foundation
import Testing
@testable import LibrettoEngine

@Suite("Brackets and quotes in the code editor")
struct CodeTypingTests {
    /// Text with `|` for the caret, as plain text and the caret's offset.
    private func caret(in marked: String) -> (text: String, caret: Int) {
        let location = (marked as NSString).range(of: "|").location
        return (marked.replacingOccurrences(of: "|", with: ""), location)
    }

    /// Types each of `keys` in turn, `⌫` deleting backward, and returns the
    /// text with `|` where the caret ends up.
    private func type(_ keys: [String], into marked: String, language: SourceLanguage = .swift) -> String {
        var (text, location) = caret(in: marked)
        var typing = CodeTyping(language: language)
        for key in keys {
            let string = text as NSString
            let tokens = SyntaxHighlighter.tokens(in: text, language: language)
            let isDelete = key == "⌫"
            guard !isDelete || location > 0 else { continue }
            let range = isDelete ? NSRange(location: location - 1, length: 1) : NSRange(location: location, length: 0)
            let typed = isDelete ? "" : key
            let edit = typing.edit(replacing: range, with: typed, in: string, tokens: tokens)
                ?? CodeEdit(range: range, replacement: typed, selection: NSRange(
                    location: range.location + (typed as NSString).length, length: 0
                ))
            text = string.replacingCharacters(in: edit.range, with: edit.replacement)
            location = edit.selection.location
            typing.selectionDidChange(edit.selection, in: text as NSString)
        }
        return (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "|")
    }

    private func match(_ marked: String, language: SourceLanguage = .swift) -> [String]? {
        let (text, location) = caret(in: marked)
        let string = text as NSString
        guard let pair = CodeTyping.matchingBracket(
            at: location, in: string, tokens: SyntaxHighlighter.tokens(in: text, language: language)
        ) else { return nil }
        return [pair.bracket, pair.match].map { string.substring(with: NSRange(location: $0, length: 1)) + "@\($0)" }
    }

    @Test("An opening bracket brings its closer, and typing the closer steps past it")
    func closesBrackets() {
        #expect(type(["("], into: "f|") == "f(|)")
        #expect(type(["(", "[", "{"], into: "|") == "([{|}])")
        #expect(type(["(", "x", ")"], into: "f|") == "f(x)|")
        #expect(type(["(", "[", "]", ")"], into: "|") == "([])|")
        #expect(type(["{", "}", ";"], into: "|") == "{};|")
    }

    @Test("Only a closer the editor put in is stepped past")
    func stepsOnlyOverItsOwn() {
        #expect(type([")"], into: "f(x|)") == "f(x)|)")
        // Leaving the line forgets the closer.
        #expect(type(["(", "\n", ")"], into: "f|") == "f(\n    )|\n)")
    }

    @Test("An opener before a word comes alone")
    func notBeforeWords() {
        #expect(type(["("], into: "|name") == "(|name")
        #expect(type(["("], into: "|) ") == "(|)) ")
        #expect(type(["\""], into: "|name") == "\"|name")
    }

    @Test("Quotes close themselves, but not after a word, in a comment or for a language's other quotes")
    func closesQuotes() {
        #expect(type(["\"", "a", "\""], into: "let s = |") == "let s = \"a\"|")
        #expect(type(["\"", "\"", "\""], into: "|") == "\"\"\"|")
        #expect(type(["'"], into: "// don|", language: .swift) == "// don'|")
        #expect(type(["'"], into: "x = |", language: .python) == "x = '|'")
        #expect(type(["'"], into: "x = |", language: .swift) == "x = '|")
        #expect(type(["'"], into: "fn f<|", language: .rust) == "fn f<'|")
        #expect(type(["'"], into: "don|", language: .python) == "don'|")
    }

    @Test("Brackets and quotes in strings and comments are left alone")
    func notInLiterals() {
        #expect(type(["("], into: "let s = \"a|\"") == "let s = \"a(|\"")
        #expect(type(["("], into: "// note |") == "// note (|")
        #expect(type(["("], into: "/* a */ |") == "/* a */ (|)")
    }

    @Test("Plain text has no help with brackets")
    func plainText() {
        #expect(type(["(", "'"], into: "|", language: .plainText) == "('|")
    }

    @Test("Nor has a diff, whatever its lines were cut from")
    func diff() {
        #expect(type(["(", "\""], into: "+|", language: .diff) == "+(\"|")
    }

    @Test("Deleting an opener just typed takes its closer with it")
    func deletesPairs() {
        #expect(type(["(", "⌫"], into: "f|") == "f|")
        #expect(type(["\"", "⌫"], into: "x = |") == "x = |")
        #expect(type(["⌫"], into: "f(|)") == "f|)")
    }

    @Test("Return keeps the line's indent, and between brackets opens an indented line")
    func returns() {
        #expect(type(["\n"], into: "\tlet a = 1|") == "\tlet a = 1\n\t|")
        #expect(type(["{", "\n"], into: "func f() |") == "func f() {\n    |\n}")
        #expect(type(["\n"], into: "if x {\n\tf {|}\n}") == "if x {\n\tf {\n\t\t|\n\t}\n}")
        #expect(type(["\n"], into: "a {\n  b\n}\nc {|}") == "a {\n  b\n}\nc {\n  |\n}")
        #expect(type(["\n", "x"], into: "f(|)") == "f(\n    x|\n)")
        #expect(type(["\n"], into: "s = \"{|}\"") == "s = \"{\n|}\"")
        #expect(type(["\n"], into: "{|}", language: .plainText) == "{\n|}")
    }

    @Test("The bracket beside the caret is matched, before it first")
    func matches() {
        #expect(match("f(a, b)|") == [")@6", "(@1"])
        #expect(match("f|(a, b)") == ["(@1", ")@6"])
        #expect(match("{ [|] }") == ["[@2", "]@3"])
        #expect(match("{ (a) | }") == nil)
        #expect(match("f(a|") == nil)
        #expect(match("x|") == nil)
    }

    @Test("Brackets in strings and comments are passed over when matching")
    func matchesPastLiterals() {
        #expect(match("f|(\")\", /* ) */ x) // )") == ["(@1", ")@16"])
        #expect(match("f(\"(\" // (\n)|") == [")@11", "(@1"])
        #expect(match("let s = \"(|)\"") == nil)
        #expect(match("{\"a}\": [1]}|", language: .json) == ["}@10", "{@0"])
    }
}
