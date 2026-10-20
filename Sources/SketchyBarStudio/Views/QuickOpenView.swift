import SwiftUI

/// Lets the Quick Open menu command open the sheet.
@MainActor
final class QuickOpenPresenter: ObservableObject {
    @Published var isPresented = false
}

/// Searches the whole config for a file or an option.
///
/// The sheet only reads. It moves the selection of the window to the file
/// that was picked, and it leaves the search field of the detail pane on
/// the option that was picked.
struct QuickOpenView: View {
    @ObservedObject var store: SketchyBarStore

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [QuickOpenSearch.Result] = []
    @State private var selection: QuickOpenSearch.Result.ID?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchHasFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 640, height: 460)
        .onAppear {
            // The focus is set in the next run loop, because the field is
            // not ready while the sheet is still built.
            DispatchQueue.main.async { searchHasFocus = true }
            refresh()
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: store.files) { _, _ in refresh() }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search for a file or an option", text: $query)
                .textFieldStyle(.plain)
                .focused($searchHasFocus)
                .accessibilityLabel("Search for a file or an option")
                .onSubmit { activateSelection() }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .onChange(of: query) { _, _ in refresh() }
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search for a file or an option",
                systemImage: "magnifyingglass",
                description: Text("Type a file name such as clock, or an option such as padding_left.")
            )
        } else if results.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No file or option matches \(query).")
            )
        } else {
            List(selection: $selection) {
                ForEach(results) { result in
                    row(for: result)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(for result: QuickOpenSearch.Result) -> some View {
        Button {
            activate(result)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.kind == .file ? "doc.text" : "slider.horizontal.3")
                    .foregroundStyle(result.kind == .file ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: result))
                        .font(.body)

                    Text(subtitle(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(result.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: result))
    }

    private func title(for result: QuickOpenSearch.Result) -> String {
        switch result.kind {
        case .file: return result.fileName
        case .value: return result.keyPath ?? result.fileName
        }
    }

    private func subtitle(for result: QuickOpenSearch.Result) -> String {
        switch result.kind {
        case .file:
            return "File"
        case .value:
            let line = result.lineNumber.map { "line \($0)" } ?? "line unknown"
            return "\(result.fileName) · \(line) · \(result.valueText)"
        }
    }

    private func accessibilityLabel(for result: QuickOpenSearch.Result) -> String {
        switch result.kind {
        case .file:
            return "\(result.fileName), file"
        case .value:
            let line = result.lineNumber.map { "line \($0)" } ?? "line unknown"
            return "\(result.fileName), \(line), \(result.keyPath ?? "")"
        }
    }

    // MARK: - Actions

    private func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The search of a running query is stopped, so a slow search of an
        // old query cannot overrule the results of the new one.
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            results = []
            selection = nil
            return
        }

        // The search runs off the main actor, so a big config does not block
        // the window while the user types.
        let files = store.files
        searchTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                QuickOpenSearch.search(query: trimmed, in: files)
            }.value
            guard !Task.isCancelled else { return }
            results = found
            selection = found.first?.id
        }
    }

    /// Moves the selection of the list with the arrow keys.
    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = selection.flatMap { id in results.firstIndex { $0.id == id } } ?? -1
        let next = min(max(current + offset, 0), results.count - 1)
        selection = results[next].id
    }

    private func activateSelection() {
        guard let selection, let result = results.first(where: { $0.id == selection }) else { return }
        activate(result)
    }

    /// Opens the file of the result. A file result clears the search of the
    /// detail pane, and an option result narrows it down to that option.
    private func activate(_ result: QuickOpenSearch.Result) {
        store.selectedFileID = result.fileID
        store.searchText = result.keyPath ?? ""
        store.statusMessage = result.kind == .file
            ? "Opened \(result.fileName)."
            : "Opened \(result.keyPath ?? "") in \(result.fileName)."
        dismiss()
    }
}
