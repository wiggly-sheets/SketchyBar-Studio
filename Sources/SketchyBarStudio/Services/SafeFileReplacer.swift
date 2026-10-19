import Foundation

/// Owns safe filesystem replacement: canonical containment, symlink policy,
/// staging, verification, atomic replacement, and rollback.
struct SafeFileReplacer {
    var fileManager: FileManager
    let appSupportRoot: URL

    init(fileManager: FileManager = .default, appSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        self.appSupportRoot = appSupportRoot ?? Self.defaultAppSupportRoot(fileManager: fileManager)
    }

    private static func defaultAppSupportRoot(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SketchyBarStudio")
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

    /// Writes `contents` atomically. A symlinked file keeps its link: the
    /// write lands on the real target so the linked file stays in sync
    /// instead of being replaced by a regular file.
    func writeAtomicallyPreservingSymlinks(_ contents: String, to url: URL) throws {
        try contents.write(to: resolvedFileURL(for: url), atomically: true, encoding: .utf8)
    }

    /// Resolves `url` to the file it points at when `url` is a symlink.
    func resolvedFileURL(for url: URL) -> URL {
        guard isSymlink(url) else { return url }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Builds a path for a displaced copy under Application Support so the
    /// copy never lands inside the user's config repository.
    func displacedURL(for destination: URL) throws -> URL {
        let directory = appSupportRoot
            .appendingPathComponent("Restores", isDirectory: true)
            .appendingPathComponent("\(Self.timestamp())-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(destination.lastPathComponent)
    }

    /// Removes staging directories left behind by an interrupted operation.
    func sweepStagingItems(in directory: URL, keeping keep: URL? = nil) {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix("."), name.contains(".studio-") else { continue }
            if let keep, item.standardizedFileURL == keep.standardizedFileURL { continue }
            try? fileManager.removeItem(at: item)
        }
    }

    /// Transactionally installs `stagedItem` at `destination`, displacing any
    /// existing item to a rollback location. On failure, restores the displaced
    /// item. On success, removes the displaced item unless `keepDisplaced` is true.
    /// A journal in Application Support lets the next launch repair an
    /// install that a crash interrupted.
    func install(
        stagedItem: URL,
        at destination: URL,
        keepDisplaced: Bool,
        displacedPrefix: String,
        displacedURL: URL? = nil
    ) throws {
        let displaced = displacedURL ?? destination.deletingLastPathComponent()
            .appendingPathComponent("\(displacedPrefix)\(Self.timestamp())-\(UUID().uuidString)")
        let hadExisting = itemExists(at: destination)
        var keepJournal = false

        try writePendingInstall(PendingInstall(
            staged: stagedItem.path,
            destination: destination.path,
            displaced: displaced.path,
            keepDisplaced: keepDisplaced
        ))
        defer {
            if !keepJournal { removePendingInstall() }
        }

        if hadExisting {
            try fileManager.moveItem(at: destination, to: displaced)
        }

        do {
            try fileManager.moveItem(at: stagedItem, to: destination)
        } catch {
            guard hadExisting else { throw error }
            guard !itemExists(at: destination) else {
                throw SafeFileReplacerError.rollbackBlocked(displaced.path)
            }
            do {
                try fileManager.moveItem(at: displaced, to: destination)
            } catch let rollbackError {
                keepJournal = true
                throw SafeFileReplacerError.rollbackFailed(backupPath: displaced.path, reason: rollbackError.localizedDescription)
            }
            throw error
        }

        if hadExisting && !keepDisplaced {
            try? fileManager.removeItem(at: displaced)
            removeEmptyDisplacedDirectory(displaced)
        }
    }

    /// Repairs an install that a crash interrupted: the live path is put back
    /// when it went missing, and leftover staging items are removed.
    func recoverPendingInstalls() {
        guard let data = try? Data(contentsOf: pendingInstallURL),
              let pending = try? JSONDecoder().decode(PendingInstall.self, from: data) else {
            return
        }

        let staged = URL(fileURLWithPath: pending.staged)
        let destination = URL(fileURLWithPath: pending.destination)
        let displaced = URL(fileURLWithPath: pending.displaced)

        if !itemExists(at: destination) {
            if itemExists(at: displaced) {
                try? fileManager.moveItem(at: displaced, to: destination)
            } else if itemExists(at: staged) {
                try? fileManager.moveItem(at: staged, to: destination)
            }
        }

        if itemExists(at: staged) { try? fileManager.removeItem(at: staged) }
        if itemExists(at: displaced), !pending.keepDisplaced {
            try? fileManager.removeItem(at: displaced)
            removeEmptyDisplacedDirectory(displaced)
        }
        removePendingInstall()
    }

    private var pendingInstallURL: URL {
        appSupportRoot.appendingPathComponent("pending-install.json")
    }

    private func writePendingInstall(_ pending: PendingInstall) throws {
        try fileManager.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pending)
        try data.write(to: pendingInstallURL, options: .atomic)
    }

    private func removePendingInstall() {
        try? fileManager.removeItem(at: pendingInstallURL)
    }

    /// Drops the per-operation folder under Application Support once the
    /// displaced copy inside it is gone.
    private func removeEmptyDisplacedDirectory(_ displaced: URL) {
        let directory = displaced.deletingLastPathComponent()
        guard directory.path.hasPrefix(appSupportRoot.path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

private struct PendingInstall: Codable {
    let staged: String
    let destination: String
    let displaced: String
    let keepDisplaced: Bool
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
