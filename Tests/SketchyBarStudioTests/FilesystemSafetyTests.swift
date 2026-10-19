import Foundation
@testable import SketchyBarStudio
import XCTest

final class FilesystemSafetyTests: XCTestCase {
    func testConfigLocatorDiscoversFilesThroughSymlinkedRoot() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("configs/current")
        let linkedRoot = testRoot.appendingPathComponent("live/sketchybar")
        let itemURL = configRoot.appendingPathComponent("items/battery.lua")
        try write("return {}\n", to: itemURL)
        try FileManager.default.createDirectory(
            at: linkedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: configRoot)

        let files = SketchyBarConfigLocator().configFiles(in: linkedRoot)

        XCTAssertEqual(files.map(\.path), [linkedRoot.appendingPathComponent("items/battery.lua").path])
    }

    func testConfigLocatorDiscoversHiddenSketchybarEntrypoint() throws {
        let configRoot = try makeTestRoot()
        let entrypoint = configRoot.appendingPathComponent(".sketchybarrc")
        try write("sketchybar --bar height=32\n", to: entrypoint)

        let files = SketchyBarConfigLocator().configFiles(in: configRoot)

        XCTAssertEqual(files.map(\.path), [entrypoint.path])
    }

    func testConfigLocatorDoesNotRecurseIntoUnrelatedHiddenDirectories() throws {
        let configRoot = try makeTestRoot()
        let entrypoint = configRoot.appendingPathComponent(".sketchybarrc")
        try write("sketchybar --bar height=32\n", to: entrypoint)
        try write("ignored\n", to: configRoot.appendingPathComponent(".git/hooks/pre-commit.sh"))

        let files = SketchyBarConfigLocator().configFiles(in: configRoot)

        XCTAssertEqual(files.map(\.path), [entrypoint.path])
    }

    func testProfileNamesCannotEscapeProfileRoot() throws {
        for unsafeName in [".", ".."] {
            let testRoot = try makeTestRoot()
            let configRoot = testRoot.appendingPathComponent("source")
            try write("return {}\n", to: configRoot.appendingPathComponent("init.lua"))

            let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
            let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
            let profilesRoot = service.profilesRoot(for: "workspace")
            let siblingSentinel = profilesRoot.deletingLastPathComponent()
                .appendingPathComponent("another-workspace/keep.txt")
            try write("keep", to: siblingSentinel)

            XCTAssertThrowsError(
                try service.saveProfile(named: unsafeName, from: configRoot, configID: "workspace")
            )
            XCTAssertEqual(try String(contentsOf: siblingSentinel, encoding: .utf8), "keep")
        }
    }

    func testSavingProfileFromSymlinkCreatesIndependentSnapshot() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("configs/selected")
        let linkedRoot = testRoot.appendingPathComponent("live/sketchybar")
        let sourceFile = configRoot.appendingPathComponent("items/clock.lua")
        try write("original\n", to: sourceFile)
        try FileManager.default.createDirectory(
            at: linkedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: configRoot)

        let service = ProfileArchiveService(
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )
        try service.saveProfile(named: "Before changes", from: linkedRoot, configID: "workspace")
        let snapshotRoot = service.profilesRoot(for: "workspace")
            .appendingPathComponent("Before changes")

        try write("changed\n", to: sourceFile)

        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: snapshotRoot.path))
        XCTAssertEqual(
            try String(contentsOf: snapshotRoot.appendingPathComponent("items/clock.lua"), encoding: .utf8),
            "original\n"
        )
    }

    func testFailedProfileOverwritePreservesPreviousSnapshot() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let originalRoot = testRoot.appendingPathComponent("configs/original")
        let replacementRoot = testRoot.appendingPathComponent("configs/replacement")
        try write("original\n", to: originalRoot.appendingPathComponent("bar.lua"))
        try write("replacement\n", to: replacementRoot.appendingPathComponent("bar.lua"))
        let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
        try service.saveProfile(named: "Stable", from: originalRoot, configID: "workspace")

        let failingService = ProfileArchiveService(
            fileManager: ProfileCopyFailingFileManager(),
            appSupportRoot: appSupportRoot
        )
        XCTAssertThrowsError(
            try failingService.saveProfile(named: "Stable", from: replacementRoot, configID: "workspace")
        )

        let savedFile = service.profilesRoot(for: "workspace")
            .appendingPathComponent("Stable/bar.lua")
        XCTAssertEqual(try String(contentsOf: savedFile, encoding: .utf8), "original\n")
    }

    func testFailedProfileRestorePreservesLiveConfig() throws {
        let testRoot = try makeTestRoot()
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let liveFile = liveRoot.appendingPathComponent("bar.lua")
        try write("current\n", to: liveFile)
        let missingProfile = ConfigProfile(
            name: "Missing",
            url: testRoot.appendingPathComponent("profiles/missing"),
            createdAt: .now
        )
        let service = ProfileArchiveService(
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )

        XCTAssertThrowsError(try service.restore(profile: missingProfile, to: liveRoot))

        XCTAssertEqual(try String(contentsOf: liveFile, encoding: .utf8), "current\n")
        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix("sketchybar.before-studio-restore-") })
    }

    func testProfileRestoreThroughSymlinkPreservesLinkAndReplacesTargetContents() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let targetRoot = testRoot.appendingPathComponent("dotfiles/sketchybar")
        let linkedRoot = testRoot.appendingPathComponent("live/sketchybar")
        let profileRoot = testRoot.appendingPathComponent("profiles/selected")
        try write("current\n", to: targetRoot.appendingPathComponent("bar.lua"))
        try write("restored\n", to: profileRoot.appendingPathComponent("bar.lua"))
        try FileManager.default.createDirectory(
            at: linkedRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: targetRoot)

        let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
        try service.restore(
            profile: ConfigProfile(name: "Selected", url: profileRoot, createdAt: .now),
            to: linkedRoot
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkedRoot.path),
            targetRoot.path
        )
        XCTAssertEqual(
            try String(contentsOf: targetRoot.appendingPathComponent("bar.lua"), encoding: .utf8),
            "restored\n"
        )
        let targetSiblings = try FileManager.default.contentsOfDirectory(
            at: targetRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(targetSiblings.contains { $0.lastPathComponent.hasPrefix("sketchybar.before-studio-restore-") })

        let restores = try FileManager.default.contentsOfDirectory(
            at: appSupportRoot.appendingPathComponent("Restores"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(restores.count, 1)
        XCTAssertEqual(
            try String(contentsOf: restores[0].appendingPathComponent("sketchybar/bar.lua"), encoding: .utf8),
            "current\n"
        )
    }

    func testProfileRestoreRollsBackWhenStagedSnapshotCannotBeInstalled() throws {
        let testRoot = try makeTestRoot()
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let profileRoot = testRoot.appendingPathComponent("profiles/selected")
        let liveFile = liveRoot.appendingPathComponent("bar.lua")
        try write("current\n", to: liveFile)
        try write("restored\n", to: profileRoot.appendingPathComponent("bar.lua"))
        let service = ProfileArchiveService(
            fileManager: StagedRestoreMoveFailingFileManager(),
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )

        XCTAssertThrowsError(
            try service.restore(
                profile: ConfigProfile(name: "Selected", url: profileRoot, createdAt: .now),
                to: liveRoot
            )
        )

        XCTAssertEqual(try String(contentsOf: liveFile, encoding: .utf8), "current\n")
        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix("sketchybar.before-studio-restore-") })
    }

    func testConfigSwitchRejectsSourceNestedInsideLiveConfig() throws {
        let testRoot = try makeTestRoot()
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let liveFile = liveRoot.appendingPathComponent("bar.lua")
        let nestedSource = liveRoot.appendingPathComponent("profiles/alternate")
        let nestedFile = nestedSource.appendingPathComponent("init.lua")
        try write("current\n", to: liveFile)
        try write("alternate\n", to: nestedFile)

        let service = ConfigSwitchService(
            liveSketchyBarConfigURL: liveRoot,
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )
        let workspace = ConfigWorkspace.make(name: "Nested", url: nestedSource)

        XCTAssertThrowsError(try service.activate(config: workspace))
        XCTAssertEqual(try String(contentsOf: liveFile, encoding: .utf8), "current\n")
        XCTAssertEqual(try String(contentsOf: nestedFile, encoding: .utf8), "alternate\n")
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: liveRoot.path))
    }

    func testFailedConfigSwitchPreservesLiveConfig() throws {
        let testRoot = try makeTestRoot()
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let selectedRoot = testRoot.appendingPathComponent("configs/alternate")
        let liveFile = liveRoot.appendingPathComponent("bar.lua")
        try write("current\n", to: liveFile)
        try write("alternate\n", to: selectedRoot.appendingPathComponent("init.lua"))

        let service = ConfigSwitchService(
            fileManager: SymlinkCreationFailingFileManager(),
            liveSketchyBarConfigURL: liveRoot,
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )

        XCTAssertThrowsError(
            try service.activate(config: ConfigWorkspace.make(name: "Alternate", url: selectedRoot))
        )
        XCTAssertEqual(try String(contentsOf: liveFile, encoding: .utf8), "current\n")

        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix("sketchybar.before-studio-switch-") })
    }

    func testConfigSwitchActivatesSelectedConfigAndPreservesPreviousDirectory() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let selectedRoot = testRoot.appendingPathComponent("configs/alternate")
        try write("current\n", to: liveRoot.appendingPathComponent("bar.lua"))
        try write("alternate\n", to: selectedRoot.appendingPathComponent("init.lua"))
        let service = ConfigSwitchService(
            liveSketchyBarConfigURL: liveRoot,
            appSupportRoot: appSupportRoot
        )
        let workspace = ConfigWorkspace.make(name: "Alternate", url: selectedRoot)

        try service.activate(config: workspace)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: liveRoot.path),
            selectedRoot.path
        )
        XCTAssertTrue(service.isLive(config: workspace))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.hasPrefix("sketchybar.before-studio-switch-") })

        let restores = try FileManager.default.contentsOfDirectory(
            at: appSupportRoot.appendingPathComponent("Restores"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(restores.count, 1)
        XCTAssertEqual(
            try String(contentsOf: restores[0].appendingPathComponent("sketchybar/bar.lua"), encoding: .utf8),
            "current\n"
        )
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioFilesystemSafetyTests", isDirectory: true)
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

private final class SymlinkCreationFailingFileManager: FileManager, @unchecked Sendable {
    override func createSymbolicLink(at url: URL, withDestinationURL destURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class StagedRestoreMoveFailingFileManager: FileManager, @unchecked Sendable {
    private var hasFailedStagedMove = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !hasFailedStagedMove, srcURL.lastPathComponent.contains(".studio-restore-") {
            hasFailedStagedMove = true
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class ProfileCopyFailingFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
