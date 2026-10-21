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
    /// A saved profile of a config, by the path of the profile.
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

/// A saved profile of a config, with the config it belongs to.
///
/// The profiles of a config live in the archive of that config
/// (`ProfileArchiveService.profilesRoot(for:)`), so the profile of
/// another config is a choice of the preview pane too.
struct BarRenderProfile: Identifiable, Hashable {
    /// The config the profile belongs to.
    let config: ConfigWorkspace
    /// The saved profile.
    let profile: ConfigProfile

    var id: String { profile.id }
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
    /// The warnings about the source, found before the render.
    ///
    /// The render knows the files it reads, but not whether the app has
    /// the config open, so the pane hands the warnings it knows over.
    let warnings: [String]

    init(files: [BarRenderFile],
         displayWidthPoints: Double,
         displayHeightPoints: Double,
         warnings: [String] = []) {
        self.files = files
        self.displayWidthPoints = displayWidthPoints
        self.displayHeightPoints = displayHeightPoints
        self.warnings = warnings
    }
}

/// The result of one render.
///
/// The image of the result is immutable, so the result can cross the
/// boundary of the actor safely.
struct BarRenderResult: @unchecked Sendable {
    /// The image of the bar, at the fixed backing scale of 2.0.
    let image: CGImage
    /// The size of the image, in pixels.
    let pixelSize: CGSize
    /// The rectangle of every item, in absolute display points, with the y
    /// growing downwards from the top of the display.
    ///
    /// This is the value the C API answers
    /// (`include/sketchybar_preview.h`), and the value the differential
    /// test of stage 8 compares with the `bounding_rects` of
    /// `sketchybar --query`.
    let itemRects: [String: CGRect]
    /// The rectangle of every item, relative to the bar, with the y
    /// growing downwards from the top of the bar.
    ///
    /// The image of the bar is in the coordinate system of CoreGraphics,
    /// where the y grows upwards, so this rectangle is not a rectangle of
    /// the image.
    let barRelativeRects: [String: CGRect]
    /// The frame of the bar, in the points of the display.
    let barFrame: CGRect?
    /// The problems of the config and of the vendored code.
    let warnings: [String]
}

/// Why a render did not produce an image.
enum BarRenderError: LocalizedError {
    /// The core could not start, so another preview is probably still alive.
    case previewUnavailable
    /// The core could not paint the bar. The reason says why.
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .previewUnavailable:
            return "The preview core could not start. Another preview is probably still running."
        case .renderFailed(let reason):
            return reason
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

    /// The biggest width of the virtual display the render accepts, in
    /// points.
    ///
    /// The bitmap of the bar is the width of the display times the backing
    /// scale of 2.0, so 20,000 points is a bitmap of 40,000 pixels. A
    /// bigger width is refused: the bitmap would be too big to allocate,
    /// the vendored code would draw into a context that is not there
    /// (`src/context.c:6-20`, `src/bar.c:152`), and the app would die with
    /// the drafts of the user in it.
    static let maximumDisplayWidthPoints: Double = 20_000

    /// The core has one preview at a time, so there is one service.
    private init() {}

    /// Renders the bar of a config.
    ///
    /// The files of the request are read, parsed and sent to the vendored
    /// core, which lays the bar out and paints it into a bitmap. The
    /// warnings of the config and of the vendored code come back with the
    /// image.
    func render(_ request: BarRenderRequest) throws -> BarRenderResult {
        // The size of the display is checked before the core is touched.
        // A width that is not a number, or a width that is too big, would
        // make the vendored code draw into a bitmap that could not be
        // allocated.
        try Self.checkDisplay(request)

        guard let handle = SketchyBarPreviewC.create() else {
            throw BarRenderError.previewUnavailable
        }
        defer { SketchyBarPreviewC.destroy(handle) }

        // The virtual display comes first: the call rebuilds the bar, so
        // its frame follows the new display (`src/bar.c:516-522`).
        try setDisplay(handle, request: request)

        let plan = Self.plan(for: request.files)
        // The defaults of the plan come before its items, so every item
        // inherits them the way it does in SketchyBar.
        var warnings = request.warnings
        warnings += PreviewConfigBridge.apply(plan, to: handle)

        guard let image = SketchyBarPreviewC.render(handle) else {
            throw BarRenderError.renderFailed("The bar could not be rendered.")
        }

        let frame = SketchyBarPreviewC.barFrame(handle)
        var rects: [String: CGRect] = [:]
        var barRects: [String: CGRect] = [:]
        for item in plan.items {
            guard let rect = SketchyBarPreviewC.itemRect(handle, alias: item.alias) else { continue }
            rects[item.alias] = rect
            barRects[item.alias] = Self.barRelative(rect, in: frame)
        }

        return BarRenderResult(
            image: image,
            pixelSize: CGSize(width: image.width, height: image.height),
            itemRects: rects,
            barRelativeRects: barRects,
            barFrame: frame,
            warnings: warnings
        )
    }

    /// Refuses a display the render cannot draw.
    ///
    /// The width and the height of the display are the size of the bitmap
    /// of the bar, so a size that is not a number, or a size that is too
    /// big, is refused before the core is called.
    private static func checkDisplay(_ request: BarRenderRequest) throws {
        guard request.displayWidthPoints.isFinite,
              request.displayWidthPoints > 0,
              request.displayWidthPoints <= maximumDisplayWidthPoints else {
            throw BarRenderError.renderFailed(
                "The bar cannot be rendered for a display of \(sizeName(of: request.displayWidthPoints)) points wide. "
                + "The width must be a number between 1 and \(Int(maximumDisplayWidthPoints)) points."
            )
        }
        guard request.displayHeightPoints.isFinite,
              request.displayHeightPoints > 0,
              request.displayHeightPoints <= maximumDisplayWidthPoints else {
            throw BarRenderError.renderFailed(
                "The bar cannot be rendered for a display of \(sizeName(of: request.displayHeightPoints)) points high. "
                + "The height must be a number between 1 and \(Int(maximumDisplayWidthPoints)) points."
            )
        }
    }

    /// The name of a size that is not a number, for the user.
    private static func sizeName(of size: Double) -> String {
        if size.isNaN { return "an unknown" }
        if size.isInfinite { return size > 0 ? "an infinite" : "a negative infinite" }
        return String(format: "%.0f", size)
    }

    /// Sets the virtual display the bar is laid out for.
    ///
    /// The width and the height are the ones the caller measured on the
    /// main actor, so the render never asks the window server for a
    /// display: `NSScreen` belongs to the main thread. The scale is the
    /// fixed scale of 2.0 of SketchyBar, and the core ignores it anyway
    /// (`include/sketchybar_preview.h`).
    private func setDisplay(_ handle: OpaquePointer?, request: BarRenderRequest) throws {
        let code = sb_preview_set_display(handle,
                                          request.displayWidthPoints,
                                          request.displayHeightPoints,
                                          2.0)
        guard code == SketchyBarPreviewC.Code.ok else {
            throw BarRenderError.renderFailed("The virtual display of the render was refused.")
        }
    }

    /// The tree of the files of a config.
    ///
    /// The plan of every file is combined, so the defaults of the whole
    /// config reach every item, and the items keep the order of the files.
    private static func plan(for files: [BarRenderFile]) -> BarRenderPlan {
        var combined = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])
        var readable = 0

        for file in files {
            guard let contents = contents(of: file) else { continue }
            readable += 1
            // A `.lua` file is Lua. A file without an extension, such as the
            // `sketchybarrc` of the sketchybar-package, is decided by its
            // text, the same way the bridge decides it.
            let filePlan = file.kind == .lua || LuaSourceDetection.isLua(contents)
                ? PreviewConfigBridge.plan(forLua: contents)
                : PreviewConfigBridge.plan(forShell: contents)
            combined = combined.combined(with: filePlan)
        }

        // A source without a readable file paints an empty bar, so the
        // pane has to say that there was nothing to render.
        guard readable > 0 else {
            return BarRenderPlan(defaults: combined.defaults,
                                 bar: combined.bar,
                                 items: combined.items,
                                 warnings: combined.warnings + [BarRenderWarning.noReadableFile()])
        }

        return combined
    }

    /// The text of a file: the draft of the app, or the file on disk.
    private static func contents(of file: BarRenderFile) -> String? {
        if let contents = file.contents { return contents }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

    /// The rectangle of an item, relative to the bar.
    ///
    /// The rectangle of the C API is in the points of the display, with
    /// the y growing downwards from the top of the display
    /// (`include/sketchybar_preview.h`). The bar sits at the frame of the
    /// bar, so the rectangle of the item inside the bar starts at the top
    /// of the bar.
    private static func barRelative(_ rect: CGRect, in frame: CGRect?) -> CGRect {
        guard let frame else { return rect }
        return CGRect(x: rect.origin.x - frame.origin.x,
                      y: rect.origin.y - frame.origin.y,
                      width: rect.width,
                      height: rect.height)
    }
}

/// The wording of the warnings the render produces itself.
///
/// The wording lives here, so the render and the store say the same thing
/// about the same problem.
enum BarRenderWarning {
    /// A source without a readable file.
    ///
    /// A missing folder, an empty config or a deleted profile leaves the
    /// render without a file, and the bar would be an empty strip without
    /// a word about it.
    static func noReadableFile() -> String {
        "No readable config file was found, so the bar is empty."
    }
}

/// A display the bar can be rendered for.
struct BarRenderDisplay: Identifiable, Hashable {
    /// The id of the display, so the choice of the user survives a reload.
    let id: String
    /// The name of the display, for the user.
    let name: String
    /// The width of the display, in points.
    let widthPoints: Double
    /// The height of the display, in points.
    let heightPoints: Double
}

/// The displays of the machine.
///
/// The screens are read on the main thread only, because `NSScreen`
/// belongs to the main thread.
@MainActor
enum BarRenderDisplays {
    /// Every display of the machine.
    static func all() -> [BarRenderDisplay] {
        NSScreen.screens.map(display)
    }

    /// The display the app is on.
    static func main() -> BarRenderDisplay? {
        guard let screen = NSScreen.main else { return nil }
        return display(screen)
    }

    /// The display of a screen.
    private static func display(_ screen: NSScreen) -> BarRenderDisplay {
        BarRenderDisplay(id: id(of: screen),
                         name: screen.localizedName,
                         widthPoints: Double(screen.frame.width),
                         heightPoints: Double(screen.frame.height))
    }

    /// The id of a display.
    ///
    /// The number of the screen in the device description is the number
    /// the window server knows, so it is the same on every read.
    static func id(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { String($0.intValue) } ?? screen.localizedName
    }
}

/// The geometry of the rendered bar inside the preview pane.
///
/// The bar is drawn at its true size and the view applies one uniform
/// factor, so the proportions of the real menu bar survive. The bar is
/// never re-laid out to the shape of the pane, and it is never stretched:
/// the same factor goes to both axes.
struct BarRenderLayout {
    /// The scale of the backing bitmap of the render.
    ///
    /// The bitmap of the bar is always at the fixed scale of 2.0 of
    /// SketchyBar, so the points of the bar are the pixels of the image
    /// divided by two.
    static let bitmapScale: CGFloat = 2.0

    /// The size of the rendered image, in pixels.
    let imageSize: CGSize
    /// The size the pane offers, in points.
    let paneSize: CGSize
    /// True when the image is drawn at its true point size, so one image
    /// pixel lands on one device pixel of a display with the scale of 2.0.
    let isOneToOne: Bool

    /// The one factor the view applies to both axes.
    ///
    /// At 1:1 the factor is the one that turns the pixels of the image
    /// into the points of the bar, so the bar is drawn at its true size.
    var scaleFactor: CGFloat {
        guard !isOneToOne else { return 1 / Self.bitmapScale }
        guard imageSize.width > 0, paneSize.width > 0 else { return 1 }
        return paneSize.width / imageSize.width
    }

    /// The size the image is drawn at, in points.
    var drawnSize: CGSize {
        CGSize(width: imageSize.width * scaleFactor,
               height: imageSize.height * scaleFactor)
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
            return libraryProfiles.first { $0.profile.id == profilePath }?.profile.url
        }
    }
}
