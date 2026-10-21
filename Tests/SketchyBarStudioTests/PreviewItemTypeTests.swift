import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the item types of the preview.
///
/// The daemon has an item for every type but the event, and the preview
/// has to show what it can show of each of them and to say what it
/// cannot. The tests read the tree of the vendored core, so they see
/// what the core really holds.
final class PreviewItemTypeTests: XCTestCase {
    // MARK: - The fixtures

    /// The root of a fixture of the tests.
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The plan of a fixture, resolved with Lua.
    private func plan(of name: String) -> BarRenderPlan {
        PreviewConfigBridge.plan(forLuaConfigRoot: fixture(name))
    }

    /// The item of an alias in a plan.
    private func item(_ plan: BarRenderPlan, _ alias: String) -> BarRenderItemModel? {
        plan.items.first { $0.alias == alias }
    }

    // MARK: - The helpers

    /// The tree of an item of a plan, read back from the vendored core.
    ///
    /// It is nil when the core has no item with that alias, the way the
    /// daemon creates no item for an event.
    private func serialization(of plan: BarRenderPlan, alias: String) throws -> String? {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        PreviewConfigBridge.apply(plan, to: handle)

        return BarPreviewTestAccessors.itemSerialization(handle, alias: alias)
    }

    /// The number of samples of the graph of a serialized item.
    ///
    /// The graph holds one sample per point of its width
    /// (`src/graph.c:16-20`), and the serialization writes every sample
    /// (`src/graph.c:119-124`).
    private func samples(of text: String) -> Int? {
        guard let start = text.range(of: "\"data\": [") else { return nil }
        guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].split(separator: ",").count
    }

    // MARK: - The types of the items

    /// A graph reaches the tree with its type and with the width the
    /// daemon uses.
    ///
    /// The daemon reads the width of a graph after the position of the add
    /// command and hands it to `graph_setup` (`src/message.c:218-221`).
    func testAGraphReachesTheTreeWithItsTypeAndItsWidth() throws {
        let plan = self.plan(of: "lua-item-types")

        let graph = try XCTUnwrap(item(plan, "cpu"))
        XCTAssertEqual(graph.type, "graph")
        XCTAssertEqual(graph.argument, "42")

        let text = try XCTUnwrap(serialization(of: plan, alias: "cpu"))
        XCTAssertTrue(text.contains("\"type\": \"graph\""))
        XCTAssertEqual(samples(of: text), 42)
    }

    /// A bracket reaches the tree with its members.
    ///
    /// The daemon reads the members of a bracket after the position of the
    /// add command (`src/message.c:262-306`).
    func testABracketReachesTheTreeWithItsMembers() throws {
        let plan = self.plan(of: "lua-item-types")

        let bracket = try XCTUnwrap(item(plan, "group"))
        XCTAssertEqual(bracket.type, "bracket")
        XCTAssertEqual(bracket.argument, "clock cpu")

        let text = try XCTUnwrap(serialization(of: plan, alias: "group"))
        XCTAssertTrue(text.contains("\"type\": \"bracket\""))
    }

    /// A space and an alias reach the tree, and the preview shows them as
    /// a placeholder.
    ///
    /// Both need the window server, so the item keeps a box of 16 points
    /// (`preview/preview_internal.h:15`).
    func testASpaceAndAnAliasReachTheTreeAndArePlaceholders() throws {
        let plan = self.plan(of: "lua-item-types")

        XCTAssertEqual(item(plan, "spacer")?.type, "space")
        XCTAssertEqual(item(plan, "menu")?.type, "alias")

        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        PreviewConfigBridge.apply(plan, to: handle)

        XCTAssertEqual(BarPreviewTestAccessors.itemWidth(handle, alias: "spacer"), 16)
        XCTAssertEqual(BarPreviewTestAccessors.itemWidth(handle, alias: "menu"), 16)

        XCTAssertTrue(plan.warnings.contains {
            $0.contains("'space' item 'spacer'") && $0.contains("placeholder")
        }, "the space must be reported as a placeholder")
        XCTAssertTrue(plan.warnings.contains {
            $0.contains("'alias' item 'menu'") && $0.contains("placeholder")
        }, "the alias must be reported as a placeholder")
    }

    /// An event reaches the tree of the plan, and the preview does not
    /// show it.
    ///
    /// The daemon registers a custom event and creates no item for it
    /// (`src/message.c:175-185`), so the preview draws nothing for it
    /// either.
    func testAnEventReachesTheTreeAndIsNotShown() throws {
        let plan = self.plan(of: "lua-item-types")

        let event = try XCTUnwrap(item(plan, "lock"))
        XCTAssertEqual(event.type, "event")
        XCTAssertEqual(event.argument, "com.apple.screenIsLocked")

        let text = try serialization(of: plan, alias: "lock")
        XCTAssertNil(text, "the daemon creates no item for an event")

        XCTAssertTrue(plan.warnings.contains {
            $0.contains("'event' item 'lock'") && $0.contains("not shown on the bar")
        }, "the event must be reported as not shown")
    }

    /// A config with a type the daemon does not know produces a warning
    /// and no item.
    func testAConfigWithAnUnknownTypeProducesAWarningAndNoItem() {
        let plan = self.plan(of: "lua-unknown-type")

        XCTAssertEqual(plan.items.map(\.alias), ["kept"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("'widget'") },
                      "the unknown type must be reported")
    }

    /// The bar of a config with an item of every type is laid out and
    /// painted.
    ///
    /// A graph takes the width of the config, so the item has a width of
    /// its own (`src/graph.c:35-38`).
    func testTheBarOfEveryTypeIsRendered() throws {
        let plan = self.plan(of: "lua-item-types")

        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        PreviewConfigBridge.apply(plan, to: handle)

        let image = try XCTUnwrap(SketchyBarPreviewC.render(handle))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let rect = try XCTUnwrap(SketchyBarPreviewC.itemRect(handle, alias: "cpu"))
        XCTAssertGreaterThan(rect.width, 0, "the graph must have a width of its own")
    }

    // MARK: - The real config of the user

    /// The real config of the user, read only.
    ///
    /// The test is skipped when the config is not on this machine, so the
    /// suite does not depend on it. The counts of the plan and the counts
    /// of the resolver have to be the same, because the plan keeps every
    /// item the resolver read.
    func testTheRealConfigOfTheUserIsCountedByType() throws {
        let root = URL(fileURLWithPath: "/Users/Zeb/dotfiles/sketchybar")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("the real config of the user is not on this machine")
        }

        let finished = expectation(description: "the config of the user is resolved")
        var plan = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])
        var resolved: [String: Int] = [:]
        DispatchQueue.global().async {
            plan = PreviewConfigBridge.plan(forLuaConfigRoot: root)
            var counts: [String: Int] = [:]
            if let entrypoint = LuaConfigRunner.entrypoint(in: root),
               let run = try? LuaConfigRunner.resolve(configRoot: root, entrypoint: entrypoint) {
                for item in run.items {
                    counts[item.type, default: 0] += 1
                }
            }
            resolved = counts
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        var byType: [String: Int] = [:]
        for item in plan.items {
            byType[item.type, default: 0] += 1
        }

        print("item-types: the items of the config by type: \(byType.sorted { $0.key < $1.key })")

        XCTAssertFalse(byType.isEmpty, "the config of the user must have items")
        XCTAssertEqual(byType, resolved, "the plan must keep every item of the resolver")
    }
}
