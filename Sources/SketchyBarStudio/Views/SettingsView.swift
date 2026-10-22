import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which folder the file importer picks.
enum FolderPicker: String, Identifiable {
    case newConfig
    case currentConfig

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var store: SketchyBarStore
    @State private var configRootText = ""
    @State private var confirmLiveSwitch = false
    @State private var folderPicker: FolderPicker?
    @State private var showsNewConfig = false

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            ConfigLibrarySettingsTab(
                store: store,
                configRootText: $configRootText,
                confirmLiveSwitch: $confirmLiveSwitch,
                onChooseFolder: { folderPicker = $0 },
                onNewConfig: { showsNewConfig = true }
            )
            .tabItem { Label("Configs", systemImage: "folder.badge.gearshape") }

            CurrentConfigSettingsTab(
                store: store,
                configRootText: $configRootText,
                onChooseFolder: { folderPicker = $0 }
            )
            .tabItem { Label("Current", systemImage: "checkmark.circle") }

            BarThemeSettingsTab(store: store)
                .tabItem { Label("Bar Theme", systemImage: "paintpalette") }
        }
        .padding()
        .frame(width: 760, height: 560)
        .sheet(isPresented: $showsNewConfig) {
            NewConfigView(store: store)
        }
        .confirmationDialog(
            "Make selected config live?",
            isPresented: $confirmLiveSwitch,
            titleVisibility: .visible
        ) {
            Button("Make Live", role: .destructive) {
                store.activateSelectedConfigAsLiveSymlink()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This backs up any real ~/.config/sketchybar folder, replaces ~/.config/sketchybar with a symlink to the selected config, then reloads SketchyBar.")
        }
        .fileImporter(
            isPresented: Binding(
                get: { folderPicker != nil },
                set: { if !$0 { folderPicker = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderPicker
        )
        .onAppear {
            // Only fill the fields when they are empty, so a path the user
            // typed is not lost when the settings are reopened.
            if configRootText.isEmpty {
                configRootText = store.configRoot.path
            }
            if store.newConfigPath.isEmpty {
                store.newConfigPath = store.configRoot.path
            }
        }
    }

    private func handleFolderPicker(_ result: Result<[URL], Error>) {
        let target = folderPicker
        folderPicker = nil
        guard case let .success(urls) = result, let url = urls.first else { return }

        switch target {
        case .newConfig:
            store.newConfigPath = url.path
            if store.newConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.newConfigName = url.lastPathComponent
            }
        case .currentConfig:
            configRootText = url.path
            store.updateConfigRoot(url.path)
        case nil:
            break
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: SketchyBarStore

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("App theme", selection: $store.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top)
    }
}

private struct ConfigLibrarySettingsTab: View {
    @ObservedObject var store: SketchyBarStore
    @Binding var configRootText: String
    @Binding var confirmLiveSwitch: Bool
    let onChooseFolder: (FolderPicker) -> Void
    let onNewConfig: () -> Void

    var body: some View {
        Form {
            Section("Editing") {
                Picker("Selected config", selection: selectedConfigBinding) {
                    ForEach(store.configs) { config in
                        Text(config.name).tag(Optional(config.id))
                    }
                }

                HStack {
                    Label(store.isSelectedConfigLive ? "Selected config is live" : "Selected config is not live", systemImage: store.isSelectedConfigLive ? "checkmark.circle.fill" : "circle")
                    Spacer()
                    Text("~/.config/sketchybar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(store.isSelectedConfigLive ? "Already Live" : "Make Selected Live") {
                    confirmLiveSwitch = true
                }
                .disabled(store.isSelectedConfigLive)
            }

            Section("Library") {
                ForEach(store.configs) { config in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(config.name)
                            Text(config.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Use") {
                            store.selectConfig(config.id)
                            configRootText = config.path
                        }

                        Button(role: .destructive) {
                            store.removeConfig(config.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .disabled(store.configs.count <= 1)
                        .accessibilityLabel("Remove config \(config.name)")
                    }
                }
            }

            Section("Add Config") {
                Button("New Config…") {
                    onNewConfig()
                }
                .accessibilityLabel("Create a new config from a template")

                TextField("Name", text: $store.newConfigName)

                LabeledContent("Folder") {
                    HStack {
                        TextField("SketchyBar config folder", text: $store.newConfigPath)
                        Button {
                            onChooseFolder(.newConfig)
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                    }
                }

                Button("Add & Use") {
                    store.addConfig(name: store.newConfigName, path: store.newConfigPath, selectAfterAdd: true)
                    configRootText = store.configRoot.path
                }
                .disabled(newConfigNameIsEmpty)

                if newConfigNameIsEmpty {
                    Label("Give the config a name before adding it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                statusLine
            }
        }
        .formStyle(.grouped)
        .padding(.top)
    }

    private var newConfigNameIsEmpty: Bool {
        store.newConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusLine: some View {
        Label(store.statusMessage, systemImage: store.statusKind.symbolName)
            .font(.caption)
            .foregroundStyle(store.statusKind.tint)
            .lineLimit(2)
            .accessibilityLabel(store.statusMessage)
    }

    private var selectedConfigBinding: Binding<ConfigWorkspace.ID?> {
        Binding(
            get: { store.selectedConfigID },
            set: { id in
                if let id {
                    store.selectConfig(id)
                    configRootText = store.configRoot.path
                }
            }
        )
    }
}

private struct CurrentConfigSettingsTab: View {
    @ObservedObject var store: SketchyBarStore
    @Binding var configRootText: String
    let onChooseFolder: (FolderPicker) -> Void

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Path") {
                    HStack {
                        TextField("SketchyBar config folder", text: $configRootText)
                            .onSubmit { store.updateConfigRoot(configRootText) }

                        Button {
                            onChooseFolder(.currentConfig)
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                    }
                }

                HStack {
                    Button("Use This Folder") {
                        store.updateConfigRoot(configRootText)
                    }

                    Button("Reveal Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.configRoot])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top)
    }
}

private struct BarThemeSettingsTab: View {
    @ObservedObject var store: SketchyBarStore
    @State private var pattern: BarThemePattern = .noThemesFolder
    @State private var activeThemeName: String?
    @State private var selectedPaletteID: String? = BarPalette.all.first?.id
    @State private var status: Status?
    @State private var canRestore = false

    private struct Status {
        let message: String
        let isError: Bool
    }

    var body: some View {
        Form {
            Section("Detected Theme") {
                LabeledContent("Pattern") {
                    Text(patternDescription)
                }
                LabeledContent("Active theme") {
                    Text(activeThemeName ?? "None")
                }
            }

            Section("Palettes") {
                ForEach(BarPalette.all) { palette in
                    Button {
                        selectedPaletteID = palette.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: palette.id == selectedPaletteID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(palette.id == selectedPaletteID ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(palette.displayName)
                                Text(palette.isDark ? "\(palette.family) · Dark" : "\(palette.family) · Light")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 3) {
                                ForEach(Array(palette.swatches.enumerated()), id: \.offset) { _, hex in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hexLike: hex))
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(.quaternary, lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(palette.displayName)")
                    .help("\(palette.family) · \(palette.licence) · \(palette.sourceURL)")
                }
            }

            Section {
                Button("Apply \(selectedPalette?.displayName ?? "Palette")") {
                    apply()
                }
                .disabled(selectedPalette == nil || !hasPointerPattern)

                Button("Restore previous theme") {
                    restore()
                }
                .disabled(!canRestore)

                if let status {
                    Label(status.message, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.orange : Color.secondary)
                        .lineLimit(3)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top)
        .onAppear(perform: refresh)
        .onChange(of: store.configRoot) { _, _ in
            status = nil
            refresh()
        }
    }

    private var service: BarThemeService {
        BarThemeService(configRoot: store.configRoot)
    }

    private var selectedPalette: BarPalette? {
        BarPalette.all.first { $0.id == selectedPaletteID }
    }

    private var hasPointerPattern: Bool {
        if case .themedPointer = pattern { return true }
        return false
    }

    private var patternDescription: String {
        switch pattern {
        case .themedPointer(let name):
            return "Pointer file names \(name)"
        case .themedPointerMissing:
            return "No pointer file in themes/"
        case .noThemesFolder:
            return "No themes/ folder"
        }
    }

    private func refresh() {
        pattern = service.detect()
        activeThemeName = service.activeTheme()?.name
        canRestore = service.previousThemeName() != nil

        if selectedPaletteID == nil || selectedPalette == nil {
            selectedPaletteID = BarPalette.all.first?.id
        }
        if let activeThemeName,
           let matching = BarPalette.all.first(where: { $0.displayName == activeThemeName }) {
            selectedPaletteID = matching.id
        }
    }

    private func apply() {
        guard let palette = selectedPalette else { return }
        do {
            let result = try service.apply(palette)
            if result.wroteThemeFile || result.wrotePointer {
                status = Status(message: "Applied \(palette.displayName). Reload SketchyBar to see it.", isError: false)
            } else {
                status = Status(message: "\(palette.displayName) is already active.", isError: false)
            }
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
        }
        refresh()
    }

    private func restore() {
        do {
            let name = try service.restorePreviousTheme()
            status = Status(message: "Restored \(name). Reload SketchyBar to see it.", isError: false)
        } catch {
            status = Status(message: error.localizedDescription, isError: true)
        }
        refresh()
    }
}
