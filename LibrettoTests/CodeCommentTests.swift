import Foundation
import Testing
@testable import LibrettoEngine

@Suite("Commenting code out")
struct CodeCommentTests {
    /// The text after toggling. `«` and `»` mark the selection, or `|` the
    /// caret, before and after.
    private func toggle(_ marked: String, _ language: SourceLanguage = .swift) -> String? {
        let (text, selection) = unmark(marked)
        guard let edit = CodeComments.toggle(in: text, selection: selection, language: language) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return mark(result, edit.selection)
    }

    private func unmark(_ marked: String) -> (String, NSRange) {
        let string = marked as NSString
        let caret = string.range(of: "|")
        if caret.location != NSNotFound {
            return (string.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let start = string.range(of: "«").location
        let end = string.range(of: "»").location - 1
        let text = marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
        return (text, NSRange(location: start, length: end - start))
    }

    private func mark(_ text: String, _ selection: NSRange) -> String {
        let string = NSMutableString(string: text)
        if selection.length == 0 {
            string.insert("|", at: selection.location)
        } else {
            string.insert("»", at: NSMaxRange(selection))
            string.insert("«", at: selection.location)
        }
        return string as String
    }

    @Test("The caret's line is commented out, and the caret stays with its text")
    func currentLine() {
        #expect(toggle("let a = 1\nlet b| = 2\nlet c = 3") == "let a = 1\n// let b| = 2\nlet c = 3")
        #expect(toggle("let a = 1\n// let b| = 2\nlet c = 3") == "let a = 1\nlet b| = 2\nlet c = 3")
    }

    @Test("Selected lines are commented at the least indent, blank lines left alone")
    func selectedLines() {
        let source = "func f() {\n«    if a {\n\n        b()\n    }\n»}"
        let commented = "func f() {\n«    // if a {\n\n    //     b()\n    // }\n»}"
        #expect(toggle(source) == commented)
        #expect(toggle(commented) == source)
    }

    @Test("Lines are uncommented only when every one is commented")
    func mixed() {
        #expect(toggle("«// a()\nb()»") == "«// // a()\n// b()»")
        // A comment written without a space after its marker loses only the marker.
        #expect(toggle("«//a()\n  // b()»") == "«a()\n  b()»")
    }

    @Test("A selection ending at the start of a line leaves that line out")
    func wholeLines() {
        #expect(toggle("«a()\n»b()") == "«// a()\n»b()")
    }

    @Test("An empty line is commented when it is all there is")
    func emptyLine() {
        #expect(toggle("a()\n|") == "a()\n// |")
    }

    @Test("Each language's own line comment", arguments: [
        (SourceLanguage.python, "#"), (.shell, "#"), (.ruby, "#"), (.yaml, "#"), (.sql, "--"), (.php, "//"),
        (.javaScript, "//"), (.rust, "//"),
    ])
    func lineMarkers(language: SourceLanguage, marker: String) {
        #expect(toggle("x = |1", language) == "\(marker) x = |1")
    }

    @Test("PHP's comments are uncommented whichever marker they use")
    func phpMarkers() {
        #expect(toggle("«# a\n// b»", .php) == "«a\nb»")
    }

    @Test("HTML and CSS lines are wrapped in a block comment, and unwrapped")
    func blockComments() {
        let html = "<ul>\n«  <li>One</li>\n  <li>Two</li>\n»</ul>"
        let commentedHTML = "<ul>\n«  <!-- <li>One</li>\n  <li>Two</li> -->\n»</ul>"
        #expect(toggle(html, .html) == commentedHTML)
        #expect(toggle(commentedHTML, .html) == html)
        #expect(toggle("p { color: |red; }", .css) == "/* p { color: |red; } */")
        #expect(toggle("/*p { color: |red; }*/", .css) == "p { color: |red; }")
    }

    @Test("Nothing to do in plain text or a blank HTML line")
    func nothing() {
        #expect(toggle("a |b", .plainText) == nil)
        #expect(toggle("  |", .html) == nil)
    }

    @Test("JSON lines are commented out as in `tsconfig.json` and `.jsonc`")
    func json() {
        #expect(toggle("{\n  \"a\": |1\n}", .json) == "{\n  // \"a\": |1\n}")
    }

    @Test("The comment markers each language declares")
    func markers() {
        #expect(SourceLanguage.swift.commentMarkers == CommentMarkers(line: ["//"], blockOpen: "/*", blockClose: "*/"))
        #expect(SourceLanguage.html.commentMarkers == CommentMarkers(line: [], blockOpen: "<!--", blockClose: "-->"))
        #expect(SourceLanguage.css.commentMarkers == CommentMarkers(line: [], blockOpen: "/*", blockClose: "*/"))
        #expect(SourceLanguage.xml.commentMarkers == CommentMarkers(line: [], blockOpen: "<!--", blockClose: "-->"))
        #expect(SourceLanguage.scss.commentMarkers == CommentMarkers(line: ["//"], blockOpen: "/*", blockClose: "*/"))
        #expect(SourceLanguage.plainText.commentMarkers == nil)
        #expect(SourceLanguage.diff.commentMarkers == nil)
        #expect(SourceLanguage.json.commentMarkers == CommentMarkers(line: ["//"], blockOpen: "/*", blockClose: "*/"))
    }
}
