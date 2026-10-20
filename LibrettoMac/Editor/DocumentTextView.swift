import AppKit
import LibrettoEngine

/// The text view the pages show. Its own undo is off: every change goes
/// through the document's history instead, as a snapshot of the document.
/// The formatting commands AppKit sends it — Bold, the Fonts window, the
/// Colours window, alignment — change the model, by way of the editor.
final class DocumentTextView: NSTextView {
    weak var editor: PageEditor?

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        allowsUndo = false
        isRichText = true
        importsGraphics = false
        usesFontPanel = true
        usesRuler = false
        isRulerVisible = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        allowsImageEditing = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        setAccessibilityIdentifier("documentText")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // A drop cap set in the margin is drawn beside the text, outside it.
    override var clipsToBounds: Bool {
        get { false }
        set { super.clipsToBounds = newValue }
    }

    // MARK: - Pasting

    /// Text comes in as plain text, in the formatting where it lands; a picture comes in as a picture.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            editor?.insertImage(data)
            return
        }
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // MARK: - Character formatting

    @objc func toggleBold(_ sender: Any?) { editor?.toggleBold() }
    @objc func toggleItalic(_ sender: Any?) { editor?.toggleItalic() }
    @objc func toggleStrikethrough(_ sender: Any?) { editor?.toggleStrikethrough() }
    override func underline(_ sender: Any?) { editor?.toggleUnderline() }
    override func superscript(_ sender: Any?) { editor?.toggleVerticalAlignment(.superscript) }
    override func `subscript`(_ sender: Any?) { editor?.toggleVerticalAlignment(.subscript) }
    override func unscript(_ sender: Any?) {
        guard let editor, editor.state.selectionFormat.verticalAlignment != .baseline else { return }
        editor.toggleVerticalAlignment(editor.state.selectionFormat.verticalAlignment)
    }

    @objc func makeTextBigger(_ sender: Any?) { editor?.adjustFontSize(by: 1) }
    @objc func makeTextSmaller(_ sender: Any?) { editor?.adjustFontSize(by: -1) }
    @objc func clearFormatting(_ sender: Any?) { editor?.clearFormatting() }

    /// A font picked in the Fonts window or one of its favourites, or a size
    /// or trait from the Font menu, applied to each run's own font.
    override func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        editor?.convertFonts { manager.convert($0) }
    }

    /// A colour picked in the Colours window colours the text.
    override func changeColor(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { return }
        editor?.setTextColor(panel.color.rgbHex)
    }

    // MARK: - Paragraph formatting

    override func alignLeft(_ sender: Any?) { editor?.setAlignment(.leading) }
    override func alignCenter(_ sender: Any?) { editor?.setAlignment(.center) }
    override func alignRight(_ sender: Any?) { editor?.setAlignment(.trailing) }
    override func alignJustified(_ sender: Any?) { editor?.setAlignment(.justified) }
    @objc func toggleBulletedList(_ sender: Any?) { editor?.toggleList(.bulleted) }
    @objc func toggleNumberedList(_ sender: Any?) { editor?.toggleList(.numbered) }
    @objc func increaseIndent(_ sender: Any?) { editor?.indent(by: 1) }
    @objc func decreaseIndent(_ sender: Any?) { editor?.indent(by: -1) }

    @objc func applyParagraphStyle(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let choice = item.representedObject as? String else { return }
        if let builtIn = ParagraphStyleChoice(rawValue: choice) {
            editor?.applyParagraphStyle(builtIn)
        } else {
            editor?.applyParagraphStyle(id: choice)
        }
    }

    // MARK: - Inserting

    @objc func insertPageBreak(_ sender: Any?) { editor?.insertPageBreak() }

    // MARK: - Reviewing

    @objc func toggleTrackChanges(_ sender: Any?) {
        guard let editor else { return }
        editor.setTracking(!editor.document.trackRevisions)
    }

    @objc func acceptChange(_ sender: Any?) { editor?.resolveChange(accept: true) }
    @objc func rejectChange(_ sender: Any?) { editor?.resolveChange(accept: false) }
    @objc func acceptAllChanges(_ sender: Any?) { editor?.resolveAllChanges(accept: true) }
    @objc func rejectAllChanges(_ sender: Any?) { editor?.resolveAllChanges(accept: false) }
    @objc func selectNextChange(_ sender: Any?) { editor?.selectChange(forward: true) }
    @objc func selectPreviousChange(_ sender: Any?) { editor?.selectChange(forward: false) }
    @objc func removeLink(_ sender: Any?) { editor?.removeLink() }

    // MARK: - Menus

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor else { return super.validateMenuItem(item) }
        let format = editor.state.selectionFormat
        switch item.action {
        case #selector(toggleBold(_:)): item.state = format.isBold ? .on : .off
        case #selector(toggleItalic(_:)): item.state = format.isItalic ? .on : .off
        case #selector(underline(_:)): item.state = format.isUnderlined ? .on : .off
        case #selector(toggleStrikethrough(_:)): item.state = format.isStruckThrough ? .on : .off
        case #selector(superscript(_:)): item.state = format.verticalAlignment == .superscript ? .on : .off
        case #selector(`subscript`(_:)): item.state = format.verticalAlignment == .subscript ? .on : .off
        case #selector(alignLeft(_:)): item.state = format.alignment == .leading ? .on : .off
        case #selector(alignCenter(_:)): item.state = format.alignment == .center ? .on : .off
        case #selector(alignRight(_:)): item.state = format.alignment == .trailing ? .on : .off
        case #selector(alignJustified(_:)): item.state = format.alignment == .justified ? .on : .off
        case #selector(toggleBulletedList(_:)): item.state = format.listKind == .bulleted ? .on : .off
        case #selector(toggleNumberedList(_:)): item.state = format.listKind == .numbered ? .on : .off
        case #selector(toggleTrackChanges(_:)): item.state = editor.document.trackRevisions ? .on : .off
        case #selector(acceptChange(_:)), #selector(rejectChange(_:)):
            return editor.state.isOnChange || selectedRange().length > 0
        case #selector(removeLink(_:)): return editor.state.isOnLink
        case #selector(applyParagraphStyle(_:)):
            let id = item.representedObject as? String
            let styleID = ParagraphStyleChoice(rawValue: id ?? "").flatMap { editor.document.styles.styleID(for: $0) } ?? id
            item.state = styleID == format.styleID ? .on : .off
        default: break
        }
        return super.validateMenuItem(item)
    }
}

extension NSColor {
    /// Six-digit RGB, as OOXML writes a colour.
    var rgbHex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { String(format: "%02X", Int((max(0, min(1, $0)) * 255).rounded())) }
            .joined()
    }
}
