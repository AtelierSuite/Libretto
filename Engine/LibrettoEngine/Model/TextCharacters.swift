import Foundation

/// The characters the editor's text stands breaks and pictures in with.
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
