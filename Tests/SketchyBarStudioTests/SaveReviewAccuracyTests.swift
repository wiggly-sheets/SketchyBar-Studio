import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the save review.
///
/// The review must never say that nothing changed when the file did change.
/// A change that holds no changed line, such as a trailing newline that was
/// added, is held by the note of the difference.
final class SaveReviewAccuracyTests: XCTestCase {
    /// A change without a hunk is held by the note, and the note is what the
    /// summary and the sheet show.
    func testANoteReachesTheSummaryAndTheSheet() {
        let cases = [
            ("a\nb", "a\nb\n", "Only the trailing newline changed."),
            ("a\r\nb", "a\nb", "Only the line endings changed.")
        ]
        for (old, new, note) in cases {
            let difference = DiffEngine.difference(old: old, new: new)

            XCTAssertTrue(difference.hunks.isEmpty)
            XCTAssertEqual(difference.note, note)
            XCTAssertEqual(DiffEngine.summary(for: difference), note)
            XCTAssertEqual(SaveReviewView.content(for: difference), .note(note))
        }
    }

    /// Equal texts hold no hunk, no note, and the empty state of the sheet.
    func testEqualTextsHoldNoDifference() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nb\n")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertNil(difference.note)
        XCTAssertEqual(DiffEngine.summary(for: difference), "No changes")
        XCTAssertEqual(SaveReviewView.content(for: difference), .noChanges)
    }

    /// A changed line holds a hunk, no note, and the sheet shows the change.
    func testAChangedLineHoldsAHunk() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nc\n")

        XCTAssertFalse(difference.hunks.isEmpty)
        XCTAssertNil(difference.note)
        XCTAssertEqual(SaveReviewView.content(for: difference), .changes)
    }
}
