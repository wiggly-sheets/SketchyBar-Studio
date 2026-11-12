import CSketchyBar
import Foundation

/// Runs the scripts of the items of a preview and turns the calls they make
/// into property assignments.
///
/// The scripts run in a child process, the way the daemon runs them
/// (`src/bar_item.c:166-168`), and the child gets the environment of the
/// shim: the directory of the shim comes first on the `PATH`, the sink
/// variable carries the path of the sink, and the directory of the real
/// binary is not on the `PATH` at all. A script of the preview therefore
/// cannot change the live bar of the user.
///
/// There are two routes, and they keep their results apart:
///
/// * the render route runs the scripts of the items of a preview through
///   the vendored core, so the child gets the environment of the item
///   itself: its name, its variables and the sender
///   (`src/bar_item.c:142-161`). The gate of the daemon decides whether a
///   script runs at all (`src/bar_item.c:127-139`).
/// * the timer route runs the scripts by their text, for a caller that has
///   no tree of items. The child gets the name of the item and the sender.
///
/// The runner keeps one run at a time, because the vendored core keeps the
/// children of the scripts in one place.
final class PreviewScriptRunner: @unchecked Sendable {
    /// What one run of the scripts produced.
    struct Outcome: Sendable {
        /// The property assignments the scripts made.
        let assignments: [PreviewScriptShim.Assignment]
        /// What went wrong: a script that failed, a script that ran too
        /// long, or a script that calls the binary by its absolute path.
        let warnings: [String]
    }

    /// The script of one item.
    struct Script: Equatable, Sendable {
        /// The alias of the item.
        let alias: String
        /// The text of the script.
        let script: String
    }

    /// One run of the scripts and the scripts that produced it.
    struct Run: Sendable {
        /// The scripts that were run.
        let scripts: [Script]
        /// What they produced.
        let outcome: Outcome
        /// When they ran.
        let date: Date
    }

    /// The time a script may take, in seconds.
    ///
    /// The value is the one of the vendored core (`PREVIEW_SCRIPT_TIMEOUT`
    /// in `src/misc/helpers.h`): the child of a script stops itself when
    /// the script runs longer.
    static let timeoutSeconds = 3

    /// How long the values of a run are used before the scripts run again.
    static let valuesLifetime: TimeInterval = 2

    /// How long the runner waits after the last request before it is idle.
    ///
    /// The pane of the preview cannot tell the service that it is hidden
    /// without a change in the views, so the timer of the scripts stops when
    /// the requests stop.
    static let idleTimeout: TimeInterval = 10

    /// The lock that keeps two runs apart.
    private let lock = NSLock()

    /// The scripts of the items of the last request.
    private var scripts: [Script] = []

    /// The time of the last request.
    private var lastRequest: Date?

    /// The last run of the render route.
    ///
    /// The render route is the one that runs the scripts of the items
    /// through the vendored core. The timer route keeps its own result, so
    /// the result of the timer never replaces the result of the render:
    /// the two routes do not run the same scripts in the same environment.
    private var lastRenderRun: Run?

    /// The last run of the timer route.
    private var lastTimerRun: Run?

    /// Whether a tick of the timer is running.
    private var tickInProgress = false

    /// Records the scripts of a request, so the timer can run them again.
    func noteRequest(scripts: [Script]) {
        lock.lock()
        defer { lock.unlock() }
        self.scripts = scripts
        self.lastRequest = Date()
    }

    /// Marks the preview as still in use, without changing its scripts.
    ///
    /// The pane calls this while it is visible, so a script with a slow
    /// `update_freq` that produced nothing for a while does not stop the
    /// timer under it.
    func touch() {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = Date()
    }

    /// Whether the runner has been idle for longer than the timeout.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastRequest else { return true }
        return Date().timeIntervalSince(lastRequest) >= Self.idleTimeout
    }

    /// Claims the tick of the timer.
    ///
    /// The timer fires every second and a tick can take longer than that
    /// when a script hangs, so the timer asks for the tick and skips it
    /// when one is already running.
    func claimTick() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !tickInProgress else { return false }
        tickInProgress = true
        return true
    }

    /// Releases the tick of the timer.
    func releaseTick() {
        lock.lock()
        defer { lock.unlock() }
        tickInProgress = false
    }

    // MARK: - The render route

    /// The values of the items: the ones of the last run of the render
    /// route when they are fresh, or a new run of the scripts of the items.
    ///
    /// The fresh run uses the scripts the vendored core knows: the script
    /// of the item, with the variables of the item, its name and the sender
    /// (`src/bar_item.c:114-171`). The result of the timer route is never
    /// used here: the two routes do not run the same scripts in the same
    /// environment.
    func values(for scripts: [Script], in handle: OpaquePointer?) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        if let lastRenderRun,
           lastRenderRun.scripts == scripts,
           Date().timeIntervalSince(lastRenderRun.date) < Self.valuesLifetime {
            return lastRenderRun.outcome
        }

        let outcome = Self.runItems(of: handle, scripts: scripts)
        lastRenderRun = Run(scripts: scripts, outcome: outcome, date: Date())
        return outcome
    }

    /// Runs the scripts of the items of a plan, on a tree of its own.
    ///
    /// The timer of the preview uses this: the daemon runs the script of an
    /// item from its clock, with the routine of the item and nothing else
    /// (`src/bar_manager.c:554`). The counter of the item decides when its
    /// script runs (`src/bar_item.c:132-133`), so the routine runs once
    /// per tick of the timer and not once per render.
    func runItems(of plan: BarRenderPlan,
                  widthPoints: Double,
                  heightPoints: Double) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        guard let handle = SketchyBarPreviewC.create() else {
            return Outcome(assignments: [],
                           warnings: ["The scripts of the items could not run, because the preview core could not start."])
        }
        defer { SketchyBarPreviewC.destroy(handle) }

        SketchyBarPreviewC.setDisplay(handle, widthPoints: widthPoints, heightPoints: heightPoints)
        // The warnings of the plan are the warnings of the render: the
        // timer does not add them a second time.
        _ = PreviewConfigBridge.apply(plan, to: handle)

        let scripts = Self.scripts(of: plan, in: handle)
        guard !scripts.isEmpty else {
            let outcome = Outcome(assignments: [], warnings: [])
            lastRenderRun = Run(scripts: scripts, outcome: outcome, date: Date())
            return outcome
        }

        let outcome = Self.runItems(of: handle, scripts: scripts)
        lastRenderRun = Run(scripts: scripts, outcome: outcome, date: Date())
        return outcome
    }

    /// The values of the last run of the render route.
    var lastOutcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return lastRenderRun?.outcome
    }

    // MARK: - The timer route

    /// Runs the scripts of the last request again, by their text.
    ///
    /// The timer of the preview used this: the timer has no preview of its
    /// own, so it runs the scripts the way the daemon runs them, with the
    /// name of the item and the sender. The whole batch is forked at once
    /// and the wait happens once, so the batch has one deadline and not one
    /// deadline per script.
    func runCurrentScripts() -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        guard !scripts.isEmpty else {
            return Outcome(assignments: [], warnings: [])
        }

        let outcome = Self.runScripts(scripts)
        lastTimerRun = Run(scripts: scripts, outcome: outcome, date: Date())
        return outcome
    }

    /// The values of the last run of the timer route.
    var lastTimerOutcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return lastTimerRun?.outcome
    }

    // MARK: - The scripts of a tree

    /// The scripts of the items of a plan, as the vendored core knows them.
    ///
    /// The core can hold a script the config does not set: a space item
    /// gets the script of the daemon (`src/bar_item.c:428-431`). The key of
    /// the values holds the scripts of the core, so a space item is cached
    /// under its own script.
    static func scripts(of plan: BarRenderPlan, in handle: OpaquePointer?) -> [Script] {
        plan.items.compactMap { item in
            guard let script = SketchyBarPreviewC.itemScript(handle, alias: item.alias),
                  !script.isEmpty else { return nil }
            return Script(alias: item.alias, script: script)
        }
    }

    // MARK: - The runs

    /// Runs the scripts of the items of a preview.
    private static func runItems(of handle: OpaquePointer?, scripts: [Script]) -> Outcome {
        guard let installation = try? PreviewScriptShim.Installation() else {
            return Outcome(assignments: [],
                           warnings: ["The scripts of the items could not run, because the directory of the shim could not be created."])
        }
        defer { installation.remove() }

        SketchyBarPreviewC.setScriptEnvironment(shimDirectory: installation.directory.path,
                                                sinkPath: installation.sinkURL.path,
                                                logDirectory: installation.logDirectory.path)

        let code = SketchyBarPreviewC.runItemScripts(handle)
        return outcome(of: code, scripts: scripts, installation: installation)
    }

    /// Runs the scripts of the items by their text.
    private static func runScripts(_ scripts: [Script]) -> Outcome {
        guard let installation = try? PreviewScriptShim.Installation() else {
            return Outcome(assignments: [],
                           warnings: ["The scripts of the items could not run, because the directory of the shim could not be created."])
        }
        defer { installation.remove() }

        SketchyBarPreviewC.setScriptEnvironment(shimDirectory: installation.directory.path,
                                                sinkPath: installation.sinkURL.path,
                                                logDirectory: installation.logDirectory.path)

        // Every script is forked at once and the wait happens once: the
        // batch has one deadline, so N scripts that hang cost one timeout
        // and not N of them.
        let code = SketchyBarPreviewC.runScripts(aliases: scripts.map(\.alias),
                                                  scripts: scripts.map(\.script))

        return Outcome(assignments: installation.assignments(),
                       warnings: runWarnings(of: code, scripts: scripts))
    }

    /// What one run produced: the messages of the run, the warnings of the
    /// scripts that call the binary by its absolute path, and the
    /// assignments the scripts wrote into the sink.
    private static func outcome(of code: Int32,
                                 scripts: [Script],
                                 installation: PreviewScriptShim.Installation) -> Outcome {
        Outcome(assignments: installation.assignments(),
                warnings: runWarnings(of: code, scripts: scripts))
    }

    /// The warnings of one run.
    ///
    /// The messages of the run are the messages of the vendored core: they
    /// name the item whose script failed and they carry what the script
    /// wrote to its standard error.
    private static func runWarnings(of code: Int32, scripts: [Script]) -> [String] {
        var warnings: [String] = []

        for line in SketchyBarPreviewC.scriptMessages().split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { warnings.append(text) }
        }

        if code != SketchyBarPreviewC.Code.ok, warnings.isEmpty {
            warnings.append(PreviewScriptWarning.failed(code: code))
        }

        for script in scripts {
            if PreviewScriptShim.callsBinaryByAbsolutePath(script.script) {
                warnings.append(PreviewScriptWarning.absolutePath(script.alias))
            } else if PreviewScriptShim.overridesPath(script.script) {
                warnings.append(PreviewScriptWarning.pathOverride(script.alias))
            }
        }

        return warnings
    }
}

/// The wording of the warnings the scripts of the items produce.
enum PreviewScriptWarning {
    /// A script that calls the binary of the daemon by its absolute path.
    ///
    /// Such a call is not intercepted by the shim: it reaches the live bar
    /// of the user. The preview says so, so the user knows that the script
    /// was not intercepted.
    static func absolutePath(_ alias: String) -> String {
        "The script of the item '\(alias)' calls the sketchybar binary by its absolute path, so the preview cannot intercept it and the call reaches the live bar."
    }

    /// A script that sets its own PATH.
    ///
    /// The shim is the first `sketchybar` of the PATH of the child, so a
    /// script that puts another directory in front of it can reach the real
    /// binary. The preview cannot see what the script does with the PATH,
    /// so it warns about it.
    static func pathOverride(_ alias: String) -> String {
        "The script of the item '\(alias)' sets its own PATH, so the preview cannot intercept a call of the sketchybar binary and the call can reach the live bar."
    }

    /// A script that failed without a message of its own.
    static func failed(code: Int32) -> String {
        "A script of an item failed with the code \(code)."
    }
}
