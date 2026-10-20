import AppKit
import SwiftUI

/// The sheet that creates a new config from a template.
///
/// The sheet shows the files that will be written and the text of the file
/// that is picked, so the user sees the result before anything is written.
struct NewConfigView: View {
    @ObservedObject var store: SketchyBarStore
    @Environment(\.dismiss) private var dismiss

    private let scaffolder = ConfigScaffolder()

    @State private var name = ""
    @State private var folder = ""
    @State private var style: ConfigScaffolder.Style = .sbarLua
    @State private var starterItemIDs: Set<String> = Set(ConfigScaffolder.defaultStarterItemIDs)
    @State private var selectedFile: String?
    @State private var showsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                targetSection
                itemsSection
                previewSection
            }
            .formStyle(.grouped)
            .alert("The folder is not empty", isPresented: $showsConfirmation) {
                Button("Create", role: .destructive) { create(overwrite: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(targetFolder?.path ?? "The folder") already holds files. The files with the same name are replaced, and the old ones are kept in the backups folder.")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityLabel("Cancel the new config")
                Button("Create Config") { create(overwrite: false) }
                    .disabled(!isValid)
                    .accessibilityLabel("Create the config")
            }
            .padding()
        }
        .frame(width: 660, height: 700)
        .onAppear {
            if folder.isEmpty {
                folder = store.configRoot.deletingLastPathComponent().path
            }
            if selectedFile == nil {
                selectedFile = files.keys.sorted().first
            }
        }
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section("Config") {
            TextField("Name", text: $name)
                .accessibilityLabel("Name of the new config")
            if let nameError {
                warning(nameError)
            }

            LabeledContent("Folder") {
                HStack {
                    TextField("Folder of the new config", text: $folder)
                        .accessibilityLabel("Folder the new config is created in")
                    Button("Choose…") { chooseFolder() }
                        .accessibilityLabel("Choose the folder of the new config")
                }
            }

            Picker("Style", selection: $style) {
                ForEach(ConfigScaffolder.Style.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Style of the new config")

            if let targetFolder {
                Text("The config is created in \(targetFolder.path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let folderWarning {
                warning(folderWarning)
            }
        }
    }

    private var itemsSection: some View {
        Section("Items") {
            ForEach(scaffolder.starterItems(for: style)) { item in
                Toggle(item.name, isOn: Binding(
                    get: { starterItemIDs.contains(item.id) },
                    set: { isOn in
                        if isOn { starterItemIDs.insert(item.id) } else { starterItemIDs.remove(item.id) }
                    }
                ))
                .accessibilityLabel("Add the \(item.name) item")
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            List(files.keys.sorted(), id: \.self, selection: $selectedFile) { path in
                Text(path)
                    .font(.system(.body, design: .monospaced))
            }
            .frame(height: 120)
            .accessibilityLabel("Files of the new config")

            ScrollView {
                Text(files[previewPath] ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .accessibilityLabel("Contents of \(previewPath)")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // MARK: - Values

    /// The files the config will hold, with the path of every file relative
    /// to the root of the config.
    private var files: [String: String] {
        scaffolder.fileContents(style: style, starterItems: selectedStarterItems)
    }

    /// The items the user picked.
    private var selectedStarterItems: [ConfigScaffolder.StarterItem] {
        scaffolder.starterItems(for: style).filter { starterItemIDs.contains($0.id) }
    }

    /// The file the preview shows. It is the picked file, or the first file
    /// of the tree when the picked file is gone.
    private var previewPath: String {
        if let selectedFile, files[selectedFile] != nil { return selectedFile }
        return files.keys.sorted().first ?? ""
    }

    /// The folder the config is created in.
    private var targetFolder: URL? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: folder)
            .standardizedFileURL
            .appendingPathComponent(trimmedName)
    }

    private var nameError: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Give the config a name." }
        if trimmedName.contains("/") || trimmedName == "." || trimmedName == ".." {
            return "The name may not hold a slash."
        }
        return nil
    }

    /// The reason the folder cannot be used, or nil when it can.
    private var folderWarning: String? {
        guard let targetFolder else { return nil }
        if folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose the folder the config is created in."
        }
        if folderHoldsConfig(targetFolder) {
            return "The folder already holds a SketchyBar config. Choose another name or folder."
        }
        if !folderIsEmpty(targetFolder) {
            return "The folder is not empty. The files with the same name are replaced, and the old ones are kept in the backups folder."
        }
        return nil
    }

    /// True when the folder holds a SketchyBar config already.
    private func folderHoldsConfig(_ url: URL) -> Bool {
        !SketchyBarConfigLocator().configFiles(in: url).isEmpty
    }

    /// True when the folder holds no file.
    private func folderIsEmpty(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        return (contents ?? []).isEmpty
    }

    /// True when the config can be created.
    ///
    /// A folder that holds a config is never written into. A folder that is
    /// not empty is only written into after a confirmation.
    private var isValid: Bool {
        nameError == nil
            && !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(targetFolder.map { folderHoldsConfig($0) } ?? false)
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !folder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folder)
        }
        panel.prompt = "Choose"
        panel.message = "Choose the folder the new config is created in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.standardizedFileURL.path
    }

    private func create(overwrite: Bool) {
        guard let targetFolder else { return }
        if !overwrite, !folderIsEmpty(targetFolder) {
            showsConfirmation = true
            return
        }
        guard store.createConfig(
            name: name,
            in: targetFolder.deletingLastPathComponent(),
            style: style,
            starterItems: selectedStarterItems,
            overwrite: overwrite
        ) != nil else { return }
        dismiss()
    }
}
