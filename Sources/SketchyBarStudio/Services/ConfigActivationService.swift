import Foundation

enum MoveDirection {
    case up
    case down
}

struct ConfigActivationService {
    private let backupService = ConfigBackupService()

    func reference(for fileURL: URL, rootURL: URL) -> ActivationReference? {
        references(for: [fileURL], rootURL: rootURL)[fileURL.path]
    }

    func references(for fileURLs: [URL], rootURL: URL) -> [String: ActivationReference] {
        var pending = fileURLs
            .filter { canToggle(fileURL: $0, rootURL: rootURL) }
            .map { ActivationLookupCandidate(fileURL: $0, tokens: matchTokens(fileURL: $0, rootURL: rootURL)) }
            .filter { !$0.tokens.isEmpty }
        var results: [String: ActivationReference] = [:]

        for entrypoint in entrypoints(in: rootURL) {
            guard !pending.isEmpty,
                  let contents = try? String(contentsOf: entrypoint, encoding: .utf8) else {
                continue
            }

            for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard !pending.isEmpty else { return results }
                let text = String(line)
                guard let normalized = normalizedReferenceLine(text, entrypointURL: entrypoint) else {
                    continue
                }

                guard let matchIndex = bestMatchIndex(in: pending, normalizedLine: normalized) else {
                    continue
                }

                let candidate = pending.remove(at: matchIndex)
                results[candidate.fileURL.path] = ActivationReference(
                    entrypointURL: entrypoint,
                    lineNumber: offset + 1,
                    isActive: !isCommented(text)
                )
            }
        }

        return results
    }

    private func bestMatchIndex(in candidates: [ActivationLookupCandidate], normalizedLine: String) -> Int? {
        var bestIndex: Int?
        var bestTokenLength = 0

        for (index, candidate) in candidates.enumerated() {
            guard let token = candidate.tokens.first(where: { normalizedLine.contains($0) }) else {
                continue
            }

            if token.count > bestTokenLength {
                bestTokenLength = token.count
                bestIndex = index
            }
        }

        return bestIndex
    }

    func moveReference(for file: ConfigFile, direction: MoveDirection) throws {
        guard let reference = file.activationReference else { return }
        let contents = try String(contentsOf: reference.entrypointURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = reference.lineNumber - 1
        let targetIndex = direction == .up ? index - 1 : index + 1
        guard lines.indices.contains(index), lines.indices.contains(targetIndex) else { return }
        lines.swapAt(index, targetIndex)
        _ = try backupService.backup(fileURL: reference.entrypointURL, rootURL: file.rootURL)
        try lines.joined(separator: "\n").write(to: reference.entrypointURL, atomically: true, encoding: .utf8)
    }

    func moveReference(for file: ConfigFile, before targetFile: ConfigFile) throws {
        guard let source = file.activationReference,
              let target = targetFile.activationReference,
              source.entrypointURL == target.entrypointURL else {
            return
        }

        let contents = try String(contentsOf: source.entrypointURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sourceIndex = source.lineNumber - 1
        let targetIndex = target.lineNumber - 1
        guard lines.indices.contains(sourceIndex),
              lines.indices.contains(targetIndex),
              sourceIndex != targetIndex else {
            return
        }

        let line = lines.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        lines.insert(line, at: insertionIndex)
        _ = try backupService.backup(fileURL: source.entrypointURL, rootURL: file.rootURL)
        try lines.joined(separator: "\n").write(to: source.entrypointURL, atomically: true, encoding: .utf8)
    }

    func setActive(_ isActive: Bool, for file: ConfigFile) throws {
        guard let reference = file.activationReference else {
            return
        }

        let contents = try String(contentsOf: reference.entrypointURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = reference.lineNumber - 1
        guard lines.indices.contains(index) else {
            return
        }

        lines[index] = isActive ? uncomment(lines[index]) : comment(lines[index], entrypointURL: reference.entrypointURL)
        _ = try backupService.backup(fileURL: reference.entrypointURL, rootURL: file.rootURL)
        try lines.joined(separator: "\n").write(to: reference.entrypointURL, atomically: true, encoding: .utf8)
    }

    private func entrypoints(in rootURL: URL) -> [URL] {
        let fixedEntrypoints = [
            rootURL.appendingPathComponent("init.lua"),
            rootURL.appendingPathComponent("sketchybarrc"),
            rootURL.appendingPathComponent(".sketchybarrc")
        ]
        var urls = Set(fixedEntrypoints)

        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if isBackupDirectory(url, rootURL: rootURL) {
                    enumerator.skipDescendants()
                    continue
                }

                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }

                let name = url.lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                if name == "init.lua" ||
                    name == "sketchybarrc" ||
                    name == ".sketchybarrc" ||
                    ext == "sh" ||
                    ext == "bash" ||
                    ext == "zsh" {
                    urls.insert(url)
                }
            }
        }

        return urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isBackupDirectory(_ url: URL, rootURL: URL) -> Bool {
        let relative = relativePath(for: url, rootURL: rootURL)
        return relative == "backups"
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

    private func matchTokens(fileURL: URL, rootURL: URL) -> [String] {
        let relative = relativePath(for: fileURL, rootURL: rootURL)
        let noExtension = (relative as NSString).deletingPathExtension
        let dotted = noExtension.replacingOccurrences(of: "/", with: ".")
        let baseName = fileURL.deletingPathExtension().lastPathComponent

        var tokens = [
            normalizedToken(fileURL.lastPathComponent),
            normalizedToken(relative),
            normalizedToken(noExtension),
            normalizedToken(dotted)
        ]

        if baseName.count >= 4 {
            tokens.append(normalizedToken(baseName))
        }

        return Array(Set(tokens.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    private func normalizedReferenceLine(_ line: String, entrypointURL: URL) -> String? {
        let uncommented = uncomment(line)
        let normalized = normalizedToken(uncommented)
        guard !normalized.isEmpty else {
            return nil
        }

        if entrypointURL.pathExtension.lowercased() == "lua" {
            guard normalized.contains("require(") ||
                    normalized.contains("dofile(") ||
                    normalized.contains("loadfile(") ||
                    normalized.contains("sbar.exec(") else {
                return nil
            }
        } else {
            guard normalized.contains("source ") ||
                    normalized.contains(". ") ||
                    normalized.contains("bash ") ||
                    normalized.contains("zsh ") ||
                    normalized.contains("sh ") ||
                    normalized.contains("/") else {
                return nil
            }
        }

        return normalized
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
            ".sketchybarrc"
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

    private func normalizedToken(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "./", with: "")
            .replacingOccurrences(of: "$config_dir/", with: "")
            .replacingOccurrences(of: "$CONFIG_DIR/", with: "")
            .replacingOccurrences(of: "${config_dir}/", with: "")
            .replacingOccurrences(of: "${CONFIG_DIR}/", with: "")
            .replacingOccurrences(of: ".lua", with: "")
            .replacingOccurrences(of: ".sh", with: "")
            .replacingOccurrences(of: ".bash", with: "")
            .replacingOccurrences(of: ".zsh", with: "")
            .replacingOccurrences(of: "_", with: "-")
    }
}

private struct ActivationLookupCandidate {
    let fileURL: URL
    let tokens: [String]
}
