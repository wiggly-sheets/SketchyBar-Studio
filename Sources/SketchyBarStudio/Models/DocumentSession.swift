import Foundation

/// Owns a single config file's session state: raw text, parsed values, drafts,
/// file fingerprint, backup, validation, and transactional save.
struct DocumentSession {
    var file: ConfigFile
    private(set) var savedContents: String
    private(set) var draftContents: String?
    private(set) var loadError: String?

    init(file: ConfigFile, savedContents: String, draftContents: String? = nil, loadError: String? = nil) {
        self.file = file
        self.savedContents = savedContents
        self.draftContents = draftContents
        self.loadError = loadError
    }

    /// Creates a session by reading the file from disk. Read failures are
    /// captured in `loadError` rather than thrown.
    static func loading(_ file: ConfigFile) -> DocumentSession {
        do {
            let contents = try String(contentsOf: file.url, encoding: .utf8)
            return DocumentSession(file: file, savedContents: contents)
        } catch {
            return DocumentSession(file: file, savedContents: "", loadError: error.localizedDescription)
        }
    }

    var hasRawDraft: Bool { draftContents != nil && draftContents != savedContents }
    var hasStructuredDraft: Bool { file.values.contains { $0.draftValue != $0.originalValue } }
    var hasUnsavedChanges: Bool { hasRawDraft || hasStructuredDraft }
    var sourceContents: String { draftContents ?? savedContents }
    var sourceHasUnsavedChanges: Bool { hasRawDraft }

    /// Re-reads the file from disk into `savedContents` and clears any raw
    /// draft. Sets `loadError` on failure.
    mutating func refreshFromDisk() {
        do {
            let contents = try String(contentsOf: file.url, encoding: .utf8)
            savedContents = contents
            draftContents = nil
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Loads the raw draft from disk if not already loaded (used when the
    /// source editor opens). Sets `loadError` on failure.
    mutating func loadRawDraft() {
        guard draftContents == nil else { return }
        do {
            let contents = try String(contentsOf: file.url, encoding: .utf8)
            savedContents = contents
            draftContents = contents
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    mutating func updateSourceContents(_ contents: String) {
        if draftContents == nil { loadRawDraft() }
        draftContents = contents
    }

    /// Re-reads the file from disk, discarding any raw draft edits.
    mutating func discardSourceChanges() {
        refreshFromDisk()
    }

    /// Preserves value drafts and the raw draft across a reload: re-parses
    /// `file` from the freshly scanned `scanned` file, keeping draft values
    /// whose IDs still exist.
    mutating func merge(from scanned: ConfigFile) {
        let changedDrafts = Dictionary(uniqueKeysWithValues: file.values.filter { $0.draftValue != $0.originalValue }.map { ($0.id, $0.draftValue) })
        let values = scanned.values.map { scannedValue -> LuaEditableValue in
            guard let draft = changedDrafts[scannedValue.id] else { return scannedValue }
            var merged = scannedValue
            merged.draftValue = draft
            return merged
        }
        file = ConfigFile(url: scanned.url, rootURL: scanned.rootURL, kind: scanned.kind, values: values, activationReference: scanned.activationReference)
    }

    /// Validates, backs up, and writes the draft (raw or structured) to disk.
    /// Throws on competing drafts, an external edit (fingerprint change), or
    /// write failure. After a successful save, `savedContents` reflects the
    /// new on-disk content and the raw draft is cleared.
    mutating func save(using luaScanner: LuaConfigScanner, shellScanner: ShellConfigScanner, backupService: ConfigBackupService) throws {
        guard hasUnsavedChanges else { return }
        guard !(hasRawDraft && hasStructuredDraft) else { throw DocumentSessionError.competingDrafts }
        let currentContents = try String(contentsOf: file.url, encoding: .utf8)
        guard currentContents == savedContents else { throw DocumentSessionError.changedOnDisk }
        _ = try backupService.backup(fileURL: file.url, rootURL: file.rootURL)
        // Re-read right before the write so an external edit is not lost.
        let finalContents = try String(contentsOf: file.url, encoding: .utf8)
        guard finalContents == savedContents else { throw DocumentSessionError.changedOnDisk }
        if hasRawDraft, let draftContents {
            try SafeFileReplacer().writeAtomicallyPreservingSymlinks(draftContents, to: file.url)
        } else {
            switch file.kind {
            case .lua: try luaScanner.save(values: file.values, to: file.url, rootURL: file.rootURL)
            case .shell, .sketchybarRC: try shellScanner.save(values: file.values, to: file.url, rootURL: file.rootURL)
            }
        }
        savedContents = try String(contentsOf: file.url, encoding: .utf8)
        self.draftContents = nil
        loadError = nil
    }
}

enum DocumentSessionError: LocalizedError {
    case changedOnDisk
    case competingDrafts

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            return "The file changed on disk after editing began. Revert the draft to load the current file, then reapply your edit."
        case .competingDrafts:
            return "This file has both source and control edits. Discard one editing mode before saving so neither draft is overwritten."
        }
    }
}