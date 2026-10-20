import AppKit
import LibrettoEngine
import PDFKit
import UniformTypeIdentifiers

/// A document window's document: a word-processing document, read from and
/// written to any of the files `DocumentFile` handles.
///
/// One converted from a format Libretto cannot write back, such as a Pages
/// '09 document, opens as a new document named after its file, so saving it
/// asks where to keep it as a Word document rather than writing over it.
final class Document: NSDocument {
    private(set) var content = WordDocument()
    private let history = DocumentHistory()
    /// The name of the file a converted document came from.
    private var convertedName: String?
    /// Told when the document changes other than through the editor: an undo, a redo, a revert.
    var onReplace: ((WordDocument) -> Void)?
    /// Hands over what the editor holds that it has not yet, before the document is read for saving.
    var flushEditor: (() -> Void)?

    override init() {
        super.init()
        attachHistory()
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        // A converted document opens as a new one, named after its file, before any window shows it.
        if !savesInPlace, let url = fileURL {
            convertedName = url.deletingPathExtension().lastPathComponent
            fileURL = nil
            fileType = UTType.openXMLDocument.identifier
        }
        addWindowController(DocumentWindowController(document: self))
    }

    private func attachHistory() {
        history.attach(to: undoManager, read: { [unowned self] in content }, write: { [unowned self] restored in
            content = restored
            onReplace?(restored)
        })
    }

    /// Takes a change the editor made, for undo to put back.
    func apply(_ new: WordDocument, scope: EditScope) {
        let old = content
        content = new
        let isStep = history.record(from: old, to: new, scope: scope, canCoalesce: isDocumentEdited)
        // A keystroke that joins the step before it registers nothing of its own to mark the document edited.
        if !isStep, old != new, !isDocumentEdited { updateChangeCount(.changeDone) }
    }

    // MARK: - Reading

    // Documents are read and written on the main thread: neither is done concurrently.

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let type = UTType(typeName) ?? .openXMLDocument
        let read = try DocumentFile.read(fileWrapper, contentType: type)
        MainActor.assumeIsolated {
            content = read
            undoManager?.removeAllActions()
            onReplace?(read)
        }
    }

    /// Whether the document is saved back into the file it came from: not
    /// one converted from a format Libretto only reads.
    var savesInPlace: Bool { content.importedFormat == nil || savesPages }

    /// Whether it is a Pages document its edits are saved back into.
    var savesPages: Bool { content.pagesSource?.body != nil }

    override var displayName: String! {
        get { fileURL == nil ? convertedName ?? super.displayName : super.displayName }
        set { super.displayName = newValue }
    }

    // MARK: - Writing

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let content = MainActor.assumeIsolated {
            flushEditor?()
            return self.content
        }
        return try DocumentFile.fileWrapper(for: content, contentType: UTType(typeName) ?? .openXMLDocument)
    }

    /// Pages only where there is a Pages document to write the edits back into.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        let pages = [UTType.pagesDocument.identifier, UTType.pagesPackage.identifier]
        let savesPages = MainActor.assumeIsolated { self.savesPages }
        return super.writableTypes(for: saveOperation).filter { savesPages || !pages.contains($0) }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.isExtensionHidden = false
        return true
    }

    /// Saves a copy as a Word document, for what a Pages document cannot keep.
    @objc func saveAsWordDocument(_ sender: Any?) {
        flushEditor?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [content.hasMacros ? .macroEnabledDocument : .openXMLDocument]
        panel.nameFieldStringValue = displayName ?? String(localized: "Document.DefaultName")
        guard let window = windowControllers.first?.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let type = (panel.allowedContentTypes.first ?? .openXMLDocument).identifier
            save(to: url, ofType: type, for: .saveToOperation) { error in
                if let error { self.presentError(error) }
            }
        }
    }

    // MARK: - PDF and printing

    @objc func exportPDF(_ sender: Any?) {
        flushEditor?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName ?? String(localized: "Document.DefaultName")) + ".pdf"
        guard let window = windowControllers.first?.window else { return }
        let document = content
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try PDFExporter.data(from: document).write(to: url, options: .atomic)
            } catch {
                self?.presentError(error)
            }
        }
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        flushEditor?()
        guard let pdf = PDFDocument(data: PDFExporter.data(from: content)),
              let operation = pdf.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true)
        else { throw CocoaError(.fileWriteUnknown) }
        operation.jobTitle = displayName
        return operation
    }
}
