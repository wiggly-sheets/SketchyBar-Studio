import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SketchyBarStore
    @State private var configRootText = ""
    @State private var confirmLiveSwitch = false

    var body: some View {
        TabView {
            GeneralSettingsTab(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }

            ConfigLibrarySettingsTab(
                store: store,
                configRootText: $configRootText,
                confirmLiveSwitch: $confirmLiveSwitch
            )
            .tabItem { Label("Configs", systemImage: "folder.badge.gearshape") }

            CurrentConfigSettingsTab(store: store, configRootText: $configRootText)
                .tabItem { Label("Current", systemImage: "checkmark.circle") }
        }
        .padding()
        .frame(width: 760, height: 560)
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
        .onAppear {
            configRootText = store.configRoot.path
            store.newConfigPath = store.configRoot.path
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
                    }
                }
            }

            Section("Add Config") {
                TextField("Name", text: $store.newConfigName)

                LabeledContent("Folder") {
                    HStack {
                        TextField("SketchyBar config folder", text: $store.newConfigPath)
                        Button {
                            chooseConfigFolder()
                        } label: {
                            Label("Choose", systemImage: "folder")
                        }
                    }
                }

                Button("Add & Use") {
                    store.addConfig(name: store.newConfigName, path: store.newConfigPath, selectAfterAdd: true)
                    configRootText = store.configRoot.path
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top)
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

    private func chooseConfigFolder() {
        chooseFolder(startingAt: URL(fileURLWithPath: NSString(string: store.newConfigPath).expandingTildeInPath)) { url in
            store.newConfigPath = url.path
            if store.newConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.newConfigName = url.lastPathComponent
            }
        }
    }
}

private struct CurrentConfigSettingsTab: View {
    @ObservedObject var store: SketchyBarStore
    @Binding var configRootText: String

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Path") {
                    HStack {
                        TextField("SketchyBar config folder", text: $configRootText)
                            .onSubmit { store.updateConfigRoot(configRootText) }

                        Button {
                            chooseCurrentConfigFolder()
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

    private func chooseCurrentConfigFolder() {
        chooseFolder(startingAt: store.configRoot) { url in
            configRootText = url.path
            store.updateConfigRoot(url.path)
        }
    }
}

private func chooseFolder(startingAt url: URL, handler: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.title = "Choose SketchyBar Config Folder"
    panel.prompt = "Choose"
    panel.message = "Select a SketchyBar config folder."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = url

    if panel.runModal() == .OK, let url = panel.url {
        handler(url)
    }
}
