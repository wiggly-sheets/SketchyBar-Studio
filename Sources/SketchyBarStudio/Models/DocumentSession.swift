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
            apply(contents: contents)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Takes over a copy of the file that was read elsewhere, so the file is
    /// not read twice. Sets `loadError` on failure.
    mutating func refresh(with contents: String?, loadError: String?) {
        guard let contents else {
            self.loadError = loadError
            return
        }
        apply(contents: contents)
    }

    private mutating func apply(contents: String) {
        savedContents = contents
        draftContents = nil
        loadError = nil
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
    /// `file` from the freshly scanned `scanned` file, keeping the drafts
    /// that can still be matched to a value. A draft that cannot be matched
    /// safely is kept in the list and flagged as missing instead of being
    /// dropped or applied to another value. Returns how many drafts were
    /// kept that are no longer in the file.
    @discardableResult
    mutating func merge(from scanned: ConfigFile) -> Int {
        let previousValues = file.values.filter { !$0.isMissingFromFile }
        let drafts = previousValues.filter { $0.draftValue != $0.originalValue }
        var draftsByTarget: [LuaEditableValue.ID: LuaEditableValue] = [:]
        var missingDrafts: [LuaEditableValue] = []
        var takenTargets: Set<LuaEditableValue.ID> = []

        for draft in drafts {
            guard let target = Self.target(
                for: draft,
                in: scanned.values,
                previousValues: previousValues,
                taken: takenTargets
            ) else {
                var kept = draft
                kept.isMissingFromFile = true
                missingDrafts.append(kept)
                continue
            }
            draftsByTarget[target.id] = draft
            takenTargets.insert(target.id)
        }

        var values = scanned.values.map { scannedValue -> LuaEditableValue in
            guard let draft = draftsByTarget[scannedValue.id] else { return scannedValue }
            var merged = scannedValue
            merged.draftValue = draft.draftValue
            return merged
        }
        values.append(contentsOf: missingDrafts)
        file = ConfigFile(url: scanned.url, rootURL: scanned.rootURL, kind: scanned.kind, values: values, activationReference: scanned.activationReference)
        return missingDrafts.count
    }

    /// The rescanned value a draft belongs to.
    ///
    /// A draft only moves to a value that still holds the text the draft was
    /// made from, so a draft never lands on a value the user did not edit.
    /// When several values hold that text, the stable key decides which one
    /// it is, but only when the number of values with that key path did not
    /// change: a new block with the same option shifts the ordinals, and
    /// the ordinals then say nothing about the identity of a value.
    private static func target(
        for draft: LuaEditableValue,
        in scanned: [LuaEditableValue],
        previousValues: [LuaEditableValue],
        taken: Set<LuaEditableValue.ID>
    ) -> LuaEditableValue? {
        let candidates = scanned.filter { $0.keyPath == draft.keyPath }
        let sameText = candidates.filter { $0.originalValue == draft.originalValue && !taken.contains($0.id) }
        if sameText.count == 1 { return sameText[0] }
        guard sameText.count > 1 else { return nil }

        let oldCount = previousValues.filter { $0.keyPath == draft.keyPath }.count
        guard oldCount == candidates.count else { return nil }
        return sameText.first { $0.stableKey == draft.stableKey }
    }

    /// Marks the file as gone from disk. The session keeps its values and
    /// drafts so the work is not lost when the file comes back.
    mutating func markMissingFromDisk() {
        file.isMissingFromDisk = true
        loadError = "The file is missing from disk."
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
        // The backup holds the bytes that are about to be overwritten, not
        // whatever another process may have written in the meantime.
        _ = try backupService.backup(fileURL: file.url, rootURL: file.rootURL, contents: savedContents)
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