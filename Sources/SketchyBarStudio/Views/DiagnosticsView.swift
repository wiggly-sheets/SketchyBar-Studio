import AppKit
import SwiftUI

/// Shows the problems the validator found in the config.
///
/// The view only reads. It never changes the config.
struct DiagnosticsView: View {
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: [ConfigDiagnostic]?
    @State private var isAnalyzing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 520)
        .task { await analyze() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Config Diagnostics")
                    .font(.headline)

                summary
            }

            Spacer()

            Button {
                Task { await analyze() }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .disabled(isAnalyzing)
            .help("Run the analysis again")

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder
    private var summary: some View {
        if isAnalyzing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing config...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Analyzing config")
        } else if let diagnostics {
            Text(summaryText(diagnostics))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(summaryText(diagnostics))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let diagnostics {
            if diagnostics.isEmpty {
                ContentUnavailableView("No problems found", systemImage: "checkmark.seal")
            } else {
                List {
                    section("Errors", diagnostics, severity: .error)
                    section("Warnings", diagnostics, severity: .warning)
                    section("Info", diagnostics, severity: .info)
                }
            }
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ diagnostics: [ConfigDiagnostic],
        severity: ConfigDiagnostic.Severity
    ) -> some View {
        let matching = diagnostics.filter { $0.severity == severity }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching) { diagnostic in
                    row(diagnostic)
                }
            }
        }
    }

    private func row(_ diagnostic: ConfigDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName(for: diagnostic.severity))
                .foregroundStyle(color(for: diagnostic.severity))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)

                if let detail = diagnostic.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let location = locationText(for: diagnostic) {
                    Text(location)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal(diagnostic) }
        .accessibilityLabel(accessibilityLabel(for: diagnostic))
        .help(helpText(for: diagnostic))
    }

    private func helpText(for diagnostic: ConfigDiagnostic) -> String {
        guard let fileURL = diagnostic.fileURL else { return "" }
        return "Reveal \(relativePath(fileURL)) in Finder"
    }

    /// The file of a diagnostic is revealed in Finder, the same way the
    /// reachability map does it.
    private func reveal(_ diagnostic: ConfigDiagnostic) {
        guard let url = diagnostic.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Analysis

    /// The analysis runs off the main actor, so a big config does not block
    /// the window while it is read.
    private func analyze() async {
        isAnalyzing = true
        let root = rootURL
        let computed = await Task.detached(priority: .userInitiated) {
            ConfigValidator().validate(rootURL: root)
        }.value
        diagnostics = computed
        isAnalyzing = false
    }

    // MARK: - Text

    private func summaryText(_ diagnostics: [ConfigDiagnostic]) -> String {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        let infos = diagnostics.filter { $0.severity == .info }.count
        return "\(errors) errors, \(warnings) warnings, \(infos) infos"
    }

    private func iconName(for severity: ConfigDiagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for severity: ConfigDiagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func locationText(for diagnostic: ConfigDiagnostic) -> String? {
        guard let fileURL = diagnostic.fileURL else { return nil }
        let path = relativePath(fileURL)
        guard let line = diagnostic.line else { return path }
        return "\(path):\(line)"
    }

    private func accessibilityLabel(for diagnostic: ConfigDiagnostic) -> String {
        guard let location = locationText(for: diagnostic) else { return diagnostic.title }
        return "\(diagnostic.title), \(location)"
    }

    private func relativePath(_ url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}
