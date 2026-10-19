import Foundation

struct ProfileArchiveService {
    private let fileManager: FileManager
    private let replacer: SafeFileReplacer
    private let appSupportRoot: URL

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        self.appSupportRoot = appSupportRoot ?? Self.defaultAppSupportRoot(fileManager: fileManager)
        self.replacer = SafeFileReplacer(fileManager: fileManager, appSupportRoot: self.appSupportRoot)
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

        replacer.sweepStagingItems(in: root, keeping: destination)

        let staging = root.appendingPathComponent(
            ".\(cleanName).studio-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if replacer.itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try copyConfigTree(from: source, to: staging)

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
        replacer.sweepStagingItems(in: destinationParent, keeping: destination)

        let staging = destinationParent.appendingPathComponent(
            ".\(destination.lastPathComponent).studio-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if replacer.itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try copyConfigTree(from: source, to: staging)
        // The backup mirror of the user stays in the config root: a restore
        // replaces the config files, not the history of the backups.
        try carryOverBackupMirror(from: destination, to: staging)

        // The displaced copy lives in Application Support so a full copy of
        // the config never shows up in the user's config repository.
        let displaced = try replacer.displacedURL(for: destination)
        try replacer.install(
            stagedItem: staging,
            at: destination,
            keepDisplaced: true,
            displacedPrefix: "sketchybar.before-studio-restore-",
            displacedURL: displaced
        )
    }

    /// Copies a config folder without the app's own `backups/` mirror, so
    /// snapshots do not grow with every backup.
    private func copyConfigTree(from source: URL, to staging: URL) throws {
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent != "backups" {
            try fileManager.copyItem(at: child, to: staging.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// Carries the `backups/` folder of the replaced config root over to the
    /// restored root.
    ///
    /// The folder of the user is kept as it is: a symlink stays a symlink,
    /// and a backup file that is already there is never overwritten.
    private func carryOverBackupMirror(from root: URL, to staging: URL) throws {
        let source = root.appendingPathComponent("backups")
        let target = staging.appendingPathComponent("backups")

        if replacer.isSymlink(source) {
            try fileManager.copyItem(at: source, to: target)
            return
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            let destination = target.appendingPathComponent(child.lastPathComponent)
            guard !replacer.itemExists(at: destination) else { continue }
            try fileManager.copyItem(at: child, to: destination)
        }
    }

    /// Profile names are visible in the profile list, so a leading dot is
    /// removed: a hidden profile would never be listed again.
    private func sanitizedProfileName(_ name: String) -> String {
        stripLeadingDots(sanitizedPathComponent(name))
    }

    private func safeConfigID(_ configID: String) -> String {
        let cleanID = sanitizedPathComponent(configID)
        if cleanID.isEmpty || cleanID == "." || cleanID == ".." {
            return "_\(cleanID)"
        }
        return cleanID
    }

    private func sanitizedPathComponent(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func stripLeadingDots(_ name: String) -> String {
        var clean = name
        while clean.hasPrefix(".") {
            clean.removeFirst()
        }
        return clean
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
