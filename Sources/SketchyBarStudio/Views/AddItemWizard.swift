import AppKit
import SwiftUI

/// The loader files of a config: the files that load other files.
///
/// The list comes from the load graph of the app, so it holds the files
/// SketchyBar really loads: the entrypoints of the config root and the
/// `init.lua` of the item folders.
enum LoaderCandidates {
    /// The loader files of the config root, the top level `init.lua` first.
    static func candidates(in rootURL: URL) -> [URL] {
        let root = rootURL.standardizedFileURL
        let report = ConfigGraphService().report(for: root)

        // A loader file is a file that loads other files. The graph knows
        // the files it reaches and the files whose target is gone, so both
        // tell a loader file apart from an item file.
        let loaders = report.edges.map(\.from) + report.missingTargets.map(\.from)

        var seen = Set<String>()
        var result: [URL] = []
        for url in loaders {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let isRootFile = url.deletingLastPathComponent().standardizedFileURL.path == root.path
            let isModuleLoader = url.lastPathComponent == "init.lua" || url.lastPathComponent == "init.sh"
            guard isRootFile || isModuleLoader else { continue }
            result.append(url)
        }

        return result.sorted { lhs, rhs in
            let lhsTop = lhs.deletingLastPathComponent().standardizedFileURL.path == root.path
            let rhsTop = rhs.deletingLastPathComponent().standardizedFileURL.path == root.path
            if lhsTop != rhsTop { return lhsTop }
            return lhs.path < rhs.path
        }
    }
}

/// The sheet that creates a new bar item.
///
/// The wizard shows the text of the file it is about to write, so the user
/// sees the result before anything is written.
struct AddItemWizard: View {
    @ObservedObject var store: SketchyBarStore
    @Environment(\.dismiss) private var dismiss

    private let scaffolder = ItemScaffolder()

    @State private var style: ItemScaffolder.Style = .sbarLua
    @State private var templateID = "clock"
    @State private var alias = "clock"
    @State private var position = "right"
    @State private var icon = "sf.clock"
    @State private var label = ""
    @State private var updateFreq = 60
    @State private var folder = "items/right"
    @State private var loaders: [URL] = []
    @State private var loaderPath = ""
    @State private var pendingURL: URL?
    @State private var pendingContents = ""
    @State private var showsOverwriteConfirmation = false
    @State private var showsLoaderFailure = false
    @State private var loaderFailureMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                templateSection
                itemSection
                targetSection
                previewSection
            }
            .formStyle(.grouped)
            .alert("Replace the file?", isPresented: $showsOverwriteConfirmation) {
                Button("Replace", role: .destructive) {
                    guard let pendingURL else { return }
                    write(contents: pendingContents, at: pendingURL, overwrite: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(pendingURL?.lastPathComponent ?? "The file") already exists. The old file is kept in the backups folder before it is replaced.")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityLabel("Cancel the new item")
                Button("Create Item") { create() }
                    .disabled(!isValid)
                    .accessibilityLabel("Create the item")
            }
            .padding()
        }
        .frame(width: 640, height: 720)
        .onAppear {
            loaders = LoaderCandidates.candidates(in: store.configRoot)
            if loaderPath.isEmpty {
                loaderPath = defaultLoaderPath()
            }
        }
        .onChange(of: style) { _, _ in
            if let template = templates.first(where: { $0.id == templateID }) {
                select(template)
            }
            folder = defaultFolder
        }
        .onChange(of: position) { oldValue, _ in
            // The folder follows the position as long as the user did not
            // point it somewhere else.
            if folder.isEmpty || folder == "items/\(oldValue)" {
                folder = defaultFolder
            }
        }
        .alert("The loader line was not added", isPresented: $showsLoaderFailure) {
            Button("Keep the File") { dismiss() }
            Button("Remove the File", role: .destructive) { removeCreatedFile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The item file was created, but the loader file was not changed. \(loaderFailureMessage)")
        }
    }

    // MARK: - Sections

    private var templateSection: some View {
        Section("Template") {
            Picker("Style", selection: $style) {
                ForEach(ItemScaffolder.Style.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Style of the new file")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(templates) { template in
                    templateButton(template)
                }
            }
        }
    }

    private var itemSection: some View {
        Section("Item") {
            TextField("Item name", text: $alias)
                .accessibilityLabel("Item name")
            if let aliasError {
                warning(aliasError)
            }

            positionPicker

            HStack {
                TextField("Icon", text: $icon)
                    .disabled(!iconIsUsed)
                    .accessibilityLabel("Icon of the item")
                if let preview = iconPreview {
                    Image(nsImage: preview)
                        .frame(width: 22, height: 22)
                        .help("Preview of the icon")
                        .accessibilityLabel("Preview of the icon")
                }
            }
            if !iconIsUsed {
                Text("The template of this item has no icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let iconWarning {
                warning(iconWarning)
            }

            TextField("Label", text: $label)
                .disabled(labelIsSetByScript)
                .accessibilityLabel("Label of the item")
            if labelIsSetByScript {
                Text("The script of the item sets the label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Update frequency", value: $updateFreq, format: .number)
                .disabled(!updateFreqIsUsed)
                .accessibilityLabel("Update frequency in seconds")
            if updateFreqIsUsed {
                Text("The script runs every \(updateFreq) seconds. Zero means it only runs when SketchyBar asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var positionPicker: some View {
        Picker("Position", selection: $position) {
            ForEach(positionValues, id: \.self) { value in
                Text(value).tag(value)
            }
        }
        .accessibilityLabel("Position of the item")
    }

    private var targetSection: some View {
        Section("Target") {
            HStack {
                TextField("Folder", text: $folder)
                    .accessibilityLabel("Folder of the new file")
                Button("Choose…") { chooseFolder() }
                    .accessibilityLabel("Choose the folder of the new file")
            }
            if let folderError {
                warning(folderError)
            }

            if loaders.isEmpty {
                Text("No loader file with a require line was found. The item is created without a loader line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                loaderPicker
            }

            Text("New file: \(relativePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loaderPicker: some View {
        Picker("Loader file", selection: $loaderPath) {
            ForEach(loaders, id: \.path) { url in
                Text(relativeName(of: url)).tag(url.path)
            }
        }
        .accessibilityLabel("Loader file that gets the require line")
    }

    private var previewSection: some View {
        Section("Preview") {
            ScrollView {
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
            .accessibilityLabel("Preview of the new file")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func templateButton(_ template: ItemScaffolder.Template) -> some View {
        let isSelected = template.id == templateID
        return Button {
            select(template)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.headline)
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.name) template")
        .accessibilityHint(template.summary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Values

    private var templates: [ItemScaffolder.Template] {
        scaffolder.templates(for: style)
    }

    private var template: ItemScaffolder.Template? {
        templates.first { $0.id == templateID }
    }

    private var positionValues: [String] {
        SketchyBarOptionDocs.doc(for: "position")?.values ?? []
    }

    private var labelIsSetByScript: Bool {
        guard let template else { return false }
        return template.kind == .script || template.kind == .appIcon
    }

    /// True when the template of the item writes an icon.
    private var iconIsUsed: Bool {
        guard let template else { return false }
        return template.kind == .text || template.kind == .appIcon
    }

    private var updateFreqIsUsed: Bool {
        labelIsSetByScript
    }

    private var aliasError: String? {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Give the item a name." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return "The name may only hold letters, digits, dashes and underscores."
        }
        return nil
    }

    private var folderError: String? {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Choose the folder of the new file." }
        if trimmed.hasPrefix("/") || trimmed.split(separator: "/").contains("..") {
            return "The folder must be inside the config folder."
        }
        return nil
    }

    private var iconPreview: NSImage? {
        guard icon.hasPrefix("sf.") else { return nil }
        let name = String(icon.dropFirst(3))
        guard !name.isEmpty else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private var iconWarning: String? {
        guard icon.hasPrefix("sf.") else { return nil }
        let name = String(icon.dropFirst(3))
        guard !name.isEmpty else { return nil }
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil else { return nil }
        return "SketchyBar does not know the SF Symbol \"\(name)\"."
    }

    private var defaultFolder: String {
        style == .sbarLua ? "items/\(position)" : "items"
    }

    private var relativePath: String {
        let folderPart = folder.trimmingCharacters(in: .whitespaces)
        let name = alias.trimmingCharacters(in: .whitespaces)
        let fileName = "\(name).\(style.fileExtension)"
        return folderPart.isEmpty ? fileName : "\(folderPart)/\(fileName)"
    }

    private var previewText: String {
        guard let template else { return "" }
        return scaffolder.fileContents(
            template: template,
            alias: alias.trimmingCharacters(in: .whitespaces),
            position: position,
            icon: icon,
            label: label,
            updateFreq: updateFreq
        )
    }

    private var isValid: Bool {
        aliasError == nil && folderError == nil && positionValues.contains(position) && !previewText.isEmpty
    }

    private var selectedLoader: URL? {
        loaders.first { $0.path == loaderPath }
    }

    // MARK: - Actions

    private func select(_ template: ItemScaffolder.Template) {
        templateID = template.id
        alias = template.id
        icon = scaffolder.defaultIcon(for: template)
        updateFreq = scaffolder.defaultUpdateFreq(for: template)
        label = template.kind == .text ? template.name : ""
    }

    private func defaultLoaderPath() -> String {
        let root = store.configRoot.standardizedFileURL
        if let top = loaders.first(where: {
            $0.lastPathComponent == "init.lua" &&
            $0.deletingLastPathComponent().standardizedFileURL.path == root.path
        }) {
            return top.path
        }
        return loaders.first?.path ?? ""
    }

    private func relativeName(of url: URL) -> String {
        let root = store.configRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.configRoot
        panel.prompt = "Choose"
        panel.message = "Choose the folder the new item file goes into."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let root = store.configRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else {
            folder = ""
            return
        }
        folder = String(path.dropFirst(prefix.count))
    }

    private func create() {
        let url = store.configRoot.appendingPathComponent(relativePath)
        pendingURL = url
        pendingContents = previewText
        if FileManager.default.fileExists(atPath: url.path) {
            showsOverwriteConfirmation = true
            return
        }
        write(contents: pendingContents, at: url, overwrite: false)
    }

    private func write(contents: String, at url: URL, overwrite: Bool) {
        guard store.createItemFile(contents: contents, at: url, overwrite: overwrite) else { return }
        guard let loader = selectedLoader else {
            dismiss()
            return
        }

        let line = scaffolder.loaderLine(
            for: alias.trimmingCharacters(in: .whitespaces),
            relativePath: relativePath,
            style: style
        )
        if !store.insertLoaderLine(line, into: loader, forItemFile: url) {
            loaderFailureMessage = store.statusMessage
            showsLoaderFailure = true
            return
        }
        dismiss()
    }

    private func removeCreatedFile() {
        guard let pendingURL else { return }
        _ = store.removeCreatedItemFile(at: pendingURL, contents: pendingContents)
        dismiss()
    }
}
