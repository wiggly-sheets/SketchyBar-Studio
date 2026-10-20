import SwiftUI

/// Shows what a save would write, as a line diff of the file on disk and
/// the text that would be written.
///
/// The view only shows. It never writes a file, and it never changes the
/// drafts. The save is done by whoever opened the sheet.
struct SaveReviewView: View {
    let fileName: String
    let theme: AppTheme
    /// What the save would change, with the note about a change that holds
    /// no changed line.
    let difference: DiffEngine.Difference
    /// The message shown when the file changed on disk.
    let notice: String?
    let readError: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice {
                noticeRow(notice)
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 780, height: 560)
        .background(theme.background.opacity(0.35))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review the changes to \(fileName)")
        .onAppear {
            AccessibilityNotification.Announcement(summaryText).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fileName)
                .font(.headline)
                .foregroundStyle(theme.accent)

            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(summaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top)
        .padding(.bottom, notice == nil ? 16 : 6)
    }

    // MARK: - Notice

    /// The warning about a file that changed on disk.
    private func noticeRow(_ notice: String) -> some View {
        Label(notice, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let readError {
            ContentUnavailableView(
                "The File Could Not Be Read",
                systemImage: "exclamationmark.triangle",
                description: Text(readError)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch SaveReviewView.content(for: difference) {
            case .changes:
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(difference.hunks) { hunk in
                            DiffHunkView(hunk: hunk, theme: theme)
                        }
                    }
                    .padding(.vertical, 8)
                }
            case .note(let note):
                ContentUnavailableView(
                    note,
                    systemImage: "info.circle",
                    description: Text("The lines of the file are the same, but the bytes are not.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noChanges:
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "equal.circle",
                    description: Text("The file on disk already holds the text that would be written.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                onSave()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(readError != nil)
        }
        .padding()
    }

    private var summaryText: String {
        if readError != nil {
            return "The file could not be read, so the changes cannot be shown."
        }
        return DiffEngine.summary(for: difference)
    }

    /// The content the sheet shows for a difference.
    ///
    /// A difference that holds no changed line still changed the file, so
    /// the note of the difference is shown and not the empty state.
    static func content(for difference: DiffEngine.Difference) -> SaveReviewContent {
        if !difference.hunks.isEmpty { return .changes }
        if let note = difference.note { return .note(note) }
        return .noChanges
    }
}

/// What the body of the save review shows.
enum SaveReviewContent: Equatable {
    /// The file holds changed lines.
    case changes
    /// The lines are the same, but the bytes are not.
    case note(String)
    /// The file holds the text that would be written.
    case noChanges
}

/// One hunk of the diff, with the line numbers of the old and the new text.
private struct DiffHunkView: View {
    let hunk: DiffEngine.Hunk
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            ForEach(Array(numberedLines.enumerated()), id: \.offset) { _, numbered in
                DiffLineView(
                    text: numbered.line.text,
                    kind: numbered.line.kind,
                    oldNumber: numbered.oldNumber,
                    newNumber: numbered.newNumber,
                    theme: theme
                )
            }
        }
        .padding(.bottom, 10)
    }

    /// The lines of the hunk with the line numbers they hold.
    private var numberedLines: [(line: DiffEngine.Line, oldNumber: Int?, newNumber: Int?)] {
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        var numbered: [(line: DiffEngine.Line, oldNumber: Int?, newNumber: Int?)] = []
        for line in hunk.lines {
            switch line.kind {
            case .context:
                numbered.append((line, oldNumber, newNumber))
                oldNumber += 1
                newNumber += 1
            case .removed:
                numbered.append((line, oldNumber, nil))
                oldNumber += 1
            case .added:
                numbered.append((line, nil, newNumber))
                newNumber += 1
            }
        }
        return numbered
    }
}

/// One line of the diff, with the old and the new line number.
private struct DiffLineView: View {
    let text: String
    let kind: DiffEngine.Line.Kind
    let oldNumber: Int?
    let newNumber: Int?
    let theme: AppTheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(theme.muted)

            Text(newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(theme.muted)

            Text(marker)
                .frame(width: 20, alignment: .leading)
                .padding(.leading, 6)
                .foregroundStyle(color)

            Text(text.isEmpty ? " " : text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(background)
    }

    private var marker: String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    private var color: Color {
        switch kind {
        case .context: return .secondary
        case .added: return .green
        case .removed: return .red
        }
    }

    private var background: Color {
        switch kind {
        case .context: return .clear
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        }
    }
}
