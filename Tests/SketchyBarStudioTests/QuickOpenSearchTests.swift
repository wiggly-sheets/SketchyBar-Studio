import Foundation
@testable import SketchyBarStudio
import XCTest

final class QuickOpenSearchTests: XCTestCase {
    // MARK: - Helpers

    private func value(
        _ keyPath: String,
        original: String,
        line: Int = 1
    ) -> LuaEditableValue {
        LuaEditableValue(
            id: "\(keyPath)-\(original)",
            fileURL: URL(fileURLWithPath: "/tmp/root/items/clock.lua"),
            keyPath: keyPath,
            lineNumber: line,
            kind: .string,
            originalValue: original,
            draftValue: original,
            suggestedValues: [],
            valueStartOffset: 0,
            valueEndOffset: 0,
            sourceSnapshot: ""
        )
    }

    private func file(_ relativePath: String, values: [LuaEditableValue] = []) -> ConfigFile {
        ConfigFile(
            url: URL(fileURLWithPath: "/tmp/root/\(relativePath)"),
            rootURL: URL(fileURLWithPath: "/tmp/root"),
            kind: .lua,
            values: values,
            activationReference: nil
        )
    }

    // MARK: - Query

    func testEmptyQueryReturnsNoResults() {
        let files = [
            file("items/right/clock.lua", values: [value("padding_left", original: "12")])
        ]

        XCTAssertTrue(QuickOpenSearch.search(query: "", in: files).isEmpty)
        XCTAssertTrue(QuickOpenSearch.search(query: "   ", in: files).isEmpty)
    }

    func testQueryThatMatchesNothingReturnsAnEmptyList() {
        let files = [
            file("items/right/clock.lua", values: [value("padding_left", original: "12")])
        ]

        XCTAssertTrue(QuickOpenSearch.search(query: "zzznothing", in: files).isEmpty)
    }

    // MARK: - Files

    func testFileNameIsFoundByAFuzzySubsequence() {
        let files = [
            file("items/right/clock.lua"),
            file("themes/dark.lua")
        ]

        let results = QuickOpenSearch.search(query: "iclk", in: files)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.kind, .file)
        XCTAssertEqual(results.first?.fileName, "items/right/clock.lua")
    }

    func testContiguousSubstringScoresHigherThanScatteredSubsequence() throws {
        let contiguous = try XCTUnwrap(QuickOpenSearch.fuzzyScore(query: "clock", candidate: "clock"))
        let scattered = try XCTUnwrap(QuickOpenSearch.fuzzyScore(query: "clock", candidate: "c_l_o_c_k"))

        XCTAssertGreaterThan(contiguous, scattered)
    }

    func testQueryThatIsNoSubsequenceDoesNotMatch() {
        XCTAssertNil(QuickOpenSearch.fuzzyScore(query: "clock", candidate: "clok"))
        XCTAssertNil(QuickOpenSearch.fuzzyScore(query: "", candidate: "clock"))
    }

    func testExactFileMatchComesBeforeAFuzzyMatch() {
        let files = [
            file("c_l_o_c_k.lua"),
            file("clock")
        ]

        let results = QuickOpenSearch.search(query: "clock", in: files)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.fileName, "clock")
        XCTAssertEqual(results.last?.fileName, "c_l_o_c_k.lua")
    }

    func testFileComesBeforeAValueWhenTheQueryLooksLikeAFileName() {
        let files = [
            file("items/right/clock.lua", values: [value("label", original: "clock.lua")]),
            file("themes/dark.lua")
        ]

        let results = QuickOpenSearch.search(query: "clock.lua", in: files)

        XCTAssertEqual(results.first?.kind, .file)
        XCTAssertEqual(results.first?.fileName, "items/right/clock.lua")
    }

    // MARK: - Values

    func testValueIsFoundInAFileThatIsNotTheSelectedOne() {
        let files = [
            file("items/left/clock.lua", values: [value("padding_left", original: "4")]),
            file("items/right/battery.lua", values: [value("padding_left", original: "12", line: 7)])
        ]

        let results = QuickOpenSearch.search(query: "padding_left", in: files)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains {
            $0.kind == .value &&
            $0.fileName == "items/right/battery.lua" &&
            $0.keyPath == "padding_left" &&
            $0.lineNumber == 7 &&
            $0.valueText == "12"
        })
    }

    func testKeyPathAndValueTextAreBothSearchable() {
        let files = [
            file("items/right/clock.lua", values: [value("padding_left", original: "12")])
        ]

        let byKeyPath = QuickOpenSearch.search(query: "padding_left", in: files)
        let byValueText = QuickOpenSearch.search(query: "12", in: files)

        XCTAssertEqual(byKeyPath.count, 1)
        XCTAssertEqual(byKeyPath.first?.kind, .value)
        XCTAssertEqual(byKeyPath.first?.keyPath, "padding_left")
        XCTAssertEqual(byValueText.count, 1)
        XCTAssertEqual(byValueText.first?.kind, .value)
        XCTAssertEqual(byValueText.first?.valueText, "12")
    }

    // MARK: - Order and limit

    func testResultsAreCappedAtTheLimitAndStayTheSame() {
        let files = (1...25).map { index in
            file("items/item\(index).lua", values: [value("padding_left", original: "\(index)", line: index)])
        }

        let first = QuickOpenSearch.search(query: "padding", in: files, limit: 5)
        let second = QuickOpenSearch.search(query: "padding", in: files, limit: 5)

        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(first, second)
    }

    func testValuesOfOneFileAreOrderedByLine() {
        let files = [
            file("items/right/clock.lua", values: [
                value("padding_left", original: "12", line: 9),
                value("padding_right", original: "8", line: 3)
            ])
        ]

        let results = QuickOpenSearch.search(query: "padding", in: files)

        XCTAssertEqual(results.map(\.lineNumber), [3, 9])
    }
}
