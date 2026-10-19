import Foundation
@testable import SketchyBarStudio
import XCTest

final class DocumentSessionTests: XCTestCase {
    func testRawDraftSaveWritesAndUpdatesFingerprint() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: [], activationReference: nil)
        var session = DocumentSession.loading(file)

        session.updateSourceContents("width = 11\n")
        try session.save(using: LuaConfigScanner(), shellScanner: ShellConfigScanner(), backupService: ConfigBackupService())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 11\n")
        XCTAssertFalse(session.hasRawDraft)
        XCTAssertEqual(session.savedContents, "width = 11\n")
    }

    func testRawSaveRejectsExternalEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: [], activationReference: nil)
        var session = DocumentSession.loading(file)
        session.updateSourceContents("width = 11\n")
        try write("width = 12\n", to: fileURL)

        XCTAssertThrowsError(try session.save(using: LuaConfigScanner(), shellScanner: ShellConfigScanner(), backupService: ConfigBackupService())) { error in
            guard case DocumentSessionError.changedOnDisk = error else {
                return XCTFail("Expected changedOnDisk, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 12\n")
    }

    func testCompetingDraftsRejected() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        var session = DocumentSession.loading(file)
        session.updateSourceContents("width = 11\n")
        var values = session.file.values
        values[0].draftValue = "12"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil)

        XCTAssertTrue(session.hasRawDraft)
        XCTAssertTrue(session.hasStructuredDraft)
        XCTAssertThrowsError(try session.save(using: LuaConfigScanner(), shellScanner: ShellConfigScanner(), backupService: ConfigBackupService())) { error in
            guard case DocumentSessionError.competingDrafts = error else {
                return XCTFail("Expected competingDrafts, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 10\n")
    }

    func testStructuredSaveRewritesOnlyChangedValues() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\nheight = 20\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        var session = DocumentSession.loading(file)
        var values = session.file.values
        values[0].draftValue = "11"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil)

        try session.save(using: LuaConfigScanner(), shellScanner: ShellConfigScanner(), backupService: ConfigBackupService())

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 11\nheight = 20\n")
    }

    func testMergePreservesValueDraftsAcrossReload() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\nheight = 20\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        var session = DocumentSession.loading(file)
        var values = session.file.values
        values[0].draftValue = "11"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil)

        let freshlyScanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        session.merge(from: freshlyScanned)

        XCTAssertEqual(session.file.values.count, 2)
        XCTAssertEqual(session.file.values[0].draftValue, "11")
        XCTAssertEqual(session.file.values[0].originalValue, "10")
        XCTAssertEqual(session.file.values[1].draftValue, "20")
        XCTAssertEqual(session.file.values[1].originalValue, "20")
    }

    func testMergeKeepsDraftsWhenTheValueMovesToAnotherLine() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        var session = DocumentSession.loading(file)
        var values = session.file.values
        values[0].draftValue = "11"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil)

        try write("-- inserted\nwidth = 10\n", to: fileURL)
        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        session.merge(from: rescanned)

        XCTAssertEqual(session.file.values.count, 1)
        XCTAssertEqual(session.file.values[0].draftValue, "11")
        XCTAssertEqual(session.file.values[0].originalValue, "10")
        XCTAssertEqual(session.file.values[0].lineNumber, 2)
    }

    func testMergeKeepsTheDraftOfADeletedValue() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\nheight = 20\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        var session = DocumentSession.loading(file)
        var values = session.file.values
        values[0].draftValue = "11"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil)

        try write("height = 20\n", to: fileURL)
        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        let missingCount = session.merge(from: rescanned)

        XCTAssertEqual(missingCount, 1)
        let kept = try XCTUnwrap(session.file.values.first { $0.keyPath == "width" })
        XCTAssertEqual(kept.draftValue, "11")
        XCTAssertTrue(kept.isMissingFromFile)
    }

    func testMergeWithDuplicateStableKeysDoesNotTrap() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let scanner = LuaConfigScanner()
        let scanned = scanner.scan(fileURL: fileURL)
        let original = try XCTUnwrap(scanned.first)
        var duplicate = LuaEditableValue(
            id: original.id + "-duplicate",
            fileURL: original.fileURL,
            keyPath: original.keyPath,
            lineNumber: original.lineNumber,
            kind: original.kind,
            originalValue: original.originalValue,
            draftValue: "12",
            suggestedValues: original.suggestedValues,
            valueStartOffset: original.valueEndOffset,
            valueEndOffset: original.valueEndOffset,
            sourceSnapshot: original.sourceSnapshot
        )
        duplicate.stableKey = original.stableKey
        var values = scanned
        values.append(duplicate)
        var session = DocumentSession.loading(ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: values, activationReference: nil))
        var drafted = session.file.values
        drafted[0].draftValue = "11"
        session.file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: drafted, activationReference: nil)

        let rescanned = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: scanner.scan(fileURL: fileURL), activationReference: nil)
        session.merge(from: rescanned)

        XCTAssertEqual(session.file.values.first?.draftValue, "11")
    }

    func testDiscardSourceChangesReloadsFromDisk() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/first.lua")
        try write("width = 10\n", to: fileURL)
        let file = ConfigFile(url: fileURL, rootURL: root, kind: .lua, values: [], activationReference: nil)
        var session = DocumentSession.loading(file)

        session.updateSourceContents("width = 11\n")
        try write("width = 12\n", to: fileURL)
        session.discardSourceChanges()

        XCTAssertEqual(session.sourceContents, "width = 12\n")
        XCTAssertFalse(session.hasRawDraft)
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioDocumentSessionTests")
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