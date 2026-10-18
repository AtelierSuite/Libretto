#if DEBUG
import AppKit
import LibrettoEngine

/// Takes an App Store screenshot of the document the app was opened with, then quits.
/// Debug builds only, for `Assets/App Store/capture.sh`:
///
///     Libretto <document> -LibrettoScreenshot <png> [-LibrettoScreenshotTab review]
///
/// The window draws itself into the picture, at the screen's scale, so nothing
/// needs permission to record the screen.
@MainActor
enum ScreenshotMode {
    static var output: String? { UserDefaults.standard.string(forKey: "LibrettoScreenshot") }

    /// The window's size in the screenshots: the page and the inspector side by side, with room for the toolbar.
    static let windowSize = NSSize(width: 1440, height: 900)

    static func start() {
        guard let output else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        // Give the document time to open and lay out before arranging it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            arrange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                captureWhenKey(to: output, attempts: 20)
            }
        }
    }

    private static var controller: DocumentWindowController? {
        NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.first
    }

    private static func arrange() {
        guard let controller, let window = controller.window else { return }
        // Launched from a script, the app starts behind the terminal; bring it forward
        // so the window draws as the key window, with its traffic lights and toolbar in colour.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(windowSize)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
        }
        guard let editor = controller.editor else { return }
        if UserDefaults.standard.string(forKey: "LibrettoScreenshotTab") == "review",
           let inspector = (window.contentViewController as? NSSplitViewController)?
            .splitViewItems.last?.viewController as? InspectorViewController {
            // The first comment's text selected, so its card stands out beside it.
            if let comment = editor.document.comments.first { editor.selectComment(comment.id) }
            inspector.showReview()
        } else {
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.canvas.enclosingScrollView?.contentView.scroll(to: .zero)
    }

    /// Activation can lose out to whatever else is frontmost, so ask again until the
    /// window is key. If it never is, quit without a picture so the script can try again.
    private static func captureWhenKey(to path: String, attempts: Int) {
        guard let window = controller?.window else { return }
        guard NSApp.isActive && window.isKeyWindow else {
            guard attempts > 0 else { exit(1) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureWhenKey(to: path, attempts: attempts - 1)
            }
            return
        }
        // One more beat so the window redraws in its key state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard NSApp.isActive && window.isKeyWindow else {
                captureWhenKey(to: path, attempts: attempts - 1)
                return
            }
            capture(to: path)
            NSApp.terminate(nil)
        }
    }

    private static func capture(to path: String) {
        guard let window = controller?.window, let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
