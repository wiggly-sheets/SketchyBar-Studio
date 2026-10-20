import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the save review.
///
/// The review must never say that nothing changed when the file did change.
/// A change that holds no changed line, such as a trailing newline that was
/// added, is held by the note of the difference.
final class SaveReviewAccuracyTests: XCTestCase {

    // MARK: - The difference

    func testATrailingNewlineHoldsANoteAndNoHunk() {
        let difference = DiffEngine.difference(old: "a\nb", new: "a\nb\n")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertEqual(difference.note, "Only the trailing newline changed.")
    }

    func testOtherLineEndingsHoldANoteAndNoHunk() {
        let difference = DiffEngine.difference(old: "a\r\nb", new: "a\nb")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertEqual(difference.note, "Only the line endings changed.")
    }

    func testEqualTextsHoldNoHunkAndNoNote() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nb\n")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertNil(difference.note)
    }

    func testChangedLinesHoldHunksAndNoNote() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nc\n")

        XCTAssertFalse(difference.hunks.isEmpty)
        XCTAssertNil(difference.note)
    }

    // MARK: - The summary

    func testTheSummaryOfATrailingNewlineIsTheNote() {
        let difference = DiffEngine.difference(old: "a\nb", new: "a\nb\n")

        XCTAssertEqual(DiffEngine.summary(for: difference), "Only the trailing newline changed.")
    }

    func testTheSummaryOfOtherLineEndingsIsTheNote() {
        let difference = DiffEngine.difference(old: "a\r\nb", new: "a\nb")

        XCTAssertEqual(DiffEngine.summary(for: difference), "Only the line endings changed.")
    }

    func testTheSummaryOfEqualTextsIsNoChanges() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nb\n")

        XCTAssertEqual(DiffEngine.summary(for: difference), "No changes")
    }

    // MARK: - The content of the sheet

    func testTheSheetShowsTheNoteOfATrailingNewline() {
        let difference = DiffEngine.difference(old: "a\nb", new: "a\nb\n")

        XCTAssertEqual(
            SaveReviewView.content(for: difference),
            .note("Only the trailing newline changed.")
        )
    }

    func testTheSheetShowsTheNoteOfOtherLineEndings() {
        let difference = DiffEngine.difference(old: "a\r\nb", new: "a\nb")

        XCTAssertEqual(
            SaveReviewView.content(for: difference),
            .note("Only the line endings changed.")
        )
    }

    func testTheSheetShowsTheEmptyStateForEqualTexts() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nb\n")

        XCTAssertEqual(SaveReviewView.content(for: difference), .noChanges)
    }

    func testTheSheetShowsTheChangedLines() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nc\n")

        XCTAssertEqual(SaveReviewView.content(for: difference), .changes)
    }
}
