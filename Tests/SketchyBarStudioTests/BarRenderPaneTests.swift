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
    ///
    /// The item on the left has a red background, so a test can tell a
    /// painted item from an empty bar.
    private let luaSource = """
    sbar.add("item", "left", {
        position = "left",
        label = "L",
        background = { color = "0xffff0000" },
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

    /// At 1:1 the bar is drawn at its true point size: the pixels of the
    /// image divided by the backing scale of 2.0. So a bar of a display of
    /// 480 points is drawn 480 points wide, and its 960 image pixels land
    /// on 960 device pixels of a display with the scale of 2.0.
    func testTheOneToOneBarIsDrawnAtItsTruePointSize() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 960, height: 50),
                                     paneSize: CGSize(width: 480, height: 120),
                                     isOneToOne: true)

        XCTAssertEqual(layout.drawnSize.width, 480, "the bar is as wide as the display it is rendered for")
        XCTAssertEqual(layout.drawnSize.height, 25, "the bar is as tall as the bar it is rendered for")
    }

    /// At 1:1 the bar of a wide display is wider than the pane, so the
    /// pane has to scroll sideways.
    func testTheOneToOnePaneScrollsSideways() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 3420, height: 50),
                                     paneSize: CGSize(width: 600, height: 120),
                                     isOneToOne: true)

        XCTAssertEqual(layout.drawnSize.width, 1710, "the bar keeps its true point size at 1:1")
        XCTAssertEqual(layout.drawnSize.height, 25)
        XCTAssertGreaterThan(layout.drawnSize.width, layout.paneSize.width,
                             "the bar has to be wider than the pane, so the pane scrolls sideways")
    }

    /// The fitted view does not scroll: the bar fits the pane.
    func testTheFittedPaneDoesNotScroll() {
        let layout = BarRenderLayout(imageSize: CGSize(width: 960, height: 50),
                                     paneSize: CGSize(width: 480, height: 200),
                                     isOneToOne: false)

        XCTAssertLessThanOrEqual(layout.drawnSize.width, layout.paneSize.width)
    }

    /// The pane always scrolls sideways, so the whole bar is reachable at
    /// 1:1. The scroll is part of the view, so the axis is a constant of
    /// the view.
    func testThePaneAlwaysScrollsSideways() {
        XCTAssertEqual(BarRenderView.scrollAxis, .horizontal)
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

    /// The image is not blank: an item of the config is really painted.
    ///
    /// The background of the bar is a translucent black, so a test that
    /// only looks for a byte that is not zero passes on an empty bar. The
    /// red background of the item on the left is the proof.
    func testTheRenderPaintsAnItemOfTheConfig() async throws {
        let result = try await render(widthPoints: 480)

        XCTAssertTrue(hasRedPixels(result.image),
                      "the red background of the item must be in the pixels of the image")
    }

    /// The rectangles of the items are in the points of the display, and
    /// the bar relative ones are in the points of the bar.
    func testTheItemRectsAreInTheDisplayAndTheBarRelativeOnesInTheBar() async throws {
        let result = try await render(widthPoints: 480)
        let frame = try XCTUnwrap(result.barFrame, "the bar must have a frame")

        for alias in ["left", "right"] {
            let absolute = try XCTUnwrap(result.itemRects[alias])
            let relative = try XCTUnwrap(result.barRelativeRects[alias])

            XCTAssertGreaterThanOrEqual(absolute.origin.x, frame.origin.x,
                                        "the rectangle of the item is in the points of the display")
            XCTAssertLessThanOrEqual(absolute.maxX, frame.maxX,
                                     "the rectangle of the item is in the points of the display")
            XCTAssertEqual(absolute.origin.x - frame.origin.x, relative.origin.x, accuracy: 0.001,
                           "the bar relative rectangle starts at the left of the bar")
            XCTAssertEqual(absolute.origin.y - frame.origin.y, relative.origin.y, accuracy: 0.001,
                           "the bar relative rectangle starts at the top of the bar")
        }
    }

    // MARK: - The display of the render

    /// A width that is not a number, or a width that is too big, is
    /// refused before the core is touched.
    ///
    /// The core holds one preview at a time, so the handle of the test
    /// proves that the render never called into the core: a call would
    /// have found the preview of the test and failed with another error.
    func testAnImpossibleWidthIsRefusedWithoutTouchingTheCore() async throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        for width in [Double.infinity, -Double.infinity, Double.nan, 0, -1, 1e8] {
            do {
                _ = try await BarRendererService.shared.render(request(widthPoints: width))
                XCTFail("the width \(width) must be refused")
            } catch let error as BarRenderError {
                guard case .renderFailed(let reason) = error else {
                    return XCTFail("the width \(width) must fail with a message, not with \(error)")
                }
                XCTAssertTrue(reason.contains("width"),
                              "the message has to say that the width is the problem: \(reason)")
            }
        }
    }

    /// A height that is not a number is refused as well, because the
    /// height of the display is the size of the bitmap of a bar on the
    /// side of the display.
    func testAnImpossibleHeightIsRefused() async throws {
        do {
            _ = try await BarRendererService.shared.render(request(widthPoints: 480, heightPoints: .infinity))
            XCTFail("the height must be refused")
        } catch let error as BarRenderError {
            guard case .renderFailed(let reason) = error else {
                return XCTFail("the height must fail with a message, not with \(error)")
            }
            XCTAssertTrue(reason.contains("height"))
        }
    }

    // MARK: - The warnings of the render

    /// A source without a readable file says so, so the pane is not an
    /// empty strip without a word about it.
    func testASourceWithoutAReadableFileSaysSo() async throws {
        let result = try await BarRendererService.shared.render(
            BarRenderRequest(files: [BarRenderFile(url: URL(fileURLWithPath: "/tmp/sketchybar-studio-no-such-file.lua"),
                                                  kind: .lua,
                                                  contents: nil)],
                             displayWidthPoints: 480,
                             displayHeightPoints: 25)
        )

        XCTAssertTrue(result.warnings.contains { $0.contains("No readable config file") },
                      "the pane has to say that there was nothing to render")
    }

    /// The warnings of the request reach the pane, so the pane can say
    /// what the render cannot know itself.
    func testTheWarningsOfTheRequestReachTheResult() async throws {
        let result = try await BarRendererService.shared.render(
            BarRenderRequest(files: [],
                             displayWidthPoints: 480,
                             displayHeightPoints: 25,
                             warnings: ["This config is not open."])
        )

        XCTAssertTrue(result.warnings.contains("This config is not open."))
    }

    /// A config that is not open is rendered in file order, and the pane
    /// says so.
    @MainActor
    func testAConfigThatIsNotOpenSaysItIsRenderedInFileOrder() throws {
        let root = try makeConfigRoot()
        try write("sbar.add(\"item\", \"clock\", { position = \"right\", label = \"10:00\" })\n",
                  to: root.appendingPathComponent("items/clock.lua"))
        let store = SketchyBarStore(configRoot: root)

        let otherRoot = try makeConfigRoot()
        try write("sbar.add(\"item\", \"other\", { position = \"left\", label = \"x\" })\n",
                  to: otherRoot.appendingPathComponent("items/other.lua"))
        store.addConfig(name: "Other", path: otherRoot.path, selectAfterAdd: false)
        let other = try XCTUnwrap(store.configs.first { $0.id != store.selectedConfig?.id })

        let warnings = store.barRenderWarnings(for: .config(other.id))

        XCTAssertTrue(warnings.contains { $0.contains("file order") },
                      "the pane has to say that the order of the items is the order of the files")
    }

    // MARK: - The state of the pane

    /// A render that is older than the newest one never reaches the pane.
    @MainActor
    func testAnOlderRenderNeverReachesThePane() async throws {
        let state = BarRenderState()

        // The first render is a small one, the second one is a big one, so
        // the second one is still running when the first one is done.
        let first = Task { @MainActor in
            await state.render(request(widthPoints: 480))
        }
        var waited = 0
        while !state.isRendering, waited < 1000 {
            await Task.yield()
            waited += 1
        }
        XCTAssertTrue(state.isRendering, "the first render must be running")

        let second = Task { @MainActor in
            await state.render(request(widthPoints: 800, source: Self.manyItems(400)))
        }

        await first.value
        XCTAssertNil(state.image, "the older render must not publish an image")
        XCTAssertTrue(state.isRendering, "the newest render is still running")

        await second.value
        XCTAssertEqual(state.pixelSize.width, 1600, "the newest render is the one that is shown")
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
        try await BarRendererService.shared.render(request(widthPoints: widthPoints))
    }

    /// The request of a render of the fixture config.
    private func request(widthPoints: Double,
                         heightPoints: Double = 25,
                         source: String? = nil) -> BarRenderRequest {
        BarRenderRequest(
            files: [BarRenderFile(url: URL(fileURLWithPath: "/tmp/items/clock.lua"),
                                  kind: .lua,
                                  contents: source ?? luaSource)],
            displayWidthPoints: widthPoints,
            displayHeightPoints: heightPoints
        )
    }

    /// A config with many items, so a render of it takes a while.
    private static func manyItems(_ count: Int) -> String {
        (0..<count).map { index in
            "sbar.add(\"item\", \"item\(index)\", { position = \"left\", label = \"\(index)\" })"
        }.joined(separator: "\n")
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

    /// True when the image holds a red pixel, so a painted item can be
    /// told from an empty bar.
    private func hasRedPixels(_ image: CGImage) -> Bool {
        let bytes = pixels(of: image)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[offset] > 200, bytes[offset + 1] < 60, bytes[offset + 2] < 60 { return true }
        }
        return false
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
