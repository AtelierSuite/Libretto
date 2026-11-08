#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What the editor's attributed text carries besides how it looks.
///
/// The text the page view edits is a rendering of the model, with the model
/// riding along in these attributes. Reading the text back into blocks uses
/// only these, never the fonts and colours, which are derived from them.
extension NSAttributedString.Key {
    /// A `ParagraphBox`, on every character of a paragraph, its mark included.
    public static let librettoParagraph = NSAttributedString.Key("libretto.paragraph")
    /// A `RunBox`, on every character a run of text produced.
    public static let librettoRun = NSAttributedString.Key("libretto.run")
    /// An `InlineBox` on the characters a kept element shows as.
    public static let librettoToken = NSAttributedString.Key("libretto.token")
    /// A `MarkersBox` on the character after markers that take no room.
    public static let librettoMarkers = NSAttributedString.Key("libretto.markers")
    /// A `ListLabelBox` on a list paragraph, drawn in its margin.
    public static let librettoListLabel = NSAttributedString.Key("libretto.listLabel")
    /// A `BlockBox` on the mark ending a table or kept block's line.
    public static let librettoBlock = NSAttributedString.Key("libretto.block")
    /// On text drawn in capitals, which the layout manager draws upper-case glyphs for.
    public static let librettoAllCaps = NSAttributedString.Key("libretto.allCaps")
    /// A `DropCapBox` on a drop cap's paragraph, whose letter is drawn large
    /// beside the start of the next paragraph rather than on a line of its own.
    public static let librettoDropCap = NSAttributedString.Key("libretto.dropCap")
}

/// Keys that belong to the character they were put on, and must not be
/// carried on to text typed after it.
public let librettoPositionalKeys: [NSAttributedString.Key] = [
    .librettoToken, .librettoMarkers, .librettoBlock, .attachment,
]

public final class ParagraphBox: NSObject, Sendable {
    public let paragraph: Paragraph

    public init(_ paragraph: Paragraph) {
        self.paragraph = paragraph
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ParagraphBox else { return false }
        return other === self || other.paragraph == paragraph
    }

    public override var hash: Int { paragraph.id.hashValue }
}

public final class RunBox: NSObject, Sendable {
    public let format: RunFormat
    public let hyperlink: Hyperlink?
    /// The tracked change the text is part of. On a paragraph mark, the mark's own.
    public let revision: Revision?

    public init(_ format: RunFormat, hyperlink: Hyperlink?, revision: Revision? = nil) {
        self.format = format
        self.hyperlink = hyperlink
        self.revision = revision
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RunBox else { return false }
        return other === self || (other.format == format && other.hyperlink == hyperlink && other.revision == revision)
    }

    public override var hash: Int { format.hashValue }
}

/// A kept element, identified by the box itself: two tokens that happen to
/// hold the same element are still two tokens.
public final class InlineBox: NSObject, Sendable {
    public let inline: Inline
    /// The text it was shown as, to tell whether that has been edited.
    public let display: String

    public init(_ inline: Inline, display: String) {
        self.inline = inline
        self.display = display
    }
}

public final class MarkersBox: NSObject, Sendable {
    public let markers: [Inline]

    public init(_ markers: [Inline]) {
        self.markers = markers
    }
}

public final class ListLabelBox: NSObject, Sendable {
    public let text: String
    /// Where the label starts, from the text container's leading edge.
    public let indent: CGFloat

    public init(text: String, indent: CGFloat) {
        self.text = text
        self.indent = indent
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ListLabelBox else { return false }
        return other.text == text && other.indent == indent
    }

    public override var hash: Int { text.hashValue }
}

public final class DropCapBox: NSObject, Sendable {
    public let dropCap: DropCap

    public init(_ dropCap: DropCap) {
        self.dropCap = dropCap
    }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? DropCapBox)?.dropCap == dropCap
    }

    public override var hash: Int { dropCap.hashValue }
}

public final class BlockBox: NSObject, Sendable {
    public let block: Block

    public init(_ block: Block) {
        self.block = block
    }
}

/// A picture in the text.
public final class ImageAttachment: NSTextAttachment {
    public var inline = Inline(.text(""))
}

/// One line of a block shown as pictures: a table row, or a line of a kept block.
public final class BlockAttachment: NSTextAttachment {
    public var block: Block = .paragraph(Paragraph())
    /// The table row this line draws, for tables.
    public var rowID: TableRow.ID?
}

// MARK: - Special characters

public enum TextCharacters: Sendable {
    public static let paragraphBreak: Character = "\n"
    public static let lineBreak = "\u{2028}"
    public static let pageBreak = "\u{0C}"
    /// A column break, which in one column ends the page.
    public static let columnBreak = "\u{0B}"
    public static let attachment = "\u{FFFC}"

    public static let paragraphBreakUnit: unichar = 0x0A
    public static let lineBreakUnit: unichar = 0x2028
    public static let pageBreakUnit: unichar = 0x0C
    public static let columnBreakUnit: unichar = 0x0B
    public static let attachmentUnit: unichar = 0xFFFC
    public static let tabUnit: unichar = 0x09
}
