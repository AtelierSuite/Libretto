import LibrettoEngine
import SwiftUI
import UniformTypeIdentifiers

/// The app's document: a word-processing document, loaded from and saved to
/// any of the files `DocumentFile` reads and writes.
struct LibrettoDocument: FileDocument {
    static let readableContentTypes = DocumentFile.readableContentTypes
    static let writableContentTypes = DocumentFile.writableContentTypes

    var document: WordDocument

    /// What the opened file used that Libretto cannot edit. Empty for anything we
    /// authored ourselves.
    var unsupportedFeatures: UnsupportedFeatureReport { document.unsupportedFeatures }

    /// The fonts the opened file's text is set in that are not installed,
    /// and what is drawn instead. Edits only pick installed fonts, so this
    /// is worked out once, as the file opens.
    private(set) var fontSubstitutions: [FontSubstitution] = []

    init() {
        document = WordDocument()
    }

    init(document: WordDocument) {
        self.document = document
        fontSubstitutions = Typography.fontSubstitutions(in: document)
    }

    init(configuration: ReadConfiguration) throws {
        document = try DocumentFile.read(configuration.file, contentType: configuration.contentType)
        fontSubstitutions = Typography.fontSubstitutions(in: document)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try DocumentFile.fileWrapper(for: document, contentType: configuration.contentType)
    }
}
