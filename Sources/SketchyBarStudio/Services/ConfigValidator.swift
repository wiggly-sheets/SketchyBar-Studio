import Foundation

/// Finds the problems in a SketchyBar config.
///
/// The validator only reads the config. It never writes, moves or deletes a
/// file.
///
/// The checks follow the way SketchyBar loads a config: it ignores the
/// properties it does not know, it ignores the values it cannot use, it
/// loads only the files a loader reaches, and the last value of an option
/// that is set twice wins.
struct ConfigValidator: Sendable {
    /// The option domains of SketchyBar. A key inside one of them is an
    /// option of SketchyBar, so a key that is not known there is a typo.
    private static let knownDomains: Set<String> = {
        var domains: Set<String> = [
            "icon", "label", "background", "popup", "shadow", "image", "badge",
            "text", "glyph", "marker", "knob", "slider", "font", "graph", "ring",
            "alias", "bar"
        ]
        for doc in SketchyBarOptionDocs.all {
            if let domain = doc.key.split(separator: ".").first {
                domains.insert(String(domain))
            }
        }
        return domains
    }()

    /// The names of the options SketchyBar knows.
    private static let knownOptionKeys: [String] = SketchyBarOptionDocs.all.map { $0.key }

    /// The kinds of `sbar.add` that put something on the bar.
    private static let declaringKinds: Set<String> = [
        "item", "alias", "graph", "ring", "slider", "bracket"
    ]

    /// The problems of the config at the given root, ordered from the worst
    /// to the best.
    func validate(rootURL: URL) -> [ConfigDiagnostic] {
        let root = rootURL.standardizedFileURL
        var diagnostics = graphDiagnostics(root: root)
        var aliases: [AliasDeclaration] = []

        for file in SketchyBarConfigLocator().configFiles(in: root)
        where file.pathExtension.lowercased() == "lua" {
            diagnostics.append(contentsOf: luaDiagnostics(file: file, root: root, aliases: &aliases))
        }

        // An alias is used in the whole config, so the files are compared
        // with each other.
        diagnostics.append(contentsOf: Self.duplicateAliasDiagnostics(aliases, root: root))

        return Self.sorted(diagnostics)
    }

    // MARK: - Load graph

    /// The problems of the load graph: the loader lines that point at a
    /// file that is gone, and the files no loader reaches.
    private func graphDiagnostics(root: URL) -> [ConfigDiagnostic] {
        let report = ConfigGraphService().report(for: root)
        var diagnostics: [ConfigDiagnostic] = []

        for missing in report.missingTargets {
            diagnostics.append(
                ConfigDiagnostic(
                    id: "missingTarget:\(missing.from.path):\(missing.line):\(missing.target)",
                    severity: .error,
                    kind: .missingTarget,
                    title: "Missing target '\(missing.target)'",
                    detail: "The file it points at is not in the config.",
                    fileURL: missing.from,
                    line: missing.line,
                    keyPath: missing.target
                )
            )
        }

        for orphan in report.orphanFiles {
            // A file that requires a computed name can load files that the
            // graph cannot see, so the list of orphans can be too long.
            var detail = "No loader reaches this file, so SketchyBar never loads it."
            if !report.dynamicRequireFiles.isEmpty {
                detail += " A file that loads modules by a computed name can still load it."
            }

            diagnostics.append(
                ConfigDiagnostic(
                    id: "orphanFile:\(orphan.path)",
                    severity: .info,
                    kind: .orphanFile,
                    title: "Orphan file '\(orphan.lastPathComponent)'",
                    detail: detail,
                    fileURL: orphan,
                    line: nil,
                    keyPath: nil
                )
            )
        }

        return diagnostics
    }

    // MARK: - Lua files

    /// The problems of one Lua file.
    private func luaDiagnostics(
        file: URL,
        root: URL,
        aliases: inout [AliasDeclaration]
    ) -> [ConfigDiagnostic] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }

        var diagnostics: [ConfigDiagnostic] = []
        let lines = LineMap(contents)

        if let line = Self.unbalancedLine(in: contents) {
            diagnostics.append(
                ConfigDiagnostic(
                    id: "unbalancedTable:\(file.path):\(line)",
                    severity: .error,
                    kind: .unbalancedTable,
                    title: "Unbalanced brackets",
                    detail: "The braces, brackets or parentheses of this file do not balance.",
                    fileURL: file,
                    line: line,
                    keyPath: nil
                )
            )
        }

        let parse = LuaTableParser.parse(source: contents)

        for call in parse.calls where call.path.first == "sbar" {
            if call.path == ["sbar", "add"] {
                let names = Self.stringLiterals(in: call)
                guard let kind = names.first else { continue }

                if kind == "item" {
                    let alias = names.count > 1 ? names[1] : ""
                    if !alias.isEmpty {
                        let line = lines.line(for: call.range.start)
                        aliases.append(AliasDeclaration(alias: alias, file: file, line: line))
                    }
                }

                guard let table = Self.lastTable(in: call) else { continue }
                diagnostics.append(
                    contentsOf: optionDiagnostics(
                        table: table,
                        file: file,
                        lines: lines,
                        isItemTable: kind == "item"
                    )
                )
                continue
            }

            // The bar and the default items take the same options as an
            // item.
            guard call.path == ["sbar", "bar"] || call.path == ["sbar", "default"] else { continue }
            guard let table = Self.lastTable(in: call) else { continue }
            diagnostics.append(
                contentsOf: optionDiagnostics(
                    table: table,
                    file: file,
                    lines: lines,
                    isItemTable: false
                )
            )
        }

        if let diagnostic = Self.noItemDeclarationDiagnostic(
            file: file,
            root: root,
            calls: parse.calls
        ) {
            diagnostics.append(diagnostic)
        }

        return diagnostics
    }

    /// The problems of the options of one table of a SketchyBar call.
    ///
    /// The names of the options are only checked for an item, because a
    /// table of the user can hold any name.
    private func optionDiagnostics(
        table: LuaTable,
        file: URL,
        lines: LineMap,
        isItemTable: Bool
    ) -> [ConfigDiagnostic] {
        var diagnostics: [ConfigDiagnostic] = []
        var seenKeys: [String: Int] = [:]

        for entry in table.entries {
            guard !entry.path.isEmpty else { continue }
            let keyPath = entry.path.joined(separator: ".")
            let line = lines.line(for: entry.keyRange.start)

            // The same option twice in one table. The last value wins and
            // the first one is lost.
            let count = seenKeys[keyPath, default: 0]
            seenKeys[keyPath] = count + 1
            if count == 1, isItemTable {
                diagnostics.append(
                    ConfigDiagnostic(
                        id: "duplicateKey:\(file.path):\(line):\(keyPath)",
                        severity: .warning,
                        kind: .duplicateKey,
                        title: "Duplicate option '\(keyPath)'",
                        detail: "The option is set twice in the same item. The last value wins.",
                        fileURL: file,
                        line: line,
                        keyPath: keyPath
                    )
                )
            }

            if isItemTable, let unknown = Self.unknownOption(keyPath: keyPath) {
                var detail = "SketchyBar ignores options it does not know, so this value has no effect."
                if let suggestion = unknown.suggestion {
                    detail += " Did you mean '\(suggestion)'?"
                }
                diagnostics.append(
                    ConfigDiagnostic(
                        id: "unknownOption:\(file.path):\(line):\(keyPath)",
                        severity: .warning,
                        kind: .unknownOption,
                        title: "Unknown option '\(keyPath)'",
                        detail: detail,
                        fileURL: file,
                        line: line,
                        keyPath: keyPath
                    )
                )
            }

            if let invalid = Self.invalidValue(keyPath: keyPath, entry: entry) {
                diagnostics.append(
                    ConfigDiagnostic(
                        id: "invalidValue:\(file.path):\(line):\(keyPath)",
                        severity: .error,
                        kind: .invalidValue,
                        title: "Invalid value '\(invalid.value)' for '\(keyPath)'",
                        detail: "'\(keyPath)' accepts \(invalid.allowed.joined(separator: ", ")).",
                        fileURL: file,
                        line: line,
                        keyPath: keyPath
                    )
                )
            }
        }

        return diagnostics
    }

    /// The problem of an alias that is used twice in the config.
    private static func duplicateAliasDiagnostics(
        _ aliases: [AliasDeclaration],
        root: URL
    ) -> [ConfigDiagnostic] {
        var byAlias: [String: [AliasDeclaration]] = [:]
        for declaration in aliases {
            byAlias[declaration.alias, default: []].append(declaration)
        }

        var diagnostics: [ConfigDiagnostic] = []
        for alias in byAlias.keys.sorted() {
            let declarations = (byAlias[alias] ?? []).sorted {
                ($0.file.path, $0.line) < ($1.file.path, $1.line)
            }
            guard declarations.count > 1 else { continue }

            let first = declarations[0]
            let locations = declarations.map {
                "\(relativePath($0.file, root: root)):\($0.line)"
            }

            diagnostics.append(
                ConfigDiagnostic(
                    id: "duplicateAlias:\(first.file.path):\(first.line):\(alias)",
                    severity: .error,
                    kind: .duplicateAlias,
                    title: "Duplicate alias '\(alias)'",
                    detail: "Declared at \(locations.joined(separator: " and ")).",
                    fileURL: first.file,
                    line: first.line,
                    keyPath: alias
                )
            )
        }

        return diagnostics
    }

    /// The problem of a file that looks like an item file but declares
    /// nothing.
    private static func noItemDeclarationDiagnostic(
        file: URL,
        root: URL,
        calls: [LuaCall]
    ) -> ConfigDiagnostic? {
        guard isItemFile(file, root: root) else { return nil }

        let declares = calls.contains { call in
            guard call.path == ["sbar", "add"] else { return false }
            let names = stringLiterals(in: call)
            guard let kind = names.first else { return false }
            return declaringKinds.contains(kind)
        }
        guard !declares else { return nil }

        // A file that loads other files is a loader, not an item.
        guard !calls.contains(where: { $0.path == ["require"] }) else { return nil }

        return ConfigDiagnostic(
            id: "noItemDeclaration:\(file.path)",
            severity: .info,
            kind: .noItemDeclaration,
            title: "No item declared",
            detail: "This file declares no item, so it never reaches the bar.",
            fileURL: file,
            line: nil,
            keyPath: nil
        )
    }

    // MARK: - Options

    /// The option SketchyBar knows that the key is most likely meant to be,
    /// when the key is close enough to it to be a typo of it.
    ///
    /// A key that is not close to a known option is not reported. A table of
    /// the user can hold any name, and that name is not a mistake.
    private static func unknownOption(keyPath: String) -> UnknownOption? {
        let components = keyPath.split(separator: ".").map(String.init)
        guard let leaf = components.last else { return nil }

        let doc = SketchyBarOptionDocs.doc(for: keyPath)
        // A key that SketchyBar knows is fine, also when only the leaf of
        // the path is known, such as `icon.padding_left`.
        if let doc, doc.key == keyPath.lowercased() { return nil }

        if components.count > 1 {
            let domain = components[0]
            if knownDomains.contains(domain) {
                // The domain is known, so the leaf must be an option of
                // SketchyBar too.
                guard doc == nil else { return nil }
                return UnknownOption(suggestion: closestMatch(for: leaf, in: knownOptionKeys))
            }
            // The domain is not known. It is only a problem when it is
            // close to a known domain.
            guard let suggestion = closestMatch(for: domain, in: Array(knownDomains)) else { return nil }
            return UnknownOption(suggestion: suggestion)
        }

        // A key of one word is only a problem when it is close to a known
        // option.
        guard let suggestion = closestMatch(for: leaf, in: knownOptionKeys) else { return nil }
        return UnknownOption(suggestion: suggestion)
    }

    /// The problem of a value that SketchyBar cannot use.
    private static func invalidValue(
        keyPath: String,
        entry: LuaTableEntry
    ) -> (value: String, allowed: [String])? {
        guard let doc = SketchyBarOptionDocs.doc(for: keyPath) else { return nil }
        // Only an enumeration has a fixed list of values. A number, a
        // color or a font can be written in many ways.
        guard doc.type == .enumeration, !doc.values.isEmpty else { return nil }
        // Only a literal can be wrong. A value that comes from an
        // expression cannot be read.
        guard entry.kind == .string else { return nil }

        let value = SketchyBarValueRules.unquoted(entry.text)
        guard !value.isEmpty else { return nil }
        guard !isAccepted(value, by: doc) else { return nil }

        return (value, doc.values)
    }

    /// True when SketchyBar can use the value.
    private static func isAccepted(_ value: String, by doc: SketchyBarOptionDoc) -> Bool {
        let values = doc.values
        if values.contains(value) { return true }
        // A position can name the item of a popup, such as "popup.apple".
        if let prefix = value.split(separator: ".").first.map(String.init), values.contains(prefix) {
            return true
        }
        // SketchyBar reads the first letter of a position, so "l" means
        // "left".
        if value.count == 1, value.first?.isLetter == true, values.contains(where: { $0.hasPrefix(value) }) {
            return true
        }
        // SketchyBar reads a boolean-like option with its own words, so
        // `updates = "true"` works as well as `updates = "on"`.
        if values.contains("on"), values.contains("off"), isBooleanWord(value) { return true }
        return false
    }

    /// The words that SketchyBar reads as true or as false.
    private static func isBooleanWord(_ value: String) -> Bool {
        ["true", "false", "yes", "no", "1", "0"].contains(value.lowercased())
    }

    /// The known name that is closest to the given name, when it is close
    /// enough to be a typo of it.
    private static func closestMatch(for name: String, in candidates: [String]) -> String? {
        var best: (name: String, distance: Int)?

        for candidate in candidates {
            let distance = editDistance(name, candidate)
            guard distance <= 2 else { continue }
            guard best == nil || distance < best!.distance else { continue }
            best = (candidate, distance)
        }

        return best?.name
    }

    /// The number of changes that turn one name into the other.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for index in 1...left.count {
            current[0] = index
            for other in 1...right.count {
                let cost = left[index - 1] == right[other - 1] ? 0 : 1
                current[other] = min(
                    previous[other] + 1,
                    current[other - 1] + 1,
                    previous[other - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }

    // MARK: - Calls

    /// The string arguments of a call, in the order they stand in.
    private static func stringLiterals(in call: LuaCall) -> [String] {
        call.arguments.compactMap { argument in
            if case .literal(.string(let text)) = argument { return text }
            return nil
        }
    }

    /// The last table of a call. The options of a bracket come after the
    /// list of the items it holds, so the last table is the options.
    private static func lastTable(in call: LuaCall) -> LuaTable? {
        var table: LuaTable?
        for argument in call.arguments {
            if case .table(let found) = argument { table = found }
        }
        return table
    }

    // MARK: - Files

    /// True when the file sits in a folder of items, or when its name says
    /// that it is an item.
    private static func isItemFile(_ file: URL, root: URL) -> Bool {
        if file.lastPathComponent.lowercased().hasPrefix("item") { return true }

        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }

        for component in fileComponents.dropFirst(rootComponents.count).dropLast() {
            let name = component.lowercased()
            if name == "items" || name == "item" { return true }
        }

        return false
    }

    /// The path of a file inside the config.
    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Brackets

    /// The line of the bracket that does not balance, or nil when the
    /// brackets of the file balance.
    ///
    /// The scan skips the strings and the comments of the file, so a brace
    /// inside a string does not count.
    private static func unbalancedLine(in source: String) -> Int? {
        let characters = Array(source)
        let ignored = SourceRegions.luaIgnoredRegions(in: source)
        var stack: [(character: Character, line: Int)] = []
        var regionIndex = 0
        var index = 0
        var line = 1

        while index < characters.count {
            while regionIndex < ignored.count, ignored[regionIndex].end <= index {
                regionIndex += 1
            }

            var next = index + 1
            if regionIndex < ignored.count, ignored[regionIndex].start <= index {
                // A comment or a long string.
                next = ignored[regionIndex].end
                regionIndex += 1
            } else {
                let character = characters[index]
                if character == "\"" || character == "'" {
                    next = endOfQuotedString(characters, from: index, quote: character)
                } else if character == "{" || character == "[" || character == "(" {
                    stack.append((character, line))
                } else if character == "}" || character == "]" || character == ")" {
                    guard let open = stack.popLast(), matches(open.character, character) else {
                        return line
                    }
                }
            }

            for position in index..<next where characters[position].isNewline {
                line += 1
            }
            index = next
        }

        return stack.last?.line
    }

    /// True when the closing bracket closes the opening bracket.
    private static func matches(_ open: Character, _ close: Character) -> Bool {
        switch open {
        case "{": return close == "}"
        case "[": return close == "]"
        case "(": return close == ")"
        default: return false
        }
    }

    /// The index after a quoted string. A string that is never closed covers
    /// the rest of the file.
    private static func endOfQuotedString(
        _ characters: [Character],
        from start: Int,
        quote: Character
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == quote {
                return index + 1
            }
            index += 1
        }
        return characters.count
    }

    // MARK: - Order

    /// The order of a report: the worst problems first, then the file, then
    /// the line.
    private static func sorted(_ diagnostics: [ConfigDiagnostic]) -> [ConfigDiagnostic] {
        diagnostics.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }

            let leftPath = lhs.fileURL?.path ?? ""
            let rightPath = rhs.fileURL?.path ?? ""
            if leftPath != rightPath { return leftPath < rightPath }

            let leftLine = lhs.line ?? 0
            let rightLine = rhs.line ?? 0
            if leftLine != rightLine { return leftLine < rightLine }

            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - Helper types

/// A key that SketchyBar does not know.
private struct UnknownOption {
    /// The known option the key is most likely meant to be.
    let suggestion: String?
}

/// One `sbar.add("item", …)` declaration of a file.
private struct AliasDeclaration {
    let alias: String
    let file: URL
    let line: Int
}

/// The line of every character offset of a file.
private struct LineMap {
    private let starts: [Int]

    init(_ source: String) {
        var starts = [0]
        for (index, character) in source.enumerated() where character.isNewline {
            starts.append(index + 1)
        }
        self.starts = starts
    }

    /// The line the offset sits on.
    func line(for offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        var line = 0

        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= offset {
                line = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        return line + 1
    }
}
