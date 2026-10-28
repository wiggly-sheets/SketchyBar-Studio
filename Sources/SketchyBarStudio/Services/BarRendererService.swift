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
    /// The folder of the config, when the source has one.
    ///
    /// The Lua resolver needs the whole tree on disk to resolve the
    /// requires of the config, so it reads the config from the disk and
    /// the draft of the app is applied on top of the resolved tree.
    let root: URL?
    /// True when the files of the request come in the order of their
    /// names.
    ///
    /// The files of the config the app has open come in the order of the
    /// loader, and the files of a config that is not open come in the
    /// order of their names. The render needs to know, because the items
    /// of the bar follow the order of the files when the config is not
    /// resolved with Lua.
    let filesAreInFileOrder: Bool
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
         root: URL? = nil,
         filesAreInFileOrder: Bool = true,
         displayWidthPoints: Double,
         displayHeightPoints: Double,
         warnings: [String] = []) {
        self.files = files
        self.root = root
        self.filesAreInFileOrder = filesAreInFileOrder
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

    /// The resolved plans of the roots the pane rendered, so a draft of the
    /// app does not run the Lua of the config again.
    ///
    /// It is not private, so a test can tell a render that reused its
    /// resolution from a render that ran the Lua again.
    static let resolvedPlans = ResolvedPlanCache()

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

    /// How often the scripts of the items run while the preview is in use.
    static let liveValuesInterval: TimeInterval = 1

    /// The runner of the scripts of the items.
    ///
    /// The scripts run in the preview, so the bar shows the values they
    /// produce. The runner keeps the values of the last run, so a render
    /// that follows a run of the timer does not run the scripts again.
    private let runner = PreviewScriptRunner()

    /// The timer that runs the scripts of the items again and again.
    ///
    /// The timer lives while the renders are requested and stops when the
    /// requests stop: the pane of the preview cannot tell the service that
    /// it is hidden without a change in the views.
    private var liveValuesTimer: DispatchSourceTimer?

    /// The tree of the last render: the plan of the items.
    ///
    /// The timer runs the scripts of these items, so it needs the plan.
    private var livePlan: BarRenderPlan?

    /// The display of the last render: the tree of the timer is built for
    /// it, so the items have the same place on the bar.
    private var liveDisplay: (width: Double, height: Double)?

    /// The core has one preview at a time, so there is one service.
    private init() {}

    /// Renders the bar of a config.
    ///
    /// The files of the request are read, parsed and sent to the vendored
    /// core, which lays the bar out and paints it into a bitmap. The
    /// warnings of the config and of the vendored code come back with the
    /// image.
    ///
    /// The body runs inside an autorelease pool: the render allocates the
    /// objects of Foundation and of the vendored code, and a preview that
    /// stays open would grow without bound without the pool.
    func render(_ request: BarRenderRequest) throws -> BarRenderResult {
        // The size of the display is checked before the core is touched.
        // A width that is not a number, or a width that is too big, would
        // make the vendored code draw into a bitmap that could not be
        // allocated.
        try Self.checkDisplay(request)

        return try autoreleasepool {
            guard let handle = SketchyBarPreviewC.create() else {
                throw BarRenderError.previewUnavailable
            }
            defer { SketchyBarPreviewC.destroy(handle) }

            // The virtual display comes first: the call rebuilds the bar, so
            // its frame follows the new display (`src/bar.c:516-522`).
            try setDisplay(handle, request: request)

            let plan = Self.plan(for: request)
            // The defaults of the plan come before its items, so every item
            // inherits them the way it does in SketchyBar.
            var warnings = request.warnings
            warnings += PreviewConfigBridge.apply(plan, to: handle)

            // The scripts of the items run inside the preview, so the bar shows
            // the values they produce. The scripts reach the shim and not the
            // live bar of the user.
            //
            // The scripts are the ones the vendored core knows: a space item
            // gets the script of the daemon (`src/bar_item.c:428-431`), and
            // the key of the values holds it.
            let scripts = PreviewScriptRunner.scripts(of: plan, in: handle)
            runner.noteRequest(scripts: scripts)
            let outcome = runner.values(for: scripts, in: handle)
            warnings += outcome.warnings
            for assignment in outcome.assignments {
                warnings += Self.apply(assignment, to: handle)
            }

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

            livePlan = plan
            liveDisplay = (request.displayWidthPoints, request.displayHeightPoints)
            startLiveValuesTimer()

            return BarRenderResult(
                image: image,
                pixelSize: CGSize(width: image.width, height: image.height),
                itemRects: rects,
                barRelativeRects: barRects,
                barFrame: frame,
                warnings: warnings
            )
        }
    }

    /// Puts one assignment of a script into the preview.
    ///
    /// The answer of the vendored code is not swallowed: a property that
    /// the vendored parser refuses answers with a message, and the app has
    /// to show the user why the property was refused.
    private static func apply(_ assignment: PreviewScriptShim.Assignment, to handle: OpaquePointer?) -> [String] {
        let code = SketchyBarPreviewC.setItem(handle,
                                               alias: assignment.alias,
                                               key: assignment.key,
                                               value: assignment.value)
        guard code != SketchyBarPreviewC.Code.ok else { return [] }

        let message = SketchyBarPreviewC.messages(handle).trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = message.isEmpty ? "the property was refused" : message
        return ["The property '\(assignment.key)' of the item '\(assignment.alias)' was refused: \(reason)"]
    }

    /// Starts the timer that runs the scripts of the items again and again.
    ///
    /// The timer runs the scripts of the last request, so the values of the
    /// items stay fresh while the preview is in use. It stops itself when
    /// the requests stop: the pane of the preview cannot tell the service
    /// that it is hidden without a change in the views, so the timer waits
    /// for the idle timeout of the runner.
    private func startLiveValuesTimer() {
        guard liveValuesTimer == nil else { return }

        let runner = self.runner
        let queue = DispatchQueue(label: "com.sketchybarstudio.preview.live-values")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.liveValuesInterval,
                       repeating: Self.liveValuesInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // A tick that is already running is not started again, so the
            // timer does not pile up ticks when a script hangs.
            guard runner.claimTick() else { return }
            Task { await self.tickLiveValues() }
        }
        timer.resume()
        liveValuesTimer = timer
    }

    /// One tick of the timer: the routine of the items, the way the daemon
    /// runs it.
    ///
    /// The daemon runs the script of an item from its clock, with the
    /// routine of the item and nothing else (`src/bar_manager.c:554`). The
    /// counter of the item decides when its script runs, so the routine
    /// runs once per tick of the timer and not once per render.
    ///
    /// The tick builds a tree of its own, because the vendored core keeps
    /// one tree at a time and the render uses it. The counter of every item
    /// is kept between the trees, so the cadence of the daemon survives.
    private func tickLiveValues() {
        defer { runner.releaseTick() }

        guard !runner.isIdle else {
            stopLiveValuesTimer()
            return
        }
        guard let plan = livePlan, let display = liveDisplay else {
            stopLiveValuesTimer()
            return
        }

        // A config without a script has nothing to run: the tick skips it
        // instead of building a tree and a directory for nothing.
        guard plan.items.contains(where: { item in
            item.properties.contains { $0.key == "script" && !$0.value.isEmpty }
        }) else { return }

        autoreleasepool {
            _ = runner.runItems(of: plan,
                                widthPoints: display.width,
                                heightPoints: display.height)
        }
    }

    /// Stops the timer of the scripts of the items.
    private func stopLiveValuesTimer() {
        liveValuesTimer?.cancel()
        liveValuesTimer = nil
    }

    /// Stops the timer of the scripts of the items.
    ///
    /// The pane of the preview cannot tell the service that it is hidden
    /// without a change in the views, so the timer stops when the requests
    /// stop. A stage that may change the views calls this when the pane is
    /// hidden.
    func stopLiveValues() {
        stopLiveValuesTimer()
        livePlan = nil
        liveDisplay = nil
    }

    /// The values the scripts of the items produced.
    ///
    /// The pane of the preview does not read them yet: the view may not
    /// change in this stage. A later stage shows them in the pane.
    var liveValues: PreviewScriptRunner.Outcome? {
        runner.lastOutcome
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
    /// A config that a Lua interpreter can resolve is resolved with it:
    /// the values are the values of the config, the types are the types of
    /// the config and the order is the order of the load, which is the
    /// order of the daemon. The draft of the app is then applied on top of
    /// the resolved tree.
    ///
    /// The run of the Lua is the expensive half of a render, and the pane
    /// renders again on every keystroke of a draft. The run is therefore
    /// kept between renders until a file of the config changes on disk: a
    /// draft changes the text the app holds and not the text on disk, so
    /// the draft never runs the Lua again.
    ///
    /// A config that cannot be resolved with Lua is read by the parser.
    /// The plan of the parser is built only then, and a warning says why
    /// the config was not resolved.
    static func plan(for request: BarRenderRequest) -> BarRenderPlan {
        guard let root = request.root else {
            return parserFallback(
                for: request,
                reason: PreviewWarning.noLuaEntrypoint()
            )
        }

        guard let entrypoint = LuaConfigRunner.entrypoint(in: root) else {
            return parserFallback(
                for: request,
                reason: PreviewWarning.noLuaEntrypoint()
            )
        }

        do {
            let resolved = try resolvedPlan(of: root,
                                            entrypoint: entrypoint,
                                            signature: diskSignature(of: request.files))
            let draft = PreviewConfigBridge.draft(of: request.files, root: root)
            return resolved.overlaying(draft: draft)
        } catch {
            return parserFallback(
                for: request,
                reason: "The config could not be resolved with Lua: \(PreviewConfigBridge.reason(of: error))",
                addsFileOrder: true
            )
        }
    }

    /// The plan of the resolved config, reused while the files on disk are
    /// the same.
    private static func resolvedPlan(of root: URL,
                                     entrypoint: URL,
                                     signature: Int) throws -> BarRenderPlan {
        try resolvedPlans.plan(for: root.standardizedFileURL.path,
                               signature: signature) {
            try PreviewConfigBridge.plan(fromResolved: LuaConfigRunner.resolve(configRoot: root,
                                                                              entrypoint: entrypoint))
        }
    }

    /// The plan of the parser, with a warning that says why it is used.
    ///
    /// The parser reads the text of the files, so the plan holds the drafts
    /// of the app. The parser cannot read the type of an item and it cannot
    /// read a value an expression builds, and the warning names the reason
    /// the parser is used at all.
    ///
    /// The order of the items follows the order of the files, so the pane
    /// says that too when the files come in the order of their names.
    private static func parserFallback(for request: BarRenderRequest,
                                       reason: String,
                                       addsFileOrder: Bool = false) -> BarRenderPlan {
        let parsed = parserPlan(for: request.files)
        var warnings = parsed.warnings
        warnings.append(PreviewWarning.luaFallback(reason))
        if addsFileOrder, request.filesAreInFileOrder {
            warnings.append(PreviewWarning.fileOrder())
        }
        return BarRenderPlan(defaults: parsed.defaults,
                             bar: parsed.bar,
                             items: parsed.items,
                             warnings: warnings)
    }

    /// A signature of the files of a config on disk.
    ///
    /// The signature names the text of the files the resolution was built
    /// from, so a plan is reused while the files are the same and is built
    /// again as soon as one of them changes. The draft of a request is not
    /// part of the signature: a draft never changes a file on disk.
    ///
    /// shortcut: a file the config opens itself, such as a JSON table, is
    /// not in the list of the config files, so a change to it is not seen
    /// until another file changes. Upgrade when a config that reads such a
    /// file is common.
    private static func diskSignature(of files: [BarRenderFile]) -> Int {
        var hasher = Hasher()
        for file in files {
            hasher.combine(file.url.standardizedFileURL.path)
            let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey,
                                                               .fileSizeKey])
            hasher.combine(values?.contentModificationDate)
            hasher.combine(values?.fileSize)
        }
        return hasher.finalize()
    }

    /// The tree of the parser: the plan of every file is combined, so the
    /// defaults of the whole config reach every item, and the items keep
    /// the order of the files.
    private static func parserPlan(for files: [BarRenderFile]) -> BarRenderPlan {
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

/// Keeps the resolved plan of a config root between renders.
///
/// The Lua of a config is expensive to run and the pane renders again on
/// every keystroke of a draft, so the plan of a run is kept until the files
/// of the config change on disk. The key of an entry is the root of the
/// config, and the signature is the state of the files of the root on disk.
///
/// A run that fails is kept as well: a config that runs into the deadline
/// of the sandbox would otherwise stop the pane on every keystroke. A
/// change to a file of the config is a new signature, so a config the user
/// fixed on disk is resolved again.
final class ResolvedPlanCache: @unchecked Sendable {
    private struct Entry {
        let signature: Int
        let result: Result<BarRenderPlan, Error>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var runsByRoot: [String: Int] = [:]

    /// The plan of a root, or the result of the run that built it.
    ///
    /// The run happens outside of the lock, so a slow config does not hold
    /// the cache. Two renders of the same changed root can therefore run
    /// the Lua twice; they are the same request, so the second run only
    /// replaces the first.
    ///
    /// All runs are cached (success and failure). A failed run is kept so
    /// the pane does not retry the Lua on every keystroke. A change to a
    /// file of the config is a new signature, so a config the user fixed on
    /// disk is resolved again.
    func plan(for root: String,
              signature: Int,
              run: () throws -> BarRenderPlan) throws -> BarRenderPlan {
        if let entry = stored(root: root, signature: signature) {
            return try entry.result.get()
        }

        let result = Result { try run() }

        // Increment run counter for every attempt, then cache the result.
        lock.lock()
        runsByRoot[root, default: 0] += 1
        entries[root] = Entry(signature: signature, result: result)
        lock.unlock()

        return try result.get()
    }

    /// The number of runs of a root that the cache did not answer.
    ///
    /// The app does not read it: a test reads it to tell a render that
    /// reused its resolution from a render that ran the Lua again.
    func runs(of root: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return runsByRoot[root] ?? 0
    }

    /// The stored plan of a root, when the files on disk are the same.
    private func stored(root: String, signature: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[root], entry.signature == signature else { return nil }
        return entry
    }
}

/// The wording of the warnings the render produces itself.
///
/// The wording lives here, so the render and the store say the same thing
/// about the same problem.
enum BarRenderWarning {    /// A source without a readable file.
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
    ///
    /// Only the files with a draft carry their text: a file without a
    /// draft is already in the resolved config, and the app has nothing to
    /// put on top of it.
    func barRenderFiles(for source: BarRenderSource) -> [BarRenderFile] {
        if case .config(let id) = source, id == selectedConfig?.id {
            return filesInPreviewOrder.map { file in
                BarRenderFile(url: file.url,
                              kind: file.kind,
                              contents: hasUnsavedChanges(fileID: file.id) ? effectiveContents(for: file) : nil)
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
