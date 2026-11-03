import AppKit
import LibrettoEngine
import SwiftUI

/// The editor for source code and plain text: the file's text, in a fixed
/// width font, coloured by its syntax, with no pages, and under it the file's
/// line endings and encoding. Typing is handed to the document a moment after
/// it stops; a document changed from elsewhere, such as by an undo, replaces the text.
@MainActor
final class CodeEditor: NSObject, NSTextViewDelegate, @MainActor NSTextStorageDelegate {
    private(set) var document: WordDocument
    private var scheme: ColorScheme
    let scrollView: NSScrollView
    let textView: NSTextView
    /// The text, and the bar under it.
    let view: NSView
    private let lineEndingButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encodingButton = NSPopUpButton(frame: .zero, pullsDown: false)
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
        view = NSView()
        super.init()
        makeStatusBar()
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
        let text = PlainText.text(of: document)
        (textView as? CodeTextView)?.indentUnit = IndentUnit.detect(in: text) ?? .standard
        setText(text)
        updateStatusBar()
    }

    /// The bar under the text, with the file's line endings and encoding in
    /// menus that change what it is saved with.
    private func makeStatusBar() {
        let separator = NSBox()
        separator.boxType = .separator
        for (button, items, label, identifier) in [
            (lineEndingButton, LineEnding.allCases.map { ($0.displayName, $0.rawValue) },
             String(localized: "Mac.CodeEditor.LineEndings"), "lineEnding"),
            (encodingButton, TextEncoding.allCases.map { ($0.displayName, $0.rawValue) },
             String(localized: "Mac.CodeEditor.Encoding"), "textEncoding"),
        ] {
            for (title, raw) in items {
                button.addItem(withTitle: title)
                button.lastItem?.representedObject = raw
            }
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(identifier)
        }
        lineEndingButton.action = #selector(lineEndingChosen(_:))
        encodingButton.action = #selector(encodingChosen(_:))
        let bar = NSStackView(views: [lineEndingButton, encodingButton])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        bar.setHuggingPriority(.defaultHigh, for: .vertical)

        for subview in [scrollView, separator, bar] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updateStatusBar() {
        lineEndingButton.selectItem(at: LineEnding.allCases.firstIndex(of: document.lineEnding) ?? 0)
        encodingButton.selectItem(at: TextEncoding.allCases.firstIndex(of: document.textEncoding) ?? 0)
    }

    @objc private func lineEndingChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let ending = LineEnding(rawValue: raw) else { return }
        changeTextFile { $0.lineEnding = ending }
    }

    @objc private func encodingChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let encoding = TextEncoding(rawValue: raw) else { return }
        changeTextFile { $0.textEncoding = encoding }
    }

    /// Changes how the file is saved, once typing on its way to the document has reached it.
    /// An encoding that cannot write all of the text is turned down, the text left as it is.
    private func changeTextFile(_ change: (inout WordDocument) -> Void) {
        flush()
        var changed = document
        change(&changed)
        guard changed != document else { return }
        guard changed.textEncoding.canEncode(textView.string) else {
            updateStatusBar()
            let alert = NSAlert()
            alert.messageText = String(
                format: String(localized: "Mac.CodeEditor.Encoding.Unwritable"), changed.textEncoding.displayName
            )
            alert.informativeText = String(localized: "Mac.CodeEditor.Encoding.Unwritable.Detail")
            if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        document = changed
        onChange?(document, .other)
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
        updateStatusBar()
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

    // MARK: - Go to line

    /// How many lines the text has, the most a line to go to can be.
    var lineCount: Int { PlainText.lineCount(of: textView.string) }

    /// Puts the insertion point at the start of line `number`, counting from 1,
    /// and scrolls it into view. A number past the end is the last line.
    func goToLine(_ number: Int) {
        let location = PlainText.location(ofLine: number, in: textView.string)
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.window?.makeFirstResponder(textView)
        textView.scrollRangeToVisible(range)
        // The line, briefly, so the eye finds where the text has moved to.
        let line = (textView.string as NSString).lineRange(for: range)
        if line.length > 0 { textView.showFindIndicator(for: line) }
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
        // A character the file's encoding cannot write makes it UTF-8, as it is saved.
        document.textEncoding = document.textEncoding.fitting(textView.string)
        updateStatusBar()
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
