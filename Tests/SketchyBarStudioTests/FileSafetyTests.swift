import Foundation
@testable import SketchyBarStudio
import XCTest

final class FileSafetyTests: XCTestCase {
    // MARK: - Symlinked config files

    func testEditingSymlinkedConfigFileKeepsTheSymlinkAndUpdatesTheTarget() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("configs/current")
        let realFile = testRoot.appendingPathComponent("dotfiles/battery.lua")
        let linkedFile = configRoot.appendingPathComponent("battery.lua")
        try write("original\n", to: realFile)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: realFile)

        let file = ConfigFile(url: linkedFile, rootURL: configRoot, kind: .lua, values: [], activationReference: nil)
        var session = DocumentSession.loading(file)
        session.updateSourceContents("edited\n")
        try session.save(
            using: LuaConfigScanner(),
            shellScanner: ShellConfigScanner(),
            backupService: ConfigBackupService()
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkedFile.path),
            realFile.path
        )
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "edited\n")
    }

    func testBackupOfSymlinkedFileIsRegularFileWithPreEditContent() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("configs/current")
        let realFile = testRoot.appendingPathComponent("dotfiles/battery.lua")
        let linkedFile = configRoot.appendingPathComponent("battery.lua")
        try write("original\n", to: realFile)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: realFile)

        let backupURL = try ConfigBackupService().backup(fileURL: linkedFile, rootURL: configRoot)

        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: backupURL.path))
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "original\n")
    }

    // MARK: - Config switching

    func testConfigSwitchRejectsSourceNestedInsideSymlinkedLiveRoot() throws {
        let testRoot = try makeTestRoot()
        let liveTarget = testRoot.appendingPathComponent("dotfiles/sketchybar")
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let nestedSource = liveTarget.appendingPathComponent("profiles/alternate")
        try write("current\n", to: liveTarget.appendingPathComponent("bar.lua"))
        try write("alternate\n", to: nestedSource.appendingPathComponent("init.lua"))
        try FileManager.default.createDirectory(
            at: liveRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: liveRoot, withDestinationURL: liveTarget)

        let service = ConfigSwitchService(
            liveSketchyBarConfigURL: liveRoot,
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )

        XCTAssertThrowsError(
            try service.activate(config: ConfigWorkspace.make(name: "Nested", url: nestedSource))
        ) { error in
            guard case ConfigSwitchError.unsafeSource = error else {
                return XCTFail("Expected an unsafe-source error, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: liveRoot.path),
            liveTarget.path
        )
    }

    // MARK: - Loader matching

    func testBareRequireIsNotAttributedToNestedItem() throws {
        let testRoot = try makeTestRoot()
        let nestedItem = testRoot.appendingPathComponent("items/battery.lua")
        let rootItem = testRoot.appendingPathComponent("battery.lua")
        try write("drawing = true\n", to: nestedItem)
        try write("drawing = true\n", to: rootItem)
        try write("require(\"battery\")\n", to: testRoot.appendingPathComponent("init.lua"))

        let references = ConfigActivationService().references(
            for: [nestedItem, rootItem],
            rootURL: testRoot
        )

        XCTAssertNil(references[nestedItem.path])
        XCTAssertEqual(references[rootItem.path]?.lineNumber, 1)
    }

    func testTogglingItemCommentsEveryLoaderReference() throws {
        let testRoot = try makeTestRoot()
        let itemURL = testRoot.appendingPathComponent("items/battery.lua")
        let initURL = testRoot.appendingPathComponent("init.lua")
        let rcURL = testRoot.appendingPathComponent("sketchybarrc")
        try write("drawing = true\n", to: itemURL)
        try write("require(\"items.battery\")\n", to: initURL)
        try write("source \"$CONFIG_DIR/items/battery.lua\"\n", to: rcURL)

        let service = ConfigActivationService()
        let reference = try XCTUnwrap(service.reference(for: itemURL, rootURL: testRoot))
        XCTAssertEqual(reference.matches.count, 2)
        let file = ConfigFile(
            url: itemURL,
            rootURL: testRoot,
            kind: .lua,
            values: [],
            activationReference: reference
        )

        try service.setActive(false, for: file)

        XCTAssertEqual(
            try String(contentsOf: initURL, encoding: .utf8),
            "-- require(\"items.battery\")\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rcURL, encoding: .utf8),
            "# source \"$CONFIG_DIR/items/battery.lua\"\n"
        )
    }

    func testByteOrderMarkEntrypointStillExposesFirstRequire() throws {
        let testRoot = try makeTestRoot()
        let itemURL = testRoot.appendingPathComponent("items/battery.lua")
        try write("drawing = true\n", to: itemURL)
        let initURL = testRoot.appendingPathComponent("init.lua")
        try Data([0xEF, 0xBB, 0xBF] + Array("require(\"items.battery\")\n".utf8)).write(to: initURL)

        let reference = ConfigActivationService().reference(for: itemURL, rootURL: testRoot)

        XCTAssertEqual(reference?.lineNumber, 1)
    }

    // MARK: - Backups

    func testFailedBackupCopyKeepsPreviousBackup() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("config")
        let fileURL = configRoot.appendingPathComponent("battery.lua")
        try write("first\n", to: fileURL)

        let backupURL = try ConfigBackupService().backup(fileURL: fileURL, rootURL: configRoot)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "first\n")

        try write("second\n", to: fileURL)
        let failingService = ConfigBackupService(fileManager: BackupCopyFailingFileManager())

        XCTAssertThrowsError(try failingService.backup(fileURL: fileURL, rootURL: configRoot))
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "first\n")
    }

    func testBackupMirrorDoesNotOverwriteUserFileInBackupsFolder() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("config")
        let fileURL = configRoot.appendingPathComponent("battery.lua")
        let userBackup = configRoot.appendingPathComponent("backups/battery.lua")
        try write("original\n", to: fileURL)
        try write("user scratch\n", to: userBackup)

        _ = try ConfigBackupService().backup(fileURL: fileURL, rootURL: configRoot)

        XCTAssertEqual(try String(contentsOf: userBackup, encoding: .utf8), "user scratch\n")
    }

    func testBackupRejectsFileOutsideConfigRoot() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("config")
        let outsideFile = testRoot.appendingPathComponent("elsewhere/battery.lua")
        try write("original\n", to: outsideFile)

        XCTAssertThrowsError(
            try ConfigBackupService().backup(fileURL: outsideFile, rootURL: configRoot)
        ) { error in
            guard case ConfigBackupError.fileOutsideRoot = error else {
                return XCTFail("Expected a file-outside-root error, got \(error)")
            }
        }
    }

    // MARK: - Displaced copies

    func testProfileRestoreCreatesNothingNextToTheDestination() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let profileRoot = testRoot.appendingPathComponent("profiles/selected")
        try write("current\n", to: liveRoot.appendingPathComponent("bar.lua"))
        try write("restored\n", to: profileRoot.appendingPathComponent("bar.lua"))

        let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
        try service.restore(
            profile: ConfigProfile(name: "Selected", url: profileRoot, createdAt: .now),
            to: liveRoot
        )

        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["sketchybar"])
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

    func testConfigSwitchCreatesNothingNextToTheDestination() throws {
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
        try service.activate(config: ConfigWorkspace.make(name: "Alternate", url: selectedRoot))

        let siblings = try FileManager.default.contentsOfDirectory(
            at: liveRoot.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["sketchybar"])
        let restores = try FileManager.default.contentsOfDirectory(
            at: appSupportRoot.appendingPathComponent("Restores"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(restores.count, 1)
    }

    // MARK: - Profiles

    func testProfileNameWithLeadingDotIsListed() throws {
        let testRoot = try makeTestRoot()
        let configRoot = testRoot.appendingPathComponent("config")
        try write("current\n", to: configRoot.appendingPathComponent("bar.lua"))

        let service = ProfileArchiveService(
            appSupportRoot: testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        )
        try service.saveProfile(named: ".backup", from: configRoot, configID: "workspace")

        let profiles = service.listProfiles(for: "workspace")
        XCTAssertEqual(profiles.map(\.name), ["backup"])
    }

    func testProfileSnapshotSkipsBackupMirror() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let configRoot = testRoot.appendingPathComponent("config")
        let fileURL = configRoot.appendingPathComponent("battery.lua")
        try write("original\n", to: fileURL)
        try write("backup copy\n", to: configRoot.appendingPathComponent("backups/battery.lua"))

        let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
        try service.saveProfile(named: "Snapshot", from: configRoot, configID: "workspace")

        let snapshotRoot = service.profilesRoot(for: "workspace").appendingPathComponent("Snapshot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotRoot.appendingPathComponent("backups").path))
        XCTAssertEqual(
            try String(contentsOf: snapshotRoot.appendingPathComponent("battery.lua"), encoding: .utf8),
            "original\n"
        )
    }

    func testStaleStagingDirectoryIsSweptBeforeTheNextOperation() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let liveRoot = testRoot.appendingPathComponent("live/sketchybar")
        let profileRoot = testRoot.appendingPathComponent("profiles/selected")
        try write("current\n", to: liveRoot.appendingPathComponent("bar.lua"))
        try write("restored\n", to: profileRoot.appendingPathComponent("bar.lua"))
        let staleStaging = liveRoot.deletingLastPathComponent()
            .appendingPathComponent(".sketchybar.studio-restore-stale")
        try write("leftover\n", to: staleStaging.appendingPathComponent("bar.lua"))

        let service = ProfileArchiveService(appSupportRoot: appSupportRoot)
        try service.restore(
            profile: ConfigProfile(name: "Selected", url: profileRoot, createdAt: .now),
            to: liveRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleStaging.path))
    }

    // MARK: - Config library

    func testCorruptConfigLibraryIsReportedAndNotOverwritten() throws {
        let testRoot = try makeTestRoot()
        let libraryURL = testRoot.appendingPathComponent("config-library.json")
        try Data("{ not json".utf8).write(to: libraryURL)
        let service = ConfigLibraryService(libraryURL: libraryURL)

        XCTAssertThrowsError(try service.load(defaultConfigRoot: testRoot)) { error in
            guard case ConfigLibraryError.corrupt = error else {
                return XCTFail("Expected a corrupt-library error, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try service.save([ConfigWorkspace.make(name: "Test", url: testRoot)])
        )
        XCTAssertEqual(try String(contentsOf: libraryURL, encoding: .utf8), "{ not json")
    }

    // MARK: - Crash recovery

    func testRecoverPendingInstallRestoresMissingLivePath() throws {
        let testRoot = try makeTestRoot()
        let appSupportRoot = testRoot.appendingPathComponent("Application Support/SketchyBarStudio")
        let destination = testRoot.appendingPathComponent("live/sketchybar")
        let displaced = testRoot.appendingPathComponent("live/.sketchybar.studio-rollback-old")
        try write("original\n", to: displaced.appendingPathComponent("bar.lua"))

        let replacer = SafeFileReplacer(appSupportRoot: appSupportRoot)
        let journal = """
        {
          "staged": "\(testRoot.appendingPathComponent("live/.sketchybar.studio-switch-staged").path)",
          "destination": "\(destination.path)",
          "displaced": "\(displaced.path)",
          "keepDisplaced": true
        }
        """
        try write(journal, to: appSupportRoot.appendingPathComponent("pending-install.json"))

        replacer.recoverPendingInstalls()

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("bar.lua"), encoding: .utf8),
            "original\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appSupportRoot.appendingPathComponent("pending-install.json").path)
        )
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioFileSafetyTests", isDirectory: true)
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

private final class BackupCopyFailingFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
