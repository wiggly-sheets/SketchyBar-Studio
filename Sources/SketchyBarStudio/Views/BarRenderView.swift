import CoreGraphics
import SwiftUI

/// The preview pane of the rendered bar.
///
/// The bar is rendered by the vendored SketchyBar code, so the pane shows
/// the bar as SketchyBar would draw it. The image is drawn at the true
/// point size of the bar and the view applies one uniform factor that fits
/// the pane, so the proportions of the real menu bar survive. The 1:1
/// control shows the bar at its true point size, so one image pixel lands
/// on one device pixel of a display with the scale of 2.0, and the pane
/// scrolls sideways.
struct BarRenderView: View {
    /// The axis the pane scrolls on.
    ///
    /// The pane always scrolls sideways, because the bar of a display is
    /// wider than the pane at its true size.
    static let scrollAxis: Axis.Set = .horizontal

    @ObservedObject var store: SketchyBarStore
    let theme: AppTheme
    @StateObject private var state = BarRenderState()
    @State private var isOneToOne = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            liveBarNote
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

            Picker("Live bar", selection: $store.liveUpdateMode) {
                ForEach(LiveUpdateMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("How the live bar of SketchyBar follows the edits of the app. \(store.liveUpdateMode.explanation)")

            Toggle("1:1", isOn: $isOneToOne)
                .toggleStyle(.checkbox)
                .help("Show the bar at its true point size, so one image pixel lands on one device pixel of a display with the scale of 2.0. The pane scrolls sideways then.")
        }
    }

    /// What the live bar does now, and what the user can do about it.
    private var liveBarNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.liveUpdateMode.explanation)
                .font(.caption)
                .foregroundStyle(theme.muted)

            if store.liveBarHasSnapshot {
                Label("The live bar was changed by this app. The Restore button in the toolbar puts it back.",
                      systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
            }

            if !store.liveBarMessage.isEmpty {
                Text(store.liveBarMessage)
                    .font(.caption)
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private var imagePane: some View {
        GeometryReader { proxy in
            ScrollView(Self.scrollAxis) {
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

    /// What the render depends on: the source, the display and the files
    /// of that source.
    ///
    /// The key changes with every draft of the config the app has open,
    /// and with every change on disk of a config that is not open, so the
    /// bar is rendered again when the rendered source really changed.
    private var requestKey: Int {
        var hasher = Hasher()
        hasher.combine(effectiveSource)
        hasher.combine(store.barRenderDisplayID)
        hasher.combine(store.barRenderWidthOverride)
        hasher.combine(store.barRenderSignature(for: effectiveSource))
        return hasher.finalize()
    }

    /// The source the pane renders.
    private var effectiveSource: BarRenderSource? {
        if let source = store.barRenderSource { return source }
        return BarRenderChoices.defaultSource(configs: store.configs,
                                              openConfigID: store.selectedConfig?.id)
    }

    /// The display the bar is rendered for.
    ///
    /// The width of that display is the width of the virtual display, so
    /// the bar has the proportions of the real menu bar of that display: a
    /// SketchyBar bar is the display width minus twice the margin
    /// (`src/bar.c:437-494`).
    private func targetDisplay() -> BarRenderDisplay? {
        let displays = BarRenderDisplays.all()
        if let id = store.barRenderDisplayID,
           let display = displays.first(where: { $0.id == id }) {
            return display
        }
        if let main = BarRenderDisplays.main(),
           let display = displays.first(where: { $0.id == main.id }) {
            return display
        }
        return displays.first
    }

    /// Renders the bar of the current source.
    @MainActor
    private func renderCurrent() async {
        guard let source = effectiveSource else { return }
        let display = targetDisplay()
        let width = store.barRenderWidthOverride ?? display?.widthPoints ?? 1440
        let request = BarRenderRequest(
            files: store.barRenderFiles(for: source),
            displayWidthPoints: width,
            displayHeightPoints: display?.heightPoints ?? 900,
            warnings: store.barRenderWarnings(for: source)
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
            guard !Task.isCancelled, token == generation else { return }
            image = result.image
            pixelSize = result.pixelSize
            warnings = result.warnings
            isRendering = false
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            image = nil
            pixelSize = .zero
            warnings = []
            failure = error.localizedDescription
            isRendering = false
        }
    }
}
