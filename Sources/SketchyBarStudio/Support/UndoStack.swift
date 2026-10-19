import Foundation

/// One undoable change.
///
/// The closures apply the change in one direction and report whether they
/// could be applied. A change that is refused stays on the stack, so the
/// user can try again after the reason is gone.
struct UndoAction {
    let id: UUID
    /// The name of the change, shown in the Undo and Redo menu items.
    let title: String
    /// Changes that share a key and arrive in one run become a single undo
    /// step, so holding a key down does not fill the stack.
    let coalescingKey: String?
    let undo: () -> Bool
    let redo: () -> Bool

    init(
        id: UUID = UUID(),
        title: String,
        coalescingKey: String? = nil,
        undo: @escaping () -> Bool,
        redo: @escaping () -> Bool
    ) {
        self.id = id
        self.title = title
        self.coalescingKey = coalescingKey
        self.undo = undo
        self.redo = redo
    }
}

/// A bounded undo and redo stack for the edits of the store.
///
/// The stack keeps the newest actions and drops the oldest one when the
/// limit is reached. Two actions with the same coalescing key that arrive
/// inside the coalescing window are merged into one step: the step undoes
/// back to the state before the first change of the run and redoes the
/// state of the last change.
@MainActor
struct UndoStack {
    struct Entry {
        let action: UndoAction
        let registeredAt: Date
    }

    /// The most actions the stack keeps.
    let limit: Int
    /// The window in which two changes with the same key are merged.
    let coalescingInterval: TimeInterval

    private let now: () -> Date
    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    init(limit: Int = 100, coalescingInterval: TimeInterval = 1, now: @escaping () -> Date = { Date() }) {
        self.limit = limit
        self.coalescingInterval = coalescingInterval
        self.now = now
    }

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoTitle: String? { undoEntries.last?.action.title }
    var redoTitle: String? { redoEntries.last?.action.title }

    /// Adds an action. A new action clears the redo stack.
    mutating func register(_ action: UndoAction) {
        let date = now()
        if let top = undoEntries.last,
           let key = action.coalescingKey,
           top.action.coalescingKey == key,
           date.timeIntervalSince(top.registeredAt) <= coalescingInterval {
            // The merged step keeps the undo of the first change of the run
            // and the redo of the last one.
            undoEntries[undoEntries.count - 1] = Entry(
                action: UndoAction(
                    id: top.action.id,
                    title: action.title,
                    coalescingKey: key,
                    undo: top.action.undo,
                    redo: action.redo
                ),
                registeredAt: date
            )
            redoEntries.removeAll()
            return
        }

        undoEntries.append(Entry(action: action, registeredAt: date))
        if undoEntries.count > limit {
            undoEntries.removeFirst(undoEntries.count - limit)
        }
        redoEntries.removeAll()
    }

    /// Applies the newest action in reverse. Returns false when the action
    /// refused to apply, so it stays on the stack.
    @discardableResult
    mutating func undo() -> Bool {
        guard let entry = undoEntries.popLast() else { return false }
        guard entry.action.undo() else {
            undoEntries.append(entry)
            return false
        }
        redoEntries.append(entry)
        return true
    }

    /// Applies the newest undone action again. Returns false when the
    /// action refused to apply, so it stays on the redo stack.
    @discardableResult
    mutating func redo() -> Bool {
        guard let entry = redoEntries.popLast() else { return false }
        guard entry.action.redo() else {
            redoEntries.append(entry)
            return false
        }
        undoEntries.append(entry)
        return true
    }

    mutating func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}
