import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the config bridge.
///
/// The bridge is a pure mapping plus the calls into the in-process C API of
/// the vendored core, so the tests need no SketchyBar and no daemon. The
/// item tree is read back from the vendored core, so the tests see what
/// the core really holds.
final class PreviewConfigBridgeTests: XCTestCase {
    // MARK: - Fixtures

    /// An item with three properties.
    private let threeProperties = """
    sbar.add("item", "clock", {
        label = { string = "10:00" },
        icon = { string = "sf.clock" },
        background = { color = 0xff112233 },
    })
    """

    /// The same item in the shell style.
    private let itemShell = """
    sketchybar --add item clock right
    sketchybar --set clock label="10:00" icon="sf.clock" background.color=0xff112233
    """

    /// The same item in the Lua style.
    private let itemLua = """
    sbar.add("item", "clock", {
        position = "right",
        label = { string = "10:00" },
        icon = { string = "sf.clock" },
        background = { color = 0xff112233 },
    })
    """

    // MARK: - Helpers

    /// The tree of an item, read back from the vendored core.
    private func tree(of plan: BarRenderPlan, alias: String) throws -> [String: Any] {
        let text = try serialization(of: plan, alias: alias)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The serialized tree of an item, the text `sketchybar --query <item>`
    /// answers with.
    private func serialization(of plan: BarRenderPlan, alias: String) throws -> String {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        PreviewConfigBridge.apply(plan, to: handle)

        return try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: alias))
    }

    /// One value of the tree, such as `label` and `value`.
    private func value(_ item: [String: Any], _ path: String...) -> String? {
        var current: Any? = item
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current as? String
    }

    // MARK: - The items

    func testAnItemBecomesAnItemWithItsThreeProperties() {
        let plan = PreviewConfigBridge.plan(forLua: threeProperties)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.alias, "clock")
        XCTAssertEqual(plan.items.first?.properties.map(\.key),
                       ["label.string", "icon.string", "background.color"])
    }

    func testThePropertiesOfTheItemReachTheVendoredTree() throws {
        let tree = try tree(of: PreviewConfigBridge.plan(forLua: threeProperties), alias: "clock")

        XCTAssertEqual(value(tree, "label", "value"), "10:00")
        XCTAssertEqual(value(tree, "icon", "value"), "sf.clock")
        XCTAssertEqual(value(tree, "geometry", "background", "color"), "0xff112233")
    }

    func testTwoItemsInOneFileBecomeTwoItems() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "battery", { position = "left" })
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock", "battery"])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.key) }, [["position"], ["position"]])
    }

    func testTheFontSizeOfTheIconAndTheLabelStayApart() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", {
            icon = { font = { size = 11 } },
            label = { font = { size = 22 } },
        })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["icon.font.size", "label.font.size"])
        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["11", "22"])

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "icon", "font"), "Hack Nerd Font:Bold:11.00")
        XCTAssertEqual(value(tree, "label", "font"), "Hack Nerd Font:Bold:22.00")
    }

    // MARK: - The defaults

    func testTheDefaultsReachEveryItemThatDoesNotOverrideThem() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.default({ label = { string = "default" } })
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "battery", { position = "left" })
        """)

        XCTAssertEqual(plan.defaults.map(\.key), ["label.string"])
        XCTAssertEqual(plan.defaults.map(\.value), ["default"])

        let clock = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(clock, "label", "value"), "default")
        let battery = try tree(of: plan, alias: "battery")
        XCTAssertEqual(value(battery, "label", "value"), "default")
    }

    func testTheShellDefaultReachesEveryItemThatDoesNotOverrideThem() throws {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --default label.string=default
        sketchybar --add item clock right
        """)

        XCTAssertEqual(plan.defaults.map(\.key), ["label.string"])
        XCTAssertEqual(plan.defaults.map(\.value), ["default"])

        let clock = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(clock, "label", "value"), "default")
    }

    func testTheDefaultOfTheShellConfigIsTheDefaultOfTheLuaConfig() {
        let lua = PreviewConfigBridge.plan(forLua: """
        sbar.default({ icon = { font = { size = 11 } } })
        """)
        let shell = PreviewConfigBridge.plan(forShell: """
        sketchybar --default icon.font.size=11
        """)

        XCTAssertEqual(lua.defaults, shell.defaults)
    }

    func testTheDefaultsAreAppliedBeforeTheItemsAreAdded() throws {
        // The default item is a snapshot that every item inherits when it
        // is created, so a default that comes after an item never reaches
        // that item.
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.default({ width = 120 })
        sbar.add("item", "clock", { position = "right" })
        """)

        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        PreviewConfigBridge.apply(plan, to: handle)

        XCTAssertEqual(BarPreviewTestAccessors.itemWidth(handle, alias: "clock"), 120)
    }

    func testTheDefaultOfTheShellConfigIsNotABarProperty() throws {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --default label.string=default
        sketchybar --add item clock right
        """)

        XCTAssertTrue(plan.bar.isEmpty)

        let clock = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(clock, "label", "value"), "default")
    }

    // MARK: - The bar

    func testTheBarPropertiesReachTheBar() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.bar({ position = "top", height = 30 })
        """)

        XCTAssertEqual(plan.bar.map(\.key), ["position", "height"])
        XCTAssertEqual(plan.bar.map(\.value), ["top", "30"])
    }

    func testTheShellBarPropertiesReachTheBar() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --bar height=30 position=top
        sketchybar --add item clock right
        """)

        XCTAssertEqual(plan.bar.map(\.key), ["height", "position"])
        XCTAssertEqual(plan.bar.map(\.value), ["30", "top"])
        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["position"])
        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["right"])
    }

    // MARK: - The values

    func testAQuotedStringIsSentWithoutItsQuotes() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { label = { string = "10:00" } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["10:00"])

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "label", "value"), "10:00")
    }

    func testABooleanIsSentAsTrueOrFalse() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { drawing = false, scroll_texts = true })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["false", "true"])

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "geometry", "drawing"), "off")
        XCTAssertEqual(value(tree, "geometry", "scroll_texts"), "on")
    }

    func testTheUpdatesValueKeepsItsWhenShownSpelling() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { updates = "when_shown" })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["when_shown"])

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "scripting", "updates"), "when_shown")
    }

    func testAColourKeepsItsHexValue() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { background = { color = 0xff112233 } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["0xff112233"])

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "geometry", "background", "color"), "0xff112233")
    }

    // MARK: - The shell style

    func testAShellConfigProducesTheSameItemTreeAsTheLuaConfig() throws {
        let lua = try serialization(of: PreviewConfigBridge.plan(forLua: itemLua), alias: "clock")
        let shell = try serialization(of: PreviewConfigBridge.plan(forShell: itemShell), alias: "clock")

        XCTAssertEqual(lua, shell)
    }

    func testTheShellConfigReadsTheAliasOfEveryValue() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --set clock label="10:00"
        sketchybar --set battery label="80%"
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock", "battery"])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.key) },
                       [["position", "label"], ["label"]])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.value) },
                       [["right", "10:00"], ["80%"]])
    }

    func testTheShellConfigJoinsTheContinuedLines() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --set clock \\
            label="10:00" \\
            icon="sf.clock"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["label", "icon"])
        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["10:00", "sf.clock"])
    }

    func testTheShellConfigLeavesTheValuesThatTheShellBuildsOut() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --set clock label="$(date '+%H:%M')" icon="sf.clock"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["icon"])
    }

    // MARK: - The problems of a config

    func testADuplicateAliasIsMergedIntoOneItemAndReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "clock", { position = "left", label = { string = "second" } })
        """)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.alias, "clock")
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("clock"))
    }

    func testADuplicateAliasIsAddedOnce() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "clock", { position = "left" })
        """)

        // The declarations of an alias are merged into one item and the
        // properties are sent in the order of the config, so the last value
        // of a property wins. The daemon refuses the second add
        // (src/message.c:191), but SbarLua sets the properties of every
        // declaration, so they reach the item.
        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "geometry", "position"), "left")
    }

    func testAnUnknownPropertyIsReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { not_a_property = "x" })
        """)

        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        let warnings = PreviewConfigBridge.apply(plan, to: handle)

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("not_a_property"))
        XCTAssertTrue(warnings[0].contains("Invalid property"))
    }

    func testAnUnknownBarPropertyIsReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.bar({ not_a_property = "x" })
        """)

        let handle = SketchyBarPreviewC.create()
        XCTAssertNotNil(handle)
        defer { SketchyBarPreviewC.destroy(handle) }

        let warnings = PreviewConfigBridge.apply(plan, to: handle)

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("not_a_property"))
    }

    func testAnItemWithoutANameIsReported() {        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", { position = "right" })
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.warnings.count, 1)
    }

    func testTheComponentTypesThePreviewCannotShowAreReported() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add space spacer left
        sketchybar --add item clock right
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock"])
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("space"))
    }

    func testTheShellConfigAddsSeveralItems() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --add item battery left
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock", "battery"])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.value) }, [["right"], ["left"]])
    }

    func testTheSecondAddOfAnAliasIsReported() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --add item clock left
        """)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["right"])
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("clock"))
    }

    // MARK: - The disk

    func testTheBridgeNeverWritesToDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioPreviewBridgeTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("sketchybarrc")
        let contents = """
        #!/bin/sh
        sketchybar --bar height=30
        sketchybar --default icon.padding_left=2
        sketchybar --add item clock right
        sketchybar --set clock label="10:00"
        """
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let bytesBefore = try Data(contentsOf: fileURL)
        let dateBefore = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let plan = PreviewConfigBridge.plan(forShell: contents)
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        PreviewConfigBridge.apply(plan, to: handle)

        let bytesAfter = try Data(contentsOf: fileURL)
        let dateAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        XCTAssertEqual(bytesBefore, bytesAfter)
        XCTAssertEqual(dateBefore, dateAfter)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["sketchybarrc"])
    }
}
