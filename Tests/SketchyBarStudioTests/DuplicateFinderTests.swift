import Foundation
@testable import SketchyBarStudio
import XCTest

final class DuplicateFinderTests: XCTestCase {
    func testTwoFilesWithTheSameKeysAndValuesAreReportedWithAHighScore() throws {
        let root = try makeConfigRoot()
        try write(
            itemFile(alias: "battery", icon: "battery"),
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            itemFile(alias: "power", icon: "battery"),
            to: root.appendingPathComponent("items/right/power.lua")
        )

        let pairs = DuplicateFinder().findDuplicates(in: root, threshold: 0.8)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.first.relativePath, "items/right/battery.lua")
        XCTAssertEqual(pairs.first?.second.relativePath, "items/right/power.lua")
        XCTAssertEqual(pairs.first?.score ?? 0, 1.0, accuracy: 0.001)
        XCTAssertTrue(pairs.first?.differingValues.isEmpty ?? false)
        XCTAssertEqual(pairs.first?.first.alias, "battery")
        XCTAssertEqual(pairs.first?.second.alias, "power")
    }

    func testFilesWithTheSameKeysAndDifferentValuesAreReportedWithTheDifferences() throws {
        let root = try makeConfigRoot()
        try write(
            twoKeyFile(alias: "battery", icon: "battery"),
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            twoKeyFile(alias: "power", icon: "power"),
            to: root.appendingPathComponent("items/right/power.lua")
        )

        let pairs = DuplicateFinder().findDuplicates(in: root, threshold: 0.7)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.score ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(pairs.first?.differingValues ?? [], ["icon.string"])
        XCTAssertEqual(pairs.first?.sharedKeys ?? [], ["icon.string", "position"])
        XCTAssertTrue(pairs.first?.onlyInFirst.isEmpty ?? false)
        XCTAssertTrue(pairs.first?.onlyInSecond.isEmpty ?? false)
    }

    func testUnrelatedFilesAreNotReported() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"battery\", {\n\tposition = \"right\",\n\ticon = { string = \"battery\" },\n})\n",
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tlabel = { string = \"12:00\" },\n\tupdate_freq = 10,\n})\n",
            to: root.appendingPathComponent("items/right/clock.lua")
        )

        let pairs = DuplicateFinder().findDuplicates(in: root, threshold: 0.5)

        XCTAssertTrue(pairs.isEmpty)
    }

    func testAFileWithoutAnItemIsIgnored() throws {
        let root = try makeConfigRoot()
        try write(
            "require(\"items/right/battery\")\n",
            to: root.appendingPathComponent("items/right/init.lua")
        )
        try write(
            "return { red = \"0xffff0000\" }\n",
            to: root.appendingPathComponent("themes/colors.lua")
        )

        let signatures = DuplicateFinder().signatures(in: root)

        XCTAssertTrue(signatures.isEmpty)
    }

    func testTheScoreIsTheSameWhenTheTwoFilesChangePlaces() throws {
        let first = try makeConfigRoot()
        let second = try makeConfigRoot()

        try write(
            twoKeyFile(alias: "battery", icon: "battery"),
            to: first.appendingPathComponent("items/right/a.lua")
        )
        try write(
            twoKeyFile(alias: "power", icon: "power"),
            to: first.appendingPathComponent("items/right/b.lua")
        )
        try write(
            twoKeyFile(alias: "power", icon: "power"),
            to: second.appendingPathComponent("items/right/a.lua")
        )
        try write(
            twoKeyFile(alias: "battery", icon: "battery"),
            to: second.appendingPathComponent("items/right/b.lua")
        )

        let firstScore = DuplicateFinder().findDuplicates(in: first, threshold: 0.5).first?.score
        let secondScore = DuplicateFinder().findDuplicates(in: second, threshold: 0.5).first?.score

        XCTAssertNotNil(firstScore)
        XCTAssertEqual(firstScore ?? 0, secondScore ?? 0, accuracy: 0.0001)
    }

    func testAPairIsOnlyReportedOnce() throws {
        let root = try makeConfigRoot()
        try write(
            itemFile(alias: "battery", icon: "battery"),
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            itemFile(alias: "power", icon: "battery"),
            to: root.appendingPathComponent("items/right/power.lua")
        )

        let pairs = DuplicateFinder().findDuplicates(in: root, threshold: 0.8)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(Set(pairs.map(\.id)).count, pairs.count)
    }

    func testBackupsAndHiddenFilesAreNotRead() throws {
        let root = try makeConfigRoot()
        try write(
            itemFile(alias: "battery", icon: "battery"),
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            itemFile(alias: "power", icon: "battery"),
            to: root.appendingPathComponent("backups/.sketchybar-studio/items/right/battery.lua")
        )
        try write(
            itemFile(alias: "power", icon: "battery"),
            to: root.appendingPathComponent(".hidden/secret.lua")
        )
        try write(
            itemFile(alias: "power", icon: "battery"),
            to: root.appendingPathComponent("items/right/.secret.lua")
        )

        let signatures = DuplicateFinder().signatures(in: root)

        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(signatures.first?.relativePath, "items/right/battery.lua")
        XCTAssertTrue(DuplicateFinder().findDuplicates(in: root, threshold: 0.8).isEmpty)
    }

    func testAnEmptyDirectoryProducesNoPairs() throws {
        let root = try makeConfigRoot()

        let signatures = DuplicateFinder().signatures(in: root)
        let pairs = DuplicateFinder().findDuplicates(in: root, threshold: 0.8)

        XCTAssertTrue(signatures.isEmpty)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testAPairBelowTheThresholdIsNotReported() throws {
        let root = try makeConfigRoot()
        try write(
            twoKeyFile(alias: "battery", icon: "battery"),
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            twoKeyFile(alias: "power", icon: "power"),
            to: root.appendingPathComponent("items/right/power.lua")
        )

        XCTAssertTrue(DuplicateFinder().findDuplicates(in: root, threshold: 0.9).isEmpty)
        XCTAssertEqual(DuplicateFinder().findDuplicates(in: root, threshold: 0.75).count, 1)
    }

    func testAValueThatIsAnExpressionIsNotCompared() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"battery\", {\n\tposition = \"right\",\n\ticon = { color = colors.green },\n})\n",
            to: root.appendingPathComponent("items/right/battery.lua")
        )
        try write(
            "sbar.add(\"item\", \"power\", {\n\tposition = \"right\",\n\ticon = { color = colors.red },\n})\n",
            to: root.appendingPathComponent("items/right/power.lua")
        )

        let signatures = DuplicateFinder().signatures(in: root)

        XCTAssertEqual(signatures.count, 2)
        XCTAssertEqual(signatures.first?.properties.keys.sorted() ?? [], ["position"])
    }

    // MARK: - Helpers

    private func itemFile(alias: String, icon: String) -> String {
        "sbar.add(\"item\", \"\(alias)\", {\n"
            + "\tposition = \"right\",\n"
            + "\tpadding_left = 2,\n"
            + "\ticon = { string = \"\(icon)\", font = { size = 11 } },\n"
            + "})\n"
    }

    private func twoKeyFile(alias: String, icon: String) -> String {
        "sbar.add(\"item\", \"\(alias)\", {\n"
            + "\tposition = \"right\",\n"
            + "\ticon = { string = \"\(icon)\" },\n"
            + "})\n"
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
