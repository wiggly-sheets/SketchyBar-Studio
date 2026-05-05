import Foundation

struct ProfileArchiveService {
    private let fileManager = FileManager.default

    var profilesRoot: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio").appendingPathComponent("Profiles")
    }

    func listProfiles() -> [ConfigProfile] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: profilesRoot,
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

    func saveProfile(named name: String, from configRoot: URL) throws {
        let cleanName = sanitizedProfileName(name)
        guard !cleanName.isEmpty else {
            throw ProfileError.emptyName
        }

        try fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        let destination = profilesRoot.appendingPathComponent(cleanName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: configRoot, to: destination)
    }

    func restore(profile: ConfigProfile, to configRoot: URL) throws {
        let backup = configRoot.deletingLastPathComponent()
            .appendingPathComponent("sketchybar.before-studio-restore-\(Self.timestamp())")

        if fileManager.fileExists(atPath: configRoot.path) {
            try fileManager.moveItem(at: configRoot, to: backup)
        }
        try fileManager.copyItem(at: profile.url, to: configRoot)
    }

    private func sanitizedProfileName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

enum ProfileError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a profile name first."
        }
    }
}
