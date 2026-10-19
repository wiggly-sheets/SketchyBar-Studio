import AppKit
import Foundation
import SwiftUI
@testable import SketchyBarStudio
import XCTest

final class PreviewRenderingTests: XCTestCase {
    // MARK: - Helpers

    private func value(_ keyPath: String, original: String, draft: String? = nil) -> LuaEditableValue {
        LuaEditableValue(
            id: "\(keyPath)-\(original)",
            fileURL: URL(fileURLWithPath: "/tmp/root/items/foo.lua"),
            keyPath: keyPath,
            lineNumber: 1,
            kind: .string,
            originalValue: original,
            draftValue: draft ?? original,
            suggestedValues: [],
            valueStartOffset: 0,
            valueEndOffset: 0,
            sourceSnapshot: ""
        )
    }

    private func file(_ relativePath: String, values: [LuaEditableValue]) -> ConfigFile {
        ConfigFile(
            url: URL(fileURLWithPath: "/tmp/root/\(relativePath)"),
            rootURL: URL(fileURLWithPath: "/tmp/root"),
            kind: .lua,
            values: values,
            activationReference: nil
        )
    }

    /// The red, green and blue parts of a color of a preview item.
    private func components(_ color: Color?) -> (red: Double, green: Double, blue: Double)? {
        guard let color, let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (converted.redComponent, converted.greenComponent, converted.blueComponent)
    }

    // MARK: - Icon values

    func testIconParsesAnSFSymbol() {
        let icon = SketchyBarIcon.parse("sf.clock")

        XCTAssertEqual(icon.kind, .symbol)
        XCTAssertEqual(icon.symbolName, "clock")
        XCTAssertNil(icon.bundleIdentifier)
        XCTAssertNil(icon.text)
    }

    func testIconParsesAnAppIcon() {
        let icon = SketchyBarIcon.parse("app.com.apple.Safari")

        XCTAssertEqual(icon.kind, .appIcon)
        XCTAssertEqual(icon.bundleIdentifier, "com.apple.Safari")
        XCTAssertNil(icon.symbolName)
        XCTAssertNil(icon.text)
    }

    func testIconParsesTheMediaArtwork() {
        let icon = SketchyBarIcon.parse("media.artwork")

        XCTAssertEqual(icon.kind, .mediaArtwork)
        XCTAssertNil(icon.symbolName)
        XCTAssertNil(icon.bundleIdentifier)
        XCTAssertNil(icon.text)
    }

    func testIconParsesText() {
        let icon = SketchyBarIcon.parse("🎉")

        XCTAssertEqual(icon.kind, .text)
        XCTAssertEqual(icon.text, "🎉")
        XCTAssertNil(icon.symbolName)
    }

    func testIconParsesAnEmptyValueAsUnknown() {
        XCTAssertEqual(SketchyBarIcon.parse("").kind, .unknown)
        XCTAssertEqual(SketchyBarIcon.parse("   ").kind, .unknown)
        XCTAssertNil(SketchyBarIcon.parse("").symbolName)
    }

    func testIconReadsAQuotedValue() {
        let icon = SketchyBarIcon.parse("\"sf.clock\"")

        XCTAssertEqual(icon.kind, .symbol)
        XCTAssertEqual(icon.symbolName, "clock")
    }

    func testIconOfAnEmptyPrefixIsUnknown() {
        XCTAssertEqual(SketchyBarIcon.parse("sf.").kind, .unknown)
        XCTAssertEqual(SketchyBarIcon.parse("app.").kind, .unknown)
    }

    // MARK: - Icon images

    func testIconCacheHasAnImageForAKnownSymbol() {
        let icon = SketchyBarIcon.parse("sf.clock")

        XCTAssertNotNil(SketchyBarIconImageCache.shared.image(for: icon))
    }

    func testIconCacheHasNoImageForAnUnknownSymbol() {
        let icon = SketchyBarIcon.parse("sf.not_a_real_symbol_name")

        XCTAssertNil(SketchyBarIconImageCache.shared.image(for: icon))
    }

    func testIconCacheHasNoImageForAnAppThatIsNotInstalled() {
        let icon = SketchyBarIcon.parse("app.com.example.notinstalled")

        XCTAssertNil(SketchyBarIconImageCache.shared.image(for: icon))
    }

    func testIconCacheKeepsTheImageOfASymbol() {
        let icon = SketchyBarIcon.parse("sf.clock")

        let first = SketchyBarIconImageCache.shared.image(for: icon)
        let second = SketchyBarIconImageCache.shared.image(for: icon)

        XCTAssertTrue(first === second)
    }

    // MARK: - Fonts

    func testFontParsesTheFamilyTheStyleAndTheSize() throws {
        let font = try XCTUnwrap(SketchyBarFont.parse("SF Pro:Regular:14"))

        XCTAssertEqual(font.family, "SF Pro")
        XCTAssertEqual(font.style, "Regular")
        XCTAssertEqual(font.size, 14)
    }

    func testFontFallsBackForAMalformedValue() {
        XCTAssertNil(SketchyBarFont.parse("SF Pro"))
        XCTAssertNil(SketchyBarFont.parse("SF Pro:Regular"))
        XCTAssertNil(SketchyBarFont.parse("SF Pro:Regular:big"))
    }

    func testFontFallsBackToTheSystemFontForAFamilyThatIsNotInstalled() {
        let font = SketchyBarFont.nsFont(family: "Not An Installed Family", style: "Regular", size: 12)

        XCTAssertEqual(font.pointSize, 12)
    }

    func testFontUsesTheStyleOfTheFamily() {
        let font = SketchyBarFont.nsFont(family: "Helvetica Neue", style: "Bold", size: 14)

        XCTAssertEqual(font.pointSize, 14)
        XCTAssertEqual(font.fontDescriptor.object(forKey: .face) as? String, "Bold")
    }

    // MARK: - Preview items

    func testPreviewItemReadsTheQualifiedKeys() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("icon.string", original: "sf.clock"),
            value("icon.color", original: "0xffff8800"),
            value("label.string", original: "Clock"),
            value("label.font", original: "SF Pro:Regular:14"),
            value("background.color", original: "0xff112233"),
            value("background.border_color", original: "0xff445566")
        ])))

        XCTAssertEqual(item.icon.kind, .symbol)
        XCTAssertEqual(item.icon.symbolName, "clock")
        XCTAssertEqual(item.labelText, "Clock")
        XCTAssertEqual(item.title, "Clock")
        XCTAssertEqual(item.labelFont.pointSize, 14)

        let iconColor = try XCTUnwrap(components(item.iconColor))
        XCTAssertEqual(iconColor.red, 1, accuracy: 0.01)
        XCTAssertEqual(iconColor.green, 0.53, accuracy: 0.01)

        let background = try XCTUnwrap(components(item.backgroundColor))
        XCTAssertEqual(background.blue, 0.2, accuracy: 0.01)

        let border = try XCTUnwrap(components(item.borderColor))
        XCTAssertEqual(border.green, 0.33, accuracy: 0.01)
    }

    func testPreviewItemReadsTheFlatKeys() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("icon", original: "sf.clock"),
            value("label", original: "Clock"),
            value("width", original: "120"),
            value("padding_left", original: "4"),
            value("padding_right", original: "6")
        ])))

        XCTAssertEqual(item.icon.kind, .symbol)
        XCTAssertEqual(item.icon.symbolName, "clock")
        XCTAssertEqual(item.labelText, "Clock")
        XCTAssertEqual(item.widthValue?.draftValue, "120")
        XCTAssertEqual(item.leftPaddingValue?.draftValue, "4")
        XCTAssertEqual(item.rightPaddingValue?.draftValue, "6")
    }

    func testPreviewItemReadsTheFontParts() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("label.font.family", original: "Helvetica Neue"),
            value("label.font.style", original: "Bold"),
            value("label.font.size", original: "18")
        ])))

        XCTAssertEqual(item.labelFont.pointSize, 18)
        XCTAssertEqual(item.labelFont.fontDescriptor.object(forKey: .face) as? String, "Bold")
    }

    func testPreviewItemReadsTheItemFont() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("font", original: "SF Pro:Regular:20")
        ])))

        XCTAssertEqual(item.labelFont.pointSize, 20)
    }

    func testPreviewItemKeepsTheSizeWhenTheFamilyIsMissing() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("label.font.size", original: "11")
        ])))

        XCTAssertEqual(item.labelFont.pointSize, 11)
    }

    func testPreviewItemReadsTheSymbolModeAndTheSymbolColor() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("icon.string", original: "sf.clock"),
            value("symbol_mode", original: "color"),
            value("symbol_color", original: "0xff00ff00")
        ])))

        XCTAssertEqual(item.symbolMode, .color)
        XCTAssertEqual(components(item.symbolColor)?.green ?? 0, 1, accuracy: 0.01)
    }

    func testPreviewItemWithoutAnIconIsNeutral() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/wifi.lua", values: [
            value("position", original: "right")
        ])))

        XCTAssertEqual(item.icon.kind, .unknown)
        XCTAssertNil(item.icon.symbolName)
        XCTAssertNil(item.labelText)
        XCTAssertEqual(item.title, "wifi")
    }

    func testPreviewItemReadsTheVerticalOffset() throws {
        let item = try XCTUnwrap(BarPreviewItem(file: file("items/clock.lua", values: [
            value("position", original: "left"),
            value("y_offset", original: "6")
        ])))

        XCTAssertEqual(item.yOffset, 6)
    }
}
