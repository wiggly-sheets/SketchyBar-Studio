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

    /// The last run of the scripts.
    private var lastRun: Run?

    /// Records the scripts of a request, so the timer can run them again.
    func noteRequest(scripts: [Script]) {
        lock.lock()
        defer { lock.unlock() }
        self.scripts = scripts
        self.lastRequest = Date()
    }

    /// Whether the runner has been idle for longer than the timeout.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastRequest else { return true }
        return Date().timeIntervalSince(lastRequest) >= Self.idleTimeout
    }

    /// The values of the items: the ones of the last run when they are
    /// fresh, or a new run of the scripts of the items.
    ///
    /// The fresh run uses the scripts the vendored core knows: the script of
    /// the item, with the variables of the item, its name and the sender
    /// (`src/bar_item.c:114-171`).
    func values(for scripts: [Script], in handle: OpaquePointer?) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        if let lastRun,
           lastRun.scripts == scripts,
           Date().timeIntervalSince(lastRun.date) < Self.valuesLifetime {
            return lastRun.outcome
        }

        let outcome = Self.runItems(of: handle, scripts: scripts)
        lastRun = Run(scripts: scripts, outcome: outcome, date: Date())
        return outcome
    }

    /// Runs the scripts of the last request again, by their text.
    ///
    /// The timer of the preview uses this: the timer has no preview of its
    /// own, so it runs the scripts the way the daemon runs them, with the
    /// name of the item and the sender.
    func runCurrentScripts() -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        let outcome = Self.runScripts(scripts)
        lastRun = Run(scripts: scripts, outcome: outcome, date: Date())
        return outcome
    }

    /// The values of the last run of the scripts.
    var lastOutcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return lastRun?.outcome
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

        var collected: [String] = []
        for script in scripts {
            let code = SketchyBarPreviewC.runScript(alias: script.alias, script: script.script)
            collected += runWarnings(of: code, scripts: [script])
        }

        return Outcome(assignments: installation.assignments(), warnings: collected)
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

        for script in scripts where PreviewScriptShim.callsBinaryByAbsolutePath(script.script) {
            warnings.append(PreviewScriptWarning.absolutePath(script.alias))
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

    /// A script that failed without a message of its own.
    static func failed(code: Int32) -> String {
        "A script of an item failed with the code \(code)."
    }
}
