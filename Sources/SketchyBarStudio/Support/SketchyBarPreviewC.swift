import CSketchyBar

/// The thin Swift wrapper of the vendored SketchyBar preview core.
///
/// Stage 2 drives the headless item tree: the handle, the bar properties,
/// the default item and the items of the preview. The rendered image and the
/// item rectangles arrive in stage 4.
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
    @discardableResult
    static func addItem(_ handle: OpaquePointer?, alias: String) -> Int32 {
        withCStrings(alias) { aliasPointer in
            sb_preview_add_item(handle, aliasPointer)
        }
    }

    /// Sets one property of the item with that alias.
    @discardableResult
    static func setItem(_ handle: OpaquePointer?, alias: String, key: String, value: String) -> Int32 {
        withCStrings(alias, key, value) { aliasPointer, keyPointer, valuePointer in
            sb_preview_set_item(handle, aliasPointer, keyPointer, valuePointer)
        }
    }

    /// Sets the virtual display the bar is laid out for. The width and the
    /// height are in points, the scale is the scale of the backing bitmap.
    @discardableResult
    static func setDisplay(_ handle: OpaquePointer?, widthPoints: Double, heightPoints: Double, scale: Double = 2.0) -> Int32 {
        sb_preview_set_display(handle, widthPoints, heightPoints, scale)
    }

    /// The messages the vendored code produced, one per line. The pointer
    /// belongs to the preview and must not be freed.
    static func messages(_ handle: OpaquePointer?) -> String {
        guard let handle else { return "" }
        guard let text = sb_preview_messages(handle) else { return "" }
        return String(cString: text)
    }

    /// The fixed width of an item, or nil when the item has none.
    static func itemWidth(_ handle: OpaquePointer?, alias: String) -> Int? {
        withCStrings(alias) { aliasPointer in
            let width = sb_preview_test_item_width(handle, aliasPointer)
            return width < 0 ? nil : Int(width)
        }
    }

    /// The left padding of the background of an item.
    static func itemPaddingLeft(_ handle: OpaquePointer?, alias: String) -> Int? {
        withCStrings(alias) { aliasPointer in
            let padding = sb_preview_test_item_padding_left(handle, aliasPointer)
            return padding < 0 ? nil : Int(padding)
        }
    }

    /// The environment the child of the script runner receives, one
    /// "KEY=VALUE" per line.
    static func childEnvironment() -> String {
        guard let pointer = sb_preview_test_child_environment() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
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
