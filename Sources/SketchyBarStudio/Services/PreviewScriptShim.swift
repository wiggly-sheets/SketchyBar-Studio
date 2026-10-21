import Foundation

/// The `sketchybar` shim of the preview.
///
/// The scripts of the items change the bar by calling `sketchybar`. The
/// preview must never change the live bar of the user, so the child of a
/// script gets a `PATH` whose first entry is the directory of this shim, and
/// the shim writes what the script sets into a sink file instead of talking
/// to the daemon of SketchyBar.
///
/// The shim never runs the real binary. A command it does not handle is
/// reported on its standard error, the child exits with the code 64, and
/// the preview shows the report as a warning.
enum PreviewScriptShim {
    /// The text of the shim.
    ///
    /// The script is the contract of the stage: it takes the `--set` calls
    /// of the scripts of the items and writes them into the sink file. The
    /// marker of a message is skipped before the alias is read, so a script
    /// written `sketchybar -m --set clock label="12:00"` reaches the same
    /// path as `sketchybar --set clock label="12:00"`.
    static let script = #"""
    #!/bin/sh
    # The sink file comes from the environment, set by the preview runner.
    sink="$SKETCHYBAR_STUDIO_PREVIEW_SINK"

    # -m and --message are the message marker. The client strips it before it
    # sends the message (src/sketchybar.c:170-172), and the fork's own space item
    # uses this form (src/bar_item.c:430). Skip it before the alias is read.
    case "$1" in
      -m|--message)
        shift
        ;;
    esac

    case "$1" in
      --set)
        # Remaining arguments are <alias> <prop>=<value> ...
        shift
        alias="$1"; shift
        for pair in "$@"; do
          printf '%s\t%s\n' "$alias" "$pair" >> "$sink"
        done
        exit 0
        ;;
      *)
        # Not handled. Report it, never forward it to the real binary.
        printf 'sketchybar: unsupported preview command: %s\n' "$*" >&2
        exit 64
        ;;
    esac
    """#

    /// The name of the shim in its directory.
    ///
    /// The name is the name of the binary of the daemon, because the shim
    /// stands in for it: a script that calls `sketchybar` finds the shim
    /// first on the PATH of the child.
    static let executableName = "sketchybar"

    /// The name of the sink file, in the directory of the shim.
    static let sinkFileName = "sink"

    /// The name of the directory that holds the standard error of the
    /// scripts, in the directory of the shim.
    static let logDirectoryName = "logs"

    /// The variable that carries the path of the sink file to the shim.
    static let sinkEnvironmentKey = "SKETCHYBAR_STUDIO_PREVIEW_SINK"

    /// One property assignment a script made.
    struct Assignment: Equatable, Sendable {
        /// The alias of the item the script belongs to.
        let alias: String
        /// The key of the property, such as `label`.
        let key: String
        /// The value of the property, such as `12:00`.
        let value: String
    }

    /// The shim, its sink and its logs, in a directory of their own.
    ///
    /// The directory is a directory of the temporary folder of the system,
    /// and the name of it is unique, so two previews never share a sink.
    /// The whole directory is removed when the run is done: the sink file is
    /// never written outside of it.
    struct Installation {
        /// The directory that holds the shim, the sink and the logs.
        let directory: URL
        /// The file the shim writes to.
        let sinkURL: URL
        /// The directory that holds the standard error of the scripts.
        let logDirectory: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SketchyBarStudioPreview", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let logDirectory = directory.appendingPathComponent(PreviewScriptShim.logDirectoryName,
                                                               isDirectory: true)
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

            let executable = directory.appendingPathComponent(PreviewScriptShim.executableName)
            try PreviewScriptShim.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: executable.path)

            self.directory = directory
            self.sinkURL = directory.appendingPathComponent(PreviewScriptShim.sinkFileName)
            self.logDirectory = logDirectory
        }

        /// The assignments the scripts wrote into the sink.
        func assignments() -> [PreviewScriptShim.Assignment] {
            guard let text = try? String(contentsOf: sinkURL, encoding: .utf8) else { return [] }
            return PreviewScriptShim.assignments(in: text)
        }

        /// Empties the sink, so a run only reads what that run wrote.
        func resetSink() {
            try? FileManager.default.removeItem(at: sinkURL)
        }

        /// Removes the directory of the shim, the sink and the logs.
        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The assignments of the text of a sink file.
    ///
    /// Every line of the sink is an alias, a tab and a property. The pair is
    /// split at the first `=` only, because a value may hold one itself. A
    /// value that holds a space survives: the transport of SketchyBar is
    /// NUL separated and not space separated (`src/misc/helpers.h:247-263`).
    static func assignments(in text: String) -> [Assignment] {
        var assignments: [Assignment] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let alias = String(line[line.startIndex..<tab])
            let pair = String(line[line.index(after: tab)...])

            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<equals])
            let value = String(pair[pair.index(after: equals)...])

            guard !alias.isEmpty, !key.isEmpty else { continue }
            assignments.append(Assignment(alias: alias, key: key, value: value))
        }

        return assignments
    }

    /// Whether a script calls the binary of the daemon by its absolute path.
    ///
    /// Such a call is not intercepted by the shim: it reaches the live bar
    /// of the user. The preview warns about it, so the user knows that the
    /// script was not intercepted.
    static func callsBinaryByAbsolutePath(_ script: String) -> Bool {
        script.contains("/sketchybar")
    }
}
