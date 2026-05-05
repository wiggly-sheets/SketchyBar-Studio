import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SketchyBarStore
    @State private var configRootText = ""

    var body: some View {
        Form {
            Picker("App theme", selection: $store.appTheme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.rawValue).tag(theme)
                }
            }

            LabeledContent("Config folder") {
                HStack {
                    TextField("SketchyBar config folder", text: $configRootText)
                        .onSubmit {
                            store.updateConfigRoot(configRootText)
                        }

                    Button {
                        chooseConfigFolder()
                    } label: {
                        Label("Choose Folder...", systemImage: "folder")
                    }
                }
            }

            Button("Use This Folder") {
                store.updateConfigRoot(configRootText)
            }

            Button("Reveal Config Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.configRoot])
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .onAppear {
            configRootText = store.configRoot.path
        }
    }

    private func chooseConfigFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose SketchyBar Config Folder"
        panel.prompt = "Choose"
        panel.message = "Select the folder that contains your SketchyBar Lua config files."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.configRoot

        if panel.runModal() == .OK, let url = panel.url {
            configRootText = url.path
            store.updateConfigRoot(url.path)
        }
    }
}
