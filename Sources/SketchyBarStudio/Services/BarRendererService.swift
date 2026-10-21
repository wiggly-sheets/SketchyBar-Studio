import AppKit
import CoreGraphics
import CSketchyBar
import Foundation

/// What the preview pane renders.
///
/// A source is a config of the library or a saved profile of a config. The
/// config the app has open is one of the choices, not the only one.
enum BarRenderSource: Hashable, Identifiable {
    /// A config of the library, by its id.
    case config(ConfigWorkspace.ID)
    /// A saved profile of the config the app has open, by the path of the
    /// profile.
    case profile(profilePath: String)

    var id: String {
        switch self {
        case .config(let id):
            return "config:\(id)"
        case .profile(let profilePath):
            return "profile:\(profilePath)"
        }
    }
}

/// One file of a config, as the render reads it.
struct BarRenderFile: Sendable {
    let url: URL
    let kind: ConfigFileKind
    /// The text of the file, or nil to read the file from disk.
    ///
    /// The text of a file of the config the app has open is the text with
    /// the pending drafts of the app, so the preview shows the unsaved
    /// edits.
    let contents: String?
}

/// The request of one render.
struct BarRenderRequest: Sendable {
    /// The files of the config, in the order of the bar.
    let files: [BarRenderFile]
    /// The width of the virtual display, in points.
    let displayWidthPoints: Double
    /// The height of the virtual display, in points.
    let displayHeightPoints: Double
}

/// The result of one render.
struct BarRenderResult {
    /// The image of the bar, at the fixed backing scale of 2.0.
    let image: CGImage
    /// The size of the image, in pixels.
    let pixelSize: CGSize
    /// The rectangle of every item, in the points of the image.
    let itemRects: [String: CGRect]
    /// The frame of the bar, in the points of the display.
    let barFrame: CGRect?
    /// The problems of the config and of the vendored code.
    let warnings: [String]
}

/// Why a render did not produce an image.
enum BarRenderError: LocalizedError {
    /// The core could not start, so another preview is probably still alive.
    case previewUnavailable
    /// The core could not paint the bar.
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .previewUnavailable:
            return "The preview core could not start. Another preview is probably still running."
        case .renderFailed:
            return "The bar could not be rendered."
        }
    }
}

/// Renders a bar of a config with the vendored SketchyBar code.
///
/// The vendored core keeps its model in one global bar manager, so only one
/// preview exists at a time (`include/sketchybar_preview.h`). The service is
/// an actor, so the renders run one after the other and never overlap, and
/// the render runs off the main actor, because the layout and the drawing
/// take real time.
actor BarRendererService {
    static let shared = BarRendererService()

    /// Renders the bar of a config.
    ///
    /// The files of the request are read, parsed and sent to the vendored
    /// core, which lays the bar out and paints it into a bitmap. The
    /// warnings of the config and of the vendored code come back with the
    /// image.
    func render(_ request: BarRenderRequest) throws -> BarRenderResult {
        guard let handle = SketchyBarPreviewC.create() else {
            throw BarRenderError.previewUnavailable
        }
        defer { SketchyBarPreviewC.destroy(handle) }

        // The virtual display comes first: the call rebuilds the bar, so
        // its frame follows the new display (`src/bar.c:516-522`).
        setDisplay(handle, request: request)

        let plan = Self.plan(for: request.files)
        // The defaults of the plan come before its items, so every item
        // inherits them the way it does in SketchyBar.
        let warnings = PreviewConfigBridge.apply(plan, to: handle)

        guard let image = SketchyBarPreviewC.render(handle) else {
            throw BarRenderError.renderFailed
        }

        let frame = SketchyBarPreviewC.barFrame(handle)
        var rects: [String: CGRect] = [:]
        for item in plan.items {
            guard let rect = SketchyBarPreviewC.itemRect(handle, alias: item.alias) else { continue }
            rects[item.alias] = Self.imageRect(rect, in: frame)
        }

        return BarRenderResult(
            image: image,
            pixelSize: CGSize(width: image.width, height: image.height),
            itemRects: rects,
            barFrame: frame,
            warnings: warnings
        )
    }

    /// Sets the virtual display the bar is laid out for.
    ///
    /// The width and the height are the ones the caller measured on the
    /// main actor, so the render never asks the window server for a
    /// display: `NSScreen` belongs to the main thread. The scale is the
    /// fixed scale of 2.0 of SketchyBar, and the core ignores it anyway
    /// (`include/sketchybar_preview.h`).
    private func setDisplay(_ handle: OpaquePointer?, request: BarRenderRequest) {
        sb_preview_set_display(handle,
                               request.displayWidthPoints,
                               request.displayHeightPoints,
                               2.0)
    }

    /// The tree of the files of a config.
    ///
    /// The plan of every file is combined, so the defaults of the whole
    /// config reach every item, and the items keep the order of the files.
    private static func plan(for files: [BarRenderFile]) -> BarRenderPlan {
        var combined = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])

        for file in files {
            guard let contents = contents(of: file) else { continue }
            // A `.lua` file is Lua. A file without an extension, such as the
            // `sketchybarrc` of the sketchybar-package, is decided by its
            // text, the same way the bridge decides it.
            let filePlan = file.kind == .lua || LuaSourceDetection.isLua(contents)
                ? PreviewConfigBridge.plan(forLua: contents)
                : PreviewConfigBridge.plan(forShell: contents)
            combined = combined.combined(with: filePlan)
        }

        return combined
    }

    /// The text of a file: the draft of the app, or the file on disk.
    private static func contents(of file: BarRenderFile) -> String? {
        if let contents = file.contents { return contents }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

    /// The rectangle of an item in the points of the image.
    ///
    /// The rectangle of an item is in the points of the display and the
    /// image is the frame of the bar, so the origin of the bar is the
    /// origin of the image (`include/sketchybar_preview.h`).
    private static func imageRect(_ rect: CGRect, in frame: CGRect?) -> CGRect {
        guard let frame else { return rect }
        return CGRect(x: rect.origin.x - frame.origin.x,
                      y: rect.origin.y - frame.origin.y,
                      width: rect.width,
                      height: rect.height)
    }
}

/// The display the bar is rendered for.
///
/// The width of the display is the width of the virtual display, so the bar
/// has the proportions of the real menu bar of that display: a SketchyBar
/// bar is the display width minus twice the margin (`src/bar.c:437-494`).
/// The user can override the width.
enum BarRenderDisplay {
    /// The display the app is on.
    @MainActor
    static func target() -> NSScreen? {
        NSScreen.main
    }

    /// The name of the display, for the user.
    @MainActor
    static func name(of screen: NSScreen?) -> String {
        screen?.localizedName ?? "No display"
    }

    /// The width of the display, in points.
    @MainActor
    static func width(of screen: NSScreen?) -> Double {
        Double(screen?.frame.width ?? 1440)
    }

    /// The height of the display, in points. The height of the bar comes
    /// from the config, so the height of the display only matters for a bar
    /// on the side of the display.
    @MainActor
    static func height(of screen: NSScreen?) -> Double {
        Double(screen?.frame.height ?? 900)
    }
}

/// The geometry of the rendered bar inside the preview pane.
///
/// The bar is drawn at its true size and the view applies one uniform
/// factor, so the proportions of the real menu bar survive. The bar is
/// never re-laid out to the shape of the pane, and it is never stretched:
/// the same factor goes to both axes.
struct BarRenderLayout {
    /// The size of the rendered image, in pixels.
    let imageSize: CGSize
    /// The size the pane offers, in points.
    let paneSize: CGSize
    /// True when the image is drawn at one image pixel per point.
    let isOneToOne: Bool

    /// The one factor the view applies to both axes.
    var scaleFactor: CGFloat {
        guard !isOneToOne else { return 1 }
        guard imageSize.width > 0, paneSize.width > 0 else { return 1 }
        return paneSize.width / imageSize.width
    }

    /// The size the image is drawn at, in points.
    var drawnSize: CGSize {
        CGSize(width: imageSize.width * scaleFactor,
               height: imageSize.height * scaleFactor)
    }

    /// True when the drawn bar is wider than the pane, so the pane has to
    /// scroll sideways.
    var scrollsHorizontally: Bool {
        drawnSize.width > paneSize.width
    }
}

extension SketchyBarStore {
    /// The files the preview renders for a source, in the order of the bar.
    ///
    /// The files of the config the app has open carry the drafts of the
    /// app, so the preview shows the unsaved edits. Every other config and
    /// every profile is read from disk.
    func barRenderFiles(for source: BarRenderSource) -> [BarRenderFile] {
        if case .config(let id) = source, id == selectedConfig?.id {
            return filesInPreviewOrder.map { file in
                BarRenderFile(url: file.url,
                              kind: file.kind,
                              contents: effectiveContents(for: file))
            }
        }

        guard let root = barRenderRoot(for: source) else { return [] }
        let locator = SketchyBarConfigLocator()
        return locator.configFiles(in: root).compactMap { url in
            guard let kind = locator.kind(for: url) else { return nil }
            return BarRenderFile(url: url, kind: kind, contents: nil)
        }
    }

    /// The folder a source renders: the folder of the config or of the
    /// profile.
    func barRenderRoot(for source: BarRenderSource) -> URL? {
        switch source {
        case .config(let id):
            return configs.first { $0.id == id }?.url
        case .profile(let profilePath):
            return profiles.first { $0.id == profilePath }?.url
        }
    }
}
