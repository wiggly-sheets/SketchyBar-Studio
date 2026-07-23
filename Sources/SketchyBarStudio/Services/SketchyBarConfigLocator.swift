import Foundation

struct SketchyBarConfigLocator {
    var defaultConfigRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sketchybar")
    }

    func configFiles(in rootURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if isBackupDirectory(url, rootURL: rootURL) {
                enumerator.skipDescendants()
                continue
            }

            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  kind(for: url) != nil else {
                continue
            }
            urls.append(url)
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
