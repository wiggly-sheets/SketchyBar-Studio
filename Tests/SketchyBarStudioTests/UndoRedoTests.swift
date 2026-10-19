import Foundation
@testable import SketchyBarStudio
import XCTest

/// A clock the test controls, so the coalescing window is deterministic.
final class TestClock {
    var date = Date()

    func now() -> Date { date }

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

@MainActor
final class UndoRedoTests: XCTestCase {
    // MARK: - The stack

    func testUndoAndRedoBringTheStateBack() {
        var stack = UndoStack()
        var value = "one"
        stack.register(UndoAction(
            title: "Change value",
            undo: { value = "one"; return true },
            redo: { value = "two"; return true }
        ))
        value = "two"

        XCTAssertTrue(stack.canUndo)
        XCTAssertTrue(stack.undo())
        XCTAssertEqual(value, "one")
        XCTAssertTrue(stack.canRedo)
        XCTAssertTrue(stack.redo())
        XCTAssertEqual(value, "two")
    }

    func testANewActionClearsTheRedoStack() {
        var stack = UndoStack()
        stack.register(UndoAction(title: "First", undo: { true }, redo: { true }))
        XCTAssertTrue(stack.undo())
        XCTAssertTrue(stack.canRedo)

        stack.register(UndoAction(title: "Second", undo: { true }, redo: { true }))

        XCTAssertFalse(stack.canRedo)
    }

    func testTheStackDropsTheOldestActionWhenTheLimitIsReached() {
        var stack = UndoStack(limit: 2)
        for index in 0..<3 {
            stack.register(UndoAction(title: "Change \(index)", undo: { true }, redo: { true }))
        }

        XCTAssertEqual(stack.undoEntries.count, 2)
        XCTAssertEqual(stack.undoEntries.first?.action.title, "Change 1")
    }

    func testTwoChangesWithTheSameKeyBecomeOneUndoStep() {
        let clock = TestClock()
        var stack = UndoStack(now: clock.now)
        var value = "one"
        stack.register(UndoAction(
            title: "Change value",
            coalescingKey: "value:1",
            undo: { value = "one"; return true },
            redo: { value = "two"; return true }
        ))
        value = "two"
        stack.register(UndoAction(
            title: "Change value",
            coalescingKey: "value:1",
            undo: { value = "two"; return true },
            redo: { value = "three"; return true }
        ))
        value = "three"

        XCTAssertEqual(stack.undoEntries.count, 1)
        // The merged step undoes to the state before the first change and
        // redoes the state of the last change.
        XCTAssertTrue(stack.undo())
        XCTAssertEqual(value, "one")
        XCTAssertTrue(stack.redo())
        XCTAssertEqual(value, "three")
    }

    func testTwoChangesWithDifferentKeysStaySeparate() {
        var stack = UndoStack()
        stack.register(UndoAction(title: "First", coalescingKey: "value:1", undo: { true }, redo: { true }))
        stack.register(UndoAction(title: "Second", coalescingKey: "value:2", undo: { true }, redo: { true }))

        XCTAssertEqual(stack.undoEntries.count, 2)
    }

    func testChangesOutsideTheCoalescingWindowStaySeparate() {
        let clock = TestClock()
        var stack = UndoStack(now: clock.now)
        stack.register(UndoAction(title: "First", coalescingKey: "value:1", undo: { true }, redo: { true }))
        clock.advance(2)
        stack.register(UndoAction(title: "Second", coalescingKey: "value:1", undo: { true }, redo: { true }))

        XCTAssertEqual(stack.undoEntries.count, 2)
    }

    func testARefusedChangeStaysOnTheStack() {
        var stack = UndoStack()
        stack.register(UndoAction(title: "Refused", undo: { false }, redo: { true }))

        XCTAssertFalse(stack.undo())
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }

    // MARK: - The store

    func testAFreshStoreCannotUndo() throws {
        let root = try makeConfigRoot()
        try write("width = 10\n", to: root.appendingPathComponent("items/first.lua"))

        let store = SketchyBarStore(configRoot: root)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
        XCTAssertNil(store.undoTitle)
        XCTAssertNil(store.redoTitle)
    }

    func testChangingAValueAndUndoingRestoresThePreviousDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        XCTAssertEqual(draft(of: value.id, in: store), "20")
        XCTAssertTrue(store.canUndo)

        store.undo()

        XCTAssertEqual(draft(of: value.id, in: store), "10")
        XCTAssertFalse(store.canUndo)
    }

    func testRedoAppliesTheChangeAgain() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        store.undo()
        XCTAssertEqual(draft(of: value.id, in: store), "10")

        store.redo()

        XCTAssertEqual(draft(of: value.id, in: store), "20")
        XCTAssertTrue(store.canUndo)
    }

    func testChangingAValueTwiceUndoesOneStepAtATime() throws {
        let clock = TestClock()
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root, undoStack: UndoStack(now: clock.now))
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        clock.advance(2)
        store.update(valueID: value.id, draftValue: "30")

        store.undo()
        XCTAssertEqual(draft(of: value.id, in: store), "20")

        store.undo()
        XCTAssertEqual(draft(of: value.id, in: store), "10")
        XCTAssertFalse(store.canUndo)
    }

    func testTwoEditsOfTheSameValueInOneRunAreOneUndoStep() throws {
        let clock = TestClock()
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root, undoStack: UndoStack(now: clock.now))
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        store.update(valueID: value.id, draftValue: "30")

        store.undo()

        XCTAssertEqual(draft(of: value.id, in: store), "10")
        XCTAssertFalse(store.canUndo)
    }

    func testTheSourceEditCanBeUndone() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)

        store.updateSourceContents("width = 11\n", for: file)
        XCTAssertEqual(store.sourceContents(for: file), "width = 11\n")

        store.undo()

        XCTAssertEqual(store.sourceContents(for: file), "width = 10\n")
        XCTAssertFalse(store.sourceHasUnsavedChanges(for: file))
    }

    func testTheRevertedSourceCanBeUndone() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)

        store.discardSourceChanges(for: file)
        XCTAssertEqual(store.sourceContents(for: file), "width = 10\n")

        store.undo()

        XCTAssertEqual(store.sourceContents(for: file), "width = 11\n")
        XCTAssertTrue(store.sourceHasUnsavedChanges(for: file))
    }

    func testTheDiscardCanBeUndone() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)
        store.update(valueID: value.id, draftValue: "20")
        store.selectedFileID = file.id

        store.discardSelectedChanges()
        XCTAssertEqual(draft(of: value.id, in: store), "10")

        store.undo()

        XCTAssertEqual(draft(of: value.id, in: store), "20")
    }

    func testTheDiscardCanBeUndoneWithItsStagedLoaderOrder() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("require(\"items.first\")\nrequire(\"items.second\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })
        store.moveItem(fileID: second.id, before: first.id)
        store.selectedFileID = second.id

        store.discardSelectedChanges()
        XCTAssertEqual(previewOrder(of: store), ["items/first.lua", "items/second.lua"])

        store.undo()

        XCTAssertEqual(previewOrder(of: store), ["items/second.lua", "items/first.lua"])
    }

    func testTheLoaderReorderCanBeUndone() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("require(\"items.first\")\nrequire(\"items.second\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })

        store.moveItem(fileID: second.id, before: first.id)
        XCTAssertEqual(previewOrder(of: store), ["items/second.lua", "items/first.lua"])

        store.undo()

        XCTAssertEqual(previewOrder(of: store), ["items/first.lua", "items/second.lua"])
    }

    func testTheActivationToggleCanBeUndone() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: fileURL)
        try write("require(\"items.first\")\n", to: loaderURL)
        let original = try Data(contentsOf: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })

        store.setActive(false, fileID: file.id)
        XCTAssertNotEqual(try Data(contentsOf: loaderURL), original)

        store.undo()

        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
    }

    func testUndoDoesNotOverwriteALoaderFileThatChangedOnDisk() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: fileURL)
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.setActive(false, fileID: file.id)

        // Another program writes the loader file.
        try write("require(\"items.first\")\nrequire(\"items.other\")\n", to: loaderURL)

        store.undo()

        XCTAssertEqual(
            try String(contentsOf: loaderURL, encoding: .utf8),
            "require(\"items.first\")\nrequire(\"items.other\")\n"
        )
        XCTAssertTrue(store.statusMessage.contains("Undo failed"))
        // The step stays on the stack, so the user can try again later.
        XCTAssertTrue(store.canUndo)
    }

    // MARK: - Helpers

    private func draft(of valueID: LuaEditableValue.ID, in store: SketchyBarStore) -> String? {
        store.files.first { $0.values.contains { $0.id == valueID } }?.values.first { $0.id == valueID }?.draftValue
    }

    private func previewOrder(of store: SketchyBarStore) -> [String] {
        store.filesInPreviewOrder
            .filter { $0.displayName.hasPrefix("items/") }
            .map(\.displayName)
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioUndoTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
