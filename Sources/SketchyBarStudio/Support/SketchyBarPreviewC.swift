import CSketchyBar

/// The thin Swift wrapper of the vendored SketchyBar preview core.
///
/// Stage 1 proves the link: the handle is created and destroyed. The item
/// tree, the messages and the rendered image arrive in stage 2 and stage 4.
enum SketchyBarPreviewC {
    /// Creates a preview handle. Returns nil when the core cannot start.
    static func create() -> OpaquePointer? {
        sb_preview_create()
    }

    /// Releases a handle that `create` returned. Passing nil is a no-op.
    static func destroy(_ handle: OpaquePointer?) {
        sb_preview_destroy(handle)
    }
}
