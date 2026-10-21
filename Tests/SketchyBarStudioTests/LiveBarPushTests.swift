import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the push of the previewed bar to the live SketchyBar.
///
/// The tests that need the daemon of SketchyBar are skipped when it does
/// not answer, and they never fail the build because of that. The other
/// tests use a runner of their own, so the cases of a daemon that is not
/// there and of a daemon that refuses a call can be held on a machine
/// without one.
final class LiveBarPushTests: XCTestCase {

    // MARK: - The setting

    /// The mode is `Never` on a fresh install, and it is saved.
    func testTheLiveUpdateModeIsNeverOnAFreshInstallAndIsSaved() throws {
        let defaults = try makeDefaults()

        XCTAssertEqual(LiveUpdateMode.defaultMode, .never)
        XCTAssertEqual(LiveUpdateMode.saved(in: defaults), .never)

        LiveUpdateMode.whileEditing.save(in: defaults)
        XCTAssertEqual(LiveUpdateMode.saved(in: defaults), .whileEditing)

        LiveUpdateMode.onApply.save(in: defaults)
        XCTAssertEqual(LiveUpdateMode.saved(in: defaults), .onApply)

        // A value that is not a mode falls back to the safe one.
        defaults.set("something else", forKey: LiveUpdateMode.defaultsKey)
        XCTAssertEqual(LiveUpdateMode.saved(in: defaults), .never)
    }

    /// The store keeps the mode of the defaults, so the setting survives a
    /// restart of the app.
    @MainActor
    func testTheStoreKeepsTheModeOfTheDefaults() throws {
        let defaults = try makeDefaults()
        LiveUpdateMode.onApply.save(in: defaults)

        let store = try makeStore(defaults: defaults)
        XCTAssertEqual(store.liveUpdateMode, .onApply)

        store.liveUpdateMode = .whileEditing
        XCTAssertEqual(LiveUpdateMode.saved(in: defaults), .whileEditing)
    }

    // MARK: - The calls of the push

    /// The push builds one call per item, with the properties of the item.
    func testThePushBuildsOneCallPerItemWithItsProperties() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00"),
                    BarRenderProperty(key: "label.color", value: "0xff000000")
                ]),
                BarRenderItemModel(alias: "battery", properties: [
                    BarRenderProperty(key: "icon", value: "SF:Battery.100")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertEqual(live.items.count, 2)
        XCTAssertTrue(live.notes.isEmpty)

        let commands = LiveBarService.pushCommands(for: live.items)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments,
                       ["--set", "clock", "label=10:00", "label.color=0xff000000"])
        XCTAssertEqual(commands[1].arguments,
                       ["--set", "battery", "icon=SF:Battery.100"])
    }

    /// A value with a space keeps its space: the transport of SketchyBar
    /// is NUL separated, so the value needs no quoting.
    func testAValueWithASpaceKeepsItsSpace() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "Hello World")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        let commands = LiveBarService.pushCommands(for: live.items)
        XCTAssertEqual(commands.first?.arguments, ["--set", "clock", "label=Hello World"])
    }

    /// A script is never pushed: it belongs to the config and not to the
    /// running bar.
    func testThePushNeverSendsAScriptOrAClickScript() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00"),
                    BarRenderProperty(key: "script", value: "sketchybar --set clock label=12:00"),
                    BarRenderProperty(key: "click_script", value: "sketchybar --set clock label=13:00")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertEqual(live.items.first?.properties.map(\.key), ["label"])

        let arguments = LiveBarService.pushCommands(for: live.items).flatMap(\.arguments)
        XCTAssertFalse(arguments.contains { $0.hasPrefix("script=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("click_script=") })
    }

    /// An item without a name cannot be pushed: the daemon sets nothing
    /// when the item does not exist.
    func testAnItemWithoutANameIsReportedAndNotPushed() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertTrue(live.items.isEmpty)
        XCTAssertEqual(live.notes.count, 1)
        XCTAssertTrue(live.notes[0].contains("no name"))
        XCTAssertTrue(LiveBarService.pushCommands(for: live.items).isEmpty)
    }

    /// A file may declare several items, so the push is per declared item
    /// and never per file.
    func testAFileWithSeveralItemsProducesOnePushPerItem() {
        let source = """
        sbar.add("item", "clock", { position = "right", label = "10:00" })
        sbar.add("item", "battery", { position = "right", icon = "SF:Battery" })
        sbar.add("item", "wifi", { position = "right", icon = "SF:Wifi" })
        """

        let plan = PreviewConfigBridge.plan(forLua: source)
        let live = LiveBarService.liveItems(of: plan)
        XCTAssertEqual(live.items.map(\.alias), ["clock", "battery", "wifi"])

        let commands = LiveBarService.pushCommands(for: live.items)
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands.map { $0.arguments[1] }, ["clock", "battery", "wifi"])
    }

    // MARK: - The snapshot

    /// The snapshot holds the live value of every property the push
    /// changes, and it is written before the push.
    func testThePushTakesTheSnapshotOfTheLiveBarBeforeItChangesIt() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]

        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.pushedItems, 1)
        XCTAssertEqual(outcome.pushedProperties, 1)
        XCTAssertTrue(outcome.failures.isEmpty)

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.properties.map { "\($0.alias).\($0.key)" }, ["clock.label"])
        XCTAssertEqual(snapshot.properties.first?.value, "09:00")
    }

    /// The snapshot never holds a script.
    func testTheSnapshotNeverHoldsAScript() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)

        let snapshot = LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
            LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00"),
            LiveBarSnapshot.Property(alias: "clock", key: "script", value: "sketchybar --set clock label=12:00"),
            LiveBarSnapshot.Property(alias: "clock", key: "click_script", value: "sketchybar --set clock label=13:00")
        ])
        try store.save(snapshot)

        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(text.contains("sketchybar --set"))
        XCTAssertEqual(try XCTUnwrap(store.load()).properties.map(\.key), ["label"])
    }

    /// The snapshot survives a restart: the file is read back through the
    /// same code path.
    func testTheSnapshotSurvivesARestart() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)
        XCTAssertFalse(store.exists)

        let snapshot = LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
            LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00")
        ])
        try store.save(snapshot)

        // A new store, the way the app reads it after a restart.
        let afterRestart = LiveBarSnapshotStore(appSupportRoot: root)
        XCTAssertTrue(afterRestart.exists)
        XCTAssertEqual(afterRestart.load(), snapshot)
    }

    /// The snapshot lives in the Application Support of the app and never
    /// under the config of the user.
    func testTheSnapshotLivesInTheApplicationSupportOfTheApp() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)

        XCTAssertTrue(store.url.path.contains("SketchyBarStudio"))
        XCTAssertEqual(store.url.lastPathComponent, "LiveBarSnapshot.json")
    }

    // MARK: - The restore

    /// The restore builds the calls that put the snapshot back.
    func testTheRestoreBuildsTheCallsThatPutTheSnapshotBack() {
        let snapshot = LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
            LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00"),
            LiveBarSnapshot.Property(alias: "clock", key: "label.color", value: "0xff111111")
        ])

        let commands = LiveBarService.restoreCommands(for: snapshot)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, ["--set", "clock", "label=09:00"])
        XCTAssertEqual(commands[1].arguments, ["--set", "clock", "label.color=0xff111111"])
    }

    /// A restore that cannot put everything back says what it could not
    /// put back, and the rest is left alone.
    func testAPartialRestoreReportsWhatItCouldNotPutBack() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)
        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
            LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00"),
            LiveBarSnapshot.Property(alias: "gone", key: "label", value: "08:00")
        ]))

        let runner = FakeRunner()
        runner.refusedAliases = ["gone"]

        let outcome = LiveBarService.restore(snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.restoredProperties, 1)
        XCTAssertEqual(outcome.failures.count, 1)
        let failure = outcome.failures.first ?? ""
        XCTAssertTrue(failure.contains("gone"))
        XCTAssertFalse(failure.contains("clock"))

        // The property that could not be put back stays in the snapshot,
        // so the Restore button stays there for the rest.
        let kept = try XCTUnwrap(store.load())
        XCTAssertEqual(kept.properties.map(\.alias), ["gone"])
    }

    /// A restore that puts everything back clears the snapshot.
    func testAFullRestoreClearsTheSnapshot() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)
        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
            LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00")
        ]))

        let outcome = LiveBarService.restore(snapshotStore: store, runner: FakeRunner())
        XCTAssertEqual(outcome.restoredProperties, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertFalse(store.exists)
    }

    /// A restore without a snapshot says that there is nothing to put back.
    func testARestoreWithoutASnapshotSaysSo() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)

        let outcome = LiveBarService.restore(snapshotStore: store, runner: FakeRunner())
        XCTAssertFalse(outcome.hasSnapshot)
        XCTAssertEqual(outcome.restoredProperties, 0)
    }

    // MARK: - The daemon

    /// The push only asks the daemon about the items whose values
    /// changed, and it only pushes the values that really changed.
    func testThePushOnlyAsksAboutTheItemsThatChanged() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ]),
                BarRenderItemModel(alias: "battery", properties: [
                    BarRenderProperty(key: "label", value: "50%")
                ])
            ],
            warnings: []
        )

        let runner = FakeRunner()
        runner.values = [
            "clock": ["label.value": "09:00"],
            "battery": ["label.value": "50%"]
        ]

        // The first push reads every item of the plan.
        let first = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(runner.queries, ["clock", "battery"])
        XCTAssertEqual(first.pushedItems, 1)
        XCTAssertEqual(first.pushedProperties, 1)

        // The second push has nothing to do: no value changed.
        runner.forgetQueries()
        let second = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner, known: first.known)
        XCTAssertTrue(runner.queries.isEmpty)
        XCTAssertEqual(second.pushedItems, 0)
        XCTAssertEqual(second.pushedProperties, 0)
    }

    /// A push without a daemon pushes nothing.
    func testThePushPushesNothingWhenTheDaemonIsNotRunning() throws {        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let runner = FakeRunner()
        runner.isRunning = false

        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertTrue(outcome.daemonIsMissing)
        XCTAssertEqual(outcome.pushedItems, 0)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(store.exists)
    }

    /// An item that is not on the live bar is reported and not pushed.
    func testAnItemThatIsNotOnTheLiveBarIsReportedAndNotPushed() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let runner = FakeRunner()
        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.pushedItems, 0)
        XCTAssertEqual(outcome.notes.count, 1)
        XCTAssertTrue(outcome.notes[0].contains("clock"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: - The debounce

    /// A run of changes is one push and not one push per change.
    func testTheDebounceTurnsManyChangesIntoOnePush() {
        let expectation = expectation(description: "the push runs once")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        let counter = Counter()
        let debouncer = LiveBarDebouncer()
        for _ in 0..<10 {
            debouncer.schedule {
                counter.increment()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)
        // The other steps of the debounce may still be waiting, so the
        // count is read after they had their chance.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(counter.value, 1)
    }

    /// The mode `While Editing` asks for a push after the debounce, and the
    /// mode `Never` asks for nothing.
    @MainActor
    func testTheModeWhileEditingAsksForThePushAndTheModeNeverDoesNot() async throws {
        let defaults = try makeDefaults()
        let store = try makeStore(defaults: defaults)
        let valueID = try XCTUnwrap(store.files.first?.values.first?.id)

        store.liveUpdateMode = .never
        store.update(valueID: valueID, draftValue: "changed once")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(store.pendingLiveBarPush)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed twice")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let pending = try XCTUnwrap(store.pendingLiveBarPush)
        XCTAssertGreaterThan(pending.preview.propertyCount, 0)
    }

    // MARK: - The config of the user

    /// The push changes nothing on the disk of the user.
    func testThePushChangesNothingOnDisk() throws {
        let root = try makeTestRoot()
        let configRoot = root.appendingPathComponent("config")
        try write("""
        sbar.add("item", "clock", {
            position = "right",
            label = "10:00",
        })
        """, to: configRoot.appendingPathComponent("items/clock.lua"))

        let before = try snapshot(of: configRoot)

        let plan = PreviewConfigBridge.plan(forConfigRoot: configRoot)
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]

        let outcome = LiveBarService.push(plan: plan,
                                         snapshotStore: LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support")),
                                         runner: runner)

        XCTAssertEqual(outcome.pushedItems, 1)
        XCTAssertEqual(before, try snapshot(of: configRoot))
    }

    // MARK: - The query of the daemon

    /// The reader of the reply of a query takes the values of the item.
    func testTheQueryReaderReadsTheValuesOfAnItem() {
        let reply = """
        {
        	"name": "clock",
        	"type": "item",
        	"geometry": {
        		"drawing": "on",
        		"position": "right",
        		"background": {
        			"color": "0xff000000"
        		}
        	},
        	"icon": {
        		"value": "SF:Clock",
        		"color": "0xffffffff"
        	},
        	"label": {
        		"value": "10:00",
        		"color": "0xff00ff00"
        	},
        	"scripting": {
        		"script": "sketchybar --set clock label=12:00",
        		"update_freq": 5,
        		"updates": "on"
        	},
        	"bounding_rects": {
        		"display-1": {
        			"origin": [ 0.000000, 0.000000 ],
        			"size": [ 100.000000, 25.000000 ]
        		}
        	}
        }
        """

        let values = LiveBarQuery.values(in: reply)
        XCTAssertEqual(values["name"], "clock")
        XCTAssertEqual(values["label.value"], "10:00")
        XCTAssertEqual(values["label.color"], "0xff00ff00")
        XCTAssertEqual(values["icon.value"], "SF:Clock")
        XCTAssertEqual(values["geometry.position"], "right")
        XCTAssertEqual(values["geometry.background.color"], "0xff000000")
        XCTAssertEqual(values["scripting.updates"], "on")
        XCTAssertEqual(values["scripting.update_freq"], "5")
    }

    /// The daemon does not escape the backslash of a value, so the reader
    /// has to keep it.
    func testTheQueryReaderKeepsTheBackslashOfAValue() {
        let reply = "{ \"label\": { \"value\": \"C:\\Users\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertEqual(values["label.value"], "C:\\Users")
    }

    /// The refusal of the daemon is found in its answer.
    func testTheRefusalOfTheDaemonIsFound() {
        let output = "[2026-10-21 12:00:00] [!] Set: Item not found 'clock'\n"
        XCTAssertEqual(LiveBarCommandResult.failure(in: output),
                       "Set: Item not found 'clock'")
        XCTAssertNil(LiveBarCommandResult.failure(in: "{ \"name\": \"clock\" }"))
    }

    // MARK: - The daemon of the machine

    /// The push changes the live bar and the restore puts it back.
    ///
    /// The test needs a running daemon: it is skipped when the daemon does
    /// not answer, and it never fails the build because of that.
    func testThePushAndTheRestorePutTheLiveBarBack() throws {
        let runner = SketchyBarRunner()
        guard runner.daemonIsRunning() else {
            throw XCTSkip("the daemon of SketchyBar is not running")
        }

        let alias = try XCTUnwrap(firstItemOfTheLiveBar())
        let live = try XCTUnwrap(runner.liveValues(of: alias))
        let padding = try XCTUnwrap(live["label.padding_left"])
        let changed = (Int(padding) ?? 0) + 1

        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: alias, properties: [
                    BarRenderProperty(key: "label.padding_left", value: String(changed))
                ])
            ],
            warnings: []
        )

        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertEqual(outcome.pushedItems, 1)
        XCTAssertEqual(runner.liveValues(of: alias)?["label.padding_left"], String(changed))

        let restore = LiveBarService.restore(snapshotStore: store, runner: runner)
        XCTAssertTrue(restore.failures.isEmpty, "\(restore.failures)")
        XCTAssertEqual(runner.liveValues(of: alias)?["label.padding_left"], padding)
    }

    /// The name of the first item of the live bar.
    private func firstItemOfTheLiveBar() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--query", "bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        guard let start = text.range(of: "\"items\": [") else { return nil }
        guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else { return nil }

        return text[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .compactMap { part -> String? in
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.hasPrefix("\""), name.hasSuffix("\"") else { return nil }
                return String(name.dropFirst().dropLast())
            }
            .first
    }

    // MARK: - The helpers

    /// The runner of the tests: it answers like a daemon would, without
    /// one.
    private final class FakeRunner: LiveBarRunning {
        /// The live values the runner holds, keyed by the alias.
        var values: [String: [String: String]] = [:]
        /// The aliases the runner refuses to set.
        var refusedAliases: Set<String> = []
        /// True when the daemon answers.
        var isRunning = true
        /// The calls the runner received.
        private(set) var calls: [LiveBarCommand] = []
        /// The items the runner was asked about.
        private(set) var queries: [String] = []

        /// Forgets the items the runner was asked about.
        func forgetQueries() {
            queries = []
        }

        func daemonIsRunning() -> Bool { isRunning }

        func liveValues(of alias: String) -> [String: String]? {
            queries.append(alias)
            return values[alias]
        }

        func run(_ command: LiveBarCommand) -> LiveBarCommandResult {
            calls.append(command)
            guard command.arguments.first == "--set", command.arguments.count > 1 else {
                return LiveBarCommandResult(output: "")
            }
            let alias = command.arguments[1]
            guard !refusedAliases.contains(alias) else {
                return LiveBarCommandResult(output: "", failure: "Item not found '\(alias)'")
            }
            return LiveBarCommandResult(output: "")
        }
    }

    /// A counter that several threads can use.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    /// The defaults of the test, in a suite of their own.
    private func makeDefaults() throws -> UserDefaults {
        let name = "LiveBarPushTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A store with a config of its own.
    @MainActor
    private func makeStore(defaults: UserDefaults) throws -> SketchyBarStore {
        let root = try makeTestRoot()
        let configRoot = root.appendingPathComponent("config")
        try write("""
        sbar.add("item", "clock", {
            position = "right",
            label = "10:00",
        })
        """, to: configRoot.appendingPathComponent("items/clock.lua"))

        let libraryURL = root.appendingPathComponent("config-library.json")
        let store = SketchyBarStore(configRoot: configRoot,
                                    libraryURL: libraryURL,
                                    defaults: defaults)
        store.reload()
        return store
    }

    /// A folder of the test.
    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioLiveBarPushTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The bytes of every file under a folder.
    private func snapshot(of root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                               includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var states: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            states[url.path] = try Data(contentsOf: url)
        }
        return states
    }
}
