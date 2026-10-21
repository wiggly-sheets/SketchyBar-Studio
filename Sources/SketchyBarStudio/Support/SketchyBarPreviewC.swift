import AppKit
import CoreGraphics
import CSketchyBar

/// The thin Swift wrapper of the vendored SketchyBar preview core.
///
/// Stage 2 drives the headless item tree: the handle, the bar properties,
/// the default item and the items of the preview. Stage 4 renders the bar
/// into a bitmap and reads the rectangles of the items.
///
/// The error codes of the C API live in `include/sketchybar_preview.h`.
enum SketchyBarPreviewC {
    /// The codes of the C API. Zero is success, every other value is a
    /// failure.
    enum Code {
        static let ok: Int32 = 0
        static let invalidArgument: Int32 = 1
        static let outOfMemory: Int32 = 2
        static let itemNotFound: Int32 = 3
        static let itemExists: Int32 = 4
        static let propertyRejected: Int32 = 5
    }

    /// Creates a preview handle. Returns nil when the core cannot start.
    static func create() -> OpaquePointer? {
        sb_preview_create()
    }

    /// Releases a handle that `create` returned. Passing nil is a no-op.
    static func destroy(_ handle: OpaquePointer?) {
        sb_preview_destroy(handle)
    }

    /// Sets one property of the bar. The key is a SketchyBar bar property,
    /// for example "position" or "margin".
    @discardableResult
    static func setBar(_ handle: OpaquePointer?, key: String, value: String) -> Int32 {
        withCStrings(key, value) { keyPointer, valuePointer in
            sb_preview_set_bar(handle, keyPointer, valuePointer)
        }
    }

    /// Sets one property of the default item. The default item is a snapshot
    /// taken when an item is created, so every call has to come before the
    /// first `addItem`.
    @discardableResult
    static func setDefault(_ handle: OpaquePointer?, key: String, value: String) -> Int32 {
        withCStrings(key, value) { keyPointer, valuePointer in
            sb_preview_set_default(handle, keyPointer, valuePointer)
        }
    }

    /// Adds an item with an alias. The alias is the name of the item.
    ///
    /// The type is the type of the add command of the daemon, e.g. "item",
    /// "alias" or "space" (`src/message.c:196`). A type the daemon does not
    /// know leaves the item a plain item.
    @discardableResult
    static func addItem(_ handle: OpaquePointer?, alias: String, type: String = "item") -> Int32 {
        withCStrings(alias, type) { aliasPointer, typePointer in
            sb_preview_add_item(handle, aliasPointer, typePointer)
        }
    }

    /// Sets one property of the item with that alias.
    @discardableResult
    static func setItem(_ handle: OpaquePointer?, alias: String, key: String, value: String) -> Int32 {
        withCStrings(alias, key, value) { aliasPointer, keyPointer, valuePointer in
            sb_preview_set_item(handle, aliasPointer, keyPointer, valuePointer)
        }
    }

    /// Sets the virtual display the bar is laid out for.
    ///
    /// The width and the height are in points. A nil width is the width of
    /// the target display, in points: the default belongs here, because the
    /// display is a property of the machine and not of the vendored core
    /// (see `include/sketchybar_preview.h`). A width that is not nil is the
    /// override, and it changes the width of the bar.
    ///
    /// The scale is the scale of the backing bitmap. The core keeps the
    /// fixed scale of 2.0 of SketchyBar and ignores the argument, so the
    /// scale of the display never changes the size of the image.
    @discardableResult
    static func setDisplay(_ handle: OpaquePointer?,
                           widthPoints: Double? = nil,
                           heightPoints: Double? = nil,
                           scale: Double = 2.0,
                           screen: NSScreen? = nil) -> Int32 {
        let display = screen ?? NSScreen.main
        let width = widthPoints ?? defaultDisplayWidth(for: display)
        let height = heightPoints ?? defaultDisplayHeight(for: display)
        return sb_preview_set_display(handle, width, height, scale)
    }

    /// The width of the virtual display when the caller gives none, in
    /// points: the width of the target display.
    static func defaultDisplayWidth(for screen: NSScreen? = nil) -> Double {
        Double((screen ?? NSScreen.main)?.frame.width ?? 1440)
    }

    /// The height of the virtual display when the caller gives none, in
    /// points: the height of the target display. The height of the display
    /// is not the height of the bar: the bar takes its height from the
    /// config.
    static func defaultDisplayHeight(for screen: NSScreen? = nil) -> Double {
        Double((screen ?? NSScreen.main)?.frame.height ?? 900)
    }

    /// Sets the height of the menu bar above the bar, in points. Zero means
    /// there is no menu bar and the bar starts at the top of the display.
    /// The call comes after `setDisplay` and before the render: the menu
    /// bar moves the bar down.
    @discardableResult
    static func setMenuBar(_ handle: OpaquePointer?, heightPoints: Double) -> Int32 {
        sb_preview_set_menu_bar(handle, heightPoints)
    }

    /// Renders the bar into a bitmap.
    ///
    /// The image is as wide as the display and as tall as the bar, in
    /// points, at the fixed backing scale of 2.0. Swift owns the image and
    /// releases it when the value goes away, so the caller must not call
    /// `sb_preview_release_image` on it: that function belongs to the
    /// callers of the C API.
    static func render(_ handle: OpaquePointer?) -> CGImage? {
        guard let handle else { return nil }
        return sb_preview_render(handle)?.takeRetainedValue()
    }

    /// The origin and size of one item, in points, after the layout.
    ///
    /// The rectangle is the frame of the window of the item in the
    /// coordinate system of the virtual display, the same value as the
    /// `bounding_rects` of `sketchybar --query <item>`. It is nil when no
    /// item has that alias.
    static func itemRect(_ handle: OpaquePointer?, alias: String) -> CGRect? {
        guard let handle else { return nil }
        var rect = CGRect.zero
        let code = alias.withCString { aliasPointer in
            sb_preview_item_rect(handle, aliasPointer, &rect)
        }
        guard code == Code.ok else { return nil }
        return rect
    }

    /// The messages the vendored code produced, one per line. The pointer
    /// belongs to the preview and must not be freed.
    static func messages(_ handle: OpaquePointer?) -> String {
        guard let handle else { return "" }
        guard let text = sb_preview_messages(handle) else { return "" }
        return String(cString: text)
    }

    /// Hands the strings to the C API as C strings.
    private static func withCStrings<Result>(_ first: String,
                                             _ second: String,
                                             _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result) -> Result {
        first.withCString { firstPointer in
            second.withCString { secondPointer in
                body(firstPointer, secondPointer)
            }
        }
    }

    private static func withCStrings<Result>(_ text: String,
                                             _ body: (UnsafePointer<CChar>) -> Result) -> Result {
        text.withCString { body($0) }
    }

    private static func withCStrings<Result>(_ first: String,
                                             _ second: String,
                                             _ third: String,
                                             _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result) -> Result {
        first.withCString { firstPointer in
            second.withCString { secondPointer in
                third.withCString { thirdPointer in
                    body(firstPointer, secondPointer, thirdPointer)
                }
            }
        }
    }
}
