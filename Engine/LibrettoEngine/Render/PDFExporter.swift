#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Prints a document to PDF, laid out in pages exactly as the page view shows it.
public enum PDFExporter: Sendable {
    public static func data(from document: WordDocument) -> Data {
        let pages = PrintedPages(document: document)
        return PlatformGraphics.pdf(pages: pages.sizes) { page, _ in pages.draw(page) }
    }
}

/// A document laid out in pages for printing, each page drawn on its own:
/// what the PDF holds, and what rendering tests compare page by page.
public final class PrintedPages {
    /// The size of each page, in points.
    public let sizes: [CGSize]
    public var count: Int { sizes.count }

    private let storage: NSTextStorage
    private let layoutManager: PageLayoutManager
    private let container: NSTextContainer
    private let texts: WordDocumentHeaderFooter

    public init(document: WordDocument) {
        let context = RenderContext(document: document, scheme: .light, images: ImageStore())
        let rendered = DocumentRenderer.render(document.body, context: context)

        storage = NSTextStorage(attributedString: rendered.string)
        if let language = document.sourceLanguage {
            SyntaxHighlighter.apply(language, to: storage, scheme: .light, plainColor: context.defaultTextColor)
        }
        layoutManager = PageLayoutManager(geometry: PageGeometry(setup: document.pageSetup, gap: 0))
        layoutManager.styles = document.styles
        layoutManager.footnotes = NoteLayout.notes(in: storage, document: document, context: context)
        layoutManager.sections = SectionLayout.spans(in: storage, final: document.pageSetup)
        container = NSTextContainer()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let pages = layoutManager.layOutPages(in: container, startingWith: 4)
        // The pages as they settled, each section's at its own size.
        let geometry = layoutManager.geometry
        texts = WordDocumentHeaderFooter(
            document: document, sections: layoutManager.sections.map(\.setup), pageSections: layoutManager.pageSections
        )
        sizes = (0..<pages).map { geometry.shape($0).size }
    }

    /// Draws one page, top down, in the current context, from its top left corner.
    public func draw(_ page: Int) {
        guard let graphics = PlatformGraphics.currentContext else { return }
        let geometry = layoutManager.geometry
        let shape = geometry.shape(page)
        let top = geometry.textTop(page)
        let visible = CGRect(x: 0, y: top, width: geometry.contentWidth, height: shape.contentHeight)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let origin = CGPoint(x: geometry.textLeft, y: shape.margins.top - top)

        graphics.saveGState()
        graphics.clip(to: CGRect(
            x: shape.margins.left - 40, y: shape.margins.top - 2,
            width: shape.contentWidth + 80, height: shape.contentHeight + 4
        ))
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        graphics.restoreGState()

        HeaderFooterDrawing.draw(texts, page: page, of: count, shape: shape, color: .darkGray)
        if let notes = layoutManager.notesByPage[page], let height = layoutManager.noteHeights[page] {
            PageLayoutManager.drawNotes(notes, in: CGRect(
                x: shape.margins.left, y: shape.margins.top + shape.contentHeight - height,
                width: shape.contentWidth, height: height
            ), color: .black)
        }
    }

    /// One page as a picture on white paper, `scale` pixels to the point.
    public func image(_ page: Int, scale: CGFloat = 1) -> CGImage? {
        PlatformGraphics.bitmap(size: sizes[page], scale: scale) { [self] context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: sizes[page]))
            draw(page)
        }
    }
}

/// The header and footer, drawn as plain text in the page's margins.
public enum HeaderFooterDrawing: Sendable {
    public static var font: PlatformFont { .systemFont(ofSize: 9) }

    public static func frames(_ section: WordDocumentHeaderFooter.Section, shape: PageGeometry.Shape) -> (header: CGRect, footer: CGRect) {
        let header = CGRect(
            x: shape.margins.left, y: section.headerDistance,
            width: shape.contentWidth, height: max(12, shape.margins.top - section.headerDistance)
        )
        let footerHeight: CGFloat = 24
        let footer = CGRect(
            x: shape.margins.left, y: shape.size.height - section.footerDistance - footerHeight,
            width: shape.contentWidth, height: footerHeight
        )
        return (header, footer)
    }

    public static func attributed(_ text: HeaderFooterText, page: Int, of count: Int, format: String? = nil, color: PlatformColor)
        -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        switch text.alignment {
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        default: style.alignment = .natural
        }
        // Tabs in headers usually push text to the centre and right tab stops Word's styles define.
        let resolved = text.resolved(page: page + 1, of: count, format: format).replacingOccurrences(of: "\t", with: "    ")
        return NSAttributedString(
            string: resolved, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    public static func draw(_ texts: WordDocumentHeaderFooter, page: Int, of count: Int, shape: PageGeometry.Shape, color: PlatformColor) {
        let section = texts.section(forPage: page)
        let frames = frames(section, shape: shape)
        if let header = texts.header(forPage: page) {
            attributed(header, page: page, of: count, format: section.pageNumberFormat, color: color)
                .draw(with: frames.header, options: [.usesLineFragmentOrigin], context: nil)
        }
        if let footer = texts.footer(forPage: page) {
            let text = attributed(footer, page: page, of: count, format: section.pageNumberFormat, color: color)
            let height = text.boundingRect(
                with: CGSize(width: frames.footer.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], context: nil
            ).height
            var frame = frames.footer
            frame.origin.y = frame.maxY - ceil(height)
            frame.size.height = ceil(height)
            text.draw(with: frame, options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}
#endif
