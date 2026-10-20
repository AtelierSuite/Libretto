import AppKit
import LibrettoEngine

/// The paragraph styles to choose from: the usual ones, and the document's own.
@MainActor
enum StyleMenu {
    /// A menu that fills itself with the styles of the document being edited each time it opens.
    static func make(for editor: @escaping () -> PageEditor?) -> NSMenu {
        let menu = NSMenu()
        let filler = Filler(editor: editor)
        menu.delegate = filler
        objc_setAssociatedObject(menu, &Filler.key, filler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }

    /// Fills `menu` with the styles: each item's represented object a built-in choice's raw value, or a style's ID.
    static func fill(_ menu: NSMenu, for editor: PageEditor?, checking: Bool = true) {
        menu.removeAllItems()
        let styles = editor?.document.styles
        var shown: Set<String> = []
        for choice in ParagraphStyleChoice.allCases {
            let item = NSMenuItem(title: choice.label, action: #selector(DocumentTextView.applyParagraphStyle(_:)), keyEquivalent: "")
            item.representedObject = choice.rawValue
            menu.addItem(item)
            if let id = styles?.styleID(for: choice) { shown.insert(id) }
        }
        guard let editor, let styles else { return }
        let used = Set(editor.document.allParagraphs.compactMap(\.properties.styleID))
        let others = styles.offeredParagraphStyles(using: used).filter { !shown.contains($0.id) }
        guard !others.isEmpty else { return }
        menu.addItem(.separator())
        for style in others.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let item = NSMenuItem(title: style.name, action: #selector(DocumentTextView.applyParagraphStyle(_:)), keyEquivalent: "")
            item.representedObject = style.id
            menu.addItem(item)
        }
    }

    private final class Filler: NSObject, NSMenuDelegate {
        nonisolated(unsafe) static var key = 0
        let editor: () -> PageEditor?

        init(editor: @escaping () -> PageEditor?) {
            self.editor = editor
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            MainActor.assumeIsolated { StyleMenu.fill(menu, for: editor()) }
        }
    }
}
