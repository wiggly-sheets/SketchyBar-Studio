import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the new config action of the store.
///
/// The tests use a config tree of their own and their own library file, so
/// they never touch the config or the library of the user.
@MainActor
final class NewConfigStoreTests: XCTestCase {
    private let scaffolder = ConfigScaffolder()

    // MARK: - Creating a config

    func testCreatingAConfigWritesTheFilesAndAddsItToTheLibrary() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "my-config",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        ))

        // The files of the config are on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("init.lua").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("bar.lua").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("items/left/clock.lua").path)
        )

        // The library holds the config and the config is the selected one.
        XCTAssertTrue(store.configs.contains { $0.id == result.configID })
        XCTAssertEqual(store.selectedConfigID, result.configID)
        XCTAssertEqual(store.configRoot.standardizedFileURL.path, result.rootURL.standardizedFileURL.path)

        // The files of the config are read.
        XCTAssertTrue(store.files.contains { $0.displayName == "init.lua" })
        XCTAssertTrue(store.files.contains { $0.displayName == "items/left/clock.lua" })
    }

    func testEveryFileOfTheConfigIsInsideTheFolderOfTheConfig() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "my-config",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        ))

        let rootPath = result.rootURL.standardizedFileURL.path + "/"
        for url in result.fileURLs {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(rootPath))
        }
    }

    func testTheShellConfigIsCreatedAsOneFile() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "shell-config",
            in: root,
            style: .shell,
            starterItems: scaffolder.starterItems(for: .shell)
        ))

        XCTAssertEqual(result.fileURLs.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("sketchybarrc").path)
        )
    }

    func testANameWithASlashIsRefused() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = store.createConfig(
            name: "escape/../outside",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        )

        XCTAssertNil(result)
        XCTAssertTrue(store.statusMessage.contains("slash"))
    }

    // MARK: - Undo and redo

    func testTheCreationCanBeUndone() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "my-config",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        ))

        store.undo()

        // The files are gone and so is the folder of the config.
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.rootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("init.lua").path))

        // The library does not hold the config any more.
        XCTAssertFalse(store.configs.contains { $0.id == result.configID })
        XCTAssertNotEqual(store.selectedConfigID, result.configID)
    }

    func testTheCreationCanBeDoneAgain() throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "my-config",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        ))

        store.undo()
        store.redo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.rootURL.appendingPathComponent("init.lua").path))
        XCTAssertTrue(store.configs.contains { $0.id == result.configID })
        XCTAssertEqual(store.selectedConfigID, result.configID)
    }

    // MARK: - Refused creations

    func testCreatingIntoAFolderThatHoldsAConfigIsRefused() throws {
        let root = try makeRoot()
        let oldText = "sbar = require(\"sketchybar\")\n"
        let existing = try writeExistingConfig(in: root, name: "existing", text: oldText)
        let store = try makeStore(root: root)

        let result = store.createConfig(
            name: "existing",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        )

        XCTAssertNil(result)
        XCTAssertTrue(store.statusMessage.contains("already exists"))

        // The old file is untouched and no other file was left behind.
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("init.lua"), encoding: .utf8), oldText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("bar.lua").path))
    }

    func testTheConfirmedCreationReplacesTheFileAndKeepsTheOldText() throws {
        let root = try makeRoot()
        let oldText = "sbar = require(\"sketchybar\")\n"
        let existing = try writeExistingConfig(in: root, name: "existing", text: oldText)
        let store = try makeStore(root: root)

        let result = try XCTUnwrap(store.createConfig(
            name: "existing",
            in: root,
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua),
            overwrite: true
        ))

        // The file holds the new text.
        let newText = try String(contentsOf: existing.appendingPathComponent("init.lua"), encoding: .utf8)
        XCTAssertTrue(newText.contains("sbar.begin_config()"))

        // The old text is in the backup mirror.
        let backup = result.rootURL.appendingPathComponent("backups/.sketchybar-studio/init.lua")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), oldText)
    }

    // MARK: - Helpers

    private func makeStore(root: URL) throws -> SketchyBarStore {
        SketchyBarStore(
            configRoot: root,
            libraryURL: root.appendingPathComponent("library.json")
        )
    }

    /// A folder that holds a config already.
    private func writeExistingConfig(in root: URL, name: String, text: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return folder
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioNewConfigTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
