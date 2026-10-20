import SwiftUI

/// The sheet that copies an item file with a new name and a new alias.
///
/// The sheet shows the text that will be written, so the user sees the copy
/// before anything is written. Only the alias of the item changes: every
/// other line of the file stays the same.
struct CloneItemView: View {
    @ObservedObject var store: SketchyBarStore
    let file: ConfigFile
    @Environment(\.dismiss) private var dismiss

    private let cloner = ItemCloner()

    @State private var sourceText = ""
    @State private var loadError = ""
    @State private var newName = ""
    @State private var newAlias = ""
    @State private var showsLoaderFailure = false
    @State private var loaderFailureMessage = ""
    @State private var cloneResult: CloneItemResult?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                targetSection
                previewSection
            }
            .formStyle(.grouped)
            .alert("The loader line was not added", isPresented: $showsLoaderFailure) {
                Button("Keep the Copy") { dismiss() }
                Button("Remove the Copy", role: .destructive) { removeCopy() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The copy was created, but the loader file was not changed. \(loaderFailureMessage)")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityLabel("Cancel the copy")
                Button("Clone Item") { clone() }
                    .disabled(!isValid)
                    .accessibilityLabel("Clone the item")
            }
            .padding()
        }
        .frame(width: 640, height: 620)
        .onAppear { load() }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section("Source") {
            LabeledContent("File") {
                Text(file.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Folder") {
                Text(folderName)
                    .foregroundStyle(.secondary)
            }
            if !loadError.isEmpty {
                warning(loadError)
            } else if sourceAlias == nil {
                Text("This file has no sbar.add(\"item\", ...) call, so the copy gets no loader line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetSection: some View {
        Section("Copy") {
            TextField("New name", text: $newName)
                .accessibilityLabel("New name of the copy")
            if let nameError {
                warning(nameError)
            }

            TextField("New alias", text: $newAlias)
                .accessibilityLabel("New alias of the item")
            if let aliasError {
                warning(aliasError)
            }

            Text("New file: \(relativePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if targetExists {
                warning("\(targetName) already exists. Choose another name.")
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            ScrollView {
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .accessibilityLabel("Preview of the copy")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // MARK: - Values

    private var sourceAlias: String? {
        cloner.sourceAlias(in: sourceText)
    }

    private var baseName: String {
        ((file.displayName as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private var folderName: String {
        let folder = (file.displayName as NSString).deletingLastPathComponent
        return folder.isEmpty ? store.configRoot.lastPathComponent : folder
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedAlias: String {
        newAlias.trimmingCharacters(in: .whitespaces)
    }

    private var relativePath: String {
        cloner.copyPath(for: file.displayName, newName: trimmedName)
    }

    private var targetName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var targetExists: Bool {
        guard !relativePath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: store.configRoot.appendingPathComponent(relativePath).path)
    }

    private var previewText: String {
        cloner.clonedContents(of: sourceText, newAlias: trimmedAlias)
    }

    private var nameError: String? {
        if trimmedName.isEmpty { return "Give the copy a name." }
        if !cloner.isSafeFileName(trimmedName) {
            return "The name may only hold letters, digits, dashes, underscores and dots."
        }
        return nil
    }

    private var aliasError: String? {
        if trimmedAlias.isEmpty { return "Give the copy an alias." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        if trimmedAlias.rangeOfCharacter(from: allowed.inverted) != nil {
            return "The alias may only hold letters, digits, dashes, underscores and dots."
        }
        return nil
    }

    private var isValid: Bool {
        loadError.isEmpty && nameError == nil && aliasError == nil && !targetExists
    }

    // MARK: - Actions

    private func load() {
        guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
            loadError = "This file could not be read."
            return
        }
        sourceText = text
        newName = baseName + "-copy"
        newAlias = (cloner.sourceAlias(in: text) ?? baseName) + "-copy"
    }

    private func clone() {
        guard let result = store.cloneItem(
            file: file,
            newName: trimmedName,
            newAlias: trimmedAlias
        ) else { return }

        cloneResult = result
        guard !result.didAddLoaderLine else {
            dismiss()
            return
        }
        guard let failure = result.loaderFailureMessage else {
            // The copy has no loader line because the source has no item.
            dismiss()
            return
        }
        loaderFailureMessage = failure
        showsLoaderFailure = true
    }

    private func removeCopy() {
        guard let result = cloneResult else {
            dismiss()
            return
        }
        _ = store.removeCreatedItemFile(at: result.fileURL, contents: result.contents)
        dismiss()
    }
}
