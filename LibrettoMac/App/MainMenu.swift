import AppKit

/// The menu bar, built in code, every title from the string catalog.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(insertMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(reviewMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Mac.Menu.Help"))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ key: String.LocalizationValue, _ action: Selector?, _ shortcut: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: key), action: action, keyEquivalent: shortcut)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func menu(_ key: String.LocalizationValue, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: String(localized: key))
        items.forEach(menu.addItem)
        return menu
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let services = NSMenu()
        NSApp.servicesMenu = services
        let servicesItem = item("Mac.Menu.Services", nil)
        servicesItem.submenu = services
        return menu("Mac.Menu.App", [
            NSMenuItem(title: String(format: String(localized: "Mac.Menu.About"), name),
                       action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            item("Mac.Menu.SourceCode", #selector(AppDelegate.openSourceCode(_:))),
            .separator(),
            servicesItem,
            .separator(),
            NSMenuItem(title: String(format: String(localized: "Mac.Menu.Hide"), name),
                       action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item("Mac.Menu.HideOthers", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Mac.Menu.ShowAll", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            NSMenuItem(title: String(format: String(localized: "Mac.Menu.Quit"), name),
                       action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
    }

    private static func fileMenu() -> NSMenu {
        let recent = item("Mac.Menu.OpenRecent", nil)
        let recentMenu = NSMenu(title: recent.title)
        recentMenu.addItem(item("Mac.Menu.ClearRecent", #selector(NSDocumentController.clearRecentDocuments(_:))))
        // The document controller fills in the recent documents above the item with this action.
        recent.submenu = recentMenu
        return menu("Mac.Menu.File", [
            item("Mac.Menu.New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Mac.Menu.Open", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent,
            .separator(),
            item("Mac.Menu.Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Mac.Menu.Save", #selector(NSDocument.save(_:)), "s"),
            item("Mac.Menu.Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Mac.Menu.Rename", #selector(NSDocument.rename(_:))),
            item("Mac.Menu.MoveTo", #selector(NSDocument.move(_:))),
            item("Mac.Menu.Revert", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Mac.Menu.SaveAsWord", #selector(Document.saveAsWordDocument(_:))),
            item("Mac.Menu.ExportPDF", #selector(Document.exportPDF(_:))),
            .separator(),
            item("Mac.Menu.PageSetup", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Mac.Menu.Print", #selector(NSDocument.printDocument(_:)), "p"),
        ])
    }

    private static func editMenu() -> NSMenu {
        let find = menu("Mac.Menu.Find", [
            findItem("Mac.Menu.Find.Find", .showFindInterface, "f"),
            findItem("Mac.Menu.Find.FindReplace", .showReplaceInterface, "f", [.command, .option]),
            findItem("Mac.Menu.Find.Next", .nextMatch, "g"),
            findItem("Mac.Menu.Find.Previous", .previousMatch, "g", [.command, .shift]),
            findItem("Mac.Menu.Find.UseSelection", .setSearchString, "e"),
            item("Mac.Menu.Find.JumpToSelection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"),
        ])
        let spelling = menu("Mac.Menu.Spelling", [
            item("Mac.Menu.Spelling.Show", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Mac.Menu.Spelling.Check", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Mac.Menu.Spelling.WhileTyping", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Mac.Menu.Spelling.Grammar", #selector(NSTextView.toggleGrammarChecking(_:))),
            item("Mac.Menu.Spelling.Correct", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
        ])
        let substitutions = menu("Mac.Menu.Substitutions", [
            item("Mac.Menu.Substitutions.Show", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            .separator(),
            item("Mac.Menu.Substitutions.Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            item("Mac.Menu.Substitutions.Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            item("Mac.Menu.Substitutions.Text", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ])
        return menu("Mac.Menu.Edit", [
            item("Toolbar.Undo", Selector(("undo:")), "z"),
            item("Toolbar.Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Toolbar.Cut", #selector(NSText.cut(_:)), "x"),
            item("Toolbar.Copy", #selector(NSText.copy(_:)), "c"),
            item("Toolbar.Paste", #selector(NSText.paste(_:)), "v"),
            item("Mac.Menu.Delete", #selector(NSText.delete(_:))),
            item("Mac.Menu.SelectAll", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            with(find), with(spelling), with(substitutions),
        ])
    }

    private static func findItem(
        _ key: String.LocalizationValue, _ action: NSTextFinder.Action, _ shortcut: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = item(key, #selector(NSTextView.performFindPanelAction(_:)), shortcut, modifiers)
        item.tag = action.rawValue
        return item
    }

    private static func with(_ menu: NSMenu) -> NSMenuItem {
        submenu(menu)
    }

    static func insertMenu() -> NSMenu {
        menu("ActionBar.Insert", [
            item("Insert.Table", #selector(DocumentWindowController.insertTable(_:))),
            item("Insert.Picture", #selector(DocumentWindowController.insertPicture(_:))),
            item("Mac.Menu.InsertLink", #selector(DocumentWindowController.editLink(_:)), "k"),
            item("Insert.PageBreak", #selector(DocumentTextView.insertPageBreak(_:)), "\r", .command),
            .separator(),
            item("Comments.Add", #selector(DocumentWindowController.addComment(_:)), "m", [.command, .option]),
        ])
    }

    private static func formatMenu() -> NSMenu {
        let baseline = menu("Mac.Menu.Baseline", [
            item("Format.Superscript", #selector(NSTextView.superscript(_:)), "=", [.command, .control]),
            item("Format.Subscript", #selector(NSTextView.subscript(_:)), "-", [.command, .control]),
            item("Mac.Menu.Baseline.Default", #selector(NSTextView.unscript(_:))),
        ])
        let font = menu("Mac.Menu.Font", [
            item("Mac.Menu.ShowFonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t"),
            item("Toolbar.Bold", #selector(DocumentTextView.toggleBold(_:)), "b"),
            item("Toolbar.Italic", #selector(DocumentTextView.toggleItalic(_:)), "i"),
            item("Toolbar.Underline", #selector(NSText.underline(_:)), "u"),
            item("Toolbar.Strikethrough", #selector(DocumentTextView.toggleStrikethrough(_:)), "x", [.command, .shift]),
            .separator(),
            item("Format.Text.Size.Increase", #selector(DocumentTextView.makeTextBigger(_:)), "+"),
            item("Format.Text.Size.Decrease", #selector(DocumentTextView.makeTextSmaller(_:)), "-"),
            .separator(),
            with(baseline),
            .separator(),
            item("Mac.Menu.ShowColours", #selector(NSApplication.orderFrontColorPanel(_:)), "C", [.command, .shift]),
        ])
        let text = menu("Mac.Menu.Text", [
            item("Mac.Menu.AlignLeft", #selector(NSText.alignLeft(_:)), "{"),
            item("Mac.Menu.AlignCenter", #selector(NSText.alignCenter(_:)), "|"),
            item("Mac.Menu.AlignJustified", #selector(NSTextView.alignJustified(_:))),
            item("Mac.Menu.AlignRight", #selector(NSText.alignRight(_:)), "}"),
        ])
        let lists = menu("Mac.Toolbar.Lists", [
            item("ActionBar.Bullets", #selector(DocumentTextView.toggleBulletedList(_:)), "l", [.command, .shift]),
            item("ActionBar.Numbering", #selector(DocumentTextView.toggleNumberedList(_:)), "l", [.command, .option]),
            .separator(),
            item("Mac.Menu.IncreaseIndent", #selector(DocumentTextView.increaseIndent(_:)), "]"),
            item("Mac.Menu.DecreaseIndent", #selector(DocumentTextView.decreaseIndent(_:)), "["),
        ])
        let style = StyleMenu.make { (NSApp.keyWindow?.windowController as? DocumentWindowController)?.editor }
        style.title = String(localized: "ActionBar.Style")
        return menu("ActionBar.Format", [
            with(font), with(text), with(lists), with(style),
            .separator(),
            item("Format.ClearAll", #selector(DocumentTextView.clearFormatting(_:))),
        ])
    }

    private static func reviewMenu() -> NSMenu {
        menu("Panel.Review.Title", [
            item("Review.TrackChanges", #selector(DocumentTextView.toggleTrackChanges(_:)), "e", [.command, .shift]),
            .separator(),
            item("Review.Accept", #selector(DocumentTextView.acceptChange(_:))),
            item("Review.Reject", #selector(DocumentTextView.rejectChange(_:))),
            item("Review.Next", #selector(DocumentTextView.selectNextChange(_:))),
            item("Review.Previous", #selector(DocumentTextView.selectPreviousChange(_:))),
            .separator(),
            item("Review.AcceptAll", #selector(DocumentTextView.acceptAllChanges(_:))),
            item("Review.RejectAll", #selector(DocumentTextView.rejectAllChanges(_:))),
            .separator(),
            item("Link.Remove", #selector(DocumentTextView.removeLink(_:))),
            item("Toolbar.UnsupportedFeatures.Label", #selector(DocumentWindowController.showUnsupportedFeatures(_:))),
        ])
    }

    private static func viewMenu() -> NSMenu {
        menu("Mac.Menu.View", [
            item("Mac.Menu.ShowToolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Mac.Menu.CustomizeToolbar", #selector(NSWindow.runToolbarCustomizationPalette(_:))),
            item("Mac.Menu.ShowInspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
            item("Mac.Menu.ActualSize", #selector(DocumentWindowController.actualSize(_:)), "0"),
            item("Mac.Menu.ZoomIn", #selector(DocumentWindowController.zoomIn(_:)), ">"),
            item("Mac.Menu.ZoomOut", #selector(DocumentWindowController.zoomOut(_:)), "<"),
            .separator(),
            item("Mac.Menu.FullScreen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
    }

    private static func windowMenu() -> NSMenu {
        menu("Mac.Menu.Window", [
            item("Mac.Menu.Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Mac.Menu.Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Mac.Menu.BringAllToFront", #selector(NSApplication.arrangeInFront(_:))),
        ])
    }
}
