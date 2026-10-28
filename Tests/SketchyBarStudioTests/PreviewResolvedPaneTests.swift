import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the preview pane that shows the resolved config.
///
/// The pane shows the config a real Lua interpreter resolved: the values
/// are the values of the config, the types are the types of the config and
/// the order is the order of the load, which is the order of the daemon.
/// The unsaved draft of the app is applied on top of the resolved config.
final class PreviewResolvedPaneTests: XCTestCase {
    // MARK: - The fixtures

    /// The timer of the scripts of the items stops when the tests are done.
    ///
    /// The vendored core holds one preview at a time, and the timer of the
    /// preview builds a tree of its own, so a timer that runs while another
    /// test holds a preview makes that test fail.
    override func tearDown() async throws {
        await BarRendererService.shared.stopLiveValues()
    }

    /// The root of a fixture of the tests.
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The files of a fixture, with the drafts of the app.
    ///
    /// The key of the drafts is the path of the file relative to the root
    /// of the config, the way the sidebar names a file.
    private func files(of root: URL, drafts: [String: String] = [:]) -> [BarRenderFile] {
        let locator = SketchyBarConfigLocator()
        return locator.configFiles(in: root).compactMap { url in
            guard let kind = locator.kind(for: url) else { return nil }
            let relative = PreviewConfigBridge.relativePath(of: url, in: root)
            return BarRenderFile(url: url, kind: kind, contents: drafts[relative])
        }
    }

    /// The request of a render of a fixture.
    private func request(of root: URL, drafts: [String: String] = [:]) -> BarRenderRequest {
        BarRenderRequest(files: files(of: root, drafts: drafts),
                         root: root,
                         displayWidthPoints: 480,
                         displayHeightPoints: 25)
    }

    /// The plan the pane shows for a fixture.
    private func plan(of root: URL, drafts: [String: String] = [:]) -> BarRenderPlan {
        BarRendererService.plan(for: request(of: root, drafts: drafts))
    }

    /// A copy of a fixture in a temporary directory.
    ///
    /// The tests that follow a change of a file of the config change the
    /// copy, so the fixture of the tree is never touched.
    private func copyOfFixture(_ name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioResolvedPaneTests")
            .appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture(name), to: root)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: parent)
        }
        return root
    }

    /// The number of runs of the Lua of a root that the cache did not
    /// answer.
    ///
    /// The count is per root, so a test of one config is not moved by a
    /// render of another one.
    private func runs(of root: URL) -> Int {
        BarRendererService.resolvedPlans.runs(of: root.standardizedFileURL.path)
    }

    /// The text of the two items of the fixture of two items, with the
    /// label of the second item.
    private func twoItemDraft(label: String) -> String {
        """
        sbar.add("item", "one", {
        \tposition = "left",
        \tlabel = { string = "one" },
        })

        sbar.add("item", "two", {
        \tposition = "right",
        \tlabel = { string = "\(label)" },
        })
        """
    }

    /// The text of a draft of the entrypoint of a broken config.
    ///
    /// The draft is Lua, so the parser reads it as Lua and keeps the item.
    private func brokenDraft(label: String) -> String {
        """
        #!/usr/bin/env lua
        sbar.add("item", "typed", {
        \tposition = "left",
        \tlabel = { string = "\(label)" },
        })
        """
    }

    /// The value of a property of an item of a plan.
    private func value(_ plan: BarRenderPlan, _ alias: String, _ key: String) -> String? {
        plan.items
            .first { $0.alias == alias }?
            .properties
            .first { $0.key == key }?
            .value
    }

    /// The aliases of the items of a plan, in the order of the plan.
    private func aliases(_ plan: BarRenderPlan) -> [String] {
        plan.items.map(\.alias)
    }

    // MARK: - The resolved config

    /// The pane shows the values the config really has.
    ///
    /// The colour of the item comes from the module of the config, so the
    /// parser cannot read it and the resolver can. The pane shows the
    /// colour of the config and not the default of SketchyBar.
    func testThePaneShowsTheResolvedValues() throws {
        let plan = self.plan(of: fixture("lua-resolve"))

        // The colour of the module of the config.
        XCTAssertEqual(value(plan, "clock", "background.color"), "0xff112233")
        // The font of the module of the config.
        XCTAssertEqual(value(plan, "clock", "icon.font.family"), "Liga SFMono Nerd Font")
        // The value the module computes.
        XCTAssertEqual(value(plan, "clock", "icon.font.size"), "12")
        // The concatenation of the module.
        XCTAssertEqual(value(plan, "clock", "label.string"), "10:00 Liga SFMono Nerd Font")
        // The chain of the requires.
        XCTAssertEqual(value(plan, "extra", "label.string"), "extra")
        XCTAssertEqual(value(plan, "extra", "background.color"), "0xff112233")
    }

    /// Every item of the resolved config knows the file that declared it
    /// and the number of the declaration inside that file.
    func testEveryItemKnowsTheFileThatDeclaredIt() throws {
        let plan = self.plan(of: fixture("lua-resolve"))

        let clock = try XCTUnwrap(plan.items.first { $0.alias == "clock" })
        XCTAssertEqual(clock.origin?.file, "items.lua")
        XCTAssertEqual(clock.origin?.index, 0)

        let extra = try XCTUnwrap(plan.items.first { $0.alias == "extra" })
        XCTAssertEqual(extra.origin?.file, "extra.lua")
        XCTAssertEqual(extra.origin?.index, 0)
    }

    /// The order of the items is the order of the load, and not the order
    /// of the names of the files.
    func testTheOrderOfTheItemsIsTheOrderOfTheLoad() throws {
        let plan = self.plan(of: fixture("lua-load-order"))

        XCTAssertEqual(aliases(plan), ["first", "second"],
                       "the loader of the fixture loads the file of the first item first")

        let parsed = PreviewConfigBridge.plan(forConfigRoot: fixture("lua-load-order"))
        XCTAssertEqual(aliases(parsed), ["second", "first"],
                       "the parser reads the files in the order of their names")

        // Every item knows the file that declared it.
        let first = try XCTUnwrap(plan.items.first { $0.alias == "first" })
        XCTAssertEqual(first.origin?.file, "z_first.lua")
        let second = try XCTUnwrap(plan.items.first { $0.alias == "second" })
        XCTAssertEqual(second.origin?.file, "a_second.lua")
    }

    // MARK: - The draft on top of the resolved config

    /// The draft of the second file lands on the item of the second file.
    ///
    /// The two files of the fixture declare one item each, so a draft that
    /// lands on the wrong item is a draft that lands on the item of
    /// another file.
    func testTheDraftOfTheSecondFileLandsOnTheSecondItem() throws {
        let root = fixture("lua-draft-two-files")
        let draft = """
        sbar.add("item", "second", {
        \tposition = "right",
        \tlabel = { string = "drafted" },
        })
        """

        let plan = self.plan(of: root, drafts: ["second.lua": draft])

        XCTAssertEqual(value(plan, "second", "label.string"), "drafted",
                       "the draft belongs to the item of the second file")
        XCTAssertEqual(value(plan, "first", "label.string"), "first",
                       "the draft of the second file must not land on the item of the first file")
    }

    /// The draft of the second item of a file lands on the second item.
    ///
    /// The file of the fixture declares two items, so a draft that lands on
    /// the wrong item is a draft that lands on the first one.
    func testTheDraftOfTheSecondItemLandsOnTheSecondItem() throws {
        let root = fixture("lua-draft-two-items")
        let draft = """
        sbar.add("item", "one", {
        \tposition = "left",
        \tlabel = { string = "one" },
        })

        sbar.add("item", "two", {
        \tposition = "right",
        \tlabel = { string = "drafted" },
        })
        """

        let plan = self.plan(of: root, drafts: ["items.lua": draft])

        XCTAssertEqual(value(plan, "two", "label.string"), "drafted",
                       "the draft belongs to the second item of the file")
        XCTAssertEqual(value(plan, "one", "label.string"), "one",
                       "the draft of the second item must not land on the first one")
    }

    /// A draft that is an expression keeps the value of the resolved config,
    /// and the pane says so.
    ///
    /// The app cannot run the draft, so it cannot read the value of an
    /// expression. The value of the resolved config is the value of the
    /// config on the disk, and the user is told that the edit is not
    /// shown.
    func testADraftThatIsAnExpressionKeepsTheResolvedValue() throws {
        let root = fixture("lua-draft-expression")
        let draft = """
        sbar.add("item", "clock", {
        \tposition = "right",
        \tlabel = { string = "10:00" },
        \ticon = { color = colors.red },
        })
        """

        let plan = self.plan(of: root, drafts: ["items.lua": draft])

        XCTAssertEqual(value(plan, "clock", "icon.color"), "0xff00ff00",
                       "the value of the resolved config has to stay")
        XCTAssertTrue(plan.warnings.contains { $0.contains("is an expression") },
                      "the pane has to say that the edit is not shown")
        XCTAssertTrue(plan.warnings.contains { $0.contains("cannot show your edit") },
                      "the pane has to say that the edit is not shown")
    }

    /// A value the draft adds that the app cannot read is reported too.
    ///
    /// The app cannot run the draft, so it cannot read an expression. The
    /// resolved config has no value for that key, so the pane cannot show
    /// the edit and has to say so instead of dropping it without a word.
    func testADraftThatAddsAnUnreadableValueIsReported() throws {
        let root = fixture("lua-draft-two-items")
        let draft = """
        sbar.add("item", "one", {
        \tposition = "left",
        \tlabel = { string = "one" },
        })

        sbar.add("item", "two", {
        \tposition = "right",
        \tlabel = { string = "two" },
        \ticon = { color = colors.red },
        })
        """

        let plan = self.plan(of: root, drafts: ["items.lua": draft])

        XCTAssertTrue(plan.warnings.contains { $0.contains("'icon.color'") },
                      "the pane has to name the value it cannot show")
        XCTAssertNil(value(plan, "two", "icon.color"),
                     "the app cannot read the expression, so the preview cannot show the value")
    }

    /// A draft of an item that the resolved config does not have is
    /// reported.
    ///
    /// The item was typed after the config was resolved, so the preview
    /// cannot show it. The user has to know that the item is missing.
    func testADraftOfAnItemTheResolverDidNotProduceIsReported() throws {
        let root = fixture("lua-draft-two-items")
        let draft = """
        sbar.add("item", "one", {
        \tposition = "left",
        \tlabel = { string = "one" },
        })

        sbar.add("item", "two", {
        \tposition = "right",
        \tlabel = { string = "two" },
        })

        sbar.add("item", "three", {
        \tposition = "center",
        \tlabel = { string = "three" },
        })
        """

        let plan = self.plan(of: root, drafts: ["items.lua": draft])

        XCTAssertEqual(aliases(plan), ["one", "two"],
                       "the item the resolver did not produce cannot be shown")
        XCTAssertTrue(plan.warnings.contains { $0.contains("'three'") },
                      "the pane has to name the item the preview cannot show")
    }

    /// A file that declares its items in a loop does not line up.
    ///
    /// The calls of the file run twice, so the number of a declaration of
    /// the file is not the number of the calls of the file. The name of the
    /// item names the declaration then, so the draft lands on the item it
    /// belongs to and on no other one.
    func testADraftOfAFileThatDeclaresItsItemsInALoadLandsOnTheRightItem() throws {
        let root = fixture("lua-draft-loop")
        let draft = """
        for index = 1, 2 do
        \tsbar.add("item", "looped", {
        \t\tposition = "left",
        \t\tlabel = { string = "loop" },
        \t})
        end

        sbar.add("item", "last", {
        \tposition = "right",
        \tlabel = { string = "drafted" },
        })
        """

        let plan = self.plan(of: root, drafts: ["items.lua": draft])

        XCTAssertEqual(value(plan, "last", "label.string"), "drafted",
                       "the draft belongs to the item 'last'")
        XCTAssertEqual(value(plan, "looped", "label.string"), "loop",
                       "the draft must not land on the item of the loop")
    }

    /// A draft of the app does not run the Lua of the config again.
    ///
    /// The run of the Lua is the expensive half of a render, and the pane
    /// renders again on every keystroke of a draft. The resolution is kept
    /// while the files on disk are the same, so the second plan of the
    /// same config reuses the first one and only the draft changes.
    func testADraftDoesNotRunTheLuaOfTheConfigAgain() throws {
        let root = try copyOfFixture("lua-draft-two-items")

        let before = runs(of: root)
        let first = self.plan(of: root, drafts: ["items.lua": twoItemDraft(label: "drafted one")])
        XCTAssertEqual(runs(of: root), before + 1,
                       "the first plan of a config has to run the Lua")

        let second = self.plan(of: root, drafts: ["items.lua": twoItemDraft(label: "drafted two")])
        XCTAssertEqual(runs(of: root), before + 1,
                       "a draft of the app must not run the Lua of the config again")

        XCTAssertEqual(value(first, "two", "label.string"), "drafted one")
        XCTAssertEqual(value(second, "two", "label.string"), "drafted two",
                       "the second plan has to show its own draft")
    }

    /// A file of the config that changed on disk is resolved again.
    ///
    /// The resolution is only reused while the files on disk are the same,
    /// so an edit of the config on disk reaches the bar.
    func testAFileThatChangedOnDiskIsResolvedAgain() throws {
        let root = try copyOfFixture("lua-resolve")

        XCTAssertEqual(value(self.plan(of: root), "clock", "label.string"),
                       "10:00 Liga SFMono Nerd Font")

        let settings = root.appendingPathComponent("settings.lua")
        let text = try String(contentsOf: settings, encoding: .utf8)
        try text
            .replacingOccurrences(of: "Liga SFMono Nerd Font", with: "A Shorter Font")
            .write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertEqual(value(self.plan(of: root), "clock", "label.string"),
                       "10:00 A Shorter Font",
                       "a file that changed on disk has to be resolved again")
    }

    /// A config that times out is not run again for a draft.
    ///
    /// A config whose Lua hits the deadline would otherwise run the
    /// interpreter and time out on every keystroke of a draft. The timeout
    /// failure is cached while the files on disk are the same, and the plan
    /// of the parser still shows the draft.
    func testAConfigThatTimesOutDoesNotRunTheLuaAgainForADraft() throws {
        let root = try copyOfFixture("lua-infinite")
        let before = runs(of: root)

        _ = self.plan(of: root, drafts: ["sketchybarrc": brokenDraft(label: "one")])
        XCTAssertEqual(runs(of: root), before + 1,
                       "the first plan of a timed-out config has to run the Lua")

        let plan = self.plan(of: root, drafts: ["sketchybarrc": brokenDraft(label: "two")])
        XCTAssertEqual(runs(of: root), before + 1,
                       "a draft of the app must not run the Lua of a timed-out config again")
        XCTAssertEqual(value(plan, "typed", "label.string"), "two",
                       "the parser path still shows the draft")
    }

    // MARK: - The fallback

    /// A config that cannot run falls back to the parser, and the pane says
    /// so.
    func testAConfigThatCannotRunFallsBackToTheParser() throws {
        let plan = self.plan(of: fixture("lua-throws"))

        XCTAssertTrue(plan.warnings.contains { $0.contains("not resolved with Lua") },
                      "the pane has to say that the config was not resolved")
        XCTAssertEqual(plan.items.count, 0,
                       "the parser reads no item of the broken config")
    }

    /// A shell config keeps the path of the parser, and the pane says why.
    ///
    /// The config has no Lua entrypoint, so the parser is the only path
    /// for it. The values on the bar are the values the parser can read,
    /// and the pane has to say that instead of showing them as the values
    /// of the config.
    func testAShellConfigKeepsThePathOfTheParser() throws {
        let root = fixture("lua-shell")
        let plan = self.plan(of: root)

        XCTAssertEqual(aliases(plan), ["shell"],
                       "the parser reads the item of the shell config")
        XCTAssertEqual(value(plan, "shell", "label"), "shell")
        XCTAssertTrue(plan.warnings.contains { $0.contains("not resolved with Lua") },
                      "the pane has to say that the config was not resolved")
        XCTAssertTrue(plan.warnings.contains { $0.contains("no Lua entrypoint") },
                      "the pane has to name the reason the config was not resolved")
    }

    /// The pane says why a shell config is read by the parser.
    ///
    /// The warning of the plan is the warning of the pane: the render
    /// keeps the warnings of the plan and the pane shows them.
    func testThePaneSaysWhyAShellConfigIsReadByTheParser() async throws {
        let result = try await BarRendererService.shared.render(request(of: fixture("lua-shell")))

        XCTAssertTrue(result.warnings.contains { $0.contains("no Lua entrypoint") },
                      "the pane has to name the reason the parser read the config")
    }

    /// A config that is not open is rendered in the order of its files when
    /// it cannot be resolved with Lua, and the pane says so.
    ///
    /// A config that a Lua interpreter resolves is rendered in the order of
    /// the load, which is the order of the daemon, so the warning is not
    /// shown for it.
    @MainActor
    func testTheOrderWarningIsOnlyForAConfigThatCannotBeResolved() throws {
        let store = SketchyBarStore(configRoot: fixture("lua-resolve"))

        let loadOrderRoot = fixture("lua-load-order")
        store.addConfig(name: "LoadOrder", path: loadOrderRoot.path, selectAfterAdd: false)
        let loadOrder = try XCTUnwrap(store.configs.first { $0.name == "LoadOrder" })

        XCTAssertFalse(store.barRenderWarnings(for: .config(loadOrder.id))
            .contains { $0.contains("file order") },
                       "a config that a Lua interpreter resolves is rendered in the order of the load")

        let shellRoot = fixture("lua-shell")
        store.addConfig(name: "Shell", path: shellRoot.path, selectAfterAdd: false)
        let shell = try XCTUnwrap(store.configs.first { $0.name == "Shell" })

        // The config of the shell has no Lua entrypoint, so the parser
        // reads it and the items follow the order of the files.
        XCTAssertTrue(store.barRenderWarnings(for: .config(shell.id))
            .contains { $0.contains("file order") },
                      "a config that cannot be resolved with Lua is rendered in file order")
    }

    // MARK: - The live values

    /// The render draws the resolved config, and not the plan of the
    /// parser.
    ///
    /// The fixture of the test declares a graph and a bracket. The parser
    /// of the app reads no type of item, so the plan of the parser holds
    /// the plain items only. The render holds the graph and the bracket,
    /// so it draws the resolved config.
    func testTheRenderDrawsTheResolvedConfig() async throws {
        let result = try await BarRendererService.shared.render(request(of: fixture("lua-item-types")))

        XCTAssertNotNil(result.itemRects["cpu"], "the graph of the config must be in the render")
        XCTAssertNotNil(result.itemRects["group"], "the bracket of the config must be in the render")
    }

    /// The value of a script is not overwritten by the resolved config.
    ///
    /// The script of the item of the fixture moves the item to the right of
    /// the bar. The resolved config puts the item on the left, so the item
    /// is on the right of the bar only when the value of the script wins.
    func testTheValueOfTheScriptIsNotOverwrittenByTheResolvedPlan() async throws {
        let root = fixture("lua-live-values")

        let result = try await BarRendererService.shared.render(request(of: root))
        let rect = try XCTUnwrap(result.itemRects["clock"], "the item must have a rectangle")
        let frame = try XCTUnwrap(result.barFrame, "the bar must have a frame")

        XCTAssertGreaterThan(rect.midX, frame.midX,
                             "the value of the script has to win over the value of the resolved config")
    }
}
