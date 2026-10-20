import AppKit
import SwiftUI

/// Shows the item files of the config that look like copies of each other.
///
/// The view only reads. It never changes the config.
struct DuplicatesView: View {
    let rootURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var signatures: [DuplicateFinder.ItemSignature]?
    @State private var pairs: [DuplicateFinder.Pair] = []
    @State private var isAnalyzing = false
    @State private var threshold = DuplicateFinder.defaultThreshold
    @State private var selectedPairID: DuplicateFinder.Pair.ID?
    @State private var analysisID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 760, height: 560)
        .task { await analyze() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Near-Duplicate Items")
                        .font(.headline)

                    summary
                }

                Spacer()

                Button {
                    Task { await analyze(reparse: true) }
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

            thresholdControl
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
        } else if let signatures {
            Text(summaryText(signatures))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(summaryText(signatures))
        }
    }

    private var thresholdControl: some View {
        HStack(spacing: 8) {
            Text("Match")
                .font(.callout)

            Slider(value: $threshold, in: 0.5...1.0, step: 0.05) {
                Text("Match threshold")
            }
            .frame(width: 220)
            .onChange(of: threshold) { _, _ in
                Task { await analyze() }
            }

            Text("\(Int((threshold * 100).rounded()))%")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if signatures != nil {
            if pairs.isEmpty {
                ContentUnavailableView("No near-duplicates found", systemImage: "square.on.square.dashed")
            } else {
                List(selection: $selectedPairID) {
                    ForEach(pairs) { pair in
                        row(pair)
                            .tag(pair.id)
                    }

                    if let selected = selectedPair {
                        Section("Differences") {
                            differences(selected)
                        }
                    }
                }
            }
        }
    }

    private var selectedPair: DuplicateFinder.Pair? {
        pairs.first { $0.id == selectedPairID }
    }

    // MARK: - Rows

    private func row(_ pair: DuplicateFinder.Pair) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(pair.first.relativePath)
                Text("and")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pair.second.relativePath)

                Spacer()

                Text(scoreText(pair))
                    .monospacedDigit()
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(pair))

            HStack(spacing: 10) {
                Text("\(pair.sharedKeys.count) shared")
                Text("\(pair.onlyInFirst.count) only in the first")
                Text("\(pair.onlyInSecond.count) only in the second")

                Spacer()

                revealButton(for: pair.first)
                revealButton(for: pair.second)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func revealButton(for signature: DuplicateFinder.ItemSignature) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([signature.fileURL])
        } label: {
            Label(fileName(signature), systemImage: "folder")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Reveal \(signature.relativePath) in Finder")
    }

    /// The name of the file, without the folders around it.
    private func fileName(_ signature: DuplicateFinder.ItemSignature) -> String {
        signature.relativePath.split(separator: "/").last.map(String.init) ?? signature.relativePath
    }

    @ViewBuilder
    private func differences(_ pair: DuplicateFinder.Pair) -> some View {
        if pair.differingValues.isEmpty {
            Text("The shared keys hold the same values.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Key")
                        .font(.caption)
                    Text(pair.first.relativePath)
                        .font(.caption)
                    Text(pair.second.relativePath)
                        .font(.caption)
                }

                ForEach(pair.differingValues, id: \.self) { key in
                    GridRow {
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(pair.first.properties[key] ?? "—")
                        Text(pair.second.properties[key] ?? "—")
                    }
                }
            }
            .font(.callout)
        }

        if !pair.onlyInFirst.isEmpty {
            Text("Only in \(pair.first.relativePath): \(pair.onlyInFirst.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !pair.onlyInSecond.isEmpty {
            Text("Only in \(pair.second.relativePath): \(pair.onlyInSecond.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Analysis

    /// The analysis runs off the main actor, so a big config does not block
    /// the window while it is read.
    ///
    /// The files are read once. Moving the threshold only compares the
    /// files that were read before.
    private func analyze(reparse: Bool = false) async {
        isAnalyzing = true
        analysisID += 1
        let currentAnalysis = analysisID

        let root = rootURL
        let currentThreshold = threshold
        let cached = reparse ? nil : signatures

        let computed = await Task.detached(priority: .userInitiated) {
            let finder = DuplicateFinder()
            let found = cached ?? finder.signatures(in: root)
            let matched = finder.pairs(in: found, threshold: currentThreshold)
            return (found, matched)
        }.value

        // A newer run has already started, so this result is stale.
        guard currentAnalysis == analysisID else { return }

        signatures = computed.0
        pairs = computed.1
        isAnalyzing = false
    }

    // MARK: - Text

    private func summaryText(_ signatures: [DuplicateFinder.ItemSignature]) -> String {
        let files = signatures.count
        let count = pairs.count
        return "\(files) item \(files == 1 ? "file" : "files") analysed, "
            + "\(count) near-duplicate \(count == 1 ? "pair" : "pairs")"
    }

    private func scoreText(_ pair: DuplicateFinder.Pair) -> String {
        "\(Int((pair.score * 100).rounded()))% similar"
    }

    private func accessibilityLabel(_ pair: DuplicateFinder.Pair) -> String {
        "\(pair.first.relativePath) and \(pair.second.relativePath), "
            + "\(scoreText(pair)), "
            + "\(pair.sharedKeys.count) shared keys, "
            + "\(pair.onlyInFirst.count) keys only in the first, "
            + "\(pair.onlyInSecond.count) keys only in the second"
    }
}
