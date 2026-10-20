import AppKit

/// The line numbers beside the code, counting the lines of the file, not the rows they wrap into.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSTextView.didChangeSelectionNotification, object: textView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        updateThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private var font: NSFont {
        let size = max(9, (textView?.font?.pointSize ?? 13) - 2)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    @objc func contentChanged() {
        updateThickness()
        needsDisplay = true
    }

    /// Wide enough for the last line's number, and never narrower than three digits.
    private func updateThickness() {
        let lines = max(1, (textView?.string as NSString?)?.components(separatedBy: "\n").count ?? 1)
        let digits = max(3, String(lines).count)
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(width + 16)
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    override var requiredThickness: CGFloat { ruleThickness }

    override func draw(_ dirtyRect: NSRect) {
        // Only within the ruler: views draw past their bounds, and this would cover the text.
        let rect = dirtyRect.intersection(bounds)
        (textView?.backgroundColor ?? .textBackgroundColor).setFill()
        rect.fill()
        drawHashMarksAndLabels(in: rect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let current = text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0))
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        // The number of the first visible line, counting the line breaks before it.
        var number = 1
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in number += 1 }

        func drawNumber(_ number: Int, lineRect: NSRect, isCurrent: Bool) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let y = offset + lineRect.minY + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }

        var location = characters.location
        while location < NSMaxRange(characters) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(number, lineRect: lineRect, isCurrent: line == current)
            number += 1
            location = NSMaxRange(line)
        }
        // The empty line after a final line break has a number too.
        if NSMaxRange(characters) == text.length, text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            drawNumber(number, lineRect: layoutManager.extraLineFragmentRect, isCurrent: current.location == text.length)
        }
    }
}
