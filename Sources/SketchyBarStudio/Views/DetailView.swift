import SwiftUI

struct DetailView: View {
    @ObservedObject var store: SketchyBarStore

    var body: some View {
        VStack(spacing: 0) {
            if let file = store.selectedFile {
                EditableFileView(store: store, file: file, theme: store.appTheme)
            } else {
                ContentUnavailableView(
                    "No Editable Values",
                    systemImage: "slider.horizontal.3",
                    description: Text("Point the app at a SketchyBar config folder in Settings, then reload.")
                )
            }

            Divider()

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .background(store.appTheme.background.opacity(0.18))
    }
}

private struct EditableFileView: View {
    @ObservedObject var store: SketchyBarStore
    let file: ConfigFile
    let theme: AppTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.displayName)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(file.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        store.discardSelectedChanges()
                    } label: {
                        Label("Discard", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!file.hasUnsavedChanges)

                    Menu {
                        Button("Reveal in Finder") {
                            store.revealSelectedFile()
                        }
                        Button("Open in Default Editor") {
                            store.openSelectedFileExternally()
                        }
                    } label: {
                        Label("File Actions", systemImage: "ellipsis.circle")
                    }

                    Button {
                        store.saveSelectedFile()
                    } label: {
                        Label("Save File", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }

                LazyVStack(spacing: 10) {
                    ForEach(filteredValues) { value in
                        EditableValueRow(
                            value: value,
                            theme: theme,
                            onChange: { store.update(valueID: value.id, draftValue: $0) }
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    private var filteredValues: [LuaEditableValue] {
        file.values.filter { value in
            let matchesSearch: Bool
            let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if query.isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = value.keyPath.lowercased().contains(query) ||
                    value.draftValue.lowercased().contains(query)
            }

            return matchesSearch && (!store.showModifiedOnly || value.draftValue != value.originalValue)
        }
    }
}

private struct EditableValueRow: View {
    let value: LuaEditableValue
    let theme: AppTheme
    let onChange: (String) -> Void

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.keyPath)
                        .font(.body)
                        .fontWeight(.medium)
                    Text("\(value.displayLine) - \(value.kind.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 240, alignment: .leading)

                editor

                if value.draftValue != value.originalValue {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.orange)
                        .help("Unsaved change")
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var editor: some View {
        if value.isFontValue {
            fontEditor
        } else if value.hasSuggestedValues {
            Picker("Value", selection: Binding(get: { value.draftValue }, set: onChange)) {
                ForEach(value.suggestedValues, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
        } else {
            manualEditor
        }
    }

    private var fontEditor: some View {
        HStack {
            Button {
                FontPanelController.shared.showFontPanel(
                    keyPath: value.keyPath,
                    currentValue: value.draftValue,
                    onChange: onChange
                )
            } label: {
                Label("Choose Font...", systemImage: "textformat")
            }

            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var manualEditor: some View {
        switch value.kind {
        case .boolean:
            Toggle(
                "",
                isOn: Binding(
                    get: { SketchyBarBoolean.normalized(value.draftValue) == "true" },
                    set: { onChange($0 ? "true" : "false") }
                )
            )
            .labelsHidden()
        case .color:
            HStack {
                ColorPicker(
                    "Color",
                    selection: Binding(
                        get: { Color(hexLike: value.draftValue) },
                        set: { onChange(SketchyBarColor.sketchyBarHex(from: $0)) }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()

                TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
            }
        case .number:
            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        case .string:
            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
        }
    }
}
