import AppKit
import Foundation

private struct SourceDraft: Equatable {
    var savedContents: String
    var contents: String
    var loadError: String?

    var hasUnsavedChanges: Bool { contents != savedContents }
}

private enum SourceDraftError: LocalizedError {
    case changedOnDisk
    case competingStructuredDraft
    case loaderHasSourceDraft(String)

    var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            return "The file changed on disk after source editing began. Revert the source draft to load the current file, then reapply your edit."
        case .competingStructuredDraft:
            return "This file has both source and control edits. Discard one editing mode before saving so neither draft is overwritten."
        case let .loaderHasSourceDraft(name):
            return "Save or discard the source draft for \(name) before saving loader order changes."
        }
    }
}

final class SketchyBarStore: ObservableObject {
    @Published var configRoot: URL
    @Published var configs: [ConfigWorkspace] = []
    @Published var selectedConfigID: ConfigWorkspace.ID?
    @Published var files: [ConfigFile] = []
    @Published var selectedFileID: ConfigFile.ID?
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

    @Published private var sourceDrafts: [ConfigFile.ID: SourceDraft] = [:]
    @Published private var stagedLoaderOrders: [String: [ConfigFile.ID]] = [:]

    private let locator = SketchyBarConfigLocator()
    private let luaScanner = LuaConfigScanner()
    private let shellScanner = ShellConfigScanner()
    private let activationService = ConfigActivationService()
    private let configLibraryService = ConfigLibraryService()
    private let configSwitchService = ConfigSwitchService()
    private let profileService = ProfileArchiveService()
    private let backupService = ConfigBackupService()

    init(configRoot initialConfigRoot: URL? = nil) {
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
        let loadedConfigs = configLibraryService.load(defaultConfigRoot: defaultRoot)
        let savedConfigID = UserDefaults.standard.string(forKey: "selectedConfigID") ?? loadedConfigs.first?.id
        let selected = loadedConfigs.first { $0.id == savedConfigID } ?? loadedConfigs.first
        configRoot = selected?.url ?? defaultRoot
        configs = loadedConfigs
        selectedConfigID = selected?.id
        newConfigPath = configRoot.path
        reload()
    }

    var selectedConfig: ConfigWorkspace? {
        guard let selectedConfigID else { return configs.first }
        return configs.first { $0.id == selectedConfigID } ?? configs.first
    }

    var selectedFile: ConfigFile? {
        guard let selectedFileID else { return files.first }
        return files.first { $0.id == selectedFileID } ?? files.first
    }

    var unsavedFileCount: Int {
        Set(files.compactMap { hasUnsavedChanges(fileID: $0.id) ? $0.id : nil }).count
    }

    var selectedHasUnsavedChanges: Bool {
        selectedFile.map { hasUnsavedChanges(fileID: $0.id) } ?? false
    }

    var selectedConfigProfileID: String { selectedConfig?.id ?? "default" }

    var isSelectedConfigLive: Bool {
        guard let selectedConfig else { return false }
        return configSwitchService.isLive(config: selectedConfig)
    }

    var filesInPreviewOrder: [ConfigFile] {
        files.sorted { lhs, rhs in
            let lhsKey = loaderKey(for: lhs)
            let rhsKey = loaderKey(for: rhs)
            if let lhsKey, lhsKey == rhsKey {
                let order = stagedLoaderOrders[lhsKey] ?? baseLoaderOrder(forKey: lhsKey)
                let lhsIndex = order.firstIndex(of: lhs.id) ?? .max
                let rhsIndex = order.firstIndex(of: rhs.id) ?? .max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            }
            let lhsLine = lhs.activationReference?.lineNumber ?? .max
            let rhsLine = rhs.activationReference?.lineNumber ?? .max
            return lhsLine == rhsLine
                ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                : lhsLine < rhsLine
        }
    }

    func hasUnsavedChanges(fileID: ConfigFile.ID) -> Bool {
        let structured = files.first { $0.id == fileID }?.hasUnsavedChanges == true
        let source = sourceDrafts[fileID]?.hasUnsavedChanges == true
        return structured || source || hasStagedLoaderChange(fileID: fileID)
    }

    func unsavedChangeCount(fileID: ConfigFile.ID) -> Int {
        let structured = files.first { $0.id == fileID }?.values.filter { $0.draftValue != $0.originalValue }.count ?? 0
        let source = sourceDrafts[fileID]?.hasUnsavedChanges == true ? 1 : 0
        let order = hasStagedLoaderChange(fileID: fileID) ? 1 : 0
        return structured + source + order
    }

    func reload() {
        reload(preservingDraftsExcept: [])
    }

    func updateConfigRoot(_ text: String) {
        let expanded = NSString(string: text).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if let match = configs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            selectConfig(match.id)
        } else {
            addConfig(name: url.lastPathComponent.isEmpty ? "Config" : url.lastPathComponent, path: url.path, selectAfterAdd: true)
        }
    }

    func selectConfig(_ id: ConfigWorkspace.ID) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        selectedConfigID = id
        configRoot = config.url
        newConfigPath = config.path
        UserDefaults.standard.set(id, forKey: "selectedConfigID")
        UserDefaults.standard.set(config.path, forKey: "configRoot")
        selectedFileID = nil
        reload()
    }

    func addConfig(name: String, path: String, selectAfterAdd: Bool) {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard !expanded.isEmpty else {
            statusMessage = "Choose a config folder first."
            return
        }
        if let existing = configs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            if selectAfterAdd { selectConfig(existing.id) }
            return
        }
        let config = ConfigWorkspace.make(name: name, url: url)
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
        guard let fileIndex = files.firstIndex(where: { $0.values.contains(where: { $0.id == valueID }) }) else { return }
        guard sourceDrafts[files[fileIndex].id]?.hasUnsavedChanges != true else {
            statusMessage = "Save or revert the source draft before changing this file with controls."
            return
        }
        var file = files[fileIndex]
        var values = file.values
        guard let valueIndex = values.firstIndex(where: { $0.id == valueID }) else { return }
        values[valueIndex].draftValue = draftValue
        file = ConfigFile(url: file.url, rootURL: file.rootURL, kind: file.kind, values: values, activationReference: file.activationReference)
        files[fileIndex] = file
    }

    @discardableResult
    func saveSelectedFile() -> Bool {
        guard let selectedFile else { return false }
        let sourceChanged = sourceDrafts[selectedFile.id]?.hasUnsavedChanges == true
        let structuredChanged = selectedFile.hasUnsavedChanges
        let stagedKey = loaderKey(for: selectedFile).flatMap { stagedLoaderOrders[$0] == nil ? nil : $0 }
        guard !(sourceChanged && structuredChanged) else {
            statusMessage = SourceDraftError.competingStructuredDraft.localizedDescription
            return false
        }
        guard sourceChanged || structuredChanged || stagedKey != nil else {
            statusMessage = "No unsaved changes in \(selectedFile.displayName)."
            return true
        }

        var fileContentsSaved = false
        do {
            if sourceChanged {
                try writeSourceDraft(for: selectedFile)
                fileContentsSaved = true
            } else if structuredChanged {
                try saveValues(selectedFile.values, to: selectedFile.url, rootURL: selectedFile.rootURL, kind: selectedFile.kind)
                fileContentsSaved = true
            }
            if let stagedKey { try applyStagedLoaderOrder(forKey: stagedKey) }
            reload(preservingDraftsExcept: [selectedFile.id])
            statusMessage = "Saved \(selectedFile.displayName) and backed up the original under backups/."
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
        let changedIDs = Set(files.compactMap { hasUnsavedChanges(fileID: $0.id) ? $0.id : nil })
        guard !changedIDs.isEmpty else {
            statusMessage = "No unsaved changes."
            return true
        }
        var savedFileIDs: Set<ConfigFile.ID> = []
        guard !files.contains(where: { $0.hasUnsavedChanges && sourceDrafts[$0.id]?.hasUnsavedChanges == true }) else {
            statusMessage = SourceDraftError.competingStructuredDraft.localizedDescription
            return false
        }
        do {
            for file in files where changedIDs.contains(file.id) {
                if sourceDrafts[file.id]?.hasUnsavedChanges == true {
                    try writeSourceDraft(for: file)
                    savedFileIDs.insert(file.id)
                } else if file.hasUnsavedChanges {
                    try saveValues(file.values, to: file.url, rootURL: file.rootURL, kind: file.kind)
                    savedFileIDs.insert(file.id)
                }
            }
            for key in stagedLoaderOrders.keys.sorted() { try applyStagedLoaderOrder(forKey: key) }
            reload(preservingDraftsExcept: savedFileIDs)
            statusMessage = "Saved \(changedIDs.count) changed \(changedIDs.count == 1 ? "file" : "files")."
            return true
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
        sourceDrafts.removeValue(forKey: fileID)
        discardStagedLoaderChange(fileID: fileID)
        reload(preservingDraftsExcept: [fileID])
        selectedFileID = fileID
        statusMessage = "Discarded unsaved edits for \(selectedFile.displayName)."
    }

    func prepareSourceEditing(for file: ConfigFile) {
        guard !file.hasUnsavedChanges else {
            statusMessage = "Save or discard control edits in \(file.displayName) before editing its source."
            return
        }
        if let draft = sourceDrafts[file.id], draft.hasUnsavedChanges { return }
        loadSourceDraft(for: file, reportFailure: true)
    }

    func canEditSource(for file: ConfigFile) -> Bool {
        !file.hasUnsavedChanges
    }

    func sourceContents(for file: ConfigFile) -> String { sourceDrafts[file.id]?.contents ?? "" }
    func sourceLoadError(for file: ConfigFile) -> String? { sourceDrafts[file.id]?.loadError }
    func sourceHasUnsavedChanges(for file: ConfigFile) -> Bool { sourceDrafts[file.id]?.hasUnsavedChanges == true }

    func updateSourceContents(_ contents: String, for file: ConfigFile) {
        guard !file.hasUnsavedChanges else {
            statusMessage = "Save or discard control edits before changing this file's source."
            return
        }
        if sourceDrafts[file.id] == nil { loadSourceDraft(for: file, reportFailure: false) }
        guard var draft = sourceDrafts[file.id] else { return }
        draft.contents = contents
        sourceDrafts[file.id] = draft
    }

    func discardSourceChanges(for file: ConfigFile) {
        loadSourceDraft(for: file, reportFailure: true)
        if sourceDrafts[file.id]?.loadError == nil { statusMessage = "Reverted source edits for \(file.displayName)." }
    }

    @discardableResult
    func saveRawContents(for file: ConfigFile) -> Bool {
        guard sourceDrafts[file.id]?.hasUnsavedChanges == true else {
            statusMessage = "No unsaved source changes in \(file.displayName)."
            return true
        }
        do {
            try writeSourceDraft(for: file)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sketchybar", "--reload"]
        do {
            try process.run()
            process.waitUntilExit()
            statusMessage = process.terminationStatus == 0 ? "SketchyBar reloaded." : "sketchybar --reload exited with code \(process.terminationStatus)."
        } catch {
            statusMessage = "Could not run sketchybar --reload: \(error.localizedDescription)"
        }
    }

    func moveItem(fileID: ConfigFile.ID, direction: MoveDirection) {
        guard let file = files.first(where: { $0.id == fileID }), let key = loaderKey(for: file) else { return }
        var order = stagedLoaderOrders[key] ?? baseLoaderOrder(forKey: key)
        guard let index = order.firstIndex(of: fileID) else { return }
        let targetIndex = direction == .up ? index - 1 : index + 1
        guard order.indices.contains(targetIndex) else { return }
        order.swapAt(index, targetIndex)
        setStagedLoaderOrder(order, forKey: key)
        statusMessage = "Staged \(file.displayName) \(direction == .up ? "earlier" : "later"). Save to update the loader."
    }

    func moveItem(fileID: ConfigFile.ID, before targetFileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }),
              let targetFile = files.first(where: { $0.id == targetFileID }),
              file.id != targetFile.id,
              let key = loaderKey(for: file), key == loaderKey(for: targetFile) else { return }
        var order = stagedLoaderOrders[key] ?? baseLoaderOrder(forKey: key)
        guard let sourceIndex = order.firstIndex(of: fileID), let targetIndex = order.firstIndex(of: targetFileID) else { return }
        order.remove(at: sourceIndex)
        order.insert(fileID, at: sourceIndex < targetIndex ? targetIndex - 1 : targetIndex)
        setStagedLoaderOrder(order, forKey: key)
        statusMessage = "Staged \(file.displayName) before \(targetFile.displayName). Save to update the loader."
    }

    func setActive(_ isActive: Bool, fileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }), canMutateLoader(for: file) else { return }
        do {
            try activationService.setActive(isActive, for: file)
            statusMessage = isActive ? "Activated \(file.displayName)." : "Deactivated \(file.displayName)."
            reload()
        } catch {
            statusMessage = "Activation update failed: \(error.localizedDescription)"
        }
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
            statusMessage = "Restored \(profile.name). A timestamped backup of the previous config was kept next to the config folder."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func reload(preservingDraftsExcept discardedFileIDs: Set<ConfigFile.ID>) {
        let oldFilesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let configURLs = locator.configFiles(in: configRoot)
        let activationReferences = activationService.references(for: configURLs, rootURL: configRoot)
        let scannedFiles = configURLs.compactMap { url -> ConfigFile? in
            guard let kind = locator.kind(for: url) else { return nil }
            let scanned = ConfigFile(url: url, rootURL: configRoot, kind: kind, values: scanValues(url: url, kind: kind), activationReference: activationReferences[url.path])
            guard !discardedFileIDs.contains(scanned.id), let previous = oldFilesByID[scanned.id] else { return scanned }
            return mergingDrafts(from: previous, into: scanned)
        }
        files = scannedFiles
        refreshCleanSourceDrafts(availableFiles: scannedFiles)
        pruneStagedLoaderOrders()
        profiles = profileService.listProfiles(for: selectedConfigProfileID)
        if selectedFileID == nil || !files.contains(where: { $0.id == selectedFileID }) { selectedFileID = files.first?.id }
        statusMessage = files.isEmpty
            ? "No supported Lua or shell config files found in \(configRoot.path)."
            : "Loaded \(files.count) config files from \(selectedConfig?.name ?? configRoot.lastPathComponent)."
    }

    private func mergingDrafts(from previous: ConfigFile, into scanned: ConfigFile) -> ConfigFile {
        let changedDrafts = Dictionary(uniqueKeysWithValues: previous.values.filter { $0.draftValue != $0.originalValue }.map { ($0.id, $0.draftValue) })
        let values = scanned.values.map { scannedValue -> LuaEditableValue in
            guard let draft = changedDrafts[scannedValue.id] else { return scannedValue }
            var merged = scannedValue
            merged.draftValue = draft
            return merged
        }
        return ConfigFile(url: scanned.url, rootURL: scanned.rootURL, kind: scanned.kind, values: values, activationReference: scanned.activationReference)
    }

    private func loadSourceDraft(for file: ConfigFile, reportFailure: Bool) {
        do {
            let contents = try String(contentsOf: file.url, encoding: .utf8)
            sourceDrafts[file.id] = SourceDraft(savedContents: contents, contents: contents, loadError: nil)
        } catch {
            sourceDrafts[file.id] = SourceDraft(savedContents: "", contents: "", loadError: error.localizedDescription)
            if reportFailure { statusMessage = "Could not load source for \(file.displayName): \(error.localizedDescription)" }
        }
    }

    private func refreshCleanSourceDrafts(availableFiles: [ConfigFile]) {
        let availableByID = Dictionary(uniqueKeysWithValues: availableFiles.map { ($0.id, $0) })
        let cleanFileIDs = sourceDrafts.compactMap { fileID, draft in draft.hasUnsavedChanges ? nil : fileID }
        for fileID in cleanFileIDs {
            guard let file = availableByID[fileID] else {
                sourceDrafts.removeValue(forKey: fileID)
                continue
            }
            loadSourceDraft(for: file, reportFailure: false)
        }
    }

    private func writeSourceDraft(for file: ConfigFile) throws {
        guard var draft = sourceDrafts[file.id], draft.hasUnsavedChanges else { return }
        let currentContents = try String(contentsOf: file.url, encoding: .utf8)
        guard currentContents == draft.savedContents else { throw SourceDraftError.changedOnDisk }
        _ = try backupService.backup(fileURL: file.url, rootURL: file.rootURL)
        try draft.contents.write(to: file.url, atomically: true, encoding: .utf8)
        draft.savedContents = draft.contents
        draft.loadError = nil
        sourceDrafts[file.id] = draft
    }

    private func hasUnsavedChanges(in rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        if files.contains(where: { $0.url.standardizedFileURL.path.hasPrefix(rootPath) && hasUnsavedChanges(fileID: $0.id) }) { return true }
        return sourceDrafts.contains { fileID, draft in
            URL(fileURLWithPath: fileID).standardizedFileURL.path.hasPrefix(rootPath) && draft.hasUnsavedChanges
        }
    }

    private func loaderKey(for file: ConfigFile) -> String? { file.activationReference?.entrypointURL.standardizedFileURL.path }

    private func baseLoaderOrder(forKey key: String) -> [ConfigFile.ID] {
        files.filter { loaderKey(for: $0) == key }
            .sorted {
                let lhs = $0.activationReference?.lineNumber ?? .max
                let rhs = $1.activationReference?.lineNumber ?? .max
                return lhs == rhs ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending : lhs < rhs
            }
            .map(\.id)
    }

    private func setStagedLoaderOrder(_ order: [ConfigFile.ID], forKey key: String) {
        if order == baseLoaderOrder(forKey: key) { stagedLoaderOrders.removeValue(forKey: key) }
        else { stagedLoaderOrders[key] = order }
    }

    private func hasStagedLoaderChange(fileID: ConfigFile.ID) -> Bool {
        guard let file = files.first(where: { $0.id == fileID }), let key = loaderKey(for: file), let staged = stagedLoaderOrders[key] else { return false }
        let base = baseLoaderOrder(forKey: key)
        return staged.firstIndex(of: fileID) != base.firstIndex(of: fileID)
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
        for key in Array(stagedLoaderOrders.keys) {
            guard let staged = stagedLoaderOrders[key] else { continue }
            let base = baseLoaderOrder(forKey: key)
            let available = Set(base)
            var next = staged.filter { available.contains($0) }
            next.append(contentsOf: base.filter { !next.contains($0) })
            setStagedLoaderOrder(next, forKey: key)
        }
    }

    private func applyStagedLoaderOrder(forKey key: String) throws {
        if sourceDrafts[key]?.hasUnsavedChanges == true {
            throw SourceDraftError.loaderHasSourceDraft(URL(fileURLWithPath: key).lastPathComponent)
        }
        guard let desired = stagedLoaderOrders[key], desired.count > 1 else {
            stagedLoaderOrders.removeValue(forKey: key)
            return
        }
        let orderedFiles = desired.compactMap { id in files.first(where: { $0.id == id }) }
        try activationService.moveReferences(in: orderedFiles, to: desired)
        stagedLoaderOrders.removeValue(forKey: key)
    }

    private func canMutateLoader(for file: ConfigFile) -> Bool {
        guard let entrypointID = file.activationReference?.entrypointURL.path else { return true }
        guard sourceDrafts[entrypointID]?.hasUnsavedChanges != true else {
            statusMessage = "Save or discard the source draft for \(URL(fileURLWithPath: entrypointID).lastPathComponent) before changing loader activation."
            return false
        }
        return true
    }

    private func scanValues(url: URL, kind: ConfigFileKind) -> [LuaEditableValue] {
        switch kind {
        case .lua: return luaScanner.scan(fileURL: url)
        case .shell, .sketchybarRC: return shellScanner.scan(fileURL: url)
        }
    }

    private func saveValues(_ values: [LuaEditableValue], to url: URL, rootURL: URL, kind: ConfigFileKind) throws {
        switch kind {
        case .lua: try luaScanner.save(values: values, to: url, rootURL: rootURL)
        case .shell, .sketchybarRC: try shellScanner.save(values: values, to: url, rootURL: rootURL)
        }
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
