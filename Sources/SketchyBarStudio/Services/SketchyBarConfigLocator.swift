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
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { kind(for: $0) != nil }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
