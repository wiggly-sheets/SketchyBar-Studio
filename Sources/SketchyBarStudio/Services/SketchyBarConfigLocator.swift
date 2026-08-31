import Foundation

struct SketchyBarConfigLocator {
    var defaultConfigRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sketchybar")
    }

    func configFiles(in rootURL: URL) -> [URL] {
        let enumeratedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: enumeratedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if isBackupDirectory(url, rootURL: enumeratedRoot) {
                enumerator.skipDescendants()
                continue
            }

            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  kind(for: url) != nil else {
                continue
            }

            guard let relativePath = relativePath(of: url, from: enumeratedRoot) else {
                continue
            }
            urls.append(rootURL.appendingPathComponent(relativePath))
        }

        let physicalHiddenEntrypoint = enumeratedRoot.appendingPathComponent(".sketchybarrc")
        var hiddenEntrypointIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: physicalHiddenEntrypoint.path,
            isDirectory: &hiddenEntrypointIsDirectory
        ), !hiddenEntrypointIsDirectory.boolValue {
            urls.append(rootURL.appendingPathComponent(".sketchybarrc"))
        }

        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func isBackupDirectory(_ url: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return false }
        return String(filePath.dropFirst(prefix.count)) == "backups"
    }

    private func relativePath(of url: URL, from rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else {
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    func kind(for url: URL) -> ConfigFileKind? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if ext == "lua" {
            return .lua
        }
        if ext == "sh" || ext == "bash" || ext == "zsh" {
            return .shell
        }
        if name == "sketchybarrc" || name == ".sketchybarrc" {
            return .sketchybarRC
        }
        return nil
    }
}
