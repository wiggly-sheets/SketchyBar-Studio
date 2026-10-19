import Foundation
@testable import SketchyBarStudio
import XCTest

final class ConfigGraphTests: XCTestCase {
    func testReachableChainIsReachableAndHasNoOrphans() throws {
        let root = try makeConfigRoot()
        try write("require(\"items/left/clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("require(\"helpers/icons\")\n", to: root.appendingPathComponent("items/left/clock.lua"))
        try write("return {}\n", to: root.appendingPathComponent("helpers/icons.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(
            report.reachableFiles.map { $0.lastPathComponent }.sorted(),
            ["clock.lua", "icons.lua", "init.lua"]
        )
        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
        XCTAssertTrue(report.cycles.isEmpty)
    }

    func testFileNothingLoadsIsAnOrphan() throws {
        let root = try makeConfigRoot()
        try write("require(\"items/left/clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/dead.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(report.orphanFiles.map { $0.lastPathComponent }, ["dead.lua"])
    }

    func testMissingTargetIsReportedWithTheLineNumber() throws {
        let root = try makeConfigRoot()
        try write(
            "-- items\nrequire(\"items/left/gone\")\n",
            to: root.appendingPathComponent("init.lua")
        )

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(report.missingTargets.count, 1)
        XCTAssertEqual(report.missingTargets.first?.from.lastPathComponent, "init.lua")
        XCTAssertEqual(report.missingTargets.first?.line, 2)
        XCTAssertEqual(report.missingTargets.first?.target, "items/left/gone")
    }

    func testBareNameDoesNotReachANestedFile() throws {
        let root = try makeConfigRoot()
        try write("require(\"clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(report.orphanFiles.map { $0.lastPathComponent }, ["clock.lua"])
        XCTAssertEqual(report.missingTargets.map(\.target), ["clock"])
    }

    func testSlashNameReachesANestedFile() throws {
        let root = try makeConfigRoot()
        try write("require(\"items/left/clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testDottedNameReachesANestedFile() throws {
        let root = try makeConfigRoot()
        try write("require(\"items.left.clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testBareNameReachesAFileInTheConfigRoot() throws {
        let root = try makeConfigRoot()
        try write("require(\"clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testRequireCycleIsReportedOnce() throws {
        let root = try makeConfigRoot()
        try write("require(\"a\")\n", to: root.appendingPathComponent("init.lua"))
        try write("require(\"b\")\n", to: root.appendingPathComponent("a.lua"))
        try write("require(\"a\")\n", to: root.appendingPathComponent("b.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(report.cycles.count, 1)
        XCTAssertEqual(report.cycles.first?.map { $0.lastPathComponent }.sorted(), ["a.lua", "b.lua"])
    }

    func testBackupsAndHiddenFilesAreNotOrphans() throws {
        let root = try makeConfigRoot()
        try write("return {}\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("backups/old.lua"))
        try write("return {}\n", to: root.appendingPathComponent("backups/.sketchybar-studio/old.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/backups/old.lua"))
        try write("return {}\n", to: root.appendingPathComponent(".hidden.lua"))
        try write("return {}\n", to: root.appendingPathComponent(".hidden/item.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
    }

    func testModuleFolderWithAnInitFileIsReached() throws {
        let root = try makeConfigRoot()
        try write("require(\"items\")\n", to: root.appendingPathComponent("init.lua"))
        try write("require(\"items.left.clock\")\n", to: root.appendingPathComponent("items/init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testModuleThatSketchyBarBringsItselfIsNotAMissingTarget() throws {
        let root = try makeConfigRoot()
        try write("sbar = require(\"sketchybar\")\n", to: root.appendingPathComponent("init.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testModuleListInASetupTableIsReached() throws {
        let root = try makeConfigRoot()
        try write("require(\"setups\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return { items = { \"items.left.clock\" } }\n", to: root.appendingPathComponent("setups.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
    }

    func testRequireWithAComputedNameIsReportedAsDynamic() throws {
        let root = try makeConfigRoot()
        try write("require(\"items\")\n", to: root.appendingPathComponent("init.lua"))
        try write("for _, module in ipairs(items) do require(module) end\n", to: root.appendingPathComponent("items/init.lua"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertEqual(report.dynamicRequireFiles.map { $0.lastPathComponent }, ["init.lua"])
    }

    func testShellLoaderLineIsFollowed() throws {
        let root = try makeConfigRoot()
        try write("source items/left/clock.sh\n", to: root.appendingPathComponent("init.sh"))
        try write("echo hi\n", to: root.appendingPathComponent("items/left/clock.sh"))

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
    }

    func testEmptyDirectoryProducesAnEmptyReport() throws {        let root = try makeConfigRoot()

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.entrypoints.isEmpty)
        XCTAssertTrue(report.edges.isEmpty)
        XCTAssertTrue(report.reachableFiles.isEmpty)
        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertTrue(report.missingTargets.isEmpty)
        XCTAssertTrue(report.cycles.isEmpty)
    }

    func testSymlinkedFileIsReadOnlyOnce() throws {
        let root = try makeConfigRoot()
        try write("require(\"alias\")\nrequire(\"items/left/clock\")\n", to: root.appendingPathComponent("init.lua"))
        try write("return {}\n", to: root.appendingPathComponent("items/left/clock.lua"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.lua"),
            withDestinationURL: root.appendingPathComponent("items/left/clock.lua")
        )

        let report = ConfigGraphService().report(for: root)

        XCTAssertTrue(report.orphanFiles.isEmpty)
        XCTAssertEqual(report.reachableFiles.count, 2)
    }

    func testAThousandFilesAreAnalyzedQuickly() throws {
        let root = try makeConfigRoot()
        let items = root.appendingPathComponent("items")
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        for index in 0..<999 {
            try write("return {}\n", to: items.appendingPathComponent("item\(index).lua"))
        }
        try write("require(\"items/item0\")\n", to: root.appendingPathComponent("init.lua"))

        let start = Date()
        let report = ConfigGraphService().report(for: root)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(report.orphanFiles.count, 998)
        XCTAssertLessThan(elapsed, 2.0, "Analyzing 1000 files took \(elapsed) seconds")
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
