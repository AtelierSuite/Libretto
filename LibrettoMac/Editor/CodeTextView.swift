import AppKit

/// The code editor's text, with the line the insertion point is on lightly highlighted.
final class CodeTextView: NSTextView {
    /// Where the current line is drawn, so it can be redrawn when the insertion point leaves it.
    private var highlightedRect: NSRect?

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
