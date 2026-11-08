import AppKit
import LibrettoEngine

/// The code editor's text, with the line the insertion point is on lightly
/// highlighted, and its lines indented and outdented a level at a time.
final class CodeTextView: NSTextView {
    /// Whose comment markers Toggle Comment writes.
    var language = SourceLanguage.plainText
    /// Where the current line is drawn, so it can be redrawn when the insertion point leaves it.
    private var highlightedRect: NSRect?

    /// What Tab and the indent commands put before a line: what the file's
    /// lines are indented with, unless another is chosen.
    var indentUnit: IndentUnit = .standard

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lineRect = currentLineRect(), lineRect.intersects(rect) else { return }
        NSColor.textColor.withAlphaComponent(0.05).setFill()
        lineRect.fill()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        refreshCurrentLine()
    }

    override func didChangeText() {
        super.didChangeText()
        refreshCurrentLine()
    }

    /// Comments out the current or selected lines, or uncomments them. The
    /// change reaches the delegate as typing does.
    @objc func toggleComment(_ sender: Any?) {
        guard isEditable, let edit = CodeComments.toggle(in: string, selection: selectedRange(), language: language),
              shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
    }

    // MARK: - Indent

    /// Indents the selected lines, where the selection runs onto another,
    /// and otherwise types an indent in place of the selection.
    override func insertTab(_ sender: Any?) {
        let text = string as NSString
        if IndentUnit.selectsLines(selectedRange(), in: text) {
            increaseIndent(sender)
        } else {
            apply(indentUnit.insertion(in: text, at: selectedRange()))
        }
    }

    override func insertBacktab(_ sender: Any?) {
        decreaseIndent(sender)
    }

    /// Puts a level of indent before each line the selection is on.
    @objc func increaseIndent(_ sender: Any?) {
        apply(indentUnit.indent(string as NSString, selection: selectedRange()))
    }

    /// Takes a level of indent from each line the selection is on.
    @objc func decreaseIndent(_ sender: Any?) {
        apply(indentUnit.outdent(string as NSString, selection: selectedRange()))
    }

    /// Indents with the unit a menu item stands for, its tag being the unit's.
    @objc func chooseIndentUnit(_ sender: NSMenuItem) {
        guard let unit = IndentUnit(id: sender.tag) else { return }
        indentUnit = unit
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(chooseIndentUnit(_:)):
            (item as? NSMenuItem)?.state = item.tag == indentUnit.id ? .on : .off
            return true
        case #selector(increaseIndent(_:)), #selector(decreaseIndent(_:)):
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// Makes the edit as typing would, so the editor hands it to the document.
    private func apply(_ edit: IndentEdit?) {
        guard let edit, isEditable, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(edit.selection)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleComment(_:)) { return isEditable && language.commentMarkers != nil }
        return super.validateMenuItem(menuItem)
    }

    private func refreshCurrentLine() {
        if let highlightedRect { setNeedsDisplay(highlightedRect) }
        highlightedRect = currentLineRect()
        if let highlightedRect { setNeedsDisplay(highlightedRect) }
    }

    /// The whole width of the line, every row of it where it wraps, while nothing is selected.
    private func currentLineRect() -> NSRect? {
        guard let layoutManager, let textContainer, selectedRange().length == 0 else { return nil }
        let text = string as NSString
        let location = selectedRange().location
        var rect: NSRect
        if location >= text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            // After a final line break, on the empty line the layout keeps apart.
            rect = layoutManager.extraLineFragmentRect
        } else {
            let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }
        guard !rect.isEmpty || rect.height > 0 else { return nil }
        rect.origin.x = 0
        rect.size.width = bounds.width
        rect.origin.y += textContainerOrigin.y
        return rect
    }
}
