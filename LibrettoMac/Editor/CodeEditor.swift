import AppKit
import LibrettoEngine
import SwiftUI

/// The editor for source code and plain text: the file's text, in a fixed
/// width font, coloured by its syntax, with no pages. Typing is handed to
/// the document a moment after it stops; a document changed from elsewhere,
/// such as by an undo, replaces the text.
@MainActor
final class CodeEditor: NSObject, NSTextViewDelegate {
    private(set) var document: WordDocument
    private var scheme: ColorScheme
    let scrollView: NSScrollView
    let textView: NSTextView
    private var syncTask: Task<Void, Never>?

    /// Hands a changed document to whoever owns it.
    var onChange: ((WordDocument, EditScope) -> Void)?

    static let defaultPointSize: CGFloat = 13
    private var pointSize = CGFloat(UserDefaults.standard.double(forKey: "codePointSize")).nonZero ?? defaultPointSize

    init(document: WordDocument, scheme: ColorScheme) {
        self.document = document
        self.scheme = scheme
        (scrollView, textView) = Self.makeTextView()
        super.init()
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = CGSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityIdentifier("codeText")
        applyFont()
        setText(PlainText.text(of: document))
    }

    /// A text view wrapping its lines to the width of the window, with the line numbers beside it.
    /// It lays out with TextKit 1, which the line numbers and the current line read from.
    private static func makeTextView() -> (NSScrollView, NSTextView) {
        // Any size to start with, so the text view can follow the scroll view's width as it changes.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return (scrollView, textView)
    }

    private var language: SourceLanguage? { document.sourceLanguage }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular), .foregroundColor: NSColor.textColor]
    }

    /// Takes a document from the owner, showing its text if it is not the text the editor already has.
    func update(document new: WordDocument, scheme newScheme: ColorScheme) {
        let schemeChanged = newScheme != scheme
        scheme = newScheme
        guard new != document else {
            if schemeChanged { highlight() }
            return
        }
        document = new
        let text = PlainText.text(of: new)
        if text != textView.string {
            // The document's own version wins over typing not yet handed over.
            syncTask?.cancel()
            syncTask = nil
            setText(text)
        } else if schemeChanged {
            highlight()
        }
    }

    /// Hands over typing that is still waiting.
    func flush() {
        guard syncTask != nil else { return }
        sync()
    }

    private func setText(_ text: String) {
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        let length = (text as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        highlight()
    }

    private func highlight() {
        guard let storage = textView.textStorage else { return }
        if let language {
            SyntaxHighlighter.apply(language, to: storage, scheme: scheme, plainColor: .textColor)
        }
    }

    func textDidChange(_ notification: Notification) {
        highlight()
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private func sync() {
        syncTask?.cancel()
        syncTask = nil
        document.body = PlainText.body(from: textView.string, format: PlainText.codeFormat)
        onChange?(document, .typing)
    }

    // MARK: - Text size

    func adjustPointSize(by step: CGFloat) {
        setPointSize(pointSize + step)
    }

    func resetPointSize() {
        setPointSize(Self.defaultPointSize)
    }

    private func setPointSize(_ size: CGFloat) {
        pointSize = min(48, max(8, size))
        UserDefaults.standard.set(Double(pointSize), forKey: "codePointSize")
        applyFont()
    }

    private func applyFont() {
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        textView.font = font
        textView.typingAttributes = textAttributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
        (scrollView.verticalRulerView as? LineNumberRuler)?.contentChanged()
    }
}

private extension CGFloat {
    var nonZero: CGFloat? { self == 0 ? nil : self }
}
