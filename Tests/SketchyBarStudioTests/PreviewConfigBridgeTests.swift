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

    func testBothItemsAreInTheTreeOfTheCore() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "battery", { position = "left" })
        """)

        let clock = try serialization(of: plan, alias: "clock")
        let battery = try serialization(of: plan, alias: "battery")

        XCTAssertTrue(clock.contains("\"clock\""))
        XCTAssertTrue(battery.contains("\"battery\""))
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

    func testTheDefaultsOfOneFileReachTheItemsOfAnotherFile() throws {
        // The defaults of a config live in one file and its items in
        // another, so the bridge has to collect the defaults of every file.
        let defaults = PreviewConfigBridge.plan(forLua: """
        sbar.default({ label = { string = "default" } })
        """)
        let items = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        """)

        let combined = defaults.combined(with: items)

        XCTAssertEqual(combined.defaults.map(\.key), ["label.string"])
        XCTAssertEqual(combined.items.map(\.alias), ["clock"])

        let clock = try tree(of: combined, alias: "clock")
        XCTAssertEqual(value(clock, "label", "value"), "default")
    }

    func testEveryDefaultOfAFileIsRead() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.default({ label = { string = "first" } })
        sbar.default({ icon = { string = "second" } })
        """)

        XCTAssertEqual(plan.defaults.map(\.key), ["label.string", "icon.string"])
    }

    // MARK: - The bar

    func testTheBarPropertiesReachTheBar() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.bar({ position = "top", height = 30 })
        """)

        XCTAssertEqual(plan.bar.map(\.key), ["position", "height"])
        XCTAssertEqual(plan.bar.map(\.value), ["top", "30"])
    }

    func testEveryBarOfAFileIsRead() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.bar({ height = 30 })
        sbar.bar({ position = "top" })
        """)

        XCTAssertEqual(plan.bar.map(\.key), ["height", "position"])
    }

    func testTheBarDeclarationSkipsACallWithoutATable() {
        let bar = SbarLuaItemParser.bar(in: """
        sbar.bar()
        sbar.bar({ height = 30 })
        """)

        XCTAssertEqual(bar?.values.map(\.keyPath), ["bar.height"])
    }

    func testTheShellBarPropertiesReachTheBar() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --bar height=30 position=top
        sketchybar --add item clock right
        """)

        XCTAssertEqual(plan.bar.map(\.key), ["height", "position"])
        XCTAssertEqual(plan.bar.map(\.value), ["30", "top"])
        XCTAssertEqual(plan.items.first?.addPosition, "right")
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

    func testAValueThatHoldsQuotesKeepsItsQuotes() throws {
        // The parser already removed the quotes of the string, so the
        // quotes that are part of the value stay.
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { label = { string = "\\"10:00\\"" } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["\"10:00\""])

        // The serialized item is not always valid JSON: the vendored code
        // writes the text of a label without escaping it
        // (`src/text.c:1027`), so the tree is read as text here.
        let text = try serialization(of: plan, alias: "clock")
        XCTAssertTrue(text.contains("10:00"))
    }

    func testTheEscapesOfLuaAreResolved() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { label = { string = "\\x41\\69\\u{42}" } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["AEB"])
    }

    func testASingleQuotedStringResolvesItsEscapesLikeLuaDoes() {
        // Lua resolves the same escapes in a single quoted string and in a
        // double quoted string (`lua-5.5.0/src/llex.c:404-464`).
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { label = { string = 'a\\nb' } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["a\nb"])
    }

    func testABackslashThatStartsNoEscapeStaysAsItIs() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { label = { string = "a\\qb" } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["a\\qb"])
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
        sketchybar --add item battery left
        sketchybar --set battery label="80%"
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock", "battery"])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.key) },
                       [["label"], ["label"]])
        XCTAssertEqual(plan.items.map { $0.properties.map(\.value) },
                       [["10:00"], ["80%"]])
        XCTAssertEqual(plan.items.map(\.addPosition), ["right", "left"])
    }

    func testTheShellConfigJoinsTheContinuedLines() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --set clock \\
            label="10:00" \\
            icon="sf.clock"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["label", "icon"])
        XCTAssertEqual(plan.items.first?.properties.map(\.value), ["10:00", "sf.clock"])
    }

    func testACommandEndsAtTheNewline() {
        // The words of the next line are not the properties of the
        // command before it.
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --set clock label="10:00"
        echo "a=b"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["label"])
    }

    func testTheShellConfigLeavesTheValuesThatTheShellBuildsOut() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --set clock label="$(date '+%H:%M')" icon="sf.clock"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["icon"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("The value of 'label' is built by the shell") })
    }

    func testAValueWithAVariableIsLeftOutAndReported() {
        // The shell expands `$HOME`, so the value is not a literal.
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --set clock label="$HOME/x" icon="sf.clock"
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), ["icon"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("The value of 'label' is built by the shell") })
    }

    func testTheRangeOfAQuotedShellValueCoversItsQuotes() throws {
        let source = """
        sketchybar --add item clock right
        sketchybar --set clock label="10:00"
        """
        let parsed = ShellConfigCommandParser.parse(in: source)

        let value = try XCTUnwrap(parsed.items.first?.values.first)
        let start = source.index(source.startIndex, offsetBy: value.valueStartOffset)
        let end = source.index(source.startIndex, offsetBy: value.valueEndOffset)

        XCTAssertEqual(String(source[start..<end]), "\"10:00\"")
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
        XCTAssertTrue(plan.warnings[0].contains("The alias 'clock' is added twice."))
        XCTAssertTrue(plan.warnings[0].contains("the last value of a property wins"))
    }

    func testADuplicateAliasIsAddedOnce() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { position = "right" })
        sbar.add("item", "clock", { position = "left" })
        """)

        // The daemon refuses the second add (src/message.c:190-193), but
        // SbarLua sets the properties of every declaration, so they reach
        // the item and the last value of a property wins.
        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "geometry", "position"), "left")
    }

    func testTheSecondAddOfTheShellStyleIsReported() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --add item clock left
        """)

        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.addPosition, "right")
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("The alias 'clock' is added twice."))
        XCTAssertTrue(plan.warnings[0].contains("The position of the second add is ignored."))
    }

    func testThePositionOfTheSecondAddOfTheShellStyleIsIgnored() throws {
        // The position of the shell style travels in the add command, and
        // the daemon refuses the whole second add.
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --add item clock left
        sketchybar --set clock label="10:00"
        """)

        let tree = try tree(of: plan, alias: "clock")
        XCTAssertEqual(value(tree, "geometry", "position"), "right")
        XCTAssertEqual(value(tree, "label", "value"), "10:00")
    }

    func testAValueThatIsBuiltByAnExpressionIsReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "clock", { icon = { color = colors.white } })
        """)

        XCTAssertEqual(plan.items.first?.properties.map(\.key), [])
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("The value of 'icon.color' is built by an expression"))
        XCTAssertTrue(plan.warnings[0].contains("the value SketchyBar has by default"))
    }

    func testAnAliasThatIsBuiltByAnExpressionIsReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "menu." .. i, { position = "left" })
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("The alias of an item is built by an expression"))
    }

    func testAnItemWithoutANameIsReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", { position = "right" })
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("The item has no name."))
        XCTAssertTrue(plan.warnings[0].contains("item_0, item_1"))
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

    func testTheComponentTypesOfTheLuaStyleAreReported() {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("graph", "cpu", 42, { graph = { values = { 1, 2 } } })
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.warnings.count, 1)
        XCTAssertTrue(plan.warnings[0].contains("The 'graph' item 'cpu' shows no values yet"))
        XCTAssertTrue(plan.warnings[0].contains("The parser of the app cannot read the type of this item"))
    }

    func testTheShellConfigAddsSeveralItems() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock right
        sketchybar --add item battery left
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock", "battery"])
        XCTAssertEqual(plan.items.map(\.addPosition), ["right", "left"])
    }

    func testASetOfAnItemThatWasNeverAddedIsReported() {
        // The daemon sets nothing when the item does not exist
        // (src/message.c:635).
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --set clock label="10:00"
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("The item 'clock' is set but never added") })
    }

    func testAnAddWithoutAPositionIsReported() {
        // The daemon creates the item and removes it again
        // (src/message.c:202-208).
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item clock
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("The item 'clock' is added without a position") })
    }

    func testAFileWithoutASketchyBarCommandIsReported() {
        let plan = PreviewConfigBridge.plan(forShell: """
        sb --add item clock right
        """)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("The file holds no SketchyBar command") })
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

    // MARK: - Stage 8: known limits warnings

    /// The front-app alias item is dropped by the parser and warns.
    func testFrontAppAliasIsDroppedByParser() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("alias", "front_app", { position = "left" })
        """)

        // The parser path drops the alias item and warns.
        XCTAssertEqual(plan.items.count, 0)
        XCTAssertTrue(plan.warnings.contains { $0.contains("alias") && $0.contains("front_app") },
                      "warnings must mention alias front_app: \(plan.warnings)")
    }

    /// The media.artwork icon value is accepted but the preview cannot show it.
    func testMediaArtworkIconIsAccepted() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "music", {
            position = "right",
            icon = { string = "media.artwork" }
        })
        """)

        // The item is added with the icon value.
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.alias, "music")
        // No parser warning for media.artwork - it's a valid icon value.
    }

    /// A popup item is accepted by the parser.
    func testPopupItemIsAcceptedByParser() throws {
        let plan = PreviewConfigBridge.plan(forLua: """
        sbar.add("item", "parent", { position = "left" })
        sbar.add("item", "popup_item", { position = "popup", argument = "parent" })
        """)

        // The parser reads both items.
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertTrue(plan.items.contains { $0.alias == "popup_item" })
        // No parser warning for popup position - it's a valid position.
    }

    /// The shell style alias item is dropped by the parser and warns.
    func testShellAliasItemIsDroppedByParser() throws {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add alias front_app left
        sketchybar --add item clock right
        """)

        XCTAssertEqual(plan.items.map(\.alias), ["clock"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("alias") && $0.contains("front_app") },
                      "warnings must mention alias front_app: \(plan.warnings)")
    }

    /// The shell style popup item is accepted by the parser.
    func testShellPopupItemIsAcceptedByParser() throws {
        let plan = PreviewConfigBridge.plan(forShell: """
        sketchybar --add item parent left
        sketchybar --add item popup_item popup parent
        """)

        XCTAssertEqual(plan.items.count, 2)
        XCTAssertTrue(plan.items.contains { $0.alias == "popup_item" })
        // No parser warning for popup position - it's a valid position.
    }
}
