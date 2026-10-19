import Foundation

enum MoveDirection {
    case up
    case down
}

enum ActivationUpdateError: LocalizedError {
    case referenceChanged(URL)

    var errorDescription: String? {
        switch self {
        case .referenceChanged(let entrypointURL):
            return "Loader references in \(entrypointURL.lastPathComponent) changed on disk. Reload before updating their order or activation."
        }
    }
}

struct ConfigActivationService {
    private let backupService = ConfigBackupService()
    private let replacer = SafeFileReplacer()
    private static let luaLoaderPatterns = [
        #"^\s*require\s*\(\s*["']([^"']+)["']\s*\)\s*;?\s*(?:--.*)?$"#,
        #"^\s*require\s+["']([^"']+)["']\s*;?\s*(?:--.*)?$"#,
        #"^\s*(?:dofile|loadfile)\s*\(\s*["']([^"']+)["']\s*\)\s*(?:\(\s*\))?\s*;?\s*(?:--.*)?$"#,
        #"^\s*sbar\.exec\s*\(\s*["']([^"']+)["']\s*\)\s*;?\s*(?:--.*)?$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let shellLoaderPatterns = [
        #"^\s*(?:source|\.)\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;#]+))\s*;?\s*(?:#.*)?$"#,
        #"^\s*(?:bash|zsh|sh)\s+(?:\"([^\"]+)\"|'([^']+)'|([^\s;#]+))\s*;?\s*(?:#.*)?$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    func reference(for fileURL: URL, rootURL: URL) -> ActivationReference? {
        references(for: [fileURL], rootURL: rootURL)[fileURL.path]
    }

    func references(for fileURLs: [URL], rootURL: URL) -> [String: ActivationReference] {
        let candidates = fileURLs
            .filter { canToggle(fileURL: $0, rootURL: rootURL) }
            .map { ActivationLookupCandidate(fileURL: $0, targets: matchTargets(fileURL: $0, rootURL: rootURL)) }
            .filter { !$0.targets.isEmpty }
        var matchesByFile: [String: [ActivationMatch]] = [:]

        for entrypoint in entrypoints(in: rootURL) {
            guard let contents = try? readText(entrypoint) else { continue }

            for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard let target = loaderTarget(in: text, entrypointURL: entrypoint) else {
                    continue
                }

                let parsedTargets = normalizedTargetForms(target, rootURL: rootURL)
                let matched = candidates.filter { !$0.targets.isDisjoint(with: parsedTargets) }
                guard matched.count == 1 else { continue }

                matchesByFile[matched[0].fileURL.path, default: []].append(
                    ActivationMatch(
                        entrypointURL: entrypoint,
                        lineNumber: offset + 1,
                        isActive: !isCommented(text)
                    )
                )
            }
        }

        return matchesByFile.mapValues { matches in
            ActivationReference(
                entrypointURL: matches[0].entrypointURL,
                lineNumber: matches[0].lineNumber,
                isActive: matches.contains { $0.isActive },
                matches: matches
            )
        }
    }

    func moveReference(for file: ConfigFile, direction: MoveDirection) throws {
        guard let reference = file.activationReference else { return }
        let contents = try readText(reference.entrypointURL)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = reference.lineNumber - 1
        guard lines.indices.contains(index),
              line(lines[index], references: file, entrypointURL: reference.entrypointURL) else {
            throw ActivationUpdateError.referenceChanged(reference.entrypointURL)
        }

        let loaderIndices = lines.indices.filter {
            loaderTarget(in: lines[$0], entrypointURL: reference.entrypointURL) != nil
        }
        guard let currentPosition = loaderIndices.firstIndex(of: index) else {
            throw ActivationUpdateError.referenceChanged(reference.entrypointURL)
        }
        let targetPosition = direction == .up ? currentPosition - 1 : currentPosition + 1
        guard loaderIndices.indices.contains(targetPosition) else { return }
        let targetIndex = loaderIndices[targetPosition]
        lines.swapAt(index, targetIndex)
        try writeIfChanged(
            lines: lines,
            originalContents: contents,
            entrypointURL: reference.entrypointURL,
            rootURL: file.rootURL
        )
    }

    func moveReference(for file: ConfigFile, before targetFile: ConfigFile) throws {
        guard let source = file.activationReference,
              let target = targetFile.activationReference,
              source.entrypointURL == target.entrypointURL else {
            return
        }

        let contents = try readText(source.entrypointURL)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sourceIndex = source.lineNumber - 1
        let targetIndex = target.lineNumber - 1
        guard lines.indices.contains(sourceIndex),
              lines.indices.contains(targetIndex),
              sourceIndex != targetIndex else {
            return
        }
        guard line(lines[sourceIndex], references: file, entrypointURL: source.entrypointURL),
              line(lines[targetIndex], references: targetFile, entrypointURL: target.entrypointURL) else {
            throw ActivationUpdateError.referenceChanged(source.entrypointURL)
        }

        let loaderIndices = lines.indices.filter {
            loaderTarget(in: lines[$0], entrypointURL: source.entrypointURL) != nil
        }
        guard let sourcePosition = loaderIndices.firstIndex(of: sourceIndex),
              let targetPosition = loaderIndices.firstIndex(of: targetIndex) else {
            throw ActivationUpdateError.referenceChanged(source.entrypointURL)
        }

        var loaderLines = loaderIndices.map { lines[$0] }
        let movedLine = loaderLines.remove(at: sourcePosition)
        let insertionPosition = sourcePosition < targetPosition ? targetPosition - 1 : targetPosition
        loaderLines.insert(movedLine, at: insertionPosition)
        for (lineIndex, loaderLine) in zip(loaderIndices, loaderLines) {
            lines[lineIndex] = loaderLine
        }
        try writeIfChanged(
            lines: lines,
            originalContents: contents,
            entrypointURL: source.entrypointURL,
            rootURL: file.rootURL
        )
    }

    func moveReferences(in files: [ConfigFile], to orderedFileIDs: [ConfigFile.ID]) throws {
        var orderByID: [ConfigFile.ID: Int] = [:]
        for (index, id) in orderedFileIDs.enumerated() where orderByID[id] == nil {
            orderByID[id] = index
        }

        let eligibleFiles = files.filter {
            $0.activationReference != nil && orderByID[$0.id] != nil
        }
        let filesByRoot = Dictionary(grouping: eligibleFiles) { $0.rootURL.standardizedFileURL.path }

        for rootFiles in filesByRoot.values {
            guard let rootURL = rootFiles.first?.rootURL else { continue }
            let currentReferences = references(for: rootFiles.map(\.url), rootURL: rootURL)
            for file in rootFiles where currentReferences[file.url.path] == nil {
                throw ActivationUpdateError.referenceChanged(
                    file.activationReference?.entrypointURL ?? rootURL
                )
            }

            var filesByEntrypoint: [String: [ConfigFile]] = [:]
            for file in rootFiles {
                guard let reference = currentReferences[file.url.path] else {
                    throw ActivationUpdateError.referenceChanged(
                        file.activationReference?.entrypointURL ?? rootURL
                    )
                }
                filesByEntrypoint[reference.entrypointURL.standardizedFileURL.path, default: []].append(file)
            }
            for entrypointFiles in filesByEntrypoint.values {
                guard let firstFile = entrypointFiles.first,
                      let entrypointURL = currentReferences[firstFile.url.path]?.entrypointURL else {
                    continue
                }

                let desiredFiles = entrypointFiles.sorted {
                    orderByID[$0.id, default: .max] < orderByID[$1.id, default: .max]
                }
                guard desiredFiles.count > 1 else { continue }
                let contents = try readText(entrypointURL)
                var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                var lineByFileID: [ConfigFile.ID: String] = [:]
                var loaderSlots: [Int] = []

                for file in desiredFiles {
                    guard let reference = currentReferences[file.url.path] else {
                        throw ActivationUpdateError.referenceChanged(entrypointURL)
                    }
                    let lineIndex = reference.lineNumber - 1
                    guard lines.indices.contains(lineIndex),
                          line(lines[lineIndex], references: file, entrypointURL: entrypointURL) else {
                        throw ActivationUpdateError.referenceChanged(entrypointURL)
                    }
                    loaderSlots.append(lineIndex)
                    lineByFileID[file.id] = lines[lineIndex]
                }

                loaderSlots.sort()
                for (lineIndex, file) in zip(loaderSlots, desiredFiles) {
                    guard let loaderLine = lineByFileID[file.id] else {
                        throw ActivationUpdateError.referenceChanged(entrypointURL)
                    }
                    lines[lineIndex] = loaderLine
                }
                try writeIfChanged(
                    lines: lines,
                    originalContents: contents,
                    entrypointURL: entrypointURL,
                    rootURL: rootURL
                )
            }
        }
    }

    /// Comments or uncomments every loader line that references the file, so
    /// a file loaded from two entrypoints toggles in both places.
    func setActive(_ isActive: Bool, for file: ConfigFile) throws {
        guard let reference = file.activationReference else {
            return
        }

        let matchesByEntrypoint = Dictionary(grouping: reference.allMatches) {
            $0.entrypointURL.standardizedFileURL.path
        }

        for entrypointPath in matchesByEntrypoint.keys.sorted() {
            let matches = matchesByEntrypoint[entrypointPath] ?? []
            guard let entrypointURL = matches.first?.entrypointURL else { continue }
            let contents = try readText(entrypointURL)
            var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            for match in matches {
                let index = match.lineNumber - 1
                guard lines.indices.contains(index),
                      line(lines[index], references: file, entrypointURL: entrypointURL) else {
                    throw ActivationUpdateError.referenceChanged(entrypointURL)
                }
                lines[index] = isActive ? uncomment(lines[index]) : comment(lines[index], entrypointURL: entrypointURL)
            }

            try writeIfChanged(
                lines: lines,
                originalContents: contents,
                entrypointURL: entrypointURL,
                rootURL: file.rootURL
            )
        }
    }

    private func line(_ line: String, references file: ConfigFile, entrypointURL: URL) -> Bool {
        guard let target = loaderTarget(in: line, entrypointURL: entrypointURL) else {
            return false
        }
        return !matchTargets(fileURL: file.url, rootURL: file.rootURL)
            .isDisjoint(with: normalizedTargetForms(target, rootURL: file.rootURL))
    }

    /// Writes the entrypoint only when it still holds the content the change
    /// was computed from, so an external edit is never overwritten.
    private func writeIfChanged(
        lines: [String],
        originalContents: String,
        entrypointURL: URL,
        rootURL: URL
    ) throws {
        let updatedContents = lines.joined(separator: "\n")
        guard updatedContents != originalContents else { return }

        let currentContents = try readText(entrypointURL)
        guard currentContents == originalContents else {
            throw ActivationUpdateError.referenceChanged(entrypointURL)
        }

        _ = try backupService.backup(fileURL: entrypointURL, rootURL: rootURL)

        let finalContents = try readText(entrypointURL)
        guard finalContents == originalContents else {
            throw ActivationUpdateError.referenceChanged(entrypointURL)
        }

        try replacer.writeAtomicallyPreservingSymlinks(updatedContents, to: entrypointURL)
    }

    /// Reads an entrypoint without a leading byte-order mark so the first
    /// line matches loader patterns like every other line.
    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).strippingByteOrderMark()
    }

    private func entrypoints(in rootURL: URL) -> [URL] {
        [
            rootURL.appendingPathComponent("init.lua"),
            rootURL.appendingPathComponent("sketchybarrc"),
            rootURL.appendingPathComponent(".sketchybarrc"),
            rootURL.appendingPathComponent("init.sh"),
            rootURL.appendingPathComponent("loader.sh")
        ]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isCommented(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("--") || trimmed.hasPrefix("#")
    }

    private func comment(_ line: String, entrypointURL: URL) -> String {
        if isCommented(line) {
            return line
        }

        let marker = entrypointURL.pathExtension.lowercased() == "lua" ? "-- " : "# "
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return indent + marker + String(line.dropFirst(indent.count))
    }

    private func uncomment(_ line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var rest = String(line.dropFirst(indent.count))
        if rest.hasPrefix("-- ") {
            rest.removeFirst(3)
        } else if rest.hasPrefix("--") {
            rest.removeFirst(2)
        } else if rest.hasPrefix("# ") {
            rest.removeFirst(2)
        } else if rest.hasPrefix("#") {
            rest.removeFirst(1)
        }
        return indent + rest
    }

    /// Loader targets that select this file. Bare names only count for files
    /// in the config root: SketchyBar resolves `require("battery")` to
    /// `<root>/battery.lua`, never to `items/battery.lua`.
    private func matchTargets(fileURL: URL, rootURL: URL) -> Set<String> {
        let relative = relativePath(for: fileURL, rootURL: rootURL)
        let noExtension = (relative as NSString).deletingPathExtension
        let dotted = noExtension.replacingOccurrences(of: "/", with: ".")

        var targets = Set([
            relative.lowercased(),
            noExtension.lowercased(),
            dotted.lowercased()
        ])

        if !relative.contains("/") {
            targets.insert(fileURL.lastPathComponent.lowercased())
            targets.insert(fileURL.deletingPathExtension().lastPathComponent.lowercased())
        }

        return targets.filter { !$0.isEmpty }
    }

    private func loaderTarget(in line: String, entrypointURL: URL) -> String? {
        let isLua = entrypointURL.pathExtension.lowercased() == "lua"
        var statement = line.trimmingCharacters(in: .whitespaces)

        if isLua, statement.hasPrefix("--") {
            statement.removeFirst(2)
            statement = statement.trimmingCharacters(in: .whitespaces)
        } else if !isLua, statement.hasPrefix("#") {
            statement.removeFirst()
            statement = statement.trimmingCharacters(in: .whitespaces)
        }

        let patterns = isLua ? Self.luaLoaderPatterns : Self.shellLoaderPatterns
        let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: statement, range: range) else {
                continue
            }

            for captureIndex in 1..<match.numberOfRanges where match.range(at: captureIndex).location != NSNotFound {
                if let captureRange = Range(match.range(at: captureIndex), in: statement) {
                    return String(statement[captureRange])
                }
            }
        }

        return nil
    }

    private func normalizedTargetForms(_ loaderTarget: String, rootURL: URL) -> Set<String> {
        var target = loaderTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let commandPrefixes = ["source ", ". ", "bash ", "zsh ", "sh "]
        if let prefix = commandPrefixes.first(where: { target.hasPrefix($0) }) {
            target.removeFirst(prefix.count)
            target = target.trimmingCharacters(in: .whitespaces)
        }

        if (target.hasPrefix("\"") && target.hasSuffix("\"")) ||
            (target.hasPrefix("'") && target.hasSuffix("'")) {
            target = String(target.dropFirst().dropLast())
        }

        let rootPath = rootURL.standardizedFileURL.path.lowercased()
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if target.hasPrefix(rootPrefix) {
            target.removeFirst(rootPrefix.count)
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

        guard !target.isEmpty else { return [] }
        var forms: Set<String> = [target]
        let pathExtension = (target as NSString).pathExtension
        if ["lua", "sh", "bash", "zsh"].contains(pathExtension) {
            forms.insert((target as NSString).deletingPathExtension)
        }
        return forms
    }

    private func canToggle(fileURL: URL, rootURL: URL) -> Bool {
        let relative = relativePath(for: fileURL, rootURL: rootURL).lowercased()
        let coreFiles: Set<String> = [
            "init.lua",
            "bar.lua",
            "colors.lua",
            "theme.lua",
            "themes.lua",
            "sketchybarrc",
            ".sketchybarrc",
            "init.sh",
            "loader.sh"
        ]

        return !coreFiles.contains(relative)
    }

    private func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

}

private struct ActivationLookupCandidate {
    let fileURL: URL
    let targets: Set<String>
}

private extension String {
    func strippingByteOrderMark() -> String {
        hasPrefix("\u{FEFF}") ? String(dropFirst()) : self
    }
}
