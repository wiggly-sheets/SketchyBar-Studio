import Foundation
@testable import SketchyBarStudio
import XCTest

final class ParserActivationSafetyTests: XCTestCase {
    func testLuaScannerFindsEveryAssignmentOnCompactLine() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/battery.lua")
        try write(
            #"sbar.add("item", "battery", { position = "right", drawing = true })"# + "\n",
            to: fileURL
        )

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["position", "drawing"])
        XCTAssertEqual(values.map(\.draftValue), ["right", "true"])
    }

    func testLuaScannerKeepsEscapedQuotesInsideTheValue() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/quote.lua")
        try write(
            #"local item = { label = "say \"hello\"", drawing = true }"# + "\n",
            to: fileURL
        )

        let values = LuaConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["label", "drawing"])
        XCTAssertEqual(values.first?.draftValue, #"say \"hello\""#)
    }

    func testLuaSaveRewritesOnlyChangedValues() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/quote.lua")
        let source = #"local item = { label = "say \"hello\"", drawing = true }"# + "\n"
        try write(source, to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        let drawingIndex = try XCTUnwrap(values.firstIndex { $0.keyPath == "drawing" })
        values[drawingIndex].draftValue = "false"

        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            #"local item = { label = "say \"hello\"", drawing = false }"# + "\n"
        )
    }

    func testLuaSavePreservesQuoteStyleAndExistingEscapesWhenEditingAString() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/quote.lua")
        try write(#"label = "say \"hello\" at C:\\tmp""# + "\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        values[0].draftValue = #"say \"bye\" at D:\\work"#

        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            #"label = "say \"bye\" at D:\\work""# + "\n"
        )
    }

    func testLuaSaveRejectsSourceChangedSinceScan() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/position.lua")
        try write(#"position = "right""# + "\n", to: fileURL)
        let scanner = LuaConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        values[0].draftValue = "left"
        let externallyEditedSource = "-- changed elsewhere\n" + #"position = "right""# + "\n"
        try write(externallyEditedSource, to: fileURL)

        XCTAssertThrowsError(try scanner.save(values: values, to: fileURL, rootURL: root)) { error in
            guard case ConfigSourceSaveError.sourceChanged(let changedURL) = error else {
                return XCTFail("Expected a source-changed conflict, got \(error)")
            }
            XCTAssertEqual(changedURL.standardizedFileURL, fileURL.standardizedFileURL)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externallyEditedSource)
    }

    func testShellScannerKeepsEscapedQuotesAndBackslashesInsideTheValue() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        try write(
            #"LABEL="say \"hello\" at C:\\tmp" DRAWING=on"# + "\n",
            to: fileURL
        )

        let values = ShellConfigScanner().scan(fileURL: fileURL)

        XCTAssertEqual(values.map(\.keyPath), ["LABEL", "DRAWING"])
        XCTAssertEqual(values.first?.draftValue, #"say \"hello\" at C:\\tmp"#)
    }

    func testShellSaveRewritesOnlyChangedValues() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/label.sh")
        let source = #"LABEL="say \"hello\" at C:\\tmp" DRAWING=on"# + "\n"
        try write(source, to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        let drawingIndex = try XCTUnwrap(values.firstIndex { $0.keyPath == "DRAWING" })
        values[drawingIndex].draftValue = "off"

        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            #"LABEL="say \"hello\" at C:\\tmp" DRAWING=false"# + "\n"
        )
    }

    func testShellSaveQuotesAndEscapesStringsWhenEditing() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/path.sh")
        try write(#"LABEL='C:\tmp'"# + "\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        values[0].draftValue = #"D:\work"#

        try scanner.save(values: values, to: fileURL, rootURL: root)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), #"LABEL="D:\\work""# + "\n")
    }

    func testShellSaveRejectsSourceChangedSinceScan() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/position.sh")
        try write("POSITION=right\n", to: fileURL)
        let scanner = ShellConfigScanner()
        var values = scanner.scan(fileURL: fileURL)
        values[0].draftValue = "left"
        let externallyEditedSource = "# changed elsewhere\nPOSITION=right\n"
        try write(externallyEditedSource, to: fileURL)

        XCTAssertThrowsError(try scanner.save(values: values, to: fileURL, rootURL: root)) { error in
            guard case ConfigSourceSaveError.sourceChanged(let changedURL) = error else {
                return XCTFail("Expected a source-changed conflict, got \(error)")
            }
            XCTAssertEqual(changedURL.standardizedFileURL, fileURL.standardizedFileURL)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externallyEditedSource)
    }

    func testActivationLookupRequiresAnAnchoredExactLoaderTarget() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/battery.lua")
        try write("drawing = true\n", to: fileURL)
        try write(
            #"require("items.battery.extra")"# + "\n" +
                #"print('require("items.battery")')"# + "\n" +
                #"if enabled then require("items.battery") end"# + "\n" +
                #"require("items.battery")"# + "\n",
            to: root.appendingPathComponent("init.lua")
        )

        let reference = ConfigActivationService().reference(for: fileURL, rootURL: root)

        XCTAssertEqual(reference?.lineNumber, 4)
    }

    func testActivationLookupDoesNotTreatArbitraryShellScriptsAsEntrypoints() throws {
        let root = try makeConfigRoot()
        let fileURL = root.appendingPathComponent("items/battery.lua")
        try write("drawing = true\n", to: fileURL)
        try write(
            #"source "$CONFIG_DIR/items/battery.lua""# + "\n",
            to: root.appendingPathComponent("scripts/unrelated-helper.sh")
        )

        let reference = ConfigActivationService().reference(for: fileURL, rootURL: root)

        XCTAssertNil(reference)
    }

    func testDirectionalReorderSwapsLoaderReferencesWithoutMovingSetupCode() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        try write("drawing = true\n", to: firstURL)
        try write("drawing = true\n", to: secondURL)
        let entrypointURL = root.appendingPathComponent("init.lua")
        try write(
            #"require("items.first")"# + "\n" +
                "local shared_setting = true\n" +
                #"require("items.second")"# + "\n",
            to: entrypointURL
        )
        let service = ConfigActivationService()
        let secondReference = try XCTUnwrap(service.reference(for: secondURL, rootURL: root))
        let secondFile = ConfigFile(
            url: secondURL,
            rootURL: root,
            kind: .lua,
            values: [],
            activationReference: secondReference
        )

        try service.moveReference(for: secondFile, direction: .up)

        XCTAssertEqual(
            try String(contentsOf: entrypointURL, encoding: .utf8),
            #"require("items.second")"# + "\n" +
                "local shared_setting = true\n" +
                #"require("items.first")"# + "\n"
        )
    }

    func testBatchReorderUsesLoaderSlotsAndPreservesInterveningCode() throws {
        let root = try makeConfigRoot()
        let firstURL = root.appendingPathComponent("items/first.lua")
        let secondURL = root.appendingPathComponent("items/second.lua")
        let thirdURL = root.appendingPathComponent("items/third.lua")
        for url in [firstURL, secondURL, thirdURL] {
            try write("drawing = true\n", to: url)
        }
        let entrypointURL = root.appendingPathComponent("init.lua")
        let originalSource = #"require("items.first")"# + "\n" +
            "local shared_setting = true\n" +
            #"require("items.second")"# + "\n" +
            "-- keep this comment in place\n" +
            #"require("items.third")"# + "\n"
        try write(originalSource, to: entrypointURL)
        let service = ConfigActivationService()
        let references = service.references(for: [firstURL, secondURL, thirdURL], rootURL: root)
        let files = try [firstURL, secondURL, thirdURL].map { url in
            ConfigFile(
                url: url,
                rootURL: root,
                kind: .lua,
                values: [],
                activationReference: try XCTUnwrap(references[url.path])
            )
        }

        try service.moveReferences(in: files, to: [files[2].id, files[0].id, files[1].id])

        XCTAssertEqual(
            try String(contentsOf: entrypointURL, encoding: .utf8),
            #"require("items.third")"# + "\n" +
                "local shared_setting = true\n" +
                #"require("items.first")"# + "\n" +
                "-- keep this comment in place\n" +
                #"require("items.second")"# + "\n"
        )
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("backups/.sketchybar-studio/init.lua"), encoding: .utf8),
            originalSource
        )
    }

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioParserTests")
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
