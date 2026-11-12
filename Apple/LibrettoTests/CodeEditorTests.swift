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

    @Test("Typing keeps the file's line endings and encoding, until it types what the encoding cannot write")
    func textFile() throws {
        let file = try #require("let a = \"あ\"\r\n".data(using: .shiftJIS))
        var document = PlainText.document(from: file, format: PlainText.codeFormat)
        document.sourceLanguage = .swift
        let controller = CodeEditorController(document: document, language: .swift, scheme: .light)
        var latest: WordDocument?
        controller.onChange = { latest = $0 }
        let textView = controller.view.textView

        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.insertText("\nlet b = \"い\"")
        controller.textViewDidChange(textView)
        controller.flush()
        var typed = try #require(latest)
        #expect(typed.lineEnding == .crlf)
        #expect(typed.textEncoding == .shiftJIS)
        #expect(PlainText.data(from: typed) == "let a = \"あ\"\r\nlet b = \"い\"\r\n".data(using: .shiftJIS))

        textView.insertText(" // 🙂")
        controller.textViewDidChange(textView)
        controller.flush()
        typed = try #require(latest)
        #expect(typed.lineEnding == .crlf)
        #expect(typed.textEncoding == .utf8)
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

    @Test("Typing on the widest line widens the text without laying out the rest of it again")
    func typingOnWidestLine() {
        let lines = ["let long = \"" + String(repeating: "x", count: 100) + "\""] + (0..<2000).map { "let value\($0) = \($0)" }
        let (controller, _) = makeEditor(lines.joined(separator: "\n"))
        let textView = controller.view.textView
        let layoutManager = textView.layoutManager
        let length = (textView.text as NSString).length
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
        let width = textView.frame.width

        textView.selectedRange = NSRange(location: (lines[0] as NSString).length, length: 0)
        for key in ["a", "b", "c", "d"] { type(key, in: controller) }
        #expect(textView.frame.width > width)
        // Laid out still, past what was typed: the lines under it were not laid out again.
        #expect(layoutManager.firstUnlaidCharacterIndex() > length)
        // And the widest line is still one line, not wrapped.
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: (lines[0] as NSString).length + 4), actualCharacterRange: nil)
        var fragments = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in fragments += 1 }
        #expect(fragments == 1)
    }

    @Test("The text is as wide as its widest line as it is typed, shortened, broken and joined")
    func widthFollowsTyping() {
        let long = "let long = \"" + String(repeating: "x", count: 100) + "\""
        let (controller, _) = makeEditor("let a = 1\n" + long + "\nlet b = 2")
        let textView = controller.view.textView
        let text = { textView.text as NSString }
        let width = textView.frame.width
        let character = (" " as NSString).size(withAttributes: [.font: controller.view.font]).width

        // Elsewhere: no wider.
        textView.selectedRange = NSRange(location: 3, length: 0)
        type("zz", in: controller)
        #expect(textView.frame.width == width)
        // On the widest line: wider, and narrower again as it is taken back.
        let end = NSMaxRange(text().range(of: long))
        textView.selectedRange = NSRange(location: end, length: 0)
        type("yyy", in: controller)
        #expect(abs(textView.frame.width - (width + 3 * character)) < 1)
        textView.selectedRange = NSRange(location: end, length: 3)
        textView.deleteBackward()
        controller.textViewDidChange(textView)
        #expect(abs(textView.frame.width - width) < 1)
        // Broken in two, the widest line is the longer half; joined, it is whole again.
        let middle = text().range(of: long).location + 60
        textView.selectedRange = NSRange(location: middle, length: 0)
        textView.insertText("\n")
        controller.textViewDidChange(textView)
        #expect(textView.frame.width < width - 30 * character)
        textView.deleteBackward()
        controller.textViewDidChange(textView)
        #expect(abs(textView.frame.width - width) < 1)
        // Another line made longer than it takes its place.
        textView.selectedRange = NSRange(location: text().length, length: 0)
        type(" // " + String(repeating: "w", count: 140), in: controller)
        #expect(textView.frame.width > width + 20 * character)
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

    // MARK: - Indent

    @Test("The indent unit is what the file's lines are indented with", arguments: [
        ("func f() {\n\tlet a = 1\n\tif a {\n\t\tg()\n\t}\n}", IndentUnit.tab),
        ("def f():\n    a = 1\n    if a:\n        g()\n", .spaces(4)),
        ("a:\n  b:\n    c: 1\n  d: 2\n", .spaces(2)),
        ("/*\n * A comment\n */\nfunc f() {\n    g(a,\n      b)\n    h()\n}", .spaces(4)),
    ])
    func detect(source: String, unit: IndentUnit) {
        #expect(IndentUnit.detect(in: source) == unit)
    }

    @Test("A file with no indented lines says nothing of its unit")
    func detectNothing() {
        #expect(IndentUnit.detect(in: "") == nil)
        #expect(IndentUnit.detect(in: "a\nb\n\nc") == nil)
        let (controller, _) = makeEditor("let a = 1")
        #expect(controller.indentUnit == .standard)
    }

    @Test("Tab indents each selected line, blank ones aside, and Shift-Tab takes the indent off again")
    func indentLines() throws {
        let source = "func f() {\n\tlet a = 1\n\n\tg()\n}"
        let (controller, latest) = makeEditor(source)
        #expect(controller.indentUnit == .tab)
        let textView = controller.view.textView
        // From the start of the second line to the start of the last, which is not taken in.
        let start = ("func f() {\n" as NSString).length
        textView.selectedRange = NSRange(location: start, length: (source as NSString).length - 1 - start)
        controller.insertTab()
        #expect(textView.text == "func f() {\n\t\tlet a = 1\n\n\t\tg()\n}")
        // The selection still takes in the whole of the lines.
        #expect(textView.selectedRange == NSRange(location: start, length: ("\t\tlet a = 1\n\n\t\tg()\n" as NSString).length))
        controller.flush()
        let document = try #require(latest())
        #expect(String(decoding: PlainText.data(from: document), as: UTF8.self) == "func f() {\n\t\tlet a = 1\n\n\t\tg()\n}\n")

        controller.outdent()
        controller.outdent()
        #expect(textView.text == "func f() {\nlet a = 1\n\ng()\n}")
        // Nothing left to take off.
        controller.outdent()
        #expect(textView.text == "func f() {\nlet a = 1\n\ng()\n}")
    }

    @Test("Tab within a line types the spaces to the next level, and the indent commands move a caret with its line")
    func caret() {
        let (controller, _) = makeEditor("if a {\n    b()\n}")
        #expect(controller.indentUnit == .spaces(4))
        let textView = controller.view.textView
        // After "    b", a column past the level: three spaces reach the next.
        textView.selectedRange = NSRange(location: ("if a {\n    b" as NSString).length, length: 0)
        controller.insertTab()
        #expect(textView.text == "if a {\n    b   ()\n}")
        #expect(textView.selectedRange == NSRange(location: ("if a {\n    b   " as NSString).length, length: 0))

        controller.indent()
        #expect(textView.text == "if a {\n        b   ()\n}")
        #expect(textView.selectedRange == NSRange(location: ("if a {\n        b   " as NSString).length, length: 0))
        controller.outdent()
        controller.outdent()
        #expect(textView.text == "if a {\nb   ()\n}")
        #expect(textView.selectedRange == NSRange(location: ("if a {\nb   " as NSString).length, length: 0))
    }

    @Test("Another unit chosen is what lines are indented with, and outdenting takes off a tab or a level of spaces")
    func chosenUnit() {
        let (controller, _) = makeEditor("a\n\tb\n  c")
        let textView = controller.view.textView
        controller.indentUnit = .spaces(2)
        textView.selectedRange = NSRange(location: 0, length: (textView.text as NSString).length)
        controller.insertTab()
        #expect(textView.text == "  a\n  \tb\n    c")
        controller.outdent()
        controller.outdent()
        #expect(textView.text == "a\nb\nc")
    }

    @Test("A unit outside the usual ones is offered alongside them")
    func choices() {
        #expect(IndentUnit.spaces(4).choices == IndentUnit.choices)
        #expect(IndentUnit.spaces(3).choices == [.tab, .spaces(2), .spaces(3), .spaces(4), .spaces(8)])
        #expect(IndentUnit.choices.allSatisfy { IndentUnit(id: $0.id) == $0 })
    }

    @Test("Go to Line puts the caret at the line's start and scrolls it into view, a number past the end taken as the last line")
    func goToLine() {
        let source = (1...300).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let (controller, _) = makeEditor(source)
        let textView = controller.view.textView
        #expect(controller.lineCount == 300)

        /// Whether the line starting at `location` is on screen.
        func isInView(_ location: Int) -> Bool {
            let layoutManager = textView.layoutManager
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            return textView.bounds.intersects(rect.offsetBy(dx: 0, dy: textView.textContainerInset.top))
        }

        let location = PlainText.location(ofLine: 250, in: source)
        #expect(!isInView(location))
        controller.goToLine(250)
        #expect(textView.selectedRange == NSRange(location: location, length: 0))
        #expect((textView.text as NSString).substring(from: location).hasPrefix("let line250 "))
        #expect(isInView(location))

        controller.goToLine(1000)
        #expect(textView.selectedRange.location == PlainText.location(ofLine: 300, in: source))
        controller.goToLine(1)
        #expect(textView.selectedRange.location == 0)
        #expect(isInView(0))
    }
}
