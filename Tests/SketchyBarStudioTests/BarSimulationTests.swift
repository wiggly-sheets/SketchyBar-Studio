import AppKit
import CoreGraphics
import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the interactive simulation of the rendered bar.
///
/// The pane draws the image of the bar and puts the rendered items on top of
/// it, so a click, a drag and a resize of the simulation edit the file of the
/// item. The tests check the geometry that maps the bar onto the drawn image,
/// the drop that picks a position and a place, and the path from an item of
/// the render back to the file of the config.
final class BarSimulationTests: XCTestCase {
    override func tearDown() async throws {
        await BarRendererService.shared.stopLiveValues()
    }

    // MARK: - The geometry

    /// A rectangle of the bar is drawn at the factor of the pane, and a
    /// point of the drawn image maps back to the point of the bar.
    func testTheDrawnRectangleFollowsTheImageAndThePane() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 2880, height: 50),
                                     paneSize: CGSize(width: 600, height: 120),
                                     isOneToOne: false)
        let factor = SimulationGeometry.pointsPerBarPoint(layout: layout)

        // The bar is 1440 points wide, so the 600-point pane draws one point
        // of the bar at 600 / 1440 points.
        XCTAssertEqual(factor, 600.0 / 1440.0, accuracy: 0.0001)

        let drawn = SimulationGeometry.drawnRect(forBarRect: CGRect(x: 100, y: 5, width: 80, height: 25),
                                                 layout: layout)
        XCTAssertEqual(drawn.origin.x, 100 * factor, accuracy: 0.0001)
        XCTAssertEqual(drawn.origin.y, 5 * factor, accuracy: 0.0001)
        XCTAssertEqual(drawn.width, 80 * factor, accuracy: 0.0001)
        XCTAssertEqual(drawn.height, 25 * factor, accuracy: 0.0001)

        let point = SimulationGeometry.barPoints(forDrawn: CGPoint(x: drawn.origin.x, y: drawn.origin.y),
                                                 layout: layout)
        XCTAssertEqual(point.x, 100, accuracy: 0.0001)
        XCTAssertEqual(point.y, 5, accuracy: 0.0001)
    }

    /// At 1:1 the image is drawn at the point size of the bar, so one drawn
    /// point is one point of the bar.
    func testTheOneToOneLayerMapsOneDrawnPointToOneBarPoint() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 2880, height: 50),
                                     paneSize: CGSize(width: 600, height: 120),
                                     isOneToOne: true)

        XCTAssertEqual(SimulationGeometry.pointsPerBarPoint(layout: layout), 1, accuracy: 0.0001)
    }

    /// A bar without an image has no factor, so a point never divides by
    /// zero.
    func testTheGeometryRefusesAZeroSizedImage() {
        let layout = BarRenderLayout(imageSize: .zero,
                                     paneSize: CGSize(width: 600, height: 120),
                                     isOneToOne: false)

        XCTAssertEqual(SimulationGeometry.pointsPerBarPoint(layout: layout), 0)
        XCTAssertEqual(SimulationGeometry.barPoints(forDrawn: CGPoint(x: 10, y: 10), layout: layout), .zero)
    }

    // MARK: - The drop

    /// The third of the bar a drop is over is the position of the item.
    func testTheDropPicksThePositionOfTheThird() {
        let width: CGFloat = 900

        XCTAssertEqual(SimulationDrop.position(forX: 0, barWidth: width), .left)
        XCTAssertEqual(SimulationDrop.position(forX: 299, barWidth: width), .left)
        XCTAssertEqual(SimulationDrop.position(forX: 300, barWidth: width), .center)
        XCTAssertEqual(SimulationDrop.position(forX: 600, barWidth: width), .center)
        XCTAssertEqual(SimulationDrop.position(forX: 601, barWidth: width), .right)
        XCTAssertEqual(SimulationDrop.position(forX: 900, barWidth: width), .right)
    }

    /// The first item of the position that is to the right of the drop is
    /// the place the item goes before.
    func testTheDropTargetsTheNextItemOfThePosition() {
        let rects: [String: CGRect] = [
            "leftA": CGRect(x: 10, y: 0, width: 50, height: 25),
            "leftB": CGRect(x: 100, y: 0, width: 50, height: 25),
            "rightA": CGRect(x: 800, y: 0, width: 50, height: 25)
        ]
        let width: CGFloat = 900

        XCTAssertEqual(SimulationDrop.targetAlias(forX: 60, position: .left, barWidth: width, rects: rects),
                       "leftB")
        XCTAssertEqual(SimulationDrop.targetAlias(forX: 500, position: .center, barWidth: width, rects: rects),
                       nil, "an empty position has no target")
        XCTAssertEqual(SimulationDrop.targetAlias(forX: 700, position: .right, barWidth: width, rects: rects),
                       "rightA")
    }

    /// A drop to the right of every item of a position targets the last
    /// item and goes after it.
    func testTheDropAfterTheLastItemTargetsTheLastItem() {
        let rects: [String: CGRect] = [
            "leftA": CGRect(x: 10, y: 0, width: 50, height: 25),
            "leftB": CGRect(x: 100, y: 0, width: 50, height: 25)
        ]

        let target = SimulationDrop.target(forX: 295, position: .left, barWidth: 900, rects: rects)

        XCTAssertEqual(target?.alias, "leftB")
        XCTAssertEqual(target?.after, true)
    }

    // MARK: - The origins of the render

    /// The render maps an item back to the file that declared it, and the
    /// store turns the relative path into the file it edits.
    @MainActor
    func testTheRenderKnowsTheFileOfEveryItem() async throws {
        let root = try makeConfigRoot()
        let itemURL = root.appendingPathComponent("items/clock.lua")
        try write("sbar.add(\"item\", \"clock\", { position = \"right\", label = \"10:00\" })\n",
                  to: itemURL)

        let result = try await BarRendererService.shared.render(
            BarRenderRequest(files: [BarRenderFile(url: itemURL, kind: .lua, contents: nil)],
                             root: root,
                             displayWidthPoints: 480,
                             displayHeightPoints: 25)
        )

        let origin = try XCTUnwrap(result.itemOrigins["clock"])
        XCTAssertEqual(origin.file, "items/clock.lua", "the origin is the path relative to the config root")

        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.configFile(for: origin))
        XCTAssertEqual(file.url.standardizedFileURL, itemURL.standardizedFileURL)
        XCTAssertFalse(result.hasScripts, "the item has no script, so the simulation does not poll for values")
    }

    /// A shell config has no Lua origin, so the parser path builds the
    /// origins and the simulation still maps an item to its file.
    @MainActor
    func testTheParserPathBuildsTheOriginsOfAShellConfig() async throws {
        let root = try makeConfigRoot()
        let itemURL = root.appendingPathComponent("items/clock.sh")
        try write("sketchybar --add item clock right --set clock label=10:00\n", to: itemURL)

        let result = try await BarRendererService.shared.render(
            BarRenderRequest(files: [BarRenderFile(url: itemURL, kind: .shell, contents: nil)],
                             root: root,
                             displayWidthPoints: 480,
                             displayHeightPoints: 25)
        )

        XCTAssertEqual(result.itemOrigins["clock"]?.file, "items/clock.sh")
        XCTAssertEqual(result.itemOrigins["clock"]?.index, 0)
    }

    /// A shell config that adds and sets an item in different files keeps
    /// the values of the set.
    @MainActor
    func testAShellSetInAnotherFileReachesTheRender() throws {
        let root = try makeConfigRoot()
        let addURL = root.appendingPathComponent("items/clock.sh")
        let setURL = root.appendingPathComponent("items/clock.label.sh")
        try write("sketchybar --add item clock right\n", to: addURL)
        try write("sketchybar --set clock label=10:00\n", to: setURL)

        let request = BarRenderRequest(
            files: [BarRenderFile(url: addURL, kind: .shell, contents: nil),
                    BarRenderFile(url: setURL, kind: .shell, contents: nil)],
            root: root,
            displayWidthPoints: 480,
            displayHeightPoints: 25
        )
        let plan = BarRendererService.plan(for: request)
        let clock = try XCTUnwrap(plan.items.first { $0.alias == "clock" })

        XCTAssertTrue(clock.properties.contains { $0.key == "label" && $0.value == "10:00" })
        XCTAssertEqual(clock.origin?.file, "items/clock.sh")
    }

    // MARK: - The order of the loader

    /// The render puts the items of the files in the staged loader order,
    /// so a drag is visible before the loader file is saved.
    func testThePlanFollowsTheStagedFileOrder() {
        let items = [
            BarRenderItemModel(alias: "a0",
                               properties: [],
                               origin: BarRenderOrigin(file: "items/a.lua", index: 0)),
            BarRenderItemModel(alias: "b0",
                               properties: [],
                               origin: BarRenderOrigin(file: "items/b.lua", index: 0)),
            BarRenderItemModel(alias: "a1",
                               properties: [],
                               origin: BarRenderOrigin(file: "items/a.lua", index: 1))
        ]
        let plan = BarRenderPlan(defaults: [], bar: [], items: items, warnings: [])

        let reordered = plan.reordered(byFileOrder: ["items/b.lua", "items/a.lua"])

        XCTAssertEqual(reordered.items.map(\.alias), ["b0", "a0", "a1"])
    }

    /// An item whose file the loader order does not name keeps its place.
    func testTheReorderKeepsAnItemWithoutAnOriginInItsPlace() {
        let items = [
            BarRenderItemModel(alias: "unknown", properties: []),
            BarRenderItemModel(alias: "known",
                               properties: [],
                               origin: BarRenderOrigin(file: "items/known.lua", index: 0))
        ]
        let plan = BarRenderPlan(defaults: [], bar: [], items: items, warnings: [])

        XCTAssertEqual(plan.reordered(byFileOrder: ["items/known.lua"]).items.map(\.alias),
                       ["unknown", "known"])
    }

    /// A file the loader does not name keeps its slot between two ranked
    /// files, so a transitive item is not pushed to the end.
    func testTheReorderKeepsTheSlotOfAnUnrankedItem() {
        let items = [
            BarRenderItemModel(alias: "a", properties: [], origin: BarRenderOrigin(file: "items/a.lua", index: 0)),
            BarRenderItemModel(alias: "root", properties: []),
            BarRenderItemModel(alias: "b", properties: [], origin: BarRenderOrigin(file: "items/b.lua", index: 0))
        ]
        let plan = BarRenderPlan(defaults: [], bar: [], items: items, warnings: [])

        XCTAssertEqual(plan.reordered(byFileOrder: ["items/b.lua", "items/a.lua"]).items.map(\.alias),
                       ["b", "root", "a"])
    }

    // MARK: - The bar values

    /// The inspector of the bar reads `bar.height`, not the height of an
    /// item of the config.
    @MainActor
    func testTheBarInspectorReadsTheBarValueAndNotTheItemValue() throws {
        let root = try makeConfigRoot()
        try write("sbar.bar({ height = 30 })\n", to: root.appendingPathComponent("bar.lua"))
        try write("sbar.add(\"item\", \"clock\", { position = \"right\", height = 20 })\n",
                  to: root.appendingPathComponent("items/clock.lua"))

        let store = SketchyBarStore(configRoot: root)

        XCTAssertEqual(store.barValue("height")?.draftValue, "30")
        XCTAssertEqual(store.barValue("position"), nil, "the bar does not set a position here")
    }

    // MARK: - The pane

    /// The preview mode is the simulation now, and the title says so.
    func testThePreviewModeIsTheSimulation() {
        XCTAssertEqual(DetailPaneMode.preview.title, "Simulation")
    }

    // MARK: - The helpers

    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioBarSimulationTests")
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
