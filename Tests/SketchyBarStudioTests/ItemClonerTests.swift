import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the pure cloner of item files.
final class ItemClonerTests: XCTestCase {
    private let cloner = ItemCloner()

    private let itemSource = """
    -- The clock of the bar.
    local clock = sbar.add("item", "clock", {
    \tposition = "right",
    \ticon = "sf.clock",
    \tlabel = "10:30",
    })
    """

    // MARK: - The alias

    func testTheAliasOfAnItemIsFound() {
        XCTAssertEqual(cloner.sourceAlias(in: itemSource), "clock")
    }

    func testAFileWithoutAnItemHasNoAlias() {
        let source = "local M = require(\"colors\")\nreturn M\n"
        XCTAssertNil(cloner.sourceAlias(in: source))
    }

    func testAnItemWithoutANameHasNoAlias() {
        let source = "local clock = sbar.add(\"item\", {\n\tposition = \"right\",\n})\n"
        XCTAssertNil(cloner.sourceAlias(in: source))
    }

    // MARK: - The contents of the copy

    func testOnlyTheAliasChanges() {
        let clone = cloner.clonedContents(of: itemSource, newAlias: "clock-copy")

        XCTAssertTrue(clone.contains("\"clock-copy\""))
        // Putting the old alias back gives the source file byte for byte.
        XCTAssertEqual(clone.replacingOccurrences(of: "\"clock-copy\"", with: "\"clock\""), itemSource)
        // Without the alias both files are the same.
        XCTAssertEqual(
            clone.replacingOccurrences(of: "\"clock-copy\"", with: ""),
            itemSource.replacingOccurrences(of: "\"clock\"", with: "")
        )
    }

    func testTheVariableNameOfTheItemStaysTheSame() {
        let clone = cloner.clonedContents(of: itemSource, newAlias: "clock-copy")
        XCTAssertTrue(clone.contains("local clock = sbar.add(\"item\", \"clock-copy\", {"))
    }

    func testOnlyTheFirstAliasIsReplaced() {
        let source = """
        local first = sbar.add("item", "first", {
        \tposition = "left",
        })
        local second = sbar.add("item", "second", {
        \tposition = "right",
        })
        """

        let clone = cloner.clonedContents(of: source, newAlias: "first-copy")

        XCTAssertTrue(clone.contains("\"first-copy\""))
        XCTAssertTrue(clone.contains("\"second\""))
        XCTAssertEqual(clone.replacingOccurrences(of: "\"first-copy\"", with: "\"first\""), source)
    }

    func testAnAliasInACommentIsNotReplaced() {
        let source = """
        -- the alias is "clock" in this comment
        local clock = sbar.add("item", "clock", {
        \tposition = "right",
        })
        """

        let clone = cloner.clonedContents(of: source, newAlias: "clock-copy")

        XCTAssertTrue(clone.contains("-- the alias is \"clock\" in this comment"))
        XCTAssertTrue(clone.contains("\"clock-copy\""))
    }

    func testASingleQuotedAliasKeepsItsQuotes() {
        let source = "local clock = sbar.add('item', 'clock', {\n\tposition = \"right\",\n})\n"

        let clone = cloner.clonedContents(of: source, newAlias: "clock-copy")

        XCTAssertTrue(clone.contains("'clock-copy'"))
    }

    func testAFileWithoutAnItemComesBackUnchanged() {
        let source = "local M = {}\nreturn M\n"
        XCTAssertEqual(cloner.clonedContents(of: source, newAlias: "copy"), source)
    }

    // MARK: - The path of the copy

    func testTheFolderAndTheExtensionOfTheSourceAreKept() {
        XCTAssertEqual(
            cloner.copyPath(for: "items/right/clock.lua", newName: "clock-utc"),
            "items/right/clock-utc.lua"
        )
        XCTAssertEqual(
            cloner.copyPath(for: "clock.lua", newName: "clock-utc"),
            "clock-utc.lua"
        )
    }

    func testAnUnsafeNameIsRejected() {
        XCTAssertEqual(cloner.copyPath(for: "items/right/clock.lua", newName: "../evil"), "")
        XCTAssertEqual(cloner.copyPath(for: "items/right/clock.lua", newName: "items/evil"), "")
        XCTAssertEqual(cloner.copyPath(for: "items/right/clock.lua", newName: "clock copy"), "")
        XCTAssertEqual(cloner.copyPath(for: "items/right/clock.lua", newName: ".hidden"), "")
        XCTAssertEqual(cloner.copyPath(for: "items/right/clock.lua", newName: ""), "")
    }
}
