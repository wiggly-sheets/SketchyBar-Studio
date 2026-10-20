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
