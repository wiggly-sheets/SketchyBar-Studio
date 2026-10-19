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

    // MARK: - Width picker fallback

    func testWidthFallbackUsesTheDraft() {
        let fallback = SketchyBarValueRules.numericWidthFallback(
            draft: "42",
            original: "dynamic",
            siblingWidths: ["60"]
        )

        XCTAssertEqual(fallback, "42")
    }

    func testWidthFallbackNeverWritesZeroForADynamicOriginal() {
        let fallback = SketchyBarValueRules.numericWidthFallback(
            draft: "dynamic",
            original: "dynamic",
            siblingWidths: []
        )

        XCTAssertNotEqual(fallback, "0")
        XCTAssertEqual(fallback, "100")
    }

    func testWidthFallbackUsesTheOriginalWidth() {
        let fallback = SketchyBarValueRules.numericWidthFallback(
            draft: "dynamic",
            original: "120",
            siblingWidths: []
        )

        XCTAssertEqual(fallback, "120")
    }

    func testWidthFallbackUsesTheLastNumericWidthOfTheFile() {
        let fallback = SketchyBarValueRules.numericWidthFallback(
            draft: "dynamic",
            original: "dynamic",
            siblingWidths: ["60", "80"]
        )

        XCTAssertEqual(fallback, "80")
    }

    // MARK: - Color format

    func testColorSerializerKeepsTheHashFormat() {
        let color = SketchyBarColor(red: 1, green: 136.0 / 255.0, blue: 0, alpha: 1).color

        XCTAssertEqual(SketchyBarColor.hexString(from: color, preservingFormatOf: "#ff8800"), "#ff8800")
    }

    func testColorSerializerKeepsTheHexWordFormat() {
        let color = SketchyBarColor(red: 1, green: 136.0 / 255.0, blue: 0, alpha: 1).color

        XCTAssertEqual(SketchyBarColor.hexString(from: color, preservingFormatOf: "0xffff8800"), "0xffff8800")
    }

    func testColorSerializerKeepsTheDigitCount() {
        let color = SketchyBarColor(red: 1, green: 136.0 / 255.0, blue: 0, alpha: 1).color

        XCTAssertEqual(SketchyBarColor.hexString(from: color, preservingFormatOf: "#f80"), "#f80")
    }

    func testColorSerializerFallsBackForAnUnreadableValue() {
        let color = SketchyBarColor(red: 1, green: 136.0 / 255.0, blue: 0, alpha: 1).color

        XCTAssertEqual(SketchyBarColor.hexString(from: color, preservingFormatOf: "not-a-color"), "0xffff8800")
    }

    // MARK: - Number validation

    func testNumberValidationRejectsTextThatIsNotANumber() {
        XCTAssertFalse(SketchyBarValueRules.isValidNumber("12px"))
        XCTAssertFalse(SketchyBarValueRules.isValidNumber("1); os.execute(\"curl evil\")"))
        XCTAssertFalse(SketchyBarValueRules.isValidNumber("dynamic"))
        XCTAssertFalse(SketchyBarValueRules.isValidNumber(""))
    }

    func testNumberValidationAcceptsRealNumbers() {
        XCTAssertTrue(SketchyBarValueRules.isValidNumber("12"))
        XCTAssertTrue(SketchyBarValueRules.isValidNumber("12.5"))
        XCTAssertTrue(SketchyBarValueRules.isValidNumber("-3"))
    }

    func testPartialNumbersAreNotNumbersYet() {
        XCTAssertTrue(SketchyBarValueRules.isPartialNumber("-"))
        XCTAssertTrue(SketchyBarValueRules.isPartialNumber("12."))
        XCTAssertFalse(SketchyBarValueRules.isPartialNumber("12px"))
        XCTAssertFalse(SketchyBarValueRules.isPartialNumber("1.2.3"))
    }

    func testInvalidNumberDraftKeepsTheOriginalText() {
        XCTAssertEqual(SketchyBarValueRules.serializedNumber("12px", original: "10"), "10")
    }

    // MARK: - Sidebar order

    func testSidebarCategoryOrderMatchesTheDocumentedOrder() {
        XCTAssertEqual(
            SidebarCategory.allCases,
            [.items, .widgets, .bar, .themes, .scripts, .other]
        )
    }

    func testSidebarGroupsFollowTheCategoryOrder() {
        let files = [
            file("scripts/helper.sh", values: [], kind: .shell),
            file("themes/dark.lua", values: []),
            file("widgets/clock.lua", values: []),
            file("bar.lua", values: []),
            file("items/foo.lua", values: [])
        ]

        let groups = SidebarGrouper.group(files: files)

        XCTAssertEqual(groups.map(\.category), [.items, .widgets, .bar, .themes, .scripts])
    }

    func testSidebarSortsByTheStagedLoaderOrder() {
        let files = [
            file("items/a.lua", values: []),
            file("items/b.lua", values: [])
        ]
        let ranks = [files[0].id: 1, files[1].id: 0]

        let sorted = SidebarGrouper.sortedByLoaderOrder(files, ranks: ranks)

        XCTAssertEqual(sorted.map(\.displayName), ["items/b.lua", "items/a.lua"])
    }

    // MARK: - Status message

    func testStatusKindFollowsTheMessage() {
        XCTAssertEqual(StatusKind(message: "Saved foo.lua and backed up the original."), .success)
        XCTAssertEqual(StatusKind(message: "Loaded 12 config files from default."), .success)
        XCTAssertEqual(StatusKind(message: "Save failed for foo.lua: no permission"), .error)
        XCTAssertEqual(StatusKind(message: "Staged foo earlier. Save to update the loader."), .warning)
        XCTAssertEqual(StatusKind(message: "Point the app at a config folder."), .info)
    }

    // MARK: - Option reference

    func testOptionDocsResolveAFlatKey() throws {
        let doc = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "position"))

        XCTAssertEqual(doc.key, "position")
        XCTAssertEqual(doc.type, .enumeration)
        XCTAssertFalse(doc.summary.isEmpty)
    }

    func testOptionDocsResolveAQualifiedKeyThatHasItsOwnEntry() throws {
        let doc = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "popup.height"))

        XCTAssertEqual(doc.key, "popup.height")
        XCTAssertEqual(doc.defaultValue, "30")
    }

    func testOptionDocsResolveTheQualifiedKeysOfTheSubDomains() throws {
        let fontSize = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "icon.font.size"))
        XCTAssertEqual(fontSize.key, "icon.font.size")
        XCTAssertEqual(fontSize.defaultValue, "14")

        let borderColor = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "background.border_color"))
        XCTAssertEqual(borderColor.key, "background.border_color")

        let labelColor = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "label.color"))
        XCTAssertEqual(labelColor.key, "label.color")
        XCTAssertEqual(labelColor.type, .color)
    }

    func testOptionDocsFallBackToTheLeafKey() throws {
        let padding = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "icon.padding_left"))
        XCTAssertEqual(padding.key, "padding_left")

        let maxChars = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "label.max_chars"))
        XCTAssertEqual(maxChars.key, "max_chars")
    }

    func testOptionDocsHaveNoEntryForAnUnknownKey() {
        XCTAssertNil(SketchyBarOptionDocs.doc(for: "not_a_sketchybar_option"))
        XCTAssertNil(SketchyBarOptionDocs.doc(for: ""))
    }

    func testOptionDocsTableHasTheCoreKeys() {
        let keys = Set(SketchyBarOptionDocs.all.map(\.key))

        for key in ["position", "align", "width", "updates", "update_freq", "icon", "label",
                    "script", "click_script", "space", "display", "associated_display",
                    "associated_space", "ignore_association", "scroll_texts", "scroll_duration",
                    "max_chars", "cache_scripts", "lazy", "drawing", "shadow", "font",
                    "color", "highlight", "highlight_color", "padding_left", "padding_right",
                    "x_offset", "y_offset", "border_color", "border_width", "corner_radius",
                    "fill_color", "symbol_color", "symbol_mode", "percentage", "anchor",
                    "margin", "topmost", "sticky", "show_in_fullscreen", "hidden",
                    "font_smoothing", "notch_width", "notch_offset", "notch_display_height",
                    "horizontal"] {
            XCTAssertTrue(keys.contains(key), "missing option reference for \(key)")
        }
    }

    func testOptionDocsKeysAreUnique() {
        XCTAssertEqual(Set(SketchyBarOptionDocs.all.map(\.key)).count, SketchyBarOptionDocs.all.count)
    }

    func testOptionDocsListTheAcceptedValues() throws {
        let position = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "position"))
        XCTAssertEqual(position.values, ["left", "right", "center", "q", "e", "popup", "top", "bottom"])

        let updates = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "updates"))
        XCTAssertEqual(updates.values, ["on", "off", "when_shown"])

        let align = try XCTUnwrap(SketchyBarOptionDocs.doc(for: "align"))
        XCTAssertEqual(align.values, ["left", "right", "center"])
    }

    // MARK: - Option suggestions

    private let catalog = SketchyBarOptionCatalog()

    func testCatalogKeepsTheCurrentValueFirst() {
        let values = catalog.suggestedValues(for: "symbol_mode", currentValue: "custom")

        XCTAssertEqual(values.first, "custom")
        XCTAssertTrue(values.contains("automatic"))
    }

    func testCatalogReturnsThePositionList() {
        XCTAssertEqual(
            catalog.suggestedValues(for: "position", currentValue: "left"),
            ["left", "right", "center", "q", "e"]
        )
    }

    func testCatalogKeepsThePopupPositionHint() {
        let values = catalog.suggestedValues(for: "position", currentValue: "popup.space.1")

        XCTAssertEqual(values.first, "popup.space.1")
        XCTAssertTrue(values.contains("center"))
    }

    func testCatalogReturnsTheBooleanListForABooleanKey() {
        XCTAssertEqual(
            catalog.suggestedValues(for: "drawing", currentValue: "true"),
            ["true", "false"]
        )
    }

    func testCatalogReturnsTheValuesOfTheOptionReference() {
        XCTAssertEqual(
            catalog.suggestedValues(for: "symbol_mode", currentValue: "color"),
            ["automatic", "color", "draw"]
        )
        XCTAssertEqual(
            catalog.suggestedValues(for: "updates", currentValue: "when_shown"),
            ["on", "off", "when_shown"]
        )
    }

    func testCatalogHasNoSuggestionsForAFreeFormOption() {
        XCTAssertEqual(catalog.suggestedValues(for: "scroll_duration", currentValue: "200"), [])
        XCTAssertEqual(catalog.suggestedValues(for: "update_freq", currentValue: "5"), [])
    }
}