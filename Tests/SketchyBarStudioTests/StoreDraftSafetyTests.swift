import Foundation
@testable import SketchyBarStudio
import XCTest

/// Counts the change notifications of the store.
final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@MainActor
final class StoreDraftSafetyTests: XCTestCase {
    func testSavingOneFilePreservesAnotherFilesDraft() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        let store = SketchyBarStore(configRoot: root)

        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })
        store.update(valueID: try XCTUnwrap(first.values.first).id, draftValue: "11")
        store.update(valueID: try XCTUnwrap(second.values.first).id, draftValue: "21")
        store.selectedFileID = first.id

        XCTAssertTrue(store.saveSelectedFile())

        let preserved = try XCTUnwrap(store.files.first { $0.id == second.id }?.values.first)
        XCTAssertEqual(preserved.originalValue, "20")
        XCTAssertEqual(preserved.draftValue, "21")
    }

    func testSourceDraftSurvivesSelectionAndReload() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })

        store.prepareSourceEditing(for: first)
        store.updateSourceContents("width = 11\n", for: first)
        store.selectedFileID = second.id
        store.reload()

        let reloadedFirst = try XCTUnwrap(store.files.first { $0.id == first.id })
        XCTAssertEqual(store.sourceContents(for: reloadedFirst), "width = 11\n")
        XCTAssertTrue(store.sourceHasUnsavedChanges(for: reloadedFirst))
    }

    func testFailedSourceSaveKeepsDraftUnsaved() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)
        try FileManager.default.removeItem(at: fileURL)

        XCTAssertFalse(store.saveRawContents(for: file))
        XCTAssertTrue(store.sourceHasUnsavedChanges(for: file))
        XCTAssertEqual(store.sourceContents(for: file), "width = 11\n")
        XCTAssertTrue(store.statusMessage.contains("Source save failed"))
    }

    func testSourceSaveRejectsAnExternalEditWithoutLosingEitherVersion() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)
        try write("width = 12\n", to: fileURL)

        XCTAssertFalse(store.saveRawContents(for: file))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 12\n")
        XCTAssertEqual(store.sourceContents(for: file), "width = 11\n")
        XCTAssertTrue(store.sourceHasUnsavedChanges(for: file))
        XCTAssertTrue(store.statusMessage.contains("changed on disk"))
    }

    func testControlEditIsRejectedWhileTheSameFileHasASourceDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)

        store.update(valueID: value.id, draftValue: "12")

        XCTAssertEqual(store.files.first { $0.id == file.id }?.values.first?.draftValue, "10")
        XCTAssertTrue(store.statusMessage.contains("source draft"))
    }

    func testSourceOnlySupportedFileRemainsVisible() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("scripts/event.sh")
        try write("#!/bin/sh\nsketchybar --trigger studio_test\n", to: fileURL)

        let store = SketchyBarStore(configRoot: root)

        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        XCTAssertTrue(file.values.isEmpty)
    }

    func testLoaderReorderIsStagedUntilSelectedFileIsSaved() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("require(\"items.first\")\n-- setup stays here\nrequire(\"items.second\")\n", to: loaderURL)
        let originalLoader = try String(contentsOf: loaderURL, encoding: .utf8)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })

        store.moveItem(fileID: second.id, before: first.id)

        XCTAssertEqual(try String(contentsOf: loaderURL, encoding: .utf8), originalLoader)
        XCTAssertEqual(store.unsavedFileCount, 2)

        store.selectedFileID = second.id
        XCTAssertTrue(store.saveSelectedFile())
        XCTAssertEqual(
            try String(contentsOf: loaderURL, encoding: .utf8),
            "require(\"items.second\")\n-- setup stays here\nrequire(\"items.first\")\n"
        )
    }

    func testFilesInPreviewOrderReflectsStagedLoaderReorder() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("require(\"items.first\")\n-- setup stays here\nrequire(\"items.second\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })

        store.moveItem(fileID: second.id, before: first.id)

        let previewOrder = store.filesInPreviewOrder
            .filter { $0.displayName.hasPrefix("items/") }
            .map(\.displayName)
        XCTAssertEqual(previewOrder, ["items/second.lua", "items/first.lua"])
    }

    func testDiscardSelectedChangesDoesNotDiscardAnotherFilesDraft() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        let store = SketchyBarStore(configRoot: root)

        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })
        store.update(valueID: try XCTUnwrap(first.values.first).id, draftValue: "11")
        store.update(valueID: try XCTUnwrap(second.values.first).id, draftValue: "21")
        store.selectedFileID = first.id

        store.discardSelectedChanges()

        let discarded = try XCTUnwrap(store.files.first { $0.id == first.id }?.values.first)
        let preserved = try XCTUnwrap(store.files.first { $0.id == second.id }?.values.first)
        XCTAssertEqual(discarded.draftValue, "10")
        XCTAssertEqual(preserved.draftValue, "21")
    }

    func testDraftSurvivesALineInsertionAboveIt() throws {
        let root = try makeConfigRoot()
        let clockURL = root.appendingPathComponent("items/clock.lua")
        let batteryURL = root.appendingPathComponent("items/battery.lua")
        try write("-- clock\n-- config\nwidth = 10\n", to: clockURL)
        try write("width = 20\n", to: batteryURL)
        let store = SketchyBarStore(configRoot: root)
        let clock = try XCTUnwrap(store.files.first { $0.url == clockURL })
        let battery = try XCTUnwrap(store.files.first { $0.url == batteryURL })

        store.update(valueID: try XCTUnwrap(clock.values.first).id, draftValue: "20")
        store.update(valueID: try XCTUnwrap(battery.values.first).id, draftValue: "21")
        store.selectedFileID = battery.id

        // A formatter inserts a line above the edited value.
        try write("-- clock\n-- config\n-- inserted\nwidth = 10\n", to: clockURL)
        XCTAssertTrue(store.saveSelectedFile())

        let preserved = try XCTUnwrap(store.files.first { $0.id == clock.id }?.values.first)
        XCTAssertEqual(preserved.originalValue, "10")
        XCTAssertEqual(preserved.draftValue, "20")
    }

    func testDraftOfADeletedValueIsKeptAndReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\nheight = 20\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first { $0.keyPath == "width" })

        store.update(valueID: value.id, draftValue: "11")
        try write("height = 20\n", to: fileURL)
        store.reload()

        let kept = try XCTUnwrap(store.files.first { $0.id == file.id }?.values.first { $0.keyPath == "width" })
        XCTAssertEqual(kept.draftValue, "11")
        XCTAssertTrue(kept.isMissingFromFile)
        XCTAssertTrue(store.statusMessage.contains("no longer exist"))
    }

    func testFileMissingFromDiskKeepsItsDraftAcrossAReload() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11")

        try FileManager.default.removeItem(at: fileURL)
        store.reload()

        XCTAssertFalse(store.files.contains { $0.id == file.id })
        let missing = try XCTUnwrap(store.missingFiles.first { $0.id == file.id })
        XCTAssertTrue(missing.values.contains { $0.draftValue == "11" })
        XCTAssertTrue(store.statusMessage.contains("missing from disk"))
        XCTAssertTrue(store.hasUnsavedChanges)

        // The file comes back: the draft is still there and can be saved.
        try write("width = 10\n", to: fileURL)
        store.reload()
        let restored = try XCTUnwrap(store.files.first { $0.id == file.id }?.values.first)
        XCTAssertEqual(restored.draftValue, "11")
    }

    func testUpdateWithAnUnknownValueIDReportsTheMiss() throws {
        let root = try makeConfigRoot()
        try write("width = 10\n", to: root.appendingPathComponent("items/first.lua"))
        let store = SketchyBarStore(configRoot: root)

        store.update(valueID: "not-a-known-value", draftValue: "11")

        XCTAssertTrue(store.statusMessage.contains("no longer exists"))
    }

    func testSelectedFileIsNilWhenTheSelectionIsCleared() throws {
        let root = try makeConfigRoot()
        try write("width = 10\n", to: root.appendingPathComponent("items/first.lua"))
        let store = SketchyBarStore(configRoot: root)
        XCTAssertNotNil(store.selectedFile)

        store.selectedFileID = nil

        XCTAssertNil(store.selectedFile)
    }

    func testSetActiveMessageSurvivesTheReload() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("init.lua"))
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })

        store.setActive(false, fileID: file.id)

        XCTAssertTrue(store.statusMessage.contains("Deactivated"))
    }

    func testSaveSelectedFileAppliesEveryStagedLoaderOrder() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let widgetURL = root.appendingPathComponent("widgets/one.lua")
        let otherWidgetURL = root.appendingPathComponent("widgets/two.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        let shellLoaderURL = root.appendingPathComponent("sketchybarrc")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("width = 30\n", to: widgetURL)
        try write("width = 40\n", to: otherWidgetURL)
        try write("require(\"items.first\")\nrequire(\"items.second\")\n", to: loaderURL)
        try write("source widgets/one.lua\nsource widgets/two.lua\n", to: shellLoaderURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })
        let widget = try XCTUnwrap(store.files.first { $0.url == widgetURL })
        let otherWidget = try XCTUnwrap(store.files.first { $0.url == otherWidgetURL })

        store.moveItem(fileID: second.id, before: first.id)
        store.moveItem(fileID: otherWidget.id, before: widget.id)
        store.selectedFileID = first.id

        XCTAssertTrue(store.saveSelectedFile())

        XCTAssertEqual(
            try String(contentsOf: loaderURL, encoding: .utf8),
            "require(\"items.second\")\nrequire(\"items.first\")\n"
        )
        XCTAssertEqual(
            try String(contentsOf: shellLoaderURL, encoding: .utf8),
            "source widgets/two.lua\nsource widgets/one.lua\n"
        )
    }

    func testSymlinkedConfigRootDoesNotCreateASecondLibraryEntry() throws {
        let root = try makeConfigRoot()
        try write("width = 10\n", to: root.appendingPathComponent("items/first.lua"))
        let link = root.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: link)
        }
        let store = SketchyBarStore(configRoot: root)

        store.addConfig(name: "Linked", path: link.path, selectAfterAdd: true)

        XCTAssertEqual(store.configs.count, 1)
    }

    func testSelectingTheSameConfigKeepsDrafts() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11")

        store.selectConfig(try XCTUnwrap(store.selectedConfigID))

        XCTAssertEqual(store.files.first { $0.id == file.id }?.values.first?.draftValue, "11")
    }

    // MARK: - Source draft publishing

    func testSourceEditPublishesAChangeNotification() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)

        let notifications = NotificationCounter()
        let observation = store.objectWillChange.sink { notifications.increment() }
        defer { observation.cancel() }

        store.updateSourceContents("width = 11\n", for: file)

        XCTAssertTrue(store.sourceHasUnsavedChanges(for: file))
        XCTAssertGreaterThan(notifications.count, 0)
    }

    func testDiscardingTheSourceDraftPublishesAChangeNotification() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)

        let notifications = NotificationCounter()
        let observation = store.objectWillChange.sink { notifications.increment() }
        defer { observation.cancel() }

        store.discardSourceChanges(for: file)

        XCTAssertFalse(store.sourceHasUnsavedChanges(for: file))
        XCTAssertGreaterThan(notifications.count, 0)
    }

    func testTheSourceDraftCanBeSavedAfterAnEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 11\n", for: file)

        XCTAssertTrue(store.saveRawContents(for: file))

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 11\n")
        XCTAssertFalse(store.sourceHasUnsavedChanges(for: file))
    }

    // MARK: - Effective contents

    func testEffectiveContentsShowTheStructuredDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        XCTAssertEqual(store.effectiveContents(for: file), "width = 10\n")

        store.update(valueID: value.id, draftValue: "11")

        XCTAssertEqual(store.effectiveContents(for: file), "width = 11\n")
    }

    func testEffectiveContentsShowTheRawSourceDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.prepareSourceEditing(for: file)
        store.updateSourceContents("width = 12\n", for: file)

        XCTAssertEqual(store.effectiveContents(for: file), "width = 12\n")
    }

    func testEffectiveContentsAreTheBytesTheSaveWrites() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("-- item\nwidth = 10\nlabel = \"clock\"\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let width = try XCTUnwrap(file.values.first { $0.keyPath == "width" })

        store.update(valueID: width.id, draftValue: "20")
        let preview = try XCTUnwrap(store.effectiveContents(for: file))
        store.selectedFileID = file.id
        XCTAssertTrue(store.saveSelectedFile())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), preview)
    }

    // MARK: - Unsaved file count

    func testUnsavedFileCountCountsStagedOrdersAndDrafts() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let clockURL = root.appendingPathComponent("widgets/clock.lua")
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("width = 10\n", to: firstURL)
        try write("width = 20\n", to: secondURL)
        try write("width = 30\n", to: clockURL)
        try write("require(\"items.first\")\nrequire(\"items.second\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let first = try XCTUnwrap(store.files.first { $0.url == firstURL })
        let second = try XCTUnwrap(store.files.first { $0.url == secondURL })
        let clock = try XCTUnwrap(store.files.first { $0.url == clockURL })

        XCTAssertEqual(store.unsavedFileCount, 0)

        store.moveItem(fileID: second.id, before: first.id)
        store.update(valueID: try XCTUnwrap(clock.values.first).id, draftValue: "31")

        XCTAssertEqual(store.unsavedFileCount, 3)
        XCTAssertTrue(store.hasUnsavedChanges(fileID: first.id))
        XCTAssertTrue(store.hasUnsavedChanges(fileID: second.id))
        XCTAssertTrue(store.hasUnsavedChanges(fileID: clock.id))
    }

    // MARK: - Save guards

    func testTheScannerRefusesToSaveOverAnExternalEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        var values = LuaConfigScanner().scan(fileURL: fileURL)
        values[0].draftValue = "11"
        try write("width = 12\n", to: fileURL)

        XCTAssertThrowsError(try LuaConfigScanner().save(values: values, to: fileURL, rootURL: root))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 12\n")
    }

    func testAStructuredDraftIsNotSavedOverAnExternalEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11")
        store.selectedFileID = file.id
        try write("width = 12\n", to: fileURL)

        XCTAssertFalse(store.saveSelectedFile())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 12\n")
        XCTAssertEqual(store.files.first { $0.id == file.id }?.values.first?.draftValue, "11")
    }

    // MARK: - Background reload

    func testTheBackgroundReloadFillsTheStore() async throws {
        let root = try makeConfigRoot()
        try write("width = 10\n", to: root.appendingPathComponent("items/first.lua"))
        let store = SketchyBarStore(configRoot: root)

        store.reloadAsync()

        let deadline = Date().addingTimeInterval(5)
        while store.files.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.values.first?.draftValue, "10")
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioStoreTests")
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
