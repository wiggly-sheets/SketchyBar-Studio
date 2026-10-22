import SwiftUI

/// Browses the curated catalogue, previews content and installs through the
/// manifest-backed install service.
struct StoreView: View {
    @StateObject private var model: StoreModel
    @State private var readmeShowsRaw = false

    init(configRoot: URL, configID: String, appSupportRoot: URL? = nil) {
        _model = StateObject(wrappedValue: StoreModel(
            configRoot: configRoot,
            configID: configID,
            appSupportRoot: appSupportRoot,
            dependencyService: .shared,
            userDefaults: .standard
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
        .sheet(item: $model.installCandidate, onDismiss: { model.discardStaging() }) { entry in
            StoreInstallSheet(model: model, entry: entry) {
                Task { await model.install(entry) }
            }
        }
        .sheet(item: $model.resolveCandidate, onDismiss: { model.cancelResolve() }) { unresolved in
            StoreResolveSheet(model: model, unresolved: unresolved) {
                Task { await model.resolve(unresolved) }
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
                readmeShowsRaw = false
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
                    readmeSection(entry)
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
                licenceLabel(entry)
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
    private func licenceLabel(_ entry: StoreEntry) -> some View {
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

    /// The README sits next to the licence link, so attribution is on screen
    /// with the text it belongs to.
    private func readmeSection(_ entry: StoreEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("README").font(.headline)
                licenceLabel(entry)
                    .font(.caption)

                Spacer()

                if model.readmeText != nil {
                    Picker("README view", selection: $readmeShowsRaw) {
                        Text("Rendered").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .accessibilityLabel("README view")
                }
            }

            switch model.readme {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case .loaded(let text):
                ScrollView {
                    if readmeShowsRaw {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(StoreMarkdown.rendered(text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: 320)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            case .unavailable(let url):
                VStack(alignment: .leading, spacing: 2) {
                    Text("README unavailable")
                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel("README source URL")
                }
            }
        }
    }

    @ViewBuilder
    private func preview(_ entry: StoreEntry) -> some View {
        switch entry.kind {
        case .plugin:
            pluginPreview
        case .setup:
            setupPreview
        }
    }

    private var pluginPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File content").font(.headline)

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

    private var setupPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                if case .staged(let files, let total) = model.setup {
                    Text("\(files.count) files · \(StoreView.byteText(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch model.setup {
            case .idle:
                HStack(spacing: 8) {
                    Text("Inspect the setup before it is installed.")
                        .foregroundStyle(.secondary)
                    Button("Inspect Files") { model.inspectSelectedSetup() }
                }
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed(let message):
                HStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Try Again") { model.inspectSelectedSetup() }
                }
            case .staged(let files, _):
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(files) { file in
                            HStack {
                                Text(file.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Text(StoreView.byteText(file.size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                Text("These files are copied into a new profile. Your config folder is not changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        } else if entry.kind == .setup && !model.isSetupStaged {
            Text("Inspect the files first. The same staged tree is used for the install.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Renders README markdown. A parse failure falls back to the plain text, so
/// a malformed README never leaves an empty pane.
enum StoreMarkdown {
    static func rendered(_ text: String) -> AttributedString {
        rendered(text) { markdown in
            try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
        }
    }

    static func rendered(
        _ text: String,
        parse: (String) throws -> AttributedString
    ) -> AttributedString {
        (try? parse(text)) ?? AttributedString(text)
    }
}

/// A dependency install succeeded but a required dep is still missing.
struct StoreDependencyUnresolved: Identifiable {
    let entryID: String
    let entryName: String
    let missingDependencies: [StoreDependency]
    var id: String { entryID }
}

private struct StoreInstallSheet: View {
    @ObservedObject var model: StoreModel
    let entry: StoreEntry
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false
    @AppStorage("store.dependencyPolicy") private var policyRaw = StoreDependencyPolicy.ask.rawValue
    @State private var overridePolicy: StoreDependencyPolicy?

    private var policy: StoreDependencyPolicy {
        overridePolicy ?? StoreDependencyPolicy(rawValue: policyRaw) ?? .ask
    }

    private var blockingRequiredMissing: [StoreDependency] {
        guard policy == .never else { return [] }
        var missing: [StoreDependency] = []
        for (dep, status) in zip(entry.dependencies, model.dependencyStatus(for: entry)) {
            if dep.required && status == .missing { missing.append(dep) }
        }
        return missing
    }

    private var automaticInstalls: [StoreDependency] {
        guard policy == .automatic else { return [] }
        var toInstall: [StoreDependency] = []
        for (dep, status) in zip(entry.dependencies, model.dependencyStatus(for: entry)) where status == .missing {
            if dep.kind == .formula || dep.kind == .cask { toInstall.append(dep) }
        }
        return toInstall
    }

    private var installBlocked: Bool {
        blockingRequiredMissing.count > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.kind == .plugin ? "Install \(entry.name)?" : "Add \(entry.name) as a profile?")
                .font(.headline)

            Text(entry.kind == .plugin
                 ? "This exact file is written into the config folder."
                 : "The inspected tree is copied into a new profile. Your own config folder is not changed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let preview = model.previewText {
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

            if !entry.dependencies.isEmpty {
                dependenciesSection
            }

            if let url = URL(string: entry.licenceURL), let licence = entry.licence {
                Link("Read the \(licence.rawValue) licence", destination: url)
            }

            if installBlocked {
                Text("Install blocked: required dependencies are missing and the policy is \(policy.title). Install them first or change the policy.")
                    .font(.callout)
                    .foregroundStyle(.red)
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
                .disabled(!accepted || model.isWorking || installBlocked)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.reloadDependencyStatus(for: entry) }
    }

    @ViewBuilder
    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Dependencies").font(.headline)
                Spacer()
                Text("Policy: \(policy.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Policy override", selection: $overridePolicy) {
                    Text("Use setting (\(StoreDependencyPolicy(rawValue: policyRaw)?.title ?? "Ask"))").tag(nil as StoreDependencyPolicy?)
                    ForEach(StoreDependencyPolicy.allCases, id: \.self) { p in
                        Text(p.title).tag(Optional(p))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel("Dependency policy override")
            }

            switch model.dependencyCheckState {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking dependencies…").font(.caption).foregroundStyle(.secondary)
                }
            case .checked:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(entry.dependencies, model.dependencyStatus(for: entry)).enumerated()), id: \.offset) { _, pair in
                        let dep = pair.0
                        let status = pair.1
                        HStack(spacing: 6) {
                            presenceLabel(status)
                            Text(depLabel(dep))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if !dep.required {
                                Text("optional")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if policy == .automatic && !automaticInstalls.isEmpty {
                Label("Automatic install will run: " + automaticInstalls.map(\.name).joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func presenceLabel(_ status: StoreDependencyPresence) -> some View {
        switch status {
        case .present:
            Label("present", systemImage: "checkmark.circle").foregroundStyle(.green).labelStyle(.titleAndIcon)
        case .missing:
            Label("missing", systemImage: "xmark.circle").foregroundStyle(.orange).labelStyle(.titleAndIcon)
        case .unknownBecauseBrewAbsent:
            Label("brew not found", systemImage: "questionmark.circle").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        case .unknownBecauseFontconfigAbsent:
            Label("fontconfig not found", systemImage: "questionmark.circle").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        case .unknown(let reason):
            Label(reason, systemImage: "questionmark.circle").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
    }

    private func depLabel(_ dep: StoreDependency) -> String {
        switch dep.kind {
        case .formula: return "\(dep.name) (brew)"
        case .cask: return "\(dep.name) (brew --cask)"
        case .command: return dep.name
        case .font: return "\(dep.name) (font)"
        case .sketchybar: return "SketchyBar"
        }
    }
}

/// The retry sheet for a dependency that was installed but not found
/// afterwards. Retrying re-runs the presence check first.
private struct StoreResolveSheet: View {
    @ObservedObject var model: StoreModel
    let unresolved: StoreDependencyUnresolved
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resolve \(unresolved.entryName)?")
                .font(.headline)
            Text("Installed, but still missing after install: \(unresolved.missingDependencies.map(\.name).joined(separator: ", ")).")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resolve") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
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

    enum Readme: Equatable {
        case idle
        case loading
        case loaded(String)
        case unavailable(String)
    }

    enum Setup: Equatable {
        case idle
        case loading
        case staged(files: [StoreStagedFile], totalBytes: Int64)
        case failed(String)
    }

    @Published var kind: StoreEntryKind = .plugin {
        didSet { selectFirstVisibleEntry() }
    }
    @Published var selectedID: String?
    @Published var preview: Preview = .idle
    @Published var readme: Readme = .idle
    @Published var setup: Setup = .idle
    @Published var records: [StoreInstallRecord] = []
    @Published var installCandidate: StoreEntry?
    @Published var uninstallCandidate: StoreInstallRecord?
    /// A dependency install succeeded but a required dep is still missing.
    @Published var resolveCandidate: StoreDependencyUnresolved?
    @Published var errorMessage = ""
    @Published var statusMessage = ""
    @Published var isWorking = false

    // MARK: - Dependency check state
    enum DependencyCheckState: Equatable {
        case idle
        case checking
        case checked
    }
    @Published private(set) var dependencyCheckState: DependencyCheckState = .idle
    /// Presence results keyed by dependency name, for the entry shown in the
    /// install sheet. Re-checked at install time.
    private var dependencyPresences: [String: StoreDependencyPresence] = [:]

    private let dependencyService: StoreDependencyService
    private let userDefaults: UserDefaults

    var dependencyPolicy: StoreDependencyPolicy {
        StoreDependencyPolicy(rawValue: userDefaults.string(forKey: "store.dependencyPolicy") ?? "") ?? .ask
    }

    func reloadDependencyStatus(for entry: StoreEntry) {
        dependencyCheckState = .checking
        dependencyPresences = [:]
        Task { await checkDependencies(for: entry) }
    }

    func dependencyStatus(for entry: StoreEntry) -> [StoreDependencyPresence] {
        entry.dependencies.map { dependencyPresences[$0.name] ?? .missing }
    }

    private func checkDependencies(for entry: StoreEntry) async {
        let presences = await dependencyService.check(entry.dependencies)
        await MainActor.run {
            var updated: [String: StoreDependencyPresence] = [:]
            for (dep, status) in zip(entry.dependencies, presences) {
                updated[dep.name] = status
            }
            self.dependencyPresences = updated
            self.dependencyCheckState = .checked
        }
    }

    func cancelResolve() {
        resolveCandidate = nil
    }

    func resolve(_ unresolved: StoreDependencyUnresolved) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        // Re-check presence first (no install attempt).
        let postCheck = await dependencyService.check(unresolved.missingDependencies)
        var stillMissing: [StoreDependency] = []
        for (dep, status) in zip(unresolved.missingDependencies, postCheck) {
            if dep.required && status == .missing {
                stillMissing.append(dep)
            }
        }
        if stillMissing.isEmpty {
            resolveCandidate = nil
            return
        }

        // Still missing — offer to retry. For automatic policy, re-attempt.
        let policy = dependencyPolicy
        if policy == .automatic {
            for dep in stillMissing where dep.kind == .formula || dep.kind == .cask {
                _ = await dependencyService.install(dep) { line in
                    await MainActor.run { self.statusMessage = line }
                }
            }
            // Final re-check
            let final = await dependencyService.check(unresolved.missingDependencies)
            let finalMissing = zip(unresolved.missingDependencies, final).compactMap { dep, status in
                dep.required && status == .missing ? dep : nil
            }
            if finalMissing.isEmpty {
                resolveCandidate = nil
            } else {
                resolveCandidate = StoreDependencyUnresolved(
                    entryID: unresolved.entryID,
                    entryName: unresolved.entryName,
                    missingDependencies: finalMissing
                )
            }
        } else {
            resolveCandidate = StoreDependencyUnresolved(
                entryID: unresolved.entryID,
                entryName: unresolved.entryName,
                missingDependencies: stillMissing
            )
        }
    }

    let configRoot: URL
    let configID: String

    private let client: StoreClient
    private let installer: StoreInstallService
    private var previewTask: Task<Void, Never>?
    /// The inspected tree. Install copies from it instead of fetching again.
    private(set) var stagedTree: StoreTree?
    private(set) var stagedEntryID: String?

    init(
        configRoot: URL,
        configID: String,
        appSupportRoot: URL? = nil,
        client: StoreClient? = nil,
        dependencyService: StoreDependencyService = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.configRoot = configRoot
        self.configID = configID
        self.client = client ?? StoreClient()
        self.installer = StoreInstallService(appSupportRoot: appSupportRoot)
        self.dependencyService = dependencyService
        self.userDefaults = userDefaults
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

    var readmeText: String? {
        if case .loaded(let text) = readme { return text }
        return nil
    }

    var isSetupStaged: Bool {
        stagedEntryID != nil && stagedEntryID == selectedID
    }

    func selectFirstVisibleEntry() {
        guard selectedEntry == nil else { return }
        selectedID = visibleEntries.first?.id
    }

    /// Starts the fetch for the selected entry. The staging of the previous
    /// entry is dropped first, so at most one tree is on disk.
    func loadSelectedPreview() {
        previewTask?.cancel()
        discardStaging()
        preview = .idle
        readme = .idle
        guard let entry = selectedEntry else { return }
        previewTask = Task { await inspect(entry) }
    }

    /// Fetches the README and the plugin content, or stages the setup tree.
    /// Exposed for tests: no Task is spawned here.
    func inspect(_ entry: StoreEntry) async {
        guard selectedID == entry.id else { return }

        readme = .loading
        if entry.kind == .setup {
            setup = .loading
            preview = .unavailable("The setup is staged before it is installed.")
        } else {
            preview = .loading
        }

        guard entry.isInstallable else {
            readme = .unavailable(entry.rawFileURLString)
            preview = .unavailable("No verified permissive licence, so the content is not fetched.")
            setup = .idle
            return
        }

        let readmeResult = await client.readme(for: entry)
        guard selectedID == entry.id else { return }
        switch readmeResult {
        case .loaded(let readme):
            self.readme = .loaded(readme.text)
        case .unavailable(let url):
            self.readme = .unavailable(url)
        }

        switch entry.kind {
        case .plugin:
            do {
                let data = try await client.fetchPluginFile(entry)
                guard selectedID == entry.id else { return }
                preview = .text(String(decoding: data, as: UTF8.self))
            } catch {
                guard selectedID == entry.id else { return }
                preview = .failed(message(for: error))
            }
        case .setup:
            await stage(entry)
        }
    }

    func inspectSelectedSetup() {
        guard let entry = selectedEntry, entry.kind == .setup else { return }
        Task { await stage(entry) }
    }

    private func stage(_ entry: StoreEntry) async {
        guard selectedID == entry.id else { return }
        do {
            let tree = try await client.fetchSetupTree(entry)
            guard selectedID == entry.id else {
                tree.remove()
                return
            }
            do {
                let files = try tree.fileList()
                stagedTree?.remove()
                stagedTree = tree
                stagedEntryID = entry.id
                setup = .staged(files: files, totalBytes: files.reduce(0) { $0 + $1.size })
            } catch {
                tree.remove()
                setup = .failed(message(for: error))
            }
        } catch {
            guard selectedID == entry.id else { return }
            setup = .failed(message(for: error))
        }
    }

    func discardStaging() {
        stagedTree?.remove()
        stagedTree = nil
        stagedEntryID = nil
        setup = .idle
    }

    func canInstall(_ entry: StoreEntry) -> Bool {
        guard entry.isInstallable else { return false }
        switch entry.kind {
        case .plugin:
            return previewText != nil
        case .setup:
            return isSetupStaged
        }
    }

    func beginInstall(_ entry: StoreEntry) {
        errorMessage = ""
        statusMessage = ""
        installCandidate = entry
    }

    func install(_ entry: StoreEntry) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = ""

        do {
            // Re-check dependencies at install time.
            let presences = await dependencyService.check(entry.dependencies)
            var updated: [String: StoreDependencyPresence] = [:]
            for (dep, status) in zip(entry.dependencies, presences) {
                updated[dep.name] = status
            }
            self.dependencyPresences = updated
            self.dependencyCheckState = .checked

            // Check for required deps that are missing and cannot be auto-installed.
            let policy = dependencyPolicy
            let missingRequired = zip(entry.dependencies, presences).compactMap { dep, status -> StoreDependency? in
                if dep.required && status == .missing {
                    // If automatic, we'll try to install formula/cask deps.
                    if policy == .automatic && (dep.kind == .formula || dep.kind == .cask) {
                        return nil
                    }
                    return dep
                }
                return nil
            }
            if !missingRequired.isEmpty {
                errorMessage = "Required dependencies missing: " + missingRequired.map(\.name).joined(separator: ", ")
                return
            }

            // Automatic install for formula/cask deps.
            if policy == .automatic {
                let toInstall = zip(entry.dependencies, presences).compactMap { dep, status -> StoreDependency? in
                    if dep.required && status == .missing && (dep.kind == .formula || dep.kind == .cask) {
                        return dep
                    }
                    return nil
                }
                for dep in toInstall {
                    _ = await dependencyService.install(dep) { line in
                        // Stream output to status message so the user sees progress.
                        await MainActor.run {
                            self.statusMessage = line
                        }
                    }
                }
            }

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
                // For multi-file plugins, fetch and write each additional file.
                if !entry.files.isEmpty {
                    let root = configRoot.standardizedFileURL
                    let pluginDir = root.appendingPathComponent("plugins/\(entry.id)", isDirectory: true)
                    for extraPath in entry.files {
                        guard let extraName = StoreInstallService.pluginFileName(from: extraPath) else {
                            throw StoreError.invalidEntry("Multi-file entry has an unsafe path: \(extraPath)")
                        }
                        let extraData = try await client.fetchFile(entry, path: extraPath)
                        let extraDestination = pluginDir.appendingPathComponent(extraName)
                        try extraData.write(to: extraDestination, options: .atomic)
                    }
                }
            case .setup:
                guard let tree = stagedTree, stagedEntryID == entry.id else {
                    throw StoreError.invalidEntry("Inspect the setup files before installing it.")
                }
                outcome = try installer.installSetup(
                    entry,
                    tree: tree.contents,
                    configRoot: configRoot,
                    configID: configID
                )
            }
            statusMessage = status(for: outcome, entry: entry)
            installCandidate = nil
            discardStaging()
            reloadRecords()

            // Post-check: if required deps are still missing, show resolve sheet.
            let postCheck = await dependencyService.check(entry.dependencies)
            let stillMissing = zip(entry.dependencies, postCheck).compactMap { dep, status -> StoreDependency? in
                if dep.required && status == .missing { return dep }
                return nil
            }
            if !stillMissing.isEmpty {
                self.resolveCandidate = StoreDependencyUnresolved(
                    entryID: entry.id,
                    entryName: entry.name,
                    missingDependencies: stillMissing
                )
            }
        } catch {
            errorMessage = message(for: error)
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
