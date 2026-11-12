#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where the pages are, in the text container's coordinates.
///
/// The whole document is set in one tall text container, as wide as the
/// widest page's text. The band between one page's text and the next —
/// bottom margin, the gap between pages, top margin — is excluded from the
/// container, so lines skip it and the text breaks into pages by itself,
/// while staying one text that edits, selects and scrolls as one. Pages may
/// differ, section by section: a narrower page's text is kept to its own
/// width by exclusions at its sides.
public struct PageGeometry: Equatable, Sendable {
    /// One page's size and margins, in points.
    public struct Shape: Equatable, Sendable {
        public var size: CGSize
        public var margins: PlatformEdgeInsets

        public init(setup: PageSetup) {
            size = setup.size
            margins = PlatformEdgeInsets(
                top: CGFloat(setup.marginTop) / 20, left: CGFloat(setup.marginLeft) / 20,
                bottom: CGFloat(setup.marginBottom) / 20, right: CGFloat(setup.marginRight) / 20
            )
            // Margins so wide there is no page left would leave nowhere for text.
            let minimum: CGFloat = 72
            if size.width - margins.left - margins.right < minimum {
                margins.left = (size.width - minimum) / 2
                margins.right = margins.left
            }
            if size.height - margins.top - margins.bottom < minimum {
                margins.top = (size.height - minimum) / 2
                margins.bottom = margins.top
            }
        }

        public var contentWidth: CGFloat { size.width - margins.left - margins.right }
        public var contentHeight: CGFloat { size.height - margins.top - margins.bottom }
    }

    /// Each page's shape, in order; pages past the last are shaped like it.
    public private(set) var shapes: [Shape]
    /// Space between pages on screen; none in a PDF.
    public var gap: CGFloat
    /// Each listed page's top, in the column of pages.
    private var tops: [CGFloat] = []

    public init(setup: PageSetup, gap: CGFloat) {
        self.init(shapes: [Shape(setup: setup)], gap: gap)
    }

    public init(shapes: [Shape], gap: CGFloat) {
        self.shapes = shapes.isEmpty ? [Shape(setup: PageSetup())] : shapes
        self.gap = gap
        var top: CGFloat = 0
        tops = self.shapes.map { shape in
            defer { top += shape.size.height + gap }
            return top
        }
    }

    public func shape(_ index: Int) -> Shape { shapes[min(max(0, index), shapes.count - 1)] }

    /// The first page's size and margins.
    public var pageSize: CGSize { shapes[0].size }
    public var margins: PlatformEdgeInsets { shapes[0].margins }

    /// Where the container's left edge is on a page: the leftmost any page's text starts.
    public var textLeft: CGFloat { shapes.map(\.margins.left).min() ?? 0 }
    /// The container's width: to the rightmost any page's text reaches.
    public var contentWidth: CGFloat {
        (shapes.map { $0.size.width - $0.margins.right }.max() ?? 0) - textLeft
    }
    /// The least height of text on any page: what must fit on whichever page it falls.
    public var contentHeight: CGFloat { shapes.map(\.contentHeight).min() ?? 0 }
    /// The least width of text on any page.
    public var narrowestWidth: CGFloat { shapes.map(\.contentWidth).min() ?? 0 }

    /// Page `index`'s top, in the column of pages.
    public func pageTop(_ index: Int) -> CGFloat {
        if index < tops.count { return tops[max(0, index)] }
        let last = shapes.count - 1
        return tops[last] + CGFloat(index - last) * (shapes[last].size.height + gap)
    }

    /// Where page `index`'s text starts and ends, in the container.
    public func textTop(_ index: Int) -> CGFloat { pageTop(index) + shape(index).margins.top - margins.top }
    public func textBottom(_ index: Int) -> CGFloat { textTop(index) + shape(index).contentHeight }

    /// The band between page `index`'s text and the next page's.
    public func band(after index: Int, reserving reserve: CGFloat = 0) -> CGRect {
        let top = textBottom(index) - reserve
        return CGRect(x: -1, y: top, width: contentWidth + 2, height: textTop(index + 1) - top)
    }

    /// What lies beside page `index`'s text in a container wider than it.
    public func sides(of index: Int) -> [CGRect] {
        let shape = self.shape(index)
        let left = shape.margins.left - textLeft
        let right = left + shape.contentWidth
        let top = textTop(index)
        let height = shape.contentHeight
        var result: [CGRect] = []
        if left > 0.5 { result.append(CGRect(x: -1, y: top, width: left + 1, height: height)) }
        if contentWidth - right > 0.5 { result.append(CGRect(x: right, y: top, width: contentWidth - right + 1, height: height)) }
        return result
    }

    public func page(containing y: CGFloat) -> Int {
        let column = y + margins.top
        if let index = tops.lastIndex(where: { $0 <= column }), index < tops.count - 1 { return index }
        let last = shapes.count - 1
        let pitch = shapes[last].size.height + gap
        return max(0, last + Int(floor((column - tops[last]) / pitch)))
    }

    /// The pages text that ends at `height` in the container needs.
    public func pageCount(forUsedHeight height: CGFloat) -> Int {
        max(1, page(containing: max(0, height - 0.5)) + 1)
    }

    /// Where page `index` sits in a column of pages.
    public func pageFrame(_ index: Int) -> CGRect {
        CGRect(origin: CGPoint(x: 0, y: pageTop(index)), size: shape(index).size)
    }

    public func totalHeight(pages: Int) -> CGFloat {
        pageTop(pages) - gap
    }

    /// The widest page.
    public var widestPage: CGFloat { shapes.map(\.size.width).max() ?? 0 }
}

/// Lays text out in pages: page breaks end the page, and list labels are
/// drawn in the indent.
public final class PageLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    public var geometry: PageGeometry
    public var styles = StyleSheet()
    /// The appearance borders and shading are drawn for.
    public var scheme: ColorScheme = .light
    /// The text comments are on, shaded behind it; the comment at the
    /// selection more strongly than the rest.
    public var commentRanges: [NSRange] = []
    public var activeCommentRanges: [NSRange] = []
    /// Whether kept blocks, which cannot be edited, are outlined: on screen, not in print.
    public var outlinesKeptBlocks = false

    public init(geometry: PageGeometry) {
        self.geometry = geometry
        super.init()
        delegate = self
        allowsNonContiguousLayout = false
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Sets the container up for `pages` pages of text.
    /// How many pages the container was last set up for.
    private var configuredPages = 0

    public func configure(_ container: NSTextContainer, pages: Int) {
        configuredPages = pages
        container.size = CGSize(width: geometry.contentWidth, height: geometry.totalHeight(pages: pages + 1))
        container.lineFragmentPadding = 0
        container.exclusionPaths = (0..<pages).flatMap { page in
            [PlatformBezierPath(rect: geometry.band(after: page, reserving: noteHeights[page] ?? 0))]
                + geometry.sides(of: page).map { PlatformBezierPath(rect: $0) }
        } + dropCapExclusions.map { PlatformBezierPath(rect: $0) }
    }

    // MARK: - Sections

    /// A section: the last character it holds, its section break's mark, and its page setup.
    public struct SectionSpan: Equatable, Sendable {
        public var end: Int
        public var setup: PageSetup

        public init(end: Int, setup: PageSetup) {
            self.end = end
            self.setup = setup
        }
    }

    /// The document's sections, in order, the last running to the end.
    public var sections: [SectionSpan] = [] {
        didSet {
            // A section come, gone or changed lays the text out afresh. Typing only moves where
            // sections end, and the text it changes is laid out afresh anyway.
            guard oldValue.map(\.setup) != sections.map(\.setup), let storage = textStorage else { return }
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }
    /// Which section each page is in, as laid out.
    public private(set) var pageSections: [Int] = []

    // MARK: - Columns

    /// Whether lines are put in their columns; not while the text is measured without pages.
    var columnsEnabled = true
    /// Where each section's columns, balanced on its last page, end there, by section.
    public internal(set) var columnBalance: [Int: ColumnBalance] = [:]

    /// The section a character is in.
    public func section(at location: Int) -> Int {
        sections.firstIndex { location <= $0.end } ?? max(0, sections.count - 1)
    }

    /// Each page shaped as the section it starts in is, the pages it took last time over.
    private func placeSections(pages: Int) -> (shapes: [PageGeometry.Shape], pageSections: [Int]) {
        guard sections.count > 1, let container = textContainers.first, let storage = textStorage else {
            let shape = sections.first.map { PageGeometry.Shape(setup: $0.setup) } ?? geometry.shape(0)
            return ([shape], Array(repeating: 0, count: pages))
        }
        var shapes: [PageGeometry.Shape] = []
        var owners: [Int] = []
        var owner = 0
        for page in 0..<pages {
            let area = CGRect(x: 0, y: geometry.textTop(page), width: geometry.contentWidth, height: geometry.shape(page).contentHeight)
            let glyphs = glyphRange(forBoundingRect: area, in: container)
            if glyphs.length > 0 {
                let first = characterIndexForGlyph(at: glyphs.location)
                if first < storage.length { owner = max(owner, section(at: first)) }
            }
            owners.append(owner)
            shapes.append(PageGeometry.Shape(setup: sections[owner].setup))
        }
        return (shapes, owners)
    }

    /// The section break a paragraph mark is, if it is one: the section it starts.
    private func sectionStarted(byMarkAt index: Int) -> SectionSpan? {
        guard let ending = sections.firstIndex(where: { $0.end == index }), ending + 1 < sections.count else { return nil }
        return sections[ending + 1]
    }

    // MARK: - Footnotes

    /// Notes to set at the foot of the page their reference falls on: where
    /// the reference is in the text, and the note as it is drawn.
    public var footnotes: [(location: Int, text: NSAttributedString)] = []
    /// What each page keeps clear at its foot for its notes, and the notes.
    public private(set) var noteHeights: [Int: CGFloat] = [:]
    public private(set) var notesByPage: [Int: [NSAttributedString]] = [:]

    /// Space between the text and a page's notes, where the separator is drawn.
    public static let noteSeparatorSpace: CGFloat = 12

    /// Lays everything out, adding pages until the text fits, and making
    /// room at the foot of each page for the notes referred to on it.
    /// Returns how many pages it takes.
    ///
    /// Room made for notes can push a reference on to the next page, so the
    /// notes are placed again until they settle, a few times at most.
    @discardableResult
    public func layOutPages(in container: NSTextContainer, startingWith estimate: Int) -> Int {
        var pages = layOutText(in: container, startingWith: estimate)
        // Drop caps are placed the same way: where the paragraph they start falls decides where they go.
        // So are the pages' sizes, where sections differ: a page is shaped as the section it starts in.
        for _ in 0..<6 {
            let placed = footnotes.isEmpty && noteHeights.isEmpty ? (byPage: [:], heights: [:]) : placeNotes()
            let caps = placeDropCaps()
            let paged = placeSections(pages: pages)
            let floating = placeFloats(pages: pages)
            let balance = balanceColumns()
            notesByPage = placed.byPage
            dropCaps = caps
            pageSections = paged.pageSections
            placedFloats = floating.floats
            let exclusions = caps.compactMap(\.exclusion) + floating.exclusions
            let shaped = PageGeometry(shapes: paged.shapes, gap: geometry.gap)
            guard placed.heights != noteHeights || exclusions != dropCapExclusions || shaped != geometry
                || balance != columnBalance else { break }
            if balance != columnBalance, let storage = textStorage {
                columnBalance = balance
                invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            }
            noteHeights = placed.heights
            dropCapExclusions = exclusions
            geometry = shaped
            configure(container, pages: pages)
            pages = layOutText(in: container, startingWith: pages)
        }
        return pages
    }

    // MARK: - Floating pictures

    /// A floating picture where the layout set it, in the container, and the page it is on.
    public struct PlacedFloat: Equatable, Sendable {
        public var frame: CGRect
        public var page: Int
        public var image: PlatformImage
        public var behindText: Bool
        /// The picture's character in the text, which takes no room of its own.
        public var location: Int

        public init(frame: CGRect, page: Int, image: PlatformImage, behindText: Bool, location: Int) {
            self.frame = frame
            self.page = page
            self.image = image
            self.behindText = behindText
            self.location = location
        }
    }

    public private(set) var placedFloats: [PlacedFloat] = []
    /// Where the pictures a paragraph holds top and bottom start, by the
    /// paragraph's first character: the room its first line makes for them.
    private var floatTops: [Int: CGFloat] = [:]

    /// Whether a floating picture keeps text above and below it, placed down
    /// from its paragraph: one its paragraph makes room for.
    private static func isReservedInParagraph(_ picture: InlineImage) -> Bool {
        picture.wrap == .topAndBottom && picture.verticalAnchor == .paragraph && picture.page == nil
    }

    /// How far a floating object at `scale` is drawn past its frame, and how far text keeps clear past it.
    private static func overhangs(_ picture: InlineImage, scale: CGFloat)
        -> (drawn: ObjectRenderer.Overhang, kept: ObjectRenderer.Overhang) {
        guard let object = picture.object else { return (.zero, .zero) }
        let size = CGSize(width: picture.width, height: picture.height)
        return (
            ObjectRenderer.overhang(for: object, size: size).scaled(by: scale),
            ObjectRenderer.overhang(for: object, size: size, effects: false).scaled(by: scale)
        )
    }

    /// A floating picture's size on a page: no larger than the page, if it
    /// is placed on the page, or than the text, if beside its paragraph.
    private func floatSize(_ picture: InlineImage, page: Int) -> CGSize {
        let shape = geometry.shape(page)
        let isOnPage = picture.isHorizontalFromPage && picture.verticalAnchor == .page
        let room = isOnPage ? shape.size : CGSize(width: shape.contentWidth, height: shape.contentHeight * 0.9)
        let scale = min(1, room.width / max(picture.width, 1), room.height / max(picture.height, 1))
        return CGSize(width: picture.width * scale, height: picture.height * scale)
    }

    /// The room the first line of a paragraph makes above itself for the
    /// pictures in the paragraph that keep text above and below them, as Word
    /// sets the paragraph's text below them; whether it made any.
    ///
    /// Made in the line rather than kept clear of the text afterwards, so
    /// where the pictures go never depends on where the room for them moved
    /// the paragraph to: placed from the line they push down, they would follow
    /// it, push it on again, and never settle. Pictures and line that don't
    /// fit on what is left of the page start the next page together.
    private func reserveFloats(
        _ rect: UnsafeMutablePointer<CGRect>, used: UnsafeMutablePointer<CGRect>, baseline: UnsafeMutablePointer<CGFloat>,
        characters: NSRange
    ) -> Bool {
        guard let storage = textStorage, characters.location < storage.length else { return false }
        let string = storage.string as NSString
        let start = characters.location
        guard start == 0 || string.character(at: start - 1) == TextCharacters.paragraphBreakUnit,
              storage.attribute(.librettoBlock, at: start, effectiveRange: nil) == nil else {
            return false
        }
        let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
        var line = rect.pointee
        let page = geometry.page(containing: line.minY + 0.5)
        var reserve: CGFloat = 0
        storage.enumerateAttribute(.attachment, in: paragraph) { value, _, _ in
            guard let attachment = value as? ImageAttachment, case .image(let picture) = attachment.inline.content,
                  Self.isReservedInParagraph(picture) else { return }
            let size = floatSize(picture, page: page)
            let kept = Self.overhangs(picture, scale: size.width / max(picture.width, 1)).kept
            reserve = max(reserve, picture.verticalOffset + kept.top + size.height + kept.bottom + picture.wrapDistances.bottom)
        }
        guard reserve > 0 else {
            floatTops[start] = nil
            return false
        }
        var top = line.minY
        if top > geometry.textTop(page) + 1, top + reserve + line.height > geometry.textBottom(page) - (noteHeights[page] ?? 0) {
            top = geometry.textTop(page + 1)
        }
        let added = top - line.minY + reserve
        line.size.height += added
        rect.pointee = line
        used.pointee.origin.y += added
        baseline.pointee += added
        floatTops[start] = top
        return true
    }
    /// The narrowest space beside a picture that text wrapped tight or through goes into, in points.
    public static let narrowestWrap: CGFloat = 72
    private var floatExclusions: [CGRect] = []

    /// Each floating picture beside its paragraph, or where on the page it says, and what text keeps clear of.
    private func placeFloats(pages: Int) -> (floats: [PlacedFloat], exclusions: [CGRect]) {
        guard let storage = textStorage else { return ([], []) }
        let string = storage.string as NSString
        var floats: [PlacedFloat] = []
        var exclusions: [CGRect] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? ImageAttachment, case .image(let picture) = attachment.inline.content,
                  picture.wrap != .inline, let image = attachment.image else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let glyph = glyphIndexForCharacter(at: paragraph.location)
            guard glyph < numberOfGlyphs else { return }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Above and below one its paragraph made room for, at the top of that room.
            let isReserved = Self.isReservedInParagraph(picture)
            let reservedTop = isReserved ? floatTops[paragraph.location] : nil
            // One fixed to a page is on that page, or the last there is, wherever its paragraph is.
            let page = picture.page.map { min(max(0, $0), max(0, pages - 1)) }
                ?? geometry.page(containing: reservedTop.map { $0 + 0.5 } ?? line.midY)
            let shape = geometry.shape(page)
            let size = floatSize(picture, page: page)
            // A shape turned or with effects is drawn past its frame; text keeps clear of its turned corners.
            let (drawn, kept) = Self.overhangs(picture, scale: size.width / max(picture.width, 1))
            // Across: from the margin, or the page's edge; the container starts at the text's leftmost edge.
            let origin = picture.isHorizontalFromPage ? 0 : shape.margins.left
            let span = picture.isHorizontalFromPage ? shape.size.width : shape.contentWidth
            let pageX: CGFloat
            switch picture.alignment {
            case .center?: pageX = origin + (span - size.width) / 2
            case .trailing?: pageX = origin + span - size.width
            case .leading?, .justified?: pageX = origin
            case nil: pageX = origin + picture.horizontalOffset
            }
            let y: CGFloat
            switch picture.verticalAnchor {
            case .paragraph: y = reservedTop.map { $0 + kept.top } ?? line.minY + picture.verticalOffset
            case .margin: y = geometry.textTop(page) + picture.verticalOffset
            case .page: y = geometry.textTop(page) - shape.margins.top + picture.verticalOffset
            }
            let placed = CGRect(x: pageX - geometry.textLeft, y: y, width: size.width, height: size.height)
            floats.append(PlacedFloat(
                frame: drawn.around(placed), page: page, image: image, behindText: picture.wrap == .behindText,
                location: range.location
            ))
            let frame = kept.around(placed)
            // Clear of the picture by the document's wrap distances.
            let distance = picture.wrapDistances
            let top = frame.minY - distance.top
            let height = frame.height + distance.top + distance.bottom
            switch picture.wrap {
            case .square, .tight, .through:
                var bands: [CGRect]
                if picture.wrap.followsOutline {
                    // Line by line, clear of where the outline crosses it; Word keeps no distance above and below.
                    let outline = (picture.wrapPolygon ?? .frame).exclusions(
                        x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                        left: distance.left, right: distance.right, through: picture.wrap == .through
                    )
                    // A sliver too narrow for words is left empty, as Word does, rather than breaking words into it.
                    let textLeft = shape.margins.left - geometry.textLeft
                    let textRight = textLeft + shape.contentWidth
                    bands = outline.map { band in
                        let minX = band.minX - textLeft < Self.narrowestWrap ? -1 : band.minX
                        let maxX = textRight - band.maxX < Self.narrowestWrap ? geometry.contentWidth + 1 : band.maxX
                        return CGRect(x: minX, y: band.minY, width: maxX - minX, height: band.maxY - band.minY)
                    }
                } else {
                    bands = [CGRect(
                        x: frame.minX - distance.left, y: top,
                        width: frame.width + distance.left + distance.right, height: height
                    )]
                }
                // Text kept to one side leaves the other side bare, out to the edge of the text.
                if picture.wrapSide != .both {
                    let left = frame.minX - distance.left
                    let right = frame.maxX + distance.right
                    let keepsLeft = picture.wrapSide == .left
                        || (picture.wrapSide == .largest && left >= geometry.contentWidth - right)
                    bands = bands.map { band in
                        let minX = keepsLeft ? band.minX : min(band.minX, -1)
                        let maxX = keepsLeft ? max(band.maxX, geometry.contentWidth + 1) : band.maxX
                        return CGRect(x: minX, y: band.minY, width: maxX - minX, height: band.height)
                    }
                }
                exclusions += bands
            case .topAndBottom where reservedTop == nil:
                exclusions.append(CGRect(x: -1, y: top, width: geometry.contentWidth + 2, height: height))
            default: break
            }
        }
        return (floats, exclusions)
    }

    /// Whether drawing the text draws the floating pictures on its pages too;
    /// off where the pages draw them, from `floatsByPage` or with
    /// `drawFloats(onPage:behindText:at:)`, clear of what the text is clipped to.
    public var drawsFloatsWithText = true

    /// The floating pictures on each page, each framed where it is on its page, from the page's top left corner.
    public var floatsByPage: [Int: [PlacedFloat]] {
        Dictionary(grouping: placedFloats.map { placed in
            var onPage = placed
            onPage.frame = placed.frame.offsetBy(
                dx: geometry.textLeft, dy: geometry.shape(placed.page).margins.top - geometry.textTop(placed.page)
            )
            return onPage
        }, by: \.page)
    }

    /// Draws the floating pictures on a page, behind the text or in front of it.
    public func drawFloats(onPage page: Int, behindText: Bool, at origin: CGPoint) {
        for placed in placedFloats where placed.behindText == behindText && placed.page == page {
            placed.image.drawUpright(in: placed.frame.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// Draws the floating pictures on the pages the glyphs being drawn are on, behind the text or in front of it.
    private func drawFloats(behindText: Bool, forGlyphRange glyphs: NSRange, at origin: CGPoint) {
        guard drawsFloatsWithText, !placedFloats.isEmpty, glyphs.length > 0, NSMaxRange(glyphs) <= numberOfGlyphs else { return }
        let first = geometry.page(containing: lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).midY)
        let last = geometry.page(containing: lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).midY)
        for placed in placedFloats where placed.behindText == behindText && (first...last).contains(placed.page) {
            placed.image.drawUpright(in: placed.frame.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    // MARK: - Drop caps

    public struct PlacedDropCap {
        /// The drop cap's paragraph, which takes no room of its own.
        public var paragraph: NSRange
        public var letter: NSAttributedString
        /// Where the letter's top left corner goes, in the container.
        public var origin: CGPoint
        /// What the next paragraph's lines go around, unless the letter is in the margin.
        public var exclusion: CGRect?

        public init(paragraph: NSRange, letter: NSAttributedString, origin: CGPoint, exclusion: CGRect? = nil) {
            self.paragraph = paragraph
            self.letter = letter
            self.origin = origin
            self.exclusion = exclusion
        }
    }

    public private(set) var dropCaps: [PlacedDropCap] = []
    private var dropCapExclusions: [CGRect] = []

    private func placeDropCaps() -> [PlacedDropCap] {
        guard let storage = textStorage else { return [] }
        let string = storage.string as NSString
        var result: [PlacedDropCap] = []
        storage.enumerateAttribute(.librettoDropCap, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let box = value as? DropCapBox else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let next = NSMaxRange(paragraph)
            let text = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard !text.isEmpty, next < string.length else { return }
            let glyph = glyphIndexForCharacter(at: next)
            guard glyph < numberOfGlyphs else { return }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = storage.attribute(.font, at: next, effectiveRange: nil) as? PlatformFont ?? .systemFont(ofSize: 11)
            let style = storage.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle
            let lineHeight = font.lineHeight * max(1, style?.lineHeightMultiple ?? 1)
            let top = line.minY + (style?.paragraphSpacingBefore ?? 0)
            let lines = CGFloat(max(1, box.dropCap.lines))
            // As tall, cap to baseline, as the lines it drops into.
            let capFont = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? PlatformFont ?? font
            let capHeight = (lines - 1) * lineHeight + font.capHeight
            let size = capHeight / max(capFont.capHeight / capFont.pointSize, 0.1)
            let letterFont = capFont.withSize(size)
            let color = storage.attribute(.foregroundColor, at: paragraph.location, effectiveRange: nil) ?? PlatformColor.text
            let letter = NSAttributedString(string: text, attributes: [.font: letterFont, .foregroundColor: color])
            let width = ceil(letter.size().width)
            let baseline = top + (lines - 1) * lineHeight + font.ascender
            let gap: CGFloat = 4
            let x = box.dropCap.inMargin ? -(width + gap) : 0
            result.append(PlacedDropCap(
                paragraph: paragraph, letter: letter, origin: CGPoint(x: x, y: baseline - letterFont.ascender),
                exclusion: box.dropCap.inMargin ? nil
                    : CGRect(x: -1, y: top, width: width + gap + 1, height: lines * lineHeight - 1)
            ))
        }
        return result
    }

    private func placeNotes() -> (byPage: [Int: [NSAttributedString]], heights: [Int: CGFloat]) {
        guard let storage = textStorage else { return ([:], [:]) }
        var byPage: [Int: [NSAttributedString]] = [:]
        for note in footnotes where note.location < storage.length {
            let glyph = glyphIndexForCharacter(at: note.location)
            guard glyph < numberOfGlyphs else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            byPage[geometry.page(containing: line.midY), default: []].append(note.text)
        }
        let heights = Dictionary(uniqueKeysWithValues: byPage.map { page, texts in
            let shape = geometry.shape(page)
            let height = texts.reduce(Self.noteSeparatorSpace) { total, text in
                total + ceil(text.boundingRect(
                    with: CGSize(width: shape.contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).height) + 2
            }
            // Never so much that the page has no room left for its own text.
            return (page, min(height, shape.contentHeight * 0.6))
        })
        return (byPage, heights)
    }

    /// Draws a page's notes at its foot, under a short rule.
    public static func drawNotes(_ notes: [NSAttributedString], in frame: CGRect, color: PlatformColor) {
        guard !notes.isEmpty else { return }
        color.withAlphaComponent(0.5).setFill()
        PlatformGraphics.fill(CGRect(x: frame.minX, y: frame.minY + noteSeparatorSpace / 2 - 0.25, width: min(144, frame.width / 3), height: 0.5))
        var y = frame.minY + noteSeparatorSpace
        for text in notes {
            let rect = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.maxY - y)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
            y += ceil(text.boundingRect(
                with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height) + 2
            if y >= frame.maxY { break }
        }
    }

    /// The text, laid out on as many pages as it takes.
    private func layOutText(in container: NSTextContainer, startingWith estimate: Int) -> Int {
        var pages = max(1, estimate)
        if configuredPages != pages || container.exclusionPaths.isEmpty { configure(container, pages: pages) }
        ensureLayout(for: container)
        if NSMaxRange(glyphRange(for: container)) < numberOfGlyphs {
            // Adding a few pages at a time lays everything out again each
            // time; measuring the text once without pages, then laying it out
            // on roughly as many pages as that needs, is far quicker.
            container.exclusionPaths = []
            container.size = CGSize(width: geometry.contentWidth, height: 10_000_000)
            columnsEnabled = false
            ensureLayout(for: container)
            columnsEnabled = true
            let unpaged = usedRect(for: container).maxY
            pages = max(pages + 1, Int(ceil(unpaged / geometry.contentHeight * 1.1)) + 1)
            configure(container, pages: pages)
        }
        var reached = -1
        for _ in 0..<64 {
            ensureLayout(for: container)
            let used = usedRect(for: container).maxY
            let needed = geometry.pageCount(forUsedHeight: used)
            let laidOut = NSMaxRange(glyphRange(for: container))
            if laidOut >= numberOfGlyphs, needed <= pages { return needed }
            // A line taller than a page fits on none, and layout stops at it:
            // more pages only lay the same text out again.
            if laidOut >= numberOfGlyphs || laidOut == reached { return max(needed, 1) }
            reached = laidOut
            pages = max(needed, pages) + max(4, pages / 4)
            configure(container, pages: pages)
        }
        return pages
    }

    // MARK: - Capitals

    /// Text in capitals keeps its letters as typed; it is drawn with the
    /// glyphs of their capitals.
    public func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: PlatformFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let last = characterIndexes[glyphRange.length - 1]
        guard first < storage.length else { return 0 }
        var hasCaps = false
        storage.enumerateAttribute(
            .librettoAllCaps, in: NSRange(location: first, length: min(storage.length, last + 1) - first)
        ) { value, _, stop in
            if value != nil {
                hasCaps = true
                stop.pointee = true
            }
        }
        guard hasCaps else { return 0 }
        let string = storage.string as NSString
        var replaced = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard index < storage.length, storage.attribute(.librettoAllCaps, at: index, effectiveRange: nil) != nil,
                  let scalar = UnicodeScalar(string.character(at: index)),
                  CharacterSet.lowercaseLetters.contains(scalar) else { continue }
            let upper = Array(String(Character(scalar)).uppercased().utf16)
            guard upper.count == 1 else { continue }
            var unit = upper[0]
            var glyph = CGGlyph()
            if CTFontGetGlyphsForCharacters(font as CTFont, &unit, &glyph, 1) {
                replaced[offset] = glyph
                changed = true
            }
        }
        guard changed else { return 0 }
        replaced.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(
                buffer.baseAddress!, properties: properties, characterIndexes: characterIndexes, font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    // MARK: - Page breaks

    public func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length else { return action }
        let string = storage.string as NSString
        let unit = string.character(at: charIndex)
        guard unit == TextCharacters.pageBreakUnit || unit == TextCharacters.columnBreakUnit else { return action }
        // A break that ends its paragraph keeps the paragraph's mark beside
        // it, as Word does, so the next paragraph is the one to start the page.
        let endsParagraph = charIndex + 1 < string.length
            && string.character(at: charIndex + 1) == TextCharacters.paragraphBreakUnit
        return endsParagraph ? .zeroAdvancement : .lineBreak
    }

    public func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = textStorage else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.length > 0 else { return false }
        // A table row that starts a page partway through its table makes room above it for the header rows.
        if let height = repeatedHeaderHeight(forRowAt: characters.location, line: lineFragmentRect.pointee) {
            lineFragmentRect.pointee.size.height += height
            lineFragmentUsedRect.pointee.origin.y += height
            baselineOffset.pointee += height
            headerRepeats[characters.location] = height
            return true
        }
        headerRepeats[characters.location] = nil
        if storage.attribute(.librettoDropCap, at: characters.location, effectiveRange: nil) != nil {
            // A drop cap's line takes no room: its letter sits beside the next paragraph.
            var rect = lineFragmentRect.pointee
            rect.size.height = 0.01
            lineFragmentRect.pointee = rect
            lineFragmentUsedRect.pointee = CGRect(origin: rect.origin, size: CGSize(width: 0, height: 0.01))
            baselineOffset.pointee = 0
            return true
        }
        let string = storage.string as NSString
        let last = NSMaxRange(characters) - 1
        // A column break in a section set in columns moves on to the next column, which the container sees to;
        // in one column, it ends the page, as in Word.
        let inColumns = sections.isEmpty ? false : sections[section(at: characters.location)].setup.hasColumns
        func isBreak(_ unit: unichar) -> Bool {
            unit == TextCharacters.pageBreakUnit || (unit == TextCharacters.columnBreakUnit && !inColumns)
        }
        var spaced = spaceAsWord(
            lineFragmentRect, used: lineFragmentUsedRect, baseline: baselineOffset,
            characters: characters, glyphs: glyphRange, in: textContainer
        )
        if reserveFloats(
            lineFragmentRect, used: lineFragmentUsedRect, baseline: baselineOffset, characters: characters
        ) {
            spaced = true
        }
        var endsPage = isBreak(string.character(at: last))
            || (last > 0 && string.character(at: last) == TextCharacters.paragraphBreakUnit
                && isBreak(string.character(at: last - 1)))
        if !endsPage, string.character(at: last) == TextCharacters.paragraphBreakUnit, last + 1 < string.length,
           storage.attribute(.librettoBlock, at: last + 1, effectiveRange: nil) == nil,
           let box = storage.attribute(.librettoParagraph, at: last + 1, effectiveRange: nil) as? ParagraphBox {
            let next = styles.resolvedParagraphProperties(box.paragraph.properties)
            if next.pageBreakBefore == true {
                endsPage = true
            } else {
                // What the next paragraph keeps together, if it would not fit on what is left of the page,
                // or the column.
                let rect = lineFragmentRect.pointee
                let page = geometry.page(containing: rect.minY + 0.5)
                var bottom = geometry.textBottom(page) - (noteHeights[page] ?? 0)
                let nextSection = section(at: last + 1)
                let frames = inColumns && section(at: last) == nextSection ? columnFrames(section: nextSection, page: page) : []
                let column = frames.indices.min { abs(frames[$0].minX - rect.minX) < abs(frames[$1].minX - rect.minX) }
                if let column {
                    bottom = columnBottom(section: nextSection, page: page, column: column, of: frames.count)
                }
                let left = bottom - rect.maxY
                if left > 0, let needed = keptHeight(startingAt: last + 1, properties: next, available: left, width: rect.width),
                   needed > left, needed < geometry.contentHeight * 0.9 {
                    if let column, column + 1 < frames.count {
                        // On to the next column: the line reaches the column's foot, and the container does the rest.
                        var moved = rect
                        moved.size.height = bottom - rect.minY + 1
                        lineFragmentRect.pointee = moved
                        return true
                    }
                    endsPage = true
                }
            }
        }
        // A section break other than a continuous one ends the page; one onto an even or odd page,
        // the page after that too, if the next page is not the kind it wants.
        var skipsPage = false
        if !endsPage, string.character(at: last) == TextCharacters.paragraphBreakUnit,
           let next = sectionStarted(byMarkAt: last), next.setup.start != .continuous {
            endsPage = true
            let following = geometry.page(containing: lineFragmentRect.pointee.minY + 0.5) + 1
            // Page numbers count from one: an even page has an odd index.
            switch next.setup.start {
            case .evenPage: skipsPage = following % 2 == 0
            case .oddPage: skipsPage = following % 2 == 1
            default: break
            }
        }
        guard endsPage else { return spaced }
        var rect = lineFragmentRect.pointee
        let page = geometry.page(containing: rect.minY + 0.5)
        let nextPageTop = geometry.textTop(page + (skipsPage ? 2 : 1))
        guard nextPageTop > rect.maxY else { return spaced }
        rect.size.height = nextPageTop - rect.minY
        lineFragmentRect.pointee = rect
        return true
    }

    // MARK: - Spacing as Word spaces lines

    /// Word's part in how high a line is and where it falls, where TextKit
    /// would differ; whether it changed anything.
    ///
    /// - The space after a paragraph runs off the foot of a page: its last
    ///   line stays on the page if the line itself fits, where TextKit would
    ///   move it to the next page for want of room for the space after it.
    /// - The space before a paragraph is left out at the top of a page the
    ///   text flowed on to, but kept on the first page, where TextKit would
    ///   leave it out, and after a page or section break.
    /// - A line of exact height has its baseline four fifths of the way down.
    private func spaceAsWord(
        _ rect: UnsafeMutablePointer<CGRect>, used: UnsafeMutablePointer<CGRect>, baseline: UnsafeMutablePointer<CGFloat>,
        characters: NSRange, glyphs: NSRange, in container: NSTextContainer
    ) -> Bool {
        guard let storage = textStorage, characters.location < storage.length,
              storage.attribute(.librettoBlock, at: characters.location, effectiveRange: nil) == nil,
              let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
        else { return false }
        let string = storage.string as NSString
        var changed = false
        if characters.location == 0, style.paragraphSpacingBefore > 0, used.pointee.minY - rect.pointee.minY < 0.01 {
            // TextKit leaves out the space before the first paragraph; Word keeps it.
            let before = style.paragraphSpacingBefore
            rect.pointee.size.height += before
            used.pointee.origin.y += before
            baseline.pointee += before
            changed = true
        }
        // What is above the line: the space before, on a paragraph's first.
        let before = max(0, used.pointee.minY - rect.pointee.minY)
        let page = geometry.page(containing: rect.pointee.minY + 0.5)
        var startsPage = page > 0 && abs(rect.pointee.minY - geometry.textTop(page)) < 0.5

        let last = NSMaxRange(characters) - 1
        if startsPage, style.paragraphSpacing > 0, glyphs.location > 0,
           string.character(at: last) == TextCharacters.paragraphBreakUnit,
           let room = roomAtFoot(of: page - 1, beforeGlyph: glyphs.location, in: container) {
            let needed = before + used.pointee.height
            var moved = rect.pointee
            moved.origin.y = room.minY
            moved.size.height = min(moved.height, room.height)
            let probe = CGRect(x: moved.minX, y: moved.minY, width: moved.width, height: needed).insetBy(dx: 0.5, dy: 0.5)
            if needed <= room.height + 0.01, !container.exclusionPaths.contains(where: { $0.bounds.intersects(probe) }) {
                used.pointee.origin.y -= rect.pointee.minY - moved.minY
                rect.pointee = moved
                startsPage = false
                changed = true
            }
        }

        let startsParagraph = characters.location == 0
            || string.character(at: characters.location - 1) == TextCharacters.paragraphBreakUnit
        if startsPage, startsParagraph, before > 0, characters.location > 0, flowedOn(to: characters.location) {
            rect.pointee.size.height -= before
            used.pointee.origin.y -= before
            baseline.pointee -= before
            changed = true
        }

        let exact = style.maximumLineHeight
        if exact > 0, style.minimumLineHeight == exact, abs(used.pointee.height - exact) < 0.01 {
            baseline.pointee = used.pointee.minY - rect.pointee.minY + exact * 0.8
            changed = true
        }
        return changed
    }

    /// What is left at the foot of page `page`, below the line before glyph
    /// `glyph`, if that line is on it and ends there without breaking the page.
    private func roomAtFoot(of page: Int, beforeGlyph glyph: Int, in container: NSTextContainer) -> CGRect? {
        let previous = lineFragmentRect(forGlyphAt: glyph - 1, effectiveRange: nil)
        let bottom = geometry.textBottom(page) - (noteHeights[page] ?? 0)
        guard geometry.page(containing: previous.minY + 0.5) == page, previous.maxY < bottom - 0.5 else { return nil }
        return CGRect(x: previous.minX, y: previous.maxY, width: previous.width, height: bottom - previous.maxY)
    }

    /// Whether the paragraph starting at `location` begins its page because
    /// the text before it ran out of room, rather than at a page or column
    /// break, a section break that starts a page, or a page break before it.
    private func flowedOn(to location: Int) -> Bool {
        guard let storage = textStorage, location > 0 else { return false }
        let string = storage.string as NSString
        let mark = location - 1
        if mark > 0 {
            let unit = string.character(at: mark - 1)
            if unit == TextCharacters.pageBreakUnit || unit == TextCharacters.columnBreakUnit { return false }
        }
        if let section = sectionStarted(byMarkAt: mark), section.setup.start != .continuous { return false }
        if let box = storage.attribute(.librettoParagraph, at: location, effectiveRange: nil) as? ParagraphBox,
           styles.resolvedParagraphProperties(box.paragraph.properties).pageBreakBefore == true { return false }
        return true
    }

    // MARK: - Repeated header rows

    /// The rows given room for their table's header rows above them, by character, and how much.
    private var headerRepeats: [Int: CGFloat] = [:]

    /// The table and its header rows' pictures, for a table row's character.
    private func headerRows(forRowAt location: Int) -> (images: [PlatformImage], isHeader: Bool, isFirst: Bool)? {
        guard let storage = textStorage, location < storage.length,
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? BlockAttachment,
              let rowID = attachment.rowID, case .table(let table) = attachment.block,
              let index = table.rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        let headers = table.rows.prefix { $0.isHeader }
        guard !headers.isEmpty else { return nil }
        // The header rows' pictures are on the table's line, before this one.
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let headerIDs = Set(headers.map(\.id))
        var images: [PlatformImage] = []
        storage.enumerateAttribute(.attachment, in: line) { value, _, _ in
            if let row = value as? BlockAttachment, let id = row.rowID, headerIDs.contains(id), let image = row.image {
                images.append(image)
            }
        }
        return (images, index < headers.count, index == 0)
    }

    private func repeatedHeaderHeight(forRowAt location: Int, line: CGRect) -> CGFloat? {
        guard let rows = headerRows(forRowAt: location), !rows.isHeader, !rows.isFirst else { return nil }
        let page = geometry.page(containing: line.minY + 0.5)
        guard abs(line.minY - geometry.textTop(page)) < 1 else { return nil }
        let height = rows.images.reduce(0) { $0 + $1.size.height }
        return height > 0 && height < geometry.shape(page).contentHeight / 2 ? height : nil
    }

    /// Draws the header rows above each row given room for them.
    private func drawRepeatedHeaders(forGlyphRange glyphs: NSRange, at origin: CGPoint) {
        guard !headerRepeats.isEmpty else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for (location, height) in headerRepeats where NSLocationInRange(location, characters) {
            guard let rows = headerRows(forRowAt: location) else { continue }
            let glyph = glyphIndexForCharacter(at: location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            guard line.height > height else { continue }
            var y = line.minY
            for image in rows.images {
                image.drawUpright(at: CGPoint(x: origin.x + line.minX, y: origin.y + y))
                y += image.size.height
            }
        }
    }

    // MARK: - Keeping text together

    /// How much of the paragraph starting at `start` must go on one page:
    /// all of it, to keep its lines together or keep it with the next, with
    /// that one's first line; its first two lines, to leave no widow at the
    /// page's foot; or `nil` if it can break anywhere. Measured only when
    /// it might not fit in what is `available`.
    private func keptHeight(startingAt start: Int, properties: ParagraphProperties, available: CGFloat, width: CGFloat) -> CGFloat? {
        guard let storage = textStorage else { return nil }
        let keepsWhole = properties.keepLines == true || properties.keepNext == true
        guard keepsWhole || properties.widowControl == true else { return nil }
        let string = storage.string as NSString
        let range = string.paragraphRange(for: NSRange(location: start, length: 0))
        let font = storage.attribute(.font, at: start, effectiveRange: nil) as? PlatformFont ?? .systemFont(ofSize: 11)
        let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let line = Self.lineHeight(font, style)
        let before = style?.paragraphSpacingBefore ?? 0
        // Plenty of room for two lines and then some: nothing more to work out.
        if !keepsWhole, available > before + line * 2.5 { return nil }
        // The lines alone: the space after the paragraph may run off the page's foot. Its
        // mark is left out too, as measured it would make an empty line of its own.
        func height(of range: NSRange) -> CGFloat {
            var range = range
            if range.length > 1, string.character(at: NSMaxRange(range) - 1) == TextCharacters.paragraphBreakUnit {
                range.length -= 1
            }
            let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let style = value as? NSParagraphStyle, style.paragraphSpacing > 0 || style.paragraphSpacingBefore > 0,
                      let lines = style.mutableCopy() as? NSMutableParagraphStyle else { return }
                lines.paragraphSpacing = 0
                lines.paragraphSpacingBefore = 0
                text.addAttribute(.paragraphStyle, value: lines, range: range)
            }
            return ceil(text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height)
        }
        let whole = before + height(of: range)
        var needed = keepsWhole ? whole : min(whole, before + line * 2)
        if properties.keepNext == true, NSMaxRange(range) < string.length {
            let next = NSMaxRange(range)
            let following = storage.attribute(.font, at: next, effectiveRange: nil) as? PlatformFont ?? font
            let followingStyle = storage.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle
            needed += (style?.paragraphSpacing ?? 0) + (followingStyle?.paragraphSpacingBefore ?? 0)
                + Self.lineHeight(following, followingStyle)
        }
        return needed
    }

    /// How high a line of text in a font is, in a paragraph style.
    private static func lineHeight(_ font: PlatformFont, _ style: NSParagraphStyle?) -> CGFloat {
        var line = font.lineHeight * max(1, style?.lineHeightMultiple ?? 1)
        if let least = style?.minimumLineHeight, least > 0 { line = max(line, least) }
        if let most = style?.maximumLineHeight, most > 0 { line = min(line, most) }
        return line
    }

    // MARK: - Borders and shading

    private struct Decoration {
        var properties: ParagraphProperties
        var paragraph: NSRange
        var page: Int
        /// Where the column the box is in starts, across the container.
        var column: Int
        var rect: CGRect
    }

    /// Paragraph shading, and borders, a box per page; paragraphs alike
    /// share a box, with the line between them if they have one.
    private func drawParagraphDecorations(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let string = storage.string as NSString
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var decorations: [Decoration] = []
        var location = string.paragraphRange(for: NSRange(location: min(shown.location, max(0, string.length - 1)), length: 0)).location
        // One paragraph beyond what is shown, so the last one shown knows whether its box carries on.
        var end = NSMaxRange(shown)
        if end < string.length { end = NSMaxRange(string.paragraphRange(for: NSRange(location: end, length: 0))) }
        while location < end, location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            guard storage.attribute(.librettoBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) == nil,
                  let box = DocumentRenderer.paragraphBox(in: storage, paragraphRange: range) else { continue }
            let properties = styles.resolvedParagraphProperties(box.paragraph.properties)
            guard properties.shadingHex != nil || properties.borders.map({ !$0.isEmpty }) == true else { continue }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            // A box on each page, and in each column the paragraph is in there.
            struct Place: Hashable, Comparable {
                var page: Int
                var column: Int
                static func < (a: Place, b: Place) -> Bool { (a.page, a.column) < (b.page, b.column) }
            }
            let inColumns = hasColumns
            var boxes: [Place: CGRect] = [:]
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) {
                rect, _, _, _, _ in
                let place = Place(page: self.geometry.page(containing: rect.midY), column: inColumns ? Int(rect.minX.rounded()) : 0)
                boxes[place] = boxes[place].map { $0.union(rect) } ?? rect
            }
            let first = boxes.keys.min()
            let last = boxes.keys.max()
            for (place, var rect) in boxes {
                // The box holds the text, not the paragraph's spacing.
                if place == first { rect.origin.y += style?.paragraphSpacingBefore ?? 0; rect.size.height -= style?.paragraphSpacingBefore ?? 0 }
                if place == last { rect.size.height -= style?.paragraphSpacing ?? 0 }
                let left = min(style?.headIndent ?? 0, style?.firstLineHeadIndent ?? 0)
                // In columns, across the column; otherwise across the text, as before.
                let start = inColumns ? rect.minX : 0
                let width = inColumns ? rect.width : container.size.width
                rect.origin.x = start + left
                rect.size.width = width - left + (style?.tailIndent ?? 0)
                decorations.append(Decoration(
                    properties: properties, paragraph: range, page: place.page, column: place.column, rect: rect
                ))
            }
        }
        decorations.sort { ($0.paragraph.location, $0.page, $0.column) < ($1.paragraph.location, $1.page, $1.column) }

        let ink = scheme == .dark ? PlatformColor.white : PlatformColor.black
        for (index, decoration) in decorations.enumerated() {
            func joins(_ other: Decoration?) -> Bool {
                guard let other else { return false }
                return other.page == decoration.page && other.column == decoration.column
                    && other.properties.borders == decoration.properties.borders
                    && other.properties.shadingHex == decoration.properties.shadingHex
                    && other.paragraph.location != decoration.paragraph.location
                    && (NSMaxRange(other.paragraph) == decoration.paragraph.location
                        || NSMaxRange(decoration.paragraph) == other.paragraph.location)
            }
            let joinsAbove = joins(index > 0 ? decorations[index - 1] : nil)
            let joinsBelow = joins(index + 1 < decorations.count ? decorations[index + 1] : nil)
            let borders = decoration.properties.borders ?? ParagraphBorders()
            var rect = decoration.rect
            // The border's own space around the text.
            let pad = { (line: BorderLine?) in CGFloat(line?.space ?? 0) }
            rect.origin.x -= pad(borders.left)
            rect.size.width += pad(borders.left) + pad(borders.right)
            if !joinsAbove { rect.origin.y -= pad(borders.top); rect.size.height += pad(borders.top) }
            if !joinsBelow { rect.size.height += pad(borders.bottom) }
            if joinsBelow, index + 1 < decorations.count {
                // Shading runs on into the next paragraph's box, with no gap.
                rect.size.height = max(rect.height, decorations[index + 1].rect.minY - rect.minY)
            }
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            if let fill = decoration.properties.shadingHex.flatMap({ AdaptiveColor.platformColor(hex: $0, for: scheme, isText: false) }) {
                fill.setFill()
                PlatformGraphics.fill(frame)
            }
            func stroke(_ line: BorderLine?, from start: CGPoint, to end: CGPoint) {
                guard let line else { return }
                let color = line.colorHex.flatMap { AdaptiveColor.platformColor(hex: $0, for: scheme, isText: true) } ?? ink
                Self.strokeBorder(line, from: start, to: end, color: color)
            }
            if !joinsAbove {
                stroke(borders.top, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.minY))
            } else {
                stroke(borders.between, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.minY))
            }
            if !joinsBelow {
                stroke(borders.bottom, from: CGPoint(x: frame.minX, y: frame.maxY), to: CGPoint(x: frame.maxX, y: frame.maxY))
            }
            stroke(borders.left, from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.minX, y: frame.maxY))
            stroke(borders.right, from: CGPoint(x: frame.maxX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.maxY))
        }
    }

    /// One border line, in its style: single, double, dotted, dashed or thick.
    public static func strokeBorder(_ line: BorderLine, from start: CGPoint, to end: CGPoint, color: PlatformColor) {
        let width = max(0.5, CGFloat(line.size) / 8)
        let path = PlatformBezierPath()
        path.lineWidth = width
        color.setStroke()
        switch line.style {
        case "dotted": path.setLineDash([width, width * 2], count: 2, phase: 0)
        case "dashed", "dashSmallGap", "dotDash", "dotDotDash": path.setLineDash([width * 4, width * 2], count: 2, phase: 0)
        default: break
        }
        if line.style == "double" || line.style.hasPrefix("thinThick") || line.style.hasPrefix("thickThin") {
            // Two lines, the gap between them as wide as each.
            let isHorizontal = abs(end.y - start.y) < abs(end.x - start.x)
            let shift = width
            for offset in [-shift, shift] {
                let delta = isHorizontal ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0)
                path.move(to: CGPoint(x: start.x + delta.x, y: start.y + delta.y))
                path.addLine(to: CGPoint(x: end.x + delta.x, y: end.y + delta.y))
            }
        } else {
            path.move(to: start)
            path.addLine(to: end)
        }
        path.stroke()
    }

    // MARK: - Finding the text at a point

    /// The glyph at a point. Lines in columns do not run down the container
    /// in order, which the layout manager's own search counts on; there, the
    /// line under the point is found among the page's, nearest across first,
    /// and the glyph along it.
    public override func glyphIndex(
        for point: CGPoint, in container: NSTextContainer, fractionOfDistanceThroughGlyph partialFraction: UnsafeMutablePointer<CGFloat>?
    ) -> Int {
        guard hasColumns, numberOfGlyphs > 0 else {
            return super.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: partialFraction)
        }
        let page = geometry.page(containing: point.y)
        let area = CGRect(x: 0, y: geometry.textTop(page), width: geometry.contentWidth, height: geometry.shape(page).contentHeight)
        let glyphs = glyphRange(forBoundingRect: area, in: container)
        var best: (rect: CGRect, glyphs: NSRange, distance: CGFloat)?
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let across = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let down = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = across * 10_000 + down
            if best.map({ distance < $0.distance }) ?? true { best = (rect, range, distance) }
        }
        guard let line = best, line.glyphs.length > 0 else {
            return super.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: partialFraction)
        }
        let x = point.x - line.rect.minX
        let end = NSMaxRange(line.glyphs)
        let used = lineFragmentUsedRect(forGlyphAt: line.glyphs.location, effectiveRange: nil)
        for glyph in line.glyphs.location..<end {
            let start = location(forGlyphAt: glyph).x
            let next = glyph + 1 < end ? location(forGlyphAt: glyph + 1).x : used.maxX - line.rect.minX
            if x < next || glyph + 1 == end {
                if glyph + 1 == end, x >= next, let storage = textStorage {
                    // Past the end of the line: before its break, or after its last glyph.
                    let character = characterIndexForGlyph(at: glyph)
                    let isBreak = character < storage.length
                        && CharacterSet.newlines.contains(UnicodeScalar((storage.string as NSString).character(at: character)) ?? " ")
                    partialFraction?.pointee = isBreak ? 0 : 1
                    return glyph
                }
                partialFraction?.pointee = next > start ? min(1, max(0, (x - start) / (next - start))) : 0
                return glyph
            }
        }
        partialFraction?.pointee = 1
        return end - 1
    }

    /// The glyphs in a rect. Lines in columns go back up the page for each
    /// column, so a rect across part of a page may hold lines far apart in
    /// the text; pages, though, follow one another, so the rect is widened
    /// to the whole pages it crosses. Drawing more than the rect is harmless.
    public override func glyphRange(forBoundingRect bounds: CGRect, in container: NSTextContainer) -> NSRange {
        super.glyphRange(forBoundingRect: wholePages(bounds), in: container)
    }

    public override func glyphRange(forBoundingRectWithoutAdditionalLayout bounds: CGRect, in container: NSTextContainer) -> NSRange {
        super.glyphRange(forBoundingRectWithoutAdditionalLayout: wholePages(bounds), in: container)
    }

    private func wholePages(_ bounds: CGRect) -> CGRect {
        // Views ask for everything with rects of no end, which cover whole pages already.
        let limit = geometry.totalHeight(pages: 100_000)
        guard hasColumns, !bounds.isNull, !bounds.isEmpty, !bounds.isInfinite,
              bounds.minY.isFinite, bounds.maxY.isFinite, bounds.minY > -limit, bounds.maxY < limit else { return bounds }
        let first = geometry.page(containing: bounds.minY)
        let last = geometry.page(containing: bounds.maxY)
        let top = min(bounds.minY, geometry.textTop(first))
        let bottom = max(bounds.maxY, geometry.textBottom(last))
        return CGRect(x: 0, y: top, width: max(bounds.maxX, geometry.contentWidth), height: bottom - top)
    }

    // MARK: - Comments

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawParagraphDecorations(forGlyphRange: glyphsToShow, at: origin)
        if outlinesKeptBlocks { drawKeptBlockOutlines(forGlyphRange: glyphsToShow, at: origin) }
        drawFloats(behindText: true, forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !commentRanges.isEmpty, let container = textContainers.first else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in commentRanges where range.length > 0 && NSIntersectionRange(range, shown).length > 0 {
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let alpha: CGFloat = activeCommentRanges.contains(range) ? 0.5 : 0.25
            PlatformColor.systemYellow.withAlphaComponent(alpha).setFill()
            enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                PlatformGraphics.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }

    // MARK: - Kept blocks

    /// A faint dashed outline round each kept block on each page it is on, at the text's edges: the text
    /// view may not draw beyond them.
    private func drawKeptBlockOutlines(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let string = storage.string as NSString
        var blocks: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: shown) { value, range, _ in
            guard let attachment = value as? BlockAttachment, case .preserved = attachment.block else { return }
            let line = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            if blocks.last != line { blocks.append(line) }
        }
        let color = (scheme == .dark ? PlatformColor.white : PlatformColor.black).withAlphaComponent(0.25)
        for block in blocks {
            var boxes: [Int: CGRect] = [:]
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil)) {
                _, used, _, _, _ in
                let page = self.geometry.page(containing: used.midY)
                boxes[page] = boxes[page].map { $0.union(used) } ?? used
            }
            for rect in boxes.values {
                let box = CGRect(x: 0, y: rect.minY, width: container.size.width, height: rect.height)
                let frame = box.insetBy(dx: 0.5, dy: 0.5).offsetBy(dx: origin.x, dy: origin.y)
                let path = PlatformBezierPath(roundedRect: frame, cornerRadius: 2)
                path.lineWidth = 0.5
                path.setLineDash([3, 2], count: 2, phase: 0)
                color.setStroke()
                path.stroke()
            }
        }
    }

    // MARK: - List labels

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if dropCaps.isEmpty {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        } else {
            // A drop cap's own line is not drawn; its letter is, large, beside the next paragraph.
            var remaining = [glyphsToShow]
            for cap in dropCaps {
                let hidden = glyphRange(forCharacterRange: cap.paragraph, actualCharacterRange: nil)
                remaining = remaining.flatMap { range -> [NSRange] in
                    guard NSIntersectionRange(range, hidden).length > 0 else { return [range] }
                    var pieces: [NSRange] = []
                    if hidden.location > range.location {
                        pieces.append(NSRange(location: range.location, length: hidden.location - range.location))
                    }
                    if NSMaxRange(range) > NSMaxRange(hidden) {
                        pieces.append(NSRange(location: NSMaxRange(hidden), length: NSMaxRange(range) - NSMaxRange(hidden)))
                    }
                    return pieces
                }
                let shown = NSRange(location: hidden.location, length: hidden.length + 1)
                if NSIntersectionRange(shown, glyphsToShow).length > 0 {
                    cap.letter.draw(at: CGPoint(x: origin.x + cap.origin.x, y: origin.y + cap.origin.y))
                }
            }
            for range in remaining where range.length > 0 { super.drawGlyphs(forGlyphRange: range, at: origin) }
        }
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let string = storage.string as NSString
        drawTabLeaders(in: characters, at: origin)
        drawRepeatedHeaders(forGlyphRange: glyphsToShow, at: origin)
        drawFloats(behindText: false, forGlyphRange: glyphsToShow, at: origin)
        storage.enumerateAttribute(.librettoListLabel, in: characters) { value, range, _ in
            guard let label = value as? ListLabelBox, !label.text.isEmpty else { return }
            // Only where a paragraph starts within what is being drawn.
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                if paragraph.location >= characters.location {
                    drawLabel(label, atParagraphStart: paragraph.location, origin: origin)
                }
                location = NSMaxRange(paragraph)
            }
        }
    }

    /// Dots, dashes or a rule across the space a tab with a leader takes.
    private func drawTabLeaders(in characters: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let string = storage.string as NSString
        var index = characters.location
        while index < NSMaxRange(characters) {
            let found = string.range(
                of: "\t", options: .literal, range: NSRange(location: index, length: NSMaxRange(characters) - index)
            )
            guard found.location != NSNotFound else { break }
            index = found.location + 1
            guard let box = storage.attribute(.librettoParagraph, at: found.location, effectiveRange: nil) as? ParagraphBox,
                  let stops = styles.resolvedParagraphProperties(box.paragraph.properties).tabStops,
                  stops.contains(where: { $0.leader != nil }) else { continue }
            let glyph = glyphIndexForCharacter(at: found.location)
            // From where the tab starts to where the next glyph does, on the same line.
            var lineGlyphs = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            // A tab is a control glyph, with no place of its own: it starts where the glyph before it ends.
            let start = glyph > lineGlyphs.location
                ? boundingRect(forGlyphRange: NSRange(location: glyph - 1, length: 1), in: container).maxX
                : fragment.minX
            let end = glyph + 1 < NSMaxRange(lineGlyphs)
                ? fragment.minX + location(forGlyphAt: glyph + 1).x
                : lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX
            let rect = CGRect(x: start, y: fragment.minY, width: end - start, height: fragment.height)
            guard rect.width > 6,
                  let leader = stops.first(where: { CGFloat($0.position) / 20 >= rect.maxX - 1 })?.leader else { continue }
            let mark: String
            switch leader {
            case "hyphen": mark = "-"
            case "underscore", "heavy": mark = "_"
            case "middleDot": mark = "·"
            default: mark = "."
            }
            let attributes = storage.attributes(at: found.location, effectiveRange: nil)
            let font = attributes[.font] as? PlatformFont ?? .systemFont(ofSize: 11)
            let drawn: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: attributes[.foregroundColor] ?? PlatformColor.text,
            ]
            // A mark and the space after it, as many as fit.
            let unit = ((mark + " ") as NSString).size(withAttributes: drawn).width
            let count = Int((rect.width - 4) / max(unit, 1))
            guard count > 0 else { continue }
            let leaderText = Array(repeating: mark, count: count).joined(separator: " ")
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph).y
            let width = (leaderText as NSString).size(withAttributes: drawn).width
            (leaderText as NSString).draw(
                at: CGPoint(x: origin.x + rect.maxX - width - 2, y: origin.y + line.minY + baseline - font.ascender),
                withAttributes: drawn
            )
        }
    }

    private func drawLabel(_ label: ListLabelBox, atParagraphStart index: Int, origin: CGPoint) {
        guard let storage = textStorage, index < storage.length else { return }
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = location(forGlyphAt: glyph).y
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        let font = attributes[.font] as? PlatformFont ?? .systemFont(ofSize: 11)
        attributes = [.font: font, .foregroundColor: attributes[.foregroundColor] ?? PlatformColor.text]
        let point = CGPoint(
            x: origin.x + line.minX + label.indent,
            y: origin.y + line.minY + baseline - font.ascender
        )
        NSAttributedString(string: label.text, attributes: attributes).draw(at: point)
    }
}
#endif
