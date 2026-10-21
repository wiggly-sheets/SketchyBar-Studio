import Foundation

/// How the live bar of the user follows the edits of the app.
///
/// The mode is a setting, so the user can go back to `Never` at any time.
enum LiveUpdateMode: String, CaseIterable, Identifiable {
    /// The live bar changes only when the user saves and applies.
    case never
    /// The live bar is updated when the user clicks Apply or Save & Apply.
    case onApply
    /// The live bar is updated as the user edits, debounced.
    case whileEditing

    /// The mode a fresh install starts with.
    ///
    /// `Never` is the safe one: nothing of the app reaches the bar of the
    /// user until the user asks for it.
    static let defaultMode: LiveUpdateMode = .never

    /// The key of the setting in the defaults of the app.
    static let defaultsKey = "liveUpdateMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .onApply: return "On Apply"
        case .whileEditing: return "While Editing"
        }
    }

    /// What the mode does, in the words of the setting.
    var explanation: String {
        switch self {
        case .never:
            return "The live bar only changes when you save and apply the config."
        case .onApply:
            return "The live bar updates when you click Apply or Save & Apply."
        case .whileEditing:
            return "The live bar updates as you edit, debounced."
        }
    }

    /// The saved mode.
    ///
    /// A fresh install has no saved mode, so it starts with `Never`.
    static func saved(in defaults: UserDefaults = .standard) -> LiveUpdateMode {
        guard let raw = defaults.string(forKey: defaultsKey),
              let mode = LiveUpdateMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    /// Saves the mode in the defaults of the app.
    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// One property of an item, with the value the live bar gets.
struct LiveBarProperty: Equatable, Sendable {
    /// The name of the property, such as `label` or `background.color`.
    let key: String
    /// The value of the property, such as `10:00`.
    let value: String
}

/// One item of the live bar, with the properties the push sets on it.
struct LiveBarItem: Equatable, Sendable {
    /// The name of the item, such as `clock`.
    let alias: String
    /// The properties the push sets on the item.
    let properties: [LiveBarProperty]
}

/// One call of the binary of the daemon.
///
/// The arguments are the arguments of the call, without the name of the
/// binary. The transport of SketchyBar is NUL separated
/// (`src/sketchybar.c:73-86`), so a value with a space survives it and
/// needs no quoting: the value is one argument of the process.
struct LiveBarCommand: Equatable, Sendable {
    /// The arguments of the call.
    let arguments: [String]

    /// The call the way a user reads it.
    var displayText: String {
        (["sketchybar"] + arguments)
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// The call that sets the properties of an item.
    static func set(alias: String, properties: [LiveBarProperty]) -> LiveBarCommand {
        LiveBarCommand(arguments: ["--set", alias] + properties.map { "\($0.key)=\($0.value)" })
    }

    /// The call that sets the properties of the bar.
    ///
    /// The daemon wants the plain name of a property of the bar: the
    /// `bar.` prefix of the app is not a name the daemon knows, and the
    /// daemon would ignore it (`src/message.c:449-463`,
    /// `src/message.c:680-692`).
    static func setBar(properties: [LiveBarProperty]) -> LiveBarCommand {
        LiveBarCommand(arguments: ["--bar"] + properties.map {
            "\(LiveBarService.barLeaf(of: $0.key))=\($0.value)"
        })
    }
}

/// The answer of the daemon to a call.
struct LiveBarCommandResult: Equatable {
    /// Everything the daemon wrote.
    let output: String
    /// The refusal of the daemon, when it refused.
    ///
    /// The daemon writes a refusal as `[!] …` after a timestamp
    /// (`src/misc/helpers.h:83-103`), and the client hands it back with
    /// the exit code of a success, so the text is what says it.
    let failure: String?

    init(output: String, failure: String? = nil) {
        self.output = output
        self.failure = failure
    }

    /// The refusal of a text of the daemon, when the text holds one.
    ///
    /// The daemon writes a refusal as `[!] …` and the refusal always
    /// starts the answer of the daemon (`src/misc/helpers.h:103-120`,
    /// `src/sketchybar.c:88-95`), so an answer that only holds `[!]` in a
    /// value is not a refusal.
    static func failure(in output: String) -> String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("[!]") else { return nil }
        let reason = text.dropFirst(3)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the daemon refused the call" : trimmed
    }
}

/// The runner of the calls of the daemon of SketchyBar.
///
/// The tests use a runner of their own, so the cases that need a daemon
/// can be held on a machine without one.
protocol LiveBarRunning {
    /// True when the daemon of SketchyBar answers.
    func daemonIsRunning() -> Bool
    /// The live values of an item, keyed by their path, or nil when the
    /// item is not on the live bar.
    func liveValues(of alias: String) -> [String: String]?
    /// Runs a call and answers what the daemon said.
    func run(_ command: LiveBarCommand) -> LiveBarCommandResult
}

/// The runner that runs the real binary of the daemon.
struct SketchyBarRunner: LiveBarRunning {
    /// The time a call may take before it is stopped.
    static let timeout: TimeInterval = 10

    /// The name of the binary, as the app runs it.
    static let executableName = "sketchybar"

    func daemonIsRunning() -> Bool {
        let result = run(LiveBarCommand(arguments: ["--query", "bar"]))
        guard result.failure == nil else { return false }
        // The client of the daemon exits with the code of a success and
        // without an answer when the daemon does not run
        // (`src/sketchybar.c:88-90`), so an empty answer means that the
        // daemon is not there.
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func liveValues(of alias: String) -> [String: String]? {
        let result = run(LiveBarCommand(arguments: ["--query", alias]))
        guard result.failure == nil else { return nil }
        let values = LiveBarQuery.values(in: result.output)
        return values.isEmpty ? nil : values
    }

    func run(_ command: LiveBarCommand) -> LiveBarCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [Self.executableName] + command.arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // The handler is set before the process starts: a process that ends
        // right away must not leave the semaphore unsignalled
        // (`src/sketchybar.c:88-95` exits as soon as the daemon does not
        // answer).
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return LiveBarCommandResult(
                output: "",
                failure: "The binary of SketchyBar could not be run: \(error.localizedDescription)"
            )
        }

        // The pipes are read while the call runs: the answer of a query of
        // a big bar does not fit into the buffer of a pipe, and the daemon
        // would wait for a reader that is not there.
        let outputBox = DataBox()
        let errorBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outputBox.data = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if finished.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                // The child ignores the signal, so it is killed.
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            // The wait is bounded: a child that holds the pipe open must
            // not hang the app.
            _ = group.wait(timeout: .now() + 1)
            return LiveBarCommandResult(
                output: "",
                failure: "sketchybar \(command.arguments.joined(separator: " ")) did not finish within \(Int(Self.timeout)) seconds and was stopped."
            )
        }
        group.wait()

        let text = String(data: outputBox.data, encoding: .utf8) ?? ""
        let errorText = String(data: errorBox.data, encoding: .utf8) ?? ""
        // The client of the daemon answers with the code of a failure when
        // the daemon refused the call (`src/sketchybar.c:88-95`), so the
        // code of the process says how the call went.
        if process.terminationStatus != 0 {
            let reason = LiveBarCommandResult.failure(in: errorText)
                ?? LiveBarCommandResult.failure(in: text)
                ?? "sketchybar \(command.arguments.joined(separator: " ")) exited with code \(process.terminationStatus)."
            return LiveBarCommandResult(output: text, failure: reason)
        }
        return LiveBarCommandResult(output: text,
                                    failure: LiveBarCommandResult.failure(in: errorText)
                                        ?? LiveBarCommandResult.failure(in: text))
    }
}

/// A box of data that a background queue fills.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// The reader of the reply of `sketchybar --query`.
///
/// The reply is close to JSON, but it is not JSON: the label and the icon
/// are written raw (`src/bar_item.c:1027-1041`) and only the quote and the
/// newline of the other values are escaped (`src/misc/helpers.h:83-103`),
/// and the refusal of the daemon is not JSON at all (`[!] …`,
/// `src/message.c:512`). The reader takes the values it can read and
/// leaves the rest alone. A reply that a raw quote broke is refused as a
/// whole, because the reader would read the rest of it wrong.
enum LiveBarQuery {
    /// The values of a reply, keyed by their path, such as `label.value`.
    static func values(in reply: String) -> [String: String] {
        var reader = Reader(text: reply)
        return reader.read()
    }

    /// The reader of a reply.
    private struct Reader {
        private let characters: [Character]
        private var index = 0
        private var path: [String] = []
        private var values: [String: String] = [:]
        /// True when the value that was read cannot be trusted.
        ///
        /// The daemon writes the label and the icon raw and escapes only
        /// the quote and the newline of the other values, so a value with
        /// a backslash in it cannot be read back with certainty. Such a
        /// value is left out, so the restore never writes back a value
        /// that was mis-read.
        private var valueIsReadable = true

        init(text: String) {
            characters = Array(text)
        }

        mutating func read() -> [String: String] {
            // The daemon writes the label and the icon raw, so a quote in
            // a value ends the string early and the rest of the reply is
            // read wrong. Such a reply has an odd count of quotes, and it
            // is refused: a value that was cut short is never stored, so
            // a Restore never writes back a value that was mis-read.
            guard quotesAreBalanced else { return [:] }
            skipSpaces()
            _ = readValue()
            return values
        }

        /// True when every quote of the reply is closed.
        ///
        /// The daemon escapes the quote of the values it escapes
        /// (`src/misc/helpers.h:83-103`), so a quote that follows a
        /// backslash does not count.
        private var quotesAreBalanced: Bool {
            var count = 0
            var escaped = false
            for character in characters {
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if character == "\"" { count += 1 }
            }
            return count % 2 == 0
        }

        /// Reads a value: an object, an array, a string or a bare word.
        ///
        /// The result is the text of the value and whether it can be read
        /// back with certainty.
        private mutating func readValue() -> (text: String, readable: Bool)? {
            skipSpaces()
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "{": readObject(); return nil
            case "[": readArray(); return nil
            case "\"":
                let text = readString()
                return (text, valueIsReadable)
            default:
                return (readBare(), true)
            }
        }

        /// Reads an object: the values of its members get the path of the
        /// member as their last part.
        private mutating func readObject() {
            index += 1
            while index < characters.count {
                skipSpaces()
                guard index < characters.count else { return }
                if characters[index] == "}" {
                    index += 1
                    return
                }
                guard characters[index] == "\"" else {
                    index += 1
                    continue
                }
                let key = readString()
                skipSpaces()
                guard index < characters.count, characters[index] == ":" else {
                    // The key has no value. The loop reads on, so a brace
                    // that ends the object is still seen.
                    continue
                }
                index += 1
                let previous = path
                path.append(key)
                let value = readValue()
                skipSpaces()
                // A member ends with a comma or with the end of the
                // object. A value that ends anywhere else was cut short by
                // a quote the daemon wrote raw, so it is not readable.
                let endsWell = index < characters.count
                    && (characters[index] == "," || characters[index] == "}")
                if let value, value.readable, endsWell {
                    store(value.text)
                }
                path = previous
                guard endsWell else {
                    index += 1
                    continue
                }
                if characters[index] == "," {
                    index += 1
                    continue
                }
                index += 1
                return
            }
        }

        /// Reads an array. The values of an array are of no use here, so
        /// they are read and thrown away.
        private mutating func readArray() {
            index += 1
            while index < characters.count {
                skipSpaces()
                guard index < characters.count else { return }
                if characters[index] == "]" {
                    index += 1
                    return
                }
                _ = readValue()
                skipSpaces()
                if index < characters.count, characters[index] == "," {
                    index += 1
                    continue
                }
                if index < characters.count, characters[index] == "]" {
                    index += 1
                    return
                }
            }
        }

        /// Reads a string.
        ///
        /// The daemon escapes the quote and the newline of a value and it
        /// leaves the backslash alone, so a backslash in a value means the
        /// value cannot be read back with certainty.
        private mutating func readString() -> String {
            index += 1
            var text = ""
            valueIsReadable = true
            while index < characters.count {
                let character = characters[index]
                if character == "\"" {
                    index += 1
                    return text
                }
                if character == "\\" {
                    index += 1
                    guard index < characters.count else { return text }
                    let next = characters[index]
                    index += 1
                    valueIsReadable = false
                    text.append("\\")
                    text.append(next)
                    continue
                }
                text.append(character)
                index += 1
            }
            return text
        }

        /// Reads a bare word, such as a number or `on`.
        private mutating func readBare() -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                if character == "," || character == "}" || character == "]" || character.isWhitespace {
                    break
                }
                text.append(character)
                index += 1
            }
            return text
        }

        /// Remembers a value under the path of the reader.
        private mutating func store(_ text: String) {
            guard !path.isEmpty else { return }
            values[path.joined(separator: ".")] = text
        }

        /// Skips the white space of the reply.
        private mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }
    }
}

/// The snapshot of the live bar.
///
/// The snapshot holds the live value of every property a push changed, so
/// the Restore can put them back. A script is never in the snapshot: a
/// script belongs to the config, not to the running bar.
struct LiveBarSnapshot: Codable, Equatable {
    /// One property of the live bar, with the value it had before the
    /// first push.
    struct Property: Codable, Equatable {
        /// The item the property belongs to. It is empty for a property
        /// of the bar.
        let alias: String
        /// The name of the property, such as `label`.
        let key: String
        /// The value the property had.
        let value: String
    }

    /// The moment the snapshot was taken.
    let createdAt: Date
    /// The properties of the snapshot.
    var properties: [Property]

    init(createdAt: Date = .now, properties: [Property] = []) {
        self.createdAt = createdAt
        self.properties = properties
    }

    /// True when the snapshot holds a value for the property.
    func holds(alias: String, key: String) -> Bool {
        properties.contains { $0.alias == alias && $0.key == key }
    }

    /// The snapshot without the properties that must never reach the
    /// daemon.
    ///
    /// The snapshot is written without a script, and it is read back
    /// through this, so a script can never reach the file. A name the
    /// daemon reads as a regular expression is taken out as well: the
    /// daemon would set every item that matches it
    /// (`src/message.c:628-631`), so a snapshot that was edited by hand
    /// must not make the Restore touch every item of the bar.
    var safeForRestore: LiveBarSnapshot {
        LiveBarSnapshot(
            createdAt: createdAt,
            properties: properties.filter {
                !LiveBarService.neverPushedKeys.contains($0.key.lowercased())
                    && !LiveBarService.isRegexAlias($0.alias)
            }
        )
    }
}

/// The file of the snapshot of the live bar.
///
/// The file lives in the Application Support of the app. It never lives
/// under the config of the user, and it holds nothing but the values of
/// the live bar.
struct LiveBarSnapshotStore: Sendable {
    /// The file of the snapshot.
    let url: URL

    init(appSupportRoot: URL? = nil) {
        let root = appSupportRoot ?? Self.defaultAppSupportRoot()
        url = root.appendingPathComponent("LiveBarSnapshot.json")
    }

    /// The folder of the app in the Application Support of the user.
    static func defaultAppSupportRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio")
    }

    /// True when a snapshot is on disk.
    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The snapshot on disk, when there is one.
    ///
    /// The scripts and the names the daemon reads as a regular
    /// expression are taken out of the snapshot on the way in, exactly as
    /// they are taken out on the way out: a snapshot that was edited by
    /// hand must not make the daemon run a script or set every item that
    /// matches a name on a Restore.
    func load() -> LiveBarSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(LiveBarSnapshot.self, from: data) else { return nil }
        return snapshot.safeForRestore
    }

    /// Writes the snapshot to disk.
    ///
    /// The folder of the snapshot belongs to the app alone and the file
    /// holds the values of the bar of the user, so neither of them is
    /// readable by the other users of the machine.
    func save(_ snapshot: LiveBarSnapshot) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot.safeForRestore)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the snapshot from disk.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The push of the previewed bar to the running SketchyBar.
enum LiveBarService {
    /// The properties that are never pushed.
    ///
    /// A script of the preview belongs to the config and not to the
    /// running bar, and a pushed script would run against the real bar.
    static let neverPushedKeys: Set<String> = ["script", "click_script"]

    /// The bar properties the automatic modes may push.
    ///
    /// `drawing` and `blur_radius` do not change the shape of the bar of
    /// the user, so the automatic modes may push them. Every other
    /// property of the bar changes the bar itself, so it is pushed only
    /// by the explicit action of the user.
    static let safeBarLeaves: Set<String> = ["drawing", "blur_radius"]

    /// The leaves of a text of an item, such as `label.color`.
    private static let textLeaves: Set<String> = [
        "color", "highlight", "highlight_color", "drawing", "align",
        "x_offset", "y_offset", "padding_left", "padding_right",
        "font", "width", "scroll_duration"
    ]

    /// The leaves of the background of an item.
    private static let backgroundLeaves: Set<String> = [
        "color", "border_color", "border_width", "height", "corner_radius",
        "padding_left", "padding_right", "x_offset", "y_offset", "clip", "drawing"
    ]

    /// The properties of the bar that the live bar can take.
    ///
    /// `clip` is not in it: the daemon refuses it (`src/message.c:449-450`).
    /// `position` is not in it: the position of the bar is structure and
    /// not a value, so it is never pushed.
    static let barLeaves: Set<String> = [
        "topmost", "sticky", "show_in_fullscreen", "blur_radius",
        "margin", "y_offset", "drawing", "color", "border_color", "border_width",
        "height", "corner_radius", "padding_left", "padding_right", "x_offset"
    ]

    /// The keys whose value the daemon reads as a boolean and that have a
    /// value of their own beside the boolean one.
    ///
    /// `topmost` has the level `window` and `updates` has `when_shown`.
    private static let booleanKeys: Set<String> = ["topmost", "updates"]

    /// True when the daemon reads the alias as a regular expression.
    ///
    /// The daemon treats a name that starts and ends with a slash as a
    /// regular expression and sets every item that matches it
    /// (`src/message.c:628-631`), so such an alias is never pushed.
    static func isRegexAlias(_ alias: String) -> Bool {
        alias.count > 1 && alias.hasPrefix("/") && alias.hasSuffix("/")
    }

    /// The path of the live bar a property of an item is read from.
    ///
    /// The path is nil when the live bar does not hold the property in a
    /// way that can be read back. Such a property is not pushed: a
    /// property that cannot be put back must not be changed.
    ///
    /// The position of an item has no path: the position is structure and
    /// not a value, so it is never pushed.
    static func livePath(of key: String) -> String? {
        let name = key.lowercased()
        if name == "label" { return "label.value" }
        if name == "icon" { return "icon.value" }

        guard let dot = name.firstIndex(of: ".") else {
            switch name {
            case "width": return "geometry.width"
            case "drawing": return "geometry.drawing"
            case "scroll_texts": return "geometry.scroll_texts"
            case "line_break": return "geometry.line_break"
            case "y_offset": return "geometry.y_offset"
            case "padding_left": return "geometry.padding_left"
            case "padding_right": return "geometry.padding_right"
            case "updates": return "scripting.updates"
            case "update_freq": return "scripting.update_freq"
            default: return nil
            }
        }

        let domain = String(name[..<dot])
        let leaf = String(name[name.index(after: dot)...])
        switch domain {
        case "label", "icon":
            return textLeaves.contains(leaf) ? "\(domain).\(leaf)" : nil
        case "background":
            return backgroundLeaves.contains(leaf) ? "geometry.background.\(leaf)" : nil
        default:
            return nil
        }
    }

    /// The name of a property of the bar, without its prefix.
    static func barLeaf(of key: String) -> String {
        var name = key.lowercased()
        if name.hasPrefix("bar.") { name = String(name.dropFirst(4)) }
        return name
    }

    /// True when the automatic modes may push the property of the bar.
    static func isSafeBarProperty(_ key: String) -> Bool {
        safeBarLeaves.contains(barLeaf(of: key))
    }

    /// True when the property of the bar changes the bar of the user.
    ///
    /// Such a property is pushed only by the explicit action of the user.
    static func isDestructiveBarProperty(_ key: String) -> Bool {
        barLeaves.contains(barLeaf(of: key)) && !isSafeBarProperty(key)
    }

    /// The path of the live bar a property of the bar is read from.
    ///
    /// The daemon writes the settings of the bar flat: the background of
    /// the bar is written with the keys of the bar itself and not under a
    /// `background` of its own (`src/bar_manager.c:1096-1119`,
    /// `src/background.c:261-297`), so the path of a property of the bar
    /// is its plain name. The item nests its background under its
    /// geometry (`src/bar_item.c:1049`), so the path of an item is not
    /// the same.
    static func liveBarPath(of key: String) -> String? {
        let name = barLeaf(of: key)
        guard barLeaves.contains(name) else { return nil }
        return name
    }

    /// True when the live value is the value of the config.
    ///
    /// The daemon writes a boolean as `on` or `off`
    /// (`src/misc/helpers.h:83-86`) and the config writes it as `true` or
    /// `false`, so both sides are read the way the daemon reads them
    /// (`src/misc/helpers.h:278-290`).
    static func sameValue(key: String, planned: String, live: String) -> Bool {
        let name = key.lowercased()
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        if booleanKeys.contains(leaf) || SketchyBarBoolean.isBooleanKey(name) {
            return normalisedBoolean(planned, leaf: leaf) == normalisedBoolean(live, leaf: leaf)
        }
        return planned == live
    }

    /// The value of a boolean, the way the daemon reads it.
    private static func normalisedBoolean(_ value: String, leaf: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch leaf {
        case "topmost" where text == "window":
            // The bar level of `topmost` is a value of its own
            // (`src/message.c:409-418`).
            return "true"
        case "updates" where text == "when_shown":
            return "when_shown"
        default:
            return SketchyBarBoolean.normalized(text) ?? text
        }
    }

    /// True when a live value can be put back with a call.
    ///
    /// The query of an item does not say which popup an item was in, so a
    /// position of `popup` cannot be put back and is left alone.
    static func canRestore(key: String, value: String) -> Bool {
        if key.lowercased() == "position" && value.lowercased() == "popup" { return false }
        return true
    }

    /// The items of a plan that the live bar can take.
    ///
    /// A file may declare several items, so the push is per declared item
    /// and never per file. A script is never pushed, the position of an
    /// item is never pushed, and a property whose live value cannot be
    /// read back is not pushed either.
    static func liveItems(of plan: BarRenderPlan) -> (items: [LiveBarItem], notes: [String]) {
        var items: [LiveBarItem] = []
        var notes: [String] = []
        var unreadable = 0
        var positions = 0
        var popups = 0
        var regexes = 0

        for item in plan.items {
            guard !item.alias.isEmpty else {
                notes.append("An item of the preview has no name, so it cannot be pushed to the live bar.")
                continue
            }
            if isRegexAlias(item.alias) {
                regexes += 1
                continue
            }
            var properties: [LiveBarProperty] = []
            for property in item.properties {
                let key = property.key.lowercased()
                if neverPushedKeys.contains(key) { continue }
                let isPosition = key == "position" || key.hasSuffix(".position")
                if isPosition {
                    // The position of an item is structure and not a value:
                    // pushing it would move the item into a popup or off
                    // the bar (`src/bar_item.c:468-496`).
                    positions += 1
                }
                if property.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().hasPrefix("popup") {
                    // A value that starts with `popup` puts the item into
                    // the popup of another item (`src/bar_item.c:1276-1289`).
                    popups += 1
                    continue
                }
                if isPosition { continue }
                guard livePath(of: property.key) != nil else {
                    unreadable += 1
                    continue
                }
                properties.append(LiveBarProperty(key: property.key, value: property.value))
            }
            guard !properties.isEmpty else { continue }
            items.append(LiveBarItem(alias: item.alias, properties: properties))
        }

        if positions > 0 {
            notes.append("\(positions) positions of the preview are structure and not values, so they were not pushed.")
        }
        if popups > 0 {
            notes.append("\(popups) values of the preview start with 'popup' and would put an item into a popup, so they were not pushed.")
        }
        if regexes > 0 {
            notes.append("\(regexes) items of the preview have a name the daemon reads as a regular expression, so they were not pushed.")
        }
        if unreadable > 0 {
            notes.append("\(unreadable) properties of the preview cannot be read back from the live bar, so they were not pushed.")
        }
        return (items, notes)
    }

    /// The properties of the bar that the automatic modes may push.
    ///
    /// The properties that change the bar of the user are not here: they
    /// are pushed only by the explicit action of the user.
    static func liveBarProperties(of plan: BarRenderPlan) -> [LiveBarProperty] {
        plan.bar.compactMap { property in
            guard isSafeBarProperty(property.key) else { return nil }
            guard liveBarPath(of: property.key) != nil else { return nil }
            return LiveBarProperty(key: property.key, value: property.value)
        }
    }

    /// The properties of the bar that change the bar of the user.
    ///
    /// They are pushed only by the explicit action of the user, and only
    /// after the user saw what changes.
    static func destructiveBarProperties(of plan: BarRenderPlan) -> [LiveBarProperty] {
        plan.bar.compactMap { property in
            guard isDestructiveBarProperty(property.key) else { return nil }
            guard liveBarPath(of: property.key) != nil else { return nil }
            return LiveBarProperty(key: property.key, value: property.value)
        }
    }

    /// The calls that push the items to the live bar.
    static func pushCommands(for items: [LiveBarItem], bar: [LiveBarProperty] = []) -> [LiveBarCommand] {
        var commands: [LiveBarCommand] = []
        if !bar.isEmpty { commands.append(LiveBarCommand.setBar(properties: bar)) }
        for item in items where !item.alias.isEmpty && !item.properties.isEmpty && !isRegexAlias(item.alias) {
            commands.append(LiveBarCommand.set(alias: item.alias, properties: item.properties))
        }
        return commands
    }

    /// The calls that put a snapshot back.
    static func restoreCommands(for snapshot: LiveBarSnapshot) -> [LiveBarCommand] {
        snapshot.properties
            .filter { canRestore(key: $0.key, value: $0.value) }
            .map { property in
                property.alias.isEmpty
                    ? LiveBarCommand.setBar(properties: [LiveBarProperty(key: property.key, value: property.value)])
                    : LiveBarCommand.set(alias: property.alias, properties: [LiveBarProperty(key: property.key, value: property.value)])
            }
    }

    /// What a push did.
    struct PushOutcome: Equatable {
        /// The number of items that were pushed.
        var pushedItems: Int = 0
        /// The number of properties that were pushed.
        var pushedProperties: Int = 0
        /// The messages about what the push left out.
        var notes: [String] = []
        /// The failures of the push.
        var failures: [String] = []
        /// True when the daemon of SketchyBar does not answer.
        var daemonIsMissing: Bool = false
        /// The values of the items after the push.
        ///
        /// The next push only looks at the items whose values differ from
        /// these, so a push does not ask the daemon about every item of
        /// the config.
        var known: [String: [String: String]] = [:]

        /// The message of the push, for the user.
        var message: String {
            var text = "Pushed \(pushedItems) items and \(pushedProperties) properties to the live SketchyBar."
            if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
            if !failures.isEmpty {
                text += " " + failures.joined(separator: " ")
                text += " The Restore button puts the live bar back."
            }
            return text
        }
    }

    /// What a restore did.
    struct RestoreOutcome: Equatable {
        /// The number of properties that were put back.
        var restoredProperties: Int = 0
        /// The messages about what could not be put back.
        var failures: [String] = []
        /// True when the daemon of SketchyBar does not answer.
        var daemonIsMissing: Bool = false
        /// False when there was no snapshot to put back.
        var hasSnapshot: Bool = true

        /// The message of the restore, for the user.
        var message: String {
            guard hasSnapshot else { return "There is no snapshot of the live bar, so there is nothing to put back." }
            if daemonIsMissing {
                return "SketchyBar is not running, so the live bar cannot be reached and nothing was put back."
            }
            var text = "Put \(restoredProperties) properties of the live SketchyBar back."
            if !failures.isEmpty { text += " " + failures.joined(separator: " ") }
            return text
        }
    }

    /// What a push would change.
    struct LiveBarChange {
        /// The items with the properties that really change.
        var items: [LiveBarItem] = []
        /// The properties of the bar that really change.
        var bar: [LiveBarProperty] = []
        /// The value the live bar had for every property that changes.
        var previous: [LiveBarSnapshot.Property] = []
        /// The values of the items the live bar already has.
        ///
        /// The next push only looks at the items whose values differ from
        /// these, so a push does not ask the daemon about every item of
        /// the config.
        var known: [String: [String: String]] = [:]
        /// The messages about what the push leaves out.
        var notes: [String] = []
    }

    /// Works out what a push of the plan would change.
    ///
    /// The live values are read from the daemon, so only the properties
    /// that really change are pushed. The `known` values are the values of
    /// the last push: the items whose values did not change are not read
    /// from the daemon again.
    static func change(of plan: BarRenderPlan,
                       runner: LiveBarRunning,
                       known: [String: [String: String]] = [:]) -> LiveBarChange {
        var change = LiveBarChange()
        let (items, notes) = liveItems(of: plan)
        change.notes += notes

        // The bar. Only the properties that the automatic modes may push
        // are here.
        let barProperties = liveBarProperties(of: plan)
        if !barProperties.isEmpty, let live = runner.liveValues(of: "bar") {
            for property in barProperties {
                guard let path = liveBarPath(of: property.key), let current = live[path] else { continue }
                guard !sameValue(key: property.key, planned: property.value, live: current) else { continue }
                change.bar.append(property)
                change.previous.append(LiveBarSnapshot.Property(alias: "", key: property.key, value: current))
            }
        }

        // The items. Only the items whose values changed are read from the
        // daemon, so a push costs one call per changed item.
        for item in items where changed(of: item, since: known) {
            guard let live = runner.liveValues(of: item.alias) else {
                change.notes.append("The item '\(item.alias)' is not on the live bar, so it was not pushed.")
                // The item stays a candidate, so the next push tries it
                // again: the item may come back later.
                continue
            }
            var changedProperties: [LiveBarProperty] = []
            for property in item.properties {
                guard let path = livePath(of: property.key), let current = live[path] else { continue }
                guard !sameValue(key: property.key, planned: property.value, live: current) else { continue }
                changedProperties.append(property)
                change.previous.append(LiveBarSnapshot.Property(alias: item.alias,
                                                               key: property.key,
                                                               value: current))
            }
            guard !changedProperties.isEmpty else {
                // The live bar already has these values, so the next push
                // does not have to ask about the item again.
                change.known[item.alias] = values(of: item)
                continue
            }
            change.items.append(LiveBarItem(alias: item.alias, properties: changedProperties))
        }

        return change
    }

    /// What a push of the plan would change, for the confirmation of the
    /// user.
    static func preview(of plan: BarRenderPlan, runner: LiveBarRunning) -> LiveBarPushPreview {
        guard runner.daemonIsRunning() else {
            return LiveBarPushPreview(itemCount: 0,
                                      propertyCount: 0,
                                      barPropertyCount: 0,
                                      notes: ["SketchyBar is not running, so there is nothing to push."])
        }
        let change = change(of: plan, runner: runner)
        return LiveBarPushPreview(
            itemCount: change.items.count,
            propertyCount: change.items.reduce(0) { $0 + $1.properties.count },
            barPropertyCount: change.bar.count,
            notes: change.notes
        )
    }

    /// The properties of the bar that change, with the value they have
    /// now.
    static func barChanges(of plan: BarRenderPlan, runner: LiveBarRunning) -> [LiveBarPropertyChange] {
        let properties = destructiveBarProperties(of: plan)
        guard !properties.isEmpty else { return [] }
        guard let live = runner.liveValues(of: "bar") else { return [] }
        var changes: [LiveBarPropertyChange] = []
        for property in properties {
            guard let path = liveBarPath(of: property.key), let current = live[path] else { continue }
            guard !sameValue(key: property.key, planned: property.value, live: current) else { continue }
            changes.append(LiveBarPropertyChange(key: property.key,
                                                 oldValue: current,
                                                 newValue: property.value))
        }
        return changes
    }

    /// Pushes the values of the preview to the live bar.
    ///
    /// The daemon is asked first: when it does not answer, nothing is
    /// pushed. The live values of the items are read before the push, so
    /// the snapshot holds the state the live bar had, and only the values
    /// that really changed are pushed.
    ///
    /// The `known` values are the values of the last push. Only the items
    /// whose values differ from them are read from the daemon, so a push
    /// does not ask about every item of the config.
    static func push(plan: BarRenderPlan,
                     snapshotStore: LiveBarSnapshotStore,
                     runner: LiveBarRunning,
                     known: [String: [String: String]] = [:]) -> PushOutcome {
        var outcome = PushOutcome()
        outcome.known = known

        guard runner.daemonIsRunning() else {
            outcome.daemonIsMissing = true
            outcome.failures.append("SketchyBar is not running, so the live bar cannot be reached and nothing was pushed.")
            return outcome
        }

        let change = change(of: plan, runner: runner, known: known)
        outcome.notes += change.notes
        outcome.known.merge(change.known) { _, new in new }

        var snapshot = snapshotStore.load() ?? LiveBarSnapshot()
        var newProperties: [LiveBarSnapshot.Property] = []
        for property in change.previous where !snapshot.holds(alias: property.alias, key: property.key) {
            newProperties.append(property)
        }

        var pending: [(command: LiveBarCommand, item: LiveBarItem?)] = []
        if !change.bar.isEmpty {
            pending.append((LiveBarCommand.setBar(properties: change.bar), nil))
        }
        for item in change.items {
            pending.append((LiveBarCommand.set(alias: item.alias, properties: item.properties), item))
        }

        // The snapshot is written before the first push, so a restart can
        // still put the live bar back.
        if !newProperties.isEmpty {
            snapshot.properties += newProperties
            do {
                try snapshotStore.save(snapshot)
            } catch {
                outcome.failures.append("The snapshot of the live bar could not be written (\(error.localizedDescription)), so nothing was pushed.")
                return outcome
            }
        }

        for entry in pending {
            let result = runner.run(entry.command)
            if let failure = result.failure {
                // The item stays a candidate, so the next push tries it
                // again.
                outcome.failures.append("'\(entry.command.displayText)' was refused: \(failure)")
                continue
            }
            if let item = entry.item {
                outcome.pushedItems += 1
                outcome.pushedProperties += item.properties.count
                outcome.known[item.alias] = values(of: item)
            } else {
                outcome.pushedProperties += entry.command.arguments.count - 1
            }
        }

        return outcome
    }

    /// Pushes the properties of the bar to the live bar.
    ///
    /// The properties of the bar change the bar of the user, so this is
    /// the only path that pushes them and it runs only when the user
    /// asked for it.
    static func pushBarSettings(plan: BarRenderPlan,
                                snapshotStore: LiveBarSnapshotStore,
                                runner: LiveBarRunning) -> PushOutcome {
        var outcome = PushOutcome()

        guard runner.daemonIsRunning() else {
            outcome.daemonIsMissing = true
            outcome.failures.append("SketchyBar is not running, so the live bar cannot be reached and nothing was pushed.")
            return outcome
        }

        let properties = destructiveBarProperties(of: plan)
        guard !properties.isEmpty else { return outcome }

        guard let live = runner.liveValues(of: "bar") else {
            outcome.failures.append("The live bar could not be read, so the settings of the bar were not pushed.")
            return outcome
        }

        var changed: [LiveBarProperty] = []
        var newProperties: [LiveBarSnapshot.Property] = []
        for property in properties {
            guard let path = liveBarPath(of: property.key), let current = live[path] else { continue }
            guard !sameValue(key: property.key, planned: property.value, live: current) else { continue }
            changed.append(property)
            newProperties.append(LiveBarSnapshot.Property(alias: "", key: property.key, value: current))
        }
        guard !changed.isEmpty else { return outcome }

        var snapshot = snapshotStore.load() ?? LiveBarSnapshot()
        let fresh = newProperties.filter { !snapshot.holds(alias: $0.alias, key: $0.key) }
        if !fresh.isEmpty {
            snapshot.properties += fresh
            do {
                try snapshotStore.save(snapshot)
            } catch {
                outcome.failures.append("The snapshot of the live bar could not be written (\(error.localizedDescription)), so nothing was pushed.")
                return outcome
            }
        }

        let command = LiveBarCommand.setBar(properties: changed)
        let result = runner.run(command)
        if let failure = result.failure {
            outcome.failures.append("'\(command.displayText)' was refused: \(failure)")
            return outcome
        }
        outcome.pushedProperties += changed.count
        return outcome
    }

    /// True when the values of an item differ from the values of the last
    /// push.
    private static func changed(of item: LiveBarItem, since known: [String: [String: String]]) -> Bool {
        guard let previous = known[item.alias] else { return true }
        return item.properties.contains { previous[$0.key] != $0.value }
    }

    /// The values of an item, keyed by the name of the property.
    private static func values(of item: LiveBarItem) -> [String: String] {
        var values: [String: String] = [:]
        for property in item.properties {
            values[property.key] = property.value
        }
        return values
    }

    /// Puts the live bar back to the state the snapshot holds.
    ///
    /// Every property is put back on its own, so a property the daemon
    /// refuses does not stop the others. A property that could not be put
    /// back stays in the snapshot, so the user can try again.
    static func restore(snapshotStore: LiveBarSnapshotStore, runner: LiveBarRunning) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        guard let snapshot = snapshotStore.load() else {
            outcome.hasSnapshot = false
            return outcome
        }

        guard runner.daemonIsRunning() else {
            outcome.daemonIsMissing = true
            outcome.failures.append("SketchyBar is not running, so the live bar cannot be reached and nothing was put back.")
            return outcome
        }

        var remaining: [LiveBarSnapshot.Property] = []
        for property in snapshot.properties {
            guard canRestore(key: property.key, value: property.value) else {
                outcome.failures.append("The property '\(property.key)' of \(name(of: property.alias)) could not be put back, because the live bar does not say which popup it was in.")
                remaining.append(property)
                continue
            }
            let command = property.alias.isEmpty
                ? LiveBarCommand.setBar(properties: [LiveBarProperty(key: property.key, value: property.value)])
                : LiveBarCommand.set(alias: property.alias, properties: [LiveBarProperty(key: property.key, value: property.value)])
            let result = runner.run(command)
            if let failure = result.failure {
                outcome.failures.append("The property '\(property.key)' of \(name(of: property.alias)) could not be put back: \(failure)")
                remaining.append(property)
                continue
            }
            outcome.restoredProperties += 1
        }

        // The snapshot keeps what could not be put back, so the Restore
        // button stays there for the rest.
        if remaining.isEmpty {
            snapshotStore.clear()
        } else {
            var kept = snapshot
            kept.properties = remaining
            try? snapshotStore.save(kept)
        }

        return outcome
    }

    /// The name of the owner of a property, for the user.
    private static func name(of alias: String) -> String {
        alias.isEmpty ? "the bar" : "the item '\(alias)'"
    }
}

/// The throttle of the live push.
///
/// The push waits for the interval, so a run of changes is one push and
/// not one push per keystroke. The throttle also runs while the user
/// keeps typing: a change that comes in while the push waits does not
/// push the wait away, so the bar follows the edits of the user while
/// the user writes.
final class LiveBarDebouncer {
    /// The time between two pushes.
    static let interval: TimeInterval = 0.6

    private let queue = DispatchQueue(label: "com.sketchybarstudio.live-bar.debounce")
    /// The action that runs at the next run.
    private var pending: (() -> Void)?
    /// The work of the run that waits, when there is one.
    private var work: DispatchWorkItem?
    /// The moment of the last run.
    private var lastRun: TimeInterval = 0

    /// Schedules the action and forgets the one before it.
    func schedule(_ action: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = action
            self.arm()
        }
    }

    /// Forgets the scheduled action.
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.work?.cancel()
            self.work = nil
            self.pending = nil
        }
    }

    /// Makes sure a run waits for the action.
    ///
    /// A run that waits is not pushed away by a later action, so the
    /// action runs at most once per interval.
    private func arm() {
        guard work == nil else { return }
        let interval = UInt64(Self.interval * 1_000_000_000)
        var delay = interval
        if lastRun > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            let since = now - UInt64(lastRun * 1_000_000_000)
            delay = since >= interval ? 0 : interval - since
        }
        let work = DispatchWorkItem { [weak self] in self?.run() }
        self.work = work
        queue.asyncAfter(deadline: .now() + Double(delay) / 1_000_000_000, execute: work)
    }

    /// Runs the action that waits.
    private func run() {
        work = nil
        lastRun = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let action = pending
        pending = nil
        action?()
        // A change that came in while the action ran waits for the next
        // run.
        if pending != nil { arm() }
    }
}

/// What a push of the previewed bar would change.
struct LiveBarPushPreview: Equatable {
    /// The number of items the push carries.
    let itemCount: Int
    /// The number of the properties of the items the push carries.
    let propertyCount: Int
    /// The number of the properties of the bar the push carries.
    let barPropertyCount: Int
    /// The messages about what the push leaves out.
    let notes: [String]

    init(itemCount: Int,
         propertyCount: Int,
         barPropertyCount: Int = 0,
         notes: [String] = []) {
        self.itemCount = itemCount
        self.propertyCount = propertyCount
        self.barPropertyCount = barPropertyCount
        self.notes = notes
    }

    /// The sentence of the confirmation.
    var summary: String {
        var text = "\(itemCount) items and \(propertyCount) properties of the preview"
        if barPropertyCount > 0 {
            text += ", and \(barPropertyCount) properties of the bar"
        }
        text += " will be pushed to your live SketchyBar."
        if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
        return text
    }
}

/// One property of the bar that changes, with the value it has now.
struct LiveBarPropertyChange: Equatable {
    /// The name of the property, such as `bar.height`.
    let key: String
    /// The value the property has now.
    let oldValue: String
    /// The value the property gets.
    let newValue: String

    /// The property as the user reads it.
    var text: String {
        "\(key): \(oldValue) → \(newValue)"
    }
}

/// What a push carries.
enum LiveBarPushRequest {
    /// The values of the items of the preview.
    ///
    /// The flag says that only the structured values of the config are
    /// pushed: a raw source draft is a whole file, and a half-typed file
    /// must not reach the live bar.
    case items(structuredOnly: Bool)
    /// The settings of the bar itself.
    case barSettings

    /// True when the push carries the structured values only.
    var structuredOnly: Bool {
        switch self {
        case .items(let structuredOnly): return structuredOnly
        case .barSettings: return true
        }
    }

    /// True when the push carries the values of the items.
    ///
    /// The values of the items are the ones the live update mode pushes,
    /// so they follow the mode. The settings of the bar are pushed by an
    /// explicit action of the user, so the mode does not stop them.
    var pushesItems: Bool {
        if case .items = self { return true }
        return false
    }
}

/// A push that waits for the confirmation of the user.
struct PendingLiveBarPush {
    /// What the push would change.
    let preview: LiveBarPushPreview
    /// What the push carries.
    ///
    /// The push runs the way the request says and not the way the
    /// properties say: a push of the settings of the bar that changes
    /// nothing is a push of the settings of the bar and not a push of the
    /// items.
    let request: LiveBarPushRequest
    /// The properties of the bar that change, with the value they have
    /// now. It is empty for a push of the values of the items.
    let barChanges: [LiveBarPropertyChange]
    /// The name of the config the push belongs to.
    let configName: String
    /// The mode of the live bar when the push was prepared.
    ///
    /// A push of the items runs only in the mode it was prepared in, so
    /// a mode that the user changed while the dialog was open stops the
    /// push.
    let mode: LiveUpdateMode

    init(preview: LiveBarPushPreview,
         request: LiveBarPushRequest,
         barChanges: [LiveBarPropertyChange] = [],
         configName: String = "",
         mode: LiveUpdateMode = .never) {
        self.preview = preview
        self.request = request
        self.barChanges = barChanges
        self.configName = configName
        self.mode = mode
    }

    /// True when the push changes the bar of the user itself.
    var changesTheBar: Bool { !request.pushesItems }

    /// The sentence of the confirmation.
    ///
    /// The push of the bar itself names the config and says what changes,
    /// because it changes the bar the user looks at.
    var summary: String {
        guard changesTheBar else { return preview.summary }
        var text = "The bar settings of \(configName)"
        if barChanges.isEmpty {
            text += " do not change on your live SketchyBar."
        } else {
            text += " will change on your live SketchyBar: "
            text += barChanges.map(\.text).joined(separator: ", ")
            text += "."
        }
        if !preview.notes.isEmpty { text += " " + preview.notes.joined(separator: " ") }
        return text
    }
}

extension SketchyBarStore {
    /// The source the preview pane renders.
    ///
    /// The source of the pane is the one the user picked, or the config
    /// the app has open.
    var liveBarSource: BarRenderSource? {
        if let source = barRenderSource { return source }
        if let id = selectedConfig?.id { return .config(id) }
        return configs.first.map { .config($0.id) }
    }

    /// The name of the source of the preview, for the user.
    var liveBarSourceName: String {
        switch liveBarSource {
        case .config(let id):
            return "the config '\(configs.first { $0.id == id }?.name ?? id)'"
        case .profile(let profilePath):
            return "the profile '\(libraryProfiles.first { $0.profile.id == profilePath }?.profile.name ?? profilePath)'"
        case nil:
            return "no config"
        }
    }

    /// True when the source of the preview is the config the live bar runs.
    ///
    /// The values of another config would change the bar of the user
    /// without the config of the user saying so, so the push is allowed
    /// for the live config only.
    var isLiveBarSourceLive: Bool {
        guard case .config(let id) = liveBarSource else { return false }
        guard let config = configs.first(where: { $0.id == id }) else { return false }
        return configSwitchService.isLive(config: config)
    }

    /// Why the push is not allowed, when it is not.
    var liveBarBlockedReason: String? {
        guard !isLiveBarSourceLive else { return nil }
        return "Only the live config of SketchyBar can be pushed to the live bar, and the preview shows \(liveBarSourceName), so the push is off."
    }

    /// The files of the source, with the drafts of the app.
    ///
    /// The files of the config the app has open carry the drafts of the
    /// app, so the push carries the values the user sees. Every other
    /// config and every profile is read from disk.
    ///
    /// The files of a source that is not the live config are never
    /// returned: the push may only carry the values of the live config.
    func liveBarFiles(structuredOnly: Bool) -> [BarRenderFile] {
        guard isLiveBarSourceLive else { return [] }
        guard let source = liveBarSource else { return [] }
        if case .config(let id) = source, id == selectedConfig?.id {
            return filesInPreviewOrder.map { file in
                BarRenderFile(url: file.url,
                              kind: file.kind,
                              contents: structuredOnly ? structuredContents(for: file) : effectiveContents(for: file))
            }
        }

        guard let root = barRenderRoot(for: source) else { return [] }
        let locator = SketchyBarConfigLocator()
        return locator.configFiles(in: root).compactMap { url in
            guard let kind = locator.kind(for: url) else { return nil }
            return BarRenderFile(url: url, kind: kind, contents: nil)
        }
    }

    /// The tree of the source, for the push.
    ///
    /// The tree is the tree of the preview: the plan of every file is
    /// combined, so the items keep the order of the files.
    func liveBarPlan(structuredOnly: Bool) -> BarRenderPlan {
        var combined = BarRenderPlan(defaults: [], bar: [], items: [], warnings: [])

        for file in liveBarFiles(structuredOnly: structuredOnly) {
            guard let contents = file.contents ?? (try? String(contentsOf: file.url, encoding: .utf8)) else { continue }
            // A `.lua` file is Lua. A file without an extension is decided
            // by its text, the same way the bridge decides it.
            let filePlan = file.kind == .lua || LuaSourceDetection.isLua(contents)
                ? PreviewConfigBridge.plan(forLua: contents)
                : PreviewConfigBridge.plan(forShell: contents)
            combined = combined.combined(with: filePlan)
        }

        return combined
    }
}
