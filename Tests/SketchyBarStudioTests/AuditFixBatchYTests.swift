import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the fixes of the second audit batch.
///
/// The tests use config trees of their own, so they never touch the config
/// of the user.
@MainActor
final class AuditFixBatchYTests: XCTestCase {
    private let itemContents = "local clock = sbar.add(\"item\", \"clock\", {\n\tposition = \"right\",\n})\n"

    // MARK: - F2: the preview must not use the offsets of another text

    /// The crash of the old code: the file is scanned, it changes on disk
    /// and becomes shorter, the source editor reads it again and the user
    /// edits a value. The offsets of the value belong to the old text, so
    /// writing them into the new text went past its end.
    func testThePreviewSurvivesAFileThatShrankOnDisk() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("-- clock\nwidth = 10\nlabel = \"clock\"\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })

        // Another program writes a shorter file. The label moves to the
        // front, so the offset of its value is past the end of the new text.
        try write("label = \"clock\"\n", to: fileURL)

        // The user opens the source editor and goes back to the controls.
        store.prepareSourceEditing(for: file)
        let reloaded = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let label = try XCTUnwrap(reloaded.values.first { $0.keyPath == "label" })
        store.update(valueID: label.id, draftValue: "time")

        // The preview is the file as it is on disk now, with the edit.
        XCTAssertEqual(store.effectiveContents(for: file), "label = \"time\"\n")
        // The user is told that the file changed on disk.
        XCTAssertTrue(store.statusMessage.contains("changed on disk"))
    }

    /// The guard of the preview: the offsets of a value belong to the text
    /// it was scanned from, so they may only be used on that text.
    func testDraftsThatDoNotFitTheLoadedTextAreRefused() throws {
        let scanned = "-- clock\nwidth = 10\n"
        let value = makeValue(sourceSnapshot: scanned, start: 15, end: 17)

        // The text the value was scanned from is not the text of the file.
        XCTAssertFalse(SketchyBarStore.draftsFitBase([value], base: "width = 10\n"))
        // The value belongs to the text of the file.
        XCTAssertTrue(SketchyBarStore.draftsFitBase([value], base: scanned))

        // The offset of the value is past the end of the text.
        let tooLate = makeValue(sourceSnapshot: "width = 10\n", start: 40, end: 42)
        XCTAssertFalse(SketchyBarStore.draftsFitBase([tooLate], base: "width = 10\n"))

        // A value that was not edited does not matter.
        var unchanged = makeValue(sourceSnapshot: "other text\n", start: 7, end: 9)
        unchanged.draftValue = unchanged.originalValue
        XCTAssertTrue(SketchyBarStore.draftsFitBase([unchanged], base: "width = 10\n"))
    }

    /// A value that is not in the file any more is kept as a draft, but it
    /// is never written, so it does not stop the preview.
    func testADraftThatIsNotInTheFileAnyMoreDoesNotStopThePreview() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let width = try XCTUnwrap(file.values.first { $0.keyPath == "width" })

        store.update(valueID: width.id, draftValue: "20")
        // The key is gone from the file, so the draft is kept but not
        // written.
        try write("label = \"clock\"\n", to: fileURL)
        store.reload()

        let reloaded = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let missing = try XCTUnwrap(reloaded.values.first { $0.isMissingFromFile })
        XCTAssertEqual(missing.draftValue, "20")
        XCTAssertEqual(store.effectiveContents(for: file), "label = \"clock\"\n")
    }

    // MARK: - F3: undoing a creation changes nothing when the file changed

    func testUndoingACreationChangesNothingWhenTheFileChangedOnDisk() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")
        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))
        let loaderBefore = try Data(contentsOf: loaderURL)

        // Another program writes the created file.
        try write("changed on disk\n", to: url)

        XCTAssertFalse(store.removeCreatedItemFile(at: url, contents: itemContents))

        // Nothing was changed: the loader line is still there and the file
        // is still there.
        XCTAssertEqual(try Data(contentsOf: loaderURL), loaderBefore)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed on disk\n")
        XCTAssertTrue(store.statusMessage.contains("Undo failed"))
    }

    func testTheRefusedUndoOfACreationStaysOnTheStack() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")
        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(store.insertLoaderLine("require(\"items.right.clock\")", into: loaderURL, forItemFile: url))

        // Another program writes the created file.
        try write("changed on disk\n", to: url)

        store.undo()
        store.undo()

        // The file was not removed, and the step stays on the stack.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.canUndo)
        XCTAssertTrue(store.statusMessage.contains("Undo failed"))
    }

    // MARK: - F4: undoing an overwrite puts the original bytes back

    func testUndoingAnOverwritePutsTheOriginalBytesBack() throws {
        let root = try makeConfigRoot()
        let url = root.appendingPathComponent("items/clock.lua")
        // A file that is not valid UTF-8.
        let original = Data([0x77, 0x69, 0x64, 0x74, 0x68, 0x3D, 0x20, 0xFF, 0xFE, 0x0A])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let store = SketchyBarStore(configRoot: root)

        XCTAssertTrue(store.createItemFile(contents: "width = 10\n", at: url, overwrite: true))
        XCTAssertEqual(try Data(contentsOf: url), Data("width = 10\n".utf8))

        store.undo()

        // The bytes of the file that was replaced are back.
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAFileThatCannotBeReadIsNotReplaced() throws {
        let root = try makeConfigRoot()
        let url = root.appendingPathComponent("items/clock.lua")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: root.appendingPathComponent("items/missing.lua")
        )
        let store = SketchyBarStore(configRoot: root)

        // A file whose bytes cannot be read is never replaced, because such
        // a change could never be undone.
        XCTAssertFalse(store.createItemFile(contents: "width = 10\n", at: url, overwrite: true))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        XCTAssertTrue(store.statusMessage.contains("Could not read"))
    }

    // MARK: - F6: a step whose value is gone must not block the history

    func testTheUndoStackAdvancesAfterAnExternalEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        XCTAssertTrue(store.canUndo)

        // Another program writes the file and the config is read again.
        try write("-- a comment\nwidth = 10\n", to: fileURL)
        store.reload()

        store.undo()

        // The step was dropped instead of blocking the history.
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(store.statusMessage.contains("dropped"))
    }

    func testTheRedoStackAdvancesAfterAnExternalEdit() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)

        store.update(valueID: value.id, draftValue: "20")
        store.undo()
        XCTAssertTrue(store.canRedo)

        // Another program writes the file and the config is read again.
        try write("-- a comment\nwidth = 10\n", to: fileURL)
        store.reload()

        store.redo()

        // The step was dropped instead of blocking the history.
        XCTAssertFalse(store.canRedo)
        XCTAssertTrue(store.statusMessage.contains("dropped"))
    }

    // MARK: - F7: a folder that points outside the root is refused

    func testCreatingAFileInAFolderThatPointsOutsideTheRootIsRefused() throws {
        let root = try makeConfigRoot()
        let outside = try makeDirectory("outside")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("items"),
            withDestinationURL: outside
        )
        let store = SketchyBarStore(configRoot: root)
        let url = root.appendingPathComponent("items/right/clock.lua")

        XCTAssertFalse(store.createItemFile(contents: itemContents, at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("right/clock.lua").path))
        XCTAssertTrue(store.statusMessage.contains("Refusing to write outside"))
    }

    func testCreatingAFileInASymlinkedRootIsAllowed() throws {
        let root = try makeConfigRoot()
        let link = root.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let store = SketchyBarStore(configRoot: link)
        let url = link.appendingPathComponent("items/right/clock.lua")

        XCTAssertTrue(store.createItemFile(contents: itemContents, at: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("items/right/clock.lua").path))
    }

    // MARK: - F8: a loader file with a source draft is not changed

    func testAddingALoaderLineIsRefusedWhenTheLoaderHasASourceDraft() throws {
        let root = try makeConfigRoot()
        let loaderURL = root.appendingPathComponent("init.lua")
        try write("require(\"items.first\")\n", to: loaderURL)
        let store = SketchyBarStore(configRoot: root)
        let loaderFile = try XCTUnwrap(store.files.first { $0.url == loaderURL })
        store.prepareSourceEditing(for: loaderFile)
        store.updateSourceContents("require(\"items.first\")\n-- a draft\n", for: loaderFile)
        let before = try Data(contentsOf: loaderURL)

        XCTAssertFalse(store.insertLoaderLine(
            "require(\"items.right.clock\")",
            into: loaderURL,
            forItemFile: root.appendingPathComponent("items/right/clock.lua")
        ))

        // The loader file was not written.
        XCTAssertEqual(try Data(contentsOf: loaderURL), before)
        XCTAssertTrue(store.statusMessage.contains("source draft"))
    }

    // MARK: - F10: the review shows what the write really does

    func testTheSaveReviewComparesAgainstTheLoadedText() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)
        store.update(valueID: value.id, draftValue: "20")

        // Another program writes the file.
        try write("width = 30\n", to: fileURL)

        let review = try XCTUnwrap(store.saveReview(for: file))

        // The old side of the diff is the text the app holds, which is the
        // base of the write, so the review does not show the edit of the
        // other program being reverted.
        XCTAssertEqual(review.base, "width = 10\n")
        XCTAssertEqual(review.contents, "width = 20\n")
        let hunks = DiffEngine.diff(old: review.base, new: review.contents)
        XCTAssertFalse(hunks.flatMap(\.lines).contains { $0.text.contains("30") })
        // The user is told that the file changed on disk.
        XCTAssertNotNil(review.notice)
    }

    func testTheSaveReviewHasNoNoticeWhenTheFileIsUnchanged() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 10\n", to: fileURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == fileURL })
        let value = try XCTUnwrap(file.values.first)
        store.update(valueID: value.id, draftValue: "20")

        let review = try XCTUnwrap(store.saveReview(for: file))

        XCTAssertNil(review.notice)
        XCTAssertEqual(review.base, "width = 10\n")
        XCTAssertEqual(review.contents, "width = 20\n")
    }

    // MARK: - Helpers

    private func makeValue(sourceSnapshot: String, start: Int, end: Int) -> LuaEditableValue {
        LuaEditableValue(
            id: "value",
            fileURL: URL(fileURLWithPath: "/tmp/clock.lua"),
            keyPath: "width",
            lineNumber: 1,
            kind: .number,
            originalValue: "10",
            draftValue: "20",
            suggestedValues: [],
            valueStartOffset: start,
            valueEndOffset: end,
            sourceSnapshot: sourceSnapshot
        )
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioAuditFixBatchY")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioAuditFixBatchY")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
