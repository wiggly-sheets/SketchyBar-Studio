import Foundation

/// How a config names the theme it uses.
enum BarThemePattern: Equatable {
    /// A pointer file in `themes/` names a theme `.lua` file.
    case themedPointer(name: String)
    /// A Lua variable holds the name and a computed `require` reads it.
    case luaVariable(name: String, fileURL: URL, literalRange: Range<Int>)
    /// A `require("themes.<name>")` call holds the name directly.
    case literalRequire(name: String, fileURL: URL, literalRange: Range<Int>)
    /// The config has a `themes/` folder but no theme selection.
    case themedPointerMissing
    /// The config has no `themes/` folder.
    case noThemesFolder
    /// More than one file or literal names a theme.
    case ambiguous(String)
    /// The config is a shell config, which this feature does not edit.
    case shellConfigUnsupported
}

/// The exact theme selection a config holds.
struct BarThemeSelection: Equatable {
    enum Kind: String, Equatable {
        case pointerFile
        case luaVariableRequire
        case literalRequire
    }

    let kind: Kind
    let fileURL: URL
    let themeName: String
    /// UTF-8 byte range of the name inside its quotes.
    let literalRange: Range<Int>
}

/// The result of reading a config's theme selection, with the reason when
/// no single selection can be trusted.
enum BarThemeDetection: Equatable {
    case selection(BarThemeSelection)
    case pointerMissing
    case noThemesFolder
    case ambiguous(String)
    case shellConfigUnsupported
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
    let wroteSelection: Bool

    init(themeName: String, wroteThemeFile: Bool, wrotePointer: Bool, wroteSelection: Bool = false) {
        self.themeName = themeName
        self.wroteThemeFile = wroteThemeFile
        self.wrotePointer = wrotePointer
        self.wroteSelection = wroteSelection
    }
}

enum BarThemeError: LocalizedError, Equatable {
    case noThemesFolder
    case pointerMissing
    case activeThemeMissing(String)
    case targetThemeExists(String)
    case invalidThemeName(String)
    case noPreviousTheme
    case ambiguousSelection(String)
    case shellConfigUnsupported
    case selectionChanged

    var errorDescription: String? {
        switch self {
        case .noThemesFolder:
            return "This config has no themes folder. Bar theme switching needs a themes/ folder with a theme pointer file."
        case .pointerMissing:
            return "This config has no theme selection. Add a pointer file in themes/, a Lua theme variable with a computed require, or a literal require(\"themes.<name>\")."
        case .activeThemeMissing(let name):
            return "The active theme file themes/\(name).lua is missing or cannot be read."
        case .targetThemeExists(let name):
            return "themes/\(name).lua already exists with different content. A theme you wrote is never overwritten."
        case .invalidThemeName(let name):
            return "The theme name \"\(name)\" cannot be used as a file name."
        case .noPreviousTheme:
            return "No previous theme is stored for this config."
        case .ambiguousSelection(let reason):
            return reason
        case .shellConfigUnsupported:
            return "This is a shell config. Bar theme switching supports Lua configs only; a shell config is not supported."
        case .selectionChanged:
            return "The theme selection changed or no longer matches the detected literal. The selection was not edited."
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
        switch detectSelection() {
        case .selection(let selection):
            switch selection.kind {
            case .pointerFile:
                return .themedPointer(name: selection.themeName)
            case .luaVariableRequire:
                return .luaVariable(
                    name: selection.themeName,
                    fileURL: selection.fileURL,
                    literalRange: selection.literalRange
                )
            case .literalRequire:
                return .literalRequire(
                    name: selection.themeName,
                    fileURL: selection.fileURL,
                    literalRange: selection.literalRange
                )
            }
        case .pointerMissing:
            return .themedPointerMissing
        case .noThemesFolder:
            return .noThemesFolder
        case .ambiguous(let reason):
            return .ambiguous(reason)
        case .shellConfigUnsupported:
            return .shellConfigUnsupported
        }
    }

    /// Reads the selection and keeps the file and byte range it would rewrite.
    /// A pointer file wins, then a Lua variable plus computed require, then a
    /// literal require. More than one Lua candidate is refused.
    func detectSelection() -> BarThemeDetection {
        if let pointer = pointerCandidate() {
            return .selection(pointerSelection(pointer))
        }

        let candidates = luaSelectionCandidates()
        if candidates.count == 1, let candidate = candidates.first {
            return .selection(candidate)
        }
        if candidates.count > 1 {
            return .ambiguous(ambiguityReason(for: candidates))
        }

        if shellEntrypoint() != nil {
            return .shellConfigUnsupported
        }
        if !isDirectory(themesDirectory) {
            return .noThemesFolder
        }
        return .pointerMissing
    }

    /// The theme the selection names, or nil when no single selection can be
    /// trusted.
    func activeTheme() -> BarThemeFile? {
        guard case .selection(let selection) = detectSelection() else { return nil }
        return themeFile(named: selection.themeName)
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
        let pointerURL = themesDirectory.appendingPathComponent(Self.pointerFileName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: pointerURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOf: pointerURL, encoding: .utf8) else {
            return nil
        }

        let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r"),
              Self.isValidThemeName(name) else {
            return nil
        }
        return (pointerURL, name)
    }

    private func pointerSelection(_ pointer: (url: URL, name: String)) -> BarThemeSelection {
        let contents = (try? String(contentsOf: pointer.url, encoding: .utf8)) ?? pointer.name
        let range = (contents as NSString).range(of: pointer.name)
        let bytes = Self.byteRange(range, in: contents) ?? 0..<0
        return BarThemeSelection(
            kind: .pointerFile,
            fileURL: pointer.url,
            themeName: pointer.name,
            literalRange: bytes
        )
    }

    /// Lua files under the config root, except the theme files themselves and
    /// the backup mirror.
    private func luaSelectionFiles() -> [URL] {
        let root = configRoot.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "lua" else { continue }
            guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { continue }

            let relative = url.standardizedFileURL.path.dropFirst(root.path.count + 1)
            guard let first = relative.split(separator: "/").first?.lowercased(),
                  first != "themes", first != "backups" else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func luaSelectionCandidates() -> [BarThemeSelection] {
        var selections: [BarThemeSelection] = []
        for url in luaSelectionFiles() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for literal in selectionLiterals(in: contents) {
                selections.append(BarThemeSelection(
                    kind: literal.kind,
                    fileURL: url,
                    themeName: literal.themeName,
                    literalRange: literal.literalRange
                ))
            }
        }
        return selections
    }

    private func ambiguityReason(for candidates: [BarThemeSelection]) -> String {
        let paths = Set(candidates.map { $0.fileURL.standardizedFileURL.path })
        if paths.count > 1 {
            let names = Array(Set(candidates.map { relativePath(of: $0.fileURL) })).sorted()
            return "More than one file selects a theme: \(names.joined(separator: ", ")). Refusing to guess."
        }

        let name = candidates.first.map { relativePath(of: $0.fileURL) } ?? "the config"
        return "More than one literal in \(name) selects a theme. Refusing to guess."
    }

    private func relativePath(of url: URL) -> String {
        let root = configRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func shellEntrypoint() -> URL? {
        let names = ["sketchybarrc", ".sketchybarrc"]
        return names
            .map { configRoot.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private struct SelectionLiteral: Hashable {
        let kind: BarThemeSelection.Kind
        let themeName: String
        let literalRange: Range<Int>
    }

    private func selectionLiterals(in source: String) -> [SelectionLiteral] {
        let ignored = SourceRegions.luaIgnoredRegions(in: source)
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        var literals: [SelectionLiteral] = []

        for match in Self.literalRequireRegex.matches(in: source, range: fullRange) {
            guard !Self.isIgnored(match.range, in: source, ignored: ignored) else { continue }
            let name = (source as NSString).substring(with: match.range(at: 2))
            guard Self.isPlainThemeName(name),
                  let range = Self.byteRange(match.range(at: 2), in: source),
                  fileManager.fileExists(atPath: themesDirectory.appendingPathComponent(name + ".lua").path) else {
                continue
            }
            literals.append(SelectionLiteral(
                kind: .literalRequire,
                themeName: name,
                literalRange: range
            ))
        }

        let assignments: [(name: String, value: String, range: NSRange)] = Self.assignmentRegex
            .matches(in: source, range: fullRange)
            .compactMap { match in
                guard !Self.isIgnored(match.range, in: source, ignored: ignored) else { return nil }
                return (
                    (source as NSString).substring(with: match.range(at: 1)),
                    (source as NSString).substring(with: match.range(at: 3)),
                    match.range(at: 3)
                )
            }

        let computed = Self.computedRequireRegex.matches(in: source, range: fullRange)
        for match in computed {
            guard !Self.isIgnored(match.range, in: source, ignored: ignored) else { continue }
            let variable = (source as NSString).substring(with: match.range(at: 2))

            for assignment in assignments
            where assignment.name == variable && assignment.range.location < match.range.location {
                guard Self.isPlainThemeName(assignment.value),
                      let range = Self.byteRange(assignment.range, in: source),
                      fileManager.fileExists(atPath: themesDirectory.appendingPathComponent(assignment.value + ".lua").path) else {
                    continue
                }
                literals.append(SelectionLiteral(
                    kind: .luaVariableRequire,
                    themeName: assignment.value,
                    literalRange: range
                ))
            }
        }

        var seen = Set<SelectionLiteral>()
        return literals.filter { seen.insert($0).inserted }
    }

    private static func isPlainThemeName(_ name: String) -> Bool {
        !name.isEmpty
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && isValidThemeName(name)
    }

    private static func isIgnored(
        _ range: NSRange,
        in source: String,
        ignored: [SourceRegions.Region]
    ) -> Bool {
        guard let stringRange = Range(range, in: source) else { return true }
        let start = source.distance(from: source.startIndex, to: stringRange.lowerBound)
        let end = source.distance(from: source.startIndex, to: stringRange.upperBound)
        return ignored.contains { $0.intersects(start, end) }
    }

    private static func byteRange(_ range: NSRange, in source: String) -> Range<Int>? {
        guard let stringRange = Range(range, in: source) else { return nil }
        let start = source[..<stringRange.lowerBound].utf8.count
        let end = source[..<stringRange.upperBound].utf8.count
        return start..<end
    }

    private static let literalRequireRegex = try! NSRegularExpression(
        pattern: #"(?<!\bsbar\.)\brequire\s*\(\s*(["'])themes\.([^"'\n]+)\1\s*\)"#
    )

    private static let computedRequireRegex = try! NSRegularExpression(
        pattern: #"\brequire\b\s*(?:\(\s*|,\s*)?(["'])themes\.\1\s*\.\.\s*([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static let assignmentRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(["'])([^"'\n]*)\2"#
    )

    // MARK: - Apply

    @discardableResult
    func apply(_ palette: BarPalette) throws -> BarThemeApplyResult {
        let detection = detectSelection()
        guard case .selection(let selection) = detection else {
            throw error(for: detection)
        }
        guard isDirectory(themesDirectory) else { throw BarThemeError.noThemesFolder }
        guard let active = themeFile(named: selection.themeName) else {
            throw BarThemeError.activeThemeMissing(selection.themeName)
        }
        guard Self.isValidThemeName(palette.displayName) else {
            throw BarThemeError.invalidThemeName(palette.displayName)
        }

        let contents = renderedThemeContents(for: palette, from: active)
        let targetURL = themesDirectory.appendingPathComponent(palette.displayName + ".lua")

        if replacer.itemExists(at: targetURL) {
            guard let existing = try? String(contentsOf: targetURL, encoding: .utf8) else {
                throw BarThemeError.targetThemeExists(palette.displayName)
            }
            guard existing == contents else {
                throw BarThemeError.targetThemeExists(palette.displayName)
            }
        }

        var wrotePointer = false
        var wroteSelection = false

        switch selection.kind {
        case .pointerFile:
            let pointerText = try String(contentsOf: selection.fileURL, encoding: .utf8)
            let newPointerText = palette.displayName + Self.newlineSuffix(of: pointerText)

            if newPointerText != pointerText {
                try writePointer(newPointerText, at: selection.fileURL)
                defaults.set(pointerText, forKey: previousPointerKey)
                defaults.removeObject(forKey: previousLiteralKey)
                wrotePointer = true
            }
        case .luaVariableRequire, .literalRequire:
            if selection.themeName != palette.displayName {
                try rewriteLiteral(selection, to: palette.displayName)
                let stored = PreviousLiteralSelection(
                    kind: selection.kind.rawValue,
                    filePath: selection.fileURL.standardizedFileURL.path,
                    themeName: selection.themeName
                )
                defaults.set(try JSONEncoder().encode(stored), forKey: previousLiteralKey)
                defaults.removeObject(forKey: previousPointerKey)
                wroteSelection = true
            }
        }

        var wroteThemeFile = false
        if !replacer.itemExists(at: targetURL) {
            try write(contents, to: targetURL, permissionsFrom: active.url)
            wroteThemeFile = true
        }

        return BarThemeApplyResult(
            themeName: palette.displayName,
            wroteThemeFile: wroteThemeFile,
            wrotePointer: wrotePointer,
            wroteSelection: wroteSelection
        )
    }

    private func rewriteLiteral(_ selection: BarThemeSelection, to name: String) throws {
        let data = try Data(contentsOf: selection.fileURL)
        guard selection.literalRange.lowerBound >= 0,
              selection.literalRange.upperBound <= data.count else {
            throw BarThemeError.selectionChanged
        }

        let current = data.subdata(in: selection.literalRange)
        guard String(data: current, encoding: .utf8) == selection.themeName else {
            throw BarThemeError.selectionChanged
        }

        var updated = data
        updated.replaceSubrange(selection.literalRange, with: Data(name.utf8))
        guard let contents = String(data: updated, encoding: .utf8) else {
            throw BarThemeError.selectionChanged
        }
        try write(contents, to: selection.fileURL, permissionsFrom: selection.fileURL)
    }

    private func error(for detection: BarThemeDetection) -> BarThemeError {
        switch detection {
        case .selection:
            return .pointerMissing
        case .pointerMissing:
            return .pointerMissing
        case .noThemesFolder:
            return .noThemesFolder
        case .ambiguous(let reason):
            return .ambiguousSelection(reason)
        case .shellConfigUnsupported:
            return .shellConfigUnsupported
        }
    }

    // MARK: - Revert

    func previousThemeName() -> String? {
        if let stored = previousLiteralSelection() {
            return stored.themeName
        }
        guard let stored = defaults.string(forKey: previousPointerKey) else { return nil }
        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { return nil }
        return name
    }

    /// Puts the selection back to the value captured before the last apply.
    /// A pointer is restored from its remembered text; a Lua literal is
    /// rewritten in place. The theme files are not touched.
    @discardableResult
    func restorePreviousTheme() throws -> String {
        if let stored = previousLiteralSelection() {
            return try restoreLiteral(stored)
        }

        guard let stored = defaults.string(forKey: previousPointerKey) else {
            throw BarThemeError.noPreviousTheme
        }
        guard let pointer = pointerCandidate() else { throw BarThemeError.pointerMissing }

        let name = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidThemeName(name) else { throw BarThemeError.invalidThemeName(name) }

        defer { defaults.removeObject(forKey: previousPointerKey) }

        let current = try String(contentsOf: pointer.url, encoding: .utf8)
        if current != stored {
            try writePointer(stored, at: pointer.url)
        }
        return name
    }

    private struct PreviousLiteralSelection: Codable {
        let kind: String
        let filePath: String
        let themeName: String
    }

    private func previousLiteralSelection() -> PreviousLiteralSelection? {
        guard let data = defaults.data(forKey: previousLiteralKey),
              let stored = try? JSONDecoder().decode(PreviousLiteralSelection.self, from: data),
              Self.isValidThemeName(stored.themeName) else {
            return nil
        }
        return stored
    }

    private func restoreLiteral(_ stored: PreviousLiteralSelection) throws -> String {
        guard Self.isValidThemeName(stored.themeName) else {
            throw BarThemeError.invalidThemeName(stored.themeName)
        }
        guard let kind = BarThemeSelection.Kind(rawValue: stored.kind),
              case .selection(let current) = detectSelection(),
              current.kind == kind,
              current.fileURL.standardizedFileURL.path == stored.filePath else {
            throw BarThemeError.selectionChanged
        }

        defer { defaults.removeObject(forKey: previousLiteralKey) }

        try rewriteLiteral(current, to: stored.themeName)
        return stored.themeName
    }

    // MARK: - Rendering

    /// Rewrites the hex values of the active theme and keeps every other byte:
    /// the key set, the key order, the comments, the nested tables and the
    /// functions. A semantic key wins over a hue name, a hue name wins over
    /// the luminance rule.
    func renderedThemeContents(for palette: BarPalette, from active: BarThemeFile) -> String {
        var assignments: [(entry: BarThemeEntry, hex: String)] = []
        var accentUsed = false
        var remaining: [BarThemeEntry] = []

        for entry in active.entries {
            if let role = Self.heuristicRole(for: entry.key, accentUsed: accentUsed) {
                assignments.append((entry, palette.hex(for: role)))
                if role == .accent || role == .accentSecondary {
                    accentUsed = true
                }
                continue
            }

            if let hue = Self.hueName(in: entry.key) {
                switch hue {
                case .black:
                    assignments.append((entry, palette.hex(for: .background)))
                case .white:
                    assignments.append((entry, palette.hex(for: .foreground)))
                case .grey, .gray:
                    assignments.append((entry, palette.hex(for: .muted)))
                default:
                    if let swatch = palette.swatchHex(for: hue) {
                        assignments.append((entry, swatch))
                    } else {
                        remaining.append(entry)
                    }
                }
                continue
            }

            remaining.append(entry)
        }

        let byLuminance = remaining.sorted { left, right in
            let leftValue = Self.luminance(left.value)
            let rightValue = Self.luminance(right.value)
            return leftValue == rightValue ? left.lineIndex < right.lineIndex : leftValue < rightValue
        }

        if byLuminance.count == 1 {
            assignments.append((byLuminance[0], palette.hex(for: .muted)))
        } else if byLuminance.count >= 2 {
            assignments.append((byLuminance[0], palette.hex(for: .background)))
            assignments.append((byLuminance[byLuminance.count - 1], palette.hex(for: .foreground)))
            for entry in byLuminance.dropFirst().dropLast() {
                assignments.append((entry, palette.hex(for: .muted)))
            }
        }

        var lines = active.contents.components(separatedBy: "\n")
        for (entry, hex) in assignments {
            guard let replacement = Self.replacement(for: entry, hex: hex) else { continue }
            guard lines.indices.contains(entry.lineIndex) else { continue }

            let rawLine = lines[entry.lineIndex]
            let hasCarriageReturn = rawLine.hasSuffix("\r")
            let line = hasCarriageReturn ? String(rawLine.dropLast()) : rawLine
            let updated = (line as NSString).replacingCharacters(in: entry.valueRange, with: replacement)
            lines[entry.lineIndex] = updated + (hasCarriageReturn ? "\r" : "")
        }
        return lines.joined(separator: "\n")
    }

    private static func hueName(in key: String) -> BarPalette.Hue? {
        let tokens = key.lowercased().split(whereSeparator: { !$0.isLetter })
        return tokens.lazy.compactMap { BarPalette.Hue(rawValue: String($0)) }.first
    }

    private static func heuristicRole(for key: String, accentUsed: Bool) -> BarPalette.Role? {
        let name = key.lowercased()
        if name == "black" || name == "bg" || name == "base" || name == "bar"
            || name.hasSuffix("_bg") || name.contains("background") {
            return .background
        }
        if name.contains("subtext") || name.contains("muted") || name.contains("secondary") || name.contains("dim") {
            return .muted
        }
        if name == "white" || name == "fg" || name.contains("foreground")
            || name.contains("text") || name.contains("label") {
            return .foreground
        }
        if name.contains("accent") || name.contains("highlight") || name == "primary" {
            return accentUsed ? .accentSecondary : .accent
        }
        if name.contains("line") || name.contains("border") {
            return .border
        }
        return nil
    }

    private static func replacement(for entry: BarThemeEntry, hex: String) -> String? {
        let prefix = String(entry.value.prefix(2))
        let digits = String(entry.value.dropFirst(2))
        switch digits.count {
        case 8:
            // The original alpha bytes stay; only the colour changes.
            return prefix + digits.prefix(2) + hex
        case 6:
            return prefix + hex
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

    private var previousLiteralKey: String {
        "BarThemeService.previousLiteral." + configRoot.standardizedFileURL.path
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
