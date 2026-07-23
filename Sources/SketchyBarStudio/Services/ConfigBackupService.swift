import Foundation

struct ConfigBackupService {
    private let fileManager = FileManager.default

    func backup(fileURL: URL, rootURL: URL) throws -> URL {
        let relativePath = relativePath(for: fileURL, rootURL: rootURL)
        let backupURL = rootURL
            .appendingPathComponent("backups")
            .appendingPathComponent(relativePath)

        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(prefix.count))
    }
}
