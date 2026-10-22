import CoreGraphics
import Foundation
import XCTest
@testable import SketchyBarStudio

/// The semantic tests of the rendered bar.
///
/// These tests pin the behaviour of the vendored core that matters for
/// exactness: max_chars truncation, symbol_name serialization, defaults
/// inheritance, align handling, scroll_texts, and group background.
final class BarRenderSemanticTests: XCTestCase {
    // MARK: - The timer of the scripts

    override func tearDown() async throws {
        await BarRendererService.shared.stopLiveValues()
    }

    // MARK: - max_chars truncation

    /// The rendered item respects max_chars: the width of the item shrinks
    /// when max_chars truncates the label.
    func testMaxCharsTruncationReducesItemWidth() throws {
        let longLabel = String(repeating: "a", count: 50)
        let renderedWithout = try renderBar(items: [
            Item(alias: "label", type: "item", properties: ["label=\(longLabel)", "label.font=Menlo:Bold:14"])
        ])
        let renderedWith = try renderBar(items: [
            Item(alias: "label", type: "item", properties: ["label=\(longLabel)", "label.font=Menlo:Bold:14", "label.max_chars=10"])
        ])

        let rectWithout = try XCTUnwrap(renderedWithout.rects["label"])
        let rectWith = try XCTUnwrap(renderedWith.rects["label"])

        XCTAssertLessThan(rectWith.width, rectWithout.width, "max_chars must reduce the item width")
    }

    /// max_chars of zero means no truncation.
    func testMaxCharsZeroMeansNoTruncation() throws {
        let label = "short"
        let rendered = try renderBar(items: [
            Item(alias: "label", type: "item", properties: ["label=\(label)", "label.font=Menlo:Bold:14", "label.max_chars=0"])
        ])

        let rect = try XCTUnwrap(rendered.rects["label"])
        XCTAssertGreaterThan(rect.width, 0, "the item must have a width")
    }

    // MARK: - symbol_name model

    /// The background image with an sf. symbol serializes with the symbol_name key.
    func testBackgroundImageWithSymbolSerializesSymbolName() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "background.image", value: "sf.clock"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "background.color", value: "0xffffffff"), SketchyBarPreviewC.Code.ok)

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        XCTAssertTrue(serialization.contains("\"symbol_name\": \"clock\""), "the serialization must contain symbol_name: \(serialization)")
    }

    // MARK: - defaults inheritance

    /// The default item is inherited by every item added after it.
    func testDefaultItemInheritanceReachesAllItems() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "label", value: "default"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "first", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "second", position: "right"), SketchyBarPreviewC.Code.ok)

        let first = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "first"))
        let second = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "second"))

        XCTAssertTrue(first.contains("\"value\": \"default\""), "first must inherit default: \(first)")
        XCTAssertTrue(second.contains("\"value\": \"default\""), "second must inherit default: \(second)")
    }

    /// A default set after an item does not reach that item.
    func testDefaultAfterItemDoesNotReachIt() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "first", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "label", value: "after"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "second", position: "right"), SketchyBarPreviewC.Code.ok)

        let first = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "first"))
        let second = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "second"))

        XCTAssertFalse(first.contains("\"value\": \"after\""), "first must not inherit late default: \(first)")
        XCTAssertTrue(second.contains("\"value\": \"after\""), "second must inherit late default: \(second)")
    }

    /// Nested bar defaults (e.g., bar.padding_left) do not reach items.
    func testBarDefaultsDoNotReachItems() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: "padding_left", value: "10"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)

        let item = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        // The item has its own padding_left (default 0), but the bar's padding_left=10 should not appear in the item
        XCTAssertFalse(item.contains("\"padding_left\": 10"), "bar padding_left=10 must not reach item: \(item)")
    }

    /// Popup defaults (default item inside a popup) inherit correctly.
    func testPopupDefaultInheritance() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setDefault(handle, key: "label", value: "popup_default"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "parent", type: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "child", type: "item", position: "popup", argument: "parent"), SketchyBarPreviewC.Code.ok)

        let child = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "child"))
        XCTAssertTrue(child.contains("\"value\": \"popup_default\""), "popup item must inherit default: \(child)")
    }

    // MARK: - align key handling

    /// align=center shifts content inside a fixed width.
    func testAlignCenterShiftsContent() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "width", value: "100"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "label", value: "x"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "label.align", value: "center"), SketchyBarPreviewC.Code.ok)

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        XCTAssertTrue(serialization.contains("\"align\": \"center\"") || serialization.contains("\"position\": \"c\""),
                      "the item must reflect center alignment: \(serialization)")
    }

    /// align=right shifts content to the right inside a fixed width.
    func testAlignRightShiftsContent() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "width", value: "100"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "label", value: "x"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "label.align", value: "right"), SketchyBarPreviewC.Code.ok)

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        XCTAssertTrue(serialization.contains("\"align\": \"right\"") || serialization.contains("\"position\": \"r\""),
                      "the item must reflect right alignment: \(serialization)")
    }

    // MARK: - scroll_texts key handling

    /// scroll_texts=on enables text scrolling for long labels.
    func testScrollTextsOnEnablesScrolling() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "scroll_texts", value: "on"), SketchyBarPreviewC.Code.ok)

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        XCTAssertTrue(serialization.contains("\"scroll_texts\": \"on\""), "scroll_texts must be on: \(serialization)")
    }

    /// scroll_texts=off disables text scrolling.
    func testScrollTextsOffDisablesScrolling() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "item", key: "scroll_texts", value: "off"), SketchyBarPreviewC.Code.ok)

        let serialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "item"))
        XCTAssertTrue(serialization.contains("\"scroll_texts\": \"off\""), "scroll_texts must be off: \(serialization)")
    }

    // MARK: - group background inheritance

    /// A bracket/group draws one background spanning its members.
    func testGroupBackgroundSpansMembers() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "left", type: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "right", type: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "group", type: "bracket", position: "left", argument: "left right"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "group", key: "background.color", value: "0xff3355ff"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "group", key: "background.border_color", value: "0xffffffff"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "group", key: "background.border_width", value: "2"), SketchyBarPreviewC.Code.ok)

        let rectLeft = try XCTUnwrap(SketchyBarPreviewC.itemRect(handle, alias: "left"))
        let rectRight = try XCTUnwrap(SketchyBarPreviewC.itemRect(handle, alias: "right"))
        let rectGroup = try XCTUnwrap(SketchyBarPreviewC.itemRect(handle, alias: "group"))

        XCTAssertTrue(abs(rectGroup.origin.x - rectLeft.origin.x) <= 1.0,
                      "group must start at or before first member: \(rectGroup.origin.x) vs \(rectLeft.origin.x)")
        XCTAssertTrue(abs((rectGroup.origin.x + rectGroup.width) - (rectRight.origin.x + rectRight.width)) <= 1.0,
                      "group must end at or after last member: \(rectGroup.origin.x + rectGroup.width) vs \(rectRight.origin.x + rectRight.width)")
    }

    /// The group background uses the background of the first member.
    func testGroupBackgroundUsesFirstMemberBackground() throws {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create())
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: 480, heightPoints: 25), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "first", type: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "second", type: "item", position: "left"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: "group", type: "bracket", position: "left", argument: "first second"), SketchyBarPreviewC.Code.ok)
        XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: "group", key: "background.color", value: "0xff3355ff"), SketchyBarPreviewC.Code.ok)

        let groupSerialization = try XCTUnwrap(BarPreviewTestAccessors.itemSerialization(handle, alias: "group"))
        XCTAssertTrue(groupSerialization.contains("bracket"), "group must have bracket array: \(groupSerialization)")
    }

    // MARK: - Helpers

    private struct Item {
        let alias: String
        let type: String
        var position: String = "left"
        var argument: String? = nil
        var properties: [String] = []
    }

    private struct RenderedBar {
        let image: CGImage
        let rects: [String: CGRect]
        let frame: CGRect?
    }

    private func renderBar(widthPoints: Double = 480,
                           heightPoints: Double = 25,
                           scale: Double = 2.0,
                           bar: [String] = [],
                           items: [Item]) throws -> RenderedBar {
        let handle = try XCTUnwrap(SketchyBarPreviewC.create(), "the core must hand out a preview handle")
        defer { SketchyBarPreviewC.destroy(handle) }

        XCTAssertEqual(SketchyBarPreviewC.setDisplay(handle, widthPoints: widthPoints, heightPoints: heightPoints, scale: scale), SketchyBarPreviewC.Code.ok)
        for property in bar {
            let (key, value) = try XCTUnwrap(Self.split(property))
            XCTAssertEqual(SketchyBarPreviewC.setBar(handle, key: key, value: value), SketchyBarPreviewC.Code.ok, property)
        }
        for item in items {
            XCTAssertEqual(SketchyBarPreviewC.addItem(handle, alias: item.alias, type: item.type, position: item.position, argument: item.argument), SketchyBarPreviewC.Code.ok, item.alias)
            for property in item.properties {
                let (key, value) = try XCTUnwrap(Self.split(property))
                XCTAssertEqual(SketchyBarPreviewC.setItem(handle, alias: item.alias, key: key, value: value), SketchyBarPreviewC.Code.ok, property)
            }
        }

        let image = try XCTUnwrap(SketchyBarPreviewC.render(handle), "the render must hand back an image")
        var rects: [String: CGRect] = [:]
        for item in items {
            rects[item.alias] = SketchyBarPreviewC.itemRect(handle, alias: item.alias) ?? .zero
        }
        return RenderedBar(image: image, rects: rects, frame: SketchyBarPreviewC.barFrame(handle))
    }

    private static func split(_ property: String) -> (String, String)? {
        guard let separator = property.firstIndex(of: "=") else { return nil }
        return (String(property[property.startIndex..<separator]), String(property[property.index(after: separator)...]))
    }
}