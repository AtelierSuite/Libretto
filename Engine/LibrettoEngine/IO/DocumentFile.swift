import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

extension UTType {
    // Each is declared in the Info.plist. Should one go missing, it stays a type of its own,
    // never a broader one like `.data` that every file, and every save, would match.

    /// The Office Open XML document type, declared by the system.
    public static let openXMLDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    /// The `.docm` document, which may carry macros. It does not conform to
    /// the plain document type, so it is asked about in its own right.
    public static let macroEnabledDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document.macroenabled")
    /// Markdown, declared by the app. It conforms to plain text, so it is asked about first.
    public static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    /// A Pages document saved as a single file, and as a package.
    public static let pagesDocument = UTType(importedAs: "com.apple.iwork.pages.sffpages")
    public static let pagesPackage = UTType(importedAs: "com.apple.iwork.pages.pages", conformingTo: .package)
}
#endif

/// Reading and writing the files Libretto opens: `.docx` and `.docm`,
/// Markdown, source code and plain text, and Pages documents.
///
/// A `.docm` opens like any other document. Its macros are kept, and saved
/// back with it, but Libretto never runs them. Plain text and source code open
/// in the code editor and save back as text, with syntax colouring only for
/// source code. A Markdown file keeps only the formatting Markdown has. A
/// Pages document saves its edits back into itself, as far as `PagesWriter`
/// can; one from Pages '09, or a page layout one, is only read, and is saved
/// as a Word document to keep changes.
public enum DocumentFile: Sendable {
    #if canImport(UniformTypeIdentifiers)
    public static let readableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument, .pagesDocument, .pagesPackage,
    ] + SourceLanguage.contentTypes + [.plainText]
    public static let writableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument, .pagesDocument, .pagesPackage,
    ] + SourceLanguage.contentTypes + [.plainText]

    /// The document a file holds, read as its type says.
    public static func read(_ file: FileWrapper, contentType: UTType) throws -> WordDocument {
        if file.isDirectory {
            return try PagesReader.document(fromFiles: files(in: file))
        }
        guard let data = file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let filename = file.filename ?? file.preferredFilename
        if let language = SourceLanguage(contentType: contentType, filename: filename) {
            // A video sharing TypeScript's extension is no text to open, nor is a property list saved as binary.
            if contentType.conforms(to: .mpeg2TransportStream), data.prefix(4096).contains(0) {
                throw CocoaError(.fileReadCorruptFile)
            }
            if contentType.conforms(to: .propertyList), data.starts(with: Array("bplist".utf8)) {
                throw CocoaError(.fileReadCorruptFile)
            }
            var document = PlainText.document(from: data, format: PlainText.codeFormat)
            document.sourceLanguage = language
            return document
        } else if contentType.conforms(to: .markdownDocument) {
            return MarkdownReader.document(from: data)
        } else if contentType.conforms(to: .plainText) {
            return PlainText.document(from: data)
        } else if contentType.conforms(to: .pagesDocument) || contentType.conforms(to: .pagesPackage) {
            // A package type on a single file is the package zipped.
            return try PagesReader.document(from: data)
        } else {
            return try DOCXReader.document(from: data)
        }
    }

    #endif

    /// A package's files, by their paths within it, leaving out those the readers have no use for.
    private static func files(in wrapper: FileWrapper, under prefix: String = "") -> [String: Data] {
        guard wrapper.isDirectory else { return [:] }
        var files: [String: Data] = [:]
        for (name, child) in wrapper.fileWrappers ?? [:] {
            if child.isDirectory {
                files.merge(Self.files(in: child, under: prefix + name + "/")) { first, _ in first }
            } else if IWorkArchive.isRead(prefix + name), let contents = child.regularFileContents {
                files[prefix + name] = contents
            }
        }
        return files
    }

    #if canImport(UniformTypeIdentifiers)
    /// The file a document is saved as, in a type.
    public static func fileWrapper(for document: WordDocument, contentType: UTType) throws -> FileWrapper {
        // A Pages document is saved back into itself, and is never overwritten with something Pages cannot open.
        if contentType.conforms(to: .pagesDocument) || contentType.conforms(to: .pagesPackage) {
            return try PagesWriter.fileWrapper(for: document, asPackage: contentType.conforms(to: .pagesPackage))
        }
        // Text has no way to track changes; it is saved as it reads with them accepted.
        var text = document
        text.body = Revisions.resolve(document.body, accept: true)
        if contentType.conforms(to: .markdownDocument) {
            return FileWrapper(regularFileWithContents: MarkdownWriter.data(from: text))
        }
        if contentType.conforms(to: .plainText) || document.sourceLanguage != nil
            || SourceLanguage(contentType: contentType, filename: nil) != nil {
            return FileWrapper(regularFileWithContents: PlainText.data(from: text))
        }
        // A `.docx` cannot hold macros, and Word will not open one that claims to.
        let keepsMacros = contentType.conforms(to: .macroEnabledDocument)
        return FileWrapper(regularFileWithContents: try DOCXWriter.data(
            from: keepsMacros ? document : document.withoutMacros
        ))
    }
    #endif
}

// MARK: - By name

extension DocumentFile {
    /// The kinds of file Libretto reads and writes, told apart by name: for
    /// platforms with no system file types, such as WebAssembly, and for files
    /// that arrive with nothing but a name.
    public enum Format: Equatable, Sendable {
        case word
        /// A `.docm`, which may carry macros.
        case macroEnabledWord
        case markdown
        /// A Pages document as a single file, or a package zipped.
        case pages
        case plainText
        case source(SourceLanguage)

        /// The format a file's name says it is in; `nil` for one Libretto does not open.
        public init?(filename: String) {
            switch (filename as NSString).pathExtension.lowercased() {
            case "docx", "dotx": self = .word
            case "docm", "dotm": self = .macroEnabledWord
            case "md", "markdown", "mdown", "mkd": self = .markdown
            case "pages": self = .pages
            case "txt", "text": self = .plainText
            default:
                guard let language = SourceLanguage(filename: filename) else { return nil }
                self = language == .plainText ? .plainText : .source(language)
            }
        }

        /// The extension a file in the format is saved with.
        public var fileExtension: String {
            switch self {
            case .word: return "docx"
            case .macroEnabledWord: return "docm"
            case .markdown: return "md"
            case .pages: return "pages"
            case .plainText: return "txt"
            case .source(let language): return language.fileExtensions.first ?? "txt"
            }
        }

        /// The MIME type a file in the format is saved as.
        public var mimeType: String {
            switch self {
            case .word: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case .macroEnabledWord: return "application/vnd.ms-word.document.macroEnabled.12"
            case .markdown: return "text/markdown"
            case .pages: return "application/vnd.apple.pages"
            case .plainText, .source: return "text/plain"
            }
        }

        /// Whether the format keeps no more than text, and opens in the code editor.
        public var isText: Bool {
            switch self {
            case .plainText, .source: return true
            default: return false
            }
        }
    }

    /// The document a file holds, read as its format says.
    public static func read(_ data: Data, format: Format) throws -> WordDocument {
        switch format {
        case .word, .macroEnabledWord:
            return try DOCXReader.document(from: data)
        case .markdown:
            return MarkdownReader.document(from: data)
        case .pages:
            return try PagesReader.document(from: data)
        case .plainText:
            return PlainText.document(from: data)
        case .source(let language):
            var document = PlainText.document(from: data, format: PlainText.codeFormat)
            document.sourceLanguage = language
            return document
        }
    }

    /// A document's file, in a format: a Pages document is saved back into
    /// itself, as a single file.
    public static func data(for document: WordDocument, format: Format) throws -> Data {
        if format == .pages {
            return try PagesWriter.data(for: document)
        }
        // Text has no way to track changes; it is saved as it reads with them accepted.
        var text = document
        text.body = Revisions.resolve(document.body, accept: true)
        switch format {
        case .markdown:
            return MarkdownWriter.data(from: text)
        case .plainText, .source:
            return PlainText.data(from: text)
        case .macroEnabledWord:
            return try DOCXWriter.data(from: document)
        default:
            // A `.docx` cannot hold macros, and Word will not open one that claims to.
            return try DOCXWriter.data(from: document.withoutMacros)
        }
    }
}
