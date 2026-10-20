import AppKit

/// The app: documents open in windows of their own, through `Document`.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.make()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ScreenshotMode.start()
        #endif
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    /// Launched, or brought back from the Dock, with nothing open: ask for a document
    /// to open rather than starting a blank one, as Pages and TextEdit do.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func openSourceCode(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/AtelierSuite/Libretto")!)
    }
}
