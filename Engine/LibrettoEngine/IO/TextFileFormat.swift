import Foundation

/// How a text file ends its lines. The code editor shows the file's lines
/// with `\n` between them whichever it is, and saves them with this.
public enum LineEnding: String, CaseIterable, Sendable {
    case lf
    case crlf
    case cr

    /// What ends each line in the file.
    public var separator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// The ending's short name, as the editor shows it beside the text.
    public var name: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    /// The ending's name, with the systems it is the custom on, as a menu of them lists it.
    public var displayName: String {
        switch self {
        case .lf: return String(localized: "LineEnding.LF", bundle: .engine)
        case .crlf: return String(localized: "LineEnding.CRLF", bundle: .engine)
        case .cr: return String(localized: "LineEnding.CR", bundle: .engine)
        }
    }

    /// The ending most of the text's lines have. Text of one line, which
    /// has none, is taken to end its lines as most files now do.
    public static func most(in text: String) -> LineEnding {
        var counts: [LineEnding: Int] = [:]
        var afterReturn = false
        for unit in text.utf8 {
            switch unit {
            case 0x0A:
                counts[afterReturn ? .crlf : .lf, default: 0] += 1
                afterReturn = false
            case 0x0D:
                if afterReturn { counts[.cr, default: 0] += 1 }
                afterReturn = true
            default:
                if afterReturn { counts[.cr, default: 0] += 1 }
                afterReturn = false
            }
        }
        if afterReturn { counts[.cr, default: 0] += 1 }
        // A tie goes to the ending listed first.
        return allCases.reduce(.lf) { most, ending in (counts[ending] ?? 0) > (counts[most] ?? 0) ? ending : most }
    }
}

/// The encoding a text file's characters are written in.
///
/// UTF-8 is read and written without a byte order mark unless the file
/// had one; UTF-16 always has one, as there is no telling its byte order
/// otherwise. The rest are the older encodings a file not in UTF-8 is most
/// likely to be in.
public enum TextEncoding: String, CaseIterable, Sendable {
    case utf8
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian
    case shiftJIS
    case eucJP
    case windowsLatin1
    case isoLatin1

    /// Foundation's encoding for the characters, byte order mark aside.
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .shiftJIS: return .shiftJIS
        case .eucJP: return .japaneseEUC
        case .windowsLatin1: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        }
    }

    /// The bytes the file starts with to say what it is in, if any.
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8WithBOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        default: return []
        }
    }

    /// Whether it can write every character there is.
    public var isUnicode: Bool {
        switch self {
        case .utf8, .utf8WithBOM, .utf16LittleEndian, .utf16BigEndian: return true
        default: return false
        }
    }

    /// The encoding's short name, as the editor shows it beside the text.
    public var name: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return "UTF-8 BOM"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .shiftJIS: return "Shift JIS"
        case .eucJP: return "EUC-JP"
        case .windowsLatin1: return "Windows-1252"
        case .isoLatin1: return "ISO-8859-1"
        }
    }

    /// The encoding's name, as a menu of them lists it.
    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return String(localized: "TextEncoding.UTF8WithBOM", bundle: .engine)
        case .utf16LittleEndian: return String(localized: "TextEncoding.UTF16LittleEndian", bundle: .engine)
        case .utf16BigEndian: return String(localized: "TextEncoding.UTF16BigEndian", bundle: .engine)
        case .shiftJIS: return String(localized: "TextEncoding.ShiftJIS", bundle: .engine)
        case .eucJP: return String(localized: "TextEncoding.EUCJP", bundle: .engine)
        case .windowsLatin1: return String(localized: "TextEncoding.WindowsLatin1", bundle: .engine)
        case .isoLatin1: return String(localized: "TextEncoding.ISOLatin1", bundle: .engine)
        }
    }

    /// Whether every character of the text can be written in it.
    public func canEncode(_ text: String) -> Bool {
        isUnicode || text.canBeConverted(to: stringEncoding)
    }

    /// The encoding, or UTF-8 should the text have a character it cannot
    /// write, such as one typed since the file was opened.
    public func fitting(_ text: String) -> TextEncoding {
        canEncode(text) ? self : .utf8
    }

    /// The text as a file in this encoding, byte order mark and all, or
    /// `nil` should it have a character the encoding cannot write.
    public func data(for text: String) -> Data? {
        guard let characters = text.data(using: stringEncoding, allowLossyConversion: false) else { return nil }
        return Data(byteOrderMark) + characters
    }

    /// The file's text, and the encoding it was found to be in: the one its
    /// byte order mark names, else UTF-8 if it is valid as that, else
    /// whichever older encoding it reads most like, falling back to Latin-1,
    /// which reads anything.
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncoding) {
        for encoding in [TextEncoding.utf8WithBOM, .utf16LittleEndian, .utf16BigEndian] where data.starts(with: encoding.byteOrderMark) {
            let characters = data.dropFirst(encoding.byteOrderMark.count)
            if encoding == .utf8WithBOM { return (String(decoding: characters, as: UTF8.self), encoding) }
            return (String(data: characters, encoding: encoding.stringEncoding) ?? "", encoding)
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        let older: [TextEncoding] = [.shiftJIS, .eucJP, .windowsLatin1]
        #if canImport(Darwin)
        var converted: NSString?
        var isLossy: ObjCBool = false
        let found = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: older.map(\.stringEncoding.rawValue),
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &isLossy)
        if let encoding = older.first(where: { $0.stringEncoding.rawValue == found }), let converted {
            return (converted as String, encoding)
        }
        #else
        // No guessing which reads most like text here: the first that reads at all.
        for encoding in older {
            if let text = String(data: data, encoding: encoding.stringEncoding) { return (text, encoding) }
        }
        #endif
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
