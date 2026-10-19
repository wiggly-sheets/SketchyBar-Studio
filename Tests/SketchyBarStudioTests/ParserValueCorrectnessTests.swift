import Foundation
@testable import SketchyBarStudio
import XCTest

final class ParserValueCorrectnessTests: XCTestCase {
    // MARK: - Colors

    func testLuaHexColorScansAsColorAndSavesExactHex() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/colors.lua")
        try write("    color = 0xff000000,\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.originalValue, "0xff000000")
        XCTAssertEqual(values.first?.kind, .color)

        values[0].draftValue = "0xff111111"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "    color = 0xff111111,\n")
    }

    func testColorKeyScansHexValueAsColorButQuotedLabelStaysAString() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/colors.lua")
        try write("color = #ff8800\nlabel = \"#ff0000\"\n", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["color", "label"])
        XCTAssertEqual(values.map(\.kind), [.color, .string])
        XCTAssertEqual(values.map(\.originalValue), ["#ff8800", "#ff0000"])
    }

    func testQuotedColorKeepsItsQuotesWhenSaved() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/colors.lua")
        try write("color = \"#ff8800\"\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.kind, .color)

        values[0].draftValue = "0xffff0000"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "color = \"0xffff0000\"\n")
    }

    func testColorParsesAsArgb() throws {
        let color = try XCTUnwrap(SketchyBarColor.parse("0xff0000"))

        XCTAssertEqual(color.alpha, 1.0)
        XCTAssertEqual(color.red, 1.0)
        XCTAssertEqual(color.green, 0.0)
        XCTAssertEqual(color.blue, 0.0)
        XCTAssertEqual(color.sketchyBarHex, "0xffff0000")
    }

    func testEightDigitColorKeepsItsAlphaByte() throws {
        let color = try XCTUnwrap(SketchyBarColor.parse("0x80ff0000"))

        XCTAssertEqual(color.alpha, 128.0 / 255.0)
        XCTAssertEqual(color.red, 1.0)
        XCTAssertEqual(color.green, 0.0)
    }

    func testInvalidColorDraftKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/colors.lua")
        try write("color = 0xff000000\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "not-a-color"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "color = 0xff000000\n")
    }

    // MARK: - Updates

    func testUpdatesScansAsEnumAndSavesQuoted() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/updates.lua")
        try write("updates = true\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.originalValue, "on")
        XCTAssertEqual(values.first?.kind, .string)
        XCTAssertEqual(values.first?.suggestedValues, ["on", "off", "when_shown"])

        values[0].draftValue = "off"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "updates = \"off\"\n")
    }

    func testUpdatesKeepsWhenShownValue() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/updates.lua")
        try write("updates = when_shown\n", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.originalValue, "when_shown")
        XCTAssertEqual(values.first?.kind, .string)
    }

    // MARK: - Shell strings

    func testShellStringDraftIsQuotedAndEscaped() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=old\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.kind, .string)

        values[0].draftValue = "x;rm$HOME/.ssh"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=\"x;rm\\$HOME/.ssh\"\n")
    }

    func testShellStringDraftEscapesBackticksAndQuotes() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=plain\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "a`b`\"c"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "LABEL=\"a\\`b\\`\\\"c\"\n")
    }

    func testShellEmptyValueIsReported() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/icon.sh")
        try write("icon=\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.keyPath, "icon")
        XCTAssertEqual(values.first?.originalValue, "")
        XCTAssertEqual(values.first?.kind, .string)
    }

    func testShellInvalidNumberDraftKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/width.sh")
        try write("WIDTH=10\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "10px"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "WIDTH=10\n")
    }

    func testShellInvalidBooleanDraftKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/drawing.sh")
        try write("DRAWING=true\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "maybe"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "DRAWING=true\n")
    }

    // MARK: - Shell file structure

    func testShellArrayAssignmentsAreNotEditable() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("sketchybarrc")
        try write("default=(\nSPACE_ICONS=(\"1\" \"2\")\nLABEL=\"ok\"\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["LABEL"])
    }

    func testShellTrailingCommentIsNotScanned() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write("LABEL=\"x\"  # NOTE=1\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["LABEL"])
        XCTAssertEqual(values.first?.originalValue, "x")
    }

    func testShellHeredocBodyIsNotScanned() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/body.sh")
        try write("cat <<EOF\nLABEL=\"body\"\nEOF\nICON=\"real\"\n", to: fileURL)

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["ICON"])
    }

    // MARK: - Lua file structure

    func testLuaCommentValuesAreNotScanned() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/legacy.lua")
        try write(
            "-- legacy: sbar.add(\"item\",\"old\",{ position = \"left\" })\n" +
                "local note = [[ { position = \"left\" } ]]\n",
            to: fileURL
        )

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertTrue(values.isEmpty)
    }

    func testLuaCommentDoesNotHideRealValues() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/mixed.lua")
        try write("position = \"left\" -- old position = \"right\"\n", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["position"])
        XCTAssertEqual(values.first?.originalValue, "left")
    }

    // MARK: - Booleans

    func testBooleanKindIsDetectedWithoutAKnownKey() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/booleans.lua")
        try write("clip = true\nfoo = true\nbar = \"false\"\n", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["clip", "foo", "bar"])
        XCTAssertEqual(values.map(\.kind), [.boolean, .boolean, .boolean])
    }

    func testBooleanKeySetMatchesSketchyBar() {
        for key in ["clip", "lazy", "cache_scripts", "show_in_fullscreen", "drawing", "sticky"] {
            XCTAssertTrue(SketchyBarBoolean.isBooleanKey(key), "\(key) should be a boolean key")
        }

        XCTAssertFalse(SketchyBarBoolean.isBooleanKey("highlight"))
        XCTAssertFalse(SketchyBarBoolean.isBooleanKey("highlight_color"))
    }

    // MARK: - Invalid drafts

    func testLuaNumbersAreNotTruncated() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/numbers.lua")
        try write("width = 1.5e3\nheight = 12\nratio = -2.5\n", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.originalValue), ["1.5e3", "12", "-2.5"])
        XCTAssertEqual(values.map(\.kind), [.number, .number, .number])
    }

    func testInvalidNumberDraftKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/width.lua")
        try write("width = 12\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "12px"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "width = 12\n")
    }

    func testStringDraftWithALineBreakKeepsTheOriginalFile() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.lua")
        try write("label = \"a\"\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)

        values[0].draftValue = "a\nb"
        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "label = \"a\"\n")
    }

    // MARK: - Line endings

    func testScannersKeepCarriageReturnLineEndings() throws {
        let root = try makeConfigRoot()
        let luaURL = root.appendingPathComponent("items/crlf.lua")
        try write("width = 12\r\nlabel = \"a\"\r\n", to: luaURL)
        let luaScanner = LuaConfigScanner()
        var luaValues = luaScanner.scan(fileURL: luaURL)

        XCTAssertEqual(luaValues.map(\.keyPath), ["width", "label"])

        luaValues[0].draftValue = "14"
        try luaScanner.save(values: luaValues, to: luaURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: luaURL, encoding: .utf8), "width = 14\r\nlabel = \"a\"\r\n")
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioValueTests")
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
}
