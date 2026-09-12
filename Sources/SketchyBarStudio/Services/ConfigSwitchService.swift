import Foundation

struct ConfigSwitchService {
    private let fileManager: FileManager
    private let replacer: SafeFileReplacer
    private let configuredLiveSketchyBarConfigURL: URL?

    init(
        fileManager: FileManager = .default,
        liveSketchyBarConfigURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.replacer = SafeFileReplacer(fileManager: fileManager)
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
        return replacer.isSymlink(destination)
            && destination.resolvingSymlinksInPath().standardizedFileURL
                == source.resolvingSymlinksInPath().standardizedFileURL
    }

    func activate(config: ConfigWorkspace) throws {
        let source = config.url.standardizedFileURL
        let destination = liveSketchyBarConfigURL.standardizedFileURL

        if isLive(config: config) {
            return
        }

        guard !replacer.isDescendant(source, of: destination) else {
            throw ConfigSwitchError.unsafeSource(source.path)
        }

        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigSwitchError.missingSource(source.path)
        }

        if !replacer.isSymlink(destination),
           replacer.isDescendant(resolvedSource, of: destination.resolvingSymlinksInPath().standardizedFileURL) {
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
            if replacer.itemExists(at: stagedLink) {
                try? fileManager.removeItem(at: stagedLink)
            }
        }
        try fileManager.createSymbolicLink(at: stagedLink, withDestinationURL: source)

        let replacedSymlink = replacer.isSymlink(destination)
        let displacedPrefix = replacedSymlink
            ? ".\(destination.lastPathComponent).studio-rollback-"
            : "sketchybar.before-studio-switch-"
        try replacer.install(
            stagedItem: stagedLink,
            at: destination,
            keepDisplaced: !replacedSymlink,
            displacedPrefix: displacedPrefix
        )
    }
}

enum ConfigSwitchError: LocalizedError {
    case missingSource(String)
    case unsafeSource(String)
    case unsafeDestination(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path):
            return "Config folder does not exist: \(path)"
        case .unsafeSource(let path):
            return "A config inside the live SketchyBar folder cannot replace that folder: \(path)"
        case .unsafeDestination(let path):
            return "Refusing to replace an unsafe live-config destination: \(path)"
        }
    }
}
