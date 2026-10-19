import Foundation
@testable import SketchyBarStudio
import XCTest

/// Tests for the diff engine that shows what a save would write.
final class DiffEngineTests: XCTestCase {
    // MARK: - The same text

    func testTheSameTextHasNoHunks() {
        XCTAssertTrue(DiffEngine.diff(old: "one\ntwo\nthree\n", new: "one\ntwo\nthree\n").isEmpty)
    }

    func testTheSameTextWithoutANewlineHasNoHunks() {
        XCTAssertTrue(DiffEngine.diff(old: "one\ntwo", new: "one\ntwo\n").isEmpty)
    }

    // MARK: - One changed line

    func testOneChangedLineMakesOneHunk() throws {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (1...10).map { $0 == 5 ? "line 5 changed" : "line \($0)" }.joined(separator: "\n") + "\n"

        let hunks = DiffEngine.diff(old: old, new: new, contextLines: 1)

        XCTAssertEqual(hunks.count, 1)
        let hunk = try XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.oldStart, 4)
        XCTAssertEqual(hunk.oldCount, 3)
        XCTAssertEqual(hunk.newStart, 4)
        XCTAssertEqual(hunk.newCount, 3)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(hunk.lines.map(\.text), ["line 4", "line 5", "line 5 changed", "line 6"])
    }

    func testAChangedLineKeepsThreeLinesOfContextByDefault() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (1...10).map { $0 == 5 ? "line 5 changed" : "line \($0)" }.joined(separator: "\n") + "\n"

        let hunks = DiffEngine.diff(old: old, new: new)

        XCTAssertEqual(hunks.count, 1)
        let hunk = hunks.first
        XCTAssertEqual(hunk?.oldStart, 2)
        XCTAssertEqual(hunk?.oldCount, 7)
        XCTAssertEqual(hunk?.newStart, 2)
        XCTAssertEqual(hunk?.newCount, 7)
        XCTAssertEqual(hunk?.lines.filter { $0.kind == .context }.count, 6)
        XCTAssertEqual(hunk?.lines.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(hunk?.lines.filter { $0.kind == .added }.count, 1)
    }

    // MARK: - Insertions and deletions

    func testAnInsertionAtTheStart() {
        let hunks = DiffEngine.diff(old: "b\nc\n", new: "a\nb\nc\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 1)
        XCTAssertEqual(hunks.first?.oldCount, 2)
        XCTAssertEqual(hunks.first?.newStart, 1)
        XCTAssertEqual(hunks.first?.newCount, 3)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.added, .context, .context])
    }

    func testAnInsertionInTheMiddle() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\nd\ne\n", new: "a\nb\nX\nc\nd\ne\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 1)
        XCTAssertEqual(hunks.first?.oldCount, 5)
        XCTAssertEqual(hunks.first?.newStart, 1)
        XCTAssertEqual(hunks.first?.newCount, 6)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.context, .context, .added, .context, .context, .context])
        XCTAssertEqual(hunks.first?.lines.first(where: { $0.kind == .added })?.text, "X")
    }

    func testAnInsertionAtTheEnd() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\n", new: "a\nb\nc\nd\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldCount, 3)
        XCTAssertEqual(hunks.first?.newCount, 4)
        XCTAssertEqual(hunks.first?.lines.last?.kind, .added)
        XCTAssertEqual(hunks.first?.lines.last?.text, "d")
    }

    func testADeletionAtTheStart() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\n", new: "b\nc\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 1)
        XCTAssertEqual(hunks.first?.oldCount, 3)
        XCTAssertEqual(hunks.first?.newStart, 1)
        XCTAssertEqual(hunks.first?.newCount, 2)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.removed, .context, .context])
        XCTAssertEqual(hunks.first?.lines.first?.text, "a")
    }

    func testADeletionInTheMiddle() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\nd\ne\n", new: "a\nb\nd\ne\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldCount, 5)
        XCTAssertEqual(hunks.first?.newCount, 4)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.context, .context, .removed, .context, .context])
    }

    func testADeletionAtTheEnd() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\n", new: "a\nb\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldCount, 3)
        XCTAssertEqual(hunks.first?.newCount, 2)
        XCTAssertEqual(hunks.first?.lines.last?.kind, .removed)
        XCTAssertEqual(hunks.first?.lines.last?.text, "c")
    }

    // MARK: - Empty files

    func testAnEmptyOldFileIsAllAdded() {
        let hunks = DiffEngine.diff(old: "", new: "a\nb\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 0)
        XCTAssertEqual(hunks.first?.oldCount, 0)
        XCTAssertEqual(hunks.first?.newStart, 1)
        XCTAssertEqual(hunks.first?.newCount, 2)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.added, .added])
    }

    func testAnEmptyNewFileIsAllRemoved() {
        let hunks = DiffEngine.diff(old: "a\nb\n", new: "")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 1)
        XCTAssertEqual(hunks.first?.oldCount, 2)
        XCTAssertEqual(hunks.first?.newStart, 0)
        XCTAssertEqual(hunks.first?.newCount, 0)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.removed, .removed])
    }

    func testTwoEmptyFilesHaveNoHunks() {
        XCTAssertTrue(DiffEngine.diff(old: "", new: "").isEmpty)
    }

    // MARK: - Line endings

    func testCarriageReturnsDoNotMakeAChange() {
        XCTAssertTrue(DiffEngine.diff(old: "a\r\nb\r\nc\r\n", new: "a\nb\nc\n").isEmpty)
    }

    func testAChangeInAFileWithCarriageReturnsIsFound() {
        let hunks = DiffEngine.diff(old: "a\r\nb\r\nc\r\n", new: "a\r\nB\r\nc\r\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(hunks.first?.lines.map(\.text), ["a", "b", "B", "c"])
    }

    func testAFileWithoutATrailingNewlineHoldsTheSameLines() {
        XCTAssertTrue(DiffEngine.diff(old: "a\nb", new: "a\nb\n").isEmpty)
    }

    func testAChangeInAFileWithoutATrailingNewlineIsFound() {
        let hunks = DiffEngine.diff(old: "a\nb", new: "a\nc")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 1)
        XCTAssertEqual(hunks.first?.newStart, 1)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(hunks.first?.lines.map(\.text), ["a", "b", "c"])
    }

    // MARK: - Many changes

    func testManyChangesFarApartMakeManyHunks() {
        let old = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<40).map { $0 == 10 || $0 == 30 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"

        let hunks = DiffEngine.diff(old: old, new: new)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks.first?.oldStart, 8)
        XCTAssertEqual(hunks.first?.oldCount, 7)
        XCTAssertEqual(hunks.last?.oldStart, 28)
        XCTAssertEqual(hunks.last?.oldCount, 7)
    }

    func testChangesThatAreCloseMakeOneHunk() {
        let old = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<40).map { $0 == 10 || $0 == 12 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"

        XCTAssertEqual(DiffEngine.diff(old: old, new: new).count, 1)
    }

    // MARK: - Text that is not plain ASCII

    func testEmojiLinesAreCompared() {
        XCTAssertTrue(DiffEngine.diff(old: "🎉 party\n", new: "🎉 party\n").isEmpty)
    }

    func testAChangedEmojiLineIsFound() {
        let hunks = DiffEngine.diff(old: "🎉 party\n", new: "🎊 party\n")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.removed, .added])
        XCTAssertEqual(hunks.first?.lines.map(\.text), ["🎉 party", "🎊 party"])
    }

    func testALongLineIsCompared() {
        let long = String(repeating: "a", count: 20_000)
        XCTAssertTrue(DiffEngine.diff(old: long + "\n", new: long + "\n").isEmpty)

        let hunks = DiffEngine.diff(old: long + "\n", new: long + "b\n")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.removed, .added])
    }

    // MARK: - The same result every time

    func testTheSameInputAlwaysMakesTheSameHunks() {
        let old = (0..<200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<200).map { $0 % 7 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"

        let first = DiffEngine.diff(old: old, new: new)
        for _ in 0..<5 {
            XCTAssertEqual(DiffEngine.diff(old: old, new: new), first)
        }
    }

    // MARK: - Big files

    func testAFileWithFiveThousandLinesIsDiffedQuickly() {
        let old = (0..<5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<5000).map { $0 == 2500 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"

        let start = Date()
        let hunks = DiffEngine.diff(old: old, new: new)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2, "the diff of 5000 lines must not take long")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks.first?.oldStart, 2498)
        XCTAssertEqual(hunks.first?.oldCount, 7)
        XCTAssertEqual(hunks.first?.lines.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(hunks.first?.lines.first(where: { $0.kind == .added })?.text, "changed 2500")
    }

    func testTwoVeryDifferentBigFilesAreDiffedQuickly() {
        let old = (0..<3000).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let new = (0..<3000).map { "new \($0)" }.joined(separator: "\n") + "\n"

        let start = Date()
        let hunks = DiffEngine.diff(old: old, new: new)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2, "the diff of two very different files must not take long")
        XCTAssertEqual(hunks.count, 1)
    }

    // MARK: - The summary

    func testTheSummaryCountsTheChangedLines() {
        let hunks = DiffEngine.diff(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")

        XCTAssertEqual(DiffEngine.summary(for: hunks), "3 lines changed, 2 added, 1 removed")
    }

    func testTheSummaryOfAnUnchangedFile() {
        XCTAssertEqual(DiffEngine.summary(for: []), "No changes")
    }
}
