import Foundation
@testable import SketchyBarStudio
import XCTest

final class SbarLuaParserTests: XCTestCase {
    // MARK: - Helpers

    private let itemSnippet = """
    local network = sbar.add("item", "network.status", {
        position = "right",
        padding_left = 2,
        icon = {
            string = "wifi",
            font = { family = "SF Pro", size = 12 },
            color = 0xffff0000,
        },
        label = { drawing = false },
        background = { color = 0x88000000 },
    })
    """

    private func scan(_ contents: String) throws -> [LuaEditableValue] {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/network.lua")
        try write(contents, to: fileURL)
        return LuaConfigScanner().scan(fileURL: fileURL)
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioSbarLuaTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Key paths

    func testItemValuesUseQualifiedKeyPaths() throws {
        let values = try scan(itemSnippet)

        XCTAssertEqual(
            values.map(\.keyPath),
            [
                "position",
                "padding_left",
                "icon.string",
                "icon.font.family",
                "icon.font.size",
                "icon.color",
                "label.drawing",
                "background.color"
            ]
        )
    }

    func testTheAliasOfAnItemIsCaptured() throws {
        let items = SbarLuaItemParser.items(in: itemSnippet)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.alias, "network.status")
        XCTAssertEqual(items.first?.values.map(\.keyPath).first, "position")
    }

    func testTheItemTypeMustBeItem() throws {
        let items = SbarLuaItemParser.items(in: "sbar.add(\"alias\", \"a\", { position = \"left\" })")

        XCTAssertTrue(items.isEmpty)
    }

    func testAnItemWithoutANameIsStillRead() throws {
        let values = try scan("""
        sbar.add("item", {
            position = "left",
            icon = { font = { size = 12 } },
        })
        """)

        XCTAssertEqual(values.map(\.keyPath), ["position", "icon.font.size"])
    }

    // MARK: - The parser

    func testTheParserFindsTheTableConstructors() throws {
        let result = LuaTableParser.parse(source: "local a = { x = 1, y = { z = 2 } }")

        XCTAssertEqual(result.tables.count, 2)
        XCTAssertEqual(result.tables.first?.entries.map(\.path), [["x"], ["y", "z"]])
        XCTAssertEqual(result.tables.first?.entries.first?.kind, .number)
    }

    func testTheParserSkipsCommentsAndLongStrings() throws {
        let result = LuaTableParser.parse(source: "-- { x = 1 }\nlocal a = [[ { x = 2 } ]]\nlocal b = { x = 3 }")

        XCTAssertEqual(result.tables.count, 1)
        XCTAssertEqual(result.tables.first?.entries.map(\.path), [["x"]])
    }

    func testTheParserFindsTheCallOfAnItem() throws {
        let result = LuaTableParser.parse(source: "sbar.add(\"item\", \"a\", { position = \"left\" })")

        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls.first?.path, ["sbar", "add"])
    }

    // MARK: - Values that are not editable

    func testAnExpressionValueIsNotEditable() throws {
        let values = try scan("""
        sbar.add("item", "a", {
            icon = { color = colors.red },
        })
        """)

        XCTAssertTrue(values.isEmpty)
    }

    func testALongStringValueIsNotEditable() throws {
        let values = try scan("""
        sbar.add("item", "a", {
            click_script = [[
                echo hello
            ]],
            position = "left",
        })
        """)

        XCTAssertEqual(values.map(\.keyPath), ["position"])
    }

    func testACommentedOutItemHasNoValues() throws {
        let values = try scan("""
        -- sbar.add("item", "a", { position = "left" })
        --[[
        sbar.add("item", "b", { position = "right" })
        ]]
        """)

        XCTAssertTrue(values.isEmpty)
    }

    // MARK: - Values that are built by an expression

    func testAConcatenatedValueIsNotEditable() throws {
        let values = try scan("""
        sbar.add("item", "a", {
            position = "popup." .. network_bracket.name,
        })
        """)

        XCTAssertTrue(values.isEmpty)
    }

    func testEveryKindOfExpressionIsNotEditable() throws {
        let values = try scan("""
        sbar.add("item", "a", {
            position = "popup." .. network_bracket.name,
            color = colors.red,
            family = settings.default,
            string = icons.wifi.disconnected,
            label = "a" .. "b",
            x = 1 + 2,
            plain = "left",
        })
        """)

        XCTAssertEqual(values.map(\.keyPath), ["plain"])
        XCTAssertEqual(values.map(\.originalValue), ["left"])
    }

    func testTheLiteralAtTheEndOfAnExpressionIsNotEditable() throws {
        let values = try scan("""
        sbar.add("item", "a", {
            position = network_bracket.name .. "popup.",
        })
        """)

        XCTAssertTrue(values.isEmpty)
    }

    func testALiteralNextToAnExpressionIsStillEditable() throws {
        let root = try makeConfigRoot()
        let contents = """
        sbar.add("item", "a", {
            position = "popup." .. network_bracket.name,
            align = "center",
        })
        """
        let fileURL = root.appendingPathComponent("items/network.lua")
        try write(contents, to: fileURL)

        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        XCTAssertEqual(values.map(\.keyPath), ["align"])

        values[0].draftValue = "right"
        let updated = scanner.updatedContents(values: values, originalContents: contents)
        XCTAssertEqual(updated, contents.replacingOccurrences(of: "\"center\"", with: "\"right\""))
    }

    func testThePlainPathRejectsAPartOfAnExpression() throws {
        let values = try scan("""
        local x = "a" .. "b"
        local y = 1 + 2
        local z = name .. "c"
        local w = 1
        """)

        XCTAssertEqual(values.map(\.keyPath), ["w"])
        XCTAssertEqual(values.map(\.originalValue), ["1"])
    }

    // MARK: - Several items

    func testTwoItemsInOneFileKeepTheirAlias() throws {
        let values = try scan("""
        sbar.add("item", "first", { position = "left" })
        sbar.add("item", "second", { position = "right" })
        """)

        XCTAssertEqual(values.map(\.keyPath), ["position", "position"])
        XCTAssertEqual(values.map(\.valueStartOffset).count, 2)
        XCTAssertNotEqual(values[0].valueStartOffset, values[1].valueStartOffset)

        let items = SbarLuaItemParser.items(in: """
        sbar.add("item", "first", { position = "left" })
        sbar.add("item", "second", { position = "right" })
        """)
        XCTAssertEqual(items.map(\.alias), ["first", "second"])
    }

    // MARK: - Writing

    func testSavingAChangeRewritesOnlyTheEditedBytes() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/network.lua")
        try write(itemSnippet, to: fileURL)

        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        let sizeIndex = try XCTUnwrap(values.firstIndex { $0.keyPath == "icon.font.size" })
        values[sizeIndex].draftValue = "14"

        // Everything before and after the edited value stays the same.
        let edited = values[sizeIndex]
        let start = itemSnippet.index(itemSnippet.startIndex, offsetBy: edited.valueStartOffset)
        let end = itemSnippet.index(itemSnippet.startIndex, offsetBy: edited.valueEndOffset)
        XCTAssertEqual(String(itemSnippet[start..<end]), "12")
        let prefix = String(itemSnippet[..<start])
        let suffix = String(itemSnippet[end...])

        let updated = scanner.updatedContents(values: values, originalContents: itemSnippet)
        XCTAssertEqual(updated, prefix + "14" + suffix)
        XCTAssertEqual(updated.count, itemSnippet.count)

        try scanner.save(values: values, to: fileURL, rootURL: root)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            prefix + "14" + suffix
        )
    }

    func testTheFileIsUnchangedWithoutADraft() throws {
        let scanner = LuaConfigScanner()
        let values = try scan(itemSnippet)

        XCTAssertEqual(scanner.updatedContents(values: values, originalContents: itemSnippet), itemSnippet)
    }

    // MARK: - Structure

    func testItemValuesAndPlainTableValuesDoNotCollide() throws {
        let values = try scan("""
        local colors = {
            white = "#ffffff",
        }
        sbar.add("item", "a", {
            icon = { string = "wifi" },
        })
        """)

        XCTAssertEqual(values.map(\.keyPath), ["white", "icon.string"])
        XCTAssertEqual(Set(values.map(\.valueStartOffset)).count, values.count)
    }

    func testAFileWithoutAnItemKeepsThePlainKeys() throws {
        let values = try scan("""
        local colors = {
            white = "#ffffff",
            position = "left",
        }
        """)

        XCTAssertEqual(values.map(\.keyPath), ["white", "position"])
    }

    // MARK: - Malformed files

    func testAMalformedFileDoesNotCrash() throws {
        let values = try scan("""
        sbar.add("item", "a", { position = "left"
        icon = { string = "wifi"
        }}}}}} stray ]] --[[ unterminated
        """)

        XCTAssertFalse(values.isEmpty)
    }

    func testAnEmptyFileHasNoValues() throws {
        XCTAssertTrue(try scan("").isEmpty)
    }

    // MARK: - Rules

    func testTheValueRulesKnowTheQualifiedKeys() {
        XCTAssertEqual(SketchyBarValueRules.kind(for: "0xff0000", keyPath: "icon.color"), .color)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "0xff0000", keyPath: "label.color"), .color)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "0xff0000", keyPath: "background.color"), .color)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "0xff0000", keyPath: "background.border_color"), .color)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "0xff0000", keyPath: "label.highlight_color"), .color)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "12", keyPath: "icon.font.size"), .number)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "2", keyPath: "padding_left"), .number)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "12", keyPath: "width"), .number)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "false", keyPath: "label.drawing"), .boolean)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "false", keyPath: "background.drawing"), .boolean)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "\"wifi\"", keyPath: "icon.string"), .string)
        XCTAssertEqual(SketchyBarValueRules.kind(for: "\"wifi\"", keyPath: "label.string"), .string)
    }

    func testTheGroupTitleComesFromTheFirstKeySegment() {
        XCTAssertEqual(EditableValueGroup.title(for: value("icon.font.size", original: "12")), "Icon")
        XCTAssertEqual(EditableValueGroup.title(for: value("padding_left", original: "2")), "Item")
        XCTAssertEqual(EditableValueGroup.title(for: value("background.border_color", original: "0xff0000")), "Background")
        XCTAssertEqual(EditableValueGroup.title(for: value("popup.height", original: "30")), "Popup")
        XCTAssertEqual(EditableValueGroup.title(for: value("click_script", original: "x")), "Scripts")
    }

    private func value(_ keyPath: String, original: String) -> LuaEditableValue {
        LuaEditableValue(
            id: keyPath,
            fileURL: URL(fileURLWithPath: "/tmp/root/f.lua"),
            keyPath: keyPath,
            lineNumber: 1,
            kind: .string,
            originalValue: original,
            draftValue: original,
            suggestedValues: [],
            valueStartOffset: 0,
            valueEndOffset: 0,
            sourceSnapshot: ""
        )
    }
}
