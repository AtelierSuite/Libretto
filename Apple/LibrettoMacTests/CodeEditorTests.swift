import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LibrettoEngine
@testable import LibrettoMac

@MainActor
@Suite("Mac code editor")
struct CodeEditorTests {
    private func makeEditor(_ source: String, language: SourceLanguage = .swift) -> (CodeEditor, () -> WordDocument?) {
        var document = PlainText.document(from: Data(source.utf8), format: PlainText.codeFormat)
        document.sourceLanguage = language
        let editor = CodeEditor(document: document, scheme: .light)
        var latest: WordDocument?
        editor.onChange = { document, _ in latest = document }
        return (editor, { latest })
    }

    @Test("Return keeps the line's indent, and typing reaches the document as lines", arguments: [SourceLanguage.swift, .plainText])
    func newlineKeepsIndent(language: SourceLanguage) throws {
        let (editor, latest) = makeEditor("func f() {\n\tlet a = 1\n}", language: language)
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: ("func f() {\n\tlet a = 1" as NSString).length, length: 0))
        // As the Return key does, through the text view and its delegate.
        textView.insertNewline(nil)
        textView.insertText("let b = 2", replacementRange: textView.selectedRange())
        #expect(textView.string == "func f() {\n\tlet a = 1\n\tlet b = 2\n}")
        editor.flush()

        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "func f() {\n\tlet a = 1\n\tlet b = 2\n}\n")
    }

    @Test("Return between braces opens an indented line, with the closer on the line under it")
    func newlineBetweenBraces() {
        let (editor, _) = makeEditor("func f() {\n    let a = 1\n}")
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: ("func f() {\n    let a = 1" as NSString).length, length: 0))
        textView.insertNewline(nil)
        // A key at a time, as typed, so the brace closes itself.
        for key in ["if b ", "{"] { textView.insertText(key, replacementRange: textView.selectedRange()) }
        #expect(textView.string == "func f() {\n    let a = 1\n    if b {}\n}")
        textView.insertNewline(nil)
        #expect(textView.string == "func f() {\n    let a = 1\n    if b {\n        \n    }\n}")
        #expect(textView.selectedRange() == NSRange(location: ("func f() {\n    let a = 1\n    if b {\n        " as NSString).length, length: 0))
    }
}
