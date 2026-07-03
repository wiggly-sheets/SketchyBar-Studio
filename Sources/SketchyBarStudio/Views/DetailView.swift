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
    @State private var selectedValueID: LuaEditableValue.ID?
    @State private var codePreviewVersion = 0
    @AppStorage("detail.showCodePreview") private var showCodePreview = true

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 520)

            if showCodePreview {
                CodePreviewView(
                    file: file,
                    selectedLine: selectedValue?.lineNumber,
                    highlightedLines: Set(file.values.filter { $0.draftValue != $0.originalValue }.map(\.lineNumber)),
                    theme: theme,
                    refreshToken: codePreviewVersion
                )
                .frame(minWidth: 420)
            }
        }
        .onChange(of: file.id) { _, _ in
            selectedValueID = nil
            codePreviewVersion += 1
        }
    }

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupedValues) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(theme.accent)

                            ForEach(group.values) { value in
                                EditableValueRow(
                                    value: value,
                                    theme: theme,
                                    isSelected: selectedValueID == value.id,
                                    onSelect: {
                                        selectedValueID = value.id
                                    },
                                    onChange: {
                                        store.update(valueID: value.id, draftValue: $0)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
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
                showCodePreview.toggle()
            } label: {
                Label(showCodePreview ? "Hide Code" : "Show Code", systemImage: showCodePreview ? "sidebar.right" : "sidebar.right")
            }
            .help(showCodePreview ? "Hide code preview" : "Show code preview")

            Button {
                store.discardSelectedChanges()
                codePreviewVersion += 1
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
                codePreviewVersion += 1
            } label: {
                Label("Save File", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var groupedValues: [EditableValueGroup] {
        Dictionary(grouping: filteredValues) { value in
            EditableValueGroup.title(for: value)
        }
        .map { title, values in
            EditableValueGroup(title: title, values: values.sorted { $0.lineNumber < $1.lineNumber })
        }
        .sorted { EditableValueGroup.sortRank($0.title) < EditableValueGroup.sortRank($1.title) }
    }

    private var selectedValue: LuaEditableValue? {
        guard let selectedValueID else {
            return nil
        }
        return file.values.first { $0.id == selectedValueID }
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

private struct EditableValueGroup: Identifiable {
    let title: String
    let values: [LuaEditableValue]

    var id: String { title }

    static func title(for value: LuaEditableValue) -> String {
        let key = value.keyPath.lowercased()
        if key.contains("icon") { return "Icon" }
        if key.contains("label") { return "Label" }
        if key.contains("background") { return "Background" }
        if key.contains("popup") { return "Popup" }
        if key.contains("script") { return "Scripts" }
        return "Item"
    }

    static func sortRank(_ title: String) -> Int {
        switch title {
        case "Item": return 0
        case "Icon": return 1
        case "Label": return 2
        case "Background": return 3
        case "Popup": return 4
        case "Scripts": return 5
        default: return 99
        }
    }
}

private struct EditableValueRow: View {
    let value: LuaEditableValue
    let theme: AppTheme
    let isSelected: Bool
    let onSelect: () -> Void
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
        .background(theme.surface.opacity(isSelected ? 0.52 : 0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accent.opacity(isSelected ? 0.72 : 0.18), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    @ViewBuilder
    private var editor: some View {
        if value.isFontValue {
            fontEditor
        } else if value.isWidthValue {
            widthEditor
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

    private var widthEditor: some View {
        HStack {
            Picker(
                "Width mode",
                selection: Binding(
                    get: { value.draftValue == "dynamic" ? "dynamic" : "custom" },
                    set: { onChange($0 == "dynamic" ? "dynamic" : numericFallback) }
                )
            ) {
                Text("dynamic").tag("dynamic")
                Text("number").tag("custom")
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            TextField("Width", text: Binding(get: { value.draftValue == "dynamic" ? "" : value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
                .disabled(value.draftValue == "dynamic")
        }
    }

    private var numericFallback: String {
        Double(value.originalValue) == nil ? "0" : value.originalValue
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

private struct CodePreviewView: View {
    let file: ConfigFile
    let selectedLine: Int?
    let highlightedLines: Set<Int>
    let theme: AppTheme
    let refreshToken: Int
    @State private var lines: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)

                Spacer()

                Text(file.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        CodeLineView(
                            number: index + 1,
                            text: line,
                            isSelected: selectedLine == index + 1,
                            isChanged: highlightedLines.contains(index + 1),
                            theme: theme,
                            kind: file.kind
                        )
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.background.opacity(0.45))
        .onAppear(perform: loadLines)
        .onChange(of: file.id) { _, _ in loadLines() }
        .onChange(of: refreshToken) { _, _ in loadLines() }
    }

    private func loadLines() {
        let contents = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

private struct CodeLineView: View {
    let number: Int
    let text: String
    let isSelected: Bool
    let isChanged: Bool
    let theme: AppTheme
    let kind: ConfigFileKind

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(.caption, design: .default))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)

            HighlightedCodeText(text: displayText, kind: kind, theme: theme)
                .font(.system(.body, design: .default))
                .lineSpacing(3)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
    }

    private var displayText: String {
        text.isEmpty ? " " : text
    }

    private var verticalPadding: CGFloat {
        text.count > 96 ? 7 : 5
    }

    private var background: Color {
        if isSelected {
            return theme.accent.opacity(0.24)
        } else if isChanged {
            return Color.orange.opacity(0.16)
        } else {
            return Color.clear
        }
    }
}

private struct HighlightedCodeText: View {
    let text: String
    let kind: ConfigFileKind
    let theme: AppTheme

    var body: some View {
        rendered
    }

    private var rendered: Text {
        CodeSyntaxHighlighter.tokens(for: text, kind: kind).reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(token.color(in: theme))
        }
    }
}

private struct CodeToken {
    let text: String
    let kind: CodeTokenKind

    func color(in theme: AppTheme) -> Color {
        switch kind {
        case .plain:
            return .primary
        case .comment:
            return theme.muted
        case .keyword, .flag:
            return theme.accent
        case .string:
            return theme.syntaxString
        case .number:
            return theme.syntaxNumber
        case .variable:
            return theme.syntaxVariable
        }
    }
}

private enum CodeTokenKind {
    case plain
    case comment
    case keyword
    case string
    case number
    case variable
    case flag
}

private enum CodeSyntaxHighlighter {
    private static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "require", "dofile", "loadfile"
    ]

    private static let rcKeywords: Set<String> = [
        "sketchybar", "source", "export", "if", "then", "fi", "for", "do", "done", "case", "esac", "function", "bash", "zsh", "sh"
    ]

    static func tokens(for line: String, kind: ConfigFileKind) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var index = line.startIndex

        while index < line.endIndex {
            if startsComment(line, at: index, kind: kind) {
                tokens.append(CodeToken(text: String(line[index...]), kind: .comment))
                break
            }

            let character = line[index]
            if character == "\"" || character == "'" {
                let end = quotedEnd(in: line, from: index, quote: character)
                tokens.append(CodeToken(text: String(line[index..<end]), kind: .string))
                index = end
                continue
            }

            if character.isWhitespace {
                let end = line[index...].firstIndex { !$0.isWhitespace } ?? line.endIndex
                tokens.append(CodeToken(text: String(line[index..<end]), kind: .plain))
                index = end
                continue
            }

            let end = tokenEnd(in: line, from: index, kind: kind)
            let raw = String(line[index..<end])
            tokens.append(CodeToken(text: raw, kind: tokenKind(for: raw, fileKind: kind)))
            index = end
        }

        return tokens.isEmpty ? [CodeToken(text: " ", kind: .plain)] : tokens
    }

    private static func startsComment(_ line: String, at index: String.Index, kind: ConfigFileKind) -> Bool {
        switch kind {
        case .lua:
            return line[index...].hasPrefix("--")
        case .shell, .sketchybarRC:
            return line[index] == "#"
        }
    }

    private static func quotedEnd(in line: String, from start: String.Index, quote: Character) -> String.Index {
        var index = line.index(after: start)
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if character == quote && !escaped {
                return line.index(after: index)
            }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
            index = line.index(after: index)
        }
        return line.endIndex
    }

    private static func tokenEnd(in line: String, from start: String.Index, kind: ConfigFileKind) -> String.Index {
        var index = start
        while index < line.endIndex {
            if startsComment(line, at: index, kind: kind) { break }
            let character = line[index]
            if character.isWhitespace || character == "\"" || character == "'" { break }
            index = line.index(after: index)
        }
        return index
    }

    private static func tokenKind(for raw: String, fileKind: ConfigFileKind) -> CodeTokenKind {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "(),[]{}"))
        let lower = trimmed.lowercased()

        if raw.hasPrefix("--") { return .flag }
        if raw.hasPrefix("$") || raw.contains("${") { return .variable }
        if Double(trimmed) != nil || lower.hasPrefix("0x") { return .number }

        switch fileKind {
        case .lua:
            return luaKeywords.contains(lower) ? .keyword : .plain
        case .shell, .sketchybarRC:
            if lower.hasPrefix("--") { return .flag }
            return rcKeywords.contains(lower) ? .keyword : .plain
        }
    }
}
