import Foundation
@testable import SketchyBarStudio
import XCTest

final class ViewLogicTests: XCTestCase {
    // MARK: - Helpers

    private func value(
        _ keyPath: String,
        original: String,
        draft: String? = nil,
        kind: LuaValueKind? = nil
    ) -> LuaEditableValue {
        let inferredKind = kind ?? (Double(original) != nil ? .number : .string)
        return LuaEditableValue(
            id: "\(keyPath)-\(original)-\(draft ?? original)",
            fileURL: URL(fileURLWithPath: "/tmp/root/f.lua"),
            keyPath: keyPath,
            lineNumber: 1,
            kind: inferredKind,
            originalValue: original,
            draftValue: draft ?? original,
            suggestedValues: [],
            valueStartOffset: 0,
            valueEndOffset: 0,
            sourceSnapshot: ""
        )
    }

    private func file(
        _ relativePath: String,
        values: [LuaEditableValue],
        kind: ConfigFileKind = .lua
    ) -> ConfigFile {
        ConfigFile(
            url: URL(fileURLWithPath: "/tmp/root/\(relativePath)"),
            rootURL: URL(fileURLWithPath: "/tmp/root"),
            kind: kind,
            values: values,
            activationReference: nil
        )
    }

    private func groupFor(_ matches: (SidebarFileGroup) -> Bool, from files: [ConfigFile]) throws -> SidebarFileGroup {
        try XCTUnwrap(SidebarGrouper.group(files: files).first(where: matches))
    }

    // MARK: - SidebarGrouper

    func testCategoryFromTopLevelFolder() throws {
        let files = [
            file("items/foo.lua", values: []),
            file("themes/dark.lua", values: []),
            file("scripts/helper.sh", values: [], kind: .shell),
            file("bar.lua", values: []),
            file("widgets/clock.lua", values: [])
        ]
        let groups = SidebarGrouper.group(files: files)

        XCTAssertEqual(try XCTUnwrap(groups.first { $0.category == .items }).category, .items)
        XCTAssertEqual(try XCTUnwrap(groups.first { $0.category == .themes }).category, .themes)
        XCTAssertEqual(try XCTUnwrap(groups.first { $0.category == .scripts }).category, .scripts)
        XCTAssertEqual(try XCTUnwrap(groups.first { $0.category == .bar }).category, .bar)
        XCTAssertEqual(try XCTUnwrap(groups.first { $0.category == .widgets }).category, .widgets)
        XCTAssertEqual(groups.count, 5)
    }

    func testThemeCategoryFromColorValues() throws {
        let themed = file("misc/random.lua", values: [
            value("bg", original: "0xff000000", kind: .color),
            value("fg", original: "0xffffffff", kind: .color),
            value("accent", original: "0xff00ff00", kind: .color),
            value("font", original: "SF Pro"),
            value("size", original: "12")
        ])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [themed]).first)
        XCTAssertEqual(group.category, .themes)
    }

    func testScriptCategoryFromKeys() throws {
        let config = file("misc/random.lua", values: [value("script", original: "echo hi")])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [config]).first)
        XCTAssertEqual(group.category, .scripts)
    }

    func testBarCategoryFromKeys() throws {
        let config = file("misc/random.lua", values: [value("height", original: "36")])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [config]).first)
        XCTAssertEqual(group.category, .bar)
    }

    func testItemsCategoryFromKeys() throws {
        let config = file("misc/random.lua", values: [value("position", original: "left")])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [config]).first)
        XCTAssertEqual(group.category, .items)
    }

    func testOtherCategoryFallback() throws {
        let config = file("misc/random.lua", values: [value("foo", original: "bar")])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [config]).first)
        XCTAssertEqual(group.category, .other)
    }

    func testNestedPathFirstGrouping() throws {
        let nested = file("items/widgets/foo.lua", values: [value("position", original: "left")])

        let group = try XCTUnwrap(SidebarGrouper.group(files: [nested]).first)
        XCTAssertEqual(group.category, .items)
        XCTAssertEqual(group.folders.map(\.title), ["widgets"])
        XCTAssertTrue(group.folders.first?.files.contains { $0.displayName == "items/widgets/foo.lua" } == true)

        let positionNames = Set(["Left", "Center", "Right", "Unpositioned"])
        XCTAssertFalse(group.folders.contains { positionNames.contains($0.title) })
    }

    func testItemsPositionFolders() throws {
        let files = [
            file("items/left/a.lua", values: []),
            file("items/b.lua", values: [value("position", original: "left", draft: "right")]),
            file("items/c.lua", values: [])
        ]

        let group = try groupFor({ $0.category == .items }, from: files)
        XCTAssertEqual(group.folders.map(\.title), ["Left", "Right", "Unpositioned"])
    }

    func testFolderSortOrder() throws {
        let files = [
            file("items/w1.lua", values: [value("position", original: "left")]),
            file("items/w2.lua", values: [value("position", original: "center")]),
            file("items/w3.lua", values: [value("position", original: "right")]),
            file("items/w4.lua", values: []),
            file("items/widgets/foo.lua", values: [value("position", original: "left")])
        ]

        let group = try groupFor({ $0.category == .items }, from: files)
        XCTAssertEqual(group.folders.map(\.title), ["widgets", "Left", "Center", "Right", "Unpositioned"])
    }

    // MARK: - BarPreviewItem

    func testPositionFromDraftValue() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/foo.lua", values: [value("position", original: "left", draft: "right")])))

        XCTAssertEqual(item.position, .right)
        XCTAssertEqual(item.positionValue?.draftValue, "right")
    }

    func testPositionFallbackFromPath() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/left/foo.lua", values: [])))

        XCTAssertEqual(item.position, .left)
    }

    func testNilWithoutPosition() {
        XCTAssertNil(BarPreviewItem(file: file("items/foo.lua", values: [])))
    }

    func testTitleFromLabel() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/foo.lua", values: [
            value("position", original: "left"),
            value("label", original: "x", draft: "  My Label  ")
        ])))

        XCTAssertEqual(item.title, "My Label")
    }

    func testTitleFallsBackToFilename() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [value("position", original: "left")])))

        XCTAssertEqual(item.title, "clock")
    }

    // MARK: - EditableValueGroup

    func testGroupTitles() {
        XCTAssertEqual(EditableValueGroup.title(for: value("icon.string", original: "x")), "Icon")
        XCTAssertEqual(EditableValueGroup.title(for: value("label", original: "x")), "Label")
        XCTAssertEqual(EditableValueGroup.title(for: value("background.color", original: "x")), "Background")
        XCTAssertEqual(EditableValueGroup.title(for: value("popup.align", original: "x")), "Popup")
        XCTAssertEqual(EditableValueGroup.title(for: value("script", original: "x")), "Scripts")
        XCTAssertEqual(EditableValueGroup.title(for: value("width", original: "x")), "Item")
    }

    func testGroupSortRank() {
        XCTAssertLessThan(EditableValueGroup.sortRank("Item"), EditableValueGroup.sortRank("Icon"))
        XCTAssertLessThan(EditableValueGroup.sortRank("Icon"), EditableValueGroup.sortRank("Label"))
        XCTAssertLessThan(EditableValueGroup.sortRank("Label"), EditableValueGroup.sortRank("Background"))
        XCTAssertLessThan(EditableValueGroup.sortRank("Background"), EditableValueGroup.sortRank("Popup"))
        XCTAssertLessThan(EditableValueGroup.sortRank("Popup"), EditableValueGroup.sortRank("Scripts"))
        XCTAssertEqual(EditableValueGroup.sortRank("Mystery"), 99)
        XCTAssertLessThan(EditableValueGroup.sortRank("Scripts"), EditableValueGroup.sortRank("Mystery"))
    }

    // MARK: - CodeSyntaxHighlighter

    func testLuaCommentToken() {
        let tokens = CodeSyntaxHighlighter.tokens(for: "-- comment", kind: .lua)

        XCTAssertEqual(tokens.first?.kind, .comment)
        XCTAssertEqual(tokens.first?.text, "-- comment")
    }

    func testShellCommentToken() {
        let tokens = CodeSyntaxHighlighter.tokens(for: "# comment", kind: .shell)

        XCTAssertEqual(tokens.first?.kind, .comment)
        XCTAssertEqual(tokens.first?.text, "# comment")
    }

    func testStringWithEscapes() {
        let source = "\"say \\\"hi\\\"\""
        let tokens = CodeSyntaxHighlighter.tokens(for: source, kind: .lua)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.kind, .string)
        XCTAssertEqual(tokens.first?.text, source)
    }

    func testNumberTokens() {
        for source in ["42", "3.5", "0xFF"] {
            let tokens = CodeSyntaxHighlighter.tokens(for: source, kind: .lua)
            XCTAssertEqual(tokens.count, 1)
            XCTAssertEqual(tokens.first?.kind, .number)
            XCTAssertEqual(tokens.first?.text, source)
        }
    }

    func testKeywordTokens() {
        let lua = CodeSyntaxHighlighter.tokens(for: "local", kind: .lua)
        XCTAssertEqual(lua.first?.kind, .keyword)
        XCTAssertEqual(lua.first?.text, "local")

        let rc = CodeSyntaxHighlighter.tokens(for: "sketchybar", kind: .shell)
        XCTAssertEqual(rc.first?.kind, .keyword)
        XCTAssertEqual(rc.first?.text, "sketchybar")

        let plain = CodeSyntaxHighlighter.tokens(for: "foo", kind: .lua)
        XCTAssertEqual(plain.first?.kind, .plain)
        XCTAssertEqual(plain.first?.text, "foo")
    }

    func testVariableTokens() {
        for source in ["$var", "${var}"] {
            let tokens = CodeSyntaxHighlighter.tokens(for: source, kind: .shell)
            XCTAssertEqual(tokens.count, 1)
            XCTAssertEqual(tokens.first?.kind, .variable)
            XCTAssertEqual(tokens.first?.text, source)
        }
    }

    func testFlagTokens() {
        let tokens = CodeSyntaxHighlighter.tokens(for: "--flag", kind: .shell)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.kind, .flag)
        XCTAssertEqual(tokens.first?.text, "--flag")
    }

    func testRepeatedTokenizingReturnsTheSameTokens() {
        let first = CodeSyntaxHighlighter.tokens(for: "width = 10", kind: .lua)
        let second = CodeSyntaxHighlighter.tokens(for: "width = 10", kind: .lua)

        XCTAssertEqual(first.map(\.text), second.map(\.text))
        XCTAssertEqual(first.map(\.kind), second.map(\.kind))
    }

    // MARK: - Search filter

    func testSearchMatchesKeyPath() {
        let values = [value("position", original: "left"), value("width", original: "10")]
        let result = EditableValueGroup.filtered(values, searchText: "position", showModifiedOnly: false)

        XCTAssertEqual(result.map(\.keyPath), ["position"])
    }

    func testSearchMatchesDraftValue() {
        let values = [value("label", original: "x", draft: "hello world")]
        let result = EditableValueGroup.filtered(values, searchText: "hello", showModifiedOnly: false)

        XCTAssertEqual(result.map(\.keyPath), ["label"])
    }

    func testSearchIsCaseInsensitive() {
        let values = [value("position", original: "left")]
        let result = EditableValueGroup.filtered(values, searchText: "POSITION", showModifiedOnly: false)

        XCTAssertEqual(result.map(\.keyPath), ["position"])
    }

    func testEmptySearchMatchesAll() {
        let values = [value("a", original: "1"), value("b", original: "2")]

        XCTAssertEqual(EditableValueGroup.filtered(values, searchText: "", showModifiedOnly: false).count, 2)
        XCTAssertEqual(EditableValueGroup.filtered(values, searchText: "   ", showModifiedOnly: false).count, 2)
    }

    func testShowModifiedOnlyFilters() {
        let modified = value("a", original: "1", draft: "2")
        let unchanged = value("b", original: "3")
        let result = EditableValueGroup.filtered([modified, unchanged], searchText: "", showModifiedOnly: true)

        XCTAssertEqual(result.map(\.keyPath), ["a"])
    }

    // MARK: - ConfigFile.matchesSearch

    func testMatchesSearchByDisplayName() {
        let config = file("items/clock.lua", values: [value("width", original: "10")])

        XCTAssertTrue(config.matchesSearch("clock"))
        XCTAssertTrue(config.matchesSearch("CLOCK"))
    }

    func testMatchesSearchByValue() {
        let config = file("items/foo.lua", values: [value("label", original: "plain", draft: "hello world")])

        XCTAssertTrue(config.matchesSearch("hello"))
        XCTAssertTrue(config.matchesSearch("label"))
        XCTAssertFalse(config.matchesSearch("nomatch"))
    }

    func testMatchesSearchEmptyQuery() {
        let config = file("items/foo.lua", values: [value("label", original: "x")])

        XCTAssertTrue(config.matchesSearch(""))
        XCTAssertTrue(config.matchesSearch("   "))
    }

    // MARK: - Value identity

    func testValueEqualityIgnoresTheSourceSnapshot() {
        let plain = value("width", original: "10")
        let withSnapshot = LuaEditableValue(
            id: plain.id,
            fileURL: plain.fileURL,
            keyPath: plain.keyPath,
            lineNumber: plain.lineNumber,
            kind: plain.kind,
            originalValue: plain.originalValue,
            draftValue: plain.draftValue,
            suggestedValues: plain.suggestedValues,
            valueStartOffset: plain.valueStartOffset,
            valueEndOffset: plain.valueEndOffset,
            sourceSnapshot: "width = 999\n"
        )

        XCTAssertEqual(plain, withSnapshot)
        XCTAssertEqual(plain.hashValue, withSnapshot.hashValue)
    }

    func testValueEqualitySeesADifferentDraft() {
        let plain = value("width", original: "10")
        let drafted = value("width", original: "10", draft: "11")

        XCTAssertNotEqual(plain, drafted)
    }
}