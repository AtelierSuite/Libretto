import AppKit
import LibrettoEngine

/// The sidebar beside the pages: formatting for the selection, the page
/// setup of its section, and tracked changes and comments.
@MainActor
final class InspectorViewController: NSViewController {
    private let state: EditorState
    weak var editor: PageEditor? {
        didSet { refresh() }
    }

    private let tabs = NSSegmentedControl()
    private let format = FormatInspector()
    private let page = PageInspector()
    private let review = ReviewInspector()
    private let scrollView = NSScrollView()

    init(state: EditorState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = NSView()
        tabs.segmentStyle = .automatic
        tabs.segmentCount = 3
        for (index, key) in ["ActionBar.Format", "ActionBar.PageSetup", "Panel.Review.Title"].enumerated() {
            tabs.setLabel(String(localized: String.LocalizationValue(key)), forSegment: index)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setAccessibilityIdentifier("inspectorTabs")

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for pane in [format, page, review] as [InspectorPane] { pane.inspector = self }
        view = root
        show(format)
    }

    @objc private func tabChanged() {
        let panes: [InspectorPane] = [format, page, review]
        show(panes[max(0, tabs.selectedSegment)])
    }

    private func show(_ pane: InspectorPane) {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            pane.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            pane.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            pane.topAnchor.constraint(equalTo: document.topAnchor),
            pane.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
        ])
        refresh()
    }

    /// Shows the selection's formatting, and the document's changes and comments, as they are now.
    func refresh() {
        guard isViewLoaded else { return }
        let panes: [InspectorPane] = [format, page, review]
        for pane in panes where pane.superview != nil {
            pane.refresh(editor: editor, state: state)
        }
    }

    /// Opens the review tab, for the comments.
    func showReview() {
        tabs.selectedSegment = 2
        tabChanged()
    }

    var windowController: DocumentWindowController? { view.window?.windowController as? DocumentWindowController }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Building blocks

/// One of the inspector's tabs: a column of sections.
@MainActor
class InspectorPane: NSStackView {
    weak var inspector: InspectorViewController?
    var editor: PageEditor? { inspector?.editor }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func refresh(editor: PageEditor?, state: EditorState) {}

    func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func addSection(_ title: String, _ views: [NSView]) {
        if !arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            setCustomSpacing(12, after: line)
        }
        addArrangedSubview(header(title))
        for view in views {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        if let last = views.last { setCustomSpacing(14, after: last) }
    }

    /// A row of a label and a control.
    func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.distribution = .fill
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        return button
    }

    func buttons(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.distribution = .fillEqually
        return row
    }
}

/// A number of points, typed or stepped.
final class PointsField: NSStackView {
    let field = NSTextField()
    let stepper = NSStepper()
    var onChange: ((Double) -> Void)?

    init(range: ClosedRange<Double>, step: Double) {
        super.init(frame: .zero)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        field.target = self
        field.action = #selector(typed)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        let unit = NSTextField(labelWithString: String(localized: "Mac.Unit.Points"))
        unit.textColor = .secondaryLabelColor
        setViews([field, stepper, unit], in: .trailing)
        spacing = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var value: Double {
        get { stepper.doubleValue }
        set {
            stepper.doubleValue = newValue
            field.doubleValue = newValue
        }
    }

    @objc private func typed() {
        stepper.doubleValue = field.doubleValue
        onChange?(stepper.doubleValue)
    }

    @objc private func stepped() {
        field.doubleValue = stepper.doubleValue
        onChange?(stepper.doubleValue)
    }
}

// MARK: - Format

private final class FormatInspector: InspectorPane {
    private let style = NSPopUpButton()
    private let font = NSPopUpButton()
    private let size = PointsField(range: 1...1638, step: 1)
    private let traits = NSSegmentedControl()
    private let color = NSColorWell(style: .minimal)
    private let highlight = NSPopUpButton()
    private let alignmentControl = NSSegmentedControl()
    private let list = NSPopUpButton()
    private let before = PointsField(range: 0...1584, step: 6)
    private let after = PointsField(range: 0...1584, step: 6)
    private let lineSpacing = NSPopUpButton()
    private let table = TableSection()
    private static let lineSpacings: [Double] = [1, 1.15, 1.5, 2, 2.5, 3]
    private static let highlights = ["yellow", "green", "cyan", "magenta", "red", "blue", "lightGray"]

    override init() {
        super.init()
        style.target = self
        style.action = #selector(styleChosen)
        font.target = self
        font.action = #selector(fontChosen)
        size.onChange = { [weak self] points in self?.editor?.setFontSize(points) }
        traits.segmentCount = 4
        traits.trackingMode = .selectAny
        for (index, symbol) in ["bold", "italic", "underline", "strikethrough"].enumerated() {
            traits.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: index)
        }
        traits.target = self
        traits.action = #selector(traitsChanged)
        color.target = self
        color.action = #selector(colorChosen)
        highlight.target = self
        highlight.action = #selector(highlightChosen)
        highlight.addItem(withTitle: String(localized: "Highlight.None"))
        for name in Self.highlights {
            highlight.addItem(withTitle: String(localized: String.LocalizationValue("Highlight." + name)))
            highlight.lastItem?.representedObject = name
        }
        alignmentControl.segmentCount = 4
        for (index, item) in [("text.alignleft", ParagraphAlignment.leading), ("text.aligncenter", .center),
                              ("text.alignright", .trailing), ("text.justify", .justified)].enumerated() {
            alignmentControl.setImage(NSImage(systemSymbolName: item.0, accessibilityDescription: item.1.label), forSegment: index)
            alignmentControl.setToolTip(item.1.label, forSegment: index)
        }
        alignmentControl.trackingMode = .selectOne
        alignmentControl.target = self
        alignmentControl.action = #selector(alignmentChanged)
        list.addItems(withTitles: [
            String(localized: "Mac.List.None"), String(localized: "ActionBar.Bullets"), String(localized: "ActionBar.Numbering"),
        ])
        list.target = self
        list.action = #selector(listChosen)
        before.onChange = { [weak self] points in self?.editor?.setSpacing(before: Int(points * 20)) }
        after.onChange = { [weak self] points in self?.editor?.setSpacing(after: Int(points * 20)) }
        for multiple in Self.lineSpacings {
            lineSpacing.addItem(withTitle: multiple.formatted(.number.precision(.fractionLength(0...2))))
        }
        lineSpacing.target = self
        lineSpacing.action = #selector(lineSpacingChosen)
        let indents = buttons([
            button(String(localized: "Mac.Menu.DecreaseIndent"), #selector(decreaseIndent)),
            button(String(localized: "Mac.Menu.IncreaseIndent"), #selector(increaseIndent)),
        ])

        addSection(String(localized: "ActionBar.Style"), [style])
        addSection(String(localized: "Format.Section.Text"), [
            font, row(String(localized: "Format.Text.Size"), size), traits,
            row(String(localized: "Mac.Format.Colour"), color),
            row(String(localized: "Format.Section.Highlight"), highlight),
        ])
        addSection(String(localized: "ActionBar.Paragraph"), [
            alignmentControl, row(String(localized: "Mac.Format.List"), list), indents,
            row(String(localized: "Mac.Format.SpacingBefore"), before),
            row(String(localized: "Mac.Format.SpacingAfter"), after),
            row(String(localized: "Paragraph.LineSpacing"), lineSpacing),
        ])
        addArrangedSubview(table)
        table.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        table.pane = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func refresh(editor: PageEditor?, state: EditorState) {
        let format = state.selectionFormat
        for control in [style, font, highlight, list, lineSpacing] as [NSControl] + [traits, alignmentControl, color] {
            control.isEnabled = editor != nil
        }
        guard let editor else { return }
        StyleMenu.fill(style.menu!, for: editor, checking: false)
        if let index = style.itemArray.firstIndex(where: { item in
            let id = item.representedObject as? String
            let resolved = ParagraphStyleChoice(rawValue: id ?? "").flatMap { editor.document.styles.styleID(for: $0) } ?? id
            return resolved == format.styleID
        }) {
            style.selectItem(at: index)
        }

        var name = format.fontName ?? editor.document.styles.minorFont ?? NSFont.systemFont(ofSize: 12).familyName ?? ""
        if name == RunStyle.minorThemeFont { name = editor.document.styles.minorFont ?? name }
        if name == RunStyle.majorThemeFont { name = editor.document.styles.majorFont ?? name }
        if font.numberOfItems == 0 || font.lastItem?.representedObject as? Int != editor.document.fontNames.count {
            font.removeAllItems()
            let families = Array(Set(NSFontManager.shared.availableFontFamilies + editor.document.fontNames)).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            font.addItems(withTitles: families)
            font.lastItem?.representedObject = editor.document.fontNames.count
        }
        if name.hasPrefix(".") {
            // The system font, which has no family of its own to pick.
            let system = String(localized: "Mac.Format.SystemFont")
            if font.item(withTitle: system) == nil { font.insertItem(withTitle: system, at: 0) }
            font.selectItem(withTitle: system)
        } else {
            if font.item(withTitle: name) == nil { font.addItem(withTitle: name) }
            font.selectItem(withTitle: name)
        }
        size.value = Double(format.fontSize) / 2
        for (index, isOn) in [format.isBold, format.isItalic, format.isUnderlined, format.isStruckThrough].enumerated() {
            traits.setSelected(isOn, forSegment: index)
        }
        color.color = format.colorHex.flatMap { NSColor(hex: $0) } ?? .textColor
        highlight.selectItem(at: format.highlight.flatMap { Self.highlights.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        alignmentControl.selectedSegment = [ParagraphAlignment.leading, .center, .trailing, .justified].firstIndex(of: format.alignment) ?? 0
        list.selectItem(at: format.listKind == .bulleted ? 1 : format.listKind == .numbered ? 2 : 0)
        before.value = Double(format.spacingBefore) / 20
        after.value = Double(format.spacingAfter) / 20
        let nearest = Self.lineSpacings.enumerated().min { abs($0.element - format.lineSpacing) < abs($1.element - format.lineSpacing) }
        lineSpacing.selectItem(at: nearest?.offset ?? 0)
        table.refresh(editor: editor)
    }

    @objc private func styleChosen() {
        guard let id = style.selectedItem?.representedObject as? String else { return }
        if let choice = ParagraphStyleChoice(rawValue: id) {
            editor?.applyParagraphStyle(choice)
        } else {
            editor?.applyParagraphStyle(id: id)
        }
    }

    @objc private func fontChosen() {
        guard let family = font.titleOfSelectedItem else { return }
        editor?.setFont(family == String(localized: "Mac.Format.SystemFont") ? nil : family)
    }

    @objc private func traitsChanged() {
        guard let editor else { return }
        let format = editor.state.selectionFormat
        let wanted = (0..<4).map { traits.isSelected(forSegment: $0) }
        if wanted[0] != format.isBold { editor.toggleBold() }
        if wanted[1] != format.isItalic { editor.toggleItalic() }
        if wanted[2] != format.isUnderlined { editor.toggleUnderline() }
        if wanted[3] != format.isStruckThrough { editor.toggleStrikethrough() }
    }

    @objc private func colorChosen() {
        editor?.setTextColor(color.color.rgbHex)
    }

    @objc private func highlightChosen() {
        editor?.setHighlight(highlight.selectedItem?.representedObject as? String)
    }

    @objc private func alignmentChanged() {
        let alignments: [ParagraphAlignment] = [.leading, .center, .trailing, .justified]
        guard alignments.indices.contains(alignmentControl.selectedSegment) else { return }
        editor?.setAlignment(alignments[alignmentControl.selectedSegment])
    }

    @objc private func listChosen() {
        guard let editor else { return }
        switch list.indexOfSelectedItem {
        case 1: if editor.state.selectionFormat.listKind != .bulleted { editor.toggleList(.bulleted) }
        case 2: if editor.state.selectionFormat.listKind != .numbered { editor.toggleList(.numbered) }
        default: editor.removeList()
        }
    }

    @objc private func increaseIndent() { editor?.indent(by: 1) }
    @objc private func decreaseIndent() { editor?.indent(by: -1) }

    @objc private func lineSpacingChosen() {
        editor?.setSpacing(lineMultiple: Self.lineSpacings[max(0, lineSpacing.indexOfSelectedItem)])
    }
}

/// The table the selection is on: its cells' text, and rows and columns to add and take away.
private final class TableSection: NSStackView {
    weak var pane: InspectorPane?
    private var editor: PageEditor? { pane?.editor }
    private let grid = NSStackView()
    private let header = NSButton(checkboxWithTitle: String(localized: "Table.Look.HeaderRow"), target: nil, action: nil)
    private var tableID: Table.ID?
    private var shown: Table?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let line = NSBox()
        line.boxType = .separator
        let title = NSTextField(labelWithString: String(localized: "Panel.Table.Title"))
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        header.target = self
        header.action = #selector(headerToggled)
        let rows = NSStackView(views: [
            Self.button(String(localized: "Mac.Table.AddRow"), self, #selector(addRow)),
            Self.button(String(localized: "Mac.Table.DeleteRow"), self, #selector(deleteRow)),
        ])
        rows.distribution = .fillEqually
        let columns = NSStackView(views: [
            Self.button(String(localized: "Mac.Table.AddColumn"), self, #selector(addColumn)),
            Self.button(String(localized: "Mac.Table.DeleteColumn"), self, #selector(deleteColumn)),
        ])
        columns.distribution = .fillEqually
        let delete = Self.button(String(localized: "ActionBar.DeleteTable"), self, #selector(deleteTable))
        for view in [line, title, grid, header, rows, columns, delete] {
            addArrangedSubview(view)
            if view !== title && view !== header { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        return button
    }

    func refresh(editor: PageEditor) {
        guard let table = editor.selectedTable else {
            isHidden = true
            tableID = nil
            shown = nil
            return
        }
        isHidden = false
        header.state = table.rows.first?.isHeader == true ? .on : .off
        // The fields are rebuilt only when the table's shape or its text changed elsewhere.
        guard table != shown else { return }
        let focused = window?.firstResponder as? NSTextView
        if table.id == tableID, focused?.isFieldEditor == true, grid.arrangedSubviews.contains(where: { row in
            (row as? NSStackView)?.arrangedSubviews.contains { focused?.delegate === ($0 as? NSTextField) } == true
        }) {
            shown = table
            return
        }
        tableID = table.id
        shown = table
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (rowIndex, row) in table.rows.prefix(30).enumerated() {
            let fields = row.cells.enumerated().map { cellIndex, cell -> NSTextField in
                let field = CellField(string: cell.plainText)
                field.row = rowIndex
                field.cellIndex = cellIndex
                field.target = self
                field.action = #selector(cellEdited(_:))
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                field.controlSize = .small
                return field
            }
            let line = NSStackView(views: fields)
            line.distribution = .fillEqually
            line.spacing = 4
            grid.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
    }

    private final class CellField: NSTextField {
        var row = 0
        var cellIndex = 0
    }

    private func edit(_ change: (inout Table) -> Void) {
        guard let editor, var table = editor.selectedTable else { return }
        change(&table)
        shown = table
        editor.replaceTable(table)
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        guard let field = sender as? CellField else { return }
        edit { TableEditing.setText(field.stringValue, row: field.row, cell: field.cellIndex, in: &$0) }
    }

    private var lastRow: Int { max(0, (editor?.selectedTable?.rows.count ?? 1) - 1) }
    private var lastColumn: Int { max(0, (editor?.selectedTable?.columnCount ?? 1) - 1) }

    @objc private func addRow() { edit { TableEditing.insertRow(in: &$0, at: lastRow, below: true) }; shown = nil; refreshSelf() }
    @objc private func deleteRow() { edit { TableEditing.deleteRow(in: &$0, at: lastRow) }; shown = nil; refreshSelf() }
    @objc private func addColumn() { edit { TableEditing.insertColumn(in: &$0, at: lastColumn, after: true) }; shown = nil; refreshSelf() }
    @objc private func deleteColumn() { edit { TableEditing.deleteColumn(in: &$0, at: lastColumn) }; shown = nil; refreshSelf() }
    @objc private func headerToggled() { edit { TableEditing.setHeader(in: &$0, row: 0, header.state == .on) } }
    @objc private func deleteTable() { editor?.deleteSelectedTable() }

    private func refreshSelf() {
        if let editor { refresh(editor: editor) }
    }
}

// MARK: - Page

private final class PageInspector: InspectorPane {
    private struct Paper {
        var label: String
        var width: Int
        var height: Int
    }

    private static let papers = [
        Paper(label: "A4", width: 11906, height: 16838), Paper(label: "A5", width: 8391, height: 11906),
        Paper(label: "B5 (JIS)", width: 10319, height: 14571),
        Paper(label: String(localized: "PageSetup.Paper.Letter"), width: 12240, height: 15840),
        Paper(label: String(localized: "PageSetup.Paper.Legal"), width: 12240, height: 20160),
    ]
    private let paper = NSPopUpButton()
    private let orientationControl = NSSegmentedControl()
    private let top = PointsField(range: 0...720, step: 6)
    private let bottom = PointsField(range: 0...720, step: 6)
    private let left = PointsField(range: 0...720, step: 6)
    private let right = PointsField(range: 0...720, step: 6)

    override init() {
        super.init()
        for item in Self.papers { paper.addItem(withTitle: item.label) }
        paper.target = self
        paper.action = #selector(paperChosen)
        orientationControl.segmentCount = 2
        orientationControl.setLabel(String(localized: "PageSetup.Portrait"), forSegment: 0)
        orientationControl.setLabel(String(localized: "PageSetup.Landscape"), forSegment: 1)
        orientationControl.trackingMode = .selectOne
        orientationControl.target = self
        orientationControl.action = #selector(orientationChosen)
        for (field, side) in [(top, 0), (bottom, 1), (left, 2), (right, 3)] {
            field.onChange = { [weak self] points in self?.setMargin(side, Int(points * 20)) }
        }
        addSection(String(localized: "PageSetup.Section.Paper"), [paper, orientationControl])
        addSection(String(localized: "PageSetup.Section.Margins"), [
            row(String(localized: "Mac.Page.Top"), top), row(String(localized: "Mac.Page.Bottom"), bottom),
            row(String(localized: "Mac.Page.Left"), left), row(String(localized: "Mac.Page.Right"), right),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func refresh(editor: PageEditor?, state: EditorState) {
        for control in [paper, orientationControl] as [NSControl] { control.isEnabled = editor != nil }
        guard let editor else { return }
        let setup = editor.currentSection.setup
        let short = min(setup.width, setup.height)
        let long = max(setup.width, setup.height)
        if let index = Self.papers.firstIndex(where: { abs($0.width - short) < 40 && abs($0.height - long) < 40 }) {
            paper.selectItem(at: index)
        } else {
            paper.select(nil)
        }
        orientationControl.selectedSegment = setup.isLandscape ? 1 : 0
        top.value = Double(setup.marginTop) / 20
        bottom.value = Double(setup.marginBottom) / 20
        left.value = Double(setup.marginLeft) / 20
        right.value = Double(setup.marginRight) / 20
    }

    @objc private func paperChosen() {
        let chosen = Self.papers[max(0, paper.indexOfSelectedItem)]
        editor?.updateSection { setup in
            let landscape = setup.isLandscape
            setup.width = landscape ? chosen.height : chosen.width
            setup.height = landscape ? chosen.width : chosen.height
        }
    }

    @objc private func orientationChosen() {
        let landscape = orientationControl.selectedSegment == 1
        editor?.updateSection { setup in
            guard setup.isLandscape != landscape else { return }
            swap(&setup.width, &setup.height)
        }
    }

    private func setMargin(_ side: Int, _ twips: Int) {
        editor?.updateSection { setup in
            switch side {
            case 0: setup.marginTop = twips
            case 1: setup.marginBottom = twips
            case 2: setup.marginLeft = twips
            default: setup.marginRight = twips
            }
        }
    }
}

// MARK: - Review

private final class ReviewInspector: InspectorPane {
    private let tracking = NSSwitch()
    private let author = NSTextField()
    private let comments = NSStackView()
    private let empty = NSTextField(labelWithString: String(localized: "Comments.None"))

    override init() {
        super.init()
        tracking.target = self
        tracking.action = #selector(trackingToggled)
        author.placeholderString = String(localized: "Comment.DefaultAuthor")
        author.stringValue = UserDefaults.standard.string(forKey: Reviewer.nameKey) ?? ""
        author.target = self
        author.action = #selector(authorChanged)
        comments.orientation = .vertical
        comments.alignment = .leading
        comments.spacing = 8
        empty.textColor = .secondaryLabelColor
        addSection(String(localized: "Review.Section.Changes"), [
            row(String(localized: "Review.TrackChanges"), tracking),
            buttons([
                button(String(localized: "Review.Accept"), #selector(DocumentTextView.acceptChange(_:))),
                button(String(localized: "Review.Reject"), #selector(DocumentTextView.rejectChange(_:))),
            ]),
            buttons([
                button(String(localized: "Review.Previous"), #selector(DocumentTextView.selectPreviousChange(_:))),
                button(String(localized: "Review.Next"), #selector(DocumentTextView.selectNextChange(_:))),
            ]),
            buttons([
                button(String(localized: "Review.AcceptAll"), #selector(DocumentTextView.acceptAllChanges(_:))),
                button(String(localized: "Review.RejectAll"), #selector(DocumentTextView.rejectAllChanges(_:))),
            ]),
            row(String(localized: "Comments.YourName"), author),
        ])
        addSection(String(localized: "Panel.Comments.Title"), [
            button(String(localized: "Comments.Add"), #selector(DocumentWindowController.addComment(_:))), empty, comments,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The review buttons act on the text view, wherever the focus is.
    override func button(_ title: String, _ action: Selector) -> NSButton {
        let button = super.button(title, action)
        button.target = nil
        if action == #selector(DocumentWindowController.addComment(_:)) { return button }
        button.target = self
        button.action = #selector(forward(_:))
        button.identifier = NSUserInterfaceItemIdentifier(NSStringFromSelector(action))
        return button
    }

    @objc private func forward(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let textView = editor?.textView else { return }
        textView.perform(NSSelectorFromString(name), with: sender)
    }

    override func refresh(editor: PageEditor?, state: EditorState) {
        tracking.isEnabled = editor != nil
        guard let editor else { return }
        tracking.state = editor.document.trackRevisions ? .on : .off
        let selected = Set(state.selectedCommentIDs)
        let all = editor.document.comments
        empty.isHidden = !all.isEmpty
        comments.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for comment in all {
            let card = CommentCard(
                comment: comment, quote: comment.parentParaID == nil ? editor.commentQuote(comment.id) : nil,
                isReply: comment.parentParaID != nil, isSelected: selected.contains(comment.id)
            )
            card.onSelect = { [weak editor] in editor?.selectComment(comment.id) }
            card.onResolve = { [weak editor] in editor?.setCommentDone(comment.id, !comment.isDone) }
            card.onDelete = { [weak editor] in editor?.deleteComment(comment.id) }
            card.onReply = { [weak self, weak editor] in
                self?.inspector?.windowController?.promptForComment(title: String(localized: "Comments.Reply")) { text in
                    editor?.reply(to: comment.id, text: text)
                }
            }
            card.onEdit = { [weak self, weak editor] in
                self?.inspector?.windowController?.promptForComment(
                    title: String(localized: "Comments.Edit"), initial: comment.text
                ) { text in editor?.editComment(comment.id, text: text) }
            }
            comments.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: comments.widthAnchor).isActive = true
        }
        comments.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @objc private func trackingToggled() {
        editor?.setTracking(tracking.state == .on)
    }

    @objc private func authorChanged() {
        let name = author.stringValue.trimmed
        UserDefaults.standard.set(name.isEmpty ? nil : name, forKey: Reviewer.nameKey)
    }
}

/// A comment: who wrote it and when, what it says, and the text it is on.
private final class CommentCard: NSView {
    var onSelect: (() -> Void)?
    var onResolve: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReply: (() -> Void)?
    var onEdit: (() -> Void)?
    private let isSelected: Bool

    init(comment: Comment, quote: String?, isReply: Bool, isSelected: Bool) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        let author = NSTextField(labelWithString: comment.author)
        author.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let date = NSTextField(labelWithString: Self.date(comment.date))
        date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        date.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [author, date])
        let text = NSTextField(wrappingLabelWithString: comment.text)
        text.textColor = comment.isDone ? .secondaryLabelColor : .labelColor
        var views: [NSView] = [heading]
        if let quote, !quote.isEmpty {
            let quoted = NSTextField(wrappingLabelWithString: "“" + quote + "”")
            quoted.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            quoted.textColor = .secondaryLabelColor
            quoted.maximumNumberOfLines = 2
            views.append(quoted)
        }
        views.append(text)
        let actions = NSStackView(views: [
            Self.link(String(localized: comment.isDone ? "Comments.Reopen" : "Comments.Resolve"), self, #selector(resolve)),
            Self.link(String(localized: "Comments.Reply"), self, #selector(reply)),
            Self.link(String(localized: "Comments.Edit"), self, #selector(edit)),
            Self.link(String(localized: "Comments.Delete"), self, #selector(delete)),
        ])
        actions.spacing = 10
        if !isReply { views.append(actions) } else { actions.arrangedSubviews[0].isHidden = true; views.append(actions) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: isReply ? 20 : 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(comment.author + ": " + comment.text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = (isSelected ? NSColor.systemYellow.withAlphaComponent(0.22) : NSColor.quaternaryLabelColor).cgColor
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    private static func link(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private static func date(_ text: String?) -> String {
        guard let text, let date = ISO8601DateFormatter().date(from: text) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @objc private func resolve() { onResolve?() }
    @objc private func reply() { onReply?() }
    @objc private func edit() { onEdit?() }
    @objc private func delete() { onDelete?() }
}

extension NSColor {
    /// A colour from six-digit RGB, as OOXML writes one.
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).suffix(6)
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }
}
