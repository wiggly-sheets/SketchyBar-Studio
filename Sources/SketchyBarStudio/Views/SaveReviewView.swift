import SwiftUI

/// Shows what a save would write, as a line diff of the file on disk and
/// the text that would be written.
///
/// The view only shows. It never writes a file, and it never changes the
/// drafts. The save is done by whoever opened the sheet.
struct SaveReviewView: View {
    let fileName: String
    let theme: AppTheme
    let hunks: [DiffEngine.Hunk]
    let readError: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .padding()
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
        } else if hunks.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "equal.circle",
                description: Text("The file on disk already holds the text that would be written.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks) { hunk in
                        DiffHunkView(hunk: hunk, theme: theme)
                    }
                }
                .padding(.vertical, 8)
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
        return DiffEngine.summary(for: hunks)
    }
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
