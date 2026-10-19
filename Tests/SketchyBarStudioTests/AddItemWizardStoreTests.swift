import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the write path of the new item wizard.
///
/// The tests use a config tree of their own, so they never touch the
/// config of the user.
@MainActor
final class AddItemWizardStoreTests: XCTestCase {
    private let itemContents = "local clock = sbar.add(\"item\", \"clock\", {\n\tposition = \"right\",\n})\n"

    // MARK: - Creating the file

    func testCreatingAFileAddsItToTheConfigAndSelectsIt() throws {
        let root = try makeConfigRoot()
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("init.lua"))
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let file = try XCTUnwrap(store.files.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
        XCTAssertEqual(store.selectedFileID, file.id)
        XCTAssertEqual(file.displayName, "items/right/clock.lua")
    }

    func testAFileMadeOfTheScaffolderIsReadAsAnItem() throws {
        let scaffolder = ItemScaffolder()
        let template = try XCTUnwrap(scaffolder.templates(for: .sbarLua).first { $0.id == "clock" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: scaffolder.defaultIcon(for: template),
            label: "",
            updateFreq: scaffolder.defaultUpdateFreq(for: template)
        )

        let root = try makeConfigRoot()
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")
        XCTAssertTrue(store.createItemFile(contents: contents, at: url))

        let file = try XCTUnwrap(store.files.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })
        let position = try XCTUnwrap(file.values.first { $0.keyPath == "position" })
        XCTAssertEqual(position.originalValue, "right")
        XCTAssertTrue(file.values.contains { $0.keyPath == "script" })
        XCTAssertTrue(file.values.contains { $0.keyPath == "update_freq" })
    }

    func testCreatingAFileThatExistsIsRefusedUnlessItIsConfirmed() throws {
        let root = try makeConfigRoot()
        let url = root.appendingPathComponent("items/right/clock.lua")
        try write("old contents\n", to: url)
        let store = SketchyBarStore(configRoot: root)

        XCTAssertFalse(store.createItemFile(contents: itemContents, at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old contents\n")
        XCTAssertTrue(store.statusMessage.contains("already exists"))

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url, overwrite: true))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), itemContents)
        // The file that was replaced is kept in the backup mirror.
        let backup = root.appendingPathComponent("backups/.sketchybar-studio/items/right/clock.lua")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old contents\n")
    }

    func testAFileOutsideTheConfigRootIsRefused() throws {
        let root = try makeConfigRoot()
        let store = SketchyBarStore(configRoot: root)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioOutside")
            .appendingPathComponent("clock.lua")

        XCTAssertFalse(store.createItemFile(contents: itemContents, at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The loader line

    func testTheLoaderLineKeepsTheRestOfTheLoaderFile() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        let original = """
        sbar = require("sketchybar")
        sbar.begin_config()
        require("bar")
        require("items")
        sbar.hotload(true)
        sbar.end_config()
        """
        try write(original, to: loaderURL)

        let change = try ConfigActivationService().insertLoaderLine(
            "require(\"items.right.clock\")",
            into: loaderURL,
            rootURL: root
        )

        let updated = try String(contentsOf: loaderURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("require(\"items.right.clock\")"))
        XCTAssertEqual(
            updated.replacingOccurrences(of: "require(\"items.right.clock\")\n", with: ""),
            original
        )
        // The line goes after the last loader line of the file.
        XCTAssertTrue(updated.contains("require(\"items\")\nrequire(\"items.right.clock\")"))
        XCTAssertEqual(change.previousContents, original)
    }

    func testALoaderLineThatIsAlreadyThereIsRefused() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.right.clock\")\n", to: loaderURL)

        XCTAssertThrowsError(
            try ConfigActivationService().insertLoaderLine(
                "require(\"items.right.clock\")",
                into: loaderURL,
                rootURL: root
            )
        )
    }

    func testALoaderFileThatChangedOnDiskIsNotOverwritten() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")
        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))

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

    // MARK: - Undo

    func testTheCreatedFileAndTheLoaderLineAreUndoable() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let original = try Data(contentsOf: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))
        XCTAssertTrue(try String(contentsOf: loaderURL, encoding: .utf8).contains("items.right.clock"))

        store.undo()

        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        store.undo()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
        XCTAssertFalse(store.canUndo)
    }

    func testTheCreationCanBeUndoneWhenTheLoaderLineIsStillThere() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let original = try Data(contentsOf: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))

        // The loader line is taken away first, then the file.
        store.undo()
        store.undo()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: loaderURL), original)
    }

    func testTheCreationAndTheLoaderLineCanBeDoneAgain() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))

        store.undo()
        store.undo()
        store.redo()
        store.redo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try String(contentsOf: loaderURL, encoding: .utf8).contains("items.right.clock"))
    }

    // MARK: - The loader candidates

    func testTheLoaderCandidatesHoldTheEntrypointAndTheItemLoader() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar = require(\"sketchybar\")\nsbar.begin_config()\nrequire(\"items\")\nsbar.end_config()\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write("require(\"items.first\")\n", to: root.appendingPathComponent("items/init.lua"))

        let candidates = LoaderCandidates.candidates(in: root)

        XCTAssertTrue(candidates.contains { $0.lastPathComponent == "init.lua" && $0.deletingLastPathComponent().lastPathComponent == "items" })
        XCTAssertTrue(candidates.contains { $0.lastPathComponent == "init.lua" && $0.deletingLastPathComponent().lastPathComponent == root.lastPathComponent })
    }

    // MARK: - Helpers

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioWizardTests")
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
