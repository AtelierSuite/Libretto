import AppKit
import LibrettoEngine

/// What kind of change an edit was, so a run of the same kind undoes as one.
enum EditScope: Equatable {
    case typing
    case formatting
    case paragraphStyle
    case list
    case insertion
    case table
    case pageSetup
    case comment
    case review
    case other

    /// Typing, and editing a table's text, arrive a keystroke at a time.
    var coalesces: Bool { self == .typing || self == .table }

    var actionName: String {
        switch self {
        case .typing: return String(localized: "Undo.Typing")
        case .formatting: return String(localized: "Undo.Formatting")
        case .paragraphStyle: return String(localized: "Undo.ParagraphStyle")
        case .list: return String(localized: "Undo.List")
        case .insertion: return String(localized: "Undo.Insertion")
        case .table: return String(localized: "Undo.Table")
        case .pageSetup: return String(localized: "Undo.PageSetup")
        case .comment: return String(localized: "Undo.Comment")
        case .review: return String(localized: "Undo.Review")
        case .other: return String(localized: "Undo.Edit")
        }
    }
}

/// How the text at the selection is formatted, for the inspector and menus to show.
struct SelectionFormat: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruckThrough = false
    var verticalAlignment: RunStyle.VerticalPosition = .baseline
    /// Half-points.
    var fontSize = 22
    /// The font the text resolves to, a theme font as `+minor` or `+major`.
    var fontName: String?
    var colorHex: String?
    var highlight: String?
    var alignment: ParagraphAlignment = .leading
    var styleID: String?
    var listKind: ListKind?
    /// Twentieths of a point.
    var spacingBefore = 0
    var spacingAfter = 0
    var lineSpacing: Double = 1
}

/// Everything about an editing session that is not part of the document,
/// which the inspector, toolbar and menus follow.
@MainActor
final class EditorState {
    static let didChange = Notification.Name("LibrettoEditorStateDidChange")

    var selectionFormat = SelectionFormat() { didSet { changed(oldValue != selectionFormat) } }
    /// The table the selection is on, if any, which the table inspector edits.
    var selectedTableID: Table.ID? { didSet { changed(oldValue != selectedTableID) } }
    var isOnLink = false { didSet { changed(oldValue != isOnLink) } }
    var isOnImage = false { didSet { changed(oldValue != isOnImage) } }
    /// Whether the selection is on a tracked change, and whether changes are being tracked.
    var isOnChange = false { didSet { changed(oldValue != isOnChange) } }
    var isTracking = false { didSet { changed(oldValue != isTracking) } }
    /// The comments on the text at the selection.
    var selectedCommentIDs: [String] = [] { didSet { changed(oldValue != selectedCommentIDs) } }
    /// What the last change was, read by the history when it records it.
    var pendingScope: EditScope = .other

    private var isPosting = false

    private func changed(_ isChanged: Bool) {
        guard isChanged, !isPosting else { return }
        // Several changes at once are told of once, on the next turn of the run loop.
        isPosting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isPosting = false
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
