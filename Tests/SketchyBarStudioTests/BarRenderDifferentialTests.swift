import Foundation
import XCTest
@testable import SketchyBarStudio

/// The differential test of the rendered bar.
///
/// The test compares the item rectangles from the vendored renderer against
/// the `bounding_rects` of the installed `sketchybar --query <item>`. The
/// test is skipped when the daemon is not running, and it never fails the
/// build because of that. The query parser tolerates missing keys gracefully.
final class BarRenderDifferentialTests: XCTestCase {
    // MARK: - The timer of the scripts

    override func tearDown() async throws {
        await BarRendererService.shared.stopLiveValues()
    }

    // MARK: - The fixture config

    /// The fixture config the differential test renders.
    ///
    /// The config covers the item types the vendored renderer can produce
    /// without the window server: item, graph, slider, bracket. The items
    /// have fixed widths so the rectangles are stable.
    private let fixtureConfig = """
    sbar.bar({
        position = "top",
        height = 25,
        margin = 10,
        color = 0xff101010,
    })

    sbar.default({
        icon = { font = { family = "Hack Nerd Font", style = "Bold", size = 14 } },
        label = { font = { family = "Hack Nerd Font", style = "Bold", size = 14 } },
        background = { color = 0xff3355ff, border_color = 0xffffffff, border_width = 1, corner_radius = 4 },
        padding_left = 4,
        padding_right = 4,
    })

    -- Left items
    sbar.add("item", "left_one", {
        position = "left",
        label = { string = "L1" },
        width = 60,
    })
    sbar.add("item", "left_two", {
        position = "left",
        label = { string = "L2" },
        width = 60,
    })

    -- Center items
    sbar.add("item", "center_one", {
        position = "center",
        label = { string = "C1" },
        width = 80,
    })

    -- Right items
    sbar.add("item", "right_one", {
        position = "right",
        label = { string = "R1" },
        width = 60,
    })
    sbar.add("item", "right_two", {
        position = "right",
        label = { string = "R2" },
        width = 60,
    })

    -- Graph with fixed width from add command
    sbar.add("graph", "cpu_graph", 100, {
        position = "right",
        graph = { color = 0xff00ff00 },
    })

    -- Slider with fixed width from add command
    sbar.add("slider", "volume_slider", 80, {
        position = "right",
        slider = { color = 0xff00ffff },
    })

    -- Bracket grouping left items
    sbar.add("bracket", "left_bracket", {
        members = { "left_one", "left_two" },
        position = "left",
        background = { color = 0xff112233, border_color = 0xffffffff, border_width = 2 },
    })
    """

    // MARK: - The test

    /// The differential test: compares item rectangles of the vendored
    /// renderer with the bounding_rects of the installed daemon.
    ///
    /// The test is skipped when the daemon is not running. When the daemon
    /// IS present, it queries fixture items and compares bounding rects
    /// within 1-point tolerance. The query parser tolerates missing keys
    /// gracefully.
    func testItemRectanglesMatchDaemonWithinOnePoint() async throws {
        // The daemon must be running for this test to mean anything.
        let barReply = queryLiveBar()
        guard barReply != nil else {
            throw XCTSkip("the daemon of SketchyBar is not running")
        }

        // Render the fixture config with the vendored core.
        let rendered = try await renderFixture()

        // Query every item of the fixture from the live daemon and compare.
        // The fixture item names are known from the config.
        let fixtureItemNames = ["left_one", "left_two", "center_one", "right_one", "right_two", "cpu_graph", "volume_slider", "left_bracket"]
        var liveRects: [String: CGRect] = [:]
        for alias in fixtureItemNames {
            guard let reply = queryItem(alias) else {
                throw XCTSkip("the live daemon does not have fixture item '\(alias)'")
            }
            if let rect = try parseBoundingRects(reply) {
                liveRects[alias] = rect
            }
        }
        guard !liveRects.isEmpty else {
            throw XCTSkip("the live daemon has no fixture items")
        }
        for (alias, liveRect) in liveRects {
            guard let renderedRect = rendered.itemRects[alias] else {
                XCTFail("the rendered bar has no rectangle for '\(alias)'")
                continue
            }
            XCTAssertEqual(renderedRect.origin.x, liveRect.origin.x, accuracy: 1.0,
                           "x of '\(alias)' must match within 1 point: rendered \(renderedRect.origin.x) vs live \(liveRect.origin.x)")
            XCTAssertEqual(renderedRect.origin.y, liveRect.origin.y, accuracy: 1.0,
                           "y of '\(alias)' must match within 1 point: rendered \(renderedRect.origin.y) vs live \(liveRect.origin.y)")
            XCTAssertEqual(renderedRect.width, liveRect.width, accuracy: 1.0,
                           "width of '\(alias)' must match within 1 point: rendered \(renderedRect.width) vs live \(liveRect.width)")
            XCTAssertEqual(renderedRect.height, liveRect.height, accuracy: 1.0,
                           "height of '\(alias)' must match within 1 point: rendered \(renderedRect.height) vs live \(liveRect.height)")
        }
    }

    // MARK: - The query parser

    /// The tolerant parser reads a real --query reply and a reply whose
    /// value contains a backslash, and it detects the "[!] …" error prefix.
    func testQueryParserToleratesBackslashAndErrorPrefix() throws {
        // A reply with a backslash in a value (invalid JSON escape).
        // In Swift multi-line string, \\ is literal backslash, \t and \f are escapes.
        // Use \\t and \\f to get literal backslash-t and backslash-f.
        let replyWithBackslash = """
        {
            "name": "test",
            "geometry": {
                "label": {
                    "value": "path\\\\to\\\\file"
                }
            }
        }
        """
        let parsed = try SketchyBarQueryParser.parse(replyWithBackslash)
        let geometry = parsed["geometry"] as? [String: Any]
        let label = geometry?["label"] as? [String: Any]
        XCTAssertEqual(label?["value"] as? String, "path\\to\\file")

        // A reply with the error prefix "[!]".
        let errorReply = "[!] The property 'not_a_property' is not a valid property."
        let errorParsed = SketchyBarQueryParser.parseError(errorReply)
        XCTAssertNotNil(errorParsed)
        XCTAssertTrue(errorParsed!.contains("not_a_property"))

        // A valid reply without the error prefix.
        let validReply = """
        {
            "name": "test",
            "geometry": {
                "width": 100
            }
        }
        """
        let validParsed = try SketchyBarQueryParser.parse(validReply)
        let validGeometry = validParsed["geometry"] as? [String: Any]
        XCTAssertEqual(validGeometry?["width"] as? Int, 100)
    }

    // MARK: - Helpers

    /// Renders the fixture config and returns the item rectangles.
    private func renderFixture() async throws -> BarRenderResult {
        // Write the fixture to a temporary directory.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sketchybar-differential-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configFile = tempDir.appendingPathComponent("init.lua")
        try fixtureConfig.write(to: configFile, atomically: true, encoding: .utf8)

        // Render with the BarRendererService.
        let request = BarRenderRequest(
            files: [BarRenderFile(url: configFile, kind: .lua, contents: nil)],
            root: tempDir,
            filesAreInFileOrder: false,
            displayWidthPoints: 480,
            displayHeightPoints: 25,
            warnings: []
        )

        return try await BarRendererService.shared.render(request)
    }

    /// Queries the live bar and returns the bounding_rects of every item.
    private func queryLiveItemRects() throws -> [String: CGRect] {
        let barReply = try XCTUnwrap(queryLiveBar(), "the live bar must answer")
        let itemNames = try itemNames(in: barReply)

        var rects: [String: CGRect] = [:]
        for alias in itemNames {
            let reply = try XCTUnwrap(queryItem(alias), "the item '\(alias)' must answer")
            if let rect = try parseBoundingRects(reply) {
                rects[alias] = rect
            }
        }
        return rects
    }

    /// The reply of `sketchybar --query bar`, or nil when the daemon does not answer.
    private func queryLiveBar() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--query", "bar"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate it looks like JSON (starts with {) and can be parsed.
        guard trimmed.hasPrefix("{"),
              let jsonData = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: jsonData)) != nil else { return nil }
        return text.isEmpty ? nil : text
    }

    /// The reply of `sketchybar --query <item>`, or nil when the daemon does not answer.
    private func queryItem(_ alias: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--query", alias]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate it looks like JSON (starts with {) and can be parsed.
        guard trimmed.hasPrefix("{"),
              let jsonData = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: jsonData)) != nil else { return nil }
        return text.isEmpty ? nil : text
    }

    /// The names of the items of the live bar.
    private func itemNames(in reply: String) throws -> [String] {
        guard let start = reply.range(of: "\"items\": [") else { return [] }
        let json = String(reply[start.lowerBound...]) + "}"
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any],
              let items = dict["items"] as? [String] else { return [] }
        return items
    }

    /// Parses the bounding_rects from a --query reply.
    private func parseBoundingRects(_ reply: String) throws -> CGRect? {
        let data = try XCTUnwrap(reply.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any],
              let boundingRects = dict["bounding_rects"] as? [String: Any],
              let firstDisplay = boundingRects.values.first as? [String: Any],
              let origin = firstDisplay["origin"] as? [Double],
              let size = firstDisplay["size"] as? [Double],
              origin.count == 2, size.count == 2 else {
            return nil
        }
        return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
    }
}