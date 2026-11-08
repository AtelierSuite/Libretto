import Foundation
import LibrettoEngine

/// Undo and redo for a document, through its undo manager.
///
/// Every change, however it was made, passes through `record(from:to:scope:)`,
/// which registers the document as it was. Snapshots rather than inverse
/// operations: the document is a value with copy-on-write storage, so a
/// snapshot shares everything the change left alone, and no edit can forget
/// to be undoable.
@MainActor
final class DocumentHistory {
    /// How long a pause ends a run of changes that would otherwise be one step.
    static let coalescingInterval: TimeInterval = 1
    /// A step keeps its own copy of every block the change touched, so on a
    /// long document an unbounded history is an unbounded amount of memory.
    static let levels = 100

    private weak var undoManager: UndoManager?
    private var read: () -> WordDocument = { WordDocument() }
    private var write: (WordDocument) -> Void = { _ in /* Replaced on attach. */ }
    private var lastScope: EditScope?
    private var lastChange = Date.distantPast

    func attach(
        to undoManager: UndoManager?, read: @escaping () -> WordDocument, write: @escaping (WordDocument) -> Void
    ) {
        self.undoManager = undoManager
        self.read = read
        self.write = write
        undoManager?.levelsOfUndo = Self.levels
    }

    /// Notes a change the user made. Returns whether it was a step of its
    /// own, rather than part of the run before it.
    @discardableResult
    func record(from old: WordDocument, to new: WordDocument, scope: EditScope, canCoalesce: Bool) -> Bool {
        guard let undoManager, old != new else { return false }
        let now = Date()
        defer {
            lastScope = scope
            lastChange = now
        }
        // A run of the same kind of change is one step: the step already on
        // the stack holds the document from before the run began.
        if canCoalesce, scope.coalesces, scope == lastScope, undoManager.canUndo,
           now.timeIntervalSince(lastChange) < Self.coalescingInterval {
            return false
        }
        register(restoring: old, named: scope.actionName, with: undoManager)
        return true
    }

    /// Registers putting `target` back. Run from inside an undo, the inverse
    /// it registers lands on the redo stack, and the other way round.
    private func register(restoring target: WordDocument, named name: String, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                let current = history.read()
                history.register(restoring: current, named: name, with: undoManager)
                // An edit straight after an undo starts a step of its own.
                history.lastScope = nil
                history.write(target)
            }
        }
        undoManager.setActionName(name)
    }
}
