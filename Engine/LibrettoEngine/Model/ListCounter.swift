import Foundation

/// Counts list paragraphs in reading order, the way Word counts them, and
/// says what each one's label reads.
public struct ListCounter: Sendable {
    public let styles: StyleSheet
    public let numbering: NumberingDefinitions
    /// Per abstract list, the current count at each level. Lists that share
    /// an abstract definition share their count.
    private var counters: [Int: [Int: Int]] = [:]
    /// Instances already met, whose overrides, if any, have started their levels over.
    private var started: Set<Int> = []

    public init(styles: StyleSheet, numbering: NumberingDefinitions) {
        self.styles = styles
        self.numbering = numbering
    }

    /// The list a paragraph is in, its own or its style's, from its resolved properties.
    public static func listReference(_ resolved: ParagraphProperties) -> ListReference? {
        guard let list = resolved.list, list.numberingID != 0 else { return nil }
        return list
    }

    /// The label for the next paragraph, or `nil` if it is not in a list.
    public mutating func label(for direct: ParagraphProperties) -> String? {
        let resolved = styles.resolvedParagraphProperties(direct)
        guard let list = Self.listReference(resolved),
              let abstract = numbering.instances[list.numberingID],
              let level = numbering.level(list.level, of: list.numberingID) else { return nil }

        var counts = counters[abstract] ?? [:]
        if started.insert(list.numberingID).inserted, let restarts = numbering.overrides[list.numberingID] {
            // An instance that starts over does so at its first paragraph.
            for (restarted, start) in restarts {
                counts[restarted] = start - 1
                for deeper in counts.keys where deeper > restarted { counts[deeper] = nil }
            }
        }
        counts[list.level] = (counts[list.level] ?? (level.start - 1)) + 1
        // Moving up a level starts the levels below it over.
        for deeper in counts.keys where deeper > list.level { counts[deeper] = nil }
        counters[abstract] = counts

        if level.format == "bullet" { return Self.bullet(level.text) }
        if level.format == "none" { return "" }
        var result = level.text
        for index in (0...8).reversed() {
            let placeholder = "%\(index + 1)"
            guard result.contains(placeholder) else { continue }
            let format = numbering.level(index, of: list.numberingID)
            let start = format?.start ?? 1
            let value = counts[index] ?? start
            result = result.replacingOccurrences(
                of: placeholder, with: Self.format(value, as: format?.format ?? "decimal")
            )
        }
        return result
    }

    /// Bullets set in Symbol or Wingdings use private-use code points; these
    /// are what they look like.
    public static func bullet(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "\u{2022}" }
        switch scalar.value {
        case 0xF0B7, 0xF06C, 0xF09F: return "\u{2022}"
        case 0xF0A7, 0xF06E: return "\u{25AA}"
        case 0xF0D8, 0xF0E0: return "\u{27A2}"
        case 0xF0FC: return "\u{2713}"
        case 0xF000...0xF0FF: return "\u{2022}"
        default: return scalar.value == 0x6F ? "\u{25E6}" : text
        }
    }

    public static func format(_ value: Int, as format: String) -> String {
        switch format {
        case "lowerLetter": return letters(value).lowercased()
        case "upperLetter": return letters(value)
        case "lowerRoman": return roman(value).lowercased()
        case "upperRoman": return roman(value)
        case "decimalZero": return value < 10 ? "0\(value)" : String(value)
        case "decimalEnclosedCircle" where (1...20).contains(value):
            return String(Character(UnicodeScalar(0x2460 + value - 1)!))
        default: return String(value)
        }
    }

    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "" }
        // Word repeats the letter rather than counting on: Y, Z, AA, BB.
        let letter = Character(UnicodeScalar(65 + (value - 1) % 26)!)
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4000 else { return String(value) }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }
}
