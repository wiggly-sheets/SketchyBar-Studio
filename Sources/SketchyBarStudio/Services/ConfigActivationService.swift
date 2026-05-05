import Foundation

struct ConfigActivationService {
    func reference(for fileURL: URL, rootURL: URL) -> ActivationReference? {
        guard canToggle(fileURL: fileURL, rootURL: rootURL) else {
            return nil
        }

        let candidates = entrypoints(in: rootURL)
        let fileTokens = matchTokens(fileURL: fileURL, rootURL: rootURL)

        for entrypoint in candidates {
            guard let contents = try? String(contentsOf: entrypoint, encoding: .utf8) else {
                continue
            }

            var lineNumber = 1
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                if matchesReferenceLine(text, tokens: fileTokens, entrypointURL: entrypoint) {
                    return ActivationReference(
                        entrypointURL: entrypoint,
                        lineNumber: lineNumber,
                        isActive: !isCommented(text)
                    )
                }
                lineNumber += 1
            }
        }

        return nil
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
        try lines.joined(separator: "\n").write(to: reference.entrypointURL, atomically: true, encoding: .utf8)
    }

    private func entrypoints(in rootURL: URL) -> [URL] {
        var urls = [
            rootURL.appendingPathComponent("init.lua"),
            rootURL.appendingPathComponent("sketchybarrc"),
            rootURL.appendingPathComponent(".sketchybarrc")
        ]

        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                if name == "init.lua" ||
                    name == "sketchybarrc" ||
                    name == ".sketchybarrc" ||
                    ext == "sh" ||
                    ext == "bash" ||
                    ext == "zsh" {
                    urls.append(url)
                }
            }
        }

        return Array(Set(urls))
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
        return indent + marker + line.dropFirst(indent.count)
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
        let relative = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
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

    private func matchesReferenceLine(_ line: String, tokens: [String], entrypointURL: URL) -> Bool {
        let uncommented = uncomment(line)
        let normalized = normalizedToken(uncommented)
        guard !normalized.isEmpty else {
            return false
        }

        if entrypointURL.pathExtension.lowercased() == "lua" {
            guard normalized.contains("require(") ||
                    normalized.contains("dofile(") ||
                    normalized.contains("loadfile(") ||
                    normalized.contains("sbar.exec(") else {
                return false
            }
        } else {
            guard normalized.contains("source ") ||
                    normalized.contains(". ") ||
                    normalized.contains("bash ") ||
                    normalized.contains("zsh ") ||
                    normalized.contains("sh ") ||
                    normalized.contains("/") else {
                return false
            }
        }

        return tokens.contains { normalized.contains($0) }
    }

    private func canToggle(fileURL: URL, rootURL: URL) -> Bool {
        let relative = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "").lowercased()
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
