import AppKit
import Foundation

final class SketchyBarStore: ObservableObject {
    @Published var configRoot: URL
    @Published var files: [ConfigFile] = []
    @Published var selectedFileID: ConfigFile.ID?
    @Published var profiles: [ConfigProfile] = []
    @Published var profileName: String = ""
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
    private let profileService = ProfileArchiveService()

    init() {
        configRoot = Self.savedConfigRoot(defaultURL: locator.defaultConfigRoot)
        reload()
    }

    var selectedFile: ConfigFile? {
        guard let selectedFileID else { return files.first }
        return files.first { $0.id == selectedFileID } ?? files.first
    }

    var unsavedFileCount: Int {
        files.filter(\.hasUnsavedChanges).count
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
        profiles = profileService.listProfiles()

        if selectedFileID == nil || !files.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = files.first?.id
        }

        if files.isEmpty {
            statusMessage = "No editable Lua or shell assignments found in \(configRoot.path)."
        } else {
            statusMessage = "Loaded \(files.count) config files."
        }
    }

    func updateConfigRoot(_ text: String) {
        let expanded = NSString(string: text).expandingTildeInPath
        configRoot = URL(fileURLWithPath: expanded)
        UserDefaults.standard.set(configRoot.path, forKey: "configRoot")
        reload()
    }

    func update(valueID: LuaEditableValue.ID, draftValue: String) {
        guard let fileIndex = files.firstIndex(where: { file in
            file.values.contains(where: { $0.id == valueID })
        }) else {
            return
        }

        var file = files[fileIndex]
        var values = file.values
        guard let valueIndex = values.firstIndex(where: { $0.id == valueID }) else {
            return
        }

        values[valueIndex].draftValue = draftValue
        file = ConfigFile(
            url: file.url,
            rootURL: file.rootURL,
            kind: file.kind,
            values: values,
            activationReference: file.activationReference
        )
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

    func setActive(_ isActive: Bool, fileID: ConfigFile.ID) {
        guard let file = files.first(where: { $0.id == fileID }) else {
            return
        }

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
            try profileService.saveProfile(named: profileName, from: configRoot)
            profileName = ""
            profiles = profileService.listProfiles()
            statusMessage = "Saved profile."
        } catch {
            statusMessage = "Profile save failed: \(error.localizedDescription)"
        }
    }

    func restore(profile: ConfigProfile) {
        do {
            try profileService.restore(profile: profile, to: configRoot)
            reload()
            statusMessage = "Restored \(profile.name). A timestamped backup of the previous config was kept next to the config folder."
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

    private static func savedTheme() -> AppTheme {
        guard let rawValue = UserDefaults.standard.string(forKey: "appTheme"),
              let theme = AppTheme(rawValue: rawValue) else {
            return .nord
        }
        return theme
    }

    private static func savedConfigRoot(defaultURL: URL) -> URL {
        guard let path = UserDefaults.standard.string(forKey: "configRoot"), !path.isEmpty else {
            return defaultURL
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
}
