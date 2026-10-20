import AppKit
import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the fixes of the audit, batch X.
///
/// Every test pins one finding: the generated files, the icon cache, the
/// diff and the locator.
final class AuditFixBatchXTests: XCTestCase {
    private let scaffolder = ItemScaffolder()

    // MARK: - F1: the SbarLua templates run their command

    func testEveryScriptTemplateOfSbarLuaHoldsTheCommandInASubstitution() throws {
        var checked = 0
        for template in scaffolder.templates(for: .sbarLua) {
            guard template.kind == .script || template.kind == .appIcon else { continue }
            let contents = contents(for: template, alias: "my_item")
            let script = try XCTUnwrap(scriptValue(in: contents), "\(template.id) has no script")

            XCTAssertTrue(
                script.contains("sketchybar --set my_item label=\"$("),
                "\(template.id) does not run its command in a substitution"
            )
            checked += 1
        }
        XCTAssertEqual(checked, 7, "the script templates changed")
    }

    func testTheCommandOfTheSbarLuaClockIsInsideTheSubstitution() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .sbarLua).first { $0.id == "clock" })
        let contents = contents(for: template, alias: "clock")
        let script = try XCTUnwrap(scriptValue(in: contents))

        let open = try XCTUnwrap(script.range(of: "$("))
        let close = try XCTUnwrap(script.range(of: ")", range: open.upperBound..<script.endIndex))
        let command = unescapedLua(String(script[open.upperBound..<close.lowerBound]))

        XCTAssertEqual(command, "date '+%H:%M'")
    }

    // MARK: - F5: the shell file does not run the text of the user

    func testTheShellStyleEscapesTheLabelOfTheUser() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .shell).first { $0.id == "static" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: "sf.text.bubble",
            label: "$(whoami)",
            updateFreq: 0
        )

        XCTAssertTrue(contents.contains("label=\"\\$(whoami)\""))
        XCTAssertFalse(hasUnescapedSubstitution(contents), "the label of the user must not run")
    }

    func testTheShellStyleEscapesTheIconOfTheUser() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .shell).first { $0.id == "static" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: "`whoami`",
            label: "hello",
            updateFreq: 0
        )

        XCTAssertTrue(contents.contains("icon=\"\\`whoami\\`\""))
        XCTAssertFalse(hasUnescapedSubstitution(contents), "the icon of the user must not run")
    }

    func testTheShellStyleRunsTheCommandOfTheTemplate() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .shell).first { $0.id == "clock" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: "sf.clock",
            label: "",
            updateFreq: 60
        )

        XCTAssertTrue(contents.contains("label=\"$(date '+%H:%M')\""))
        XCTAssertTrue(hasUnescapedSubstitution(contents), "the command of the template must run")
    }

    // MARK: - F9: the icon cache

    func testOnlyValuesWithADotCanBeBundleIdentifiers() {
        XCTAssertTrue(SketchyBarIcon.canBeBundleIdentifier("com.apple.Safari"))
        XCTAssertFalse(SketchyBarIcon.canBeBundleIdentifier("Safari"))
        XCTAssertFalse(SketchyBarIcon.canBeBundleIdentifier(""))
        XCTAssertFalse(SketchyBarIcon.canBeBundleIdentifier("com apple Safari"))
    }

    func testAValueThatIsNotABundleIdIsNeverLookedUp() {
        var lookups = 0
        let cache = SketchyBarIconImageCache(lookup: { _ in
            lookups += 1
            return nil
        })

        let image = cache.image(for: SketchyBarIcon.parse("app.notabundleid"))

        XCTAssertNil(image)
        XCTAssertEqual(lookups, 0, "the system must not be asked for a value that is no bundle id")
    }

    func testABundleIdIsLookedUpOnce() {
        var lookups = 0
        let cache = SketchyBarIconImageCache(lookup: { _ in
            lookups += 1
            return nil
        })
        let icon = SketchyBarIcon.parse("app.com.apple.Safari")

        _ = cache.image(for: icon)
        _ = cache.image(for: icon)

        XCTAssertEqual(lookups, 1)
    }

    func testTheCacheDropsTheOldestEntryWhenItIsFull() {
        var lookups = 0
        let cache = SketchyBarIconImageCache(lookup: { _ in
            lookups += 1
            return nil
        })

        for index in 0..<100 {
            _ = cache.image(for: SketchyBarIcon.parse("app.com.example.app\(index)"))
        }
        XCTAssertEqual(lookups, 100)

        // The oldest entries were dropped, so they are looked up again.
        _ = cache.image(for: SketchyBarIcon.parse("app.com.example.app0"))
        XCTAssertEqual(lookups, 101)
    }

    // MARK: - F11: the diff tells a trailing newline

    func testATrailingNewlineIsADifference() {
        let difference = DiffEngine.difference(old: "a\nb", new: "a\nb\n")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertNotNil(difference.note)
        XCTAssertNotEqual(DiffEngine.summary(for: difference), "No changes")
    }

    func testTheSameTextHasNoDifference() {
        let difference = DiffEngine.difference(old: "a\nb\n", new: "a\nb\n")

        XCTAssertTrue(difference.hunks.isEmpty)
        XCTAssertNil(difference.note)
        XCTAssertEqual(DiffEngine.summary(for: difference), "No changes")
    }

    func testCarriageReturnsDoNotMakeAWholeFileDiff() {
        let difference = DiffEngine.difference(old: "a\r\nb\r\nc\r\n", new: "a\nb\nc\n")

        XCTAssertTrue(difference.hunks.isEmpty, "a CRLF file must not look like a changed file")
        XCTAssertNotNil(difference.note)
    }

    // MARK: - F12: the locator skips a backup folder at every depth

    func testAFileInABackupFolderIsNotListed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioAuditFixBatchXTests")
            .appendingPathComponent(UUID().uuidString)
        let items = root.appendingPathComponent("items")
        let backups = items.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let kept = items.appendingPathComponent("kept.lua")
        let backup = backups.appendingPathComponent("old.lua")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "old".write(to: backup, atomically: true, encoding: .utf8)

        let files = SketchyBarConfigLocator().configFiles(in: root)

        XCTAssertTrue(files.contains(kept))
        XCTAssertFalse(files.contains(backup), "a file in a backup folder must not be listed")
    }

    // MARK: - F13: the parser counts characters

    func testEveryRangeOfTheParserIsACharacterOffset() throws {
        let source = """
        local clock = sbar.add("item", "clock", {
        \tposition = "right",
        \ticon = { font = { size = 12 } },
        \tlabel = colors.red,
        \tempty =
        })
        """
        let characters = Array(source)
        let parsed = LuaTableParser.parse(source: source)

        XCTAssertFalse(parsed.tables.isEmpty)
        for table in parsed.tables {
            assertRange(table.range, in: characters.count)

            for entry in table.entries {
                assertRange(entry.keyRange, in: characters.count)
                assertRange(entry.valueRange, in: characters.count)

                XCTAssertGreaterThanOrEqual(
                    entry.valueRange.start,
                    entry.keyRange.end,
                    "the value of \(entry.path) must come after its key"
                )
                XCTAssertEqual(
                    String(characters[entry.valueRange.start..<entry.valueRange.end]),
                    entry.text,
                    "the range of \(entry.path) does not point at its text"
                )
            }
        }

        for call in parsed.calls {
            assertRange(call.range, in: characters.count)
        }
    }

    // MARK: - Helpers

    private func contents(for template: ItemScaffolder.Template, alias: String) -> String {
        scaffolder.fileContents(
            template: template,
            alias: alias,
            position: "right",
            icon: scaffolder.defaultIcon(for: template),
            label: "Hello",
            updateFreq: scaffolder.defaultUpdateFreq(for: template)
        )
    }

    /// The script of the first item of a generated file.
    private func scriptValue(in contents: String) -> String? {
        let item = SbarLuaItemParser.items(in: contents).first
        let rawValue = item?.values.first { $0.keyPath == "script" }?.rawValue
        return rawValue.map(SketchyBarValueRules.unquoted)
    }

    /// The text of a Lua string, without the escape of the quotes.
    private func unescapedLua(_ value: String) -> String {
        value.replacingOccurrences(of: "\\'", with: "'")
    }

    /// True when the text holds a command substitution that the shell would
    /// run.
    private func hasUnescapedSubstitution(_ text: String) -> Bool {
        var index = text.startIndex
        while let range = text.range(of: "$(", range: index..<text.endIndex) {
            if range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] != "\\" {
                return true
            }
            index = range.upperBound
        }
        return false
    }

    private func assertRange(
        _ range: LuaSourceRange,
        in count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(range.start, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(range.end, count, "the range is outside the file", file: file, line: line)
        XCTAssertLessThanOrEqual(range.start, range.end, "the range runs backwards", file: file, line: line)
    }
}
