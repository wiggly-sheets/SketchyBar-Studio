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
    static func setBar(properties: [LiveBarProperty]) -> LiveBarCommand {
        LiveBarCommand(arguments: ["--bar"] + properties.map { "\($0.key)=\($0.value)" })
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
    static func failure(in output: String) -> String? {
        guard let start = output.range(of: "[!]") else { return nil }
        let text = output[start.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "the daemon refused the call" : reason
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

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            group.wait()
            return LiveBarCommandResult(
                output: "",
                failure: "sketchybar \(command.arguments.joined(separator: " ")) did not finish within \(Int(Self.timeout)) seconds and was stopped."
            )
        }
        group.wait()

        let text = String(data: outputBox.data, encoding: .utf8) ?? ""
        let errorText = String(data: errorBox.data, encoding: .utf8) ?? ""
        let combined = text + errorText
        return LiveBarCommandResult(output: text, failure: LiveBarCommandResult.failure(in: combined))
    }
}

/// A box of data that a background queue fills.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// The reader of the reply of `sketchybar --query`.
///
/// The reply is close to JSON, but it is not JSON: a value that holds a
/// backslash is not escaped (`src/misc/helpers.h:83-103`), and the refusal
/// of the daemon is not JSON at all (`[!] …`, `src/message.c:512`). The
/// reader takes the values it can read and leaves the rest alone.
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

        init(text: String) {
            characters = Array(text)
        }

        mutating func read() -> [String: String] {
            skipSpaces()
            readValue(storing: true)
            return values
        }

        /// Reads a value: an object, an array, a string or a bare word.
        private mutating func readValue(storing: Bool) {
            skipSpaces()
            guard index < characters.count else { return }
            switch characters[index] {
            case "{": readObject()
            case "[": readArray()
            case "\"":
                let text = readString()
                if storing { store(text) }
            default:
                let text = readBare()
                if storing { store(text) }
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
                    index += 1
                    continue
                }
                index += 1
                let previous = path
                path.append(key)
                readValue(storing: true)
                path = previous
                skipSpaces()
                if index < characters.count, characters[index] == "," {
                    index += 1
                    continue
                }
                if index < characters.count, characters[index] == "}" {
                    index += 1
                    return
                }
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
                readValue(storing: false)
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

        /// Reads a string. The daemon escapes the quote and the newline of
        /// a value, and it leaves the backslash alone, so a backslash that
        /// is not one of the two keeps itself and the character behind it.
        private mutating func readString() -> String {
            index += 1
            var text = ""
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
                    if next == "n" {
                        text.append("\n")
                    } else if next == "\"" {
                        text.append("\"")
                    } else {
                        text.append("\\")
                        text.append(next)
                    }
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

    /// The snapshot without the scripts.
    ///
    /// The snapshot is written without a script, and it is read back
    /// through this, so a script can never reach the file.
    var withoutScripts: LiveBarSnapshot {
        LiveBarSnapshot(
            createdAt: createdAt,
            properties: properties.filter {
                !LiveBarService.neverPushedKeys.contains($0.key.lowercased())
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
    func load() -> LiveBarSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveBarSnapshot.self, from: data)
    }

    /// Writes the snapshot to disk.
    func save(_ snapshot: LiveBarSnapshot) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot.withoutScripts)
        try data.write(to: url, options: .atomic)
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
    private static let barLeaves: Set<String> = [
        "position", "topmost", "sticky", "show_in_fullscreen", "blur_radius",
        "margin", "y_offset", "drawing", "color", "border_color", "border_width",
        "height", "corner_radius", "padding_left", "padding_right", "x_offset", "clip"
    ]

    /// The path of the live bar a property of an item is read from.
    ///
    /// The path is nil when the live bar does not hold the property in a
    /// way that can be read back. Such a property is not pushed: a
    /// property that cannot be put back must not be changed.
    static func livePath(of key: String) -> String? {
        let name = key.lowercased()
        if name == "label" { return "label.value" }
        if name == "icon" { return "icon.value" }

        guard let dot = name.firstIndex(of: ".") else {
            switch name {
            case "position": return "geometry.position"
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

    /// The path of the live bar a property of the bar is read from.
    static func liveBarPath(of key: String) -> String? {
        var name = key.lowercased()
        if name.hasPrefix("bar.") { name = String(name.dropFirst(4)) }
        return barLeaves.contains(name) ? name : nil
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
    /// and never per file. A script is never pushed, and a property whose
    /// live value cannot be read back is not pushed either.
    static func liveItems(of plan: BarRenderPlan) -> (items: [LiveBarItem], notes: [String]) {
        var items: [LiveBarItem] = []
        var notes: [String] = []
        var unreadable = 0

        for item in plan.items {
            guard !item.alias.isEmpty else {
                notes.append("An item of the preview has no name, so it cannot be pushed to the live bar.")
                continue
            }
            var properties: [LiveBarProperty] = []
            for property in item.properties {
                if neverPushedKeys.contains(property.key.lowercased()) { continue }
                guard livePath(of: property.key) != nil else {
                    unreadable += 1
                    continue
                }
                properties.append(LiveBarProperty(key: property.key, value: property.value))
            }
            guard !properties.isEmpty else { continue }
            items.append(LiveBarItem(alias: item.alias, properties: properties))
        }

        if unreadable > 0 {
            notes.append("\(unreadable) properties of the preview cannot be read back from the live bar, so they were not pushed.")
        }
        return (items, notes)
    }

    /// The properties of the bar that the live bar can take.
    static func liveBarProperties(of plan: BarRenderPlan) -> [LiveBarProperty] {
        plan.bar.compactMap { property in
            guard liveBarPath(of: property.key) != nil else { return nil }
            return LiveBarProperty(key: property.key, value: property.value)
        }
    }

    /// The calls that push the items to the live bar.
    static func pushCommands(for items: [LiveBarItem], bar: [LiveBarProperty] = []) -> [LiveBarCommand] {
        var commands: [LiveBarCommand] = []
        if !bar.isEmpty { commands.append(LiveBarCommand.setBar(properties: bar)) }
        for item in items where !item.alias.isEmpty && !item.properties.isEmpty {
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
        let (items, notes) = liveItems(of: plan)
        outcome.notes += notes
        outcome.known = known

        guard runner.daemonIsRunning() else {
            outcome.daemonIsMissing = true
            outcome.failures.append("SketchyBar is not running, so the live bar cannot be reached and nothing was pushed.")
            return outcome
        }

        var snapshot = snapshotStore.load() ?? LiveBarSnapshot()
        var newProperties: [LiveBarSnapshot.Property] = []
        var pending: [(command: LiveBarCommand, item: LiveBarItem?)] = []

        // The bar.
        let barProperties = liveBarProperties(of: plan)
        if !barProperties.isEmpty, let live = runner.liveValues(of: "bar") {
            var changedBar: [LiveBarProperty] = []
            for property in barProperties {
                guard let path = liveBarPath(of: property.key), let current = live[path] else { continue }
                guard current != property.value else { continue }
                changedBar.append(property)
                if !snapshot.holds(alias: "", key: property.key) {
                    newProperties.append(LiveBarSnapshot.Property(alias: "", key: property.key, value: current))
                }
            }
            if !changedBar.isEmpty {
                pending.append((LiveBarCommand.setBar(properties: changedBar), nil))
                outcome.pushedProperties += changedBar.count
            }
        }

        // The items. Only the items whose values changed are read from the
        // daemon, so a push costs one call per changed item.
        for item in items where changed(of: item, since: known) {
            guard let live = runner.liveValues(of: item.alias) else {
                outcome.notes.append("The item '\(item.alias)' is not on the live bar, so it was not pushed.")
                outcome.known[item.alias] = values(of: item)
                continue
            }
            var changedProperties: [LiveBarProperty] = []
            for property in item.properties {
                guard let path = livePath(of: property.key), let current = live[path] else { continue }
                guard current != property.value else { continue }
                changedProperties.append(property)
                if !snapshot.holds(alias: item.alias, key: property.key) {
                    newProperties.append(LiveBarSnapshot.Property(alias: item.alias,
                                                                   key: property.key,
                                                                   value: current))
                }
            }
            guard !changedProperties.isEmpty else {
                // The live bar already has these values.
                outcome.known[item.alias] = values(of: item)
                continue
            }
            pending.append((LiveBarCommand.set(alias: item.alias, properties: changedProperties), item))
            outcome.pushedItems += 1
            outcome.pushedProperties += changedProperties.count
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
                outcome.known[item.alias] = values(of: item)
            }
        }

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

/// The debounce of the live push.
///
/// The push waits for the interval, so a run of changes is one push and
/// not one push per keystroke.
final class LiveBarDebouncer {
    /// The time the push waits.
    static let interval: TimeInterval = 0.6

    private let queue = DispatchQueue(label: "com.sketchybarstudio.live-bar.debounce")
    private var work: DispatchWorkItem?

    /// Schedules the action and forgets the one before it.
    func schedule(_ action: @escaping () -> Void) {
        work?.cancel()
        let work = DispatchWorkItem(block: action)
        self.work = work
        queue.asyncAfter(deadline: .now() + Self.interval, execute: work)
    }

    /// Forgets the scheduled action.
    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// What a push of the previewed bar would change.
struct LiveBarPushPreview: Equatable {
    /// The number of items the push carries.
    let itemCount: Int
    /// The number of properties the push carries.
    let propertyCount: Int
    /// The messages about what the push leaves out.
    let notes: [String]

    /// The sentence of the confirmation.
    var summary: String {
        var text = "\(itemCount) items and \(propertyCount) properties of the preview will be pushed to your live SketchyBar."
        if !notes.isEmpty { text += " " + notes.joined(separator: " ") }
        return text
    }
}

/// A push that waits for the confirmation of the user.
struct PendingLiveBarPush {
    /// What the push would change.
    let preview: LiveBarPushPreview
    /// True when the push carries the structured values only.
    let structuredOnly: Bool
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

    /// The files of the source, with the drafts of the app.
    ///
    /// The files of the config the app has open carry the drafts of the
    /// app, so the push carries the values the user sees. Every other
    /// config and every profile is read from disk.
    func liveBarFiles(structuredOnly: Bool) -> [BarRenderFile] {
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
