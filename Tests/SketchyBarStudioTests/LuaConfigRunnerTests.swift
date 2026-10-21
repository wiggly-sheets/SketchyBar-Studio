import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the Lua config resolver.
///
/// The resolver runs the Lua of a config in a sandbox and reads what the
/// config declares, so the preview shows the values of the config and not
/// the defaults of SketchyBar. The tests need no SketchyBar and no
/// daemon: the resolver runs in the process of the test.
final class LuaConfigRunnerTests: XCTestCase {
    // MARK: - The fixtures

    /// The root of a fixture of the tests.
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The plan of a fixture, resolved with Lua.
    private func plan(of name: String) -> BarRenderPlan {
        PreviewConfigBridge.plan(forLuaConfigRoot: fixture(name))
    }

    /// The value of a property of an item of a plan.
    private func value(_ plan: BarRenderPlan, _ alias: String, _ key: String) -> String? {
        plan.items
            .first { $0.alias == alias }?
            .properties
            .first { $0.key == key }?
            .value
    }

    /// The aliases of the items of a plan, in the order of the plan.
    private func aliases(_ plan: BarRenderPlan) -> [String] {
        plan.items.map(\.alias)
    }

    // MARK: - The values of a config

    /// A module that returns a literal table, a local function that returns
    /// a table, a computed value, a concatenation and a chain of requires
    /// all reach the plan with their real values.
    func testTheValuesOfTheConfigAreResolved() throws {
        let plan = self.plan(of: "lua-resolve")

        // The literal table of the module.
        XCTAssertEqual(value(plan, "clock", "icon.font.family"), "Liga SFMono Nerd Font")
        // The computed value: the size of the module plus one.
        XCTAssertEqual(value(plan, "clock", "icon.font.size"), "12")
        // The concatenation.
        XCTAssertEqual(value(plan, "clock", "label.string"), "10:00 Liga SFMono Nerd Font")
        // The colour of the module, in the spelling of SbarLua.
        XCTAssertEqual(value(plan, "clock", "background.color"), "0xff112233")
        // The boolean of the item.
        XCTAssertEqual(value(plan, "clock", "drawing"), "true")
        // The position of the item.
        XCTAssertEqual(value(plan, "clock", "position"), "right")

        // The local function that returns a table reaches the default item.
        let defaults = Dictionary(uniqueKeysWithValues: plan.defaults.map { ($0.key, $0.value) })
        XCTAssertEqual(defaults["icon.font.family"], "Liga SFMono Nerd Font")
        XCTAssertEqual(defaults["icon.font.size"], "11")
        XCTAssertEqual(defaults["icon.font.style"], "Regular")
        XCTAssertEqual(defaults["label.font.style"], "Bold")
        XCTAssertEqual(defaults["updates"], "when_shown")

        // The chain of the requires: the module of the extra item is the
        // module of the settings.
        XCTAssertEqual(value(plan, "extra", "label.string"), "extra")
        XCTAssertEqual(value(plan, "extra", "background.color"), "0xff112233")
    }

    /// The parser cannot read the values of the fixture, so the plan of
    /// the parser and the plan of the resolver are not the same.
    func testTheParserCannotReadTheValuesOfTheConfig() throws {
        let parsed = PreviewConfigBridge.plan(forConfigRoot: fixture("lua-resolve"))
        let resolved = self.plan(of: "lua-resolve")

        XCTAssertTrue(parsed.warnings.contains { $0.contains("is built by an expression") })
        XCTAssertNil(value(parsed, "clock", "icon.font.family"),
                      "the parser cannot read the family of the font")
        XCTAssertEqual(value(resolved, "clock", "icon.font.family"), "Liga SFMono Nerd Font")
        XCTAssertEqual(value(resolved, "clock", "background.color"), "0xff112233")
    }

    // MARK: - The sandbox

    /// A module that runs a shell command does not run it, and the rest of
    /// the config still loads.
    func testTheShellOfAModuleIsNotRun() throws {
        let marker = try markerPath()
        defer { try? FileManager.default.removeItem(at: marker) }
        setenv("SKETCHYBAR_STUDIO_MARKER", marker.path, 1)
        defer { unsetenv("SKETCHYBAR_STUDIO_MARKER") }

        let plan = self.plan(of: "lua-unsafe")

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the sandbox must not run the shell of the config")
        XCTAssertEqual(aliases(plan), ["safe"], "the rest of the config must still load")
        XCTAssertTrue(plan.warnings.contains { $0.contains("could not be loaded") },
                      "the module that failed must be a warning")
    }

    /// The sandbox removes the globals a config must not use, empties the
    /// path of the C modules and lets only the modules of the config load.
    func testTheSandboxRemovesTheDangerousGlobals() throws {
        let plan = self.plan(of: "lua-sandbox")

        XCTAssertEqual(value(plan, "sandbox", "no_os_execute"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_os_exit"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_io_popen"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_dofile"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_loadfile"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_load"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_package_loadlib"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_debug"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_io_tmpfile"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_os_tmpname"), "true")
        XCTAssertEqual(value(plan, "sandbox", "empty_cpath"), "")
        XCTAssertEqual(value(plan, "sandbox", "no_c_searcher"), "true")

        let path = try XCTUnwrap(value(plan, "sandbox", "path"))
        XCTAssertTrue(path.hasPrefix(fixture("lua-sandbox").path),
                      "the path of the modules must be the root of the config")
        XCTAssertTrue(path.contains("/?.lua;"))
    }

    /// The debug library is out of reach, so the config cannot switch off
    /// the deadline of the run.
    ///
    /// The library is in the loaded modules of the interpreter as well, so
    /// `require("debug")` must not find it either.
    func testTheDebugLibraryIsOutOfReach() throws {
        let plan = self.plan(of: "lua-sandbox")

        XCTAssertEqual(value(plan, "sandbox", "no_debug_module"), "true")
        XCTAssertEqual(value(plan, "sandbox", "no_debug_reachable"), "true")
    }

    /// `io.open` only reads: a file in a write mode is not created.
    func testIoOpenOnlyReads() throws {
        let marker = try markerPath()
        defer { try? FileManager.default.removeItem(at: marker) }
        setenv("SKETCHYBAR_STUDIO_MARKER", marker.path, 1)
        defer { unsetenv("SKETCHYBAR_STUDIO_MARKER") }

        _ = self.plan(of: "lua-sandbox")

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the sandbox must not write a file")
    }

    /// `io.output` with a file name would create the file, so it is
    /// refused.
    func testIoOutputDoesNotCreateAFile() throws {
        let marker = try markerPath()
        defer { try? FileManager.default.removeItem(at: marker) }
        setenv("SKETCHYBAR_STUDIO_MARKER", marker.path, 1)
        defer { unsetenv("SKETCHYBAR_STUDIO_MARKER") }

        let plan = self.plan(of: "lua-sandbox")

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the sandbox must not create a file with io.output")
        XCTAssertEqual(value(plan, "sandbox", "no_io_output"), "true")
    }

    /// A file outside of the config root is read, and the run warns about
    /// it. The file is not refused: the daemon reads it as well.
    func testAFileOutsideTheConfigRootIsReported() throws {
        let outside = try markerPath()
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        setenv("SKETCHYBAR_STUDIO_OUTSIDE", outside.path, 1)
        defer { unsetenv("SKETCHYBAR_STUDIO_OUTSIDE") }

        let plan = self.plan(of: "lua-sandbox")

        XCTAssertTrue(plan.warnings.contains { $0.contains(outside.path) },
                      "the file outside of the config root must be reported")
    }

    // MARK: - The failures

    /// An endless loop aborts with the deadline of the sandbox instead of
    /// hanging the app.
    ///
    /// The fixture tries to switch the deadline off with the debug library
    /// before the loop, and the deadline still holds.
    func testAnEndlessLoopAbortsWithTheDeadline() throws {
        let root = fixture("lua-infinite")
        let entrypoint = try XCTUnwrap(LuaConfigRunner.entrypoint(in: root))

        let finished = expectation(description: "the run aborts")
        var failure: Error?
        DispatchQueue.global().async {
            do {
                _ = try LuaConfigRunner.resolve(configRoot: root, entrypoint: entrypoint)
            } catch {
                failure = error
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 30)

        guard let failure else {
            return XCTFail("the endless loop must abort with the deadline of the sandbox")
        }
        guard case LuaConfigRunner.Failure.timedOut = failure else {
            return XCTFail("the endless loop must abort with the deadline of the sandbox, got \(failure)")
        }
    }
    /// A config that fails falls back to the parser, and the warning says
    /// so.
    func testAConfigThatFallsBackToTheParser() throws {
        let root = fixture("lua-throws")
        let plan = PreviewConfigBridge.plan(forLuaConfigRoot: root)

        XCTAssertTrue(plan.warnings.contains { $0.contains("not resolved with Lua") },
                      "the fallback must be a warning")
        XCTAssertEqual(plan.items.count, 0, "the parser reads no item of the broken config")
    }

    /// A config without a Lua entrypoint falls back to the parser.
    func testAConfigWithoutALuaEntrypointFallsBackToTheParser() throws {
        let root = fixture("lua-shell")
        let plan = PreviewConfigBridge.plan(forLuaConfigRoot: root)

        XCTAssertTrue(plan.warnings.contains { $0.contains("no Lua entrypoint") },
                      "the fallback must be a warning")
        XCTAssertEqual(plan.items.count, 1, "the parser reads the shell config")
    }

    // MARK: - The names and the order of the items

    /// A name that an expression builds is resolved.
    func testAComputedAliasIsResolved() throws {
        let plan = self.plan(of: "lua-computed-alias")

        XCTAssertEqual(aliases(plan), ["space.1", "space.2", "space.3"])
        XCTAssertEqual(value(plan, "space.2", "label.string"), "s2")
        XCTAssertFalse(plan.warnings.contains { $0.contains("alias of an item is built by an expression") },
                       "the name of the item is resolved, so it is no warning")
    }

    /// An item without a name gets the generated name of SbarLua, and the
    /// counter follows the order of the load.
    ///
    /// The counter of the daemon starts at zero, so the first name is
    /// `item_0`.
    func testAnItemWithoutANameGetsAGeneratedName() throws {
        let plan = self.plan(of: "lua-aliasless")

        XCTAssertEqual(aliases(plan), ["item_0", "item_1"])
        XCTAssertEqual(value(plan, "item_0", "label.string"), "first")
        XCTAssertEqual(value(plan, "item_1", "label.string"), "second")
    }

    /// The counter of the generated names is the counter of the process,
    /// so the modules of the config share it.
    func testTheCounterOfTheNamesIsSharedByTheModules() throws {
        let plan = self.plan(of: "lua-shared-counter")

        XCTAssertEqual(aliases(plan), ["item_0", "item_1"])
        XCTAssertEqual(value(plan, "item_0", "label.string"), "first")
        XCTAssertEqual(value(plan, "item_1", "label.string"), "second")
    }

    /// A type the daemon does not support creates no item, and the run
    /// says so.
    func testAnUnsupportedTypeCreatesNoItem() throws {
        let plan = self.plan(of: "lua-unsupported-type")

        XCTAssertEqual(aliases(plan), ["kept"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("'ring'") },
                      "the type the daemon does not support must be reported")
    }

    /// The text of a number is the text the daemon receives, which is the
    /// text Lua writes for it.
    func testTheTextOfANumberIsTheTextOfLua() throws {
        let plan = self.plan(of: "lua-numbers")

        XCTAssertEqual(value(plan, "numbers", "integer"), "12")
        XCTAssertEqual(value(plan, "numbers", "float"), "12.0")
        // Lua writes the shortest text that reads back to the same number,
        // so a third needs 17 digits.
        XCTAssertEqual(value(plan, "numbers", "third"), "0.33333333333333331")
    }

    /// The properties of an item come from the last argument of the call,
    /// and a call that ends with something else has no properties.
    func testThePropertiesComeFromTheLastArgument() throws {
        let plan = self.plan(of: "lua-last-argument")

        XCTAssertEqual(aliases(plan), ["last"])
        XCTAssertEqual(plan.items.first?.properties.count, 0,
                       "the last argument is not a table, so there are no properties")
    }

    /// The order of the items is the order of the load, not the order of
    /// the files.
    func testTheOrderOfTheItemsIsTheOrderOfTheLoad() throws {
        let plan = self.plan(of: "lua-load-order")

        XCTAssertEqual(aliases(plan), ["first", "second"])

        let parsed = PreviewConfigBridge.plan(forConfigRoot: fixture("lua-load-order"))
        XCTAssertEqual(aliases(parsed), ["second", "first"],
                       "the parser reads the files in the order of their names")
    }

    // MARK: - The real config of the user

    /// The real config of the user, read only.
    ///
    /// The test is skipped when the config is not on this machine, so the
    /// suite does not depend on it. It prints what the resolver reads, so
    /// the numbers of the report can be seen.
    ///
    /// The run of the config is bounded by the deadline of the sandbox, and
    /// the test gives up after 30 seconds all the same, so a broken
    /// deadline cannot hang the suite.
    func testTheRealConfigOfTheUserIsResolved() throws {
        let root = URL(fileURLWithPath: "/Users/Zeb/dotfiles/sketchybar")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("the real config of the user is not on this machine")
        }

        let finished = expectation(description: "the config of the user is resolved")
        var parsed = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])
        var resolved = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])
        var run: LuaConfigRunner.ResolvedConfig?
        DispatchQueue.global().async {
            parsed = PreviewConfigBridge.plan(forConfigRoot: root)
            resolved = PreviewConfigBridge.plan(forLuaConfigRoot: root)
            let entrypoint = LuaConfigRunner.entrypoint(in: root)
            if let entrypoint {
                run = try? LuaConfigRunner.resolve(configRoot: root, entrypoint: entrypoint)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        let expressions = parsed.warnings.filter { $0.contains("is built by an expression") }.count

        let parsedAliases = Set(parsed.items.map(\.alias))
        let parsedKeys = Set(parsed.items.flatMap { item in
            item.properties.map { "\(item.alias).\($0.key)" }
        })
        let resolvedKeys = Set(resolved.items.flatMap { item in
            item.properties.map { "\(item.alias).\($0.key)" }
        })
        let newlyResolved = resolvedKeys.subtracting(parsedKeys)
        let ofNamedItems = newlyResolved.filter { parsedAliases.contains(String($0.prefix(while: { $0 != "." }))) }

        print("lua-resolve: the parser leaves \(expressions) values unresolved")
        print("lua-resolve: the resolver reads \(ofNamedItems.count) of them, and \(newlyResolved.count - ofNamedItems.count) more that belong to the items the parser cannot name")
        print("lua-resolve: the parser has \(parsed.items.count) items, the resolver has \(resolved.items.count)")

        // The items of a type the preview cannot show.
        let items = try XCTUnwrap(run?.items)
        var byType: [String: Int] = [:]
        var dropped: [String: Int] = [:]
        for item in items {
            byType[item.type, default: 0] += 1
            if item.type != "item" {
                dropped[item.type, default: 0] += item.properties.count
            }
        }
        print("lua-resolve: the items of the config by type: \(byType.sorted { $0.key < $1.key })")
        print("lua-resolve: the values of the items the preview cannot show: \(dropped.sorted { $0.key < $1.key })")
        print("lua-resolve: the warnings of the run: \(run?.warnings ?? [])")

        XCTAssertFalse(resolved.items.isEmpty, "the resolver must read the items of the config")
        XCTAssertGreaterThan(newlyResolved.count, 0, "the resolver must read the values the parser cannot")
    }

    // MARK: - The helpers

    /// A path in the temporary directory, for the marker of the sandbox.
    private func markerPath() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sketchybar-studio-sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("marker-\(UUID().uuidString)")
    }
}
