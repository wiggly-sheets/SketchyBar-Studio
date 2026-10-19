import SwiftUI

struct DetailView: View {
    @ObservedObject var store: SketchyBarStore

    var body: some View {
        VStack(spacing: 0) {
            BarPreviewView(store: store, theme: store.appTheme)
                .padding()

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

            HStack(spacing: 6) {
                Image(systemName: store.statusKind.symbolName)
                    .foregroundStyle(store.statusKind.tint)
                    .accessibilityHidden(true)

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(store.statusKind.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(store.statusMessage)
            .accessibilityAddTraits(.isStaticText)
        }
        .background(store.appTheme.background.opacity(0.18))
        .onChange(of: store.statusMessage) { _, message in
            guard !message.isEmpty else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

private struct EditableFileView: View {
    @ObservedObject var store: SketchyBarStore
    let file: ConfigFile
    let theme: AppTheme
    @State private var selectedValueID: LuaEditableValue.ID?
    @State private var codePreviewVersion = 0
    @AppStorage("detail.showCodePreview") private var showCodePreview = true
    @AppStorage("detail.showSourceEditor") private var showSourceEditor = false

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 520)

            if showCodePreview {
                CodePreviewView(
                    file: file,
                    contents: previewContents,
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
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if showSourceEditor {
                    SourceEditorView(
                        store: store,
                        file: file,
                        theme: theme
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedValues) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.headline)
                                    .foregroundStyle(theme.accent)

                                ForEach(group.values) { value in
                                    EditableValueRow(
                                        value: value,
                                        file: file,
                                        theme: theme,
                                        isSelected: selectedValueID == value.id,
                                        isEditable: loadError == nil,
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
                Label(
                    showCodePreview ? "Hide Code" : "Show Code",
                    systemImage: showCodePreview ? "sidebar.squares.right" : "sidebar.squares.left"
                )
            }
            .help(showCodePreview ? "Hide code preview" : "Show code preview")

            Button {
                showSourceEditor.toggle()
            } label: {
                Label(showSourceEditor ? "Use Controls" : "Edit Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(store.hasUnsavedChanges(fileID: file.id))
            .help(
                store.hasUnsavedChanges(fileID: file.id)
                    ? "Save or discard edits before switching editing modes"
                    : (showSourceEditor ? "Return to structured controls" : "Edit the complete source file")
            )

            Button {
                store.discardSelectedChanges()
                codePreviewVersion += 1
            } label: {
                Label("Discard", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.hasUnsavedChanges(fileID: file.id))

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
                if store.saveSelectedFile() {
                    codePreviewVersion += 1
                }
            } label: {
                Label("Save File", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(loadError != nil)
            .help(loadError == nil ? "Save this file" : "This file could not be read, so it cannot be saved")
        }
    }

    private var loadError: String? {
        store.loadError(for: file)
    }

    /// The preview shows the pending draft, not the file on disk.
    private var previewContents: String {
        store.effectiveContents(for: file) ?? ""
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
        EditableValueGroup.filtered(file.values, searchText: store.searchText, showModifiedOnly: store.showModifiedOnly)
    }
}

struct EditableValueGroup: Identifiable {
    let title: String
    let values: [LuaEditableValue]

    var id: String { title }

    static func filtered(_ values: [LuaEditableValue], searchText: String, showModifiedOnly: Bool) -> [LuaEditableValue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.filter { value in
            let matchesSearch = query.isEmpty ||
                value.keyPath.lowercased().contains(query) ||
                value.draftValue.lowercased().contains(query)
            return matchesSearch && (!showModifiedOnly || value.draftValue != value.originalValue)
        }
    }

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
    let file: ConfigFile
    let theme: AppTheme
    let isSelected: Bool
    let isEditable: Bool
    let onSelect: () -> Void
    let onChange: (String) -> Void

    @State private var isShowingDoc = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(value.keyPath)
                            .font(.body)
                            .fontWeight(.medium)

                        if let doc {
                            Button {
                                isShowingDoc = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Option reference for \(value.keyPath)")
                            .accessibilityLabel("Option reference for \(value.keyPath)")
                            .popover(isPresented: $isShowingDoc) {
                                OptionDocPopover(doc: doc)
                            }
                        }
                    }

                    Text(value.isMissingFromFile ? "Not in file any more - draft kept" : "\(value.displayLine) - \(value.kind.rawValue)")
                        .font(.caption)
                        .foregroundStyle(value.isMissingFromFile ? .red : .secondary)
                }
                .frame(width: 240, alignment: .leading)

                editor
                    .disabled(!isEditable)

                if value.draftValue != value.originalValue {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.orange)
                        .help(value.isMissingFromFile ? "Unsaved change - the key is no longer in the file" : "Unsaved change")
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
        .simultaneousGesture(
            TapGesture().onEnded {
                onSelect()
            }
        )
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
            .help(helpText(value.keyPath))
        } else {
            manualEditor
        }
    }

    /// The reference entry of the row, when the option has one.
    private var doc: SketchyBarOptionDoc? {
        SketchyBarOptionDocs.doc(for: value.keyPath)
    }

    /// Adds the summary of the reference entry to a tooltip, so the text is
    /// also readable without opening the popover.
    private func helpText(_ text: String) -> String {
        guard let summary = doc?.summary else { return text }
        return "\(text)\n\(summary)"
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
            .help(helpText("\(value.keyPath): switch between a dynamic width and a fixed number of points"))

            ValidatedNumberField(
                title: "Width",
                value: value.draftValue == "dynamic" ? "" : value.draftValue,
                onCommit: onChange
            )
            .frame(maxWidth: 110)
            .disabled(value.draftValue == "dynamic")
        }
    }

    /// The width to use when the mode switches back to a number. The draft
    /// wins, then the value in the file, then the last numeric width of the
    /// same file. It never writes a zero width.
    private var numericFallback: String {
        let siblings = file.values
            .filter { $0.isWidthValue && $0.id != value.id }
            .map(\.draftValue)
        return SketchyBarValueRules.numericWidthFallback(
            draft: value.draftValue,
            original: value.originalValue,
            siblingWidths: siblings
        )
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
            .help(helpText("\(value.keyPath): pick a font family, style and size"))

            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .help(helpText(value.keyPath))
        }
    }

    @ViewBuilder
    private var manualEditor: some View {
        switch value.kind {
        case .boolean:
            Toggle(
                value.keyPath,
                isOn: Binding(
                    get: { SketchyBarBoolean.normalized(value.draftValue) == "true" },
                    set: { onChange($0 ? "true" : "false") }
                )
            )
            .labelsHidden()
            .accessibilityLabel(value.keyPath)
            .help(helpText("\(value.keyPath): turn this option on or off"))
        case .color:
            colorEditor
        case .number:
            ValidatedNumberField(title: "Value", value: value.draftValue, onCommit: onChange)
                .frame(maxWidth: 240)
                .help(helpText(value.keyPath))
        case .string:
            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .help(helpText(value.keyPath))
        }
    }

    private var colorEditor: some View {
        HStack(spacing: 6) {
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { Color(hexLike: value.draftValue) },
                    set: { onChange(SketchyBarColor.hexString(from: $0, preservingFormatOf: colorFormatReference)) }
                ),
                supportsOpacity: true
            )
            .labelsHidden()
            .help(helpText("\(value.keyPath): pick a color. The format of the current value is kept"))

            TextField("Value", text: Binding(get: { value.draftValue }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
                .help(helpText(value.keyPath))

            if colorIsUnreadable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This color cannot be read. Use a hex value such as #ff8800 or 0xffff8800.")
                    .accessibilityLabel("Warning: this color cannot be read")
            }
        }
    }

    /// The value the color format is taken from: the value in the file, or
    /// the draft when the file value cannot be read.
    private var colorFormatReference: String {
        SketchyBarColor.parse(value.originalValue) != nil ? value.originalValue : value.draftValue
    }

    private var colorIsUnreadable: Bool {
        SketchyBarColor.parse(value.draftValue) == nil
    }
}

/// The reference entry of an option, shown in a popover.
private struct OptionDocPopover: View {
    let doc: SketchyBarOptionDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(doc.key)
                .font(.headline)

            Text(doc.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            row("Type", doc.type.rawValue)
            row("Values", doc.values.isEmpty ? "any value" : doc.values.joined(separator: ", "))
            row("Default", doc.defaultValue ?? "no default")
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A number field that keeps the raw text while it is typed and only
/// commits values that are real numbers.
private struct ValidatedNumberField: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void

    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: binding)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)

            if !isValid {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(warning)
            }
        }
        .onChange(of: value) { _, _ in
            text = nil
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { text ?? value },
            set: { newValue in
                text = newValue
                if SketchyBarValueRules.isValidNumber(newValue) {
                    onCommit(newValue)
                }
            }
        )
    }

    private var currentText: String { text ?? value }

    private var isValid: Bool {
        currentText.isEmpty || SketchyBarValueRules.isValidNumber(currentText)
    }

    private var warning: String {
        if SketchyBarValueRules.isPartialNumber(currentText) {
            return "Not a complete number yet"
        }
        return "Not a number. The file keeps its current value."
    }
}

private struct CodePreviewView: View {
    let file: ConfigFile
    let contents: String
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

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(lines.indices, id: \.self) { index in
                            CodeLineView(
                                number: index + 1,
                                text: lines[index],
                                isSelected: selectedLine == index + 1,
                                isChanged: highlightedLines.contains(index + 1),
                                theme: theme,
                                kind: file.kind
                            )
                            .id(index)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedLine) { _, line in
                    guard let line else { return }
                    proxy.scrollTo(line - 1, anchor: .center)
                }
                .onAppear {
                    guard let line = selectedLine else { return }
                    proxy.scrollTo(line - 1, anchor: .center)
                }
            }
        }
        .background(theme.background.opacity(0.45))
        .onAppear(perform: loadLines)
        .onChange(of: file.id) { _, _ in loadLines() }
        .onChange(of: contents) { _, _ in loadLines() }
        .onChange(of: refreshToken) { _, _ in loadLines() }
    }

    private func loadLines() {
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

struct CodeToken {
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

enum CodeTokenKind {
    case plain
    case comment
    case keyword
    case string
    case number
    case variable
    case flag
}

enum CodeSyntaxHighlighter {
    private static let luaKeywords: Set<String> = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "require", "dofile", "loadfile"
    ]

    private static let rcKeywords: Set<String> = [
        "sketchybar", "source", "export", "if", "then", "fi", "for", "do", "done", "case", "esac", "function", "bash", "zsh", "sh"
    ]

    static func tokens(for line: String, kind: ConfigFileKind) -> [CodeToken] {
        let key = TokenCacheKey(text: line, kind: kind)
        if let cached = TokenCache.shared.tokens(for: key) {
            return cached
        }
        let tokens = tokenize(line, kind: kind)
        TokenCache.shared.store(tokens, for: key)
        return tokens
    }

    private static func tokenize(_ line: String, kind: ConfigFileKind) -> [CodeToken] {
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

private struct TokenCacheKey: Hashable {
    let text: String
    let kind: ConfigFileKind
}

/// Keeps the tokens of the lines that were already tokenized, so a
/// re-render does not tokenize the same lines again.
private final class TokenCache {
    static let shared = TokenCache()

    private let lock = NSLock()
    private var storage: [TokenCacheKey: [CodeToken]] = [:]
    private let limit = 4000

    func tokens(for key: TokenCacheKey) -> [CodeToken]? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ tokens: [CodeToken], for key: TokenCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = tokens
    }
}
