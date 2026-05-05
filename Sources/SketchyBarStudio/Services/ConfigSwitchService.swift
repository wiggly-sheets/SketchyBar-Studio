import Foundation

struct ConfigSwitchService {
    private let fileManager = FileManager.default

    var liveSketchyBarConfigURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sketchybar")
    }

    func isLive(config: ConfigWorkspace) -> Bool {
        let destination = liveSketchyBarConfigURL.standardizedFileURL
        let source = config.url.standardizedFileURL

        if source.path == destination.path {
            return true
        }

        guard let linkedPath = try? fileManager.destinationOfSymbolicLink(atPath: destination.path) else {
            return false
        }

        let linkedURL = URL(fileURLWithPath: linkedPath, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
        return linkedURL.path == source.path
    }

    func activate(config: ConfigWorkspace) throws {
        let source = config.url.standardizedFileURL
        let destination = liveSketchyBarConfigURL.standardizedFileURL

        if source.path == destination.path {
            return
        }

        guard fileManager.fileExists(atPath: source.path) else {
            throw ConfigSwitchError.missingSource(source.path)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) || isSymlink(destination) {
            if isSymlink(destination) {
                try fileManager.removeItem(at: destination)
            } else {
                let backup = destination.deletingLastPathComponent()
                    .appendingPathComponent("sketchybar.before-studio-switch-\(Self.timestamp())")
                try fileManager.moveItem(at: destination, to: backup)
            }
        }

        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

enum ConfigSwitchError: LocalizedError {
    case missingSource(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Config folder does not exist: \(path)"
        }
    }
}
