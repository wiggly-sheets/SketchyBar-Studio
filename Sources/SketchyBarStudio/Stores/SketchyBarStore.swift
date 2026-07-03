import AppKit
import Foundation

final class SketchyBarStore: ObservableObject {
    @Published var configRoot: URL
    @Published var configs: [ConfigWorkspace] = []
    @Published var selectedConfigID: ConfigWorkspace.ID?
    @Published var files: [ConfigFile] = []
    @Published var selectedFileID: ConfigFile.ID?
    @Published var profiles: [ConfigProfile] = []
    @Published var profileName: String = ""
    @Published var newConfigName: String = ""
    @Published var newConfigPath: String = ""
    @Published var statusMessage: String = ""
    @Published var searchText: String = ""
    @Published var showModifiedOnly = false
    @Published var appTheme: AppTheme = SketchyBarStore.savedTheme() {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
        }
    }

    private let locator = SketchyBarConfigLocator()
    private let luaScanner = LuaConfigScanner()
    private let shellScanner = ShellConfigScanner()
    private let activationService = ConfigActivationService()
    private let configLibraryService = ConfigLibraryService()
    private let configSwitchService = ConfigSwitchService()
    private let profileService = ProfileArchiveService()

    init() {
        let defaultRoot = locator.defaultConfigRoot
        let loadedConfigs = configLibraryService.load(defaultConfigRoot: defaultRoot)
        let savedConfigID = UserDefaults.standard.string(forKey: "selectedConfigID") ?? loadedConfigs.first?.id
        let selected = loadedConfigs.first { $0.id == savedConfigID } ?? loadedConfigs.first

        configRoot = selected?.url ?? defaultRoot
        configs = loadedConfigs
        selectedConfigID = savedConfigID
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
        files.filter(\.hasUnsavedChanges).count
    }

    var selectedConfigProfileID: String {
        selectedConfig?.id ?? "default"
    }

    var isSelectedConfigLive: Bool {
        guard let selectedConfig else { return false }
        return configSwitchService.isLive(config: selectedConfig)
    }

    func reload() {
        let scannedFiles = locator.configFiles(in: configRoot).compactMap { url -> ConfigFile? in
            guard let kind = locator.kind(for: url) else {
                return nil
            }

            return ConfigFile(
                url: url,
                rootURL: configRoot,
                kind: kind,
                values: scanValues(url: url, kind: kind),
                activationReference: activationService.reference(for: url, rootURL: configRoot)
            )
        }

        files = scannedFiles.filter { !$0.values.isEmpty }
        profiles = profileService.listProfiles(for: selectedConfigProfileID)

        if selectedFileID == nil || !files.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = files.first?.id
        }

        if files.isEmpty {
            statusMessage = "No editable Lua or shell assignments found in \(configRoot.path)."
        } else {
            statusMessage = "Loaded \(files.count) config files from \(selectedConfig?.name ?? configRoot.lastPathComponent)."
        }
    }

    func updateConfigRoot(_ text: String) {
        let expanded = NSString(string: text).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if let match = configs.first(where: { $0.url.path == url.path }) {
            selectConfig(match.id)
        } else {
            let name = url.lastPathComponent.isEmpty ? "Config" : url.lastPathComponent
            addConfig(name: name, path: url.path, selectAfterAdd: true)
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

        if let existing = configs.first(where: { $0.url.path == url.path }) {
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
        configs.removeAll { $0.id == id }
        saveConfigLibrary()
        if selectedConfigID == id {
            selectConfig(configs.first!.id)
        }
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
        guard let fileIndex = files.firstIndex(where: { file in
            file.values.contains(where: { $0.id == valueID })
        }) else { return }

        var file = files[fileIndex]
        var values = file.values
        guard let valueIndex = values.firstIndex(where: { $0.id == valueID }) else { return }

        values[valueIndex].draftValue = draftValue
        file = ConfigFile(url: file.url, rootURL: file.rootURL, kind: file.kind, values: values, activationReference: file.activationReference)
        files[fileIndex] = file
    }

    func saveSelectedFile() {
        guard let selectedFile else { return }
        save(file: selectedFile)
    }

    func saveAllChangedFiles() {
        let changedFiles = files.filter(\.hasUnsavedChanges)
        guard !changedFiles.isEmpty else {
            statusMessage = "No unsaved changes."
            return
        }

        for file in changedFiles {
            do {
                try saveValues(file.values, to: file.url, kind: file.kind)
            } catch {
                statusMessage = "Save failed for \(file.displayName): \(error.localizedDescription)"
                return
            }
        }

        statusMessage = "Saved \(changedFiles.count) changed files."
        reload()
    }

    func saveAllAndApply() {
        saveAllChangedFiles()
        applySketchyBarReload()
    }

    func discardSelectedChanges() {
        guard let selectedFile else { return }
        let fileID = selectedFile.id
        reload()
        selectedFileID = fileID
        statusMessage = "Discarded unsaved edits for \(selectedFile.displayName)."
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
        guard let file = files.first(where: { $0.id == fileID }) else { return }
        do {
            try activationService.moveReference(for: file, direction: direction)
            statusMessage = "Moved \(file.displayName) \(direction == .up ? "up" : "down")."
            reload()
        } catch {
            statusMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    func moveItem(fileID: ConfigFile.ID, before targetFileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }),
              let targetFile = files.first(where: { $0.id == targetFileID }),
              file.id != targetFile.id else { return }

        do {
            try activationService.moveReference(for: file, before: targetFile)
            statusMessage = "Moved \(file.displayName) before \(targetFile.displayName)."
            reload()
        } catch {
            statusMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    func setActive(_ isActive: Bool, fileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }) else { return }

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
        do {
            try profileService.restore(profile: profile, to: configRoot)
            reload()
            statusMessage = "Restored \(profile.name). A timestamped backup of previous config was kept next to config folder."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func scanValues(url: URL, kind: ConfigFileKind) -> [LuaEditableValue] {
        switch kind {
        case .lua:
            return luaScanner.scan(fileURL: url)
        case .shell, .sketchybarRC:
            return shellScanner.scan(fileURL: url)
        }
    }

    private func saveValues(_ values: [LuaEditableValue], to url: URL, kind: ConfigFileKind) throws {
        switch kind {
        case .lua:
            try luaScanner.save(values: values, to: url)
        case .shell, .sketchybarRC:
            try shellScanner.save(values: values, to: url)
        }
    }

    private func save(file: ConfigFile) {
        do {
            try saveValues(file.values, to: file.url, kind: file.kind)
            statusMessage = "Saved \(file.displayName) and wrote a .studio-backup copy."
            reload()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func saveConfigLibrary() {
        do {
            try configLibraryService.save(configs)
        } catch {
            statusMessage = "Config library save failed: \(error.localizedDescription)"
        }
    }

    private static func savedTheme() -> AppTheme {
        guard let rawValue = UserDefaults.standard.string(forKey: "appTheme"),
              let theme = AppTheme(rawValue: rawValue) else { return .nord }
        return theme
    }
}
