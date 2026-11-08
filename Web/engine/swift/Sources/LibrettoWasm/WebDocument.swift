import Foundation
import LibrettoEngine

/// What a file Libretto opens holds, and how it is read and written. The web's
/// counterpart of the Apple apps' `LibrettoDocument`, keyed by file name
/// rather than by uniform type, since that is what a browser hands over.
struct WebDocument {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    var document: WordDocument
    var fileName: String
    /// The format the file came in; `nil` for a new document, which is a Word document.
    var format: DocumentFile.Format?

    init(document: WordDocument = WordDocument(), fileName: String) {
        self.document = document
        self.fileName = fileName
        format = nil
    }

    init(data: Data, fileName: String) throws {
        self.fileName = fileName
        let format = DocumentFile.Format(filename: fileName) ?? Self.sniff(data)
        document = try DocumentFile.read(data, format: format)
        self.format = format
    }

    /// A file whose name says nothing: a ZIP package is a Word document, anything else text.
    private static func sniff(_ data: Data) -> DocumentFile.Format {
        data.starts(with: [0x50, 0x4B]) ? .word : .plainText
    }

    /// Whether the document opens in the code editor: plain text and source code.
    var isText: Bool { format?.isText ?? false }

    /// Whether a Pages document can take its edits back. One from Pages '09, or
    /// a page layout one, is only read, and saved as a Word document.
    var isSavablePages: Bool { format == .pages && document.pagesSource != nil }

    /// The formats the document can be saved as, its own first.
    var saveFormats: [DocumentFile.Format] {
        switch format {
        case .plainText, .source:
            return [defaultSaveFormat]
        case .markdown:
            return [.markdown, .word, .plainText]
        case .pages:
            return (isSavablePages ? [.pages] : []) + [.word, .markdown, .plainText]
        case .macroEnabledWord:
            return [.macroEnabledWord, .word, .markdown, .plainText]
        case .word, nil:
            return (document.hasMacros ? [.macroEnabledWord] : []) + [.word, .markdown, .plainText]
        }
    }

    /// The format a plain Save writes: the one the file came in, where it can be written back.
    var defaultSaveFormat: DocumentFile.Format {
        switch format {
        case .pages where !isSavablePages: return .word
        case let format?: return format
        case nil: return .word
        }
    }

    /// The name a file saved in `format` is given: the document's own name for
    /// its own format, else its name with the format's extension.
    func fileName(for format: DocumentFile.Format) -> String {
        if format == self.format, format.isText { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        return "\(base.isEmpty ? "Untitled" : base).\(format.fileExtension)"
    }

    func data(as format: DocumentFile.Format) throws -> Data {
        try DocumentFile.data(for: document, format: format)
    }
}

extension DocumentFile.Format {
    /// The format's name in requests and responses.
    var key: String {
        switch self {
        case .word: return "docx"
        case .macroEnabledWord: return "docm"
        case .markdown: return "md"
        case .pages: return "pages"
        case .plainText: return "txt"
        case .source(let language): return "source:\(language.rawValue)"
        }
    }

    init?(key: String) {
        switch key {
        case "docx": self = .word
        case "docm": self = .macroEnabledWord
        case "md": self = .markdown
        case "pages": self = .pages
        case "txt": self = .plainText
        default:
            guard key.hasPrefix("source:"), let language = SourceLanguage(rawValue: String(key.dropFirst(7))) else {
                return nil
            }
            self = .source(language)
        }
    }
}
