import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Libretto
@testable import LibrettoEngine

@MainActor
@Suite("Code editor")
struct CodeEditorTests {
    private func makeEditor(_ source: String, language: SourceLanguage = .swift) -> (CodeEditorController, () -> WordDocument?) {
        var document = PlainText.document(from: Data(source.utf8), format: PlainText.codeFormat)
        document.sourceLanguage = language
        let controller = CodeEditorController(document: document, language: language, scheme: .light)
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        controller.view.layoutIfNeeded()
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        return (controller, { latest })
    }

    @Test("Return keeps the line's indent, and typing reaches the document as lines", arguments: [SourceLanguage.swift, .plainText])
    func typing(language: SourceLanguage) throws {
        let (controller, latest) = makeEditor("func f() {\n\tlet a = 1\n}", language: language)
        let textView = controller.view.textView
        textView.selectedRange = NSRange(location: ("func f() {\n\tlet a = 1" as NSString).length, length: 0)
        if controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n") {
            textView.insertText("\n")
        }
        textView.insertText("let b = 2")
        controller.textViewDidChange(textView)
        controller.flush()

        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "func f() {\n\tlet a = 1\n\tlet b = 2\n}\n")
        #expect(document.sourceLanguage == language)
    }

    /// Types `text` at the caret as the keyboard would, letting the editor step in.
    private func type(_ text: String, in controller: CodeEditorController) {
        let textView = controller.view.textView
        if controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: text) {
            textView.insertText(text)
        }
        controller.textViewDidChange(textView)
    }

    @Test("Brackets close themselves, Return opens a line between braces, and the caret's bracket is matched")
    func brackets() throws {
        let (controller, latest) = makeEditor("func f() ")
        let textView = controller.view.textView
        textView.selectedRange = NSRange(location: 9, length: 0)
        type("{", in: controller)
        #expect(textView.text == "func f() {}")
        #expect(textView.selectedRange == NSRange(location: 10, length: 0))
        #expect(controller.matchedBrackets == [9, 10])

        type("\n", in: controller)
        #expect(textView.text == "func f() {\n    \n}")
        #expect(textView.selectedRange == NSRange(location: 15, length: 0))
        #expect(controller.matchedBrackets.isEmpty)

        type("g(", in: controller)
        type("(", in: controller)
        type("\"", in: controller)
        type("(", in: controller)
        #expect(textView.text == "func f() {\n    g((\"(\")\n}")
        type("\"", in: controller)
        type(")", in: controller)
        #expect(textView.text == "func f() {\n    g((\"(\")\n}")
        #expect(textView.selectedRange == NSRange(location: 22, length: 0))
        // The bracket in the string is passed over.
        #expect(controller.matchedBrackets == [21, 17])

        controller.flush()
        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "func f() {\n    g((\"(\")\n}\n")
    }

    @Test("⌘/ comments the selected lines out and back in, and the change reaches the document")
    func toggleComment() throws {
        let (controller, latest) = makeEditor("let a = 1\nlet b = 2\nlet c = 3")
        let textView = controller.view.textView
        textView.selectedRange = NSRange(location: 4, length: 10)
        #expect(textView.canPerformAction(#selector(CodeTextView.toggleComment), withSender: nil))
        textView.toggleComment()
        #expect(textView.text == "// let a = 1\n// let b = 2\nlet c = 3")
        #expect(textView.selectedRange == NSRange(location: 7, length: 13))
        controller.flush()
        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "// let a = 1\n// let b = 2\nlet c = 3\n")

        textView.toggleComment()
        #expect(textView.text == "let a = 1\nlet b = 2\nlet c = 3")
    }

    @Test("⌘/ does nothing in plain text, which has no comments")
    func toggleCommentInPlainText() {
        let (controller, _) = makeEditor("hello", language: .plainText)
        let textView = controller.view.textView
        #expect(!textView.canPerformAction(#selector(CodeTextView.toggleComment), withSender: nil))
        textView.toggleComment()
        #expect(textView.text == "hello")
    }

    @Test("A long line makes the text wider than the screen rather than wrapping")
    func longLines() {
        let (controller, _) = makeEditor("let short = 1\nlet long = \"" + String(repeating: "x", count: 200) + "\"")
        let textView = controller.view.textView
        #expect(textView.frame.width > controller.view.bounds.width)
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        var fragments = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            fragments += 1
        }
        #expect(fragments == 2)
    }

    @Test("A document changed elsewhere, as by an undo, replaces the text")
    func update() {
        let (controller, _) = makeEditor("let a = 1")
        var changed = controller.document
        changed.body = PlainText.body(from: "let b = 2\nlet c = 3", format: PlainText.codeFormat)
        controller.update(document: changed, scheme: .light)
        #expect(controller.view.textView.text == "let b = 2\nlet c = 3")
        let keyword = controller.view.textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
    }

    @Test("⌘+ and ⌘− resize the text within bounds, keep its colours, and are remembered")
    func zoom() throws {
        let key = "CodeEditor.PointSize"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let (controller, _) = makeEditor("let a = 1")
        let view = controller.view
        let textView = view.textView
        #expect(view.pointSize == CodeEditorContainer.defaultPointSize)
        let gutterWidth = view.gutter.frame.width

        view.adjustPointSize(by: 4)
        #expect(view.pointSize == 18)
        let font = try #require(textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize > 17)
        #expect(view.gutter.frame.width > gutterWidth)
        let keyword = textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(keyword == SyntaxHighlighter.color(for: .keyword, scheme: .light))
        #expect(UserDefaults.standard.double(forKey: key) == 18)

        view.adjustPointSize(by: 100)
        #expect(view.pointSize == CodeEditorContainer.pointSizes.upperBound)
        view.resetPointSize()
        #expect(view.pointSize == CodeEditorContainer.defaultPointSize)
    }

    @Test("Typing colours the text as colouring it whole does, comments opened and closed included")
    func typingColours() {
        let lines = (0..<200).map { "let value\($0) = \"\($0)\" // \($0)" }
        let (controller, _) = makeEditor(lines.joined(separator: "\n"))
        let textView = controller.view.textView
        let storage = textView.textStorage
        // Told of each edit, so as to colour only around it.
        #expect(storage.delegate === controller)
        for (anchor, typed) in [("let value50", "/* "), ("let value60", "*/ "), ("value70", "x"), ("/* ", "")] {
            let found = (textView.text as NSString).range(of: anchor)
            textView.selectedRange = typed.isEmpty ? found : NSRange(location: found.location, length: 0)
            if typed.isEmpty { textView.deleteBackward() } else { textView.insertText(typed) }
            controller.textViewDidChange(textView)

            let whole = NSMutableAttributedString(attributedString: storage)
            SyntaxHighlighter.apply(.swift, to: whole, scheme: .light, plainColor: .label)
            var same = true
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { color, range, stop in
                var effective = NSRange()
                let expected = whole.attribute(.foregroundColor, at: range.location, effectiveRange: &effective) as? UIColor
                if expected != color as? UIColor || NSMaxRange(effective) < NSMaxRange(range) {
                    same = false
                    stop.pointee = true
                }
            }
            #expect(same, "after typing \(typed.debugDescription) at \(anchor)")
        }
        let comment = (textView.text as NSString).range(of: "let value55").location
        #expect(storage.attribute(.foregroundColor, at: comment, effectiveRange: nil) as? UIColor
            == SyntaxHighlighter.color(for: .keyword, scheme: .light))
    }
}
