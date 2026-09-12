import Foundation
@testable import SketchyBarStudio
import XCTest

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
