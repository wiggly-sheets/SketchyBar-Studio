import CoreGraphics
import SwiftUI

/// The preview pane of the rendered bar.
///
/// The bar is rendered by the vendored SketchyBar code, so the pane shows
/// the bar as SketchyBar would draw it. The image is drawn at its true
/// pixel size and the view applies one uniform factor that fits the pane,
/// so the proportions of the real menu bar survive. The 1:1 control shows
/// the bar at one image pixel per point, and the pane scrolls sideways.
struct BarRenderView: View {
    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    @StateObject private var state = BarRenderState()
    @State private var isOneToOne = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            BarRenderProfilePicker(store: store, theme: theme)
            imagePane
            messages
        }
        .padding(16)
        .background(theme.background.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        .task(id: requestKey) { await renderCurrent() }
    }

    private var header: some View {
        HStack {
            Label("Rendered Bar", systemImage: "menubar.rectangle")
                .font(.headline)
                .foregroundStyle(theme.accent)

            Spacer()

            Toggle("1:1", isOn: $isOneToOne)
                .toggleStyle(.checkbox)
                .help("Show the bar at one image pixel per point. The pane scrolls sideways then.")
        }
    }

    private var imagePane: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                imageView(in: proxy.size)
                    .frame(minWidth: proxy.size.width, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 120)
        .background(theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.accent.opacity(0.55))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func imageView(in paneSize: CGSize) -> some View {
        if let image = state.image {
            let layout = BarRenderLayout(imageSize: state.pixelSize,
                                         paneSize: paneSize,
                                         isOneToOne: isOneToOne)
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.drawnSize.width, height: layout.drawnSize.height)
        } else {
            Text(state.isRendering ? "Rendering the bar..." : "No bar to show yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let failure = state.failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        } else if !state.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// What the render depends on: the source, the width and the drafts.
    ///
    /// The key changes with every draft, so a new draft renders the bar
    /// again.
    private var requestKey: Int {
        var hasher = Hasher()
        hasher.combine(effectiveSource)
        hasher.combine(store.barRenderWidthOverride)
        hasher.combine(store.sourceDraftRevision)
        for file in store.files {
            hasher.combine(file.id)
            for value in file.values {
                hasher.combine(value.draftValue)
            }
        }
        return hasher.finalize()
    }

    /// The source the pane renders.
    private var effectiveSource: BarRenderSource? {
        if let source = store.barRenderSource { return source }
        return BarRenderChoices.defaultSource(configs: store.configs,
                                              openConfigID: store.selectedConfig?.id)
    }

    /// Renders the bar of the current source.
    @MainActor
    private func renderCurrent() async {
        guard let source = effectiveSource else { return }
        let display = BarRenderDisplay.target()
        let width = store.barRenderWidthOverride ?? BarRenderDisplay.width(of: display)
        let request = BarRenderRequest(
            files: store.barRenderFiles(for: source),
            displayWidthPoints: width,
            displayHeightPoints: BarRenderDisplay.height(of: display)
        )
        await state.render(request)
    }
}

/// The state of the rendered bar.
///
/// The render runs off the main actor and the image comes back to the main
/// actor. Every render gets a number, and the result of an older render is
/// dropped, so a slow render cannot overwrite a newer one.
@MainActor
final class BarRenderState: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isRendering = false
    @Published private(set) var failure: String?

    /// The number of the newest render. A result of an older render is
    /// dropped.
    private var generation = 0

    func render(_ request: BarRenderRequest) async {
        generation &+= 1
        let token = generation
        isRendering = true
        failure = nil

        do {
            let result = try await BarRendererService.shared.render(request)
            guard token == generation else { return }
            image = result.image
            pixelSize = result.pixelSize
            warnings = result.warnings
            isRendering = false
        } catch {
            guard token == generation else { return }
            image = nil
            pixelSize = .zero
            warnings = []
            failure = error.localizedDescription
            isRendering = false
        }
    }
}
