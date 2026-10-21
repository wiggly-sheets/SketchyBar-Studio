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
    ///
    /// A value can hold a newline, and the sink holds one line per
    /// property. The shim escapes the backslashes and the newlines, and
    /// the preview unescapes them again (`PreviewScriptShim.unescaped`).
    static let script = #"""
    #!/bin/sh
    # The sink file comes from the environment, set by the preview runner.
    sink="$SKETCHYBAR_STUDIO_PREVIEW_SINK"

    # A newline in a value, kept in a variable so the case below can match
    # it without a command.
    newline='
    '

    # The backslashes and the newlines of a value are escaped: the sink
    # holds one line per property, and the transport of SketchyBar is NUL
    # separated and keeps the value whole (src/misc/helpers.h:247-263).
    escape() {
      printf '%s' "$1" | sed -e ':a' -e '$!{N;ba' -e '}' -e 's/\\/\\\\/g' -e 's/\n/\\n/g'
    }

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
        case "$alias" in
          *\\*|*"$newline"*) escaped_alias=$(escape "$alias") ;;
          *) escaped_alias="$alias" ;;
        esac
        for pair in "$@"; do
          case "$pair" in
            *\\*|*"$newline"*) escaped=$(escape "$pair") ;;
            *) escaped="$pair" ;;
          esac
          printf '%s\t%s\n' "$escaped_alias" "$escaped" >> "$sink"
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
            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("SketchyBarStudioPreview", isDirectory: true)
            try PreviewScriptShim.createPrivateDirectory(at: parent)

            let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try PreviewScriptShim.createPrivateDirectory(at: directory)

            let logDirectory = directory.appendingPathComponent(PreviewScriptShim.logDirectoryName,
                                                               isDirectory: true)
            try PreviewScriptShim.createPrivateDirectory(at: logDirectory)

            let executable = directory.appendingPathComponent(PreviewScriptShim.executableName)
            try PreviewScriptShim.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: executable.path)

            // The sink is created here, with a mode only the user of the app
            // can read. The shim appends to it.
            let sinkURL = directory.appendingPathComponent(PreviewScriptShim.sinkFileName)
            FileManager.default.createFile(atPath: sinkURL.path, contents: nil, attributes: [.posixPermissions: 0o600])

            self.directory = directory
            self.sinkURL = sinkURL
            self.logDirectory = logDirectory
        }

        /// The assignments the scripts wrote into the sink.
        func assignments() -> [PreviewScriptShim.Assignment] {
            guard let text = try? String(contentsOf: sinkURL, encoding: .utf8) else { return [] }
            return PreviewScriptShim.assignments(in: text)
        }

        /// Removes the directory of the shim, the sink and the logs.
        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Creates a directory that only the user of the app can read.
    ///
    /// The temporary folder of a GUI app is private already: it is a
    /// directory of `/var/folders/…` with the mode 0700. The fallback of
    /// `/tmp` is not: a directory that another user can write into must not
    /// hold the shim of the preview, so such a directory is refused.
    ///
    /// A directory that is only readable by the others is made private
    /// instead of refused: an older version of the app left its directory
    /// behind with the mode 0755, and refusing for good would break the
    /// scripts of the preview for every user of that version.
    static func createPrivateDirectory(at url: URL) throws {
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PreviewScriptShimError.notADirectory(url)
            }

            let attributes = try manager.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o022 == 0 else {
                // Another user can write into the directory: the shim of
                // the preview would not be the shim of the app.
                throw PreviewScriptShimError.worldWritable(url)
            }
            if mode & 0o077 != 0 {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            return
        }

        try manager.createDirectory(at: url,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }

    /// The assignments of the text of a sink file.
    ///
    /// Every line of the sink is an alias, a tab and a property. The pair is
    /// split at the first `=` only, because a value may hold one itself. A
    /// value that holds a space survives: the transport of SketchyBar is
    /// NUL separated and not space separated (`src/misc/helpers.h:247-263`).
    /// A value that holds a newline survives too: the shim escapes it, and
    /// the escape is undone here.
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
            assignments.append(Assignment(alias: unescaped(alias),
                                           key: unescaped(key),
                                           value: unescaped(value)))
        }

        return assignments
    }

    /// Undoes the escapes of the shim.
    ///
    /// The shim escapes the backslashes and the newlines of a value, so a
    /// value that holds one of them survives the line based sink. The
    /// escape of a backslash comes first, so `\\n` is a backslash and an
    /// `n`, and only `\n` is a newline.
    static func unescaped(_ text: String) -> String {
        guard text.contains("\\") else { return text }

        var result = ""
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let next = iterator.next() else {
                result.append(character)
                break
            }
            switch next {
            case "n": result.append("\n")
            case "\\": result.append("\\")
            default:
                result.append(character)
                result.append(next)
            }
        }

        return result
    }

    /// Whether a script calls the binary of the daemon by its absolute path.
    ///
    /// Such a call is not intercepted by the shim: it reaches the live bar
    /// of the user. The preview warns about it, so the user knows that the
    /// script was not intercepted.
    static func callsBinaryByAbsolutePath(_ script: String) -> Bool {
        for line in lines(of: script) where !isComment(line) {
            if mentionsBinaryByPath(line) { return true }
        }
        return false
    }

    /// Whether a script sets its own PATH.
    ///
    /// The shim is the first `sketchybar` of the PATH of the child, so a
    /// script that sets its own PATH can put the real binary in front of
    /// the shim. The preview cannot see that, so it warns about it.
    static func overridesPath(_ script: String) -> Bool {
        for line in lines(of: script) where !isComment(line) {
            if line.contains("PATH=") && mentionsBinary(line) { return true }
        }
        return false
    }

    /// The lines of a script that are not comments.
    private static func lines(of script: String) -> [String] {
        script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Whether a line is a comment: the shell ignores it.
    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    /// Whether a line mentions the binary of the daemon.
    private static func mentionsBinary(_ line: String) -> Bool {
        line.contains(PreviewScriptShim.executableName)
    }

    /// Whether a line calls the binary of the daemon by a path.
    private static func mentionsBinaryByPath(_ line: String) -> Bool {
        let name = PreviewScriptShim.executableName
        var searchStart = line.startIndex

        while searchStart < line.endIndex,
              let found = line.range(of: name, range: searchStart..<line.endIndex) {
            if found.lowerBound > line.startIndex {
                let before = line[line.index(before: found.lowerBound)]
                if before == "/" { return true }
            }
            searchStart = found.upperBound
        }

        return false
    }
}

/// The problems the installation of the shim can run into.
enum PreviewScriptShimError: LocalizedError {
    /// A file is in the way of a directory of the shim.
    case notADirectory(URL)
    /// A directory of the shim is writable by other users.
    case worldWritable(URL)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "The path of the directory of the scripts is a file: \(url.path)"
        case .worldWritable(let url):
            return "The directory of the scripts is writable by other users: \(url.path)"
        }
    }
}
