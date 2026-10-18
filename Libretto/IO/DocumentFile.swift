import Foundation
import UniformTypeIdentifiers

extension UTType {
    // Each is declared in the Info.plist. Should one go missing, it stays a type of its own,
    // never a broader one like `.data` that every file, and every save, would match.

    /// The Office Open XML document type, declared by the system.
    static let openXMLDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
    /// The `.docm` document, which may carry macros. It does not conform to
    /// the plain document type, so it is asked about in its own right.
    static let macroEnabledDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document.macroenabled")
    /// Markdown, declared by the app. It conforms to plain text, so it is asked about first.
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    /// A Pages document saved as a single file, and as a package.
    static let pagesDocument = UTType(importedAs: "com.apple.iwork.pages.sffpages")
    static let pagesPackage = UTType(importedAs: "com.apple.iwork.pages.pages", conformingTo: .package)
}

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
enum DocumentFile {
    static let readableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument, .pagesDocument, .pagesPackage,
    ] + SourceLanguage.contentTypes + [.plainText]
    static let writableContentTypes: [UTType] = [
        .openXMLDocument, .macroEnabledDocument, .markdownDocument, .pagesDocument, .pagesPackage,
    ] + SourceLanguage.contentTypes + [.plainText]

    /// The document a file holds, read as its type says.
    static func read(_ file: FileWrapper, contentType: UTType) throws -> WordDocument {
        if file.isDirectory {
            return try PagesReader.document(fromFiles: files(in: file))
        }
        guard let data = file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let filename = file.filename ?? file.preferredFilename
        if let language = SourceLanguage(contentType: contentType, filename: filename) {
            // A video sharing TypeScript's extension is no text to open.
            if contentType.conforms(to: .mpeg2TransportStream), data.prefix(4096).contains(0) {
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

    /// The file a document is saved as, in a type.
    static func fileWrapper(for document: WordDocument, contentType: UTType) throws -> FileWrapper {
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
}
