import AppKit
import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import SketchyBarStudio

/// The tests of the render of the preview core.
///
/// The core lays a bar out and paints it into a bitmap, with no window
/// server and no permission (`docs/bar-renderer/phase-4-layout-and-render.md`).
/// The tests check the size of the image, the rectangles of the items, the
/// points against the pixels and the visible parts of the bar. The last
/// test compares the render with a golden image.
final class BarRenderGoldenTests: XCTestCase {
    // MARK: - The item of a rendered bar

    /// One item of a rendered bar.
    private struct Item {
        let alias: String
        let type: String
        let properties: [String]
    }

    /// The image of a rendered bar and the rectangles of its items.
    private struct RenderedBar {
        let image: CGImage
        let rects: [String: CGRect]
    }

    // MARK: - The smoke test

    /// The smoke test of the stage: a preview is created, one item is added
    /// with a fixed width, the bar is rendered and a non-null image of the
    /// expected pixel size comes back.
    func testRenderReturnsAnImageOfTheExpectedPixelSize() throws {
        let rendered = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: ["width=120", "label=hello"])
        ])

        XCTAssertEqual(rendered.image.width, 960, "the width of the image is the width of the display times 2")
        XCTAssertEqual(rendered.image.height, 50, "the height of the image is the height of the bar times 2")
    }

    /// A bar with three items has the size of the display and the size of
    /// the bar, in the fixed backing scale of 2.0.
    func testTheImageIsAsWideAsTheDisplayAndAsTallAsTheBar() throws {
        let rendered = try renderBar(items: Self.threeItems)

        XCTAssertEqual(rendered.image.width, 960)
        XCTAssertEqual(rendered.image.height, 50)
    }

    /// The height of the bar comes from the config, not from the display.
    func testTheHeightOfTheBarComesFromTheConfig() throws {
        let rendered = try renderBar(bar: ["height=30"], items: Self.threeItems)

        XCTAssertEqual(rendered.image.height, 60, "the height of the bar is 30 points, so the image is 60 pixels high")
    }

    // MARK: - The rectangles of the items

    /// Every item has a rectangle in points, and the rectangle is half the
    /// size of the pixels of the item in the image.
    func testEveryItemHasARectInPoints() throws {
        let rendered = try renderBar(items: Self.threeItems)

        XCTAssertEqual(rendered.rects.count, 3)
        for item in Self.threeItems {
            let rect = try XCTUnwrap(rendered.rects[item.alias], "the item '\(item.alias)' must have a rectangle")
            XCTAssertGreaterThan(rect.width, 0, "the rectangle of '\(item.alias)' must not be empty")
            XCTAssertGreaterThan(rect.height, 0, "the rectangle of '\(item.alias)' must not be empty")
            XCTAssertLessThanOrEqual(rect.width * 2, Double(rendered.image.width))
            XCTAssertLessThanOrEqual(rect.height * 2, Double(rendered.image.height))
        }
    }

    /// The rectangle of an item is the place of its pixels in the image: the
    /// background of the item covers the width of the rectangle, twice.
    func testTheRectangleOfAnItemIsHalfTheSizeOfItsPixels() throws {
        let rendered = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: [
                "width=120",
                "background.color=0xffff0000"
            ])
        ])

        let rect = try XCTUnwrap(rendered.rects["apple"])
        let red = try XCTUnwrap(redPixels(of: rendered.image), "the background of the item must be visible")

        XCTAssertEqual(red.originX, rect.origin.x * 2, accuracy: 1)
        XCTAssertEqual(red.width, rect.width * 2, accuracy: 1)
    }

    /// The image is not blank: at least one pixel differs from the
    /// background of the bar.
    func testTheImageIsNotBlank() throws {
        let rendered = try renderBar(items: Self.threeItems)

        let bytes = pixels(of: rendered.image)
        XCTAssertTrue(bytes.contains { $0 != 0 }, "the image must hold more than the empty background")
    }

    // MARK: - The virtual display

    /// The width of the virtual display is the width of the target display,
    /// in points, and an explicit width changes it.
    func testTheDefaultWidthIsTheWidthOfTheTargetDisplay() throws {
        let screen = try XCTUnwrap(NSScreen.main, "the test needs a screen")

        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }
        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle), SketchyBarPreviewC.Code.ok)
        let image = try XCTUnwrap(SketchyBarPreviewC.render(handle))

        XCTAssertEqual(image.width, Int(ceil(screen.frame.width * 2)),
                       "the default width of the display is the width of the screen in points")
    }

    /// An explicit width is the override of the default.
    func testTheWidthOverrideChangesTheImage() throws {
        let narrow = try renderBar(widthPoints: 480, items: Self.threeItems)
        let wide = try renderBar(widthPoints: 800, items: Self.threeItems)

        XCTAssertEqual(narrow.image.width, 960)
        XCTAssertEqual(wide.image.width, 1600)
    }

    /// The bitmap is at the fixed scale of 2.0, whatever the scale of the
    /// display is, and whatever the width of the override is.
    func testTheBitmapScaleIsAlwaysTwo() throws {
        for scale in [1.0, 2.0, 3.0] {
            let rendered = try renderBar(widthPoints: 480, scale: scale, items: Self.threeItems)

            XCTAssertEqual(rendered.image.width, 960, "the scale of the display does not change the bitmap")
            XCTAssertEqual(rendered.image.height, 50, "the scale of the display does not change the bitmap")
        }
    }

    /// The menu bar moves the bar down, so the rectangles of the items move
    /// with it.
    func testTheMenuBarMovesTheBarDown() throws {
        let without = try renderBar(items: Self.threeItems)
        let with = try renderBar(menuBarPoints: 24, items: Self.threeItems)

        for item in Self.threeItems {
            let top = try XCTUnwrap(without.rects[item.alias])
            let lower = try XCTUnwrap(with.rects[item.alias])

            XCTAssertEqual(top.origin.y, 0, accuracy: 1)
            XCTAssertEqual(lower.origin.y, 24, accuracy: 1, "the menu bar moves the bar down")
        }
    }

    // MARK: - The visible parts of the bar

    /// The bar background, the background of an item, its border, its text
    /// and its image are all visible in the image.
    func testEveryPartOfTheBarIsVisible() throws {
        let bar = try renderBar(bar: ["color=0xff101010"], items: [
            Item(alias: "apple", type: "item", properties: ["label=hello"])
        ])
        let plainBar = try renderBar(bar: ["color=0x00000000"], items: [
            Item(alias: "apple", type: "item", properties: ["label=hello"])
        ])
        XCTAssertNotEqual(pixels(of: bar.image), pixels(of: plainBar.image), "the background of the bar must be visible")

        let withBackground = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: ["label=hello", "background.color=0xff3355ff"])
        ])
        let withoutBackground = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: ["label=hello"])
        ])
        XCTAssertNotEqual(pixels(of: withBackground.image), pixels(of: withoutBackground.image),
                          "the background of an item must be visible")

        let withBorder = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: [
                "label=hello",
                "background.color=0xff3355ff",
                "background.border_color=0xffffffff",
                "background.border_width=2"
            ])
        ])
        XCTAssertNotEqual(pixels(of: withBorder.image), pixels(of: withBackground.image),
                          "the border of an item must be visible")

        let withText = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: ["label=hello"])
        ])
        let withoutText = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: [])
        ])
        XCTAssertNotEqual(pixels(of: withText.image), pixels(of: withoutText.image),
                          "the text of an item must be visible")

        // The image of a background is drawn with the background, so the
        // background has to be enabled (src/background.c:209-210).
        let withImage = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: [
                "label=hello",
                "background.color=0xff000000",
                "background.image=sf.clock"
            ])
        ])
        let withoutImage = try renderBar(items: [
            Item(alias: "apple", type: "item", properties: [
                "label=hello",
                "background.color=0xff000000"
            ])
        ])
        XCTAssertNotEqual(pixels(of: withImage.image), pixels(of: withoutImage.image),
                          "the image of an item must be visible")
    }

    // MARK: - The placeholders

    /// An alias item shows a captured menu bar item and a space item shows
    /// a captured space. The preview has no window server, so they keep a
    /// box of 16 points.
    func testTheItemsOfTheWindowServerKeepAPlaceholder() throws {
        let rendered = try renderBar(items: [
            Item(alias: "extra", type: "alias", properties: []),
            Item(alias: "space", type: "space", properties: [])
        ])

        for alias in ["extra", "space"] {
            let rect = try XCTUnwrap(rendered.rects[alias], "the item '\(alias)' must have a rectangle")
            XCTAssertEqual(rect.width, 16, accuracy: 1, "the placeholder of '\(alias)' is 16 points wide")
            XCTAssertGreaterThan(rect.height, 0)
        }
    }

    /// A width of the config wins over the placeholder.
    func testAWidthOfTheConfigWinsOverThePlaceholder() throws {
        let rendered = try renderBar(items: [
            Item(alias: "extra", type: "alias", properties: ["width=80"])
        ])

        let rect = try XCTUnwrap(rendered.rects["extra"])
        XCTAssertEqual(rect.width, 80, accuracy: 1)
    }

    // MARK: - The window server

    /// The preview never reaches the window server: the core of the preview
    /// has no undefined symbol of the window server and no symbol of the
    /// Mach machinery.
    func testThePreviewDoesNotReachTheWindowServer() throws {
        let object = try XCTUnwrap(Self.previewObjectURL(),
                                    "the object of the preview core must be next to the test bundle")
        let symbols = try XCTUnwrap(Self.undefinedSymbols(of: object),
                                    "the symbols of the preview core must be readable")

        for forbidden in ["mach_send_message", "bootstrap_register", "_SLS"] {
            XCTAssertFalse(symbols.contains { $0.contains(forbidden) },
                           "the preview core must not reach \(forbidden): \(symbols.joined(separator: ", "))")
        }
    }

    // MARK: - The golden image

    /// The render of a fixed config has to match the golden image.
    ///
    /// The plan skips the test when the Nerd Font is not installed
    /// (`docs/bar-renderer/testing.md`): it is the default family of the
    /// renderer. The config of the golden image sets its own font, so the
    /// file is comparable on every machine of the same macOS version, and
    /// the environment variable runs the test on a machine that has no Nerd
    /// Font.
    func testTheGoldenImage() throws {
        let mode = GoldenMode.current
        if mode == .compare {
            try XCTSkipUnless(Self.hackNerdFontIsInstalled,
                              "Hack Nerd Font is not installed, so the pixels of the text are not comparable")
        }

        let rendered = try renderBar(widthPoints: 480, heightPoints: 25,
                                     bar: ["color=0xff101010"],
                                     items: Self.goldenItems)
        XCTAssertEqual(rendered.image.width, 960)
        XCTAssertEqual(rendered.image.height, 50)

        let file = Self.goldenFileURL
        if mode == .write {
            let data = try pngData(of: rendered.image)
            try data.write(to: file)
            return
        }

        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path),
                          "the golden image of this macOS version has not been generated yet")
        let golden = try XCTUnwrap(CGImageSourceCreateWithData(try Data(contentsOf: file) as CFData, nil))
        let goldenImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(golden, 0, nil))

        XCTAssertEqual(pixels(of: rendered.image), pixels(of: goldenImage),
                       "the render must match the golden image")
    }

    // MARK: - The helpers

    /// Three items with a label, one on each side of the bar.
    private static let threeItems = [
        Item(alias: "left", type: "item", properties: ["position=left", "label=left"]),
        Item(alias: "center", type: "item", properties: ["position=center", "label=center"]),
        Item(alias: "right", type: "item", properties: ["position=right", "label=right"])
    ]

    /// The fixed config of the golden image.
    ///
    /// The font is set, so the image does not depend on the font of the
    /// machine, and the background of the bar is opaque, so the file holds
    /// the pixels of the render without a loss.
    private static let goldenItems = [
        Item(alias: "left", type: "item", properties: [
            "position=left",
            "label=SBS",
            "label.font=Menlo:Bold:14",
            "background.color=0xff3355ff",
            "background.border_color=0xffffffff",
            "background.border_width=1",
            "background.corner_radius=4",
            "padding_left=4",
            "padding_right=4"
        ]),
        Item(alias: "center", type: "item", properties: [
            "position=center",
            "label=preview",
            "label.font=Menlo:Bold:14",
            "label.color=0xffffcc00"
        ]),
        Item(alias: "right", type: "item", properties: [
            "position=right",
            "label=26",
            "label.font=Menlo:Bold:14",
            "label.color=0xff00ff00"
        ])
    ]

    /// Renders a bar and returns the image with the rectangles of the items.
    private func renderBar(widthPoints: Double = 480,
                            heightPoints: Double = 25,
                            scale: Double = 2.0,
                            menuBarPoints: Double = 0,
                            bar: [String] = [],
                            items: [Item]) throws -> RenderedBar {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create(), "the core must hand out a preview handle")
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle,
                                                      widthPoints: widthPoints,
                                                      heightPoints: heightPoints,
                                                      scale: scale),
                       SketchyBarPreviewC.Code.ok)
        if menuBarPoints > 0 {
            XCTAssertEqual(SketchyBarPreviewC.setMenuBar(handle, heightPoints: menuBarPoints),
                           SketchyBarPreviewC.Code.ok)
        }
        for property in bar {
            let (key, value) = try XCTUnwrap(Self.split(property))
            XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: key, value: value),
                           SketchyBarPreviewC.Code.ok, property)
        }
        for item in items {
            XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: item.alias, type: item.type),
                           SketchyBarPreviewC.Code.ok, item.alias)
            for property in item.properties {
                let (key, value) = try XCTUnwrap(Self.split(property))
                XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: item.alias, key: key, value: value),
                               SketchyBarPreviewC.Code.ok, property)
            }
        }

        let image = try XCTUnwrap(SketchyBarPreviewC.render(handle), "the render must hand back an image")
        var rects: [String: CGRect] = [:]
        for item in items {
            rects[item.alias] = SketchyBarPreviewC.itemRect(handle, alias: item.alias)
        }
        return RenderedBar(image: image, rects: rects)
    }

    /// Splits a "key=value" property. The value keeps everything after the
    /// first "=".
    private static func split(_ property: String) -> (String, String)? {
        guard let separator = property.firstIndex(of: "=") else { return nil }
        return (String(property[property.startIndex..<separator]),
                String(property[property.index(after: separator)...]))
    }

    /// The pixels of an image in one format, so two images can be compared.
    ///
    /// The colour space is sRGB and the alpha is premultiplied, so the
    /// pixels of the render and the pixels of the golden file, which is a
    /// PNG, can be compared.
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

    /// The place of the red pixels of an image.
    private struct RedPixels {
        let originX: Double
        let width: Double
    }

    /// The place of the red pixels of an image, or nil when the image holds
    /// no red pixel.
    private func redPixels(of image: CGImage) -> RedPixels? {
        let bytes = pixels(of: image)
        let width = image.width
        var minX = width
        var maxX = -1
        for y in 0..<image.height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard bytes[offset] > 200, bytes[offset + 1] < 60, bytes[offset + 2] < 60 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return nil }
        return RedPixels(originX: Double(minX), width: Double(maxX - minX + 1))
    }

    /// The image as a PNG holds it.
    private func pngData(of image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        _ = try XCTUnwrap(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: - The golden file

    /// The mode of the golden test.
    private enum GoldenMode {
        case compare
        case write
        case force

        /// The mode the environment asks for.
        ///
        /// "write" writes the golden file, "force" runs the test on a
        /// machine that has no Nerd Font.
        static var current: GoldenMode {
            switch ProcessInfo.processInfo.environment["SKETCHYBAR_STUDIO_GOLDEN"] {
            case "write": return .write
            case "force": return .force
            default: return .compare
            }
        }
    }

    /// The name of the golden file. The macOS version is part of the name,
    /// because the text of a glyph is not the same on every macOS release.
    private static var goldenFileName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "bar-render-golden-macos\(version.majorVersion).\(version.minorVersion).\(version.patchVersion).png"
    }

    /// The golden file of this macOS version.
    private static var goldenFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(goldenFileName)
    }

    /// True when the Nerd Font is installed. It is the default family of
    /// the renderer (`src/font.c:152-158`).
    private static var hackNerdFontIsInstalled: Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Hack Nerd Font"
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
        return (CTFontCopyFamilyName(font) as String) == "Hack Nerd Font"
    }

    // MARK: - The object of the preview core

    /// The object file of the preview core. It is built next to the test
    /// bundle.
    private static func previewObjectURL() -> URL? {
        let bundle = Bundle(for: BarRenderGoldenTests.self)
        let directory = bundle.bundleURL.deletingLastPathComponent()
        let object = directory.appendingPathComponent("CSketchyBar.o")
        return FileManager.default.fileExists(atPath: object.path) ? object : nil
    }

    /// The symbols the preview core needs and does not define itself.
    private static func undefinedSymbols(of object: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-u", object.path]
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
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
