import AppKit
import LibrettoEngine
import SwiftUI
import UniformTypeIdentifiers

/// A document's window: the pages, or the code editor for source code, with
/// the inspector beside them and the toolbar above.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let state = EditorState()
    private var pageEditor: PageEditor?
    private var codeEditor: CodeEditor?
    private let editorHost = EditorHostViewController()
    private let notice = NoticeAccessory()
    private let inspector: InspectorViewController
    private let splitViewController = NSSplitViewController()
    private var stateObserver: NSObjectProtocol?

    private var libretto: Document? { document as? Document }
    /// The page editor, unless the window shows the code editor.
    var editor: PageEditor? { pageEditor }

    init(document: Document) {
        inspector = InspectorViewController(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        let editorItem = NSSplitViewItem(viewController: editorHost)
        editorItem.minimumThickness = 360
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 340
        inspectorItem.canCollapse = true
        splitViewController.splitViewItems = [editorItem, inspectorItem]
        window.contentViewController = splitViewController
        // The content view controller sizes the window to its views; documents open at a size to read pages in.
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.center()
        window.setFrameAutosaveName("DocumentWindow")

        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        notice.layoutAttribute = .bottom
        notice.isHidden = true
        window.addTitlebarAccessoryViewController(notice)

        editorHost.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        stateObserver = NotificationCenter.default.addObserver(
            forName: EditorState.didChange, object: state, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stateChanged() }
        }
        connect(document)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Set once the document has taken the window on, when what is said about saving it can be worked out.
    override var document: AnyObject? {
        didSet {
            refreshNotice()
            updateToolbarState()
            window?.toolbar?.validateVisibleItems()
            if codeEditor != nil {
                // Nothing in the inspector applies to source code.
                DispatchQueue.main.async { [weak self] in self?.setInspectorShown(false) }
            }
        }
    }

    // MARK: - Editors

    private var scheme: ColorScheme {
        editorHost.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func connect(_ document: Document) {
        document.onReplace = { [weak self] restored in self?.documentReplaced(restored) }
        document.flushEditor = { [weak self] in
            self?.pageEditor?.flush()
            self?.codeEditor?.flush()
        }
        makeEditor(for: document.content)
    }

    /// The pages, or the code editor for a source file.
    private func makeEditor(for content: WordDocument) {
        if content.sourceLanguage != nil {
            if let codeEditor {
                codeEditor.update(document: content, scheme: scheme)
                return
            }
            pageEditor = nil
            let editor = CodeEditor(document: content, scheme: scheme)
            editor.onChange = { [weak self] new, scope in self?.editorChanged(new, scope: scope) }
            codeEditor = editor
            editorHost.show(editor.scrollView)
            inspector.editor = nil
            setInspectorShown(false)
        } else {
            if let pageEditor {
                pageEditor.update(document: content, scheme: scheme)
                refreshNotice()
                return
            }
            codeEditor = nil
            let editor = PageEditor(document: content, scheme: scheme, state: state)
            editor.onChange = { [weak self] new, scope in self?.editorChanged(new, scope: scope) }
            pageEditor = editor
            let scrollView = PageScrollView(canvas: editor.canvas)
            editorHost.show(scrollView)
            inspector.editor = editor
            refreshNotice()
        }
        updateToolbarState()
        window?.makeFirstResponder(pageEditor?.textView ?? codeEditor?.textView)
    }

    private func editorChanged(_ new: WordDocument, scope: EditScope) {
        libretto?.apply(new, scope: scope)
        refreshNotice()
        inspector.refresh()
        window?.toolbar?.validateVisibleItems()
    }

    /// The document changed from outside the editor: an undo, a redo, a revert.
    private func documentReplaced(_ restored: WordDocument) {
        if (restored.sourceLanguage != nil) != (codeEditor != nil) {
            pageEditor = nil
            codeEditor = nil
        }
        makeEditor(for: restored)
        inspector.refresh()
        window?.toolbar?.validateVisibleItems()
    }

    private func appearanceChanged() {
        guard let content = libretto?.content else { return }
        pageEditor?.update(document: pageEditor?.document ?? content, scheme: scheme)
        codeEditor?.update(document: codeEditor?.document ?? content, scheme: scheme)
    }

    private func stateChanged() {
        inspector.refresh()
        window?.toolbar?.validateVisibleItems()
        updateToolbarState()
    }

    // MARK: - Notices

    /// Says when changes will not all be kept where they are saved, with the way to keep them.
    private func refreshNotice() {
        guard let libretto, codeEditor == nil else {
            notice.isHidden = true
            return
        }
        let content = libretto.content
        let message: String?
        if libretto.savesPages, PagesWriter.hasUnsavableChanges(content) {
            message = String(localized: "Notice.Pages.Unsaved")
        } else if !libretto.savesInPlace {
            message = String(localized: "Mac.Notice.Converted")
        } else {
            message = nil
        }
        notice.configure(message: message, action: message == nil ? nil : (
            title: String(localized: libretto.savesInPlace ? "Notice.Imported.Save" : "Mac.Notice.SaveAs"),
            perform: { [weak self] in
                guard let libretto = self?.libretto else { return }
                if libretto.savesInPlace {
                    libretto.saveAsWordDocument(nil)
                } else {
                    libretto.saveAs(nil)
                }
            }
        ))
    }

    @objc func showUnsupportedFeatures(_ sender: Any?) {
        guard let window, let libretto else { return }
        let report = libretto.content.unsupportedFeatures
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Notice.UnsupportedFeatures.Title")
        let message = libretto.savesPages ? "Notice.UnsupportedFeatures.PagesMessage"
            : libretto.content.importedFormat != nil ? "Notice.UnsupportedFeatures.ImportedMessage"
            : "Notice.UnsupportedFeatures.Message"
        alert.informativeText = String(localized: String.LocalizationValue(message)) + "\n\n"
            + report.orderedFeatures.map { "• " + $0.label }.joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Inserting

    @objc func insertTable(_ sender: Any?) {
        guard let window, let editor = pageEditor else { return }
        let rows = NSStepperField(label: String(localized: "Mac.InsertTable.Rows"), value: 3, range: 1...50)
        let columns = NSStepperField(label: String(localized: "Mac.InsertTable.Columns"), value: 3, range: 1...10)
        let stack = NSStackView(views: [rows, columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        let alert = NSAlert()
        alert.messageText = String(localized: "Panel.InsertTable.Title")
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "InsertTable.Insert"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            editor.insertTable(rows: rows.value, columns: columns.value)
        }
    }

    @objc func insertPicture(_ sender: Any?) {
        guard let window, let editor = pageEditor else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            editor.insertImage(data)
        }
    }

    @objc func editLink(_ sender: Any?) {
        guard let window, let editor = pageEditor else { return }
        editor.flush()
        let context = editor.linkContext
        let address = NSTextField(string: context.link.map(Self.address) ?? "")
        address.placeholderString = String(localized: "Link.Address")
        let text = NSTextField(string: context.text)
        text.placeholderString = String(localized: "Link.Text")
        let stack = NSStackView(views: [address, text])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        for field in [address, text] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Panel.Link.Title")
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: context.link == nil ? "Link.Insert" : "Link.Update"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        if context.link != nil { alert.addButton(withTitle: String(localized: "Link.Remove")) }
        alert.window.initialFirstResponder = address
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                guard !address.stringValue.trimmed.isEmpty else { return }
                editor.makeLink(address: address.stringValue, text: text.stringValue)
            case .alertThirdButtonReturn:
                editor.removeLink()
            default:
                break
            }
        }
    }

    /// A link as the address field shows it: a bookmark as `#name`.
    private static func address(_ link: Hyperlink) -> String {
        if let anchor = link.anchor { return "#" + anchor }
        return link.url?.absoluteString ?? ""
    }

    @objc func addComment(_ sender: Any?) {
        promptForComment(title: String(localized: "Comments.Add")) { [weak self] text in
            self?.pageEditor?.addComment(text)
        }
    }

    /// Asks for a comment's text, in a sheet.
    func promptForComment(title: String, initial: String = "", _ done: @escaping (String) -> Void) {
        guard let window else { return }
        let field = NSTextField(string: initial)
        field.placeholderString = String(localized: "Comments.New.Placeholder")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Common.OK"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let text = field.stringValue.trimmed
            guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
            done(text)
        }
    }

    // MARK: - Zoom

    private var pageScrollView: NSScrollView? { pageEditor?.canvas.enclosingScrollView }

    @objc func zoomIn(_ sender: Any?) {
        if let codeEditor { return codeEditor.adjustPointSize(by: 1) }
        pageScrollView?.animator().magnification *= 1.25
    }

    @objc func zoomOut(_ sender: Any?) {
        if let codeEditor { return codeEditor.adjustPointSize(by: -1) }
        pageScrollView?.animator().magnification /= 1.25
    }

    @objc func actualSize(_ sender: Any?) {
        if let codeEditor { return codeEditor.resetPointSize() }
        pageScrollView?.animator().magnification = 1
    }

    @objc func showFormatInspector(_ sender: Any?) {
        setInspectorShown(true)
    }

    private func setInspectorShown(_ isShown: Bool) {
        guard let item = splitViewController.splitViewItems.last else { return }
        if window?.isVisible == true { item.animator().isCollapsed = !isShown } else { item.isCollapsed = !isShown }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(insertTable(_:)), #selector(insertPicture(_:)), #selector(editLink(_:)),
             #selector(addComment(_:)), #selector(showFormatInspector(_:)):
            return pageEditor != nil && libretto?.isInViewingMode == false
        case #selector(showUnsupportedFeatures(_:)):
            return libretto?.content.unsupportedFeatures.isEmpty == false
        default:
            return true
        }
    }

    // MARK: - Toolbar

    private enum Item {
        static let style = NSToolbarItem.Identifier("style")
        static let font = NSToolbarItem.Identifier("font")
        static let alignment = NSToolbarItem.Identifier("alignment")
        static let lists = NSToolbarItem.Identifier("lists")
        static let insert = NSToolbarItem.Identifier("insert")
        static let comment = NSToolbarItem.Identifier("comment")
        static let track = NSToolbarItem.Identifier("track")
        static let unsupported = NSToolbarItem.Identifier("unsupported")
        static let language = NSToolbarItem.Identifier("language")
    }

    /// The items that only do something to pages, hidden while editing source code.
    private static let pageItems: Set<NSToolbarItem.Identifier> = [
        Item.style, Item.font, Item.alignment, Item.lists, Item.insert, Item.comment, Item.track, .toggleInspector,
    ]

    private var languageButton: NSPopUpButton?
    private var fontControl: NSSegmentedControl?
    private var alignmentControl: NSSegmentedControl?
    private var trackItem: NSToolbarItem?

    /// Quick formatting on the left, what can be added on the right; the rest of the formatting is in the inspector.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.style, Item.font, .flexibleSpace, Item.insert, Item.comment, Item.track,
         Item.unsupported, Item.language, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Item.alignment, Item.lists, .space, .print]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = makeToolbarItem(identifier)
        if Self.pageItems.contains(identifier) { item?.isHidden = codeEditor != nil }
        if identifier == Item.language { item?.isHidden = codeEditor == nil }
        return item
    }

    private func makeToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case Item.style:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "ActionBar.Style")
            item.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
            item.menu = StyleMenu.make(for: { [weak self] in self?.pageEditor })
            item.showsIndicator = true
            return validated(item)
        case Item.font:
            let control = NSSegmentedControl(
                images: ["bold", "italic", "underline", "strikethrough"].map { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! },
                trackingMode: .selectAny, target: self, action: #selector(fontSegment(_:))
            )
            for (index, key) in ["Toolbar.Bold", "Toolbar.Italic", "Toolbar.Underline", "Toolbar.Strikethrough"].enumerated() {
                control.setToolTip(String(localized: String.LocalizationValue(key)), forSegment: index)
            }
            fontControl = control
            return group(identifier, label: String(localized: "Format.Section.Text"), control: control)
        case Item.alignment:
            let control = NSSegmentedControl(
                images: ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"].map {
                    NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
                },
                trackingMode: .selectOne, target: self, action: #selector(alignmentSegment(_:))
            )
            for (index, alignment) in [ParagraphAlignment.leading, .center, .trailing, .justified].enumerated() {
                control.setToolTip(alignment.label, forSegment: index)
            }
            alignmentControl = control
            return group(identifier, label: String(localized: "ActionBar.Alignment"), control: control)
        case Item.lists:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Mac.Toolbar.Lists")
            item.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "ActionBar.Bullets"), action: #selector(DocumentTextView.toggleBulletedList(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "ActionBar.Numbering"), action: #selector(DocumentTextView.toggleNumberedList(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Mac.Menu.IncreaseIndent"), action: #selector(DocumentTextView.increaseIndent(_:)), keyEquivalent: "")
            menu.addItem(withTitle: String(localized: "Mac.Menu.DecreaseIndent"), action: #selector(DocumentTextView.decreaseIndent(_:)), keyEquivalent: "")
            item.menu = menu
            return validated(item)
        case Item.insert:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "ActionBar.Insert")
            item.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
            item.menu = MainMenu.insertMenu()
            return validated(item)
        case Item.comment:
            return button(identifier, label: String(localized: "Comments.Add"), symbol: "text.bubble", action: #selector(addComment(_:)))
        case Item.track:
            let item = button(identifier, label: String(localized: "Review.TrackChanges"), symbol: "pencil.line",
                              action: #selector(DocumentTextView.toggleTrackChanges(_:)))
            trackItem = item
            return item
        case Item.language:
            let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            for language in SourceLanguage.allCases {
                popUp.addItem(withTitle: language.displayName)
                popUp.lastItem?.representedObject = language.rawValue
            }
            popUp.target = self
            popUp.action = #selector(languageChosen(_:))
            languageButton = popUp
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Mac.Toolbar.Language")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.view = popUp
            updateToolbarState()
            return item
        case Item.unsupported:
            return button(identifier, label: String(localized: "Toolbar.UnsupportedFeatures.Label"),
                          symbol: "exclamationmark.triangle", action: #selector(showUnsupportedFeatures(_:)))
        default:
            return nil
        }
    }

    private func validated(_ item: NSToolbarItem) -> NSToolbarItem {
        item.toolTip = item.label
        item.autovalidates = true
        return item
    }

    private func button(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.isBordered = true
        return item
    }

    private func group(_ identifier: NSToolbarItem.Identifier, label: String, control: NSSegmentedControl) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = control
        return item
    }

    @objc private func fontSegment(_ sender: NSSegmentedControl) {
        guard let editor = pageEditor else { return }
        let format = state.selectionFormat
        let segment = sender.selectedSegment
        switch segment {
        case 0 where sender.isSelected(forSegment: 0) != format.isBold: editor.toggleBold()
        case 1 where sender.isSelected(forSegment: 1) != format.isItalic: editor.toggleItalic()
        case 2 where sender.isSelected(forSegment: 2) != format.isUnderlined: editor.toggleUnderline()
        case 3 where sender.isSelected(forSegment: 3) != format.isStruckThrough: editor.toggleStrikethrough()
        default: break
        }
        updateToolbarState()
    }

    @objc private func languageChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let language = SourceLanguage(rawValue: raw) else { return }
        codeEditor?.setLanguage(language)
    }

    @objc private func alignmentSegment(_ sender: NSSegmentedControl) {
        let alignments: [ParagraphAlignment] = [.leading, .center, .trailing, .justified]
        guard alignments.indices.contains(sender.selectedSegment) else { return }
        pageEditor?.setAlignment(alignments[sender.selectedSegment])
    }

    private func updateToolbarState() {
        let format = state.selectionFormat
        let isPages = pageEditor != nil
        for item in window?.toolbar?.items ?? [] {
            if Self.pageItems.contains(item.itemIdentifier) { item.isHidden = codeEditor != nil }
            if item.itemIdentifier == Item.language { item.isHidden = codeEditor == nil }
        }
        if let languageButton, let codeEditor {
            languageButton.selectItem(at: SourceLanguage.allCases.firstIndex(of: codeEditor.language) ?? 0)
        }
        if let fontControl {
            fontControl.isEnabled = isPages
            for (index, isOn) in [format.isBold, format.isItalic, format.isUnderlined, format.isStruckThrough].enumerated() {
                fontControl.setSelected(isOn, forSegment: index)
            }
        }
        if let alignmentControl {
            alignmentControl.isEnabled = isPages
            let alignments: [ParagraphAlignment] = [.leading, .center, .trailing, .justified]
            alignmentControl.selectedSegment = alignments.firstIndex(of: format.alignment) ?? 0
        }
        trackItem?.image = NSImage(
            systemSymbolName: state.isTracking ? "pencil.line" : "pencil", accessibilityDescription: trackItem?.label
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateToolbarState()
    }
}

extension DocumentWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.unsupported:
            item.isHidden = libretto?.content.unsupportedFeatures.isEmpty != false
            return !item.isHidden
        case Item.style, Item.lists, Item.insert, Item.comment, Item.track:
            return pageEditor != nil
        default:
            return validate(item.action)
        }
    }
}

/// The scroll view the pages are in, keeping them in the middle as it resizes.
final class PageScrollView: NSScrollView {
    private let canvas: PageCanvasView

    init(canvas: PageCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 4
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func tile() {
        super.tile()
        canvas.layoutPages()
    }
}

/// Holds the editor, and tells of the appearance changing.
final class EditorHostViewController: NSViewController {
    var onAppearanceChange: (() -> Void)?
    private var editorView: NSView?

    override func loadView() {
        let view = AppearanceView()
        view.onAppearanceChange = { [weak self] in self?.onAppearanceChange?() }
        self.view = view
    }

    func show(_ editor: NSView) {
        editorView?.removeFromSuperview()
        editorView = editor
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.topAnchor),
            editor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private final class AppearanceView: NSView {
        var onAppearanceChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }
}

/// A bar under the toolbar, saying what will not be kept and offering a way to keep it.
final class NoticeAccessory: NSTitlebarAccessoryViewController {
    private let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var perform: (() -> Void)?

    override func loadView() {
        icon.contentTintColor = .systemOrange
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(tapped)
        let row = NSStackView(views: [icon, label, button])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.setAccessibilityIdentifier("notice")
        view = row
    }

    func configure(message: String?, action: (title: String, perform: () -> Void)?) {
        _ = view
        label.stringValue = message ?? ""
        button.title = action?.title ?? ""
        button.isHidden = action == nil
        perform = action?.perform
        isHidden = message == nil
    }

    @objc private func tapped() { perform?() }
}

/// A labelled number with a stepper beside it.
final class NSStepperField: NSStackView {
    private let field = NSTextField()
    private let stepper = NSStepper()

    var value: Int { stepper.integerValue }

    init(label: String, value: Int, range: ClosedRange<Int>) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: label)
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.integerValue = value
        stepper.target = self
        stepper.action = #selector(stepped)
        field.integerValue = value
        field.alignment = .right
        field.target = self
        field.action = #selector(typed)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        title.widthAnchor.constraint(equalToConstant: 100).isActive = true
        setViews([title, field, stepper], in: .leading)
        spacing = 6
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func stepped() { field.integerValue = stepper.integerValue }

    @objc private func typed() {
        stepper.integerValue = field.integerValue
        field.integerValue = stepper.integerValue
    }
}
