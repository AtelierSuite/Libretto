import AppKit
import LibrettoEngine
import SwiftUI

/// The editor for source code and plain text: the file's text, in a fixed
/// width font, coloured by its syntax, with no pages. Typing is handed to
/// the document a moment after it stops; a document changed from elsewhere,
/// such as by an undo, replaces the text.
@MainActor
final class CodeEditor: NSObject, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
    private(set) var document: WordDocument
    private var scheme: ColorScheme
    let scrollView: NSScrollView
    let textView: NSTextView
    private var syncTask: Task<Void, Never>?
    /// The syntax colouring, kept so that an edit colours only the lines around it. Bracket matching
    /// and auto-closing read the tokens it last coloured by.
    private var coloring = SyntaxColoring()
    /// Set while the editor makes an edit itself, so it is not taken for typing.
    private var isEditing = false
    private lazy var typing = CodeTyping(language: language)
    /// The bracket beside the insertion point and the one it pairs with, while there is such a pair.
    private(set) var matchedBrackets: [Int] = []

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
        textView.textStorage?.delegate = self
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
        (textView as? CodeTextView)?.language = language
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
        let textView = CodeTextView(usingTextLayoutManager: false)
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

    /// The language the text is coloured as: the file's own, until another is chosen for it.
    private(set) lazy var language: SourceLanguage = document.sourceLanguage ?? .plainText

    /// Colours the text as another language, leaving the file as it is.
    func setLanguage(_ new: SourceLanguage) {
        guard new != language else { return }
        language = new
        typing.language = new
        (textView as? CodeTextView)?.language = new
        highlight()
        matchBrackets()
    }

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
        typing.reset()
        highlight()
        matchBrackets()
    }

    private func highlight() {
        guard let storage = textView.textStorage else { return }
        coloring.apply(language, to: storage, scheme: scheme, plainColor: .textColor)
    }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        // Colouring changes attributes only, which leave the colouring as it is.
        guard editedMask.contains(.editedCharacters) else { return }
        coloring.noteEdit(editedRange, changeInLength: delta)
    }

    /// Marks the bracket beside the insertion point and its pair, behind the text.
    private func matchBrackets() {
        guard let layoutManager = textView.layoutManager else { return }
        // Everywhere, as the marks move with the text it was typed into.
        let whole = NSRange(location: 0, length: layoutManager.attributedString().length)
        if !matchedBrackets.isEmpty {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        }
        let selection = textView.selectedRange()
        if selection.length == 0, let pair = CodeTyping.matchingBracket(
            at: selection.location, in: textView.string as NSString, tokens: coloring.tokens
        ) {
            matchedBrackets = [pair.bracket, pair.match]
        } else {
            matchedBrackets = []
        }
        for position in matchedBrackets {
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.4),
                forCharacterRange: NSRange(location: position, length: 1)
            )
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        // Text still being composed, as with a Japanese input method, is the input method's until it is committed.
        guard !isEditing, let text, !textView.hasMarkedText(),
              let edit = typing.edit(
                  replacing: range, with: text, in: textView.string as NSString, tokens: coloring.tokens
              )
        else { return true }
        isEditing = true
        if !edit.movesOnly, textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
            textView.textStorage?.replaceCharacters(
                in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: textAttributes)
            )
            textView.didChangeText()
        }
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
        isEditing = false
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !isEditing { typing.selectionDidChange(textView.selectedRange(), in: textView.string as NSString) }
        matchBrackets()
    }

    func textDidChange(_ notification: Notification) {
        highlight()
        matchBrackets()
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
