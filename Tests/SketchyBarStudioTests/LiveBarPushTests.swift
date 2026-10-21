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
        let store = LiveBarSnapshotStore()

        XCTAssertTrue(store.url.path.contains("SketchyBarStudio"))
        XCTAssertEqual(store.url.lastPathComponent, "LiveBarSnapshot.json")
    }

    /// The file of the snapshot belongs to the user alone.
    func testTheSnapshotFileBelongsToTheUserAlone() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
                                           LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00")
                                       ]))

        let manager = FileManager.default
        let file = try XCTUnwrap(manager.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(file.int16Value, 0o600)

        let folder = try XCTUnwrap(manager.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(folder.int16Value, 0o700)
    }

    /// A snapshot that was edited by hand never holds a script, so the
    /// daemon cannot run it on a Restore.
    func testASnapshotThatWasEditedByHandNeverHoldsAScript() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)
        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
                                           LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00")
                                       ]))

        // The file on disk gets a script, the way a hand edit would.
        var text = try String(contentsOf: store.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"key\" : \"label\"",
                                         with: "\"key\" : \"script\"")
        try text.write(to: store.url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertFalse(loaded.properties.contains { $0.key == "script" })
    }

    /// A name the daemon reads as a regular expression never reaches the
    /// daemon: the daemon would set every item that matches it.
    func testANameThatLooksLikeARegexNeverReachesTheDaemonOnARestore() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root)

        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
                                           LiveBarSnapshot.Property(alias: "clock", key: "label", value: "09:00")
                                       ]))

        // The file on disk gets the name, the way a hand edit would.
        var text = try String(contentsOf: store.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"alias\" : \"clock\"",
                                         with: "\"alias\" : \"/clock/\"")
        try text.write(to: store.url, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertTrue(loaded.properties.isEmpty)

        // A snapshot that is written never holds the name either.
        try store.save(LiveBarSnapshot(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       properties: [
                                           LiveBarSnapshot.Property(alias: "/clock/", key: "label", value: "09:00")
                                       ]))
        let written = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(written.contains("/clock/"))
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

    /// Ten schedules that come at the same time run the push once.
    ///
    /// The test does not say anything about a run of changes that comes
    /// one change after the other: the throttle of the push is the thing
    /// that holds that case.
    func testTenSchedulesAtTheSameTimeRunThePushOnce() {
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

    /// The throttle runs the push while the user keeps typing.
    ///
    /// A change that comes in while the push waits does not push the wait
    /// away, so the push runs again after the interval.
    func testTheThrottleRunsThePushWhileTheUserKeepsTyping() {
        let expectation = expectation(description: "the push runs twice")
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = false

        let counter = Counter()
        let debouncer = LiveBarDebouncer()
        // The user keeps typing for a second and a half.
        for step in 0..<8 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2 * Double(step)) {
                debouncer.schedule {
                    counter.increment()
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5)
        XCTAssertGreaterThanOrEqual(counter.value, 2)
    }

    /// The mode `While Editing` asks for a push after the debounce, and the
    /// mode `Never` asks for nothing.
    ///
    /// The test confirms the push and looks at what the daemon got, so a
    /// push that does nothing cannot pass the test.
    @MainActor
    func testTheModeWhileEditingPushesTheValueAndTheModeNeverDoesNot() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]
        let store = try makeStore(defaults: defaults, runner: runner)
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        store.liveUpdateMode = .never
        store.update(valueID: valueID, draftValue: "changed once")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(store.pendingLiveBarPush)
        XCTAssertTrue(runner.calls.isEmpty)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed twice")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let pending = try XCTUnwrap(store.pendingLiveBarPush)
        XCTAssertGreaterThan(pending.preview.propertyCount, 0)

        store.confirmLiveBarPush()
        try await Task.sleep(nanoseconds: 500_000_000)

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.arguments.first, "--set")
        XCTAssertEqual(call.arguments[1], "clock")
        XCTAssertTrue(call.arguments.contains("label=changed twice"),
                      "the daemon got \(call.arguments)")
    }

    // MARK: - The shape of the calls

    /// A value with an equal sign in it keeps the equal sign: the daemon
    /// splits the argument at the first equal sign
    /// (`src/misc/helpers.h:143-162`).
    func testAValueWithAnEqualSignKeepsIt() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "label", value: "a=b")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        let commands = LiveBarService.pushCommands(for: live.items)
        XCTAssertEqual(commands.first?.arguments, ["--set", "clock", "label=a=b"])
    }

    /// An item the daemon does not know is refused, and the item stays a
    /// candidate, so the next push tries it again.
    func testAnItemTheDaemonDoesNotKnowIsRefusedAndTriedAgain() throws {
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
        runner.refusedAliases = ["clock"]

        let first = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(first.pushedItems, 0)
        XCTAssertEqual(first.failures.count, 1)
        XCTAssertTrue(first.failures[0].contains("clock"))

        // The item was not pushed, so the next push tries it again.
        let second = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner, known: first.known)
        XCTAssertEqual(second.failures.count, 1)
    }

    /// An item that is not on the live bar is tried again by the next
    /// push.
    func testAnItemThatIsNotOnTheLiveBarIsTriedAgain() throws {
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
        let first = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(first.pushedItems, 0)
        XCTAssertNil(first.known["clock"], "the item stays a candidate")

        let second = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner, known: first.known)
        XCTAssertEqual(second.notes.filter { $0.contains("clock") }.count, 1)
    }

    /// A malformed answer of the daemon holds no value, so the item is
    /// not on the live bar as far as the app knows it.
    func testAMalformedAnswerOfTheDaemonHoldsNoValue() {
        let runner = FakeRunner()
        runner.replies = ["clock": "{ \"label\": { \"value\": \"10:00\""]
        XCTAssertNil(runner.liveValues(of: "clock"))
    }

    // MARK: - The rules of the push

    /// The automatic modes push the safe properties of the bar and nothing
    /// else.
    ///
    /// The properties that change the bar of the user are pushed only by
    /// the explicit action of the user.
    func testTheAutomaticModesPushOnlyTheSafePropertiesOfTheBar() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [
                BarRenderProperty(key: "drawing", value: "true"),
                BarRenderProperty(key: "blur_radius", value: "15"),
                BarRenderProperty(key: "height", value: "30"),
                BarRenderProperty(key: "margin", value: "8"),
                BarRenderProperty(key: "color", value: "0xff000000"),
                BarRenderProperty(key: "topmost", value: "true")
            ],
            items: [],
            warnings: []
        )

        XCTAssertEqual(LiveBarService.liveBarProperties(of: plan).map(\.key),
                       ["drawing", "blur_radius"])
        XCTAssertEqual(LiveBarService.destructiveBarProperties(of: plan).map(\.key),
                       ["height", "margin", "color", "topmost"])
    }

    /// The push of the automatic modes never sends a property that
    /// changes the bar of the user.
    func testThePushNeverSendsTheSettingsOfTheBar() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [
                BarRenderProperty(key: "height", value: "30"),
                BarRenderProperty(key: "drawing", value: "true")
            ],
            items: [],
            warnings: []
        )

        let runner = FakeRunner()
        // The daemon writes the settings of the bar flat, next to the
        // keys of the bar itself (`src/bar_manager.c:1096-1119`).
        runner.values = ["bar": ["height": "25", "drawing": "off"]]

        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.pushedProperties, 1)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.arguments, ["--bar", "drawing=true"])
    }

    /// The name of a property of the bar reaches the daemon without the
    /// `bar.` prefix, because the daemon does not know that prefix.
    func testTheNameOfAPropertyOfTheBarReachesTheDaemonWithoutThePrefix() {
        let command = LiveBarCommand.setBar(properties: [
            LiveBarProperty(key: "bar.height", value: "30")
        ])
        XCTAssertEqual(command.arguments, ["--bar", "height=30"])
    }

    /// The settings of the bar are pushed only by the explicit action of
    /// the user, and the action says what changes.
    func testTheSettingsOfTheBarArePushedOnlyByTheExplicitAction() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [
                BarRenderProperty(key: "height", value: "30"),
                BarRenderProperty(key: "margin", value: "8")
            ],
            items: [],
            warnings: []
        )

        let runner = FakeRunner()
        runner.values = ["bar": ["height": "25", "margin": "4"]]

        let changes = LiveBarService.barChanges(of: plan, runner: runner)
        XCTAssertEqual(changes.map(\.key), ["height", "margin"])
        XCTAssertEqual(changes.map(\.oldValue), ["25", "4"])
        XCTAssertEqual(changes.map(\.newValue), ["30", "8"])

        let outcome = LiveBarService.pushBarSettings(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.pushedProperties, 2)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.arguments, ["--bar", "height=30", "margin=8"])
    }

    /// The position of an item is structure and not a value, so it is
    /// never pushed.
    func testThePositionOfAnItemIsNeverPushed() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "position", value: "right"),
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertEqual(live.items.first?.properties.map(\.key), ["label"])
        XCTAssertTrue(live.notes.contains { $0.contains("positions") })
    }

    /// A value that starts with `popup` would put the item into a popup
    /// of another item, so it is refused.
    func testAValueThatStartsWithPopupIsRefused() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "position", value: "popup.clock"),
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertEqual(live.items.first?.properties.map(\.key), ["label"])
        XCTAssertTrue(live.notes.contains { $0.contains("popup") })
    }

    /// A name the daemon reads as a regular expression is never pushed:
    /// the daemon would set every item that matches it.
    func testANameThatLooksLikeARegexIsNeverPushed() {
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "/clock/", properties: [
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let live = LiveBarService.liveItems(of: plan)
        XCTAssertTrue(live.items.isEmpty)
        XCTAssertTrue(live.notes.contains { $0.contains("regular expression") })
    }

    /// The boolean of the config and the boolean of the daemon are the
    /// same value, so the push does not send it again and again.
    func testTheBooleanOfTheConfigAndTheBooleanOfTheDaemonAreTheSameValue() {
        XCTAssertTrue(LiveBarService.sameValue(key: "drawing", planned: "true", live: "on"))
        XCTAssertTrue(LiveBarService.sameValue(key: "label.drawing", planned: "true", live: "on"))
        XCTAssertTrue(LiveBarService.sameValue(key: "scroll_texts", planned: "false", live: "off"))
        XCTAssertTrue(LiveBarService.sameValue(key: "bar.topmost", planned: "window", live: "on"))
        XCTAssertFalse(LiveBarService.sameValue(key: "drawing", planned: "true", live: "off"))
        XCTAssertFalse(LiveBarService.sameValue(key: "label", planned: "10:00", live: "on"))
    }

    /// The push of the automatic modes does not send the boolean of an
    /// item again and again.
    func testThePushDoesNotSendTheBooleanOfTheItemAgain() throws {
        let root = try makeTestRoot()
        let store = LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support"))
        let plan = BarRenderPlan(
            defaults: [],
            bar: [],
            items: [
                BarRenderItemModel(alias: "clock", properties: [
                    BarRenderProperty(key: "drawing", value: "true"),
                    BarRenderProperty(key: "label", value: "10:00")
                ])
            ],
            warnings: []
        )

        let runner = FakeRunner()
        runner.values = ["clock": ["geometry.drawing": "on", "label.value": "10:00"]]

        let outcome = LiveBarService.push(plan: plan, snapshotStore: store, runner: runner)
        XCTAssertEqual(outcome.pushedProperties, 0)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    // MARK: - The store

    /// The push is refused for a source that is not the live config.
    ///
    /// The values of another config would change the bar of the user
    /// without that config saying so, so the control is off and the
    /// message names the source.
    @MainActor
    func testThePushIsRefusedForASourceThatIsNotTheLiveConfig() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        let root = try makeTestRoot()
        let store = try makeStore(defaults: defaults,
                                  runner: runner,
                                  liveConfigURL: root.appendingPathComponent("another-config"))
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        XCTAssertFalse(store.isLiveBarSourceLive)
        XCTAssertNotNil(store.liveBarBlockedReason)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertNil(store.pendingLiveBarPush)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// The "Apply Bar Settings" with no change of the bar never pushes
    /// the items: the action pushes the settings of the bar and nothing
    /// else.
    @MainActor
    func testTheApplyBarSettingsWithNoChangeNeverPushesTheItems() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["bar": ["height": "25"], "clock": ["label.value": "09:00"]]
        let store = try makeStore(defaults: defaults, runner: runner)

        // The config of the test has no settings of the bar, so nothing
        // changes.
        store.requestLiveBarSettingsPush()
        try await Task.sleep(nanoseconds: 500_000_000)
        let pending = try XCTUnwrap(store.pendingLiveBarPush)
        XCTAssertTrue(pending.barChanges.isEmpty)

        store.confirmLiveBarPush()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(runner.calls.isEmpty,
                      "the daemon got \(runner.calls.map(\.arguments))")
    }

    /// The mode `Never` cannot be bypassed by a push that was prepared
    /// while the mode was on.
    ///
    /// The preview of the push runs in the background, and the user can
    /// turn the mode off while it runs. The push must not reach the live
    /// bar then.
    @MainActor
    func testTheModeNeverIsNotBypassedByAPushThatWasPrepared() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]
        // The query of the daemon takes a while, so the preview is still
        // running when the user changes the mode.
        runner.queryDelays = [2]
        let store = try makeStore(defaults: defaults, runner: runner)
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed")
        // The debounce waits, and then the preview starts.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(store.pendingLiveBarPush)

        // The user turns the mode off while the preview runs.
        store.liveUpdateMode = .never
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertNil(store.pendingLiveBarPush,
                     "the preview did not wait for the confirmation of the user")
        XCTAssertTrue(runner.calls.isEmpty,
                      "the daemon got \(runner.calls.map(\.arguments))")
    }

    /// A preview that is older than the newest one does not overwrite
    /// it: the dialog must show the newest values of the user.
    @MainActor
    func testAnOlderPreviewDoesNotOverwriteANewerOne() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]
        // The first query takes a while, so the first preview lands after
        // the second one.
        runner.queryDelays = [2, 0]
        let store = try makeStore(defaults: defaults, runner: runner)

        store.liveUpdateMode = .whileEditing
        store.requestLiveBarPush(structuredOnly: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        store.requestLiveBarPush(structuredOnly: true)

        // The second preview found a change. The live bar takes the value
        // of the config while the first preview is still running.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        runner.setValues(["label.value": "10:00"], for: "clock")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let pending = try XCTUnwrap(store.pendingLiveBarPush)
        XCTAssertEqual(pending.preview.propertyCount, 1,
                       "the older preview won over the newer one")
    }

    /// A push that changed nothing does not use up the confirmation of the
    /// user: the next push asks again.
    @MainActor
    func testAFailedPushDoesNotUseUpTheConfirmationOfTheUser() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.isRunning = false
        let store = try makeStore(defaults: defaults, runner: runner)
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNotNil(store.pendingLiveBarPush)
        store.confirmLiveBarPush()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(store.statusMessage.contains("not running"))

        // The push changed nothing, so the user is asked again.
        store.update(valueID: valueID, draftValue: "changed again")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNotNil(store.pendingLiveBarPush)
    }

    /// Two pushes that follow each other do not fight: the older plan
    /// does not win over the newer one.
    @MainActor
    func testTwoPushesThatFollowEachOtherDoNotFight() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]
        let store = try makeStore(defaults: defaults, runner: runner)
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed once")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        store.confirmLiveBarPush()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // The push that follows is slow, so the request that comes after
        // it has to wait for it.
        runner.delays = [0, 3]
        store.update(valueID: valueID, draftValue: "changed twice")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // The request comes in while the slow push runs.
        store.update(valueID: valueID, draftValue: "changed three times")
        store.requestLiveBarPush(structuredOnly: true)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let values = runner.calls.flatMap(\.arguments).filter { $0.hasPrefix("label=") }
        XCTAssertEqual(values.last, "label=changed three times",
                       "the daemon got \(runner.calls.map(\.arguments))")

        // The app knows the values of the live bar, so the next push has
        // nothing to do. An older plan that won would send the value
        // again.
        runner.forgetCalls()
        store.requestLiveBarPush(structuredOnly: true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(runner.calls.isEmpty,
                      "the daemon got \(runner.calls.map(\.arguments))")
    }

    /// A restore drops the values of the last push, so the next push asks
    /// the daemon again.
    @MainActor
    func testARestoreDropsTheValuesOfTheLastPush() async throws {
        let defaults = try makeDefaults()
        let runner = FakeRunner()
        runner.values = ["clock": ["label.value": "09:00"]]
        let store = try makeStore(defaults: defaults, runner: runner)
        let valueID = try XCTUnwrap(store.files.first?.values.first { $0.keyPath == "label" }?.id)

        store.liveUpdateMode = .whileEditing
        store.update(valueID: valueID, draftValue: "changed")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        store.confirmLiveBarPush()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(runner.calls.isEmpty)

        store.restoreLiveBar()
        try await Task.sleep(nanoseconds: 500_000_000)

        // The next push asks the daemon about the item again.
        runner.forgetQueries()
        store.update(valueID: valueID, draftValue: "changed again")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(runner.queries.contains("clock"),
                      "the next push asks the daemon about the item")
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

    /// The daemon does not escape the backslash of a value, so a value
    /// with a backslash in it cannot be read back with certainty and is
    /// left out.
    func testTheQueryReaderLeavesOutAValueWithABackslash() {
        let reply = "{ \"label\": { \"value\": \"C:\\Users\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertNil(values["label.value"])
    }

    /// A quote inside a value cuts the value short, so the value is not
    /// readable and the rest of the reply still is.
    func testTheQueryReaderLeavesOutAValueWithAQuoteInIt() {
        let reply = "{ \"label\": { \"value\": \"He said \"hi\"\" }, \"icon\": { \"value\": \"SF:Clock\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertNil(values["label.value"])
        XCTAssertEqual(values["icon.value"], "SF:Clock")
    }

    /// A quote in a value followed by a comma breaks the reply: the
    /// reader would read the value short and the rest of the reply wrong.
    ///
    /// Such a reply is refused as a whole, so the value that was cut
    /// short is never stored and a Restore never writes it back.
    func testTheQueryReaderRefusesAValueWithARawQuoteInIt() {
        let reply = "{ \"label\": { \"value\": \"He said \", hi\" }, \"icon\": { \"value\": \"SF:Clock\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertNil(values["label.value"])
        XCTAssertNil(values["icon.value"])
    }

    /// A newline in a value is a newline of the value, so the reader keeps
    /// it and reads the rest of the reply.
    func testTheQueryReaderKeepsANewlineInAValue() {
        let reply = "{ \"label\": { \"value\": \"one\ntwo\" }, \"icon\": { \"value\": \"SF:Clock\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertEqual(values["label.value"], "one\ntwo")
        XCTAssertEqual(values["icon.value"], "SF:Clock")
    }

    /// A reply that ends in the middle is not read as a whole, so the
    /// value that was cut is left out.
    func testTheQueryReaderLeavesOutTheValueOfATruncatedReply() {
        let reply = "{ \"label\": { \"value\": \"10:00\""
        let values = LiveBarQuery.values(in: reply)
        XCTAssertNil(values["label.value"])
    }

    /// A value that ends with a backslash cannot be read back, so it is
    /// left out.
    func testTheQueryReaderLeavesOutAValueWithATrailingBackslash() {
        let reply = "{ \"label\": { \"value\": \"C:\\\" } }"
        let values = LiveBarQuery.values(in: reply)
        XCTAssertNil(values["label.value"])
    }

    /// The refusal of the daemon is found in its answer.
    ///
    /// The refusal always starts the answer of the daemon, so an answer
    /// that only holds `[!]` in a value is not a refusal.
    func testTheRefusalOfTheDaemonIsFound() {
        let output = "[!] Set: Item not found 'clock'\n"
        XCTAssertEqual(LiveBarCommandResult.failure(in: output),
                       "Set: Item not found 'clock'")
        XCTAssertNil(LiveBarCommandResult.failure(in: "{ \"name\": \"clock\" }"))
        XCTAssertNil(LiveBarCommandResult.failure(in: "{ \"label\": { \"value\": \"[!] hello\" } }"))
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
    private final class FakeRunner: LiveBarRunning, @unchecked Sendable {
        /// The live values the runner holds, keyed by the alias.
        var values: [String: [String: String]] = [:]
        /// The raw answers of the runner, keyed by the alias.
        ///
        /// An answer that is given this way is read by the reader of the
        /// app, so a broken answer can be held on a machine without a
        /// daemon.
        var replies: [String: String] = [:]
        /// The aliases the runner refuses to set.
        var refusedAliases: Set<String> = []
        /// True when the daemon answers.
        var isRunning = true
        /// The calls the runner received.
        private(set) var calls: [LiveBarCommand] = []
        /// The items the runner was asked about.
        private(set) var queries: [String] = []
        /// The time every call takes, in the order of the calls.
        var delays: [TimeInterval] = []
        /// The time every query takes, in the order of the queries.
        ///
        /// A query that is slow stands for a daemon that needs a while,
        /// so two previews can be in flight at the same time.
        var queryDelays: [TimeInterval] = []
        /// The lock of the runner: a push runs in the background.
        private let lock = NSLock()

        /// Sets the live values of an item.
        func setValues(_ values: [String: String], for alias: String) {
            lock.lock()
            defer { lock.unlock() }
            self.values[alias] = values
        }

        /// Forgets the items the runner was asked about.
        func forgetQueries() {
            lock.lock()
            defer { lock.unlock() }
            queries = []
        }

        /// Forgets the calls the runner received.
        func forgetCalls() {
            lock.lock()
            defer { lock.unlock() }
            calls = []
        }

        func daemonIsRunning() -> Bool { isRunning }

        func liveValues(of alias: String) -> [String: String]? {
            lock.lock()
            let index = queries.count
            queries.append(alias)
            lock.unlock()
            if index < queryDelays.count {
                Thread.sleep(forTimeInterval: queryDelays[index])
            }
            lock.lock()
            let reply = replies[alias]
            let known = values[alias]
            lock.unlock()
            if let reply {
                let parsed = LiveBarQuery.values(in: reply)
                return parsed.isEmpty ? nil : parsed
            }
            return known
        }

        func run(_ command: LiveBarCommand) -> LiveBarCommandResult {
            lock.lock()
            let index = calls.count
            calls.append(command)
            let delay = index < delays.count ? delays[index] : 0
            lock.unlock()
            // A call that is slow stands for a daemon that needs a while,
            // so two pushes can follow each other.
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }

            lock.lock()
            defer { lock.unlock() }
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
    ///
    /// The config of the store is the live config of SketchyBar for the
    /// test, so the push is allowed. The runner and the file of the
    /// snapshot are the ones of the test, so the test never reaches the
    /// daemon of the user and never writes the snapshot of the user.
    @MainActor
    private func makeStore(defaults: UserDefaults,
                           runner: FakeRunner = FakeRunner(),
                           liveConfigURL: URL? = nil) throws -> SketchyBarStore {
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
                                    defaults: defaults,
                                    liveBarRunner: runner,
                                    liveBarSnapshotStore: LiveBarSnapshotStore(appSupportRoot: root.appendingPathComponent("support")),
                                    liveSketchyBarConfigURL: liveConfigURL ?? configRoot)
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
