import Foundation
@testable import SketchyBarStudio
import XCTest

/// The bar and an item share the name of some properties, but the values
/// of those names are not the same. The bar sits at the top or at the
/// bottom, an item sits at the left, at the right or in the center.
final class BarLevelPropertyTests: XCTestCase {
    // MARK: - Helpers

    private let barSnippet = """
    sbar.bar({
        position = "top",
        margin = 4,
        height = 28,
        color = 0x40000000,
    })
    """

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioBarLevelTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        let folder = URL(fileURLWithPath: url.pathComponents.dropLast().joined(separator: "/"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scanLua(_ contents: String) throws -> [LuaEditableValue] {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("bar.lua")
        try write(contents, to: fileURL)
        return LuaConfigScanner().scan(fileURL: fileURL)
    }

    private func scanShell(_ contents: String) throws -> [LuaEditableValue] {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("sketchybarrc")
        try write(contents, to: fileURL)
        return ShellConfigScanner().scan(fileURL: fileURL)
    }

    // MARK: - The key paths of the bar

    func testTheBarTableUsesTheKeyPathsOfTheBar() throws {
        let values = try scanLua(barSnippet)

        XCTAssertEqual(
            values.map(\.keyPath),
            ["bar.position", "bar.margin", "bar.height", "bar.color"]
        )
    }

    func testTheBarPositionOffersTheValuesOfTheBar() throws {
        let values = try scanLua(barSnippet)

        let position = try XCTUnwrap(values.first { $0.keyPath == "bar.position" })
        XCTAssertEqual(position.suggestedValues, ["top", "bottom"])
    }

    func testTheBarColorIsAColor() throws {
        let values = try scanLua(barSnippet)

        let color = try XCTUnwrap(values.first { $0.keyPath == "bar.color" })
        XCTAssertEqual(color.kind, .color)
    }

    func testAnItemKeepsTheKeyPathsOfAnItem() throws {
        let values = try scanLua("sbar.add(\"item\", \"x\", { position = \"right\" })")

        XCTAssertEqual(values.map(\.keyPath), ["position"])
        XCTAssertEqual(values.first?.suggestedValues, ["left", "right", "center", "q", "e"])
    }

    func testAFileWithoutABarKeepsThePlainKeys() throws {
        let values = try scanLua("""
        local colors = {
            white = "#ffffff",
            position = "left",
        }
        """)

        XCTAssertEqual(values.map(\.keyPath), ["white", "position"])
    }

    func testABarPropertyWithoutABarEntryFallsBackToItsLeaf() throws {
        let values = try scanLua("sbar.bar({\n\tmargin = 4,\n})\n")

        let margin = try XCTUnwrap(values.first)
        XCTAssertEqual(margin.keyPath, "bar.margin")
        XCTAssertEqual(SketchyBarOptionDocs.doc(for: margin.keyPath)?.key, "margin")
    }

    // MARK: - The shell

    func testTheShellBarPropertiesUseTheKeyPathsOfTheBar() throws {
        let values = try scanShell("sketchybar --bar position=top margin=4\n")

        XCTAssertEqual(values.map(\.keyPath), ["bar.position", "bar.margin"])

        let position = try XCTUnwrap(values.first { $0.keyPath == "bar.position" })
        XCTAssertEqual(position.suggestedValues, ["top", "bottom"])
    }

    func testTheShellItemPropertiesKeepTheKeyPathsOfAnItem() throws {
        let values = try scanShell("sketchybar --set clock position=right\n")

        XCTAssertEqual(values.map(\.keyPath), ["position"])
    }

    func testTheShellLineThatAddsAnItemHasNoBarValues() throws {
        let values = try scanShell("sketchybar --add item clock left\n")

        XCTAssertTrue(values.isEmpty)
    }

    // MARK: - The validator

    func testTheValidatorAcceptsThePositionOfTheBar() throws {
        let root = try makeConfigRoot()
        try write(barSnippet, to: root.appendingPathComponent("bar.lua"))

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .invalidValue }.isEmpty)
    }

    func testTheValidatorReportsAnInvalidPositionOfTheBar() throws {
        let root = try makeConfigRoot()
        try write("sbar.bar({\n\tposition = \"sideways\",\n})\n", to: root.appendingPathComponent("bar.lua"))

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let invalid = diagnostics.filter { $0.kind == .invalidValue }
        XCTAssertEqual(invalid.count, 1)
        XCTAssertEqual(invalid.first?.keyPath, "bar.position")
        XCTAssertEqual(invalid.first?.severity, .error)
    }

    func testTheValidatorStillReportsAnInvalidPositionOfAnItem() throws {
        let root = try makeConfigRoot()
        try write(
            "sbar.add(\"item\", \"clock\", {\n\tposition = \"sideways\",\n})\n",
            to: root.appendingPathComponent("clock.lua")
        )

        let diagnostics = ConfigValidator().validate(rootURL: root)

        let invalid = diagnostics.filter { $0.kind == .invalidValue }
        XCTAssertEqual(invalid.count, 1)
        XCTAssertEqual(invalid.first?.keyPath, "position")
    }

    func testTheValidatorDoesNotReportABarPropertyAsUnknown() throws {
        let root = try makeConfigRoot()
        try write("sbar.bar({\n\tmargin = 4,\n})\n", to: root.appendingPathComponent("bar.lua"))

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .unknownOption }.isEmpty)
    }

    // MARK: - Writing

    func testWritingABarValueChangesOnlyItsOwnBytes() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("bar.lua")
        try write(barSnippet, to: fileURL)

        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        let index = try XCTUnwrap(values.firstIndex { $0.keyPath == "bar.position" })
        values[index].draftValue = "bottom"

        let edited = values[index]
        let start = barSnippet.index(barSnippet.startIndex, offsetBy: edited.valueStartOffset)
        let end = barSnippet.index(barSnippet.startIndex, offsetBy: edited.valueEndOffset)
        XCTAssertEqual(String(barSnippet[start..<end]), "\"top\"")

        let prefix = String(barSnippet[..<start])
        let suffix = String(barSnippet[end...])
        let updated = scanner.updatedContents(values: values, originalContents: barSnippet)

        XCTAssertEqual(updated, prefix + "\"bottom\"" + suffix)

        try scanner.save(values: values, to: fileURL, rootURL: root)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), prefix + "\"bottom\"" + suffix)
    }

    func testTheBarTableIsUnchangedWithoutADraft() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("bar.lua")
        try write(barSnippet, to: fileURL)

        let scanner = LuaConfigScanner()
        let values = scanner.scan(fileURL: fileURL)

        XCTAssertEqual(scanner.updatedContents(values: values, originalContents: barSnippet), barSnippet)
    }

    func testTheBarValuesStayEditable() throws {
        let values = try scanLua(barSnippet)

        XCTAssertEqual(values.count, 4)
        XCTAssertTrue(values.allSatisfy { !$0.isMissingFromFile })
        XCTAssertEqual(Set(values.map(\.valueStartOffset)).count, values.count)
    }

    // MARK: - The config the app writes

    func testTheGeneratedConfigHasNoInvalidValue() throws {
        let scaffolder = ConfigScaffolder()
        let files = scaffolder.fileContents(
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        )
        let root = try makeConfigRoot()
        for (path, contents) in files {
            try write(contents, to: root.appendingPathComponent(path))
        }

        let diagnostics = ConfigValidator().validate(rootURL: root)

        XCTAssertTrue(diagnostics.filter { $0.kind == .invalidValue }.isEmpty)
    }

    func testTheGeneratedBarUsesTheKeyPathsOfTheBar() throws {
        let scaffolder = ConfigScaffolder()
        let files = scaffolder.fileContents(
            style: .sbarLua,
            starterItems: scaffolder.starterItems(for: .sbarLua)
        )
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("bar.lua")
        try write(files["bar.lua"] ?? "", to: fileURL)

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.first?.keyPath, "bar.position")
        XCTAssertEqual(values.first?.suggestedValues, ["top", "bottom"])
    }

    // MARK: - The picker

    private let catalog = SketchyBarOptionCatalog()

    func testThePickerKeepsTheCurrentValueOfEveryOption() {
        for doc in SketchyBarOptionDocs.all where !doc.values.isEmpty {
            for value in doc.values {
                let suggestions = catalog.suggestedValues(for: doc.key, currentValue: value)
                XCTAssertTrue(
                    suggestions.contains(value),
                    "the picker of \(doc.key) has no tag for \(value)"
                )
            }
        }
    }

    func testThePickerOffersTheBarValuesOfTheBarProperties() {
        XCTAssertEqual(
            catalog.suggestedValues(for: "bar.position", currentValue: "top"),
            ["top", "bottom"]
        )
        XCTAssertEqual(
            catalog.suggestedValues(for: "bar.display", currentValue: "main"),
            ["all", "main"]
        )
    }

    func testThePickerOffersTheItemValuesOfTheItemProperties() {
        XCTAssertEqual(
            catalog.suggestedValues(for: "position", currentValue: "left"),
            ["left", "right", "center", "q", "e"]
        )
    }
}
