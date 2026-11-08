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

    init() {
        document = WordDocument()
    }

    init(document: WordDocument) {
        self.document = document
    }

    init(configuration: ReadConfiguration) throws {
        document = try DocumentFile.read(configuration.file, contentType: configuration.contentType)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try DocumentFile.fileWrapper(for: document, contentType: configuration.contentType)
    }
}
