import Foundation
@testable import SketchyBarStudio
import XCTest

final class ConfigValidatorTests: XCTestCase {
    func testUnknownOptionInAnItemIsAWarning() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tpositon = \"left\",\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let unknown = diagnostics.filter { $0.kind == .unknownOption }
        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(unknown.first?.severity, .warning)
        XCTAssertEqual(unknown.first?.keyPath, "positon")
        XCTAssertEqual(unknown.first?.line, 2)
        XCTAssertEqual(unknown.first?.fileURL?.lastPathComponent, "clock.lua")
    }

    func testUnknownKeyInAThemeTableIsNotReported() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/left/clock\")\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", { position = \"left\" })\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )
        try write(
            "return {\n\tmy_own_color = \"0xffff0000\",\n\tanother_name = 12,\n}\n",
            to: root.appendingPathComponent("themes/colors.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .unknownOption }.isEmpty)
    }

    func testInvalidValueOfAKnownOptionIsAnError() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"middle\",\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let invalid = diagnostics.filter { $0.kind == .invalidValue }
        XCTAssertEqual(invalid.count, 1)
        XCTAssertEqual(invalid.first?.severity, .error)
        XCTAssertEqual(invalid.first?.keyPath, "position")
        XCTAssertEqual(invalid.first?.line, 2)
        XCTAssertEqual(invalid.first?.title, "Invalid value 'middle' for 'position'")
    }

    func testValueThatSketchyBarReadsFromTheFirstLetterIsAccepted() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"l\",\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .invalidValue }.isEmpty)
    }

    func testDuplicateAliasIsReportedOnceWithBothLocations() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", { position = \"left\" })\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", { position = \"right\" })\n",
            to: root.appendingPathComponent("items/right/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let duplicates = diagnostics.filter { $0.kind == .duplicateAlias }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.severity, .error)
        XCTAssertEqual(duplicates.first?.keyPath, "clock")
        let detail = duplicates.first?.detail ?? ""
        XCTAssertTrue(detail.contains("items/left/clock.lua:1"), detail)
        XCTAssertTrue(detail.contains("items/right/clock.lua:1"), detail)
    }

    func testMissingRequireTargetIsReportedWithTheLine() throws {
        let root = try makeConfigRoot()
        try write(
            "-- items\nrequire(\"nope\")\n",
            to: root.appendingPathComponent("init.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let missing = diagnostics.filter { $0.kind == .missingTarget }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.severity, .error)
        XCTAssertEqual(missing.first?.line, 2)
        XCTAssertEqual(missing.first?.keyPath, "nope")
    }

    func testFileThatNothingLoadsIsAnOrphan() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/left/clock\")\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", { position = \"left\" })\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )
        try write(
            "return {}\n",
            to: root.appendingPathComponent("items/left/dead.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let orphans = diagnostics.filter { $0.kind == .orphanFile }
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.severity, .info)
        XCTAssertEqual(orphans.first?.fileURL?.lastPathComponent, "dead.lua")
    }

    func testUnbalancedBraceIsReported() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"left\",\n)\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let unbalanced = diagnostics.filter { $0.kind == .unbalancedTable }
        XCTAssertEqual(unbalanced.count, 1)
        XCTAssertEqual(unbalanced.first?.severity, .error)
        XCTAssertEqual(unbalanced.first?.fileURL?.lastPathComponent, "clock.lua")
    }

    func testBracesInsideAStringOrACommentAreNotReported() throws {
        let root = try makeConfigRoot()
        try write(
            "-- a comment with { and }\nsbar.add(\"item\", \"clock\", {\n\tlabel = { string = \"a { b } c\" },\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .unbalancedTable }.isEmpty)
    }

    func testItemFileWithoutAnItemIsReported() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/left/empty\")\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write(
            "return {}\n",
            to: root.appendingPathComponent("items/left/empty.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let empty = diagnostics.filter { $0.kind == .noItemDeclaration }
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty.first?.severity, .info)
        XCTAssertEqual(empty.first?.fileURL?.lastPathComponent, "empty.lua")
    }

    func testSameOptionTwiceInOneItemIsReported() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"left\",\n\tposition = \"right\",\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let duplicates = diagnostics.filter { $0.kind == .duplicateKey }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.severity, .warning)
        XCTAssertEqual(duplicates.first?.keyPath, "position")
        XCTAssertEqual(duplicates.first?.line, 3)
    }

    func testCleanConfigHasNoDiagnostics() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/left/clock\")\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"left\",\n\ticon = { string = \"C\", font = { size = 12 } },\n\tlabel = { string = \"C\" },\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertEqual(diagnostics.map { $0.title }, [])
    }

    func testTheReportIsTheSameInEveryRun() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/left/clock\")\nrequire(\"nope\")\n",
            to: root.appendingPathComponent("init.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tpositon = \"left\",\n\tposition = \"middle\",\n})\n",
            to: root.appendingPathComponent("items/left/clock.lua")
        )

        let first = ConfigValidator().validate(rootURL: root)
        let second = ConfigValidator().validate(rootURL: root)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map { $0.id }, second.map { $0.id })
    }

    func testAFiveHundredFileConfigIsAnalyzedQuickly() throws {
        let root = try makeConfigRoot()
        let items = root.appendingPathComponent("items")
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        for index in 0..<499 {
            try write(
                "sbar.add(\"item\", \"item\(index)\", { position = \"right\" })\n",
                to: items.appendingPathComponent("item\(index).lua")
            )
        }
        try write("require(\"items/item0\")\n", to: root.appendingPathComponent("init.lua"))

        let start = Date()
        let diagnostics = ConfigValidator().validate(rootURL: root)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(diagnostics.filter { $0.kind == .orphanFile }.count, 498)
        XCTAssertLessThan(elapsed, 5.0, "Analyzing 500 files took \(elapsed) seconds")
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioTests")
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
