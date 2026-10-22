import Foundation

/// How a config names the theme it uses.
enum BarThemePattern: Equatable {
    /// A pointer file in `themes/` names a theme `.lua` file.
    case themedPointer(name: String)
    /// The config has a `themes/` folder but no pointer file.
    case themedPointerMissing
    /// The config has no `themes/` folder.
    case noThemesFolder
}

/// A top level `key = 0x…` entry of a theme file. The range points at the
/// value inside the line, so a rewrite keeps the indentation and the comment.
struct BarThemeEntry: Equatable {
    let key: String
    let value: String
    let lineIndex: Int
    let valueRange: NSRange
}

/// The theme file the pointer names, with its text and its hex entries.
struct BarThemeFile: Equatable {
    let name: String
    let url: URL
    let contents: String
    let entries: [BarThemeEntry]
}

struct BarThemeApplyResult: Equatable {
    let themeName: String
    let wroteThemeFile: Bool
    let wrotePointer: Bool
}

enum BarThemeError: LocalizedError, Equatable {
    case noThemesFolder
    case pointerMissing
    case activeThemeMissing(String)
    case targetThemeExists(String)
    case invalidThemeName(String)
    case noPreviousTheme

    var errorDescription: String? {
        switch self {
        case .noThemesFolder:
            return "This config has no themes folder. Bar theme switching needs a themes/ folder with a theme pointer file."
        case .pointerMissing:
            return "This config has a themes folder but no pointer file. A pointer file holds one theme name and is not a .lua or .sh file."
        case .activeThemeMissing(let name):
            return "The active theme file themes/\(name).lua is missing or cannot be read."
        case .targetThemeExists(let name):
            return "themes/\(name).lua already exists with different content. A theme you wrote is never overwritten."
        case .invalidThemeName(let name):
            return "The theme name \"\(name)\" cannot be used as a file name."
        case .noPreviousTheme:
            return "No previous theme is stored for this config."
        }
    }
}

/// Reads the theme pattern of a config, writes a palette as a new theme file,
/// and puts the pointer back.
struct BarThemeService {
    static let pointerFileName = "current_theme"

    private let configRoot: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let replacer: SafeFileReplacer
    private let backupService: ConfigBackupService

    init(configRoot: URL, fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        self.configRoot = configRoot
        self.fileManager = fileManager
        self.defaults = defaults
        self.replacer = SafeFileReplacer(fileManager: fileManager)
        self.backupService = ConfigBackupService(fileManager: fileManager)
    }

    // MARK: - Detection

    var themesDirectory: URL {
        configRoot.appendingPathComponent("themes", isDirectory: true)
    }

    func detect() -> BarThemePattern {
        guard isDirectory(themesDirectory) else { return .noThemesFolder }
        guard let pointer = pointerCandidate() else { return .themedPointerMissing }
        return .themedPointer(name: pointer.name)
    }

    /// The theme the pointer names, or nil when the pattern or the file is
    /// missing.
    func activeTheme() -> BarThemeFile? {
        guard case let .themedPointer(name) = detect() else { return nil }
        return themeFile(named: name)
    }

    func themeFile(named name: String) -> BarThemeFile? {
        let url = themesDirectory.appendingPathComponent(name + ".lua")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return BarThemeFile(
            name: name,
            url: url,
            contents: contents,
            entries: Self.hexEntries(in: contents)
        )
    }

    private func pointerCandidate() -> (url: URL, name: String)? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: themesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates: [(url: URL, name: String)] = files.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard ext != "lua", ext != "sh" else { return nil }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return nil
            }

            let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r"),
                  Self.isValidThemeName(name) else {
                return nil
            }
            return (url, name)
        }

        if let named = candidates.first(where: { $0.url.lastPathComponent == Self.pointerFileName }) {
            return named
        }
        return candidates.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }.first
    }

    // MARK: - Apply

    @discardableResult
    func apply(_ palette: BarPalette) throws -> BarThemeApplyResult {
        guard isDirectory(themesDirectory) else { throw BarThemeError.noThemesFolder }
        guard let pointer = pointerCandidate() else { throw BarThemeError.pointerMissing }
        guard let active = themeFile(named: pointer.name) else {
            throw BarThemeError.activeThemeMissing(pointer.name)
        }
        guard Self.isValidThemeName(palette.displayName) else {
            throw BarThemeError.invalidThemeName(palette.displayName)
        }

        let contents = renderedThemeContents(for: palette, from: active)
        let targetURL = themesDirectory.appendingPathComponent(palette.displayName + ".lua")
        var wroteThemeFile = false

        if replacer.itemExists(at: targetURL) {
            guard let existing = try? String(contentsOf: targetURL, encoding: .utf8) else {
                throw BarThemeError.targetThemeExists(palette.displayName)
            }
            guard existing == contents else {
                throw BarThemeError.targetThemeExists(palette.displayName)
            }
        } else {
            try write(contents, to: targetURL, permissionsFrom: active.url)
            wroteThemeFile = true
        }

        let pointerText = try String(contentsOf: pointer.url, encoding: .utf8)
        let newPointerText = palette.displayName + Self.newlineSuffix(of: pointerText)
        var wrotePointer = false

        if newPointerText != pointerText {
            try writePointer(newPointerText, at: pointer.url)
            defaults.set(pointerText, forKey: previousPointerKey)
            wrotePointer = true
        }

        return BarThemeApplyResult(
            themeName: palette.displayName,
            wroteThemeFile: wroteThemeFile,
            wrotePointer: wrotePointer
        )
    }

    // MARK: - Revert

    func previousThemeName() -> String? {
        guard let stored = defaults.string(forKey: previousPointerKey) else { return nil }
        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { return nil }
        return name
    }

    /// Puts the pointer file back to the value captured before the last
    /// apply. The theme files are not touched.
    @discardableResult
    func restorePreviousTheme() throws -> String {
        guard let stored = defaults.string(forKey: previousPointerKey) else {
            throw BarThemeError.noPreviousTheme
        }
        guard let pointer = pointerCandidate() else { throw BarThemeError.pointerMissing }

        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidThemeName(name) else { throw BarThemeError.invalidThemeName(name) }

        let current = try String(contentsOf: pointer.url, encoding: .utf8)
        if current != stored {
            try writePointer(stored, at: pointer.url)
        }
        defaults.removeObject(forKey: previousPointerKey)
        return name
    }

    // MARK: - Rendering

    /// Rewrites the hex values of the active theme and keeps every other byte:
    /// the key set, the key order, the comments, the nested tables and the
    /// functions.
    func renderedThemeContents(for palette: BarPalette, from active: BarThemeFile) -> String {
        var assignments: [(entry: BarThemeEntry, role: BarPalette.Role)] = []
        var accentUsed = false
        var remaining: [BarThemeEntry] = []

        for entry in active.entries {
            if let role = Self.heuristicRole(for: entry.key, accentUsed: accentUsed) {
                assignments.append((entry, role))
                if role == .accent || role == .accentSecondary {
                    accentUsed = true
                }
            } else {
                remaining.append(entry)
            }
        }

        let byLuminance = remaining.sorted { left, right in
            let leftValue = Self.luminance(left.value)
            let rightValue = Self.luminance(right.value)
            return leftValue == rightValue ? left.lineIndex < right.lineIndex : leftValue < rightValue
        }

        if byLuminance.count == 1 {
            assignments.append((byLuminance[0], .muted))
        } else if byLuminance.count >= 2 {
            assignments.append((byLuminance[0], .background))
            assignments.append((byLuminance[byLuminance.count - 1], .foreground))
            for entry in byLuminance.dropFirst().dropLast() {
                assignments.append((entry, .muted))
            }
        }

        var lines = active.contents.components(separatedBy: "\n")
        for (entry, role) in assignments {
            guard let replacement = Self.replacement(for: entry, role: role, palette: palette) else { continue }
            guard lines.indices.contains(entry.lineIndex) else { continue }

            let rawLine = lines[entry.lineIndex]
            let hasCarriageReturn = rawLine.hasSuffix("\r")
            let line = hasCarriageReturn ? String(rawLine.dropLast()) : rawLine
            let updated = (line as NSString).replacingCharacters(in: entry.valueRange, with: replacement)
            lines[entry.lineIndex] = updated + (hasCarriageReturn ? "\r" : "")
        }
        return lines.joined(separator: "\n")
    }

    private static func heuristicRole(for key: String, accentUsed: Bool) -> BarPalette.Role? {
        let name = key.lowercased()
        if name == "black" || name == "bg" || name == "base" || name == "bar"
            || name.hasSuffix("_bg") || name.contains("background") {
            return .background
        }
        if name == "white" || name == "fg" || name.contains("foreground")
            || name.contains("text") || name.contains("label") {
            return .foreground
        }
        if name.contains("accent") || name.contains("highlight") || name == "primary" {
            return accentUsed ? .accentSecondary : .accent
        }
        if name.contains("subtext") || name.contains("muted") || name.contains("secondary") || name.contains("dim") {
            return .muted
        }
        if name.contains("line") || name.contains("border") {
            return .border
        }
        return nil
    }

    private static func replacement(for entry: BarThemeEntry, role: BarPalette.Role, palette: BarPalette) -> String? {
        let prefix = String(entry.value.prefix(2))
        let digits = String(entry.value.dropFirst(2))
        switch digits.count {
        case 8:
            // The original alpha bytes stay; only the colour changes.
            return prefix + digits.prefix(2) + palette.hex(for: role)
        case 6:
            return prefix + palette.hex(for: role)
        default:
            return nil
        }
    }

    private static func luminance(_ value: String) -> Double {
        var digits = value.lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        if digits.count == 8 { digits.removeFirst(2) }
        guard digits.count == 6, let integer = UInt32(digits, radix: 16) else { return 0 }

        let red = Double((integer >> 16) & 0xff) / 255
        let green = Double((integer >> 8) & 0xff) / 255
        let blue = Double(integer & 0xff) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    // MARK: - Parsing

    /// Reads the top level `key = 0x…` entries of a Lua theme. A nested table,
    /// a number, a function and a comment are not entries and stay untouched.
    static func hexEntries(in contents: String) -> [BarThemeEntry] {
        let lines = contents.components(separatedBy: "\n")
        var depth = 0
        var entries: [BarThemeEntry] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if depth == 1, let match = entryRegex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) {
                let text = line as NSString
                entries.append(BarThemeEntry(
                    key: text.substring(with: match.range(at: 1)),
                    value: text.substring(with: match.range(at: 2)),
                    lineIndex: lineIndex,
                    valueRange: match.range(at: 2)
                ))
            }
            depth += braceDelta(in: line)
        }
        return entries
    }

    private static let entryRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(0[xX][0-9A-Fa-f]+)[ \t]*,?[ \t]*(?:--.*)?$"#
    )

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var inSingle = false
        var inDouble = false
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", inSingle || inDouble {
                escaped = true
            } else if character == "'", !inDouble {
                inSingle.toggle()
            } else if character == "\"", !inSingle {
                inDouble.toggle()
            } else if !inSingle, !inDouble {
                let next = line.index(after: index)
                if character == "-", next < line.endIndex, line[next] == "-" {
                    break
                }
                if character == "{" { delta += 1 }
                if character == "}" { delta -= 1 }
            }
            index = line.index(after: index)
        }
        return delta
    }

    // MARK: - Files

    private var previousPointerKey: String {
        "BarThemeService.previousPointer." + configRoot.standardizedFileURL.path
    }

    private static func isValidThemeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.contains("\n") && !name.contains("\r")
    }

    private static func newlineSuffix(of text: String) -> String {
        if text.hasSuffix("\r\n") { return "\r\n" }
        if text.hasSuffix("\n") { return "\n" }
        return ""
    }

    private func writePointer(_ contents: String, at url: URL) throws {
        try write(contents, to: url, permissionsFrom: url)
    }

    private func write(_ contents: String, to url: URL, permissionsFrom source: URL?) throws {
        let resolvedSource = source.map { replacer.resolvedFileURL(for: $0) }
        let permissions = resolvedSource.flatMap {
            try? fileManager.attributesOfItem(atPath: $0.path)[.posixPermissions]
        }
        if fileManager.fileExists(atPath: url.path) {
            _ = try backupService.backup(fileURL: url, rootURL: configRoot)
        }
        try replacer.writeAtomicallyPreservingSymlinks(contents, to: url)

        if let permissions {
            let resolvedTarget = replacer.resolvedFileURL(for: url)
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolvedTarget.path)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
