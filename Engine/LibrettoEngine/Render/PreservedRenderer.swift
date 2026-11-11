#if canImport(UIKit) || canImport(AppKit)
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Draws a kept block, such as a content control or a table Libretto cannot
/// edit, as what it holds looks: its paragraphs and tables laid out as the
/// body's are, in pictures a line high, so it breaks across pages between
/// lines and is not edited.
public enum PreservedRenderer: Sendable {
    /// Lines not this tall, such as a drop cap's own, go with the line after them.
    private static let shortestSlice: CGFloat = 1

    public static func images(_ block: PreservedBlock, context: RenderContext) -> [PlatformImage] {
        let content = shownContent(block)
        let width = max(1, context.contentWidth)
        guard !content.isEmpty else { return [emptyImage(width: width)] }

        let rendered = DocumentRenderer.render(content, context: context)
        let storage = NSTextStorage(attributedString: rendered.string)
        // One page as wide as the text, and too tall for anything kept to fill.
        var setup = PageSetup()
        setup.width = Int((width * 20).rounded(.up))
        setup.height = 20 * 100_000
        setup.marginTop = 0
        setup.marginBottom = 0
        setup.marginLeft = 0
        setup.marginRight = 0
        let layoutManager = PageLayoutManager(geometry: PageGeometry(setup: setup, gap: 0))
        layoutManager.styles = context.styles
        layoutManager.scheme = context.scheme
        let container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.layOutPages(in: container, startingWith: 1)

        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return [emptyImage(width: width)] }
        var slices: [(top: CGFloat, bottom: CGFloat)] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            if let last = slices.last, last.bottom - last.top < shortestSlice || rect.minY < last.bottom - 0.5 {
                // A line beside the one before, as text beside a float is, or after one that takes no room.
                slices[slices.count - 1].bottom = max(last.bottom, rect.maxY)
            } else {
                slices.append((slices.last?.bottom ?? rect.minY, rect.maxY))
            }
        }
        // Never taller than a page, or the line could not be laid out at all.
        let tallest = max(24, context.contentHeight * 0.9)
        return slices.map { slice in
            let height = min(max(shortestSlice, ceil(slice.bottom - slice.top)), tallest)
            let area = CGRect(x: 0, y: slice.top, width: width, height: height)
            return PlatformImage.drawn(size: CGSize(width: width, height: height)) { graphics in
                graphics.clip(to: CGRect(origin: .zero, size: area.size))
                // The lines around it too, so what reaches into this line from them, such as a picture, is drawn.
                let shown = layoutManager.glyphRange(forBoundingRect: area.insetBy(dx: 0, dy: -height), in: container)
                let origin = CGPoint(x: 0, y: -slice.top)
                layoutManager.drawBackground(forGlyphRange: shown, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: shown, at: origin)
            }
        }
    }

    /// What a block holds, or failing that, its text as plain paragraphs.
    public static func shownContent(_ block: PreservedBlock) -> [Block] {
        if !block.content.isEmpty { return block.content }
        guard !block.displayText.isEmpty else { return [] }
        return block.displayText.components(separatedBy: "\n").map { line in
            var paragraph = Paragraph()
            if !line.isEmpty { paragraph.inlines = [Inline(.text(line))] }
            return .paragraph(paragraph)
        }
    }

    /// A control with nothing in it still takes a line, so it can be seen and selected.
    private static func emptyImage(width: CGFloat) -> PlatformImage {
        PlatformImage.drawn(size: CGSize(width: width, height: 14)) { _ in }
    }
}
#endif
