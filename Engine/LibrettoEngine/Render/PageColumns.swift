#if canImport(UIKit) || canImport(AppKit)
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The text container pages are laid out in: like any other, but a line in a
/// section set in columns is put in its column, as wide as it, and goes on to
/// the next column, rather than the next page, when its column is full.
///
/// The layout manager works out where; the container only asks it, line by
/// line, as the typesetter proposes each.
public final class PageTextContainer: NSTextContainer {
    /// What is left of a line split around something it goes round, which
    /// the typesetter proposes next for the same line.
    private var remainder: CGRect?

    public override var isSimpleRectangularTextContainer: Bool {
        guard let layout = layoutManager as? PageLayoutManager, layout.hasColumns else {
            return super.isSimpleRectangularTextContainer
        }
        return false
    }

    public override func lineFragmentRect(
        forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<CGRect>?
    ) -> CGRect {
        var proposed = proposedRect
        if let remainder, abs(remainder.minX - proposed.minX) < 0.5, abs(remainder.minY - proposed.minY) < 0.5 {
            // The rest of a line already in its column.
            self.remainder = nil
        } else if let layout = layoutManager as? PageLayoutManager,
                  let placed = layout.columnPlacement(proposing: proposedRect, at: characterIndex) {
            proposed = placed
        }
        let rect = super.lineFragmentRect(
            forProposedRect: proposed, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect
        )
        if let remaining = remainingRect?.pointee, !remaining.isEmpty { remainder = remaining } else { remainder = nil }
        return rect
    }
}

extension PageLayoutManager {
    /// Whether any section is set in more than one column.
    public var hasColumns: Bool { sections.contains { $0.setup.hasColumns } }

    /// Section `index`'s columns on page `page`, in the container: one, the
    /// width of the page's text, for a section in one column.
    public func columnFrames(section index: Int, page: Int) -> [CGRect] {
        let shape = geometry.shape(page)
        let left = shape.margins.left - geometry.textLeft
        let setup = sections.indices.contains(index) ? sections[index].setup : PageSetup()
        return setup.columnFrames(width: Double(shape.contentWidth)).map {
            CGRect(x: left + CGFloat($0.x), y: geometry.textTop(page), width: CGFloat($0.width), height: shape.contentHeight)
        }
    }

    /// The first character of section `index`.
    func sectionStart(_ index: Int) -> Int {
        index > 0 && sections.indices.contains(index - 1) ? sections[index - 1].end + 1 : 0
    }

    /// Where the line starting at `characterIndex` goes, if it is in a
    /// section set in columns or follows one on the same page: in the column
    /// the line before is in, below it; at the top of the next column when
    /// that one is full or ends with a column break; or on the next page
    /// after the last column. `nil` leaves the line where it was proposed.
    func columnPlacement(proposing proposed: CGRect, at characterIndex: Int) -> CGRect? {
        guard columnsEnabled, hasColumns, let storage = textStorage, characterIndex <= storage.length else { return nil }
        let index = section(at: characterIndex)
        let previous = characterIndex > 0 ? previousLine(before: characterIndex) : nil
        let previousSection = characterIndex > 0 ? section(at: characterIndex - 1) : index
        let inColumns = sections[index].setup.hasColumns
        let followsColumns = previousSection != index && sections[previousSection].setup.hasColumns
        guard inColumns || followsColumns else { return nil }

        var page = geometry.page(containing: proposed.minY + 0.5)
        var y = proposed.minY
        var column = 0
        if let previous, previousSection == index {
            // On in the column the line before is in, unless it moved the text on to a later page.
            let previousPage = geometry.page(containing: previous.minY + 0.5)
            if proposed.minY < geometry.textTop(previousPage + 1) - 0.5 {
                page = previousPage
                let frames = columnFrames(section: index, page: page)
                column = frames.indices.min { abs(frames[$0].minX - previous.minX) < abs(frames[$1].minX - previous.minX) } ?? 0
                let bottom = columnBottom(section: index, page: page, column: column, of: frames.count)
                let top = columnTop(section: index, page: page)
                let full = y + proposed.height > bottom + 0.5 && y > top + 0.5
                if full || breaksColumn(before: characterIndex) {
                    if column + 1 < frames.count {
                        column += 1
                        y = top
                    } else {
                        page += 1
                        column = 0
                        y = geometry.textTop(page)
                    }
                }
            }
        } else if followsColumns, let previous {
            // A section after one in columns starts below the longest of them, where the text continues on the page.
            let previousPage = geometry.page(containing: previous.minY + 0.5)
            if page == previousPage { y = max(y, lowestLine(inSection: previousSection, page: page)) }
        }
        let frames = columnFrames(section: index, page: page)
        let frame = frames[min(column, frames.count - 1)]
        return CGRect(x: frame.minX, y: y, width: frame.width, height: proposed.height)
    }

    /// The line the character before `characterIndex` is on, if it has been laid out.
    private func previousLine(before characterIndex: Int) -> CGRect? {
        let glyph = glyphIndexForCharacter(at: characterIndex - 1)
        guard glyph < numberOfGlyphs else { return nil }
        let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        return rect.height > 0 || rect.width > 0 ? rect : nil
    }

    /// Whether the text before `characterIndex` ends with a column break, alone or before its paragraph's mark.
    private func breaksColumn(before characterIndex: Int) -> Bool {
        guard let storage = textStorage, characterIndex > 0 else { return false }
        let string = storage.string as NSString
        let last = string.character(at: characterIndex - 1)
        if last == TextCharacters.columnBreakUnit { return true }
        return last == TextCharacters.paragraphBreakUnit && characterIndex > 1
            && string.character(at: characterIndex - 2) == TextCharacters.columnBreakUnit
    }

    /// Where section `index`'s columns start on `page`: where its first line
    /// is if it starts there, or the top of the page's text.
    func columnTop(section index: Int, page: Int) -> CGFloat {
        let top = geometry.textTop(page)
        let start = sectionStart(index)
        guard let storage = textStorage, start < storage.length else { return top }
        let glyph = glyphIndexForCharacter(at: start)
        guard glyph < numberOfGlyphs else { return top }
        let first = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        guard first.height > 0, geometry.page(containing: first.minY + 0.5) == page else { return top }
        return max(top, first.minY)
    }

    /// How far down column `column` of `count` goes on `page`: to the foot of
    /// the page's text, or, where the section's columns are balanced on
    /// its last page, about as far as each other.
    func columnBottom(section index: Int, page: Int, column: Int, of count: Int) -> CGFloat {
        let bottom = geometry.textBottom(page) - (noteHeights[page] ?? 0)
        guard column + 1 < count, let balance = columnBalance[index], balance.page == page else { return bottom }
        return min(bottom, balance.bottom)
    }

    /// The foot of section `index`'s lowest line on `page`.
    private func lowestLine(inSection index: Int, page: Int) -> CGFloat {
        guard let storage = textStorage else { return 0 }
        let start = sectionStart(index)
        let end = min(sections[index].end + 1, storage.length)
        guard start < end else { return 0 }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
        var lowest: CGFloat = 0
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var range = NSRange()
            let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range, withoutAdditionalLayout: true)
            guard range.length > 0 else { break }
            if geometry.page(containing: rect.minY + 0.5) == page { lowest = max(lowest, rect.maxY) }
            glyph = NSMaxRange(range)
        }
        return lowest
    }

    /// Where the columns of each section followed by a continuous one on the
    /// same page end there: about as far down as each other, as Word sets
    /// them, rather than the first full and the last short.
    func balanceColumns() -> [Int: ColumnBalance] {
        guard hasColumns, let storage = textStorage else { return [:] }
        var result: [Int: ColumnBalance] = [:]
        for index in sections.indices.dropLast() where sections[index].setup.hasColumns
            && sections[index + 1].setup.start == .continuous {
            let start = sectionStart(index)
            let end = min(sections[index].end + 1, storage.length)
            guard start < end else { continue }
            let glyphs = glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil, withoutAdditionalLayout: true)
            guard last.height > 0 else { continue }
            let page = geometry.page(containing: last.minY + 0.5)
            // The height of the section's lines on its last page, shared among its columns.
            var total: CGFloat = 0
            var tallest: CGFloat = 0
            var glyph = glyphs.location
            var hasBreak = false
            while glyph < NSMaxRange(glyphs) {
                var range = NSRange()
                let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range, withoutAdditionalLayout: true)
                guard range.length > 0 else { break }
                if geometry.page(containing: rect.minY + 0.5) == page {
                    total += rect.height
                    tallest = max(tallest, rect.height)
                    let characters = characterRange(forGlyphRange: range, actualGlyphRange: nil)
                    if breaksColumn(before: NSMaxRange(characters)) { hasBreak = true }
                }
                glyph = NSMaxRange(range)
            }
            // Columns broken by hand are left as they were broken.
            guard !hasBreak else { continue }
            let count = CGFloat(columnFrames(section: index, page: page).count)
            let top = columnTop(section: index, page: page)
            // Half a line over, so the first columns are the longer, as in Word.
            result[index] = ColumnBalance(page: page, bottom: (top + total / count + tallest / 2).rounded(.up))
        }
        return result
    }
}

/// Where a section's balanced columns end on its last page.
public struct ColumnBalance: Equatable, Sendable {
    public var page: Int
    public var bottom: CGFloat
}
#endif
