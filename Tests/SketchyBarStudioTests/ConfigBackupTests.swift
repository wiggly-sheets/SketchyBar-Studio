import Foundation
@testable import SketchyBarStudio
import XCTest

final class ConfigBackupTests: XCTestCase {
    func testBackupMirrorsRelativePathUnderBackupsFolder() throws {
        let root = try makeConfigRoot()
        let fileURL = root
            .appendingPathComponent("items")
            .appendingPathComponent("left")
            .appendingPathComponent("battery.lua")
        try write("battery_width = 42\n", to: fileURL)

        let backupURL = try ConfigBackupService().backup(fileURL: fileURL, rootURL: root)

        XCTAssertEqual(
            backupURL.path,
            root.appendingPathComponent("backups/items/left/battery.lua").path
        )
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "battery_width = 42\n")
    }

    func testConfigLocatorSkipsMirroredBackupsFolder() throws {
        let root = try makeConfigRoot()
        let itemURL = root.appendingPathComponent("items/left/battery.lua")
        let backupURL = root.appendingPathComponent("backups/items/left/battery.lua")
        try write("battery_width = 42\n", to: itemURL)
        try write("battery_width = 10\n", to: backupURL)

        let files = SketchyBarConfigLocator().configFiles(in: root)

        XCTAssertEqual(files.map { $0.standardizedFileURL.path }, [itemURL.standardizedFileURL.path])
    }

    func testActivationLookupScansEntrypointsOnceAndFindsActiveAndInactiveItems() throws {
        let root = try makeConfigRoot()
        let batteryURL = root.appendingPathComponent("items/battery.lua")
        let clockURL = root.appendingPathComponent("items/clock.lua")
        try write("width = 42\n", to: batteryURL)
        try write("width = 10\n", to: clockURL)
        try write("require(\"items.battery\")\n-- require(\"items.clock\")\n", to: root.appendingPathComponent("init.lua"))

        let references = ConfigActivationService().references(for: [batteryURL, clockURL], rootURL: root)

        XCTAssertEqual(references[batteryURL.path]?.lineNumber, 1)
        XCTAssertEqual(references[batteryURL.path]?.isActive, true)
        XCTAssertEqual(references[clockURL.path]?.lineNumber, 2)
        XCTAssertEqual(references[clockURL.path]?.isActive, false)
    }


    func testActivationLookupPrefersLongestMatchingToken() throws {
        let root = try makeConfigRoot()
        let spaceURL = root.appendingPathComponent("items/space.lua")
        let spacesURL = root.appendingPathComponent("items/spaces.lua")
        try write("width = 42\n", to: spaceURL)
        try write("width = 10\n", to: spacesURL)
        try write("require(\"items.spaces\")\nrequire(\"items.space\")\n", to: root.appendingPathComponent("init.lua"))

        let references = ConfigActivationService().references(for: [spaceURL, spacesURL], rootURL: root)

        XCTAssertEqual(references[spacesURL.path]?.lineNumber, 1)
        XCTAssertEqual(references[spaceURL.path]?.lineNumber, 2)
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
