import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SketchyBarStore
    @SceneStorage("sidebar.expanded.groups") private var expandedGroupStorage = ""
    @State private var expandedGroups: Set<String> = Set(SidebarCategory.defaultExpandedIDs)

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedFileID) {
                ForEach(sidebarGroups) { group in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: group.id),
                        content: {
                            ForEach(group.files) { file in
                                ConfigFileRow(
                                    file: file,
                                    onActiveChange: { store.setActive($0, fileID: file.id) }
                                )
                                    .tag(file.id)
                            }

                            ForEach(group.folders) { folder in
                                SidebarFolderNodeView(
                                    folder: folder,
                                    expansionBinding: expansionBinding,
                                    onActiveChange: { file, isActive in
                                        store.setActive(isActive, fileID: file.id)
                                    }
                                )
                            }
                        },
                        label: {
                            Label(group.title, systemImage: group.systemImage)
                        }
                    )
                }
            }
            .listStyle(.sidebar)

            ProfilePanel(store: store)
                .padding()
        }
        .navigationTitle("SketchyBar")
        .onAppear {
            if !expandedGroupStorage.isEmpty {
                expandedGroups = Set(expandedGroupStorage.split(separator: "|").map(String.init))
            }
        }
        .onChange(of: expandedGroups) { _, newValue in
            expandedGroupStorage = newValue.sorted().joined(separator: "|")
        }
    }

    private var sidebarGroups: [SidebarFileGroup] {
        let filtered = store.files.filter { file in
            file.matchesSearch(store.searchText) &&
                (!store.showModifiedOnly || file.hasUnsavedChanges)
        }
        return SidebarGrouper.group(files: filtered)
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

private struct SidebarFolderNodeView: View {
    let folder: SidebarFolderNode
    let expansionBinding: (String) -> Binding<Bool>
    let onActiveChange: (ConfigFile, Bool) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: expansionBinding(folder.id),
            content: {
                ForEach(folder.files) { file in
                    ConfigFileRow(
                        file: file,
                        onActiveChange: { onActiveChange(file, $0) }
                    )
                        .tag(file.id)
                }

                ForEach(folder.folders) { child in
                    SidebarFolderNodeView(
                        folder: child,
                        expansionBinding: expansionBinding,
                        onActiveChange: onActiveChange
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

private struct ConfigFileRow: View {
    let file: ConfigFile
    let onActiveChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.sidebarTitle)
                    .lineLimit(1)
                    .foregroundStyle(file.isActive ? .primary : .secondary)
                Text(file.rowDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

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
        }
        .opacity(file.isActive ? 1 : 0.45)
    }
}

private struct ProfilePanel: View {
    @ObservedObject var store: SketchyBarStore

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
                        store.restore(profile: profile)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Restore profile")
                }
            }
        }
    }
}

private enum SidebarCategory: String, CaseIterable {
    case bar
    case items
    case widgets
    case themes
    case scripts
    case other

    static let defaultExpandedIDs = [
        SidebarCategory.bar.id,
        SidebarCategory.items.id,
        SidebarCategory.widgets.id,
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

private struct SidebarFileGroup: Identifiable {
    let category: SidebarCategory
    let files: [ConfigFile]
    let folders: [SidebarFolderNode]

    var id: String { category.id }
    var title: String { category.title }
    var systemImage: String { category.systemImage }
}

private struct SidebarFolderNode: Identifiable {
    let id: String
    let title: String
    let folders: [SidebarFolderNode]
    let files: [ConfigFile]
}

private enum SidebarGrouper {
    static func group(files: [ConfigFile]) -> [SidebarFileGroup] {
        let categorized = Dictionary(grouping: files) { category(for: $0) }

        return SidebarCategory.allCases.compactMap { category in
            guard let files = categorized[category], !files.isEmpty else {
                return nil
            }

            let tree = SidebarTreeBuilder(category: category, files: files).build()
            return SidebarFileGroup(category: category, files: tree.files, folders: tree.folders)
        }
    }

    private static func category(for file: ConfigFile) -> SidebarCategory {
        let path = file.displayName.lowercased()
        let components = file.sidebarPathComponents.map { $0.lowercased() }
        let keys = file.values.map { $0.keyPath.lowercased() }
        let colorValueCount = file.values.filter { $0.kind == .color }.count

        if let folderCategory = categoryFromTopLevelFolder(components.first) {
            return folderCategory
        }

        if path.contains("theme") || path.contains("color") || path.contains("palette") ||
            colorValueCount > max(2, file.values.count / 2) {
            return .themes
        }

        if path.contains("script") || path.contains("plugin") ||
            keys.contains(where: { $0 == "script" || $0 == "click_script" || $0 == "mach_helper" || $0 == "update_freq" }) {
            return .scripts
        }

        if path.contains("bar") || keys.contains(where: { barKeys.contains($0) }) {
            return .bar
        }

        if widgetNames.contains(where: { path.contains($0) }) {
            return .widgets
        }

        if path.contains("item") || keys.contains(where: { itemKeys.contains($0) }) {
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

    func build() -> SidebarFolderNode {
        let root = SidebarFolderBox(title: "", path: "category.\(category.rawValue).root")

        for file in files.sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
            root.insert(file: file, folderComponents: relativeFolderComponents(for: file))
        }

        return root.node
    }

    private func relativeFolderComponents(for file: ConfigFile) -> [String] {
        var components = file.sidebarPathComponents
        guard components.count > 1 else {
            return []
        }

        components.removeLast()

        if shouldDropCategoryFolder(components.first) {
            components.removeFirst()
        }

        return components
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
    private var childFolders: [String: SidebarFolderBox] = [:]
    private var childFiles: [ConfigFile] = []

    init(title: String, path: String) {
        self.title = title
        self.path = path
    }

    func insert(file: ConfigFile, folderComponents: [String]) {
        guard let first = folderComponents.first else {
            childFiles.append(file)
            return
        }

        let childPath = "\(path)/\(first)"
        let child = childFolders[first] ?? SidebarFolderBox(title: first, path: childPath)
        childFolders[first] = child
        child.insert(file: file, folderComponents: Array(folderComponents.dropFirst()))
    }

    var node: SidebarFolderNode {
        SidebarFolderNode(
            id: "folder.\(path)",
            title: title,
            folders: childFolders.values
                .map(\.node)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            files: childFiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
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

    var rowDetail: String {
        let changedCount = values.filter { $0.draftValue != $0.originalValue }.count
        if changedCount > 0 {
            return "\(changedCount) changed of \(editableCount) values"
        }
        return "\(editableCount) \(kind.rawValue) values"
    }
}
