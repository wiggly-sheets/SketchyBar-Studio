import CSketchyBar
import Foundation

/// The test-only accessors of the preview core.
///
/// The C API exports them for the tests of the preview core. The app never
/// calls them, so the Swift wrappers live in the test target and the app
/// target does not mention them.
enum BarPreviewTestAccessors {
    /// The fixed width of an item, or nil when the item has none.
    static func itemWidth(_ handle: OpaquePointer?, alias: String) -> Int? {
        alias.withCString { aliasPointer in
            let width = sb_preview_test_item_width(handle, aliasPointer)
            return width < 0 ? nil : Int(width)
        }
    }

    /// The left padding of the background of an item.
    static func itemPaddingLeft(_ handle: OpaquePointer?, alias: String) -> Int? {
        alias.withCString { aliasPointer in
            let padding = sb_preview_test_item_padding_left(handle, aliasPointer)
            return padding < 0 ? nil : Int(padding)
        }
    }

    /// The serialized form of an item, the same text `sketchybar --query
    /// <item>` answers with.
    static func itemSerialization(_ handle: OpaquePointer?, alias: String) -> String? {
        alias.withCString { aliasPointer in
            guard let pointer = sb_preview_test_item_serialize(handle, aliasPointer) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }

    /// The environment the child of the script runner receives, one
    /// "KEY=VALUE" per line.
    static func childEnvironment() -> String {
        guard let pointer = sb_preview_test_child_environment() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// The bitmap of an item, at the scale of the backing bitmap.
    static func itemImage(_ handle: OpaquePointer?, alias: String) -> CGImage? {
        guard let handle else { return nil }
        return alias.withCString { aliasPointer in
            sb_preview_test_item_image(handle, aliasPointer)?.takeRetainedValue()
        }
    }
}
