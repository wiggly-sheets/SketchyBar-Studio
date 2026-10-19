import Foundation
@testable import SketchyBarStudio
import XCTest

/// Tests for the draft, store and scanner accuracy fixes.
@MainActor
final class DraftStoreAccuracyTests: XCTestCase {
    // MARK: - FIX 1: a draft stays on the value it belongs to

    func testDraftDoesNotMoveToAnotherValueWhenABlockWithTheSameOptionIsInserted() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write(Self.twoItems, to: fileURL)
        let scanner = LuaConfigScanner()
        var session = DocumentSession.loading(
            ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        )
        session = try withDraft(on: session, keyPath: "position", value: "center")

        // A new item with the same option is inserted above the two items.
        try write(Self.newItem + Self.twoItems, to: fileURL)
        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        let missingCount = session.merge(from: rescanned)

        // The draft is reported instead of landing on another item.
        XCTAssertEqual(missingCount, 1)
        let drafted = try XCTUnwrap(session.file.values.first { $0.draftValue == "center" })
        XCTAssertTrue(drafted.isMissingFromFile)
        XCTAssertEqual(session.file.values.filter { $0.draftValue == "center" }.count, 1)

        // Every value on disk keeps its own text.
        for value in session.file.values where !value.isMissingFromFile {
            XCTAssertEqual(value.draftValue, value.originalValue)
        }
        XCTAssertEqual(session.file.values.filter { $0.keyPath == "position" && !$0.isMissingFromFile }.count, 3)
    }

    func testAValueThatChangedOnDiskIsNotOverwrittenByAStaleDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var session = DocumentSession.loading(
            ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        )
        session = try withDraft(on: session, keyPath: "width", value: "11")

        // Another process writes a new value to the same line.
        try write("width = 12\n", to: fileURL)
        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        let missingCount = session.merge(from: rescanned)

        XCTAssertEqual(missingCount, 1)
        let kept = try XCTUnwrap(session.file.values.first { $0.keyPath == "width" && $0.isMissingFromFile })
        XCTAssertEqual(kept.draftValue, "11")
        XCTAssertEqual(kept.originalValue, "10")
        // The value on disk is not touched by the stale draft.
        let onDisk = try XCTUnwrap(session.file.values.first { $0.keyPath == "width" && !$0.isMissingFromFile })
        XCTAssertEqual(onDisk.originalValue, "12")
        XCTAssertEqual(onDisk.draftValue, "12")
    }

    func testDraftSurvivesALineShift() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var session = DocumentSession.loading(
            ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        )
        session = try withDraft(on: session, keyPath: "width", value: "11")

        // A formatter inserts a line above the edited value.
        try write("-- inserted\nwidth = 10\n", to: fileURL)
        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        let missingCount = session.merge(from: rescanned)

        XCTAssertEqual(missingCount, 0)
        let value = try XCTUnwrap(session.file.values.first { $0.keyPath == "width" })
        XCTAssertEqual(value.draftValue, "11")
        XCTAssertEqual(value.originalValue, "10")
        XCTAssertEqual(value.lineNumber, 2)
        XCTAssertFalse(value.isMissingFromFile)
    }

    // MARK: - FIX 2: Save All and the quit guard

    func testSaveAllReportsAFileThatIsMissingFromDiskAndKeepsItsDraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11")

        try FileManager.default.removeItem(at: fileURL)
        store.reload()
        XCTAssertTrue(store.missingFiles.contains { $0.id == file.id })
        XCTAssertEqual(store.unsavedFileCount, 1)

        XCTAssertFalse(store.saveAllChangedFiles())

        XCTAssertEqual(
            store.statusMessage,
            "No file was saved. 1 file is missing from disk and its draft was not saved: items/clock.lua"
        )
        // The draft is still there and the file was not written.
        let missing = try XCTUnwrap(store.missingFiles.first { $0.id == file.id })
        XCTAssertTrue(missing.values.contains { $0.draftValue == "11" })
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTheQuitGuardKeepsTheAppOpenWhileADraftIsUnsaved() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11")
        try FileManager.default.removeItem(at: fileURL)
        store.reload()

        let delegate = AppDelegate()
        delegate.store = store

        XCTAssertFalse(delegate.saveAllAndMayTerminate())
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    // MARK: - FIX 3: the backup holds the bytes that are about to be overwritten

    func testTheBackupHoldsTheBytesThatAreAboutToBeOverwritten() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        var session = DocumentSession.loading(
            ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: [], activationReference: nil)
        )
        session.updateSourceContents("width = 11\n")
        try session.save(using: LuaConfigScanner(), shellScanner: ShellConfigScanner(), backupService: ConfigBackupService())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 11\n")
        let backupURL = root.appendingPathComponent("backups/.sketchybar-studio/items/clock.lua")
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "width = 10\n")

        // Another process writes to the file: the backup keeps the bytes of
        // the version that was overwritten.
        try write("width = 99\n", to: fileURL)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "width = 10\n")
    }

    func testTheBackupStoresTheGivenTextInsteadOfTheFileOnDisk() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("external text\n", to: fileURL)

        let backupURL = try ConfigBackupService().backup(fileURL: fileURL, rootURL: root, contents: "app text\n")

        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "app text\n")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "external text\n")
    }

    func testTheBackupOfASymlinkedFileIsARegularFile() throws {
        let root = try makeConfigRoot()
        let realURL = root.appendingPathComponent("items/real.lua")
        let linkURL = root.appendingPathComponent("items/link.lua")
        try write("real text\n", to: realURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let backupURL = try ConfigBackupService().backup(fileURL: linkURL, rootURL: root, contents: "app text\n")

        let isLink = (try backupURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false
        XCTAssertFalse(isLink)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "app text\n")
    }

    // MARK: - FIX 4: a file that is missing from disk stays marked

    func testAFileThatIsMissingFromDiskStaysMarkedAfterAnEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let valueID = try XCTUnwrap(file.values.first).id

        try FileManager.default.removeItem(at: fileURL)
        store.reload()
        XCTAssertTrue(try XCTUnwrap(store.missingFiles.first { $0.id == file.id }).isMissingFromDisk)

        store.update(valueID: valueID, draftValue: "11")

        let missing = try XCTUnwrap(store.missingFiles.first { $0.id == file.id })
        XCTAssertTrue(missing.isMissingFromDisk)
        XCTAssertTrue(missing.values.contains { $0.draftValue == "11" })
        XCTAssertFalse(store.files.contains { $0.id == file.id })
    }

    // MARK: - FIX 5: the shell heredoc detection

    func testAShiftInShellArithmeticDoesNotStopTheScanner() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("scripts/event.sh")
        try write("#!/bin/sh\ncount=$((a<<b))\nposition=right\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        let position = try XCTUnwrap(values.first { $0.keyPath == "position" })
        XCTAssertEqual(position.originalValue, "right")
        XCTAssertEqual(position.lineNumber, 3)
    }

    func testAHeredocWithoutATerminatorDoesNotHideTheRestOfTheFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("scripts/event.sh")
        try write("#!/bin/sh\ncat <<EOF\nposition=right\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        let position = try XCTUnwrap(values.first { $0.keyPath == "position" })
        XCTAssertEqual(position.lineNumber, 3)
    }

    func testAHeredocIsStillIgnored() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("scripts/event.sh")
        try write("#!/bin/sh\ncat <<EOF\nposition=inside\nEOF\nposition=outside\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        let positions = values.filter { $0.keyPath == "position" }
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.originalValue, "outside")
    }

    // MARK: - Helpers

    private static let twoItems = """
    sbar.add("item", {
        position = "right",
        label = "one"
    })
    sbar.add("item", {
        position = "right",
        label = "two"
    })
    """

    private static let newItem = """
    sbar.add("item", {
        position = "right",
        label = "new"
    })
    """

    /// A copy of the session with a draft on the first value of a key path.
    private func withDraft(on session: DocumentSession, keyPath: String, value: String) throws -> DocumentSession {
        var session = session
        var values = session.file.values
        let index = try XCTUnwrap(values.firstIndex { $0.keyPath == keyPath })
        values[index].draftValue = value
        session.file = ConfigFile(
            url: session.file.url,
            rootURL: session.file.rootURL,
            kind: session.file.kind,
            values: values,
            activationReference: session.file.activationReference
        )
        return session
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioDraftStoreTests")
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
