import Foundation

/// Owns safe filesystem replacement: canonical containment, symlink policy,
/// staging, verification, atomic replacement, and rollback.
struct SafeFileReplacer {
    var fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the canonical child of `root` named `name`, or throws if the
    /// name would escape the root (e.g. "." or "..").
    func containedChild(named name: String, of root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let destination = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == standardizedRoot else {
            throw SafeFileReplacerError.unsafeChildName(name)
        }
        return destination
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymlink(url)
    }

    func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > parentComponents.count
            && candidateComponents.starts(with: parentComponents)
    }

    /// Transactionally installs `stagedItem` at `destination`, displacing any
    /// existing item to a rollback location. On failure, restores the displaced
    /// item. On success, removes the displaced item unless `keepDisplaced` is true.
    func install(stagedItem: URL, at destination: URL, keepDisplaced: Bool, displacedPrefix: String) throws {
        let displaced = destination.deletingLastPathComponent()
            .appendingPathComponent("\(displacedPrefix)\(Self.timestamp())-\(UUID().uuidString)")
        let hadExisting = itemExists(at: destination)

        if hadExisting {
            try fileManager.moveItem(at: destination, to: displaced)
        }

        do {
            try fileManager.moveItem(at: stagedItem, to: destination)
        } catch {
            guard hadExisting else { throw error }
            do {
                guard !itemExists(at: destination) else {
                    throw SafeFileReplacerError.rollbackBlocked(displaced.path)
                }
                try fileManager.moveItem(at: displaced, to: destination)
            } catch let rollbackError {
                throw SafeFileReplacerError.rollbackFailed(backupPath: displaced.path, reason: rollbackError.localizedDescription)
            }
            throw error
        }

        if hadExisting && !keepDisplaced {
            try? fileManager.removeItem(at: displaced)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

enum SafeFileReplacerError: LocalizedError {
    case unsafeChildName(String)
    case rollbackBlocked(String)
    case rollbackFailed(backupPath: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsafeChildName(let name):
            return "Refusing to use unsafe path component \"\(name)\"."
        case .rollbackBlocked(let backupPath):
            return "The replacement could not roll back because the destination was recreated. The original remains at \(backupPath)."
        case .rollbackFailed(let backupPath, let reason):
            return "The replacement failed and the original could not be put back. It remains at \(backupPath). \(reason)"
        }
    }
}