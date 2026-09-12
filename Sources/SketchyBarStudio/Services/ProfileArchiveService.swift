import Foundation

struct ProfileArchiveService {
    private let fileManager: FileManager
    private let replacer: SafeFileReplacer
    private let appSupportRoot: URL

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        self.replacer = SafeFileReplacer(fileManager: fileManager)
        self.appSupportRoot = appSupportRoot ?? Self.defaultAppSupportRoot(fileManager: fileManager)
    }

    private static func defaultAppSupportRoot(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio")
    }

    func profilesRoot(for configID: String) -> URL {
        appSupportRoot
            .appendingPathComponent("Profiles")
            .appendingPathComponent(safeConfigID(configID))
    }

    func listProfiles(for configID: String) -> [ConfigProfile] {
        let root = profilesRoot(for: configID)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey]) else {
                return nil
            }
            return ConfigProfile(name: url.lastPathComponent, url: url, createdAt: values.creationDate ?? .now)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func saveProfile(named name: String, from configRoot: URL, configID: String) throws {
        let cleanName = sanitizedProfileName(name)
        guard !cleanName.isEmpty else {
            throw ProfileError.emptyName
        }
        guard cleanName != ".", cleanName != ".." else {
            throw ProfileError.invalidName
        }

        let source = configRoot.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileError.missingSource(configRoot.path)
        }

        let root = profilesRoot(for: configID)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = try replacer.containedChild(named: cleanName, of: root)

        let staging = root.appendingPathComponent(
            ".\(cleanName).studio-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if replacer.itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: source, to: staging)

        try replacer.install(
            stagedItem: staging,
            at: destination,
            keepDisplaced: false,
            displacedPrefix: ".\(cleanName).studio-rollback-"
        )
    }

    func restore(profile: ConfigProfile, to configRoot: URL) throws {
        let source = profile.url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileError.missingProfile(profile.url.path)
        }

        let logicalDestination = configRoot.standardizedFileURL
        let destination = replacer.isSymlink(logicalDestination)
            ? logicalDestination.resolvingSymlinksInPath().standardizedFileURL
            : logicalDestination
        let destinationParent = destination.deletingLastPathComponent()
        guard destination != destinationParent else {
            throw ProfileError.unsafeRestoreDestination(destination.path)
        }

        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let staging = destinationParent.appendingPathComponent(
            ".\(destination.lastPathComponent).studio-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if replacer.itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try fileManager.copyItem(at: source, to: staging)

        try replacer.install(
            stagedItem: staging,
            at: destination,
            keepDisplaced: true,
            displacedPrefix: "sketchybar.before-studio-restore-"
        )
    }

    private func sanitizedProfileName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func safeConfigID(_ configID: String) -> String {
        let cleanID = sanitizedProfileName(configID)
        if cleanID.isEmpty || cleanID == "." || cleanID == ".." {
            return "_\(cleanID)"
        }
        return cleanID
    }
}

enum ProfileError: LocalizedError {
    case emptyName
    case invalidName
    case missingSource(String)
    case missingProfile(String)
    case unsafeRestoreDestination(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a profile name first."
        case .invalidName:
            return "Profile names cannot be \".\" or \"..\"."
        case .missingSource(let path):
            return "Config folder does not exist: \(path)"
        case .missingProfile(let path):
            return "Profile folder does not exist: \(path)"
        case .unsafeRestoreDestination(let path):
            return "Refusing to restore a profile over an unsafe destination: \(path)"
        }
    }
}
