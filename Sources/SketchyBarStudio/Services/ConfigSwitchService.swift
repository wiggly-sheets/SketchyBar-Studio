import Foundation

struct ConfigSwitchService {
    private let fileManager: FileManager
    private let configuredLiveSketchyBarConfigURL: URL?

    init(
        fileManager: FileManager = .default,
        liveSketchyBarConfigURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.configuredLiveSketchyBarConfigURL = liveSketchyBarConfigURL
    }

    var liveSketchyBarConfigURL: URL {
        if let configuredLiveSketchyBarConfigURL {
            return configuredLiveSketchyBarConfigURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("sketchybar")
    }

    func isLive(config: ConfigWorkspace) -> Bool {
        let destination = liveSketchyBarConfigURL.standardizedFileURL
        let source = config.url.standardizedFileURL

        if source.path == destination.path {
            return true
        }
        return isSymlink(destination)
            && destination.resolvingSymlinksInPath().standardizedFileURL
                == source.resolvingSymlinksInPath().standardizedFileURL
    }

    func activate(config: ConfigWorkspace) throws {
        let source = config.url.standardizedFileURL
        let destination = liveSketchyBarConfigURL.standardizedFileURL

        if isLive(config: config) {
            return
        }

        guard !isDescendant(source, of: destination) else {
            throw ConfigSwitchError.unsafeSource(source.path)
        }

        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigSwitchError.missingSource(source.path)
        }

        if !isSymlink(destination),
           isDescendant(resolvedSource, of: destination.resolvingSymlinksInPath().standardizedFileURL) {
            throw ConfigSwitchError.unsafeSource(source.path)
        }

        let destinationParent = destination.deletingLastPathComponent()
        guard destination != destinationParent else {
            throw ConfigSwitchError.unsafeDestination(destination.path)
        }
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let stagedLink = destinationParent.appendingPathComponent(
            ".\(destination.lastPathComponent).studio-switch-\(UUID().uuidString)"
        )
        defer {
            if itemExists(at: stagedLink) {
                try? fileManager.removeItem(at: stagedLink)
            }
        }
        try fileManager.createSymbolicLink(at: stagedLink, withDestinationURL: source)

        let hadExistingConfig = itemExists(at: destination)
        let replacedSymlink = isSymlink(destination)
        let displacedConfig = destinationParent.appendingPathComponent(
            replacedSymlink
                ? ".\(destination.lastPathComponent).studio-rollback-\(UUID().uuidString)"
                : "sketchybar.before-studio-switch-\(Self.timestamp())-\(UUID().uuidString)",
            isDirectory: !replacedSymlink
        )

        if hadExistingConfig {
            try fileManager.moveItem(at: destination, to: displacedConfig)
        }

        do {
            try fileManager.moveItem(at: stagedLink, to: destination)
        } catch {
            guard hadExistingConfig else {
                throw error
            }

            do {
                guard !itemExists(at: destination) else {
                    throw ConfigSwitchError.rollbackBlocked(displacedConfig.path)
                }
                try fileManager.moveItem(at: displacedConfig, to: destination)
            } catch let rollbackError {
                throw ConfigSwitchError.rollbackFailed(
                    backupPath: displacedConfig.path,
                    reason: rollbackError.localizedDescription
                )
            }
            throw error
        }

        if replacedSymlink {
            try? fileManager.removeItem(at: displacedConfig)
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymlink(url)
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && candidateComponents.starts(with: parentComponents)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

enum ConfigSwitchError: LocalizedError {
    case missingSource(String)
    case unsafeSource(String)
    case unsafeDestination(String)
    case rollbackBlocked(String)
    case rollbackFailed(backupPath: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Config folder does not exist: \(path)"
        case .unsafeSource(let path):
            return "A config inside the live SketchyBar folder cannot replace that folder: \(path)"
        case .unsafeDestination(let path):
            return "Refusing to replace an unsafe live-config destination: \(path)"
        case .rollbackBlocked(let backupPath):
            return "The config switch could not roll back because the destination was recreated. The original config remains at \(backupPath)."
        case .rollbackFailed(let backupPath, let reason):
            return "The config switch failed and the original config could not be put back. It remains at \(backupPath). \(reason)"
        }
    }
}
