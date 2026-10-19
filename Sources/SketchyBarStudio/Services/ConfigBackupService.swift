import Foundation

struct ConfigBackupService {
    /// Reserved folder inside `backups/` so the mirror never overwrites a
    /// file the user keeps in `backups/` themselves.
    static let mirrorDirectoryName = ".sketchybar-studio"

    private let fileManager: FileManager
    private let replacer: SafeFileReplacer

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.replacer = SafeFileReplacer(fileManager: fileManager)
    }

    /// Copies the current file into the `backups/` mirror. The backup slot is
    /// replaced in one step, so a failed copy leaves the previous backup in
    /// place instead of emptying it.
    func backup(fileURL: URL, rootURL: URL) throws -> URL {
        let relativePath = try relativePath(for: fileURL, rootURL: rootURL)
        let backupURL = rootURL
            .appendingPathComponent("backups")
            .appendingPathComponent(Self.mirrorDirectoryName)
            .appendingPathComponent(relativePath)

        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Copy the real file so the backup is a regular file with real
        // content even when the live config file is a symlink.
        let sourceURL = replacer.resolvedFileURL(for: fileURL)
        let temporaryURL = backupURL.deletingLastPathComponent()
            .appendingPathComponent(".\(backupURL.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)

        if fileManager.fileExists(atPath: backupURL.path) {
            _ = try fileManager.replaceItemAt(backupURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: backupURL)
        }
        return backupURL
    }

    private func relativePath(for fileURL: URL, rootURL: URL) throws -> String {
        for root in [rootURL, rootURL.resolvingSymlinksInPath()] {
            let rootPath = root.standardizedFileURL.path
            let filePath = fileURL.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

            guard filePath.hasPrefix(prefix) else { continue }
            return String(filePath.dropFirst(prefix.count))
        }

        throw ConfigBackupError.fileOutsideRoot(fileURL.path)
    }
}

enum ConfigBackupError: LocalizedError {
    case fileOutsideRoot(String)

    var errorDescription: String? {
        switch self {
        case .fileOutsideRoot(let path):
            return "Refusing to back up a file outside the config folder: \(path)"
        }
    }
}
