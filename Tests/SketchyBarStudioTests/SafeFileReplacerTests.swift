import Foundation
@testable import SketchyBarStudio
import XCTest

final class SafeFileReplacerTests: XCTestCase {
    func testContainedChildRejectsDotComponents() throws {
        let root = try makeTestRoot()

        XCTAssertThrowsError(try SafeFileReplacer().containedChild(named: ".", of: root))
        XCTAssertThrowsError(try SafeFileReplacer().containedChild(named: "..", of: root))

        let child = try SafeFileReplacer().containedChild(named: "Profile", of: root)
        XCTAssertEqual(
            child.path,
            root.appendingPathComponent("Profile", isDirectory: true).standardizedFileURL.path
        )
    }

    func testInstallRollsBackWhenStagedMoveFails() throws {
        let replacer = SafeFileReplacer(fileManager: StagedInstallMoveFailingFileManager())
        let root = try makeTestRoot()
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        let originalFile = destination.appendingPathComponent("bar.lua")
        try write("original\n", to: originalFile)
        let staging = root.appendingPathComponent(".studio-test-\(UUID().uuidString)", isDirectory: true)
        try write("staged\n", to: staging.appendingPathComponent("bar.lua"))

        XCTAssertThrowsError(
            try replacer.install(
                stagedItem: staging,
                at: destination,
                keepDisplaced: false,
                displacedPrefix: ".rollback-"
            )
        )

        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), "original\n")
        let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix(".rollback-") })
    }

    func testInstallKeepsDisplacedItemWhenRequested() throws {
        let replacer = SafeFileReplacer()
        let root = try makeTestRoot()
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        try write("original\n", to: destination.appendingPathComponent("bar.lua"))
        let staging = root.appendingPathComponent(".staged-\(UUID().uuidString)", isDirectory: true)
        try write("staged\n", to: staging.appendingPathComponent("bar.lua"))

        try replacer.install(
            stagedItem: staging,
            at: destination,
            keepDisplaced: true,
            displacedPrefix: "backup-"
        )

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("bar.lua"), encoding: .utf8),
            "staged\n"
        )
        let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backups = siblings.filter { $0.lastPathComponent.hasPrefix("backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(
            try String(contentsOf: backups[0].appendingPathComponent("bar.lua"), encoding: .utf8),
            "original\n"
        )
    }

    func testInstallRemovesDisplacedItemWhenNotKept() throws {
        let replacer = SafeFileReplacer()
        let root = try makeTestRoot()
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        try write("original\n", to: destination.appendingPathComponent("bar.lua"))
        let staging = root.appendingPathComponent(".staged-\(UUID().uuidString)", isDirectory: true)
        try write("staged\n", to: staging.appendingPathComponent("bar.lua"))

        try replacer.install(
            stagedItem: staging,
            at: destination,
            keepDisplaced: false,
            displacedPrefix: "backup-"
        )

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("bar.lua"), encoding: .utf8),
            "staged\n"
        )
        let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix("backup-") })
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioSafeFileReplacerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class StagedInstallMoveFailingFileManager: FileManager, @unchecked Sendable {
    private var hasFailedStagedMove = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !hasFailedStagedMove, srcURL.lastPathComponent.contains(".studio-test-") {
            hasFailedStagedMove = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}