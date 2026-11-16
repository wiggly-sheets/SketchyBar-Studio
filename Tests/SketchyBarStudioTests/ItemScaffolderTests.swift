import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the item scaffolder.
///
/// The generated files are read back with the parser of the app, so a file
/// that the parser cannot read is a failure here too.
final class ItemScaffolderTests: XCTestCase {
    private let scaffolder = ItemScaffolder()

    // MARK: - The SbarLua files

    func testEveryTemplateDeclaresTheItemWithItsAlias() {
        for template in scaffolder.templates(for: .sbarLua) {
            let contents = contents(for: template, alias: "my_item")

            XCTAssertTrue(
                contents.contains("sbar.add(\"item\", \"my_item\", {"),
                "\(template.id) does not declare the item"
            )
            XCTAssertTrue(contents.hasSuffix("\n"), "\(template.id) does not end with a newline")
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                XCTAssertFalse(
                    line.hasSuffix(" ") || line.hasSuffix("\t"),
                    "\(template.id) has a line with trailing whitespace"
                )
            }
        }
    }

    func testTheAliasInTheScriptIsTheAliasOfTheItem() {
        for template in scaffolder.templates(for: .sbarLua) {
            guard template.kind == .script || template.kind == .appIcon else { continue }
            let contents = contents(for: template, alias: "my_item")

            XCTAssertTrue(
                contents.contains("sketchybar --set my_item label="),
                "\(template.id) does not set the label of its own item"
            )
            XCTAssertEqual(
                contents.components(separatedBy: "sketchybar --set ").count - 1,
                1,
                "\(template.id) sets the label of more than one item"
            )
        }
    }

    func testTheGeneratedFileIsReadByTheSbarLuaParser() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .sbarLua).first { $0.id == "clock" })
        let contents = contents(for: template, alias: "clock")

        let items = SbarLuaItemParser.items(in: contents)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.alias, "clock")

        XCTAssertEqual(value("position", in: item), "\"right\"")
        XCTAssertEqual(value("update_freq", in: item), "60")
        let script = try XCTUnwrap(value("script", in: item))
        XCTAssertTrue(script.contains("sketchybar --set clock label="))
    }

    func testEveryPropertyOfTheGeneratedTableIsKnownToSketchyBar() throws {
        for template in scaffolder.templates(for: .sbarLua) {
            let contents = contents(for: template, alias: "my_item")
            let parsed = LuaTableParser.parse(source: contents)
            let table = try XCTUnwrap(parsed.tables.first, "\(template.id) has no table")

            for entry in table.entries {
                let keyPath = entry.path.joined(separator: ".")
                XCTAssertNotNil(
                    SketchyBarOptionDocs.doc(for: keyPath),
                    "\(template.id) uses the unknown option \(keyPath)"
                )
            }
        }
    }

    func testTheCustomTemplateOnlyHoldsThePosition() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .sbarLua).first { $0.id == "custom" })
        let contents = contents(for: template, alias: "my_item")

        let parsed = LuaTableParser.parse(source: contents)
        let table = try XCTUnwrap(parsed.tables.first)
        XCTAssertEqual(table.entries.map(\.path), [["position"]])
    }

    func testTheScriptTemplateHoldsThePositionTheScriptAndTheFrequency() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .sbarLua).first { $0.id == "clock" })
        let contents = contents(for: template, alias: "my_item")

        let parsed = LuaTableParser.parse(source: contents)
        let table = try XCTUnwrap(parsed.tables.first)
        XCTAssertEqual(
            table.entries.map(\.path),
            [["position"], ["script"], ["update_freq"]]
        )
    }

    // MARK: - The shell files

    func testTheShellStyleWritesTheAddAndTheSetLine() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .shell).first { $0.id == "clock" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: "sf.clock",
            label: "",
            updateFreq: 60
        )

        XCTAssertTrue(contents.contains("sketchybar --add item clock right"))
        XCTAssertTrue(contents.contains("sketchybar --set clock label="))
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    func testTheShellStyleOfTheCustomTemplateOnlyAddsTheItem() throws {
        let template = try XCTUnwrap(scaffolder.templates(for: .shell).first { $0.id == "custom" })
        let contents = scaffolder.fileContents(
            template: template,
            alias: "clock",
            position: "right",
            icon: "",
            label: "",
            updateFreq: 0
        )

        XCTAssertEqual(contents, "sketchybar --add item clock right\n")
    }

    // MARK: - The loader line

    func testTheLoaderLineFollowsThePathOfTheFile() {
        XCTAssertEqual(
            scaffolder.loaderLine(for: "clock", relativePath: "items/left/clock.lua"),
            "require(\"items.left.clock\")"
        )
        XCTAssertEqual(
            scaffolder.loaderLine(for: "clock", relativePath: "items/right/battery.lua"),
            "require(\"items.right.battery\")"
        )
    }

    func testTheShellLoaderLineSourcesTheFile() {
        let line = scaffolder.loaderLine(for: "clock", relativePath: "items/right/clock.sh", style: .shell)

        XCTAssertEqual(line, "source items/right/clock.sh")
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

    private func value(_ keyPath: String, in item: StructuredItem) -> String? {
        item.values.first { $0.keyPath == keyPath }?.rawValue
    }
}
