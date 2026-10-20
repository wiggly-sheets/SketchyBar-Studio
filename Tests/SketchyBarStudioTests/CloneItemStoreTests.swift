import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the clone action of the store.
///
/// The tests use a config tree of their own, so they never touch the
/// config of the user.
@MainActor
final class CloneItemStoreTests: XCTestCase {
    private let itemContents = "local clock = sbar.add(\"item\", \"clock\", {\n\tposition = \"right\",\n})\n"

    // MARK: - Cloning

    func testCloningCreatesTheFileAndAddsTheLoaderLine() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        let result = try XCTUnwrap(store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
        XCTAssertEqual(result.fileURL.lastPathComponent, "clock-copy.lua")

        // The copy holds the new alias and nothing else changes.
        let clone = try String(contentsOf: result.fileURL, encoding: .utf8)
        XCTAssertEqual(clone, itemContents.replacingOccurrences(of: "\"clock\"", with: "\"clock-copy\""))

        // The loader file loads the copy.
        let loader = try String(contentsOf: loaderURL, encoding: .utf8)
        XCTAssertTrue(loader.contains("require(\"items.right.clock-copy\")"))
        XCTAssertTrue(loader.contains("require(\"items.first\")"))
    }

    func testTheCopyIsAddedToTheConfig() throws {
        let root = try makeConfigRoot()
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("init.lua"))
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        let result = try XCTUnwrap(store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy"))

        XCTAssertTrue(store.files.contains { $0.url.standardizedFileURL.path == result.fileURL.standardizedFileURL.path })
    }

    func testAFileWithoutAnItemIsCopiedWithoutALoaderLine() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        try write("local M = {}\nreturn M\n", to: root.appendingPathComponent("items/right/helpers.lua"))
        let original = try Data(contentsOf: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/helpers.lua" })

        let result = try XCTUnwrap(store.cloneItem(file: source, newName: "helpers-copy", newAlias: "helpers-copy"))

        XCTAssertFalse(result.didAddLoaderLine)
        XCTAssertNil(result.loaderFailureMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "local M = {}\nreturn M\n")
        // The loader file is untouched.
        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
    }

    // MARK: - Undo and redo

    func testTheCopyAndTheLoaderLineAreUndoable() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let original = try Data(contentsOf: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        let result = try XCTUnwrap(store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy"))

        // The loader line goes first, the file stays.
        store.undo()
        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))

        // The file goes with it.
        store.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
        XCTAssertFalse(store.canUndo)
    }

    func testTheCopyCanBeDoneAgain() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        let result = try XCTUnwrap(store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy"))

        store.undo()
        store.undo()
        store.redo()
        store.redo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
        let loader = try String(contentsOf: loaderURL, encoding: .utf8)
        XCTAssertTrue(loader.contains("require(\"items.right.clock-copy\")"))
    }

    func testARedoOfTheLoaderLineIsRefusedWhenTheLoaderFileChangedOnDisk() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        _ = store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy")
        store.undo()

        // Another program writes the loader file.
        try write("require(\"items.first\")\nrequire(\"items.other\")\n", to: loaderURL)

        store.redo()

        XCTAssertTrue(store.statusMessage.contains("Redo failed"))
        // The step stays on the stack, so the user can try again later.
        XCTAssertTrue(store.canRedo)
        XCTAssertEqual(
            try String(contentsOf: loaderURL, encoding: .utf8),
            "require(\"items.first\")\nrequire(\"items.other\")\n"
        )
    }

    // MARK: - Refused clones

    func testATargetThatAlreadyExistsIsRefused() throws {
        let root = try makeConfigRoot()
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("init.lua"))
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let targetURL = root.appendingPathComponent("items/right/clock-copy.lua")
        try write("old contents\n", to: targetURL)
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        XCTAssertNil(store.cloneItem(file: source, newName: "clock-copy", newAlias: "clock-copy"))

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "old contents\n")
        XCTAssertTrue(store.statusMessage.contains("already exists"))
    }

    func testASourceOutsideTheConfigRootIsRefused() throws {
        let root = try makeConfigRoot()
        let store = SketchyBarStore(configRoot: root)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioCloneOutside")
            .appendingPathComponent("clock.lua")
        try write(itemContents, to: outsideURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: outsideURL.deletingLastPathComponent()) }
        let outsideFile = ConfigFile(
            url: outsideURL,
            rootURL: root,
            kind: .lua,
            values: [],
            activationReference: nil
        )

        XCTAssertNil(store.cloneItem(file: outsideFile, newName: "clock-copy", newAlias: "clock-copy"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clock-copy.lua").path))
        XCTAssertTrue(store.statusMessage.contains("outside the config folder"))
    }

    func testAnUnsafeNameIsRefused() throws {
        let root = try makeConfigRoot()
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("init.lua"))
        try write(itemContents, to: root.appendingPathComponent("items/right/clock.lua"))
        let store = SketchyBarStore(configRoot: root)
        let source = try XCTUnwrap(store.files.first { $0.displayName == "items/right/clock.lua" })

        XCTAssertNil(store.cloneItem(file: source, newName: "../escape", newAlias: "clock-copy"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.lua").path))
        XCTAssertTrue(store.statusMessage.contains("not a safe file name"))
    }

    // MARK: - Helpers

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioCloneTests")
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
