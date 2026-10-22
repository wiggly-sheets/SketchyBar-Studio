import Foundation

/// Finds the problems in a shell-based SketchyBar config.
///
/// The service only reads the config. It never writes, moves or deletes a
/// file.
public struct ShellDiagnosticService: Sendable {
    /// One problem the service found in a shell config.
    public struct Diagnostic: Sendable {
        /// The stable id of the problem.
        public let id: String
        /// How bad the problem is.
        public let severity: Severity
        /// The kind of problem.
        public let kind: Kind
        /// One short line that names the problem.
        public let title: String
        /// A second line that explains the problem.
        public let detail: String?
        /// The file the problem is in.
        public let fileURL: URL
        /// The line of the file the problem is on.
        public let line: Int?
        /// The option or the alias the problem is about.
        public let keyPath: String?
    }

    /// How bad the problem is.
    public enum Severity: Int, Comparable, Sendable {
        case error
        case warning
        case info

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The kind of problem.
    public enum Kind: String, Sendable {
        /// The same alias is added twice.
        case duplicateAlias
        /// An item is set but never added.
        case missingLabel
        /// A script path points at a file that is gone.
        case missingFile
        /// A loader line points at a file that is gone.
        case brokenLoader
    }

    /// The problems of the shell config at the given file and root.
    public func diagnose(file: URL, root: URL) -> [Diagnostic] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }

        var diagnostics: [Diagnostic] = []
        let commands = ShellConfigCommandParser.parse(in: contents)

        // Missing label: items that are set but never added
        for warning in commands.warnings {
            if warning.contains("is set but never added") {
                // Extract alias from warning: "The item 'alias' is set but never added, so the preview cannot show it."
                let alias = extractAlias(from: warning, pattern: "The item '([^']+)' is set but never added")
                if let alias {
                    diagnostics.append(Diagnostic(
                        id: "missingLabel:\(file.path):\(alias)",
                        severity: .warning,
                        kind: .missingLabel,
                        title: "Item '\(alias)' set but never added",
                        detail: "The item is set but never added, so SketchyBar ignores it.",
                        fileURL: file,
                        line: nil,
                        keyPath: alias
                    ))
                }
            } else if warning.contains("is added without a position") {
                let alias = extractAlias(from: warning, pattern: "The item '([^']+)' is added without a position")
                if let alias {
                    diagnostics.append(Diagnostic(
                        id: "missingLabel:\(file.path):\(alias)",
                        severity: .warning,
                        kind: .missingLabel,
                        title: "Item '\(alias)' added without position",
                        detail: "The item is added without a position, so SketchyBar removes it.",
                        fileURL: file,
                        line: nil,
                        keyPath: alias
                    ))
                }
            } else if warning.contains("holds no SketchyBar command") {
                diagnostics.append(Diagnostic(
                    id: "missingLabel:\(file.path):noCommand",
                    severity: .info,
                    kind: .missingLabel,
                    title: "No SketchyBar command",
                    detail: "The file holds no SketchyBar command, so it adds nothing to the bar.",
                    fileURL: file,
                    line: nil,
                    keyPath: nil
                ))
            } else if warning.hasPrefix("The preview cannot show the '") {
                // unsupportedType
                let type = extractAlias(from: warning, pattern: "The preview cannot show the '([^']+)'")
                let alias = extractAlias(from: warning, pattern: "item '([^']+)'")
                if let alias, let type {
                    diagnostics.append(Diagnostic(
                        id: "missingLabel:\(file.path):\(alias)",
                        severity: .info,
                        kind: .missingLabel,
                        title: "Unsupported item type '\(type)'",
                        detail: "The preview cannot show this item type.",
                        fileURL: file,
                        line: nil,
                        keyPath: alias
                    ))
                }
            }
        }

        // Dynamic values are warnings from the parser
        for warning in commands.warnings {
            if warning.contains("is built by the shell") {
                let keyPath = extractAlias(from: warning, pattern: "The value of '([^']+)' is built by the shell")
                if let keyPath {
                    diagnostics.append(Diagnostic(
                        id: "dynamicValue:\(file.path):\(keyPath)",
                        severity: .warning,
                        kind: .missingLabel,
                        title: "Dynamic value '\(keyPath)'",
                        detail: "The value is built by the shell, so the preview shows the default value.",
                        fileURL: file,
                        line: nil,
                        keyPath: keyPath
                    ))
                }
            }
        }

        // Duplicate aliases: check across all commands
        var aliasLines: [String: [Int]] = [:]
        let addCommands = ShellConfigCommandParser.addCommands(in: contents)
        for (alias, line) in addCommands {
            aliasLines[alias, default: []].append(line)
        }

        for (alias, lines) in aliasLines where lines.count > 1 {
            let firstLine = lines[0]
            diagnostics.append(Diagnostic(
                id: "duplicateAlias:\(file.path):\(firstLine):\(alias)",
                severity: .error,
                kind: .duplicateAlias,
                title: "Duplicate alias '\(alias)'",
                detail: "The alias is added at lines \(lines.map(String.init).joined(separator: ", ")).",
                fileURL: file,
                line: firstLine,
                keyPath: alias
            ))
        }

        // Check for missing file references in script paths
        // Look for script= or background.script= in the parsed items
        for item in commands.items {
            for value in item.values {
                if value.keyPath.hasSuffix("script") || value.keyPath.hasSuffix("background.script") {
                    let scriptPath = value.rawValue
                    if isMissingFile(scriptPath, relativeTo: file) {
                        diagnostics.append(Diagnostic(
                            id: "missingFile:\(file.path):\(value.keyPath)",
                            severity: .error,
                            kind: .missingFile,
                            title: "Missing script file '\(scriptPath)'",
                            detail: "The script path points at a file that does not exist.",
                            fileURL: file,
                            line: item.values.first { $0.keyPath == value.keyPath }.flatMap { _ in item.values.firstIndex(where: { $0.keyPath == value.keyPath }) }.map { $0 + 1 },
                            keyPath: value.keyPath
                        ))
                    }
                }
            }
        }

        // Check for broken loader lines (source/require commands that point to missing files)
        let loaderDiagnostics = checkBrokenLoaders(in: contents, file: file, root: root)
        diagnostics.append(contentsOf: loaderDiagnostics)

        return diagnostics
    }

    /// Checks for loader lines that point at missing files.
    private func checkBrokenLoaders(in contents: String, file: URL, root: URL) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let lines = contents.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("source ") || trimmed.hasPrefix(". ") || trimmed.hasPrefix("require ") else {
                continue
            }

            // Extract the file path from the loader line
            let path: String?
            if trimmed.hasPrefix("source ") {
                path = String(trimmed.dropFirst("source ".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix(". ") {
                path = String(trimmed.dropFirst(". ".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("require ") {
                path = String(trimmed.dropFirst("require ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                path = nil
            }

            guard let target = path, !target.isEmpty else { continue }

            // Check if the file exists
            let targetURL: URL
            if target.hasPrefix("/") {
                targetURL = URL(fileURLWithPath: target)
            } else {
                targetURL = file.deletingLastPathComponent().appendingPathComponent(target)
            }

            if !FileManager.default.fileExists(atPath: targetURL.path) {
                diagnostics.append(Diagnostic(
                    id: "brokenLoader:\(file.path):\(index + 1):\(target)",
                    severity: .error,
                    kind: .brokenLoader,
                    title: "Broken loader '\(target)'",
                    detail: "The loader line points at a file that does not exist.",
                    fileURL: file,
                    line: index + 1,
                    keyPath: target
                ))
            }
        }

        return diagnostics
    }

    /// True when the path points at a file that does not exist.
    private func isMissingFile(_ path: String, relativeTo file: URL) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Skip shell expansions and variables
        if trimmed.contains("$") || trimmed.contains("~") {
            return false
        }

        let targetURL: URL
        if trimmed.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: trimmed)
        } else {
            targetURL = file.deletingLastPathComponent().appendingPathComponent(trimmed)
        }

        return !FileManager.default.fileExists(atPath: targetURL.path)
    }

    /// Extracts a capture group from a string using a regex pattern.
    private func extractAlias(from string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let captureRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return String(string[captureRange])
    }
}