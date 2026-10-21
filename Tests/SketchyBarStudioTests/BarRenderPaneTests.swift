import AppKit
import CoreGraphics
import Foundation
@testable import SketchyBarStudio
import XCTest

/// The tests of the preview pane of the rendered bar.
///
/// The pane draws the image of the bar with one uniform factor, so the
/// proportions of the real menu bar survive, and the render follows the
/// width of the display and not the shape of the pane.
final class BarRenderPaneTests: XCTestCase {
    // MARK: - The fixtures

    /// A config with two items, one on each side of the bar.
    private let luaSource = """
    sbar.add("item", "left", {
        position = "left",
        label = "L",
    })
    sbar.add("item", "right", {
        position = "right",
        label = "R",
    })
    """

    // MARK: - The geometry of the pane

    /// The fitted image keeps the aspect ratio of the rendered image.
    func testTheFittedImageKeepsTheAspectRatioOfTheRender() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 960, height: 50),
                                     paneSize: CGSize(width: 480, height: 200),
                                     isOneToOne: false)

        let rendered = Double(layout.imageSize.width) / Double(layout.imageSize.height)
        let drawn = Double(layout.drawnSize.width) / Double(layout.drawnSize.height)

        XCTAssertEqual(drawn, rendered, accuracy: rendered * 0.001,
                       "the fitted image must have the aspect ratio of the rendered image")
    }

    /// The scaled-to-fit view applies the same factor to both axes.
    func testTheFittedImageUsesOneFactorForBothAxes() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 960, height: 50),
                                     paneSize: CGSize(width: 480, height: 200),
                                     isOneToOne: false)

        XCTAssertEqual(layout.drawnSize.width, 480, "the fitted image is as wide as the pane")
        XCTAssertEqual(layout.drawnSize.width / layout.imageSize.width,
                       layout.drawnSize.height / layout.imageSize.height,
                       accuracy: 0.0001,
                       "the same factor goes to both axes")
    }

    /// At 1:1 the image is drawn at one image pixel per point, so the bar
    /// is wider than the pane and the pane scrolls sideways.
    func testTheOneToOnePaneScrollsSideways() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 3420, height: 50),
                                     paneSize: CGSize(width: 600, height: 120),
                                     isOneToOne: true)

        XCTAssertEqual(layout.drawnSize.width, 3420, "the image keeps its pixel size at 1:1")
        XCTAssertEqual(layout.drawnSize.height, 50)
        XCTAssertTrue(layout.scrollsHorizontally, "the pane has to scroll sideways at 1:1")
    }

    /// The fitted view does not scroll: the bar fits the pane.
    func testTheFittedPaneDoesNotScroll() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 960, height: 50),
                                     paneSize: CGSize(width: 480, height: 200),
                                     isOneToOne: false)

        XCTAssertFalse(layout.scrollsHorizontally)
    }

    // MARK: - The render

    /// The image is the width of the display in points times 2 and the
    /// height of the bar in points times 2. The render follows the
    /// display, never the shape of the pane.
    func testTheRenderFollowsTheDisplayAndNotThePane() async throws {
        let result = try await render(widthPoints: 480)

        XCTAssertEqual(result.image.width, 960, "the width of the image is the width of the display times 2")
        XCTAssertEqual(result.image.height, 50, "the height of the image is the height of the bar times 2")
    }

    /// The width override changes the proportions of the bar.
    func testTheWidthOverrideChangesTheProportionsOfTheBar() async throws {
        let narrow = try await render(widthPoints: 480)
        let wide = try await render(widthPoints: 800)

        let narrowRatio = Double(narrow.image.width) / Double(narrow.image.height)
        let wideRatio = Double(wide.image.width) / Double(wide.image.height)

        XCTAssertNotEqual(narrowRatio, wideRatio, accuracy: 0.0001,
                          "a different width must produce a different aspect ratio")
        XCTAssertEqual(wide.image.width, 1600)
    }

    /// The bar is never re-laid out to the shape of the pane: the render
    /// holds every item of the config.
    func testTheRenderHoldsEveryItemOfTheConfig() async throws {
        let result = try await render(widthPoints: 480)

        XCTAssertEqual(result.itemRects.count, 2, "both items of the config must be in the render")
        for alias in ["left", "right"] {
            let rect = try XCTUnwrap(result.itemRects[alias], "the item '\(alias)' must have a rectangle")
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    /// The image is not blank: the bar is really painted.
    func testTheRenderIsNotBlank() async throws {
        let result = try await render(widthPoints: 480)

        XCTAssertTrue(pixels(of: result.image).contains { $0 != 0 },
                      "the image must hold more than the empty background")
    }

    // MARK: - The files of the render

    /// The files of the config the app has open carry the drafts, and a
    /// config that is not open is read from disk.
    @MainActor
    func testTheDraftsReachTheRenderAndAnotherConfigIsReadFromDisk() throws {
        let root = try makeConfigRoot()
        let itemURL = root.appendingPathComponent("items/clock.lua")
        try write("sbar.add(\"item\", \"clock\", { position = \"right\", label = \"10:00\" })\n", to: itemURL)
        let store = SketchyBarStore(configRoot: root)
        let file = try XCTUnwrap(store.files.first { $0.url == itemURL })
        store.update(valueID: try XCTUnwrap(file.values.first).id, draftValue: "11:00")

        let otherRoot = try makeConfigRoot()
        try write("sbar.add(\"item\", \"other\", { position = \"left\", label = \"x\" })\n",
                  to: otherRoot.appendingPathComponent("items/other.lua"))
        store.addConfig(name: "Other", path: otherRoot.path, selectAfterAdd: false)
        let other = try XCTUnwrap(store.configs.first { $0.id != store.selectedConfig?.id })

        let open = store.barRenderFiles(for: .config(try XCTUnwrap(store.selectedConfig?.id)))
        XCTAssertEqual(open.count, 1)
        XCTAssertTrue(try XCTUnwrap(open.first?.contents).contains("11:00"),
                      "the draft of the app must reach the render")

        let otherFiles = store.barRenderFiles(for: .config(other.id))
        XCTAssertEqual(otherFiles.count, 1)
        XCTAssertNil(otherFiles.first?.contents, "a config that is not open is read from disk")
    }

    /// The preview of a config that is not the open one shows a bar.
    @MainActor
    func testThePreviewOfAConfigThatIsNotOpenShowsABar() async throws {
        let root = try makeConfigRoot()
        try write("sbar.add(\"item\", \"clock\", { position = \"right\", label = \"10:00\" })\n",
                  to: root.appendingPathComponent("items/clock.lua"))
        let store = SketchyBarStore(configRoot: root)

        let otherRoot = try makeConfigRoot()
        try write("sbar.add(\"item\", \"other\", { position = \"left\", label = \"x\" })\n",
                  to: otherRoot.appendingPathComponent("items/other.lua"))
        store.addConfig(name: "Other", path: otherRoot.path, selectAfterAdd: false)
        let other = try XCTUnwrap(store.configs.first { $0.id != store.selectedConfig?.id })

        let result = try await BarRendererService.shared.render(
            BarRenderRequest(files: store.barRenderFiles(for: .config(other.id)),
                             displayWidthPoints: 480,
                             displayHeightPoints: 25)
        )

        XCTAssertEqual(result.image.width, 960, "the image is as wide as the virtual display")
        XCTAssertTrue(pixels(of: result.image).contains { $0 != 0 }, "the image must not be blank")
        XCTAssertEqual(result.itemRects.count, 1)
    }

    // MARK: - The helpers

    /// Renders the fixture config for a display of the given width.
    private func render(widthPoints: Double) async throws -> BarRenderResult {
        try await BarRendererService.shared.render(
            BarRenderRequest(
                files: [BarRenderFile(url: URL(fileURLWithPath: "/tmp/items/clock.lua"),
                                      kind: .lua,
                                      contents: luaSource)],
                displayWidthPoints: widthPoints,
                displayHeightPoints: 25
            )
        )
    }

    /// The pixels of an image, so a blank image can be told from a painted
    /// one.
    private func pixels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// A config folder in a temporary directory.
    private func makeConfigRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchyBarStudioBarRenderTests")
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
