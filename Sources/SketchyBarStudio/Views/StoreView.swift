import SwiftUI

/// Browses the curated catalogue, previews content and installs through the
/// manifest-backed install service.
struct StoreView: View {
    @StateObject private var model: StoreModel

    init(configRoot: URL, configID: String, appSupportRoot: URL? = nil) {
        _model = StateObject(wrappedValue: StoreModel(
            configRoot: configRoot,
            configID: configID,
            appSupportRoot: appSupportRoot
        ))
    }

    var body: some View {
        HSplitView {
            catalogue
            detail
        }
        .navigationTitle("Store")
        .onAppear {
            model.reloadRecords()
            model.loadSelectedPreview()
        }
        .onChange(of: model.kind) { _, _ in
            model.selectFirstVisibleEntry()
        }
        .sheet(item: $model.installCandidate) { entry in
            StoreInstallSheet(
                entry: entry,
                preview: model.previewText,
                isWorking: model.isWorking
            ) {
                model.install(entry)
            }
        }
        .alert(
            "Uninstall \(model.uninstallCandidate?.name ?? "")?",
            isPresented: Binding(
                get: { model.uninstallCandidate != nil },
                set: { if !$0 { model.cancelUninstall() } }
            ),
            presenting: model.uninstallCandidate
        ) { _ in
            Button("Uninstall", role: .destructive) { model.confirmUninstall() }
            Button("Cancel", role: .cancel) { model.cancelUninstall() }
        } message: { record in
            Text(model.uninstallDescription(for: record))
        }
    }

    private var catalogue: some View {
        VStack(spacing: 0) {
            Picker("Catalogue", selection: $model.kind) {
                ForEach(StoreEntryKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .accessibilityLabel("Catalogue kind")

            List(selection: $model.selectedID) {
                ForEach(model.visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                        Text(entry.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if entry.licence == nil {
                            Text("No verified licence")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .tag(entry.id)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.selectedID) { _, _ in
                model.loadSelectedPreview()
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entry = model.selectedEntry {
                    header(entry)
                    metadata(entry)
                    preview(entry)
                    installControls(entry)
                } else {
                    ContentUnavailableView(
                        "Pick an Entry",
                        systemImage: "shippingbox",
                        description: Text("Choose a plugin or a setup from the catalogue.")
                    )
                }

                if !model.errorMessage.isEmpty {
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if !model.statusMessage.isEmpty {
                    Label(model.statusMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                installedSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420)
    }

    private func header(_ entry: StoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.name)
                .font(.title2.weight(.semibold))
            Text(entry.summary)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private func metadata(_ entry: StoreEntry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Author").foregroundStyle(.secondary)
                Text(entry.author)
            }
            GridRow {
                Text("Licence").foregroundStyle(.secondary)
                if let licence = entry.licence {
                    if let url = URL(string: entry.licenceURL) {
                        Link(licence.rawValue, destination: url)
                    } else {
                        Text(licence.rawValue)
                    }
                } else {
                    Text("No verified licence").foregroundStyle(.orange)
                }
            }
            GridRow {
                Text("Source").foregroundStyle(.secondary)
                Text("\(entry.repository)/\(entry.path.isEmpty ? "" : entry.path)")
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Pinned ref").foregroundStyle(.secondary)
                Text(entry.ref)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func preview(_ entry: StoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.kind == .plugin ? "File content" : "What is installed")
                .font(.headline)

            switch model.preview {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case .text(let text):
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            case .unavailable(let text):
                Text(text).foregroundStyle(.secondary)
            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("Retry") { model.loadSelectedPreview() }
                }
            }
        }
    }

    @ViewBuilder
    private func installControls(_ entry: StoreEntry) -> some View {
        HStack {
            Button {
                model.beginInstall(entry)
            } label: {
                Label(entry.kind == .plugin ? "Install Plugin…" : "Install Setup…", systemImage: "arrow.down.circle")
            }
            .disabled(!model.canInstall(entry) || model.isWorking)

            if model.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        if !entry.isInstallable {
            Text("This entry is not installable: no verified permissive licence.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Installed from the Store")
                .font(.headline)

            if model.records.isEmpty {
                Text("Nothing installed for this config folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.records) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.name) — \(record.author)")
                            Text(record.installedPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Uninstall…") { model.beginUninstall(record) }
                            .accessibilityLabel("Uninstall \(record.name)")
                    }
                }
            }
        }
    }
}

private struct StoreInstallSheet: View {
    let entry: StoreEntry
    let preview: String?
    let isWorking: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.kind == .plugin ? "Install \(entry.name)?" : "Add \(entry.name) as a profile?")
                .font(.headline)

            Text(entry.kind == .plugin
                 ? "This exact file is written into the config folder."
                 : "The setup is copied into a new profile. Your own config folder is not changed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let preview {
                ScrollView {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

            if let url = URL(string: entry.licenceURL), let licence = entry.licence {
                Link("Read the \(licence.rawValue) licence", destination: url)
            }

            Toggle("I accept the \(entry.licence?.rawValue ?? "") licence and want to install this entry.", isOn: $accepted)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!accepted || isWorking)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

@MainActor
final class StoreModel: ObservableObject {
    enum Preview: Equatable {
        case idle
        case loading
        case text(String)
        case unavailable(String)
        case failed(String)
    }

    @Published var kind: StoreEntryKind = .plugin {
        didSet { selectFirstVisibleEntry() }
    }
    @Published var selectedID: String?
    @Published var preview: Preview = .idle
    @Published var records: [StoreInstallRecord] = []
    @Published var installCandidate: StoreEntry?
    @Published var uninstallCandidate: StoreInstallRecord?
    @Published var errorMessage = ""
    @Published var statusMessage = ""
    @Published var isWorking = false

    let configRoot: URL
    let configID: String

    private let client: StoreClient
    private let installer: StoreInstallService

    init(configRoot: URL, configID: String, appSupportRoot: URL? = nil) {
        self.configRoot = configRoot
        self.configID = configID
        self.client = StoreClient()
        self.installer = StoreInstallService(appSupportRoot: appSupportRoot)
        selectFirstVisibleEntry()
    }

    var visibleEntries: [StoreEntry] {
        StoreCatalogue.entries.filter { $0.kind == kind }
    }

    var selectedEntry: StoreEntry? {
        visibleEntries.first { $0.id == selectedID }
    }

    var previewText: String? {
        if case .text(let text) = preview { return text }
        return nil
    }

    func selectFirstVisibleEntry() {
        guard selectedEntry == nil else { return }
        selectedID = visibleEntries.first?.id
    }

    func loadSelectedPreview() {
        guard let entry = selectedEntry else {
            preview = .idle
            return
        }
        Task { await loadPreview(entry) }
    }

    private func loadPreview(_ entry: StoreEntry) async {
        guard entry.isInstallable else {
            preview = .unavailable("No verified permissive licence, so the content is not fetched.")
            return
        }
        guard entry.kind == .plugin else {
            preview = .unavailable("The setup is fetched when you confirm, then copied into a new profile.")
            return
        }

        preview = .loading
        do {
            let data = try await client.fetchPluginFile(entry)
            preview = .text(String(decoding: data, as: UTF8.self))
        } catch {
            preview = .failed(message(for: error))
        }
    }

    func canInstall(_ entry: StoreEntry) -> Bool {
        guard entry.isInstallable else { return false }
        switch entry.kind {
        case .plugin:
            return previewText != nil
        case .setup:
            return true
        }
    }

    func beginInstall(_ entry: StoreEntry) {
        errorMessage = ""
        statusMessage = ""
        installCandidate = entry
    }

    func install(_ entry: StoreEntry) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = ""
        Task {
            do {
                let outcome: StoreInstallOutcome
                switch entry.kind {
                case .plugin:
                    let data = try await client.fetchPluginFile(entry)
                    outcome = try installer.installPlugin(
                        entry,
                        contents: data,
                        configRoot: configRoot,
                        configID: configID
                    )
                case .setup:
                    let tree = try await client.fetchSetupTree(entry)
                    defer { tree.remove() }
                    outcome = try installer.installSetup(
                        entry,
                        tree: tree.contents,
                        configRoot: configRoot,
                        configID: configID
                    )
                }
                statusMessage = status(for: outcome, entry: entry)
                installCandidate = nil
                reloadRecords()
            } catch {
                errorMessage = message(for: error)
            }
            isWorking = false
        }
    }

    func reloadRecords() {
        do {
            records = try installer.records(configRoot: configRoot, configID: configID)
        } catch {
            records = []
            errorMessage = message(for: error)
        }
    }

    func beginUninstall(_ record: StoreInstallRecord) {
        uninstallCandidate = record
    }

    func cancelUninstall() {
        uninstallCandidate = nil
    }

    func uninstallDescription(for record: StoreInstallRecord) -> String {
        var lines = ["Removed path: \(record.installedPath)"]
        if let edit = record.loaderEdit {
            lines.append("Reverted loader line in \(edit.entrypointPath): \(edit.line)")
        }
        if record.location == .profile {
            lines.append("Only this profile folder is removed. Your config folder is not touched.")
        }
        return lines.joined(separator: "\n")
    }

    func confirmUninstall() {
        guard let record = uninstallCandidate else { return }
        uninstallCandidate = nil
        errorMessage = ""
        do {
            let removed = try installer.uninstall(recordID: record.id, configRoot: configRoot, configID: configID)
            statusMessage = "Removed \(removed.map(\.lastPathComponent).joined(separator: ", "))."
            reloadRecords()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func status(for outcome: StoreInstallOutcome, entry: StoreEntry) -> String {
        if entry.kind == .setup {
            return "Added the setup as the profile \(outcome.installedURL.lastPathComponent). It is separate from your config."
        }
        switch outcome.loader {
        case .inserted(let entrypoint, let line):
            return "Installed \(outcome.record.installedPath) and added \(line) to \(entrypoint)."
        case .alreadyActive(let line):
            return "Installed \(outcome.record.installedPath). \(line) was already in the loader."
        case .manual(let line, let reason):
            return "Installed \(outcome.record.installedPath). Add this line yourself: \(line) — \(reason)"
        case nil:
            return "Installed \(outcome.record.installedPath)."
        }
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
