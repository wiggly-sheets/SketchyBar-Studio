import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the config scaffolder.
///
/// The generated files are read back with the parsers of the app, so a
/// file that the app cannot read is a failure here too. The Lua files are
/// checked with `luac` and the shell file with `sh` when the system has
/// them.
final class ConfigScaffolderTests: XCTestCase {
    private let scaffolder = ConfigScaffolder()

    // MARK: - The files of a config

    func testTheSbarLuaConfigHoldsEveryFileItNeeds() {
        let files = files(for: .sbarLua)

        XCTAssertEqual(
            files.keys.sorted(),
            [
                "bar.lua",
                "helpers/icons.lua",
                "init.lua",
                "items/left/clock.lua",
                "items/right/battery.lua",
                "items/right/media.lua",
                "items/right/volume.lua",
                "items/right/wifi.lua",
                "sketchybarrc",
                "themes/colors.lua"
            ]
        )
    }

    func testTheShellConfigHoldsTheEntryPoint() {
        let files = files(for: .shell)

        XCTAssertEqual(files.keys.sorted(), ["sketchybarrc"])
    }

    func testOnlyThePickedItemsAreWritten() {
        let items = scaffolder.starterItems(for: .sbarLua)
            .filter { $0.id == "clock" || $0.id == "battery" }
        let files = scaffolder.fileContents(style: .sbarLua, starterItems: items)

        XCTAssertEqual(
            files.keys.sorted(),
            [
                "bar.lua",
                "helpers/icons.lua",
                "init.lua",
                "items/left/clock.lua",
                "items/right/battery.lua",
                "sketchybarrc",
                "themes/colors.lua"
            ]
        )
    }

    func testEveryFileEndsWithANewlineAndHasNoTrailingWhitespace() {
        for style in ConfigScaffolder.Style.allCases {
            for (path, contents) in files(for: style) {
                XCTAssertTrue(contents.hasSuffix("\n"), "\(path) does not end with a newline")
                for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                    XCTAssertFalse(
                        line.hasSuffix(" ") || line.hasSuffix("\t"),
                        "\(path) has a line with trailing whitespace"
                    )
                }
            }
        }
    }

    func testTheFilesUseTabsForTheIndentation() {
        for style in ConfigScaffolder.Style.allCases {
            for (path, contents) in files(for: style) where path.hasSuffix(".lua") {
                for line in contents.split(separator: "\n") where line.hasPrefix(" ") {
                    XCTFail("\(path) indents with spaces")
                }
            }
        }
    }

    // MARK: - The loader of the config

    func testTheInitFileLoadsTheFilesThatExist() throws {
        let files = files(for: .sbarLua)
        let initFile = try XCTUnwrap(files["init.lua"])

        let requires = initFile.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("require(\""), line.hasSuffix("\")") else { return nil }
            return String(line.dropFirst("require(\"".count).dropLast("\")".count))
        }

        // Every file of the config is loaded, and every load points at a
        // file that exists.
        let expected = Set(
            files.keys
                .filter { $0.hasSuffix(".lua") && $0 != "init.lua" }
                .map { $0.replacingOccurrences(of: ".lua", with: "").replacingOccurrences(of: "/", with: ".") }
        )
        XCTAssertEqual(Set(requires), expected)
        for module in requires {
            let path = module.replacingOccurrences(of: ".", with: "/") + ".lua"
            XCTAssertNotNil(files[path], "init.lua loads \(module), but there is no \(path)")
        }
    }

    func testTheInitFileStartsAndEndsTheConfig() throws {
        let initFile = try XCTUnwrap(files(for: .sbarLua)["init.lua"])

        XCTAssertTrue(initFile.contains("sbar = require(\"sketchybar\")"))
        XCTAssertTrue(initFile.contains("sbar.begin_config()"))
        XCTAssertTrue(initFile.contains("sbar.hotload(true)"))
        XCTAssertTrue(initFile.contains("sbar.end_config()"))
        XCTAssertTrue(initFile.contains("sbar.event_loop()"))

        // The config is started before it is ended.
        let begin = try XCTUnwrap(initFile.range(of: "sbar.begin_config()"))
        let end = try XCTUnwrap(initFile.range(of: "sbar.end_config()"))
        XCTAssertLessThan(begin.lowerBound, end.lowerBound)
    }

    func testTheLauncherRunsTheEntrypointOfTheConfig() throws {
        let launcher = try XCTUnwrap(files(for: .sbarLua)["sketchybarrc"])

        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(launcher.contains("init.lua"))
    }

    // MARK: - The items of the config

    func testEveryItemFileIsReadByTheSbarLuaParser() throws {
        for (path, contents) in files(for: .sbarLua) where path.hasPrefix("items/") {
            let items = SbarLuaItemParser.items(in: contents)
            let item = try XCTUnwrap(items.first, "\(path) does not parse")
            XCTAssertEqual(items.count, 1, "\(path) declares more than one item")
            XCTAssertEqual(
                item.alias,
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                "\(path) has the wrong alias"
            )
            XCTAssertNotNil(value("position", in: item), "\(path) has no position")
            XCTAssertNotNil(value("script", in: item), "\(path) has no script")
        }
    }

    func testTheClockStandsOnTheLeftAndTheOtherItemsOnTheRight() throws {
        let files = files(for: .sbarLua)

        let clock = try XCTUnwrap(SbarLuaItemParser.items(in: files["items/left/clock.lua"] ?? "").first)
        XCTAssertEqual(value("position", in: clock), "\"left\"")
        XCTAssertEqual(value("update_freq", in: clock), "60")

        let battery = try XCTUnwrap(SbarLuaItemParser.items(in: files["items/right/battery.lua"] ?? "").first)
        XCTAssertEqual(value("position", in: battery), "\"right\"")
        XCTAssertEqual(value("update_freq", in: battery), "10")
    }

    func testTheScriptOfAnItemFillsTheLabelOfThatItem() throws {
        for (path, contents) in files(for: .sbarLua) where path.hasPrefix("items/") {
            let item = try XCTUnwrap(SbarLuaItemParser.items(in: contents).first, "\(path) does not parse")
            let script = try XCTUnwrap(value("script", in: item), "\(path) has no script")
            XCTAssertTrue(
                script.contains("sketchybar --set \(item.alias) label="),
                "\(path) does not fill the label of its own item"
            )
        }
    }

    // MARK: - The options of the config

    func testEveryOptionOfTheConfigIsKnownToSketchyBar() throws {
        for (path, contents) in files(for: .sbarLua) {
            let parsed = LuaTableParser.parse(source: contents)
            for call in parsed.calls where call.path == ["sbar", "add"] || call.path == ["sbar", "bar"] {
                let table = try XCTUnwrap(
                    call.arguments.compactMap { argument -> LuaTable? in
                        if case .table(let table) = argument { return table }
                        return nil
                    }.first,
                    "\(path) has no table of options"
                )
                for entry in table.entries {
                    let keyPath = entry.path.joined(separator: ".")
                    XCTAssertNotNil(
                        SketchyBarOptionDocs.doc(for: keyPath),
                        "\(path) uses the unknown option \(keyPath)"
                    )
                }
            }
        }
    }

    func testTheBarHoldsTheLookOfTheBar() throws {
        let contents = try XCTUnwrap(files(for: .sbarLua)["bar.lua"])
        let parsed = LuaTableParser.parse(source: contents)
        let call = try XCTUnwrap(parsed.calls.first { $0.path == ["sbar", "bar"] })
        let table = try XCTUnwrap(call.arguments.compactMap { argument -> LuaTable? in
            if case .table(let table) = argument { return table }
            return nil
        }.first)

        XCTAssertEqual(
            table.entries.map(\.path),
            [["position"], ["margin"], ["height"], ["color"], ["topmost"], ["font_smoothing"]]
        )
        XCTAssertEqual(value("position", in: table), "\"top\"")
        XCTAssertEqual(value("margin", in: table), "4")
        XCTAssertEqual(value("height", in: table), "28")
        XCTAssertEqual(value("topmost", in: table), "true")
        XCTAssertEqual(value("font_smoothing", in: table), "true")
    }

    // MARK: - The theme and the icons

    func testTheThemeHoldsTheColoursOfTheConfig() throws {
        let contents = try XCTUnwrap(files(for: .sbarLua)["themes/colors.lua"])
        let parsed = LuaTableParser.parse(source: contents)
        let table = try XCTUnwrap(parsed.tables.first)

        XCTAssertEqual(value("bg", in: table), "0xff1e1e2e")
        XCTAssertEqual(value("fg", in: table), "0xffcdd6f4")
        XCTAssertEqual(value("accent", in: table), "0xff89b4fa")
    }

    func testTheIconsHoldTheSymbolsOfTheItems() throws {
        let contents = try XCTUnwrap(files(for: .sbarLua)["helpers/icons.lua"])
        let parsed = LuaTableParser.parse(source: contents)
        let table = try XCTUnwrap(parsed.tables.first)

        XCTAssertEqual(value("clock", in: table), "\"sf.clock\"")
        XCTAssertEqual(value("battery", in: table), "\"sf.battery.100\"")
    }

    // MARK: - The shell config

    func testTheShellConfigSetsTheBarAndTheItems() throws {
        let contents = try XCTUnwrap(files(for: .shell)["sketchybarrc"])

        XCTAssertTrue(contents.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(contents.contains("sketchybar --bar position=top"))
        XCTAssertTrue(contents.contains("sketchybar --add item clock left"))
        XCTAssertTrue(contents.contains("sketchybar --add item battery right"))
        XCTAssertTrue(contents.contains("sketchybar --set clock label="))
        XCTAssertTrue(contents.contains("sketchybar --set clock update_freq=60"))
    }

    // MARK: - The tools of the system

    func testTheShellConfigIsValidShell() throws {
        guard let sh = toolPath("sh") else {
            throw XCTSkip("The system has no sh.")
        }
        let root = try makeRoot()
        let url = root.appendingPathComponent("sketchybarrc")
        try XCTUnwrap(files(for: .shell)["sketchybarrc"]).write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try run(sh, arguments: ["-n", url.path]), 0, "The shell config is not valid shell.")
    }

    func testEveryLuaFileIsValidLua() throws {
        guard let luac = toolPath("luac") else {
            throw XCTSkip("The system has no luac.")
        }
        let root = try makeRoot()
        let files = files(for: .sbarLua)

        for (path, contents) in files where path.hasSuffix(".lua") {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)

            XCTAssertEqual(try run(luac, arguments: ["-p", url.path]), 0, "\(path) is not valid Lua.")
        }
    }

    // MARK: - Helpers

    private func files(for style: ConfigScaffolder.Style) -> [String: String] {
        scaffolder.fileContents(
            style: style,
            starterItems: scaffolder.starterItems(for: style)
        )
    }

    private func value(_ keyPath: String, in item: StructuredItem) -> String? {
        item.values.first { $0.keyPath == keyPath }?.rawValue
    }

    private func value(_ keyPath: String, in table: LuaTable) -> String? {
        table.entries.first { $0.path.joined(separator: ".") == keyPath }?.text
    }

    /// The path of a tool, when the system has it.
    private func toolPath(_ name: String) -> String? {
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for searchPath in searchPaths {
            let url = URL(fileURLWithPath: String(searchPath)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
        }
        return nil
    }

    /// Runs a tool and waits for it.
    private func run(_ tool: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioConfigScaffolderTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
