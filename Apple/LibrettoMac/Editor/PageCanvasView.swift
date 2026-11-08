import AppKit
import LibrettoEngine

/// A column of pages, with the document's one text view laid over them so
/// its text falls on the pages' printable areas. It is the scroll view's
/// document view, and zooms with its magnification.
final class PageCanvasView: NSView {
    /// Space between pages.
    static let pageGap: CGFloat = 20
    /// Space around the column.
    private static let inset: CGFloat = 32

    private let textView: NSTextView
    private var geometry: PageGeometry?
    private var pages = 0
    private var texts = WordDocumentHeaderFooter()
    private var notes = PageNotes()
    /// Where the column of pages starts across, to keep it in the middle of a wider window.
    private var columnLeft: CGFloat = 0

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        addSubview(textView)
        setAccessibilityIdentifier("pages")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    func update(geometry: PageGeometry, pages: Int, texts: WordDocumentHeaderFooter, notes: PageNotes) {
        guard geometry != self.geometry || pages != self.pages || texts != self.texts || notes != self.notes else { return }
        self.geometry = geometry
        self.pages = pages
        self.texts = texts
        self.notes = notes
        layoutPages()
        needsDisplay = true
    }

    /// Sizes the canvas to the pages, at least as wide as what the scroll view shows, and puts the text on them.
    func layoutPages() {
        guard let geometry else { return }
        let visibleWidth = enclosingScrollView.map { $0.contentView.bounds.width } ?? 0
        let columnWidth = geometry.widestPage + Self.inset * 2
        let width = max(columnWidth, visibleWidth)
        columnLeft = floor((width - columnWidth) / 2) + Self.inset
        let size = CGSize(width: width, height: geometry.totalHeight(pages: pages) + Self.inset * 2)
        if frame.size != size { setFrameSize(size) }
        let textFrame = CGRect(
            x: columnLeft + geometry.textLeft, y: Self.inset + geometry.margins.top,
            width: geometry.contentWidth, height: max(1, geometry.totalHeight(pages: pages) - geometry.margins.top)
        )
        if textView.frame != textFrame { textView.frame = textFrame }
    }

    private func pageFrame(_ index: Int) -> CGRect {
        geometry?.pageFrame(index).offsetBy(dx: columnLeft, dy: Self.inset) ?? .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let geometry, let context = NSGraphicsContext.current?.cgContext else { return }
        let paper = NSColor.textBackgroundColor
        let ink = NSColor.secondaryLabelColor
        for index in 0..<pages {
            let frame = pageFrame(index)
            guard frame.insetBy(dx: -12, dy: -12).intersects(dirtyRect) else { continue }
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            paper.setFill()
            frame.fill()
            context.restoreGState()

            let shape = geometry.shape(index)
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            HeaderFooterDrawing.draw(texts, page: index, of: pages, shape: shape, color: ink)
            if let pageNotes = notes.byPage[index], let height = notes.heights[index] {
                PageLayoutManager.drawNotes(pageNotes, in: CGRect(
                    x: shape.margins.left, y: shape.margins.top + shape.contentHeight - height,
                    width: shape.contentWidth, height: height
                ), color: .labelColor)
            }
            context.restoreGState()
        }
    }

    /// A click in a page's margin puts the caret on the nearest text.
    override func mouseDown(with event: NSEvent) {
        let point = textView.convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(
            x: min(max(point.x, 0), textView.bounds.width - 1), y: min(max(point.y, 0), textView.bounds.height - 1)
        )
        let index = textView.characterIndexForInsertion(at: clamped)
        textView.setSelectedRange(NSRange(location: index, length: 0))
        window?.makeFirstResponder(textView)
    }
}
