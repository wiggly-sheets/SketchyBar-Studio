import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SketchyBarStore
    @SceneStorage("sidebar.expanded.groups") private var expandedGroupStorage = ""
    @State private var expandedGroups: Set<String> = Set(SidebarCategory.defaultExpandedIDs)
    /// The grouped files. They are rebuilt only when the files, the search
    /// text or the filters change, not on every body pass.
    @State private var groups: [SidebarFileGroup] = []
    /// The file the clone sheet copies.
    @State private var cloneFile: ConfigFile?

    static let missingFilesGroupID = "group.missing-files"

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedFileID) {
                ForEach(groups) { group in
                    SidebarGroupSection(
                        group: group,
                        store: store,
                        expansionBinding: expansionBinding,
                        erroredFileIDs: erroredFileIDs,
                        onClone: { cloneFile = $0 }
                    )
                }

                if !store.missingFiles.isEmpty {
                    MissingFilesSection(store: store, expansionBinding: expansionBinding)
                }
            }
            .listStyle(.sidebar)

            ProfilePanel(store: store)
                .padding()
        }
        .navigationTitle("SketchyBar")
        .sheet(item: $cloneFile) { file in
            CloneItemView(store: store, file: file)
        }
        .onAppear {
            rebuildGroups()
            if !expandedGroupStorage.isEmpty {
                expandedGroups = Set(expandedGroupStorage.split(separator: "|").map(String.init))
            }
        }
        .onChange(of: store.files) { _, _ in rebuildGroups() }
        .onChange(of: store.searchText) { _, _ in rebuildGroups() }
        .onChange(of: store.showModifiedOnly) { _, _ in rebuildGroups() }
        .onChange(of: store.sourceDraftRevision) { _, _ in rebuildGroups() }
        .onChange(of: store.stagedChangedFileIDs) { _, _ in rebuildGroups() }
        .onChange(of: store.stagedOrderRevision) { _, _ in rebuildGroups() }
        .onChange(of: expandedGroups) { _, newValue in
            expandedGroupStorage = newValue.sorted().joined(separator: "|")
        }
    }

    private func rebuildGroups() {
        let filtered = store.files.filter { file in
            file.matchesSearch(store.searchText) &&
                (!store.showModifiedOnly || store.hasUnsavedChanges(fileID: file.id))
        }
        groups = SidebarGrouper.group(files: filtered, ranks: store.loaderRanks())
    }

    private var erroredFileIDs: Set<ConfigFile.ID> {
        Set(store.files.filter { store.loadError(for: $0) != nil }.map(\.id))
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedGroups.insert(id)
                } else {
                    expandedGroups.remove(id)
                }
            }
        )
    }
}

private struct SidebarGroupSection: View {
    let group: SidebarFileGroup
    @ObservedObject var store: SketchyBarStore
    let expansionBinding: (String) -> Binding<Bool>
    let erroredFileIDs: Set<ConfigFile.ID>
    let onClone: (ConfigFile) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(group.id),
            content: {
                ForEach(group.files) { file in
                    ConfigFileRow(
                        file: file,
                        unsavedChangeCount: store.unsavedChangeCount(fileID: file.id),
                        isErrored: erroredFileIDs.contains(file.id),
                        stagedPosition: store.stagedPosition(for: file),
                        onMoveUp: { store.moveItem(fileID: file.id, direction: .up) },
                        onMoveDown: { store.moveItem(fileID: file.id, direction: .down) },
                        onActiveChange: { store.setActive($0, fileID: file.id) },
                        onDropFileID: { droppedID in store.moveItem(fileID: droppedID, before: file.id) },
                        onClone: { onClone(file) }
                    )
                    .tag(file.id)
                }

                ForEach(group.folders) { folder in
                    SidebarFolderNodeView(
                        folder: folder,
                        store: store,
                        expansionBinding: expansionBinding,
                        erroredFileIDs: erroredFileIDs,
                        onClone: onClone
                    )
                }
            },
            label: {
                Label(group.title, systemImage: group.systemImage)
            }
        )
    }
}

private struct MissingFilesSection: View {
    @ObservedObject var store: SketchyBarStore
    let expansionBinding: (String) -> Binding<Bool>

    var body: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(SidebarView.missingFilesGroupID),
            content: {
                ForEach(store.missingFiles) { file in
                    MissingFileRow(
                        file: file,
                        unsavedChangeCount: store.unsavedChangeCount(fileID: file.id)
                    )
                    .tag(file.id)
                }
            },
            label: {
                Label("Missing Files", systemImage: "exclamationmark.triangle")
            }
        )
    }
}

private struct SidebarFolderNodeView: View {
    let folder: SidebarFolderNode
    @ObservedObject var store: SketchyBarStore
    let expansionBinding: (String) -> Binding<Bool>
    let erroredFileIDs: Set<ConfigFile.ID>
    let onClone: (ConfigFile) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(folder.id),
            content: {
                ForEach(folder.files) { file in
                    ConfigFileRow(
                        file: file,
                        unsavedChangeCount: store.unsavedChangeCount(fileID: file.id),
                        isErrored: erroredFileIDs.contains(file.id),
                        stagedPosition: store.stagedPosition(for: file),
                        onMoveUp: { store.moveItem(fileID: file.id, direction: .up) },
                        onMoveDown: { store.moveItem(fileID: file.id, direction: .down) },
                        onActiveChange: { store.setActive($0, fileID: file.id) },
                        onDropFileID: { droppedID in store.moveItem(fileID: droppedID, before: file.id) },
                        onClone: { onClone(file) }
                    )
                    .tag(file.id)
                }

                ForEach(folder.folders) { child in
                    SidebarFolderNodeView(
                        folder: child,
                        store: store,
                        expansionBinding: expansionBinding,
                        erroredFileIDs: erroredFileIDs,
                        onClone: onClone
                    )
                }
            },
            label: {
                Label(folder.title, systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
        )
    }
}

private struct MissingFileRow: View {
    let file: ConfigFile
    let unsavedChangeCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
        }
    }

    private var detail: String {
        if unsavedChangeCount > 0 {
            return "\(unsavedChangeCount) unsaved \(unsavedChangeCount == 1 ? "change" : "changes") kept"
        }
        return "Missing from disk"
    }
}

private struct ConfigFileRow: View {
    let file: ConfigFile
    let unsavedChangeCount: Int
    let isErrored: Bool
    let stagedPosition: Int?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onActiveChange: (Bool) -> Void
    let onDropFileID: (ConfigFile.ID) -> Bool
    let onClone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.sidebarTitle)
                    .lineLimit(1)
                    .foregroundStyle(file.isActive ? .primary : .secondary)
                Text(rowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isErrored {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("This file could not be read")
                    .accessibilityLabel("This file could not be read")
            }

            if let stagedPosition {
                Text("\(stagedPosition)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.orange))
                    .help("Staged loader position \(stagedPosition). Save to write it to the entrypoint.")
                    .accessibilityLabel("Staged loader position \(stagedPosition), not saved yet")
            }

            if file.activationReference != nil {
                Button { onMoveUp() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .help("Move earlier in loader")
                    .accessibilityLabel("Move \(file.sidebarTitle) earlier in loader")
                Button { onMoveDown() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .help("Move later in loader")
                    .accessibilityLabel("Move \(file.sidebarTitle) later in loader")
            }

            Toggle(
                "Active",
                isOn: Binding(
                    get: { file.isActive },
                    set: onActiveChange
                )
            )
            .labelsHidden()
            .controlSize(.mini)
            .disabled(file.activationReference == nil)
            .help(file.activationReference == nil ? "No init/sketchybarrc reference found" : "Comment or uncomment reference in entrypoint")
            .accessibilityLabel("\(file.sidebarTitle) active")
        }
        .opacity(file.isActive ? 1 : 0.45)
        .draggable(file.id)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first else { return false }
            return onDropFileID(droppedID)
        }
        .contextMenu {
            Button("Clone Item…") { onClone() }
                .accessibilityLabel("Clone \(file.sidebarTitle)")
        }
    }

    private var rowDetail: String {
        if unsavedChangeCount > 0 {
            return "\(unsavedChangeCount) unsaved \(unsavedChangeCount == 1 ? "change" : "changes")"
        }
        return "\(file.editableCount) \(file.kind.rawValue) values"
    }
}

private struct ProfilePanel: View {
    @ObservedObject var store: SketchyBarStore
    @State private var restoreCandidate: ConfigProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles")
                .font(.headline)

            HStack {
                TextField("New profile", text: $store.profileName)
                Button {
                    store.saveProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Save current config as a profile")
                .accessibilityLabel("Save profile")
            }

            ForEach(store.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .lineLimit(1)
                        Text(profile.createdAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        restoreCandidate = profile
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Restore profile")
                    .accessibilityLabel("Restore profile \(profile.name)")
                }
            }
        }
        .confirmationDialog(
            "Restore profile?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let restoreCandidate {
                    store.restore(profile: restoreCandidate)
                }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) {
                restoreCandidate = nil
            }
        } message: {
            Text("This replaces the selected config folder with the saved profile. A timestamped backup is kept next to the config folder.")
        }
    }
}

enum SidebarCategory: String, CaseIterable {
    case items
    case widgets
    case bar
    case themes
    case scripts
    case other

    static let defaultExpandedIDs = [
        SidebarCategory.items.id,
        SidebarCategory.widgets.id,
        SidebarCategory.bar.id,
        SidebarCategory.themes.id,
        SidebarCategory.scripts.id
    ]

    var id: String {
        "category.\(rawValue)"
    }

    var title: String {
        switch self {
        case .bar:
            return "Bar"
        case .items:
            return "Items"
        case .widgets:
            return "Widgets"
        case .themes:
            return "Themes & Colors"
        case .scripts:
            return "Scripts"
        case .other:
            return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .bar:
            return "menubar.rectangle"
        case .items:
            return "slider.horizontal.2.square"
        case .widgets:
            return "rectangle.grid.2x2"
        case .themes:
            return "paintpalette"
        case .scripts:
            return "terminal"
        case .other:
            return "tray"
        }
    }
}

struct SidebarFileGroup: Identifiable {
    let category: SidebarCategory
    let files: [ConfigFile]
    let folders: [SidebarFolderNode]

    var id: String { category.id }
    var title: String { category.title }
    var systemImage: String { category.systemImage }
}

struct SidebarFolderNode: Identifiable {
    let id: String
    let title: String
    let folders: [SidebarFolderNode]
    let files: [ConfigFile]
}

enum SidebarGrouper {
    static func group(files: [ConfigFile], ranks: [ConfigFile.ID: Int] = [:]) -> [SidebarFileGroup] {
        let categorized = Dictionary(grouping: files) { category(for: $0) }

        return SidebarCategory.allCases.compactMap { category in
            guard let files = categorized[category], !files.isEmpty else {
                return nil
            }

            let tree = SidebarTreeBuilder(category: category, files: files, ranks: ranks).build()
            return SidebarFileGroup(category: category, files: tree.files, folders: tree.folders)
        }
    }

    /// The order the sidebar shows: the staged loader order first, then the
    /// alphabetical order.
    static func sortedByLoaderOrder(_ files: [ConfigFile], ranks: [ConfigFile.ID: Int]) -> [ConfigFile] {
        files.sorted { lhs, rhs in
            let lhsRank = ranks[lhs.id] ?? .max
            let rhsRank = ranks[rhs.id] ?? .max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func category(for file: ConfigFile) -> SidebarCategory {
        let path = file.displayName.lowercased()
        let components = file.sidebarPathComponents.map { $0.lowercased() }
        let colorValueCount = file.values.filter { $0.kind == .color }.count

        if let folderCategory = categoryFromTopLevelFolder(components.first) {
            return folderCategory
        }

        if path.contains("theme") || path.contains("color") || path.contains("palette") ||
            colorValueCount > max(2, file.values.count / 2) {
            return .themes
        }

        if path.contains("script") || path.contains("plugin") ||
            file.values.contains(where: { scriptKeys.contains($0.keyPath.lowercased()) }) {
            return .scripts
        }

        if path.contains("bar") || file.values.contains(where: { barKeys.contains($0.keyPath.lowercased()) }) {
            return .bar
        }

        if widgetNames.contains(where: { path.contains($0) }) {
            return .widgets
        }

        if path.contains("item") || file.values.contains(where: { itemKeys.contains($0.keyPath.lowercased()) }) {
            return .items
        }

        return .other
    }

    private static func categoryFromTopLevelFolder(_ folder: String?) -> SidebarCategory? {
        guard let folder else {
            return nil
        }

        switch folder {
        case "bar", "bars":
            return .bar
        case "item", "items":
            return .items
        case "widget", "widgets":
            return .widgets
        case "theme", "themes", "color", "colors", "palette", "palettes":
            return .themes
        case "script", "scripts", "plugin", "plugins":
            return .scripts
        default:
            return nil
        }
    }

    private static let barKeys: Set<String> = [
        "height",
        "notch_display_height",
        "margin",
        "notch_width",
        "notch_offset",
        "font_smoothing",
        "sticky"
    ]

    private static let scriptKeys: Set<String> = [
        "script",
        "click_script",
        "mach_helper",
        "update_freq"
    ]

    private static let itemKeys: Set<String> = [
        "position",
        "drawing",
        "space",
        "display",
        "ignore_association",
        "padding_left",
        "padding_right",
        "width",
        "scroll_texts",
        "label",
        "icon"
    ]

    private static let widgetNames = [
        "battery",
        "calendar",
        "clock",
        "cpu",
        "disk",
        "front_app",
        "media",
        "memory",
        "music",
        "network",
        "space",
        "spaces",
        "volume",
        "weather",
        "wifi",
        "aerospace"
    ]
}

private struct SidebarTreeBuilder {
    let category: SidebarCategory
    let files: [ConfigFile]
    let ranks: [ConfigFile.ID: Int]

    func build() -> SidebarFolderNode {
        let root = SidebarFolderBox(title: "", path: "category.\(category.rawValue).root", ranks: ranks)

        for file in SidebarGrouper.sortedByLoaderOrder(files, ranks: ranks) {
            root.insert(file: file, folderComponents: relativeFolderComponents(for: file))
        }

        return root.node
    }

    private func relativeFolderComponents(for file: ConfigFile) -> [String] {
        var components = file.sidebarPathComponents
        guard !components.isEmpty else { return [] }
        components.removeLast()

        if shouldDropCategoryFolder(components.first) {
            components.removeFirst()
        }

        if category == .items, components.isEmpty {
            components.insert(file.sidebarBarPositionFolder, at: 0)
        } else if category == .items {
            components = components.map(normalizedPositionFolder)
        }

        return components
    }

    private func normalizedPositionFolder(_ component: String) -> String {
        switch component.lowercased() {
        case "left": return "Left"
        case "center": return "Center"
        case "right": return "Right"
        default: return component
        }
    }

    private func shouldDropCategoryFolder(_ folder: String?) -> Bool {
        guard let folder = folder?.lowercased() else {
            return false
        }

        switch category {
        case .bar:
            return ["bar", "bars"].contains(folder)
        case .items:
            return ["item", "items"].contains(folder)
        case .widgets:
            return ["widget", "widgets"].contains(folder)
        case .themes:
            return ["theme", "themes", "color", "colors", "palette", "palettes"].contains(folder)
        case .scripts:
            return ["script", "scripts", "plugin", "plugins"].contains(folder)
        case .other:
            return false
        }
    }
}

private final class SidebarFolderBox {
    let title: String
    let path: String
    private let ranks: [ConfigFile.ID: Int]
    private var childFolders: [String: SidebarFolderBox] = [:]
    private var childFiles: [ConfigFile] = []

    init(title: String, path: String, ranks: [ConfigFile.ID: Int] = [:]) {
        self.title = title
        self.path = path
        self.ranks = ranks
    }

    func insert(file: ConfigFile, folderComponents: [String]) {
        guard let first = folderComponents.first else {
            childFiles.append(file)
            return
        }

        let childPath = "\(path)/\(first)"
        let child = childFolders[first] ?? SidebarFolderBox(title: first, path: childPath, ranks: ranks)
        childFolders[first] = child
        child.insert(file: file, folderComponents: Array(folderComponents.dropFirst()))
    }

    static func sortRank(_ title: String) -> String {
        switch title {
        case "Left": return "8-0"
        case "Center": return "8-1"
        case "Right": return "8-2"
        case "Unpositioned": return "8-3"
        default: return "0-" + title.lowercased()
        }
    }

    var node: SidebarFolderNode {
        SidebarFolderNode(
            id: "folder.\(path)",
            title: title,
            folders: childFolders.values
                .map(\.node)
                .sorted { SidebarFolderBox.sortRank($0.title) < SidebarFolderBox.sortRank($1.title) },
            files: SidebarGrouper.sortedByLoaderOrder(childFiles, ranks: ranks)
        )
    }
}

private extension ConfigFile {
    var sidebarPathComponents: [String] {
        displayName.split(separator: "/").map(String.init)
    }

    var sidebarTitle: String {
        displayName.split(separator: "/").last.map(String.init) ?? displayName
    }

    var sidebarBarPositionFolder: String {
        let position = values.first { value in
            let leaf = value.keyPath.lowercased().split(separator: ".").last.map(String.init) ?? value.keyPath.lowercased()
            return leaf == "position"
        }?.draftValue.lowercased()

        switch position {
        case "left": return "Left"
        case "center": return "Center"
        case "right": return "Right"
        default: return "Unpositioned"
        }
    }

}
