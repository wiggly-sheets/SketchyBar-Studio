import Foundation

/// Builds the load graph of a SketchyBar config: the files the entrypoints
/// reach, the files no loader loads, the loader lines that point at files
/// that are gone, and the require cycles.
///
/// The service only reads files. It never writes, moves, or deletes.
struct ConfigGraphService: Sendable {
    /// The files SketchyBar loads on its own. Same list the activation
    /// service uses, so both agree on what an entrypoint is.
    static let entrypointNames = [
        "init.lua",
        "sketchybarrc",
        ".sketchybarrc",
        "init.sh",
        "loader.sh"
    ]

    /// Modules SketchyBar and SbarLua bring themselves. A loader line that
    /// names one of them does not point at a file in the config.
    private static let runtimeModules: Set<String> = [
        "sketchybar",
        "sbar",
        "socket",
        "cairo",
        "alerts"
    ]

    /// A string literal in a Lua file.
    private static let luaLiteralPattern = #"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#
    /// A require call whose name is computed at runtime.
    private static let luaDynamicRequirePattern = #"require\s*\(\s*[^"')]"#
    /// A `pcall(require, ...)` whose name is computed at runtime.
    private static let luaDynamicPCallPattern = #"pcall\s*\(\s*require\s*,\s*([^)]*)"#
    /// The text before a literal that makes it a require call.
    private static let luaRequireCallPattern = #"(?:^|[^A-Za-z0-9_])(require|dofile|loadfile)\s*\(\s*$"#
    private static let luaRequireWordPattern = #"(?:^|[^A-Za-z0-9_])(require|dofile|loadfile)\s*$"#
    /// A shell loader line.
    private static let shellLoaderPatterns = [
        #"^\s*(?:source|\.)\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;#]+))\s*;?\s*(?:#.*)?$"#,
        #"^\s*(?:bash|zsh|sh)\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;#]+))\s*;?\s*(?:#.*)?$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let knownExtensions = ["lua", "sh", "bash", "zsh"]

    private let locator = SketchyBarConfigLocator()

    /// Reads the config and returns its load graph. A file that cannot be
    /// read is skipped instead of failing the whole report.
    func report(for rootURL: URL) -> ConfigGraphReport {
        let root = rootURL.standardizedFileURL
        let files = locator.configFiles(in: root).filter { !isExcluded($0, rootURL: root) }
        // The file name on disk wins, so a require that uses another case
        // still points at the file the config really has.
        var canonicalByKey: [String: URL] = [:]
        for file in files {
            canonicalByKey[Self.key(for: file)] = file
        }

        var edges: [ConfigGraphEdge] = []
        var missingTargets: [ConfigGraphMissingTarget] = []
        var dynamicRequireFiles: [URL] = []
        var visited: Set<String> = []
        let entrypoints = entrypoints(in: root)
        var queue = entrypoints

        while let file = queue.first {
            queue.removeFirst()
            // The visited set holds resolved paths, so a symlink that points
            // back into the config cannot loop forever.
            let key = Self.key(for: file)
            guard visited.insert(key).inserted else { continue }

            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let isLua = Self.isLuaSource(url: file, contents: contents)
            let references = loaderReferences(in: contents, isLua: isLua)
            if references.hasDynamicRequire {
                dynamicRequireFiles.append(file)
            }

            for reference in references.items {
                switch resolve(reference.target, rootURL: root, isLua: isLua, canonicalByKey: canonicalByKey) {
                case .file(let target):
                    edges.append(
                        ConfigGraphEdge(from: file, to: target, line: reference.line, text: reference.text)
                    )
                    queue.append(target)
                case .missing:
                    // A plain string that names a module is only a hint, so
                    // it is dropped when it points nowhere.
                    guard reference.isRequireCall else { continue }
                    missingTargets.append(
                        ConfigGraphMissingTarget(from: file, line: reference.line, target: reference.target)
                    )
                case .external:
                    continue
                }
            }
        }

        let reachableKeys = visited
        let reachableFiles = files.filter { reachableKeys.contains(Self.key(for: $0)) }
        let orphanFiles = files.filter { !reachableKeys.contains(Self.key(for: $0)) }

        return ConfigGraphReport(
            entrypoints: entrypoints,
            edges: edges.sorted { ($0.from.path, $0.line) < ($1.from.path, $1.line) },
            reachableFiles: reachableFiles.sorted { $0.path < $1.path },
            orphanFiles: orphanFiles.sorted { $0.path < $1.path },
            missingTargets: missingTargets.sorted { ($0.from.path, $0.line) < ($1.from.path, $1.line) },
            cycles: findCycles(in: edges),
            dynamicRequireFiles: dynamicRequireFiles.sorted { $0.path < $1.path }
        )
    }

    // MARK: - Entrypoints

    private func entrypoints(in rootURL: URL) -> [URL] {
        Self.entrypointNames
            .map { rootURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Loader lines

    /// One loader call found in a file.
    private struct LoaderReference {
        let line: Int
        let text: String
        let target: String
        /// True for a require call, false for a plain string that names a
        /// module. Only a require call that points nowhere is worth
        /// reporting.
        let isRequireCall: Bool
    }

    private struct FileReferences {
        let items: [LoaderReference]
        /// True when the file requires a name it computes at runtime.
        let hasDynamicRequire: Bool
    }

    /// Finds the loader calls of a file. A commented loader line counts as a
    /// reference, the same way the activation service treats it, so an item
    /// that is switched off is not reported as a dead file.
    private func loaderReferences(in contents: String, isLua: Bool) -> FileReferences {
        if isLua {
            return luaReferences(in: contents)
        }
        return FileReferences(items: shellReferences(in: contents), hasDynamicRequire: false)
    }

    /// A Lua file is scanned for require calls and for the module names that
    /// configs keep in a table, such as the item list of a setup.
    private func luaReferences(in contents: String) -> FileReferences {
        var items: [LoaderReference] = []
        var hasDynamicRequire = false

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)

            if Self.matches(Self.luaDynamicRequirePattern, in: text, range: range) {
                hasDynamicRequire = true
            }
            if let argument = Self.firstCapture(Self.luaDynamicPCallPattern, in: text, range: range),
               !Self.isPlainLiteral(argument) {
                hasDynamicRequire = true
            }

            for literal in Self.literals(in: text, range: range) {
                let prefix = String(text[text.startIndex..<literal.start])
                let isRequireCall = Self.isRequirePrefix(prefix)
                // A plain string only counts as a module name when it looks
                // like a path, so words like "default" do not point at a
                // file.
                guard isRequireCall || Self.looksLikeModuleName(literal.value) else { continue }

                items.append(
                    LoaderReference(
                        line: index + 1,
                        text: isRequireCall ? text.trimmingCharacters(in: .whitespaces) : literal.value,
                        target: literal.value,
                        isRequireCall: isRequireCall
                    )
                )
            }
        }

        return FileReferences(items: items, hasDynamicRequire: hasDynamicRequire)
    }

    /// A shell line is a loader line when the whole line is a `source` or
    /// `.` call.
    private func shellReferences(in contents: String) -> [LoaderReference] {
        var items: [LoaderReference] = []

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)

            for regex in Self.shellLoaderPatterns {
                guard let match = regex.firstMatch(in: text, range: range) else { continue }

                for captureIndex in 1..<match.numberOfRanges where match.range(at: captureIndex).location != NSNotFound {
                    guard let captureRange = Range(match.range(at: captureIndex), in: text) else { continue }
                    items.append(
                        LoaderReference(
                            line: index + 1,
                            text: text.trimmingCharacters(in: .whitespaces),
                            target: String(text[captureRange]),
                            isRequireCall: true
                        )
                    )
                    break
                }
            }
        }

        return items
    }

    /// The string literals of a line with the place they sit at.
    private static func literals(in text: String, range: NSRange) -> [(value: String, start: String.Index)] {
        guard let regex = try? NSRegularExpression(pattern: luaLiteralPattern) else { return [] }

        var found: [(value: String, start: String.Index)] = []
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range(at: 0), in: text) else { continue }
            let raw = String(text[whole])
            found.append((unescape(String(raw.dropFirst().dropLast())), whole.lowerBound))
        }
        return found
    }

    /// True when the text before a literal ends in a require call.
    private static func isRequirePrefix(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return matches(luaRequireCallPattern, in: trimmed, range: range)
            || matches(luaRequireWordPattern, in: trimmed, range: range)
    }

    /// True when the text names a module instead of being a word.
    private static func looksLikeModuleName(_ text: String) -> Bool {
        text.contains(".") || text.contains("/")
    }

    /// A file is Lua when it ends in `.lua`, when its first line asks for
    /// Lua, or when it requires Lua modules.
    private static func isLuaSource(url: URL, contents: String) -> Bool {
        if url.pathExtension.lowercased() == "lua" { return true }

        let firstLine = contents.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#!") { return firstLine.lowercased().contains("lua") }

        return contents.contains("require(")
    }

    /// True when the text is one plain quoted string.
    private static func isPlainLiteral(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        let first = trimmed.first
        let last = trimmed.last
        guard first == "\"" || first == "'" else { return false }
        return last == first
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func matches(_ pattern: String, in text: String, range: NSRange) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func firstCapture(_ pattern: String, in text: String, range: NSRange) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            guard let capture = Range(match.range(at: index), in: text) else { continue }
            return String(text[capture])
        }
        return nil
    }

    // MARK: - Targets

    private enum ResolvedTarget {
        case file(URL)
        /// The target is inside the config but no file sits there.
        case missing
        /// The target points outside the config, so it is not its business.
        case external
    }

    /// Resolves a loader target the way SketchyBar does: `items/left/clock`
    /// and `items.left.clock` both mean `items/left/clock.lua`, while a bare
    /// `clock` only means a file in the config root. A module name can also
    /// be a folder with an `init.lua` in it, the way Lua loads modules.
    private func resolve(
        _ rawTarget: String,
        rootURL: URL,
        isLua: Bool,
        canonicalByKey: [String: URL]
    ) -> ResolvedTarget {
        let target = normalize(rawTarget, rootURL: rootURL)
        guard !target.isEmpty else { return .external }
        if Self.runtimeModules.contains(target.lowercased()) { return .external }
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else { return .external }
        // A module name starts with a letter, a digit, or an underscore.
        // Everything else is not a name at all.
        guard let first = target.first, first.isLetter || first.isNumber || first == "_" else { return .external }

        for relative in candidatePaths(for: target, isLua: isLua) {
            let url = rootURL.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            return .file(canonicalByKey[Self.key(for: url)] ?? url)
        }

        return .missing
    }

    /// Strips the parts of a target that only say where the config lives.
    private func normalize(_ rawTarget: String, rootURL: URL) -> String {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)

        if (target.hasPrefix("\"") && target.hasSuffix("\"")) ||
            (target.hasPrefix("'") && target.hasSuffix("'")) {
            target = String(target.dropFirst().dropLast())
        }

        for root in [rootURL, rootURL.resolvingSymlinksInPath()] {
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if target.hasPrefix(prefix) {
                target.removeFirst(prefix.count)
                break
            }
        }

        let configPrefixes = [
            "$config_dir/",
            "${config_dir}/",
            "$sketchybar_config_dir/",
            "${sketchybar_config_dir}/",
            "$home/.config/sketchybar/",
            "${home}/.config/sketchybar/",
            "~/.config/sketchybar/"
        ]
        if let prefix = configPrefixes.first(where: { target.hasPrefix($0) }) {
            target.removeFirst(prefix.count)
        }
        while target.hasPrefix("./") {
            target.removeFirst(2)
        }

        return target
    }

    /// The paths a target can point at, most likely first.
    private func candidatePaths(for target: String, isLua: Bool) -> [String] {
        let targetExtension = (target as NSString).pathExtension.lowercased()

        var bases: [String]
        if Self.knownExtensions.contains(targetExtension) {
            bases = [target]
        } else if isLua, target.contains("."), !target.contains("/") {
            bases = [target.replacingOccurrences(of: ".", with: "/"), target]
        } else {
            bases = [target]
        }

        var candidates: [String] = []
        for base in bases {
            if !Self.knownExtensions.contains((base as NSString).pathExtension.lowercased()) {
                if isLua {
                    // Lua loads a module from `name.lua` or from `name/init.lua`.
                    candidates.append(base + ".lua")
                    candidates.append(base + "/init.lua")
                } else {
                    candidates.append(contentsOf: [base + ".sh", base + ".bash", base + ".zsh"])
                }
            }
            candidates.append(base)
        }

        return candidates
    }

    // MARK: - Cycles

    /// Finds the require cycles of the graph. Every cycle is reported once,
    /// no matter which file the walk started at.
    private func findCycles(in edges: [ConfigGraphEdge]) -> [[URL]] {
        var adjacency: [String: [String]] = [:]
        var urlsByKey: [String: URL] = [:]
        for edge in edges {
            let from = Self.key(for: edge.from)
            let to = Self.key(for: edge.to)
            adjacency[from, default: []].append(to)
            urlsByKey[from] = edge.from
            urlsByKey[to] = edge.to
        }

        var state: [String: Int] = [:]
        var path: [String] = []
        var cycles: [[String]] = []
        var seen: Set<String> = []

        func visit(_ node: String) {
            state[node] = 1
            path.append(node)

            for next in adjacency[node] ?? [] {
                if state[next] == 1, let index = path.firstIndex(of: next) {
                    let cycle = canonical(Array(path[index...]))
                    if seen.insert(cycle.joined(separator: ">")).inserted {
                        cycles.append(cycle)
                    }
                } else if state[next] == nil {
                    visit(next)
                }
            }

            path.removeLast()
            state[node] = 2
        }

        for node in adjacency.keys.sorted() where state[node] == nil {
            visit(node)
        }

        return cycles.map { cycle in
            cycle.compactMap { urlsByKey[$0] }
        }
    }

    /// Turns a cycle into one fixed order, so the same cycle is not reported
    /// twice with the files in a different order.
    private func canonical(_ cycle: [String]) -> [String] {
        guard let index = cycle.indices.min(by: { cycle[$0] < cycle[$1] }) else { return cycle }
        return Array(cycle[index...]) + Array(cycle[..<index])
    }

    // MARK: - Files

    /// Folders the analysis skips: the backup mirror, git data, and hidden
    /// files. The hidden entrypoint `.sketchybarrc` stays.
    private func isExcluded(_ url: URL, rootURL: URL) -> Bool {
        let components = relativeComponents(of: url, from: rootURL)
        guard let name = components.last else { return false }

        for component in components.dropLast() {
            if component == "backups" || component == ".git" || component.hasPrefix(".") {
                return true
            }
        }

        if name.hasPrefix(".") {
            return !(components.count == 1 && name == ".sketchybarrc")
        }

        return false
    }

    private func relativeComponents(of url: URL, from rootURL: URL) -> [String] {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else {
            return [url.lastPathComponent]
        }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    /// The path a file is known by, with the symlinks resolved. The name is
    /// folded, because macOS does not tell a file with another case apart.
    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}
