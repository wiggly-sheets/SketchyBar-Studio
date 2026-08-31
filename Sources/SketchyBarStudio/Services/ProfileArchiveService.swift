import Foundation

struct ProfileArchiveService {
    private let fileManager: FileManager
    private let appSupportRoot: URL

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
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
        let destination = try containedChild(named: cleanName, of: root)

        let staging = root.appendingPathComponent(
            ".\(cleanName).studio-profile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            if itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: source, to: staging)

        let hadExistingProfile = itemExists(at: destination)
        let displacedProfile = root.appendingPathComponent(
            ".\(cleanName).studio-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        if hadExistingProfile {
            try fileManager.moveItem(at: destination, to: displacedProfile)
        }

        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            guard hadExistingProfile else {
                throw error
            }
            do {
                guard !itemExists(at: destination) else {
                    throw ProfileError.profileRollbackBlocked(displacedProfile.path)
                }
                try fileManager.moveItem(at: displacedProfile, to: destination)
            } catch let rollbackError {
                throw ProfileError.profileRollbackFailed(
                    backupPath: displacedProfile.path,
                    reason: rollbackError.localizedDescription
                )
            }
            throw error
        }

        if hadExistingProfile {
            try? fileManager.removeItem(at: displacedProfile)
        }
    }

    func restore(profile: ConfigProfile, to configRoot: URL) throws {
        let source = profile.url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileError.missingProfile(profile.url.path)
        }

        let logicalDestination = configRoot.standardizedFileURL
        let destination = isSymlink(logicalDestination)
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
            if itemExists(at: staging) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try fileManager.copyItem(at: source, to: staging)

        let backup = destinationParent.appendingPathComponent(
            "sketchybar.before-studio-restore-\(Self.timestamp())-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadExistingConfig = itemExists(at: destination)

        if hadExistingConfig {
            try fileManager.moveItem(at: destination, to: backup)
        }

        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            guard hadExistingConfig else {
                throw error
            }

            do {
                guard !itemExists(at: destination) else {
                    throw ProfileError.restoreRollbackBlocked(backup.path)
                }
                try fileManager.moveItem(at: backup, to: destination)
            } catch let rollbackError {
                throw ProfileError.restoreRollbackFailed(
                    backupPath: backup.path,
                    reason: rollbackError.localizedDescription
                )
            }
            throw error
        }
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

    private func containedChild(named name: String, of root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let destination = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == standardizedRoot else {
            throw ProfileError.invalidName
        }
        return destination
    }

    private func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || isSymlink(url)
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

enum ProfileError: LocalizedError {
    case emptyName
    case invalidName
    case missingSource(String)
    case missingProfile(String)
    case unsafeRestoreDestination(String)
    case restoreRollbackBlocked(String)
    case restoreRollbackFailed(backupPath: String, reason: String)
    case profileRollbackBlocked(String)
    case profileRollbackFailed(backupPath: String, reason: String)

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
        case .restoreRollbackBlocked(let backupPath):
            return "The restore could not roll back because the destination was recreated. The original config remains at \(backupPath)."
        case .restoreRollbackFailed(let backupPath, let reason):
            return "The restore failed and the original config could not be put back. It remains at \(backupPath). \(reason)"
        case .profileRollbackBlocked(let backupPath):
            return "The profile could not be rolled back because its destination was recreated. The previous snapshot remains at \(backupPath)."
        case .profileRollbackFailed(let backupPath, let reason):
            return "Saving the profile failed and the previous snapshot could not be put back. It remains at \(backupPath). \(reason)"
        }
    }
}
