import AppKit
import SwiftUI

/// Shows which config files SketchyBar loads, which files no loader
/// reaches, and which loader lines point at files that are gone.
///
/// The view only reads. It never changes the config.
struct ReachabilityView: View {
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var report: ConfigGraphReport?
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
                Text("Reachability Map")
                    .font(.headline)

                summary
            }

            Spacer()

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
        } else if let report {
            Text(summaryText(for: report))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(summaryText(for: report))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            if report.missingTargets.isEmpty && report.orphanFiles.isEmpty && report.cycles.isEmpty {
                ContentUnavailableView("No load problems found", systemImage: "checkmark.circle")
            } else {
                List {
                    missingTargetsSection(report)
                    orphanFilesSection(report)
                    cyclesSection(report)
                }
            }
        }
    }

    private func missingTargetsSection(_ report: ConfigGraphReport) -> some View {
        Section("Missing Targets") {
            if report.missingTargets.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.missingTargets) { missing in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relativePath(missing.from))
                        Text("Line \(missing.line) requires \(missing.target)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    revealButton(for: missing.from)
                }
            }
        }
    }

    private func orphanFilesSection(_ report: ConfigGraphReport) -> some View {
        Section("Orphan Files") {
            if report.orphanFiles.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if !report.dynamicRequireFiles.isEmpty {
                    Text(dynamicRequireNote(report))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(report.orphanFiles, id: \.self) { file in
                    HStack {
                        Text(relativePath(file))

                        Spacer()

                        revealButton(for: file)
                    }
                }
            }
        }
    }

    private func cyclesSection(_ report: ConfigGraphReport) -> some View {
        Section("Cycles") {
            if report.cycles.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.cycles, id: \.self) { cycle in
                HStack {
                    Text(cycleChain(cycle))

                    Spacer()

                    if let first = cycle.first {
                        revealButton(for: first)
                    }
                }
            }
        }
    }

    private func revealButton(for url: URL) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("Reveal", systemImage: "folder")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Reveal \(relativePath(url)) in Finder")
    }

    // MARK: - Analysis

    /// The analysis runs off the main actor, so a big config does not block
    /// the window while it is read.
    private func analyze() async {
        isAnalyzing = true
        let root = rootURL
        let computed = await Task.detached(priority: .userInitiated) {
            ConfigGraphService().report(for: root)
        }.value
        report = computed
        isAnalyzing = false
    }

    // MARK: - Text

    private func summaryText(for report: ConfigGraphReport) -> String {
        "\(report.reachableFiles.count) reachable files, "
            + "\(report.orphanFiles.count) orphan files, "
            + "\(report.missingTargets.count) missing targets, "
            + "\(report.cycles.count) cycles"
    }

    private func cycleChain(_ cycle: [URL]) -> String {
        let names = cycle.map { $0.lastPathComponent }
        guard let first = names.first else { return "" }
        return (names + [first]).joined(separator: " → ")
    }

    /// A file that requires a computed name can load files the map cannot
    /// see, so the orphan list can be incomplete.
    private func dynamicRequireNote(_ report: ConfigGraphReport) -> String {
        let names = report.dynamicRequireFiles.map { relativePath($0) }.joined(separator: ", ")
        return "\(names) load modules by a computed name, so this list can be incomplete."
    }

    private func relativePath(_ url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }
}
