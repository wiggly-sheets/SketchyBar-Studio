import Foundation
@testable import SketchyBarStudio
import XCTest

final class StoreTests: XCTestCase {
    // MARK: - Catalogue

    func testCatalogueEntriesAreVerifiedAndPinned() {
        let entries = StoreCatalogue.entries
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "entry ids must be unique")

        for entry in entries {
            XCTAssertTrue(entry.repositoryIsWellFormed, "\(entry.id): repository is not owner/repo")
            XCTAssertTrue(entry.hasPinnedRef, "\(entry.id): ref must be a tag or commit")
            XCTAssertTrue(entry.hasSafePath, "\(entry.id): path must be relative and free of ..")
            XCTAssertEqual(entry.licenceURL.hasPrefix("https://"), true, "\(entry.id): licence link")
            XCTAssertTrue(entry.licenceURL.contains(entry.repository), "\(entry.id): licence link must point at its repository")
            XCTAssertNotNil(entry.licence, "\(entry.id): a licence must be verified")
            if let licence = entry.licence {
                XCTAssertTrue(StoreLicence.permissive.contains(licence), "\(entry.id): \(licence.rawValue) is not permissive")
            }
            XCTAssertTrue(entry.isInstallable, "\(entry.id): listed entries must be installable")
        }
    }

    func testRawAndArchiveURLConstruction() {
        let entry = makeEntry(repository: "owner/repo", path: "items/clock.lua", ref: "v1.0.0")

        XCTAssertEqual(entry.rawFileURLString, "https://raw.githubusercontent.com/owner/repo/v1.0.0/items/clock.lua")
        XCTAssertEqual(entry.archiveURLString, "https://codeload.github.com/owner/repo/tar.gz/v1.0.0")
    }

    func testBranchRefAndUnsafePathAreNotInstallable() {
        XCTAssertFalse(makeEntry(ref: "main").hasPinnedRef)
        XCTAssertFalse(makeEntry(ref: "master").isInstallable)
        XCTAssertTrue(makeEntry(ref: "a1b2c3d").isInstallable)
        XCTAssertFalse(makeEntry(path: "/etc/passwd").hasSafePath)
        XCTAssertFalse(makeEntry(path: "../escape.lua").hasSafePath)
        XCTAssertTrue(makeEntry(kind: .setup, path: "").isInstallable)
    }

    // MARK: - Client

    func testPluginFetchUsesThePinnedRawURL() async throws {
        let entry = makeEntry(repository: "owner/repo", path: "items/clock.lua", ref: "v1.0.0")
        let transport = URLCheckingTransport(
            expected: "https://raw.githubusercontent.com/owner/repo/v1.0.0/items/clock.lua",
            payload: Data("print(1)\n".utf8)
        )

        let data = try await StoreClient(transport: transport).fetchPluginFile(entry)

        XCTAssertEqual(data, Data("print(1)\n".utf8))
    }

    func testMissingLicenceRefusesBeforeAnyFetch() async {
        let transport = FailingTransport()
        let service = StoreClient(transport: transport)

        do {
            _ = try await service.fetchPluginFile(makeEntry(licence: nil))
            XCTFail("expected licenceMissing")
        } catch let error as StoreError {
            XCTAssertEqual(error, .licenceMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDownloadLimitIsEnforced() async {
        let transport = StubTransport(payload: Data(repeating: 0, count: 8))

        do {
            _ = try await StoreClient(transport: transport, downloadLimit: 4)
                .fetchPluginFile(makeEntry())
            XCTFail("expected tooLarge")
        } catch let error as StoreError {
            XCTAssertEqual(error, .tooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testArchiveExtractionTakesOnlyTheRequestedSubtree() throws {
        let root = try makeTestRoot()
        let data = try tarData(
            in: root,
            files: [
                "pkg/a.txt": "a\n",
                "pkg/sub/b.txt": "b\n"
            ],
            members: ["pkg"]
        )
        let client = StoreClient(transport: StubTransport())

        let tree = try client.extractArchive(data, treePath: "pkg/sub")
        defer { tree.remove() }

        XCTAssertEqual(tree.contents.lastPathComponent, "sub")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: tree.contents.path),
            ["b.txt"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.contents.appendingPathComponent("a.txt").path))
    }

    func testArchiveRejectsParentTraversalMember() throws {
        let root = try makeTestRoot()
        let data = try tarData(
            in: root,
            files: ["pkg/a.txt": "a\n"],
            members: ["pkg/a.txt"],
            transform: ",^pkg/,../,"
        )

        XCTAssertThrowsError(try StoreClient(transport: StubTransport()).extractArchive(data, treePath: "")) { error in
            guard case StoreError.unsafeArchive = error else {
                return XCTFail("expected unsafeArchive, got \(error)")
            }
        }
    }

    func testArchiveRejectsAbsoluteMember() throws {
        let root = try makeTestRoot()
        let data = try tarData(
            in: root,
            files: ["pkg/a.txt": "a\n"],
            members: ["pkg/a.txt"],
            transform: ",^pkg/,/abs/,",
            preserveAbsolute: true
        )

        XCTAssertFalse(StoreClient.isSafeArchivePath("/abs/a.txt"))
        XCTAssertThrowsError(try StoreClient(transport: StubTransport()).extractArchive(data, treePath: "")) { error in
            guard case StoreError.unsafeArchive = error else {
                return XCTFail("expected unsafeArchive, got \(error)")
            }
        }
    }

    func testArchiveRejectsSymlinkMember() throws {
        let root = try makeTestRoot()
        let data = try tarData(
            in: root,
            files: ["pkg/a.txt": "a\n"],
            links: ["pkg/link": "a.txt"],
            members: ["pkg"]
        )

        XCTAssertThrowsError(try StoreClient(transport: StubTransport()).extractArchive(data, treePath: "")) { error in
            guard case StoreError.unsafeArchive = error else {
                return XCTFail("expected unsafeArchive, got \(error)")
            }
        }
    }

    func testArchiveFileCountLimitIsEnforced() throws {
        let root = try makeTestRoot()
        let data = try tarData(
            in: root,
            files: [
                "pkg/a.txt": "a\n",
                "pkg/b.txt": "b\n",
                "pkg/c.txt": "c\n"
            ],
            members: ["pkg"]
        )

        XCTAssertThrowsError(
            try StoreClient(transport: StubTransport(), fileLimit: 2).extractArchive(data, treePath: "")
        ) { error in
            XCTAssertEqual(error as? StoreError, .tooManyFiles)
        }
    }

    // MARK: - Manifest

    func testManifestRoundTripKeepsEveryRecordedField() throws {
        let root = try makeTestRoot()
        let configRoot = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let store = StoreManifestStore(appSupportRoot: root.appendingPathComponent("support"))
        let record = makeRecord(
            installedPath: "plugins/datetime.lua",
            loaderEdit: StoreLoaderEdit(entrypointPath: "init.lua", line: "require(\"plugins.datetime\")"),
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.append(record, configRoot: configRoot, configID: "workspace")
        let loaded = try store.load(configRoot: configRoot, configID: "workspace")

        XCTAssertEqual(loaded.records, [record])
        XCTAssertEqual(loaded.configID, "workspace")
        XCTAssertEqual(loaded.configRoot, configRoot.standardizedFileURL.path)

        let otherRoot = root.appendingPathComponent("other")
        XCTAssertNotEqual(store.manifestURL(forConfigRoot: configRoot), store.manifestURL(forConfigRoot: otherRoot))
    }

    // MARK: - Plugin install and uninstall

    func testPluginInstallWritesFileAndLoaderLine() throws {
        let (service, configRoot, _) = try makeInstallFixture()
        let entry = makeEntry(name: "Clock", path: "items/datetime.lua")
        let contents = Data("print(1)\r\n".utf8)

        let outcome = try service.installPlugin(entry, contents: contents, configRoot: configRoot, configID: "workspace")

        XCTAssertEqual(outcome.loader, StoreLoaderOutcome.inserted(entrypoint: "init.lua", line: "require(\"plugins.datetime\")"))
        XCTAssertEqual(try Data(contentsOf: configRoot.appendingPathComponent("plugins/datetime.lua")), contents)
        XCTAssertEqual(
            try String(contentsOf: configRoot.appendingPathComponent("init.lua"), encoding: .utf8),
            "require(\"bar\")\nrequire(\"plugins.datetime\")\n"
        )

        let records = try service.records(configRoot: configRoot, configID: "workspace")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].entryID, entry.id)
        XCTAssertEqual(records[0].licence, .mit)
        XCTAssertEqual(records[0].installedPath, "plugins/datetime.lua")
        XCTAssertEqual(records[0].loaderEdit?.line, "require(\"plugins.datetime\")")
    }

    func testUninstallRemovesOnlyTheRecordedFileAndItsLoaderLine() throws {
        let (service, configRoot, _) = try makeInstallFixture()
        let clock = try service.installPlugin(
            makeEntry(id: "clock", path: "items/datetime.lua"),
            contents: Data("clock\n".utf8),
            configRoot: configRoot,
            configID: "workspace"
        )
        let cpu = try service.installPlugin(
            makeEntry(id: "cpu", name: "CPU", path: "items/cpu.lua"),
            contents: Data("cpu\n".utf8),
            configRoot: configRoot,
            configID: "workspace"
        )

        let removed = try service.uninstall(recordID: clock.record.id, configRoot: configRoot, configID: "workspace")

        XCTAssertEqual(removed.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/datetime.lua").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/cpu.lua").path))
        XCTAssertEqual(
            try String(contentsOf: configRoot.appendingPathComponent("init.lua"), encoding: .utf8),
            "require(\"bar\")\nrequire(\"plugins.cpu\")\n"
        )
        let records = try service.records(configRoot: configRoot, configID: "workspace")
        XCTAssertEqual(records.map(\.id), [cpu.record.id])
    }

    func testUninstallRefusesATamperedConfigPath() throws {
        let (service, configRoot, supportRoot) = try makeInstallFixture()
        let outcome = try service.installPlugin(
            makeEntry(path: "items/datetime.lua"),
            contents: Data("clock\n".utf8),
            configRoot: configRoot,
            configID: "workspace"
        )
        let sentinel = configRoot.deletingLastPathComponent().appendingPathComponent("escape.lua")
        try Data("keep\n".utf8).write(to: sentinel)

        let manifestStore = StoreManifestStore(appSupportRoot: supportRoot)
        let manifestURL = manifestStore.manifestURL(forConfigRoot: configRoot)
        var manifest = try decodeManifest(at: manifestURL)
        manifest.records[0] = copy(outcome.record, installedPath: "../escape.lua")
        try encode(manifest, to: manifestURL)

        XCTAssertThrowsError(
            try service.uninstall(recordID: outcome.record.id, configRoot: configRoot, configID: "workspace")
        ) { error in
            guard case StoreInstallError.manifestTampered = error else {
                return XCTFail("expected manifestTampered, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/datetime.lua").path))
        XCTAssertEqual(
            try String(contentsOf: configRoot.appendingPathComponent("init.lua"), encoding: .utf8),
            "require(\"bar\")\nrequire(\"plugins.datetime\")\n"
        )
    }

    func testUninstallRefusesWhenTheLoaderLineChanged() throws {
        let (service, configRoot, _) = try makeInstallFixture()
        let outcome = try service.installPlugin(
            makeEntry(path: "items/datetime.lua"),
            contents: Data("clock\n".utf8),
            configRoot: configRoot,
            configID: "workspace"
        )
        try Data("require(\"bar\")\n".utf8).write(to: configRoot.appendingPathComponent("init.lua"))

        XCTAssertThrowsError(
            try service.uninstall(recordID: outcome.record.id, configRoot: configRoot, configID: "workspace")
        ) { error in
            guard case StoreInstallError.loaderEditChanged = error else {
                return XCTFail("expected loaderEditChanged, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/datetime.lua").path))
    }

    // MARK: - Multi-file plugin install and uninstall

    func testMultiFilePluginInstallWritesAllFilesAndFolder() throws {
        let (service, configRoot, _) = try makeInstallFixture()
        let entry = makeEntry(
            id: "multi-test",
            path: "items/main.lua",
            files: ["plugins/helper.sh", "plugins/lib/util.lua"]
        )
        let mainContents = Data("print('main')\n".utf8)
        let extraContents = [
            "plugins/helper.sh": Data("#!/bin/bash\necho helper\n".utf8),
            "plugins/lib/util.lua": Data("return { util = true }\n".utf8)
        ]

        let outcome = try service.installPlugin(entry, contents: mainContents, configRoot: configRoot, configID: "workspace")

        // Primary file written
        let mainURL = configRoot.appendingPathComponent("plugins/multi-test/main.lua")
        XCTAssertEqual(try Data(contentsOf: mainURL), mainContents)

        // Extra files written by caller (simulate StoreModel.install behavior)
        let pluginDir = configRoot.appendingPathComponent("plugins/multi-test")
        for (path, data) in extraContents {
            let name = (path as NSString).lastPathComponent
            let dest = pluginDir.appendingPathComponent(name)
            try data.write(to: dest, options: .atomic)
        }

        // Verify all files exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("main.lua").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("helper.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("util.lua").path))

        // Record points to folder, not single file
        let records = try service.records(configRoot: configRoot, configID: "workspace")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].installedPath, "plugins/multi-test")
        XCTAssertEqual(records[0].loaderEdit?.line, "require(\"plugins.main\")")
    }

    func testMultiFilePluginUninstallRemovesEntireFolderAndLoaderLine() throws {
        let (service, configRoot, _) = try makeInstallFixture()
        let entry = makeEntry(
            id: "multi-test",
            path: "items/main.lua",
            files: ["plugins/helper.sh", "plugins/lib/util.lua"]
        )
        let mainContents = Data("print('main')\n".utf8)

        let outcome = try service.installPlugin(entry, contents: mainContents, configRoot: configRoot, configID: "workspace")

        // Write extra files to simulate complete install
        let pluginDir = configRoot.appendingPathComponent("plugins/multi-test")
        try Data("#!/bin/bash\necho helper\n".utf8).write(to: pluginDir.appendingPathComponent("helper.sh"), options: .atomic)
        try Data("return { util = true }\n".utf8).write(to: pluginDir.appendingPathComponent("util.lua"), options: .atomic)

        let removed = try service.uninstall(recordID: outcome.record.id, configRoot: configRoot, configID: "workspace")

        // Entire folder removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginDir.path))
        // Loader line reverted
        XCTAssertEqual(
            try String(contentsOf: configRoot.appendingPathComponent("init.lua"), encoding: .utf8),
            "require(\"bar\")\n"
        )
        // Manifest record removed
        let records = try service.records(configRoot: configRoot, configID: "workspace")
        XCTAssertTrue(records.isEmpty)
        // Removed URLs include folder and loader file
        XCTAssertEqual(removed.count, 2)
    }

    func testMultiFilePluginUninstallRefusesTamperedFolderPath() throws {
        let (service, configRoot, supportRoot) = try makeInstallFixture()
        let entry = makeEntry(
            id: "multi-test",
            path: "items/main.lua",
            files: ["plugins/helper.sh"]
        )
        let outcome = try service.installPlugin(
            entry,
            contents: Data("print('main')\n".utf8),
            configRoot: configRoot,
            configID: "workspace"
        )

        // Tamper the manifest to point outside the config
        let manifestStore = StoreManifestStore(appSupportRoot: supportRoot)
        let manifestURL = manifestStore.manifestURL(forConfigRoot: configRoot)
        var manifest = try decodeManifest(at: manifestURL)
        manifest.records[0] = copy(outcome.record, installedPath: "../escape")
        try encode(manifest, to: manifestURL)

        XCTAssertThrowsError(
            try service.uninstall(recordID: outcome.record.id, configRoot: configRoot, configID: "workspace")
        ) { error in
            guard case StoreInstallError.manifestTampered = error else {
                return XCTFail("expected manifestTampered, got \(error)")
            }
        }

        // Folder still exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: configRoot.appendingPathComponent("plugins/multi-test").path))
    }

    func testMultiFilePluginInstallFailsWhenExtraFileMissing() async throws {
        let transport = RecordingTransport(routes: [
            // Main plugin file
            rawURL("items/main.lua", makeEntry(id: "multi-test", path: "items/main.lua", files: ["plugins/helper.sh"])): .data(Data("print('main')\n".utf8)),
            // Extra file fails
        ])
        let client = StoreClient(transport: transport)
        let (service, configRoot, _) = try makeInstallFixture()
        let entry = makeEntry(
            id: "multi-test",
            path: "items/main.lua",
            files: ["plugins/helper.sh"]
        )

        // Fetch main file
        let mainData = try await client.fetchPluginFile(entry)
        // Fetch extra file - should fail
        do {
            _ = try await client.fetchFile(entry, path: "plugins/helper.sh")
            XCTFail("expected notFound")
        } catch let error as StoreError {
            XCTAssertEqual(error, .notFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Setup install and uninstall

    func testSetupInstallCreatesANewProfileAndLeavesTheConfigAlone() throws {
        let (service, configRoot, supportRoot) = try makeInstallFixture()
        let tree = try makeSetupTree()
        let entry = makeEntry(kind: .setup, name: "Islands", path: "", ref: "v1.0.0")

        let first = try service.installSetup(entry, tree: tree, configRoot: configRoot, configID: "workspace")
        let second = try service.installSetup(entry, tree: tree, configRoot: configRoot, configID: "workspace")

        XCTAssertNil(first.loader)
        XCTAssertNotEqual(first.installedURL, second.installedURL)
        XCTAssertEqual(first.installedURL.deletingLastPathComponent().lastPathComponent, "workspace")
        XCTAssertEqual(
            try String(contentsOf: first.installedURL.appendingPathComponent("bar.lua"), encoding: .utf8),
            "bar = true\n"
        )
        XCTAssertEqual(
            try String(contentsOf: configRoot.appendingPathComponent("init.lua"), encoding: .utf8),
            "require(\"bar\")\n"
        )
        XCTAssertEqual(try service.records(configRoot: configRoot, configID: "workspace").count, 2)

        let removed = try service.uninstall(recordID: first.record.id, configRoot: configRoot, configID: "workspace")

        XCTAssertEqual(removed, [first.installedURL.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.installedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.installedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Profiles").path))
    }

    func testUninstallRefusesATamperedProfilePath() throws {
        let (service, configRoot, supportRoot) = try makeInstallFixture()
        let tree = try makeSetupTree()
        let outside = configRoot.deletingLastPathComponent().appendingPathComponent("outside-profile")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: outside.appendingPathComponent("keep.txt"))

        let outcome = try service.installSetup(
            makeEntry(kind: .setup, name: "Islands", path: "", ref: "v1.0.0"),
            tree: tree,
            configRoot: configRoot,
            configID: "workspace"
        )

        let manifestStore = StoreManifestStore(appSupportRoot: supportRoot)
        let manifestURL = manifestStore.manifestURL(forConfigRoot: configRoot)
        var manifest = try decodeManifest(at: manifestURL)
        manifest.records[0] = copy(outcome.record, installedPath: outside.path)
        try encode(manifest, to: manifestURL)

        XCTAssertThrowsError(
            try service.uninstall(recordID: outcome.record.id, configRoot: configRoot, configID: "workspace")
        ) { error in
            guard case StoreInstallError.manifestTampered = error else {
                return XCTFail("expected manifestTampered, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.installedURL.path))
    }

    // MARK: - README

    func testReadmeResolutionPrefersEntryDirectoryThenRoot() async throws {
        let entry = makeEntry(kind: .setup, path: "sub", ref: "v1.0.0")
        let transport = RecordingTransport(routes: [
            rawURL("readme.md", entry): .data(Data("# Readme\n".utf8))
        ])

        let result = try XCTUnwrapLoaded(
            await StoreClient(transport: transport).readme(for: entry)
        )

        XCTAssertTrue(result.text.hasPrefix("# Readme"))
        XCTAssertEqual(
            transport.requestedURLs(),
            [rawURL("sub/README.md", entry), rawURL("README.md", entry), rawURL("readme.md", entry)]
        )
    }

    func testReadmeResolutionFallsBackToExtensionlessREADME() async throws {
        let entry = makeEntry(path: "items/datetime.lua")
        let transport = RecordingTransport(routes: [
            rawURL("README", entry): .data(Data("plain\n".utf8))
        ])

        let loaded = try XCTUnwrapLoaded(await StoreClient(transport: transport).readme(for: entry))

        XCTAssertEqual(loaded.text, "plain\n")
        XCTAssertEqual(loaded.url.absoluteString, rawURL("README", entry))
        XCTAssertEqual(transport.requestedURLs().count, 4)
    }

    func testReadmeSizeCapIsEnforced() async {
        let entry = makeEntry()
        let oversized = Data(repeating: 0x41, count: StoreClient.maxReadmeBytes + 1)
        let transport = RecordingTransport(routes: [
            rawURL("items/README.md", entry): .data(oversized)
        ])

        let result = await StoreClient(transport: transport).readme(for: entry)

        XCTAssertEqual(result, .unavailable(url: rawURL("items/README.md", entry)))
    }

    func testReadmeFailureYieldsUnavailableWithSourceURL() async {
        let entry = makeEntry()
        let transport = RecordingTransport()

        let result = await StoreClient(transport: transport).readme(for: entry)

        guard case .unavailable(let url) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertTrue(url.hasPrefix(rawURL("", entry)))
        XCTAssertTrue(url.hasSuffix("/README"))
    }

    func testReadmeIsCachedPerEntryAndRef() async {
        let entry = makeEntry()
        let transport = RecordingTransport(routes: [
            rawURL("items/README.md", entry): .data(Data("# Cached\n".utf8))
        ])
        let client = StoreClient(transport: transport)

        _ = await client.readme(for: entry)
        _ = await client.readme(for: entry)
        XCTAssertEqual(transport.count(rawURL("items/README.md", entry)), 1)

        let otherRef = makeEntry(ref: "v2.0.0")
        _ = await client.readme(for: otherRef)
        XCTAssertEqual(transport.count(rawURL("items/README.md", otherRef)), 1)
        XCTAssertEqual(transport.count(rawURL("items/README.md", entry)), 1)
    }

    func testMarkdownParseFailureFallsBackToPlainText() {
        struct BrokenMarkdown: Error {}

        let result = StoreMarkdown.rendered("# Title") { _ in
            throw BrokenMarkdown()
        }

        XCTAssertEqual(String(result.characters), "# Title")
    }

    // MARK: - Setup staging

    @MainActor
    func testSetupStagingIsReusedOnInstall() async throws {
        let fixture = try makeModelFixture()
        let entry = makeEntry(kind: .setup, name: "Islands", path: "", ref: "v1.0.0")
        let transport = RecordingTransport(routes: [
            rawURL("README.md", entry): .data(Data("# Islands\n".utf8)),
            entry.archiveURLString: .data(try tarData(
                in: fixture.root,
                files: ["pkg/bar.lua": "bar\n"],
                members: ["pkg"]
            ))
        ])
        let model = fixture.model(transport: transport)
        model.selectedID = entry.id

        await model.inspect(entry)

        guard case .staged(let files, let total) = model.setup else {
            return XCTFail("expected a staged tree, got \(model.setup)")
        }
        XCTAssertEqual(files.map(\.path), ["bar.lua"])
        XCTAssertEqual(total, Int64("bar\n".utf8.count))
        let stagingRoot = try XCTUnwrap(model.stagedTree).workingDirectory

        await model.install(entry)

        XCTAssertEqual(transport.count(entry.archiveURLString), 1)
        XCTAssertNil(model.stagedTree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertEqual(model.records.count, 1)
    }

    @MainActor
    func testStagingIsDiscardedWhenSelectionChanges() async throws {
        let fixture = try makeModelFixture()
        let entry = makeEntry(kind: .setup, name: "Islands", path: "", ref: "v1.0.0")
        let transport = RecordingTransport(routes: [
            entry.archiveURLString: .data(try tarData(
                in: fixture.root,
                files: ["pkg/bar.lua": "bar\n"],
                members: ["pkg"]
            ))
        ])
        let model = fixture.model(transport: transport)
        model.selectedID = entry.id

        await model.inspect(entry)
        let stagingRoot = try XCTUnwrap(model.stagedTree).workingDirectory

        model.selectedID = StoreCatalogue.entries.first { $0.kind == .plugin }?.id
        model.loadSelectedPreview()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertNil(model.stagedTree)
        XCTAssertEqual(model.setup, .idle)
    }

    @MainActor
    func testOversizedArchiveIsRefusedAtStaging() async throws {
        let fixture = try makeModelFixture()
        let entry = makeEntry(kind: .setup, name: "Islands", path: "", ref: "v1.0.0")
        let transport = RecordingTransport(routes: [
            entry.archiveURLString: .data(Data(repeating: 0, count: 128))
        ])
        let model = fixture.model(
            transport: transport,
            client: StoreClient(transport: transport, downloadLimit: 32)
        )
        model.selectedID = entry.id

        await model.inspect(entry)

        guard case .failed(let message) = model.setup else {
            return XCTFail("expected a refusal, got \(model.setup)")
        }
        XCTAssertTrue(message.contains("20 MB"), message)
        XCTAssertNil(model.stagedTree)
    }

    // MARK: - Helpers

    private struct StubTransport: StoreTransport {
        var payload = Data()
        var failure: StoreError?

        func fetch(_ url: URL, limit: Int) async throws -> Data {
            if let failure { throw failure }
            return payload
        }
    }

    private struct FailingTransport: StoreTransport {
        func fetch(_ url: URL, limit: Int) async throws -> Data {
            throw StoreError.offline("the test must not fetch")
        }
    }

    private struct URLCheckingTransport: StoreTransport {
        let expected: String
        let payload: Data

        func fetch(_ url: URL, limit: Int) async throws -> Data {
            guard url.absoluteString == expected else {
                throw StoreError.invalidEntry("unexpected URL \(url.absoluteString)")
            }
            return payload
        }
    }

    private struct ModelFixture {
        let root: URL
        let configRoot: URL
        let supportRoot: URL
        @MainActor let makeModel: (RecordingTransport, StoreClient?) -> StoreModel

        @MainActor
        func model(transport: RecordingTransport, client: StoreClient? = nil) -> StoreModel {
            makeModel(transport, client)
        }
    }

    @MainActor
    private func makeModelFixture() throws -> ModelFixture {
        let root = try makeTestRoot()
        let configRoot = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try Data("require(\"bar\")\n".utf8).write(to: configRoot.appendingPathComponent("init.lua"))
        let supportRoot = root.appendingPathComponent("support")
        return ModelFixture(root: root, configRoot: configRoot, supportRoot: supportRoot) { transport, client in
            StoreModel(
                configRoot: configRoot,
                configID: "workspace",
                appSupportRoot: supportRoot,
                client: client ?? StoreClient(transport: transport)
            )
        }
    }

    private func rawURL(_ path: String, _ entry: StoreEntry) -> String {
        "https://raw.githubusercontent.com/\(entry.repository)/\(entry.ref)/\(path)"
    }

    private func XCTUnwrapLoaded(
        _ result: StoreReadmeResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> StoreReadme {
        guard case .loaded(let readme) = result else {
            XCTFail("expected a loaded README, got \(result)", file: file, line: line)
            throw StoreError.notFound
        }
        return readme
    }

    private final class RecordingTransport: StoreTransport, @unchecked Sendable {
        enum Reply {
            case data(Data)
            case error(StoreError)
        }

        private let lock = NSLock()
        private let routes: [String: Reply]
        private let fallback: Reply
        private var calls: [String: Int] = [:]
        private var order: [String] = []

        init(routes: [String: Reply] = [:], fallback: Reply = .error(.notFound)) {
            self.routes = routes
            self.fallback = fallback
        }

        func fetch(_ url: URL, limit: Int) async throws -> Data {
            switch record(url) {
            case .data(let data):
                return data
            case .error(let error):
                throw error
            }
        }

        private func record(_ url: URL) -> Reply {
            lock.lock()
            defer { lock.unlock() }
            let key = url.absoluteString
            calls[key, default: 0] += 1
            order.append(key)
            return routes[key] ?? fallback
        }

        func count(_ url: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return calls[url] ?? 0
        }

        func requestedURLs() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return order
        }
    }

    private func makeEntry(
        id: String = "test-entry",
        kind: StoreEntryKind = .plugin,
        name: String = "Test",
        repository: String = "owner/repo",
        path: String = "items/datetime.lua",
        files: [String] = [],
        ref: String = "v1.0.0",
        licence: StoreLicence? = .mit
    ) -> StoreEntry {
        StoreEntry(
            id: id,
            kind: kind,
            name: name,
            author: "author",
            repository: repository,
            path: path,
            files: files,
            ref: ref,
            licence: licence,
            licenceURL: licence == nil ? "" : "https://github.com/\(repository)/blob/\(ref)/LICENSE",
            summary: "summary",
            tags: [],
            dependencies: []
        )
    }

    private func makeRecord(
        installedPath: String,
        loaderEdit: StoreLoaderEdit?,
        installedAt: Date
    ) -> StoreInstallRecord {
        StoreInstallRecord(
            id: UUID(),
            entryID: "test-entry",
            kind: .plugin,
            name: "Test",
            author: "author",
            licence: .mit,
            licenceURL: "https://github.com/owner/repo/blob/v1.0.0/LICENSE",
            location: .configFile,
            installedPath: installedPath,
            loaderEdit: loaderEdit,
            installedAt: installedAt
        )
    }

    private func makeInstallFixture() throws -> (StoreInstallService, URL, URL) {
        let root = try makeTestRoot()
        let configRoot = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        try Data("require(\"bar\")\n".utf8).write(to: configRoot.appendingPathComponent("init.lua"))
        let supportRoot = root.appendingPathComponent("support")
        return (StoreInstallService(appSupportRoot: supportRoot), configRoot, supportRoot)
    }

    private func makeSetupTree() throws -> URL {
        let root = try makeTestRoot()
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("bar = true\n".utf8).write(to: tree.appendingPathComponent("bar.lua"))
        try Data("colors = {}\n".utf8).write(to: tree.appendingPathComponent("colors.lua"))
        return tree
    }

    private func makeTestRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func tarData(
        in root: URL,
        files: [String: String] = [:],
        links: [String: String] = [:],
        members: [String],
        transform: String? = nil,
        preserveAbsolute: Bool = false
    ) throws -> Data {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        for (path, destination) in links {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }

        let archive = root.appendingPathComponent("fixture-\(UUID().uuidString).tgz")
        var arguments = ["-czf", archive.path]
        if preserveAbsolute { arguments.append("-P") }
        if let transform { arguments.append(contentsOf: ["-s", transform]) }
        arguments.append(contentsOf: ["-C", stage.path] + members)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        return try Data(contentsOf: archive)
    }

    private func decodeManifest(at url: URL) throws -> StoreManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoreManifest.self, from: Data(contentsOf: url))
    }

    private func encode(_ manifest: StoreManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func copy(_ record: StoreInstallRecord, installedPath: String) -> StoreInstallRecord {
        StoreInstallRecord(
            id: record.id,
            entryID: record.entryID,
            kind: record.kind,
            name: record.name,
            author: record.author,
            licence: record.licence,
            licenceURL: record.licenceURL,
            location: record.location,
            installedPath: installedPath,
            loaderEdit: record.loaderEdit,
            installedAt: record.installedAt
        )
    }
}
