import AppKit
import Foundation
import SwiftUI

private enum SourceDraftError: LocalizedError {
    case loaderHasSourceDraft(String)

    var errorDescription: String? {
        switch self {
        case let .loaderHasSourceDraft(name):
            return "Save or discard the source draft for \(name) before saving loader order changes."
        }
    }
}

/// How a status message should be shown.
enum StatusKind {
    case info
    case success
    case warning
    case error

    /// Guesses the kind from the message, so every place that sets a
    /// message stays consistent.
    init(message: String) {
        let lowered = message.lowercased()
        if lowered.contains("failed") || lowered.contains("could not") || lowered.contains("stopped") || lowered.contains("error") {
            self = .error
        } else if lowered.contains("staged") || lowered.contains("save or") || lowered.contains("unsaved") ||
            lowered.contains("kept as") || lowered.contains("cannot") || lowered.contains("not saved") {
            self = .warning
        } else if lowered.hasPrefix("saved") || lowered.hasPrefix("loaded") || lowered.hasPrefix("added") ||
            lowered.hasPrefix("restored") || lowered.hasPrefix("activated") || lowered.hasPrefix("deactivated") ||
            lowered.hasPrefix("reverted") || lowered.hasPrefix("discarded") {
            self = .success
        } else {
            self = .info
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// One config file read from disk together with the values scanned from it.
private struct ScannedConfigFile {
    let file: ConfigFile
    let contents: String?
    let loadError: String?
}

/// A loader line the app added, with the content of the loader file before
/// and after the change.
private struct LoaderLineRecord {
    let change: ActivationChange
    /// The line as it was written into the loader file.
    let line: String
}

/// The result of a clone.
struct CloneItemResult {
    /// The file that was written.
    let fileURL: URL
    /// The text that was written.
    let contents: String
    /// The loader file that was changed.
    let loaderURL: URL?
    /// True when the loader line was added.
    let didAddLoaderLine: Bool
    /// Why the loader line was not added.
    let loaderFailureMessage: String?
}

/// The result of creating a new config.
struct NewConfigResult {
    /// The folder of the new config.
    let rootURL: URL
    /// The files that were written.
    let fileURLs: [URL]
    /// The entry of the config library.
    let configID: ConfigWorkspace.ID
}

/// Where a value lives inside its file.
private struct ValueLocation {
    let fileID: ConfigFile.ID
    let valueID: LuaEditableValue.ID
    let position: Int
}

/// What a save would write, with the text it is compared against.
struct SaveReviewPreview {
    /// The text the app holds, which is the base of the write.
    let base: String
    /// The text the save would write.
    let contents: String
    /// The notice when the file changed on disk since it was loaded.
    let notice: String?
}

@MainActor
final class SketchyBarStore: ObservableObject {
    @Published var configRoot: URL
    @Published var configs: [ConfigWorkspace] = []
    @Published var selectedConfigID: ConfigWorkspace.ID?
    @Published var files: [ConfigFile] = []
    @Published var selectedFileID: ConfigFile.ID?
    @Published var missingFiles: [ConfigFile] = []
    @Published var profiles: [ConfigProfile] = []
    @Published var profileName = ""
    @Published var newConfigName = ""
    @Published var newConfigPath = ""
    @Published var statusMessage = ""
    @Published var searchText = ""
    @Published var showModifiedOnly = false
    @Published var appTheme: AppTheme = SketchyBarStore.savedTheme() {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }

    private var sessions: [ConfigFile.ID: DocumentSession] = [:]
    private var valueIndex: [LuaEditableValue.ID: ValueLocation] = [:]
    /// The loader lines the app added, keyed by the file they load. Undoing
    /// the creation of that file takes the loader line with it.
    private var loaderLineRecords: [String: LoaderLineRecord] = [:]
    /// The undo and redo steps of the edits the user made.
    private var undoStack = UndoStack()
    /// Bumped whenever the undo stack changes, so the menu items follow it.
    @Published private(set) var undoRevision = 0
    @Published private var stagedLoaderOrders: [String: [ConfigFile.ID]] = [:]
    /// The files whose loader position differs from the saved loader order.
    @Published private(set) var stagedChangedFileIDs: Set<ConfigFile.ID> = []
    /// Bumped whenever the staged loader order changes, so the sidebar can
    /// rebuild its rows.
    @Published private(set) var stagedOrderRevision = 0
    /// Bumped whenever a raw source draft changes. The source views read it
    /// so they re-evaluate their enablement after every source edit.
    @Published private(set) var sourceDraftRevision = 0
    /// Guards against an out-of-order background reload.
    private var reloadGeneration = 0
    /// Kept so the status message can report a config library that could
    /// not be read.
    private var libraryErrorMessage: String?

    private let locator = SketchyBarConfigLocator()
    private let luaScanner = LuaConfigScanner()
    private let shellScanner = ShellConfigScanner()
    private let activationService = ConfigActivationService()
    private let configLibraryService: ConfigLibraryService
    private let configSwitchService = ConfigSwitchService()
    private let profileService = ProfileArchiveService()
    private let backupService = ConfigBackupService()

    /// `libraryURL` points the config library at another file, so a test
    /// never writes the library of the user.
    init(
        configRoot initialConfigRoot: URL? = nil,
        undoStack: UndoStack? = nil,
        libraryURL: URL? = nil
    ) {
        self.configLibraryService = ConfigLibraryService(libraryURL: libraryURL)
        self.undoStack = undoStack ?? UndoStack()
        if let initialConfigRoot {
            let config = ConfigWorkspace.make(name: initialConfigRoot.lastPathComponent, url: initialConfigRoot)
            configRoot = initialConfigRoot
            configs = [config]
            selectedConfigID = config.id
            newConfigPath = initialConfigRoot.path
            reload()
            return
        }

        let defaultRoot = locator.defaultConfigRoot
        var libraryError: String?
        var loadedConfigs: [ConfigWorkspace]
        do {
            loadedConfigs = try configLibraryService.load(defaultConfigRoot: defaultRoot)
        } catch {
            libraryError = error.localizedDescription
            loadedConfigs = [ConfigWorkspace(id: "default", name: "Default", path: defaultRoot.path, createdAt: .now)]
        }
        let savedConfigID = UserDefaults.standard.string(forKey: "selectedConfigID")
        var selected = loadedConfigs.first { $0.id == savedConfigID }
        if selected == nil, let savedRootPath = UserDefaults.standard.string(forKey: "configRoot") {
            let restoredURL = URL(fileURLWithPath: NSString(string: savedRootPath).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: restoredURL.path) {
                let restored = ConfigWorkspace.make(name: restoredURL.lastPathComponent, url: restoredURL)
                loadedConfigs.append(restored)
                selected = restored
            }
        }
        selected = selected ?? loadedConfigs.first
        configRoot = selected?.url ?? defaultRoot
        configs = loadedConfigs
        selectedConfigID = selected?.id
        newConfigPath = configRoot.path
        libraryErrorMessage = libraryError
        // The first scan runs in the background so the window opens right
        // away instead of waiting for the whole config to be read.
        statusMessage = libraryError.map {
            "Loading config files... Config library could not be read: \($0)"
        } ?? "Loading config files..."
        reloadAsync()
    }

    var selectedConfig: ConfigWorkspace? {
        guard let selectedConfigID else { return configs.first }
        return configs.first { $0.id == selectedConfigID } ?? configs.first
    }

    var selectedFile: ConfigFile? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID } ?? missingFiles.first { $0.id == selectedFileID }
    }

    /// True when any session (including files that vanished from disk) or a
    /// staged loader order still holds unsaved work.
    var hasUnsavedChanges: Bool {
        sessions.contains { $0.value.hasUnsavedChanges } || !stagedLoaderOrders.isEmpty
    }

    var selectedHasLoadError: Bool {
        selectedFile.map { loadError(for: $0) != nil } ?? false
    }

    var unsavedFileCount: Int {
        var changed = stagedChangedFileIDs
        // The files that are missing from disk count too, so the save
        // buttons stay in step with the work that is still open.
        for file in files + missingFiles where sessions[file.id]?.hasUnsavedChanges == true {
            changed.insert(file.id)
        }
        return changed.count
    }

    /// True when an edit can be undone.
    var canUndo: Bool { undoStack.canUndo }

    /// True when an undone edit can be done again.
    var canRedo: Bool { undoStack.canRedo }

    /// The name of the edit the Undo menu item undoes.
    var undoTitle: String? { undoStack.undoTitle }

    /// The name of the edit the Redo menu item does again.
    var redoTitle: String? { undoStack.redoTitle }

    /// Undoes the newest edit. The edit itself reports why it was refused.
    func undo() {
        reportDeadStep(undoStack.undoEntries.last?.action)
        guard undoStack.undo() else { return }
        undoRevision &+= 1
    }

    /// Does the newest undone edit again.
    func redo() {
        reportDeadStep(undoStack.redoEntries.last?.action)
        guard undoStack.redo() else { return }
        undoRevision &+= 1
    }

    /// Tells the user that a step was dropped, because the value it
    /// belongs to is gone.
    private func reportDeadStep(_ action: UndoAction?) {
        guard let action, action.isDead() else { return }
        statusMessage = "The change cannot be undone any more, because the value it belongs to is gone. The step was dropped from the history."
    }

    var selectedHasUnsavedChanges: Bool {
        selectedFile.map { hasUnsavedChanges(fileID: $0.id) } ?? false
    }

    var selectedConfigProfileID: String { selectedConfig?.id ?? "default" }

    /// How the current status message should be shown.
    var statusKind: StatusKind { StatusKind(message: statusMessage) }

    var isSelectedConfigLive: Bool {
        guard let selectedConfig else { return false }
        return configSwitchService.isLive(config: selectedConfig)
    }

    var filesInPreviewOrder: [ConfigFile] {
        let orderIndexes = loaderOrderIndexes()
        return files.sorted { lhs, rhs in
            if let key = loaderKey(for: lhs), key == loaderKey(for: rhs), let indexes = orderIndexes[key] {
                let lhsIndex = indexes[lhs.id] ?? .max
                let rhsIndex = indexes[rhs.id] ?? .max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            }
            let lhsLine = lhs.activationReference?.lineNumber ?? .max
            let rhsLine = rhs.activationReference?.lineNumber ?? .max
            if lhsLine != rhsLine { return lhsLine < rhsLine }
            return lhs.displayName < rhs.displayName
        }
    }

    func hasUnsavedChanges(fileID: ConfigFile.ID) -> Bool {
        _ = sourceDraftRevision
        return sessions[fileID]?.hasUnsavedChanges == true || stagedChangedFileIDs.contains(fileID)
    }

    func unsavedChangeCount(fileID: ConfigFile.ID) -> Int {
        guard let session = sessions[fileID] else { return 0 }
        let structured = session.file.values.filter { $0.draftValue != $0.originalValue }.count
        let source = session.hasRawDraft ? 1 : 0
        let order = stagedChangedFileIDs.contains(fileID) ? 1 : 0
        return structured + source + order
    }

    func reload() {
        reload(preservingDraftsExcept: [])
    }

    /// Reloads the config in the background so the window stays responsive
    /// while the files are read and scanned.
    func reloadAsync() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let rootURL = configRoot
        let configURLs = locator.configFiles(in: rootURL)
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = SketchyBarStore.scanConfig(rootURL: rootURL, configURLs: configURLs)
            await self?.applyIfCurrent(scanned, generation: generation)
        }
    }

    func updateConfigRoot(_ text: String) {
        let expanded = NSString(string: text).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if let match = configs.first(where: { SketchyBarStore.isSameConfigFolder($0.url, url) }) {
            selectConfig(match.id)
        } else {
            addConfig(name: url.lastPathComponent.isEmpty ? "Config" : url.lastPathComponent, path: url.path, selectAfterAdd: true)
        }
    }

    /// Selects a config.
    ///
    /// `keepHistory` leaves the undo steps of the store alone. The undo of
    /// a new config uses it, so moving away from that config does not take
    /// the history of the user with it.
    func selectConfig(_ id: ConfigWorkspace.ID, keepHistory: Bool = false) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        if id == selectedConfigID {
            // Same entry: keep the sessions and their drafts, just refresh.
            reload()
            return
        }
        // Sessions only exist for the current root, so switching configs
        // drops the drafts of the old root. Refuse while they are unsaved.
        if hasUnsavedChanges(in: configRoot) {
            statusMessage = "Save or discard your edits in \(selectedConfig?.name ?? configRoot.lastPathComponent) before switching configs."
            return
        }
        selectedConfigID = id
        configRoot = config.url
        newConfigPath = config.path
        UserDefaults.standard.set(id, forKey: "selectedConfigID")
        UserDefaults.standard.set(config.path, forKey: "configRoot")
        selectedFileID = nil
        sessions.removeAll()
        valueIndex.removeAll()
        // The steps belong to the old root, so they go with its drafts.
        if !keepHistory {
            undoStack.clear()
            undoRevision &+= 1
        }
        reload()
    }

    func addConfig(name: String, path: String, selectAfterAdd: Bool) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Give the config a name before adding it."
            return
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard !expanded.isEmpty else {
            statusMessage = "Choose a config folder first."
            return
        }
        if let existing = configs.first(where: { SketchyBarStore.isSameConfigFolder($0.url, url) }) {
            if selectAfterAdd { selectConfig(existing.id) }
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            statusMessage = "No config folder found at \(url.path)."
            return
        }
        let config = ConfigWorkspace.make(name: trimmedName, url: url)
        configs.append(config)
        saveConfigLibrary()
        newConfigName = ""
        newConfigPath = url.path
        statusMessage = "Added config \(config.name)."
        if selectAfterAdd { selectConfig(config.id) }
    }

    func removeConfig(_ id: ConfigWorkspace.ID) {
        guard configs.count > 1 else {
            statusMessage = "Keep at least one config."
            return
        }
        guard let config = configs.first(where: { $0.id == id }) else { return }
        guard !hasUnsavedChanges(in: config.url) else {
            statusMessage = "Save or discard edits in \(config.name) before removing it from the library."
            return
        }
        configs.removeAll { $0.id == id }
        saveConfigLibrary()
        if selectedConfigID == id, let first = configs.first { selectConfig(first.id) }
    }

    func activateSelectedConfigAsLiveSymlink() {
        guard let selectedConfig else { return }
        do {
            try configSwitchService.activate(config: selectedConfig)
            statusMessage = "Activated \(selectedConfig.name) as ~/.config/sketchybar symlink."
            applySketchyBarReload()
        } catch {
            statusMessage = "Config switch failed: \(error.localizedDescription)"
        }
    }

    func update(valueID: LuaEditableValue.ID, draftValue: String) {
        guard let location = valueIndex[valueID] else {
            statusMessage = "That value no longer exists — reload the file to pick up changes."
            return
        }
        guard let previous = value(at: location)?.draftValue else {
            statusMessage = "That value no longer exists — reload the file to pick up changes."
            return
        }
        guard applyDraft(valueID: valueID, draftValue: draftValue) else { return }
        registerUndo(UndoAction(
            title: "Change \(value(at: location)?.keyPath ?? "value")",
            coalescingKey: "value:\(location.fileID):\(valueID)",
            undo: { [weak self] in
                guard let self else { return false }
                guard self.valueIsGone(valueID) else {
                    guard self.applyDraft(valueID: valueID, draftValue: previous) else {
                        self.statusMessage = "Undo failed: \(self.statusMessage)"
                        return false
                    }
                    return true
                }
                // The value is gone, so there is nothing to undo.
                self.statusMessage = "The value no longer exists, so the edit was skipped."
                return true
            },
            redo: { [weak self] in
                guard let self else { return false }
                guard self.valueIsGone(valueID) else {
                    return self.applyDraft(valueID: valueID, draftValue: draftValue)
                }
                // The value is gone, so there is nothing to redo.
                self.statusMessage = "The value no longer exists, so the edit was skipped."
                return true
            },
            // A step whose value is gone is dropped, so it cannot block the
            // history for good.
            isDead: { [weak self] in self?.valueIsGone(valueID) ?? true }
        ))
    }

    /// Writes a draft into a value without adding an undo step.
    @discardableResult
    private func applyDraft(valueID: LuaEditableValue.ID, draftValue: String) -> Bool {
        guard let location = valueIndex[valueID] else {
            statusMessage = "That value no longer exists — reload the file to pick up changes."
            return false
        }
        guard sessions[location.fileID]?.hasRawDraft != true else {
            statusMessage = "Save or revert the source draft before changing this file with controls."
            return false
        }
        guard var session = sessions[location.fileID], value(at: location) != nil else {
            statusMessage = "That value no longer exists — reload the file to pick up changes."
            return false
        }
        var values = session.file.values
        values[location.position].draftValue = draftValue
        // The flags of the file are kept, so a file that is missing from
        // disk stays marked as missing after an edit.
        session.file = ConfigFile(
            url: session.file.url,
            rootURL: session.file.rootURL,
            kind: session.file.kind,
            values: values,
            activationReference: session.file.activationReference,
            isMissingFromDisk: session.file.isMissingFromDisk
        )
        sessions[location.fileID] = session
        syncFiles()
        return true
    }

    /// The value an index entry points at, when it still holds that value.
    private func value(at location: ValueLocation) -> LuaEditableValue? {
        guard let session = sessions[location.fileID],
              session.file.values.indices.contains(location.position),
              session.file.values[location.position].id == location.valueID else { return nil }
        return session.file.values[location.position]
    }

    /// True when the value of an undo step is gone from the file.
    ///
    /// Such a step has nothing left to do, so it must not block the
    /// history.
    private func valueIsGone(_ valueID: LuaEditableValue.ID) -> Bool {
        guard let location = valueIndex[valueID] else { return true }
        return value(at: location) == nil
    }

    /// True when the file of an undo step is gone, so the step has nothing
    /// left to do.
    private func sourceIsGone(_ fileID: ConfigFile.ID) -> Bool {
        sessions[fileID] == nil
    }

    /// Adds an undo step for a change the user made.
    private func registerUndo(_ action: UndoAction) {
        undoStack.register(action)
        undoRevision &+= 1
    }

    @discardableResult
    func saveSelectedFile() -> Bool {
        guard let selectedFile, var session = sessions[selectedFile.id] else { return false }
        guard !(session.hasRawDraft && session.hasStructuredDraft) else {
            statusMessage = DocumentSessionError.competingDrafts.localizedDescription
            return false
        }
        guard session.hasUnsavedChanges || !stagedLoaderOrders.isEmpty else {
            statusMessage = "No unsaved changes in \(selectedFile.displayName)."
            return true
        }
        let droppedDrafts = missingDraftCount(in: session)
        var fileContentsSaved = false
        do {
            if session.hasUnsavedChanges {
                try session.save(using: luaScanner, shellScanner: shellScanner, backupService: backupService)
                sessions[selectedFile.id] = session
                fileContentsSaved = true
            }
            for key in stagedLoaderOrders.keys.sorted() { try applyStagedLoaderOrder(forKey: key) }
            reload(preservingDraftsExcept: [selectedFile.id])
            statusMessage = "Saved \(selectedFile.displayName) and backed up the original under backups/." + droppedDraftSuffix(droppedDrafts)
            return true
        } catch {
            if fileContentsSaved {
                reload(preservingDraftsExcept: [selectedFile.id])
                statusMessage = "Saved \(selectedFile.displayName), but its loader order could not be saved: \(error.localizedDescription)"
            } else {
                statusMessage = "Save failed for \(selectedFile.displayName): \(error.localizedDescription)"
            }
            return false
        }
    }

    @discardableResult
    func saveAllChangedFiles() -> Bool {
        // The drafts of files that vanished from disk count too, so the
        // quit guard does not offer a save that cannot save everything.
        let changedIDs = Set((files + missingFiles).compactMap { hasUnsavedChanges(fileID: $0.id) ? $0.id : nil })
        guard !changedIDs.isEmpty else {
            statusMessage = "No unsaved changes."
            return true
        }
        var savedFileIDs: Set<ConfigFile.ID> = []
        var droppedDrafts = 0
        var missingFileNames: [String] = []
        guard !files.contains(where: { sessions[$0.id]?.hasRawDraft == true && $0.hasUnsavedChanges }) else {
            statusMessage = DocumentSessionError.competingDrafts.localizedDescription
            return false
        }
        do {
            for fileID in changedIDs {
                guard var session = sessions[fileID] else { continue }
                if session.file.isMissingFromDisk {
                    // There is no file to write, so the draft stays in
                    // memory and is reported instead of being lost.
                    missingFileNames.append(session.file.displayName)
                    continue
                }
                droppedDrafts += missingDraftCount(in: session)
                try session.save(using: luaScanner, shellScanner: shellScanner, backupService: backupService)
                sessions[fileID] = session
                savedFileIDs.insert(fileID)
            }
            for key in stagedLoaderOrders.keys.sorted() { try applyStagedLoaderOrder(forKey: key) }
            reload(preservingDraftsExcept: savedFileIDs)
            statusMessage = savedMessage(savedCount: savedFileIDs.count, missingFileNames: missingFileNames)
                + droppedDraftSuffix(droppedDrafts)
            return missingFileNames.isEmpty
        } catch {
            if !savedFileIDs.isEmpty { reload(preservingDraftsExcept: savedFileIDs) }
            statusMessage = "Save All stopped: \(error.localizedDescription)"
            return false
        }
    }

    func saveAllAndApply() {
        guard saveAllChangedFiles() else { return }
        applySketchyBarReload()
    }

    func discardSelectedChanges() {
        guard let selectedFile else { return }
        let fileID = selectedFile.id
        let capturedSession = sessions[fileID]
        let capturedKey = loaderKey(for: selectedFile)
        let capturedOrder = capturedKey.flatMap { stagedLoaderOrders[$0] }
        applyDiscardChanges(for: fileID)
        statusMessage = "Discarded unsaved edits for \(selectedFile.displayName)."
        registerUndo(UndoAction(
            title: "Discard edits of \(selectedFile.displayName)",
            coalescingKey: nil,
            undo: { [weak self] in
                self?.restoreDiscardedChanges(
                    fileID: fileID,
                    session: capturedSession,
                    key: capturedKey,
                    order: capturedOrder
                ) ?? false
            },
            redo: { [weak self] in self?.applyDiscardChanges(for: fileID) ?? false }
        ))
    }

    /// Drops the drafts and the staged loader order of a file.
    @discardableResult
    private func applyDiscardChanges(for fileID: ConfigFile.ID) -> Bool {
        sessions.removeValue(forKey: fileID)
        discardStagedLoaderChange(fileID: fileID)
        reload(preservingDraftsExcept: [fileID])
        if files.contains(where: { $0.id == fileID }) { selectedFileID = fileID }
        return true
    }

    /// Puts back the drafts and the staged loader order a discard removed.
    /// The drafts go through the normal merge, so a draft only lands on the
    /// value it was made on.
    @discardableResult
    private func restoreDiscardedChanges(
        fileID: ConfigFile.ID,
        session: DocumentSession?,
        key: String?,
        order: [ConfigFile.ID]?
    ) -> Bool {
        if let session {
            sessions[fileID] = session
        }
        if let key, let order {
            stagedLoaderOrders[key] = order
        } else if let key {
            stagedLoaderOrders.removeValue(forKey: key)
        }
        reload(preservingDraftsExcept: [])
        recomputeStagedChangedFileIDs()
        stagedOrderRevision &+= 1
        return true
    }

    func prepareSourceEditing(for file: ConfigFile) {
        guard !file.hasUnsavedChanges else {
            statusMessage = "Save or discard control edits in \(file.displayName) before editing its source."
            return
        }
        guard var session = sessions[file.id] else { return }
        let loaded = session.savedContents
        if session.draftContents == nil { session.loadRawDraft() }
        // The values are read again, so their offsets belong to the text the
        // app writes with.
        store(session: rescanValues(in: session))
        sourceDraftRevision &+= 1
        if loaded != session.savedContents {
            statusMessage = "\(file.displayName) changed on disk. It was read again, so the preview shows the file as it is now."
        }
    }

    func canEditSource(for file: ConfigFile) -> Bool {
        !file.hasUnsavedChanges
    }

    func sourceContents(for file: ConfigFile) -> String { sessions[file.id]?.sourceContents ?? "" }
    func sourceLoadError(for file: ConfigFile) -> String? { loadError(for: file) }
    func sourceHasUnsavedChanges(for file: ConfigFile) -> Bool {
        _ = sourceDraftRevision
        return sessions[file.id]?.sourceHasUnsavedChanges == true
    }

    /// The contents the file would have with the pending drafts applied: the
    /// raw source draft when there is one, otherwise the saved contents with
    /// the structured drafts applied.
    ///
    /// The result is nil when the drafts cannot be applied to the text the
    /// app holds. That happens when the file changed on disk after the
    /// values were scanned, because the offsets of a value belong to the
    /// text it was scanned from.
    func effectiveContents(for file: ConfigFile) -> String? {
        guard let session = sessions[file.id] else { return nil }
        if session.hasRawDraft { return session.sourceContents }
        guard session.hasStructuredDraft else { return session.savedContents }
        guard Self.draftsFitBase(session.file.values, base: session.savedContents) else {
            reportPreviewIssue(for: file)
            return nil
        }
        switch file.kind {
        case .lua:
            return luaScanner.updatedContents(values: session.file.values, originalContents: session.savedContents)
        case .shell, .sketchybarRC:
            return shellScanner.updatedContents(values: session.file.values, originalContents: session.savedContents)
        }
    }

    /// True when the edited values of a file can be written into the text
    /// the app holds.
    ///
    /// The offsets of a value belong to the text it was scanned from, so
    /// they may only be used on that text.
    static func draftsFitBase(_ values: [LuaEditableValue], base: String) -> Bool {
        for value in values where value.draftValue != value.originalValue && !value.isMissingFromFile {
            guard value.sourceSnapshot == base,
                  value.valueStartOffset >= 0,
                  value.valueEndOffset >= value.valueStartOffset,
                  value.valueStartOffset <= base.count,
                  value.valueEndOffset <= base.count else { return false }
        }
        return true
    }

    /// The reason the preview of a file cannot be shown, when it cannot.
    func previewIssue(for file: ConfigFile) -> String? {
        guard let session = sessions[file.id] else { return nil }
        guard !session.hasRawDraft, session.hasStructuredDraft else { return nil }
        guard Self.draftsFitBase(session.file.values, base: session.savedContents) else {
            return "\(file.displayName) changed on disk, so the preview cannot be shown. Reload the config first."
        }
        return nil
    }

    /// Tells the user that the preview of a file cannot be shown.
    ///
    /// The message is set outside the view update, so the view is not
    /// redrawn while it draws.
    private func reportPreviewIssue(for file: ConfigFile) {
        guard let message = previewIssue(for: file), statusMessage != message else { return }
        Task { [weak self] in
            guard let self, self.statusMessage != message else { return }
            self.statusMessage = message
        }
    }

    /// What a save would write, with the text it is compared against.
    ///
    /// The base is the text the app holds, not the text on disk, so the
    /// review shows the change the write really makes. A file that changed
    /// on disk gets a notice, because the save will be refused.
    func saveReview(for file: ConfigFile) -> SaveReviewPreview? {
        guard let session = sessions[file.id], session.loadError == nil else { return nil }
        guard let contents = effectiveContents(for: file) else { return nil }
        let base = session.savedContents
        let disk = try? String(contentsOf: file.url, encoding: .utf8)
        let notice = disk != nil && disk != base
            ? "\(file.displayName) changed on disk since it was loaded. Reload it before saving; the diff below shows the change against the loaded text."
            : nil
        return SaveReviewPreview(base: base, contents: contents, notice: notice)
    }

    /// The read error of a file, if it could not be loaded. Such a file is
    /// not editable until it is read again.
    func loadError(for file: ConfigFile) -> String? { sessions[file.id]?.loadError }

    func updateSourceContents(_ contents: String, for file: ConfigFile) {
        guard !file.hasUnsavedChanges else {
            statusMessage = "Save or discard control edits before changing this file's source."
            return
        }
        guard var session = sessions[file.id] else { return }
        let previous = session.sourceContents
        let base = session.savedContents
        session.updateSourceContents(contents)
        // The values are read again when the text the app writes with
        // changed, so their offsets belong to that text.
        if base != session.savedContents {
            session = rescanValues(in: session)
        }
        store(session: session)
        sourceDraftRevision &+= 1
        registerUndo(UndoAction(
            title: "Edit source of \(file.displayName)",
            coalescingKey: "source:\(file.id)",
            undo: { [weak self] in self?.applySourceContents(previous, for: file.id) ?? false },
            redo: { [weak self] in self?.applySourceContents(contents, for: file.id) ?? false },
            // A step whose file is gone is dropped, so it cannot block the
            // history for good.
            isDead: { [weak self] in self?.sourceIsGone(file.id) ?? true }
        ))
    }

    /// Writes the source draft of a file without adding an undo step.
    @discardableResult
    private func applySourceContents(_ contents: String, for fileID: ConfigFile.ID) -> Bool {
        guard var session = sessions[fileID] else {
            // The file is gone, so there is nothing to restore.
            statusMessage = "The file is gone, so the source edit was skipped."
            return true
        }
        guard !session.file.hasUnsavedChanges else {
            statusMessage = "Save or discard control edits before changing this file's source."
            return false
        }
        session.updateSourceContents(contents)
        store(session: rescanValues(in: session))
        sourceDraftRevision &+= 1
        return true
    }

    func discardSourceChanges(for file: ConfigFile) {
        guard var session = sessions[file.id] else { return }
        let previous = session.sourceContents
        session.discardSourceChanges()
        store(session: rescanValues(in: session))
        sourceDraftRevision &+= 1
        if session.loadError == nil { statusMessage = "Reverted source edits for \(file.displayName)." }
        registerUndo(UndoAction(
            title: "Revert source of \(file.displayName)",
            coalescingKey: nil,
            undo: { [weak self] in self?.applySourceContents(previous, for: file.id) ?? false },
            redo: { [weak self] in self?.applyDiscardSourceChanges(for: file.id) ?? false },
            // A step whose file is gone is dropped, so it cannot block the
            // history for good.
            isDead: { [weak self] in self?.sourceIsGone(file.id) ?? true }
        ))
    }

    /// Reads the source of a file from disk again, without adding an undo
    /// step.
    @discardableResult
    private func applyDiscardSourceChanges(for fileID: ConfigFile.ID) -> Bool {
        guard var session = sessions[fileID] else {
            // The file is gone, so there is nothing to discard.
            statusMessage = "The file is gone, so the source edit was skipped."
            return true
        }
        session.discardSourceChanges()
        store(session: rescanValues(in: session))
        sourceDraftRevision &+= 1
        return true
    }

    @discardableResult
    func saveRawContents(for file: ConfigFile) -> Bool {
        guard var session = sessions[file.id], session.hasRawDraft else {
            statusMessage = "No unsaved source changes in \(file.displayName)."
            return true
        }
        do {
            try session.save(using: luaScanner, shellScanner: shellScanner, backupService: backupService)
            sessions[file.id] = session
            sourceDraftRevision &+= 1
            reload(preservingDraftsExcept: [file.id])
            statusMessage = "Saved source for \(file.displayName) and backed up the original under backups/."
            return true
        } catch {
            statusMessage = "Source save failed for \(file.displayName): \(error.localizedDescription)"
            return false
        }
    }

    func revealSelectedFile() {
        guard let selectedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedFile.url])
    }

    func openSelectedFileExternally() {
        guard let selectedFile else { return }
        NSWorkspace.shared.open(selectedFile.url)
    }

    func applySketchyBarReload() {
        statusMessage = "Reloading SketchyBar..."
        Task.detached(priority: .userInitiated) { [weak self] in
            let message = SketchyBarStore.runSketchyBarReload()
            await self?.setStatusMessage(message)
        }
    }

    @discardableResult
    func moveItem(fileID: ConfigFile.ID, direction: MoveDirection) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }), let key = loaderKey(for: file) else { return false }
        var order = stagedLoaderOrders[key] ?? baseLoaderOrder(forKey: key)
        guard let index = order.firstIndex(of: fileID) else { return false }
        let targetIndex = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(targetIndex) else { return false }
        let previous = stagedLoaderOrders[key]
        order.swapAt(index, targetIndex)
        let staged = order
        setStagedLoaderOrder(order, forKey: key)
        statusMessage = "Staged \(file.displayName) \(direction == .up ? "earlier" : "later"). Save to update the loader."
        registerUndo(UndoAction(
            title: "Move \(file.displayName) \(direction == .up ? "earlier" : "later")",
            coalescingKey: "order:\(key):\(fileID)",
            undo: { [weak self] in self?.restoreStagedOrder(previous, forKey: key) ?? false },
            redo: { [weak self] in self?.restoreStagedOrder(staged, forKey: key) ?? false }
        ))
        return true
    }

    @discardableResult
    func moveItem(fileID: ConfigFile.ID, before targetFileID: ConfigFile.ID) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }),
              let targetFile = files.first(where: { $0.id == targetFileID }),
              file.id != targetFile.id else {
            statusMessage = "That item cannot be moved here."
            return false
        }
        guard let key = loaderKey(for: file) else {
            statusMessage = "\(file.displayName) is not loaded by an entrypoint, so it has no loader order."
            return false
        }
        guard key == loaderKey(for: targetFile) else {
            statusMessage = "Items loaded by different entrypoints cannot be reordered together."
            return false
        }
        var order = stagedLoaderOrders[key] ?? baseLoaderOrder(forKey: key)
        guard let sourceIndex = order.firstIndex(of: fileID), let targetIndex = order.firstIndex(of: targetFileID) else {
            statusMessage = "That item cannot be moved here."
            return false
        }
        let previous = stagedLoaderOrders[key]
        order.remove(at: sourceIndex)
        order.insert(fileID, at: sourceIndex < targetIndex ? targetIndex - 1 : targetIndex)
        let staged = order
        setStagedLoaderOrder(order, forKey: key)
        statusMessage = "Staged \(file.displayName) before \(targetFile.displayName). Save to update the loader."
        registerUndo(UndoAction(
            title: "Move \(file.displayName) before \(targetFile.displayName)",
            coalescingKey: "order:\(key):\(fileID)",
            undo: { [weak self] in self?.restoreStagedOrder(previous, forKey: key) ?? false },
            redo: { [weak self] in self?.restoreStagedOrder(staged, forKey: key) ?? false }
        ))
        return true
    }

    /// Puts a staged loader order back.
    @discardableResult
    private func restoreStagedOrder(_ order: [ConfigFile.ID]?, forKey key: String) -> Bool {
        if let order {
            stagedLoaderOrders[key] = order
        } else {
            stagedLoaderOrders.removeValue(forKey: key)
        }
        recomputeStagedChangedFileIDs()
        stagedOrderRevision &+= 1
        return true
    }

    /// Moves an item to another bar position and stages its loader order in
    /// one step. The position is only changed when the order change is
    /// accepted, so a rejected move never leaves half of the edit behind.
    @discardableResult
    func moveItem(fileID: ConfigFile.ID, before targetFileID: ConfigFile.ID?, to position: String) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }) else {
            statusMessage = "That item is no longer in the config."
            return false
        }
        guard sessions[fileID]?.hasRawDraft != true else {
            statusMessage = "Save or revert the source draft before moving this item."
            return false
        }
        if let targetFileID {
            guard moveItem(fileID: fileID, before: targetFileID) else { return false }
        }
        if let positionValue = file.values.first(where: { SketchyBarValueRules.leaf(of: $0.keyPath) == "position" }) {
            update(valueID: positionValue.id, draftValue: position)
        }
        return true
    }

    /// The position of every file in the loader order, with the staged
    /// changes applied. The sidebar uses it to show the staged order.
    func loaderRanks() -> [ConfigFile.ID: Int] {
        var ranks: [ConfigFile.ID: Int] = [:]
        for (index, file) in filesInPreviewOrder.enumerated() {
            ranks[file.id] = index
        }
        return ranks
    }

    /// The staged position of a file inside its loader, when the order
    /// changed. The number is not written to disk until the file is saved.
    func stagedPosition(for file: ConfigFile) -> Int? {
        guard stagedChangedFileIDs.contains(file.id),
              let key = loaderKey(for: file),
              let order = stagedLoaderOrders[key],
              let index = order.firstIndex(of: file.id) else { return nil }
        return index + 1
    }

    func setActive(_ isActive: Bool, fileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }), canMutateLoader(for: file) else { return }
        do {
            let changes = try activationService.setActive(isActive, for: file)
            let warnings = reload(preservingDraftsExcept: [])
            let confirmation = isActive ? "Activated \(file.displayName)." : "Deactivated \(file.displayName)."
            statusMessage = warnings.isEmpty ? confirmation : confirmation + " " + warnings.joined(separator: " ")
            registerUndo(UndoAction(
                title: isActive ? "Activate \(file.displayName)" : "Deactivate \(file.displayName)",
                // Two toggles are never merged: each one has its own
                // content to put back.
                coalescingKey: nil,
                undo: { [weak self] in self?.restoreActivation(changes, rootURL: file.rootURL) ?? false },
                redo: { [weak self] in self?.applyActivation(isActive, fileID: fileID) ?? false }
            ))
        } catch {
            statusMessage = "Activation update failed: \(error.localizedDescription)"
        }
    }

    /// Puts the loader content back after an activation change. The write
    /// goes through the same guards as the change itself, so a loader file
    /// that changed on disk is never overwritten.
    @discardableResult
    private func restoreActivation(_ changes: [ActivationChange], rootURL: URL) -> Bool {
        do {
            try activationService.restore(changes, rootURL: rootURL)
        } catch {
            statusMessage = "Undo failed: \(error.localizedDescription)"
            return false
        }
        reload(preservingDraftsExcept: [])
        return true
    }

    /// Toggles an item on or off again.
    @discardableResult
    private func applyActivation(_ isActive: Bool, fileID: ConfigFile.ID) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }), canMutateLoader(for: file) else { return false }
        do {
            _ = try activationService.setActive(isActive, for: file)
        } catch {
            statusMessage = "Redo failed: \(error.localizedDescription)"
            return false
        }
        reload(preservingDraftsExcept: [])
        return true
    }

    // MARK: - Clone item

    /// Copies an item file with a new name and a new alias.
    ///
    /// The copy is written through the guarded write of the app, so a file
    /// that already exists is never replaced. The loader line goes into
    /// the loader file of the source, so the copy is loaded next to the
    /// source. A file without an SbarLua item has no alias and gets no
    /// loader line.
    ///
    /// Creating the copy and adding the loader line are two undo steps, so
    /// Cmd-Z takes them back one by one.
    @discardableResult
    func cloneItem(file: ConfigFile, newName: String, newAlias: String) -> CloneItemResult? {
        let cloner = ItemCloner()
        guard isInsideConfigRoot(file.url) else {
            statusMessage = "Refusing to clone a file outside the config folder: \(file.url.path)"
            return nil
        }
        guard let contents = try? String(contentsOf: file.url, encoding: .utf8) else {
            statusMessage = "Could not read \(file.displayName)."
            return nil
        }

        let targetPath = cloner.copyPath(for: relativePath(of: file), newName: newName)
        guard !targetPath.isEmpty else {
            statusMessage = "\(newName) is not a safe file name."
            return nil
        }
        let targetURL = configRoot.appendingPathComponent(targetPath)
        guard isInsideConfigRoot(targetURL) else {
            statusMessage = "Refusing to write outside the config folder: \(targetURL.path)"
            return nil
        }
        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
            statusMessage = "\(targetURL.lastPathComponent) already exists. Choose another name."
            return nil
        }

        let newContents = cloner.clonedContents(of: contents, newAlias: newAlias)
        guard createItemFile(
            contents: newContents,
            at: targetURL,
            overwrite: false,
            undoTitle: "Clone \(targetURL.lastPathComponent)"
        ) else { return nil }

        guard cloner.sourceAlias(in: contents) != nil else {
            statusMessage = "Cloned \(file.displayName) to \(targetPath). The file has no sbar.add(\"item\", ...) call, so no loader line was added."
            return CloneItemResult(
                fileURL: targetURL,
                contents: newContents,
                loaderURL: nil,
                didAddLoaderLine: false,
                loaderFailureMessage: nil
            )
        }
        guard let loaderURL = cloneLoaderURL(for: file) else {
            statusMessage = "Cloned \(file.displayName) to \(targetPath). No loader file was found, so no loader line was added."
            return CloneItemResult(
                fileURL: targetURL,
                contents: newContents,
                loaderURL: nil,
                didAddLoaderLine: false,
                loaderFailureMessage: nil
            )
        }

        let line = ItemScaffolder().loaderLine(for: newAlias, relativePath: targetPath, style: .sbarLua)
        guard insertLoaderLine(line, into: loaderURL, forItemFile: targetURL) else {
            return CloneItemResult(
                fileURL: targetURL,
                contents: newContents,
                loaderURL: loaderURL,
                didAddLoaderLine: false,
                loaderFailureMessage: statusMessage
            )
        }

        statusMessage = "Cloned \(file.displayName) to \(targetPath) and added the loader line to \(loaderURL.lastPathComponent)."
        return CloneItemResult(
            fileURL: targetURL,
            contents: newContents,
            loaderURL: loaderURL,
            didAddLoaderLine: true,
            loaderFailureMessage: nil
        )
    }

    /// The loader file that gets the loader line of a clone.
    ///
    /// The loader of the source comes first. Without one, the loader of the
    /// closest folder that holds the source is used, so the copy is loaded
    /// next to its siblings.
    private func cloneLoaderURL(for file: ConfigFile) -> URL? {
        if let entrypoint = file.activationReference?.entrypointURL { return entrypoint }

        let folder = file.url.deletingLastPathComponent().standardizedFileURL.path
        let candidates = LoaderCandidates.candidates(in: configRoot)
        let ancestors = candidates
            .filter { folder.hasPrefix($0.deletingLastPathComponent().standardizedFileURL.path + "/") }
            .sorted { $0.path.count > $1.path.count }
        return ancestors.first ?? candidates.first
    }

    /// The path of a file inside the config root.
    private func relativePath(of file: ConfigFile) -> String {
        let rootPath = configRoot.standardizedFileURL.path
        let filePath = file.url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return file.url.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    // MARK: - New configs

    /// Creates a new config from a template.
    ///
    /// The folder of the config is created inside the folder the user
    /// chose. The files are written through the guarded write of the app,
    /// so a symlinked file keeps its link. A file that already exists is
    /// only replaced with `overwrite`, and a replaced file is kept in the
    /// backup mirror first.
    ///
    /// A file that cannot be written takes the files that were written
    /// before it with it, so a half written config is never left behind.
    ///
    /// The config is added to the library and selected, so the new files
    /// show up right away. The creation is undoable: undoing it removes the
    /// files and the entry of the library.
    @discardableResult
    func createConfig(
        name: String,
        in folder: URL,
        style: ConfigScaffolder.Style,
        starterItems: [ConfigScaffolder.StarterItem],
        overwrite: Bool = false
    ) -> NewConfigResult? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "Give the config a name before creating it."
            return nil
        }
        guard !trimmedName.contains("/"), trimmedName != ".", trimmedName != ".." else {
            statusMessage = "The name of the config may not hold a slash."
            return nil
        }

        let rootURL = folder.standardizedFileURL.appendingPathComponent(trimmedName)
        let files = ConfigScaffolder().fileContents(style: style, starterItems: starterItems)
        let rootExisted = FileManager.default.fileExists(atPath: rootURL.path)

        guard let written = writeNewConfigFiles(files, rootURL: rootURL, overwrite: overwrite) else {
            // The write took the files it wrote with it. The folder of the
            // config only goes when the app created it.
            if !rootExisted { try? FileManager.default.removeItem(at: rootURL) }
            return nil
        }

        let config = ConfigWorkspace.make(name: trimmedName, url: rootURL)
        configs.append(config)
        saveConfigLibrary()
        newConfigPath = rootURL.path
        selectConfig(config.id)
        let isSelected = selectedConfigID == config.id
        statusMessage = createdConfigMessage(trimmedName, fileCount: written.count, isSelected: isSelected)

        registerUndo(UndoAction(
            title: "Create config \(trimmedName)",
            // The creation of a config is never merged with another change.
            coalescingKey: nil,
            undo: { [weak self] in
                self?.undoNewConfig(config: config, files: written, rootURL: rootURL, removeRoot: !rootExisted) ?? false
            },
            redo: { [weak self] in
                self?.redoNewConfig(config: config, files: files, rootURL: rootURL) ?? false
            }
        ))
        return NewConfigResult(rootURL: rootURL, fileURLs: written, configID: config.id)
    }

    /// Writes the files of a new config.
    ///
    /// The files are written through the guarded write of the app, so a
    /// symlinked file keeps its link. A file that already exists is only
    /// replaced with `overwrite`, and a replaced file is kept in the backup
    /// mirror first.
    ///
    /// A file that cannot be written takes the files that were written
    /// before it with it, so a half written config is never left behind.
    /// The method returns the files that were written, or nil when the
    /// creation was refused.
    private func writeNewConfigFiles(
        _ files: [String: String],
        rootURL: URL,
        overwrite: Bool
    ) -> [URL]? {
        let replacer = SafeFileReplacer()
        var written: [URL] = []

        for (relativePath, contents) in files.sorted(by: { $0.key < $1.key }) {
            let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
            guard isInside(url, root: rootURL) else {
                removeNewConfigFiles(written, rootURL: rootURL, removeRoot: false)
                statusMessage = "Refusing to write outside the config folder: \(url.path)"
                return nil
            }

            if replacer.itemExists(at: url) {
                guard overwrite else {
                    removeNewConfigFiles(written, rootURL: rootURL, removeRoot: false)
                    statusMessage = "\(relativePath) already exists. Confirm to replace it."
                    return nil
                }
                do {
                    // A file that is replaced is kept in the backup mirror
                    // first.
                    _ = try backupService.backup(fileURL: url, rootURL: rootURL)
                } catch {
                    removeNewConfigFiles(written, rootURL: rootURL, removeRoot: false)
                    statusMessage = "Could not back up \(relativePath): \(error.localizedDescription)"
                    return nil
                }
            }

            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try replacer.writeAtomicallyPreservingSymlinks(contents, to: url)
            } catch {
                removeNewConfigFiles(written, rootURL: rootURL, removeRoot: false)
                statusMessage = "Could not create \(relativePath): \(error.localizedDescription)"
                return nil
            }
            written.append(url)
        }

        return written
    }

    /// Removes the files of a new config and the folders that are empty
    /// afterwards.
    ///
    /// A folder that still holds something is kept, so nothing of the user
    /// is lost. The folder of the config only goes when the app created it.
    private func removeNewConfigFiles(_ urls: [URL], rootURL: URL, removeRoot: Bool) {
        for url in urls.reversed() {
            try? FileManager.default.removeItem(at: url)
        }

        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var folders: Set<URL> = []
        for url in urls {
            var folder = url.deletingLastPathComponent()
            while folder.standardizedFileURL.path.hasPrefix(rootPrefix) {
                folders.insert(folder)
                folder = folder.deletingLastPathComponent()
            }
        }
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            // A folder that still holds something is not removed.
            try? FileManager.default.removeItem(at: folder)
        }

        if removeRoot {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    /// Takes a new config back: the files and the entry of the library go.
    private func undoNewConfig(
        config: ConfigWorkspace,
        files: [URL],
        rootURL: URL,
        removeRoot: Bool
    ) -> Bool {
        removeNewConfigFiles(files, rootURL: rootURL, removeRoot: removeRoot)
        configs.removeAll { $0.id == config.id }
        saveConfigLibrary()
        if selectedConfigID == config.id, let first = configs.first {
            // The history stays, so the creation can be done again.
            selectConfig(first.id, keepHistory: true)
        }
        statusMessage = "Removed the config \(config.name)."
        return true
    }

    /// Creates a new config again after an undo.
    private func redoNewConfig(
        config: ConfigWorkspace,
        files: [String: String],
        rootURL: URL
    ) -> Bool {
        guard let written = writeNewConfigFiles(files, rootURL: rootURL, overwrite: false) else {
            return false
        }
        if !configs.contains(where: { $0.id == config.id }) {
            configs.append(config)
            saveConfigLibrary()
        }
        // The history stays, so the creation can be taken back again.
        selectConfig(config.id, keepHistory: true)
        let isSelected = selectedConfigID == config.id
        statusMessage = createdConfigMessage(config.name, fileCount: written.count, isSelected: isSelected)
        return true
    }

    /// The message of a created config.
    private func createdConfigMessage(_ name: String, fileCount: Int, isSelected: Bool) -> String {
        let message = "Created the config \(name) with \(fileCount) files."
        guard !isSelected else { return message }
        return message + " It was not selected, because the current config has unsaved edits."
    }

    // MARK: - New item files

    /// Creates a new config file with the given contents.
    ///
    /// The file is written through the guarded write of the app, so a
    /// symlinked file keeps its link. The folder of the file is created when
    /// it does not exist yet, but only inside the config root. An existing
    /// file is never replaced without `overwrite`, and a replaced file is
    /// kept in the backup mirror first.
    ///
    /// The config is reloaded and the new file is selected, so the file
    /// shows up in the sidebar right away. The change is undoable: undoing
    /// it removes the new file, or puts the old text back when the file
    /// existed before.
    @discardableResult
    func createItemFile(contents: String, at url: URL, overwrite: Bool = false, undoTitle: String? = nil) -> Bool {
        guard isInsideConfigRoot(url) else {
            statusMessage = "Refusing to write outside the config folder: \(url.path)"
            return false
        }

        let replacer = SafeFileReplacer()
        let existed = replacer.itemExists(at: url)
        if existed, !overwrite {
            statusMessage = "\(url.lastPathComponent) already exists. Confirm to replace it."
            return false
        }

        var previousBytes: Data?
        if existed {
            // The bytes of the file that is replaced are kept, so the undo
            // can put the file back exactly as it was. A file whose bytes
            // cannot be read is never replaced, because such a change
            // could never be undone.
            guard let bytes = try? Data(contentsOf: url) else {
                statusMessage = "Could not read \(url.lastPathComponent), so it is not replaced."
                return false
            }
            previousBytes = bytes
            do {
                // A file that is replaced is kept in the backup mirror first.
                _ = try backupService.backup(fileURL: url, rootURL: configRoot)
            } catch {
                statusMessage = "Could not back up \(url.lastPathComponent): \(error.localizedDescription)"
                return false
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try replacer.writeAtomicallyPreservingSymlinks(contents, to: url)
        } catch {
            statusMessage = "Could not create \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }

        reload(preservingDraftsExcept: [])
        if let created = files.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            selectedFileID = created.id
        }
        statusMessage = "Created \(url.lastPathComponent)."

        registerUndo(UndoAction(
            title: undoTitle ?? "Create \(url.lastPathComponent)",
            // The creation and the loader line are two steps, so they are
            // never merged.
            coalescingKey: nil,
            undo: { [weak self] in
                self?.removeCreatedItemFile(at: url, contents: contents, previousBytes: previousBytes) ?? false
            },
            redo: { [weak self] in self?.writeItemFile(contents: contents, at: url) ?? false }
        ))
        return true
    }

    /// Removes a file the app created, when it still holds the text the app
    /// wrote. A file that existed before the creation is put back with its
    /// old bytes.
    ///
    /// The content of the file is read and compared first, so a file that
    /// changed on disk is refused before anything is changed.
    @discardableResult
    func removeCreatedItemFile(at url: URL, contents: String, previousBytes: Data? = nil) -> Bool {
        let current = try? Data(contentsOf: url)
        if let current {
            // The file is there, so it must still hold the text the app
            // wrote.
            guard let text = String(data: current, encoding: .utf8), text == contents else {
                statusMessage = "Undo failed: \(url.lastPathComponent) changed on disk and was not removed."
                return false
            }
        }

        // The loader line of the item goes with the file.
        let key = url.standardizedFileURL.path
        if let record = loaderLineRecords[key] {
            guard removeLoaderLineIfPresent(record) else { return false }
            loaderLineRecords.removeValue(forKey: key)
        }

        guard current != nil else {
            // The file is gone already.
            reload(preservingDraftsExcept: [])
            return true
        }

        do {
            if let previousBytes {
                // The bytes of the file that was replaced are put back.
                let target = SafeFileReplacer().resolvedFileURL(for: url)
                try previousBytes.write(to: target, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            statusMessage = "Undo failed: \(error.localizedDescription)"
            return false
        }

        reload(preservingDraftsExcept: [])
        statusMessage = "Removed \(url.lastPathComponent)."
        return true
    }

    /// Adds a loader line to a loader file.
    ///
    /// The write goes through the guarded path of the activation service:
    /// the file is read again before the write, a backup is made, and a
    /// symlinked file keeps its link. The change is undoable, and the undo
    /// puts the loader file back byte for byte.
    ///
    /// A loader file with an unsaved source draft is refused, because the
    /// draft could never be saved after the loader changed.
    @discardableResult
    func insertLoaderLine(_ line: String, into entrypointURL: URL, forItemFile itemFileURL: URL? = nil) -> Bool {
        guard canMutateLoader(at: entrypointURL) else { return false }
        do {
            let change = try activationService.insertLoaderLine(line, into: entrypointURL, rootURL: configRoot)
            let record = LoaderLineRecord(change: change, line: line)
            let key = (itemFileURL ?? entrypointURL).standardizedFileURL.path
            loaderLineRecords[key] = record
            reload(preservingDraftsExcept: [])
            statusMessage = "Added the loader line to \(entrypointURL.lastPathComponent)."
            registerUndo(UndoAction(
                title: "Add loader line in \(entrypointURL.lastPathComponent)",
                coalescingKey: nil,
                undo: { [weak self] in self?.undoLoaderLine(record, key: key) ?? false },
                redo: { [weak self] in self?.redoLoaderLine(record, key: key) ?? false }
            ))
            return true
        } catch {
            statusMessage = "Could not add the loader line: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes the file of a created item again, after an undo.
    private func writeItemFile(contents: String, at url: URL) -> Bool {
        guard isInsideConfigRoot(url) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try SafeFileReplacer().writeAtomicallyPreservingSymlinks(contents, to: url)
        } catch {
            statusMessage = "Redo failed: \(error.localizedDescription)"
            return false
        }
        reload(preservingDraftsExcept: [])
        statusMessage = "Created \(url.lastPathComponent)."
        return true
    }

    /// Takes the loader line of a created item away.
    private func undoLoaderLine(_ record: LoaderLineRecord, key: String) -> Bool {
        do {
            try activationService.restore([record.change], rootURL: configRoot)
        } catch {
            statusMessage = "Undo failed: \(error.localizedDescription)"
            return false
        }
        loaderLineRecords.removeValue(forKey: key)
        reload(preservingDraftsExcept: [])
        statusMessage = "Removed the loader line from \(record.change.entrypointURL.lastPathComponent)."
        return true
    }

    /// Puts the loader line of a created item back.
    private func redoLoaderLine(_ record: LoaderLineRecord, key: String) -> Bool {
        let current = (try? String(contentsOf: record.change.entrypointURL, encoding: .utf8)) ?? ""
        if current == record.change.newContents {
            // The line is already there.
            return true
        }
        guard current == record.change.previousContents else {
            statusMessage = "Redo failed: \(record.change.entrypointURL.lastPathComponent) changed on disk."
            return false
        }
        do {
            let change = try activationService.insertLoaderLine(
                record.line,
                into: record.change.entrypointURL,
                rootURL: configRoot
            )
            loaderLineRecords[key] = LoaderLineRecord(change: change, line: record.line)
            reload(preservingDraftsExcept: [])
            statusMessage = "Added the loader line to \(record.change.entrypointURL.lastPathComponent)."
            return true
        } catch {
            statusMessage = "Redo failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Removes the loader line of a created item, when it is still there.
    private func removeLoaderLineIfPresent(_ record: LoaderLineRecord) -> Bool {
        let current = (try? String(contentsOf: record.change.entrypointURL, encoding: .utf8)) ?? ""
        guard current != record.change.newContents else {
            do {
                try activationService.restore([record.change], rootURL: configRoot)
            } catch {
                statusMessage = "Undo failed: \(error.localizedDescription)"
                return false
            }
            return true
        }
        if current.contains(record.line) {
            // The loader file changed on disk, so the line cannot be taken
            // out without losing the other changes.
            statusMessage = "Undo failed: \(record.change.entrypointURL.lastPathComponent) changed on disk."
            return false
        }
        // The line is gone already.
        return true
    }

    /// True when the url is inside the config root of the store.
    private func isInsideConfigRoot(_ url: URL) -> Bool {
        isInside(url, root: configRoot)
    }

    /// True when the url is inside the given root.
    ///
    /// Both the url and the root are resolved first, so a symlinked folder
    /// inside the root cannot be used to write outside of it. A symlinked
    /// root is fine: the resolved root is the real folder.
    private func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = resolvedPath(of: root)
        let path = resolvedPath(of: url)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    /// The path of a url with every symlink in it resolved.
    ///
    /// A path that does not exist yet is resolved as far as it exists, so
    /// the folders that lead to it are resolved too. Without that, a
    /// symlinked folder inside the config root would look like a folder of
    /// the root.
    private func resolvedPath(of url: URL) -> String {
        var path = url.standardizedFileURL.path
        var rest: [String] = []
        while path != "/", !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                return ([resolved] + rest).joined(separator: "/")
            }
            rest.insert((path as NSString).lastPathComponent, at: 0)
            path = (path as NSString).deletingLastPathComponent
        }
        return url.standardizedFileURL.path
    }

    func saveProfile() {
        do {
            try profileService.saveProfile(named: profileName, from: configRoot, configID: selectedConfigProfileID)
            profileName = ""
            profiles = profileService.listProfiles(for: selectedConfigProfileID)
            statusMessage = "Saved profile for \(selectedConfig?.name ?? "config")."
        } catch {
            statusMessage = "Profile save failed: \(error.localizedDescription)"
        }
    }

    func restore(profile: ConfigProfile) {
        guard !hasUnsavedChanges(in: configRoot) else {
            statusMessage = "Save or discard all edits in this config before restoring a profile."
            return
        }
        do {
            try profileService.restore(profile: profile, to: configRoot)
            reload(preservingDraftsExcept: Set(files.map(\.id)))
            statusMessage = "Restored \(profile.name). A timestamped copy of the previous config was kept in the app's Application Support folder."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Reads every config file once and scans it. It only touches file
    /// URLs, so it can run off the main actor.
    nonisolated private static func scanConfig(rootURL: URL, configURLs: [URL]) -> [ScannedConfigFile] {
        let locator = SketchyBarConfigLocator()
        let activationReferences = ConfigActivationService().references(for: configURLs, rootURL: rootURL)

        return configURLs.compactMap { url in
            guard let kind = locator.kind(for: url) else { return nil }

            var contents: String?
            var loadError: String?
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch {
                loadError = error.localizedDescription
            }

            let text = contents ?? ""
            let values: [LuaEditableValue]
            switch kind {
            case .lua: values = LuaConfigScanner().scan(fileURL: url, contents: text)
            case .shell, .sketchybarRC: values = ShellConfigScanner().scan(fileURL: url, contents: text)
            }

            let file = ConfigFile(
                url: url,
                rootURL: rootURL,
                kind: kind,
                values: values,
                activationReference: activationReferences[url.path]
            )
            return ScannedConfigFile(file: file, contents: contents, loadError: loadError)
        }
    }

    /// Re-reads every config file. Drafts are carried over by stable key, so
    /// they survive line shifts. Files that vanished from disk keep their
    /// session so their drafts are not lost. Returns the warnings that
    /// belong in the status message.
    @discardableResult
    private func reload(preservingDraftsExcept discardedFileIDs: Set<ConfigFile.ID>) -> [String] {
        reloadGeneration += 1
        let scanned = Self.scanConfig(rootURL: configRoot, configURLs: locator.configFiles(in: configRoot))
        return apply(scanned, preservingDraftsExcept: discardedFileIDs)
    }

    /// Takes over a freshly scanned config and rebuilds the session state.
    @discardableResult
    private func apply(_ scanned: [ScannedConfigFile], preservingDraftsExcept discardedFileIDs: Set<ConfigFile.ID>) -> [String] {
        var nextSessions: [ConfigFile.ID: DocumentSession] = [:]
        var warnings: [String] = []
        for scannedFile in scanned {
            let scannedConfig = scannedFile.file
            if discardedFileIDs.contains(scannedConfig.id) {
                nextSessions[scannedConfig.id] = DocumentSession(
                    file: scannedConfig,
                    savedContents: scannedFile.contents ?? "",
                    loadError: scannedFile.loadError
                )
            } else if var existing = sessions[scannedConfig.id] {
                if !existing.hasRawDraft { existing.refresh(with: scannedFile.contents, loadError: scannedFile.loadError) }
                let missingDrafts = existing.merge(from: scannedConfig)
                if missingDrafts > 0 {
                    warnings.append("\(missingDrafts) edited \(missingDrafts == 1 ? "value" : "values") no longer \(missingDrafts == 1 ? "exists" : "exist") in \(scannedConfig.url.lastPathComponent) and \(missingDrafts == 1 ? "was kept as a draft" : "were kept as drafts").")
                }
                nextSessions[scannedConfig.id] = existing
            } else {
                nextSessions[scannedConfig.id] = DocumentSession(
                    file: scannedConfig,
                    savedContents: scannedFile.contents ?? "",
                    loadError: scannedFile.loadError
                )
            }
        }
        // Files that vanished from disk keep their session so drafts survive.
        var vanishedFiles: [ConfigFile] = []
        for (fileID, session) in sessions where nextSessions[fileID] == nil {
            var kept = session
            kept.markMissingFromDisk()
            nextSessions[fileID] = kept
            vanishedFiles.append(kept.file)
        }
        sessions = nextSessions
        vanishedFiles.sort { $0.id < $1.id }
        missingFiles = vanishedFiles
        files = scanned.compactMap { nextSessions[$0.file.id]?.file }
        pruneStagedLoaderOrders()
        profiles = profileService.listProfiles(for: selectedConfigProfileID)
        rebuildValueIndex()
        if selectedFileID == nil {
            selectedFileID = files.first?.id
        } else if !files.contains(where: { $0.id == selectedFileID }) && !missingFiles.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = files.first?.id
        }
        for file in missingFiles {
            warnings.append("\(file.displayName) is missing from disk; its unsaved draft was kept.")
        }
        var message = files.isEmpty
            ? "No supported Lua or shell config files found in \(configRoot.path)."
            : "Loaded \(files.count) config files from \(selectedConfig?.name ?? configRoot.lastPathComponent)."
        if let libraryErrorMessage {
            message += " Config library could not be read: \(libraryErrorMessage)"
        }
        if !warnings.isEmpty { message += " " + warnings.joined(separator: " ") }
        statusMessage = message
        return warnings
    }

    /// Takes over a scan that finished in the background, unless a newer
    /// reload started in the meantime.
    private func applyIfCurrent(_ scanned: [ScannedConfigFile], generation: Int) {
        guard reloadGeneration == generation else { return }
        apply(scanned, preservingDraftsExcept: [])
    }

    private func setStatusMessage(_ message: String) {
        statusMessage = message
    }

    /// Runs `sketchybar --reload` and waits for it with a timeout, so an
    /// Automation prompt cannot freeze the app.
    nonisolated private static func runSketchyBarReload() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--reload"]

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return "Could not run sketchybar --reload: \(error.localizedDescription)"
        }

        if finished.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return "sketchybar --reload did not finish within 10 seconds and was stopped."
        }
        return process.terminationStatus == 0
            ? "SketchyBar reloaded."
            : "sketchybar --reload exited with code \(process.terminationStatus)."
    }

    /// Reads the values of a file again, so their offsets belong to the
    /// text the app writes with.
    ///
    /// A draft that cannot be matched to a value of the new text is kept,
    /// so no work is lost.
    private func rescanValues(in session: DocumentSession) -> DocumentSession {
        var session = session
        let values: [LuaEditableValue]
        switch session.file.kind {
        case .lua:
            values = luaScanner.scan(fileURL: session.file.url, contents: session.savedContents)
        case .shell, .sketchybarRC:
            values = shellScanner.scan(fileURL: session.file.url, contents: session.savedContents)
        }
        let scanned = ConfigFile(
            url: session.file.url,
            rootURL: session.file.rootURL,
            kind: session.file.kind,
            values: values,
            activationReference: session.file.activationReference
        )
        let wasMissing = session.file.isMissingFromDisk
        _ = session.merge(from: scanned)
        session.file.isMissingFromDisk = wasMissing
        return session
    }

    /// Puts a session back into the store and keeps the files and the value
    /// index in step with it.
    private func store(session: DocumentSession) {
        sessions[session.file.id] = session
        syncFiles()
        rebuildValueIndex()
    }

    private func syncFiles() {
        let orderedIDs = files.map(\.id)
        let orderedIDSet = Set(orderedIDs)
        var next = orderedIDs.compactMap { sessions[$0]?.file }
        let leftovers = sessions.values
            .map(\.file)
            .filter { !orderedIDSet.contains($0.id) && !$0.isMissingFromDisk }
            .sorted { $0.id < $1.id }
        next.append(contentsOf: leftovers)
        files = next
        // The files that are missing from disk keep their place in the
        // sidebar, with the drafts they hold.
        missingFiles = sessions.values
            .map(\.file)
            .filter { $0.isMissingFromDisk }
            .sorted { $0.id < $1.id }
    }

    private func rebuildValueIndex() {
        var index: [LuaEditableValue.ID: ValueLocation] = [:]
        for (fileID, session) in sessions {
            for (position, value) in session.file.values.enumerated() where index[value.id] == nil {
                index[value.id] = ValueLocation(fileID: fileID, valueID: value.id, position: position)
            }
        }
        valueIndex = index
    }

    private func missingDraftCount(in session: DocumentSession) -> Int {
        session.file.values.filter { $0.isMissingFromFile && $0.draftValue != $0.originalValue }.count
    }

    private func droppedDraftSuffix(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return " \(count) edited \(count == 1 ? "value" : "values") no longer \(count == 1 ? "exists" : "exist") in the file and could not be saved."
    }

    /// The message of a save that lists what was saved and what could not
    /// be saved because the file is gone.
    private func savedMessage(savedCount: Int, missingFileNames: [String]) -> String {
        var message = savedCount == 0
            ? "No file was saved."
            : "Saved \(savedCount) \(savedCount == 1 ? "file" : "files")."
        guard !missingFileNames.isEmpty else { return message }
        message += " \(missingFileNames.count) \(missingFileNames.count == 1 ? "file is" : "files are") missing from disk and "
            + "\(missingFileNames.count == 1 ? "its draft was not saved" : "their drafts were not saved"): "
            + missingFileNames.joined(separator: ", ")
        return message
    }

    /// Two paths point at the same folder when they resolve to the same
    /// physical location, so a symlinked config is not added twice. The
    /// paths are compared as strings because a resolved directory URL can
    /// carry a trailing slash.
    private static func isSameConfigFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Checks every session, not only the files currently listed, so drafts
    /// in files that vanished from disk are counted too. Sessions only exist
    /// for the current config root.
    private func hasUnsavedChanges(in rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        return sessions.contains { fileID, session in
            URL(fileURLWithPath: fileID).standardizedFileURL.path.hasPrefix(rootPath) && session.hasUnsavedChanges
        }
    }

    private func loaderKey(for file: ConfigFile) -> String? { file.activationReference?.entrypointURL.standardizedFileURL.path }

    private func baseLoaderOrder(forKey key: String) -> [ConfigFile.ID] {
        files.filter { loaderKey(for: $0) == key }
            .sorted {
                let lhs = $0.activationReference?.lineNumber ?? .max
                let rhs = $1.activationReference?.lineNumber ?? .max
                return lhs == rhs ? $0.displayName < $1.displayName : lhs < rhs
            }
            .map(\.id)
    }

    /// The position of every file inside its loader, built once so the
    /// preview sort does not sort the loader again for every comparison.
    private func loaderOrderIndexes() -> [String: [ConfigFile.ID: Int]] {
        var result: [String: [ConfigFile.ID: Int]] = [:]
        for key in Set(files.compactMap { loaderKey(for: $0) }) {
            let order = stagedLoaderOrders[key] ?? baseLoaderOrder(forKey: key)
            result[key] = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
        return result
    }

    private func setStagedLoaderOrder(_ order: [ConfigFile.ID], forKey key: String) {
        if order == baseLoaderOrder(forKey: key) { stagedLoaderOrders.removeValue(forKey: key) }
        else { stagedLoaderOrders[key] = order }
        recomputeStagedChangedFileIDs()
        stagedOrderRevision &+= 1
    }

    private func recomputeStagedChangedFileIDs() {
        var changed: Set<ConfigFile.ID> = []
        for (key, staged) in stagedLoaderOrders {
            let base = baseLoaderOrder(forKey: key)
            for fileID in base where staged.firstIndex(of: fileID) != base.firstIndex(of: fileID) {
                changed.insert(fileID)
            }
        }
        stagedChangedFileIDs = changed
    }

    private func discardStagedLoaderChange(fileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }), let key = loaderKey(for: file), var staged = stagedLoaderOrders[key] else { return }
        let base = baseLoaderOrder(forKey: key)
        guard let baseIndex = base.firstIndex(of: fileID), let stagedIndex = staged.firstIndex(of: fileID) else { return }
        staged.remove(at: stagedIndex)
        let preceding = base[..<baseIndex].reversed().first { staged.contains($0) }
        let following = base.dropFirst(baseIndex + 1).first { staged.contains($0) }
        if let preceding, let index = staged.firstIndex(of: preceding) { staged.insert(fileID, at: index + 1) }
        else if let following, let index = staged.firstIndex(of: following) { staged.insert(fileID, at: index) }
        else { staged.append(fileID) }
        setStagedLoaderOrder(staged, forKey: key)
    }

    private func pruneStagedLoaderOrders() {
        var pruned: [String: [ConfigFile.ID]] = [:]
        for (key, staged) in stagedLoaderOrders {
            let base = baseLoaderOrder(forKey: key)
            let available = Set(base)
            var next = staged.filter { available.contains($0) }
            next.append(contentsOf: base.filter { !next.contains($0) })
            if next != base { pruned[key] = next }
        }
        stagedLoaderOrders = pruned
        recomputeStagedChangedFileIDs()
        stagedOrderRevision &+= 1
    }

    private func applyStagedLoaderOrder(forKey key: String) throws {
        if sessions[key]?.hasRawDraft == true {
            throw SourceDraftError.loaderHasSourceDraft(URL(fileURLWithPath: key).lastPathComponent)
        }
        guard let desired = stagedLoaderOrders[key], desired.count > 1 else {
            stagedLoaderOrders.removeValue(forKey: key)
            recomputeStagedChangedFileIDs()
            return
        }
        let orderedFiles = desired.compactMap { id in files.first(where: { $0.id == id }) }
        try activationService.moveReferences(in: orderedFiles, to: desired)
        stagedLoaderOrders.removeValue(forKey: key)
        recomputeStagedChangedFileIDs()
    }

    private func canMutateLoader(for file: ConfigFile) -> Bool {
        guard let entrypointURL = file.activationReference?.entrypointURL else { return true }
        return canMutateLoader(at: entrypointURL)
    }

    /// True when the loader file can be changed.
    ///
    /// A loader file with an unsaved source draft is refused, because the
    /// draft could never be saved after the loader changed.
    private func canMutateLoader(at entrypointURL: URL) -> Bool {
        guard session(forFileAt: entrypointURL)?.hasRawDraft != true else {
            statusMessage = "Save or discard the source draft for \(entrypointURL.lastPathComponent) before changing the loader."
            return false
        }
        return true
    }

    /// The session of a file, found by its path.
    private func session(forFileAt url: URL) -> DocumentSession? {
        if let session = sessions[url.path] { return session }
        return sessions[url.standardizedFileURL.path]
    }

    private func saveConfigLibrary() {
        do { try configLibraryService.save(configs) }
        catch { statusMessage = "Config library save failed: \(error.localizedDescription)" }
    }

    private static func savedTheme() -> AppTheme {
        guard let rawValue = UserDefaults.standard.string(forKey: "appTheme"), let theme = AppTheme(rawValue: rawValue) else { return .nord }
        return theme
    }
}
